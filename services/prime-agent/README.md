# prime-agent on freeq

A [freeq](https://github.com/freeq-irc/freeq) worker built on
[`@freeq/bot-kit`](https://github.com/freeq-irc/freeq/tree/main/freeq-bot-kit-js)
that hands each task to a fresh [Prime
Agent](https://github.com/PrimeIntellect-ai/prime-agent) in its own Modal
Sandbox, running GLM 5.3 Flash on Cloudflare Workers AI. When Cloudflare
rejects GLM 5.3 with a capacity 429, the task automatically retries once with
GLM 4.7 Flash.

```
 freeq (#tasks)          Fly                     Modal
 ──────────────          ──────────────────      ─────────────────────────────
 "offer say hello" ────► task-desk               (nothing here joins freeq)
                         │ posts the offer,
                         │ no Modal token
                         ▼
 handoff offer  ───────► freeq-bot (worker)
 caps=prime_agent        │ claims it; one DID,
                         │ one WebSocket
                         │
                         └─ run_task(prompt, task_id) ─► run_task
                                                          │ per task:
                                                          ├─ Sandbox.create() ─┐
                                                          │                    ▼
                                                          │       Sandbox (disposable)
                                                          │         prime-agent --mode json
                                                          │         --model @cf/zai-org/glm-5.3-flash
                                                          │           · python REPL
                                                          │           · shell, files, subagents
                                                          │                    │
                                                          ◄─ JSON events ──────┘
                                                          │  terminate()
 complete + answer ◄──── answer + proof ◄─────────────────┘
```

Prime Agent's main tool is a persistent Python REPL — it runs shell commands,
edits files and spawns subagents through code. That is not something to host in
the bot's own container, which is why each task gets a disposable Sandbox:
isolated filesystem, its own egress policy, a hard timeout, and nothing carried
over from the task before it. The bot process itself never reasons.

## Files

| Path | What it is |
| --- | --- |
| [modal_app.py](modal_app.py) | The Modal app: `run_task` (one task, one Sandbox) and `proof` |
| [bot/src/bot.ts](bot/src/bot.ts) | The bot — identity, presence, task lifecycle |
| [bot/src/roles.ts](bot/src/roles.ts) | Requester or worker: which powers this process has |
| [bot/src/offers.ts](bot/src/offers.ts) | Requester side: post an offer, follow what becomes of it |
| [bot/src/prime.ts](bot/src/prime.ts) | Worker side: its one call into Modal, and the concurrency gate |
| [tools/verify-proof.mjs](tools/verify-proof.mjs) | Checks a task's proof against Modal's keys, no account needed |

**Two Fly bots, one Modal app.** `#tasks` holds a *requester* (people ask it
for work; it posts open offers and reports back) and a *worker* (it claims
offers, runs them, answers with a proof link). Only the worker holds a Modal
token, and it takes no orders from the channel — work it pays for is work the
channel watched being asked for. See [bot/README.md](bot/README.md).

Two *workers* would be the mistake the earlier arrangement made: channel
membership is the socket, so a second claimant races for every offer under a
second DID. The Modal app has no freeq code in it at all — it cannot join, only
compute.

## Setup

```bash
modal secret create cloudflare-ai CLOUDFLARE_API_KEY=... CLOUDFLARE_ACCOUNT_ID=...
```

The bot's own config (`FREEQ_OWNER_DID`, `FREEQ_CHANNELS`, and the Modal token
it dispatches with) lives on Fly — see [bot/README.md](bot/README.md).

Both Cloudflare values are needed: Prime Agent's `cloudflare-workers-ai`
provider authenticates with `CLOUDFLARE_API_KEY` and substitutes
`CLOUDFLARE_ACCOUNT_ID` into its base URL
(`https://api.cloudflare.com/client/v4/accounts/{CLOUDFLARE_ACCOUNT_ID}/ai/v1`).
The API token needs Workers AI read access.

That secret is injected into each **Sandbox** and read nowhere else — neither
the dispatch Function nor the bot has any use for a model key.

## Run it

Smoke-test the sandbox path with no freeq involved (this is also what warms the
image build, which takes a few minutes the first time):

```bash
modal run modal_app.py --prompt "What is a did:key, in two sentences?"
```

Then deploy the dispatch side. There is nothing to start afterwards: `run_task`
is called on demand by the bot, so a deploy is the whole story here.

```bash
modal deploy modal_app.py
```

One catch, learned the hard way: a warm container from the previous version
keeps serving calls, and `scaledown_window` holds one for ten minutes. A
deploy that changes `run_task`'s signature therefore looks like it did nothing
— the bot's calls keep hitting the old code and failing the same way. Cycle it:

```bash
modal container list
modal container stop -y <container-id>
```

The bot is deployed separately, to Fly — see [bot/README.md](bot/README.md).
Hand it work by posting an open `handoff` offer with `caps=prime_agent` from
any freeq client, or by addressing it in the channel: `@prime-agent what does
act-caps mean?`

```bash
modal app logs prime-agent
```

## Tuning

Sandbox and model knobs are read from the environment in
[modal_app.py](modal_app.py) at deploy time; `MAX_CONCURRENT_TASKS` is read by
the bot at runtime.

| Variable | Default | What it does |
| --- | --- | --- |
| `PRIME_AGENT_MODEL` | `@cf/zai-org/glm-5.3-flash` | `@cf/zai-org/glm-5.3` is the full model: ~9x the input cost, text-only |
| `PRIME_AGENT_FALLBACK_MODEL` | `@cf/zai-org/glm-4.7-flash` | Used only after the primary model returns a capacity 429; set it to the primary model to disable fallback |
| `PRIME_AGENT_PROVIDER` | `cloudflare-workers-ai` | Prime Agent provider id |
| `PRIME_AGENT_THINKING` | unset | `off` … `max`; see the note below |
| `MODEL_SECRET_NAME` | `cloudflare-ai` | Modal secret attached to each Sandbox |
| `SANDBOX_TIMEOUT_S` | `900` | Hard ceiling on one task |
| `SANDBOX_CPU` / `SANDBOX_MEMORY_MIB` | `2` / `4096` | Sandbox size |
| `PRIME_AGENT_MAX_OUTPUT` | `32768` | Rewrites the max-output figure in Prime Agent's GLM catalog entries; see the note below |
| `MAX_CONCURRENT_TASKS` | `3` | Sandboxes in flight at once |
| `SANDBOX_EGRESS_ALLOWLIST` | unset (open) | Comma-separated domains the agent may reach; `api.cloudflare.com` is the minimum |

## Notes on the design

- **One connection, by construction.** The Modal app holds no freeq client, no
  DID and no bot kit, so there is nothing here to bring up alongside the Fly
  bot by accident. The worker that used to run here — reaching Sandbox
  creation over loopback — is deleted rather than left dormant behind an unset
  schedule.
- **The dispatch interface is one call wide.** The bot holds a Modal workspace
  token, which is a larger credential than the job needs; the mitigation is
  that `run_task(prompt, task_id)` is all it can name. Image, secrets, timeout,
  egress and teardown are decided here, out of the caller's reach, so a
  compromised bot can spend the account's money but cannot change what a
  Sandbox is allowed to do.
- **No thinking level by default.** The Cloudflare GLM catalog entries declare
  `reasoning: true` but carry no thinking-level map, unlike the direct z.ai
  ones — so `--thinking` is only passed when `PRIME_AGENT_THINKING` is set.
  Worth revisiting once you see how the model behaves.
- **Fresh agent per task, shared nothing.** `--no-session` plus a new Sandbox
  each time. Prime Agent's Continual Harness — the `/refine` loop, durable
  memories, learned skills — is therefore *not* in play: nothing survives the
  task. If you want that, the change is to mount a Volume at the Sandbox's
  `~/.prime` and drop `--no-session`; be aware one requester's refinements then
  shape everyone else's tasks.
- **Identity survives restarts.** The did:key seed and the
  `FreeqBotDelegation/v1` cert live on the Fly machine's persistent disk, so
  the network sees one continuous DID. Lose that disk and the bot returns as a
  stranger.
- **Backpressure over queueing.** At `MAX_CONCURRENT_TASKS` the bot declines to
  claim rather than claiming and queueing: an unclaimed offer stays open for
  another worker, a claimed one does not.
- **The Sandbox is always terminated**, including on failure — a leaked Sandbox
  bills until its timeout.
- **Task lifecycle.** `claim` → `progress` (sandbox id, as it starts) →
  `complete` (a digest in `act-ctx`, full answer to the channel) or `fail`.
  Presence flips `idle` → `executing` → `idle`, visible via WHOIS.

## Verified / not verified

Running, with the Fly bot dispatching and Sandboxes answering: offers claimed
from `#tasks`, tasks that call tools completing, and proofs published and
checked with [tools/verify-proof.mjs](tools/verify-proof.mjs).

What the first real runs cost, and what they taught:

- **`pi` budgets `max_tokens` from its catalog's max-output figure**, and the
  Cloudflare GLM entries list the whole context window there — so Workers AI
  rejected every call for exceeding the limit by the length of the prompt. The
  Sandbox image now rewrites that figure (`PRIME_AGENT_MAX_OUTPUT`) and fails
  the build if the catalog moved.
- **Not every Workers AI model can finish a tool-using task.** `pi` sends
  `content: null` on the assistant message carrying tool calls;
  `gpt-oss-120b` and `llama-3.3-70b` reject that shape with a bodyless 400 on
  the turn *after* the first tool result, while `glm-5.3-flash` accepts it. A
  model that answers a one-shot prompt is not yet a model that works here.
- **`-p` does not stop `pi` reading stdin**, and the pipe Modal hands an
  `exec` never reaches EOF — so the agent finished its work and then waited
  forever. It runs under `sh -c … </dev/null`.
- **A failed model call still exits 0** and still emits a well-formed event
  stream, with the reason in `errorMessage` on a message that has no content.
  Read it, or every provider-side fault looks like "no answer".
