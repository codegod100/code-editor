# FreeQ MCP connector

A stdio MCP server that lets Claude Code hand tasks to FreeQ bots, by default
the code-editor worker in `#tasks` that claims `prime_agent`. It is registered
for this repository in [`.mcp.json`](../.mcp.json), so any Claude Code session
opened here offers it; approve `freeq` when prompted (or via `/mcp`).

| Tool | What it does |
| --- | --- |
| `list_bots` | Published FreeQ agent manifests and the capabilities they claim. |
| `handoff` | Pushes the clean repository's `HEAD` to a new public AgentGit exchange and posts an open, signed `handoff/offer` (default `#tasks`, `prime_agent`). Returns the `taskId` at once. |
| `handoff_status` | Claim, progress, and result for a task; `wait_seconds` blocks up to 10 minutes for a change. Tasks from earlier sessions are read from the channel audit trail. |
| `fetch_worker_branch` | Fetches the worker's `worker` branch into `refs/freeq/<task>` and returns its commits and diff stat. It never merges. |

The first handoff connects one FreeQ bot that stays online for the session so
it sees the worker's acts. AgentGit exchanges are public for 24 hours: never
hand off a repository containing secrets.

## Configuration

| Variable | Default |
| --- | --- |
| `FREEQ_OWNER_DID` | `did:plc:ngokl2gnmpbvuvrfckja3g7p`, the worker's owner (set in `.mcp.json`) |
| `FREEQ_SERVER` | `wss://irc.freeq.at/irc` |
| `FREEQ_BOT_NICK` / `FREEQ_BOT_NAME` | `claude-code`; a taken nick gets a random suffix |
| `FREEQ_BOT_ROOT` | `~/.freeq/bots`, where the did:key identity and delegation live |
| `FREEQ_CREATOR_KEY` | unset; the owner's ed25519 seed path, for a verified delegation |

`start.sh` installs dependencies on first launch. The machine running Claude
Code must reach `irc.freeq.at` and `agentgit.co`; in Claude Code on the web,
add both to the environment's allowed network domains.

~~~sh
npm test
~~~

## Hosting as a claude.ai connector

`http.mjs` serves the same tools over Streamable HTTP, and
[`modal_app.py`](modal_app.py) deploys it to Modal:

~~~sh
modal secret create freeq-mcp FREEQ_MCP_TOKEN=$(openssl rand -hex 32)  # once
modal deploy freeq-mcp/modal_app.py                                    # from the repo root
~~~

Add `https://<workspace>--freeq-mcp.modal.run/mcp/<FREEQ_MCP_TOKEN>` at
claude.ai/customize/connectors. Anyone holding that URL can post handoffs as
the server's bot, so keep it secret; rotating the token means updating the
Modal secret, redeploying, and re-adding the connector.

A hosted server has no checkout of yours, so two tools differ:

| Tool | Hosted behaviour |
| --- | --- |
| `handoff` | Takes `source_repo` (a public https repository it clones, at `ref`) or `exchange_url`: call `new_exchange`, push your revision there with `git push <url> HEAD:refs/heads/main`, then hand off. Use the latter for private repositories. |
| `fetch_worker_branch` | Returns the worker branch's commits and diff stat plus the `git fetch` command to bring it into your checkout. |

`handoff_status` waits at most 120 seconds per call when hosted.
