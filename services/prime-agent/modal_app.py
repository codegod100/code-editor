"""prime-agent on Modal — the compute behind a freeq bot, and nothing else.

Two deployed Functions:

  run_task  one task → one disposable Sandbox running Prime Agent
            (https://github.com/PrimeIntellect-ai/prime-agent) on GLM 5.3 Flash
            over Cloudflare Workers AI, torn down afterwards
  proof     serves the Modal-signed identity tokens a finished task published

Nothing here connects to freeq. The bot that holds the IRC socket, the DID and
the task lifecycle lives on Fly (see bot/src/prime.ts) and calls `run_task`
through the Modal JS SDK. Exactly one process may hold that connection —
channel membership *is* the socket, and a second connection would race the
first for every offer — so this app deliberately has no way to open one.

That split puts a workspace token on the Fly machine, so keep the shape that
makes it survivable: the bot asks for `run_task` and nothing else, and every
Sandbox detail (image, secrets, timeout, egress, teardown) stays here, out of
reach of the caller. A caller who can only name a prompt and a task id cannot
widen the blast radius of the job, whatever credential it holds.

Sandboxes land in their own App, `prime-agent-sandboxes`, so
`modal app logs prime-agent` stays readable.

Secrets expected in the workspace:
  cloudflare-ai     CLOUDFLARE_API_KEY=... CLOUDFLARE_ACCOUNT_ID=...
                    — injected into each Sandbox, nothing else reads it

  modal secret create cloudflare-ai CLOUDFLARE_API_KEY=... CLOUDFLARE_ACCOUNT_ID=...

Deploy:       modal deploy modal_app.py
Smoke-test:   modal run modal_app.py --prompt "What is a did:key?"
"""

from __future__ import annotations

import json
import os
import shlex
import time
import threading
from typing import Any, Callable

import modal

app = modal.App("prime-agent")

# Only the Sandboxes need model credentials; nothing else here reads them.
model_secret = modal.Secret.from_name(os.environ.get("MODEL_SECRET_NAME", "cloudflare-ai"))

# ── Per-task Sandbox ─────────────────────────────────────────────────────
PRIME_AGENT_PKG = os.environ.get("PRIME_AGENT_PKG", "@earendil-works/pi-coding-agent")
# Back to a GLM — gpt-oss-120b cannot finish a task that uses a tool.
#
# It answers a one-shot prompt fine, and then dies the moment a tool result
# comes back: Cloudflare's schema for that model requires `content` to be a
# string, and `pi` sends `content: null` on the assistant message that carries
# the tool calls, so the *second* request of every tool-using task is rejected
# with a bodyless 400. Replayed by hand against this account: gpt-oss-120b and
# llama-3.3-70b reject that message shape, glm-5.3-flash accepts it.
#
# The GLM problem that sent us to gpt-oss in the first place is a catalog bug,
# not a model limit: `pi` budgets `max_tokens` from max-output, and the GLM
# entries list 1048576 there — the whole context window — so Cloudflare refuses
# every call for exceeding it by the length of the prompt. MAX_OUTPUT_CAP below
# rewrites that figure in the Sandbox image.
PRIMARY_MODEL = os.environ.get("PRIME_AGENT_MODEL", "@cf/zai-org/glm-5.3-flash")
FALLBACK_MODEL = os.environ.get("PRIME_AGENT_FALLBACK_MODEL", "@cf/zai-org/glm-4.7-flash")
PROVIDER = os.environ.get("PRIME_AGENT_PROVIDER", "cloudflare-workers-ai")
# The Cloudflare GLM entries declare `reasoning: true` but carry no thinking
# level map, so no level is passed unless you ask for one.
THINKING = os.environ.get("PRIME_AGENT_THINKING", "")

SANDBOX_APP = os.environ.get("SANDBOX_APP", "prime-agent-sandboxes")
SANDBOX_TIMEOUT_S = int(os.environ.get("SANDBOX_TIMEOUT_S", 15 * 60))
SANDBOX_CPU = float(os.environ.get("SANDBOX_CPU", 2))
# Floor on the gap between progress notes. Each one lands in the channel as an
# act move, so this is a courtesy limit, not a performance one.
PROGRESS_MIN_GAP_S = float(os.environ.get("PROGRESS_MIN_GAP_S", 20))
SANDBOX_MEMORY_MIB = int(os.environ.get("SANDBOX_MEMORY_MIB", 4096))

# Domain allowlist for Sandbox egress. Unset means open — usually what you want
# for research work. Set it to lock a Sandbox to the model endpoint and a
# package mirror or two; `api.cloudflare.com` is the minimum.
EGRESS_ALLOWLIST = [
    d.strip() for d in os.environ.get("SANDBOX_EGRESS_ALLOWLIST", "").split(",") if d.strip()
]

# What the GLM entries in Prime Agent's model catalog should say for max
# output. Anything well under the context window works; this leaves ~1.27M
# tokens of room for the conversation, which no task here will reach.
MAX_OUTPUT_CAP = os.environ.get("PRIME_AGENT_MAX_OUTPUT", "32768")

# Rewrite that figure wherever the catalog ships it — the JSON data file and
# the bundled copy compiled into dist/ both carry it, and which one a given
# release reads is an implementation detail. Failing the build when nothing
# matched is the point: a silent no-op here comes back as a 400 per task.
_CAP_CATALOG = (
    'const fs=require("fs"),path=require("path");'
    f'const root="/usr/local/lib/node_modules/{PRIME_AGENT_PKG}";'
    'const id="@cf/zai-org/glm-";const cap=process.env.PI_MAX_OUTPUT;'
    'const re=new RegExp(id+"[\\\\s\\\\S]{0,600}?maxTokens\\"?\\\\s*:\\\\s*1048576","g");'
    'const files=[];(function walk(d){for(const e of fs.readdirSync(d,{withFileTypes:true}))'
    '{const p=path.join(d,e.name);if(e.isDirectory())walk(p);'
    'else if(/\\.(js|json)$/.test(e.name))files.push(p);}})(root);'
    'let hits=0;for(const f of files){const s=fs.readFileSync(f,"utf8");if(!s.includes(id))continue;'
    'const out=s.replace(re,m=>m.replace(/1048576$/,cap));'
    'if(out!==s){fs.writeFileSync(f,out);hits++;console.log("capped max-output in "+f);}}'
    'if(!hits)throw new Error("no GLM catalog entry to cap — has the catalog moved?");'
)

# The Sandbox image: Node 22, Prime Agent, and uv — which Prime Agent's Python
# tool needs the first time it runs. Modal caches the build, so this is paid
# once per layer change rather than once per task.
sandbox_image = (
    modal.Image.from_registry("node:22-slim", add_python=None)
    .run_commands(
        "apt-get update && apt-get install -y --no-install-recommends "
        "ca-certificates curl git ripgrep python3 && rm -rf /var/lib/apt/lists/*",
        # uv backs Prime Agent's managed CPython; baking it in keeps the first
        # ipython call from paying for an install.
        "curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh",
        f"npm install -g --no-fund --no-audit {PRIME_AGENT_PKG}",
        # The npm bin is `pi`; the docs and CLI call it prime-agent.
        'ln -sf "$(command -v pi)" /usr/local/bin/prime-agent',
        f"PI_MAX_OUTPUT={MAX_OUTPUT_CAP} node -e {shlex.quote(_CAP_CATALOG)}",
    )
    .workdir("/work")
)


class _Events:
    """Prime Agent's JSON event stream, reduced to what the bot reports.

    Fed a line at a time rather than a finished buffer, because a task that
    takes five minutes should not be five minutes of silence: the caller gets
    a note as each tool starts, so the channel can show the task is alive and
    what it is doing. Reading stdout only after the process exits — which is
    what this replaced — makes a working run and a hung one look identical
    from outside.

    Carries the final answer, the tools used, and any error the agent
    reported. A failed model call still exits 0 and still emits a well-formed
    stream, with the failure in `errorMessage` on a message that has no
    content; unread, every provider-side fault looks like "no answer".
    """

    def __init__(self) -> None:
        self.text = ""
        self.tool_calls: list[str] = []
        self.error = ""
        self._buf = ""

    def feed(self, chunk: str) -> list[str]:
        """Consume a chunk of stdout, returning notes worth reporting.

        Chunk boundaries do not respect line boundaries, so hold the tail
        until its newline arrives — a half-read JSON object parses as
        nothing, and would drop the event it belonged to.
        """
        notes: list[str] = []
        self._buf += chunk
        *lines, self._buf = self._buf.split("\n")
        for raw in lines:
            notes.extend(self._line(raw))
        return notes

    def close(self) -> list[str]:
        """Consume whatever arrived without a trailing newline."""
        tail, self._buf = self._buf, ""
        return self._line(tail)

    def _line(self, raw: str) -> list[str]:
        line = raw.strip()
        if not line.startswith("{"):
            return []
        try:
            event: Any = json.loads(line)
        except json.JSONDecodeError:
            return []  # not an event, or not one we understand

        if event.get("type") == "tool_execution_start" and event.get("toolName"):
            self.tool_calls.append(event["toolName"])
            return [f"tool {len(self.tool_calls)}: {event['toolName']}"]

        if (
            event.get("type") == "message_end"
            and event.get("message", {}).get("role") == "assistant"
        ):
            message = event["message"]
            # Each assistant message supersedes the last; the final one is the answer.
            content = message.get("content")
            if isinstance(content, str):
                parts = [content]
            elif isinstance(content, list):
                parts = [
                    c.get("text", "")
                    for c in content
                    if isinstance(c, dict) and c.get("type") == "text"
                ]
            else:
                parts = []
            joined = "".join(parts).strip()
            if joined:
                self.text = joined
            if message.get("stopReason") == "error":
                self.error = message.get("errorMessage") or "agent reported an error"
                return [f"model error: {self.error}"]
        return []


def _parse_events(stdout: str) -> tuple[str, list[str], str]:
    """The reducer above, run over a finished buffer. Kept for tests."""
    events = _Events()
    events.feed(stdout)
    events.close()
    return events.text, events.tool_calls, events.error


# Proof manifests, keyed by task id. Written by run_prime_agent, read by the
# public `proof` endpoint below.
proofs = modal.Dict.from_name("prime-agent-proofs", create_if_missing=True)


def run_prime_agent(
    prompt: str,
    on_progress: Callable[[str], None] | None = None,
    task_id: str | None = None,
) -> dict:
    """Run GLM 5.3, falling back to GLM 4.7 only after a capacity 429."""
    note = on_progress or (lambda _msg: None)
    try:
        return _run_prime_agent(prompt, PRIMARY_MODEL, note, task_id)
    except RuntimeError as error:
        if (
            not FALLBACK_MODEL
            or FALLBACK_MODEL == PRIMARY_MODEL
            or "429 status code" not in str(error)
        ):
            raise
        note(f"{PRIMARY_MODEL} unavailable (429); retrying with {FALLBACK_MODEL}")
        result = _run_prime_agent(prompt, FALLBACK_MODEL, note, task_id)
        result["fallback_from"] = PRIMARY_MODEL
        return result


def _run_prime_agent(
    prompt: str,
    active_model: str,
    note: Callable[[str], None],
    task_id: str | None,
) -> dict:
    """Run one task to completion in a fresh Sandbox.

    Always terminates the Sandbox, including on failure — a leaked Sandbox
    bills until its timeout.
    """
    import time

    started_at = time.monotonic()
    sandbox_app = modal.App.lookup(SANDBOX_APP, create_if_missing=True)

    note("starting sandbox")
    create_started = time.monotonic()
    sandbox = modal.Sandbox.create(
        app=sandbox_app,
        image=sandbox_image,
        secrets=[model_secret],
        # Modal signs a JWT naming this container, its app and its workspace,
        # and publishes the key that verifies it at oidc.modal.com. That turns
        # "we ran a sandbox for you" from our word into Modal's, checkable by
        # anyone with no access to this workspace — and it outlives the
        # Sandbox, which disappears from the API the moment it terminates.
        include_oidc_identity_token=True,
        timeout=SANDBOX_TIMEOUT_S,
        workdir="/work",
        cpu=SANDBOX_CPU,
        memory=SANDBOX_MEMORY_MIB,
        **({"outbound_domain_allowlist": EGRESS_ALLOWLIST} if EGRESS_ALLOWLIST else {}),
    )

    try:
        create_ms = int((time.monotonic() - create_started) * 1000)
        identity_token = _read_identity_token(sandbox)
        note(f"sandbox {sandbox.object_id} up in {create_ms}ms — running prime-agent")
        exec_started = time.monotonic()
        # Run through a shell for one reason: `</dev/null`.
        #
        # `-p` makes pi non-interactive, but it still reads stdin, and the pipe
        # Modal hands an exec never reaches EOF. So the agent finishes its work
        # and then waits forever for input nobody will send — no output on
        # either stream, killed by the Sandbox timeout. Measured: identical
        # invocations differ only in stdin, and it decides everything.
        #   stdin = pipe       → hangs until killed
        #   stdin = /dev/null  → answers in seconds
        argv = [
            "prime-agent",
            "--mode", "json",
            "--provider", PROVIDER,
            "--model", active_model,
            *(("--thinking", THINKING) if THINKING else ()),
            "--no-session",
            "-p",
            # Everything after `--` is the prompt, even if it starts with a dash.
            "--", prompt,
        ]
        command = " ".join(shlex.quote(a) for a in argv)
        proc = sandbox.exec(
            "sh", "-c", f"exec {command} </dev/null",
            timeout=SANDBOX_TIMEOUT_S,
            workdir="/work",
        )

        # Drain stderr on its own thread: waiting on stdout alone while stderr
        # backs up would stall the process.
        stderr_chunks: list[str] = []
        drain = threading.Thread(
            target=lambda: stderr_chunks.append(proc.stderr.read()), daemon=True
        )
        drain.start()

        # Read stdout as it arrives, not after the fact. The notes are the only
        # sign of life a requester gets during a long run, so they are rationed
        # rather than streamed: one per tool call, and never more than one every
        # PROGRESS_MIN_GAP_S, because each one costs the bot an act move in a
        # channel other people are reading.
        events = _Events()
        last_note_at = 0.0
        for chunk in proc.stdout:
            for candidate in events.feed(chunk):
                now = time.monotonic()
                if now - last_note_at < PROGRESS_MIN_GAP_S:
                    continue
                last_note_at = now
                note(candidate)
        events.close()

        exit_code = proc.wait()
        drain.join(timeout=10)
        stderr = "".join(stderr_chunks)
        text, tool_calls, error = events.text, events.tool_calls, events.error

        if not text:
            tail = "\n".join(stderr.strip().splitlines()[-6:])
            detail = error or tail or f"exit {exit_code}, nothing on stdout or stderr"
            raise RuntimeError(f"prime-agent produced no answer ({active_model}): {detail}")

        return {
            "ok": True,
            "text": text,
            # Where the time went, so "it's slow" can be diagnosed rather than
            # guessed at: sandbox creation and the agent run are very different
            # problems with very different fixes.
            "create_ms": create_ms,
            # One entry per Sandbox this task used. Today that is always one;
            # the shape is a list because "how many sandboxes did this job
            # really use" is the question the proof exists to answer.
            "proof": [{"sandbox_id": sandbox.object_id, "identity_token": identity_token}],
            "agent_ms": int((time.monotonic() - exec_started) * 1000),
            "sandbox_id": sandbox.object_id,
            "elapsed_ms": int((time.monotonic() - started_at) * 1000),
            "tool_calls": tool_calls,
            "exit_code": exit_code,
            "model": active_model,
        }
    finally:
        try:
            sandbox.terminate()
        except Exception as exc:  # a leaked Sandbox is worth a loud log line
            print(f"[sandbox] terminate failed for {sandbox.object_id}: {exc!r}")


def _read_identity_token(sandbox: "modal.Sandbox") -> str:
    """The Sandbox's Modal-signed identity token, or "" if it has none.

    Read from inside the Sandbox because that is where Modal puts it. A failure
    here must not fail the task: the proof is evidence about the work, not the
    work itself.
    """
    try:
        proc = sandbox.exec("printenv", "MODAL_IDENTITY_TOKEN", timeout=30)
        token = (proc.stdout.read() or "").strip()
        proc.wait()
        return token
    except Exception as exc:
        print(f"[proof] could not read identity token: {exc!r}")
        return ""


# ── Remote dispatch: the Fly bot's only way in ───────────────────────────
# This is the whole interface. The IRC side of this system used to run here as
# a subprocess reaching Sandbox creation over loopback; it lives on Fly now,
# and the loopback broker and the freeq worker that needed it are gone rather
# than left dormant — a second thing able to join #tasks is a thing that will
# eventually join #tasks. See the note at the top of this file.


@app.function(
    image=modal.Image.debian_slim(python_version="3.12"),
    # Sandbox.create() injects this into the Sandbox; the Function never reads it.
    secrets=[model_secret],
    # Outlive the Sandbox we are waiting on, with room for setup and teardown.
    timeout=SANDBOX_TIMEOUT_S + 120,
    # Stay warm between tasks so a working session doesn't pay container cold
    # start on every command, while an idle night still scales to zero.
    scaledown_window=int(os.environ.get("DISPATCH_SCALEDOWN_S", 600)),
)
def run_task(prompt: str, task_id: str | None = None) -> dict:
    """One task, one Sandbox. The unit of work the bot dispatches."""
    result = run_prime_agent(
        prompt, on_progress=lambda msg: print(f"[run-task] {msg}"), task_id=task_id
    )
    if task_id:
        # Published as-is by the `proof` endpoint. Written after the fact rather
        # than during, so a task that fails mid-run publishes nothing to argue
        # about.
        proofs[task_id] = {
            "task_id": task_id,
            "app": SANDBOX_APP,
            "completed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "sandboxes": result.get("proof", []),
        }
    return result


# ── The public proof endpoint ────────────────────────────────────────────
# Deliberately unauthenticated: a proof nobody outside the workspace can fetch
# is not a proof. It serves only task ids that a completed run wrote, so it is
# a publication channel, not a lookup API over the workspace.
#
# What it hands out are Modal-signed identity tokens. They are short-lived
# credentials as well as evidence — anyone who fetches one before it expires
# could present it to a third party that trusts Modal's OIDC issuer. They
# expire in minutes and are inert afterwards, but that window is real, so do
# not widen it by extending token lifetimes.
web_image = modal.Image.debian_slim(python_version="3.12").pip_install("fastapi[standard]")


@app.function(image=web_image, max_containers=2)
@modal.asgi_app()
def proof():
    from fastapi import FastAPI, HTTPException

    api = FastAPI(docs_url=None, redoc_url=None)

    @api.get("/proof/{task_id}")
    def get_proof(task_id: str) -> dict:
        try:
            manifest = proofs[task_id]
        except KeyError:
            raise HTTPException(status_code=404, detail="no proof for that task id")
        return {
            **manifest,
            "verify": {
                "jwks": "https://oidc.modal.com/.well-known/openid-configuration",
                "how": (
                    "Verify each identity_token against Modal's JWKS. Distinct "
                    "container_id claims are distinct Sandboxes; app_name and "
                    "workspace_id say whose they were."
                ),
            },
        }

    return api


@app.local_entrypoint()
def main(prompt: str = "What is a did:key, in two sentences?"):
    """Run one task through the sandbox path with no freeq involved — the
    fastest way to check that the image builds, that Workers AI answers, and
    that the event parsing finds the final message."""
    result = run_prime_agent(prompt, on_progress=lambda msg: print(f"[run-task] {msg}"))
    print(
        f"[run-task] {result['sandbox_id']} exited {result['exit_code']} "
        f"in {result['elapsed_ms']}ms"
        + (f" — tools: {', '.join(result['tool_calls'])}" if result["tool_calls"] else "")
    )
    print(result["text"])
