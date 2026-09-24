# Code Editor FreeQ worker

This is the always-on Fly.io counterpart to the editor's FreeQ handoff
button. It is intentionally a worker, not a chat bot:

- The editor posts signed open offers to #tasks.
- This worker claims only offers whose capability exactly matches
  FREEQ_CAPABILITY (currently prime_agent).
- It calls the explicitly configured Modal task function and publishes claim,
  progress, completion, or failure acts to the same channel.
- It accepts no IRC commands and never posts offers, keeping request creation
  and paid task execution separate.

The worker has no HTTP service. It keeps one outbound WebSocket open and must
remain running, so Fly must not autostop it.

On every connection it publishes a signed FreeQ agent manifest. The editor
discovers the manifest from FreeQ's public agent feed, so the capability offered
in its handoff dialog is the same capability this worker actually claims.

## Configuration

Copy .env.example for local use. Every operational value is required; startup
fails clearly if one is absent or invalid. The worker's Modal credentials are
MODAL_TOKEN_ID and MODAL_TOKEN_SECRET and belong only in Fly secrets, never in
this repository or an environment file.

The did:key seed is stored below FREEQ_STATE_DIR. On Fly, the state volume is
mounted at /data. That volume is the worker's identity and must survive every
deployment. Back it up through Fly's volume backup process before replacing or
destroying the machine.

## Deploy

The production app remains named freeq-bot to retain its existing identity and
volume. From this directory:

~~~sh
fly secrets set FREEQ_OWNER_DID=did:plc:... MODAL_TOKEN_ID=... MODAL_TOKEN_SECRET=...
fly deploy
~~~

The config declares one immediate-update machine and mounts volume state at
/data. Do not scale beyond one machine: two workers would share the same nick,
and the volume allows only one writer.

## Verify

~~~sh
npm ci
npm run typecheck
fly logs
~~~

After startup, logs must include a joined #tasks line and a ready line naming
caps=prime_agent. An editor handoff with any other capability is deliberately
left unclaimed.

## Provider probe

After deploying this version, distinguish a transient provider rejection from a
persistent one by signaling the deployed worker:

~~~sh
fly ssh console -a freeq-bot -C "kill -USR1 \$(pgrep -f '^/usr/local/bin/node .*src/bot.ts$')"
fly logs -a freeq-bot --no-tail
~~~

It calls the same configured Modal `run_task` function as a handoff with a
minimal deterministic prompt. A successful result has
`[healthcheck] provider-accepted-request`; a 429 has
`[healthcheck] provider-rate-limited`. This is a real agent request and may
incur the normal task cost, so it is intentionally not a scheduled health
check. The probe runs in the existing worker process; do not launch a second
Node process on this 256 MiB machine.
