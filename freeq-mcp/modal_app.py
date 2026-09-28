"""Host the FreeQ MCP connector on Modal, for use as a claude.ai custom connector.

One-time setup (the token is the secret part of the connector URL)::

    modal secret create freeq-mcp FREEQ_MCP_TOKEN=$(openssl rand -hex 32)

Deploy from the repository root::

    modal deploy freeq-mcp/modal_app.py

The connector URL is ``https://<workspace>--freeq-mcp.modal.run/mcp/<FREEQ_MCP_TOKEN>``.
"""

from pathlib import Path

import modal

HERE = Path(__file__).resolve().parent
REPOSITORY_ROOT = HERE.parent
PORT = 8000

app = modal.App("freeq-mcp")
# The bot's did:key identity and delegation, so restarts keep the same identity.
bots = modal.Volume.from_name("freeq-mcp-bots", create_if_missing=True)
secret = modal.Secret.from_name("freeq-mcp", required_keys=["FREEQ_MCP_TOKEN"])

image = (
    modal.Image.debian_slim(python_version="3.12")
    .apt_install("ca-certificates", "curl", "git")
    .run_commands(
        "curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && apt-get install -y nodejs",
    )
    .env(
        {
            "PORT": str(PORT),
            "FREEQ_OWNER_DID": "did:plc:ngokl2gnmpbvuvrfckja3g7p",
            "FREEQ_SERVER": "wss://irc.freeq.at/irc",
            "FREEQ_BOT_ROOT": "/data/bots",
        }
    )
    # Install dependencies in their own layer so source edits don't reinstall them.
    .add_local_file(HERE / "package.json", "/app/freeq-mcp/package.json", copy=True)
    .add_local_file(HERE / "package-lock.json", "/app/freeq-mcp/package-lock.json", copy=True)
    .run_commands("npm ci --prefix /app/freeq-mcp --omit=dev --no-audit --no-fund")
    .add_local_dir(HERE, "/app/freeq-mcp", ignore=["node_modules", "*.test.mjs", "*.py"])
    # The connector shares these dependency-free modules with the editor's handoff.
    .add_local_file(
        REPOSITORY_ROOT / "freeq-handoff/channel-ready.mjs",
        "/app/freeq-handoff/channel-ready.mjs",
    )
    .add_local_file(
        REPOSITORY_ROOT / "freeq-handoff/offer-fields.mjs",
        "/app/freeq-handoff/offer-fields.mjs",
    )
)


@app.function(
    image=image,
    secrets=[secret],
    volumes={"/data": bots},
    # One process owns the FreeQ bot and the in-memory handoff registry.
    # Handoffs it no longer tracks are read back from the channel audit trail.
    max_containers=1,
    scaledown_window=20 * 60,
)
@modal.concurrent(max_inputs=100)
@modal.web_server(PORT, startup_timeout=60, label="freeq-mcp")
def serve():
    import subprocess

    subprocess.Popen(["node", "/app/freeq-mcp/http.mjs"])
