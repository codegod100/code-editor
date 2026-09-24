# freeq-bot

A small TypeScript freeq client built on [`@freeq/bot-kit`](https://github.com/freeq-irc/freeq/tree/main/freeq-bot-kit-js).
It connects, joins channels, and answers when addressed. That's all it is: one
outbound WebSocket and a command table.

No inbound ports, no database, no build step. A 256MB always-on machine is
plenty — see [Hosting](#hosting).

## Two roles, two machines

One image runs as either half of a pair that shares `#tasks`, chosen by
`FREEQ_ROLE`:

| | `requester` (`task-desk`) | `worker` (`freeq-bot`) |
| --- | --- | --- |
| Takes asks from people | yes — `offer <task>` | only `run`, when addressed |
| Posts offers | yes | never |
| Claims offers | never | yes, `caps=prime_agent` |
| Modal credentials | **none** | `MODAL_TOKEN_ID` / `_SECRET` |
| Worst case if compromised | noise in a channel | your Modal bill |

They are two machines rather than two code paths because the credentials
differ. The worker takes no orders from the channel at all: it acts on offers
posted in the open, where everyone can see who asked for what. Anyone may ask;
only the worker can pay for it.

```
src/bot.ts        connection, config, dispatch, shutdown
src/roles.ts      which half this process is, and why the powers are split
src/commands.ts   what the bot actually does — the only file you need to edit
src/offers.ts     the requester's side: post an offer, follow what becomes of it
src/prime.ts      the worker's one call into Modal
src/fire-offer.ts post one offer and exit, for testing without a requester
```

## Run it locally

```bash
npm install
cp .env.example .env   # set FREEQ_OWNER_DID at minimum
set -a; . ./.env; set +a
npm start
```

First run writes a fresh `did:key` identity under `FREEQ_STATE_DIR` (default
`~/.freeq/bots/<nick>/`). **That seed is the bot's identity** — back it up, and
keep it on a persistent disk. Delete it and the bot comes back as a stranger.

Then, in any channel it joined:

```
@your-bot help
@your-bot offer say hello
task-desk: pending
```

**Every command must be addressed**: `@nick cmd`, `nick: cmd` or `nick cmd` in
a channel, or a bare `cmd` in a DM. There is no `!` prefix — two of these bots
read the same channel, so an unaddressed command belongs to both and both would
answer it.

The requester's `offer` splits its argument on `|`: the part before it is the
title the channel reads, the part after is context handed to the agent.

```
@task-desk offer summarize this | https://modal.com/docs/guide
```

## Adding a command

Add an entry to `shared` in [src/commands.ts](src/commands.ts) — or to
`workerOnly` / `requesterOnly` if it needs one role's powers. Return a
string to reply, `null` to stay silent; async is fine, and throwing is reported
to the caller rather than crashing the bot.

```ts
weather: {
  help: "weather <city>",
  run: async ({ args }) => {
    const r = await fetch(`https://wttr.in/${encodeURIComponent(args)}?format=3`);
    return r.text();
  },
},
```

Set `ownerOnly: true` to restrict a command to `FREEQ_OWNER_DID`. Sender
identity comes from the server (`bot.resolveSenderDid`), not from the nick, so
it can't be spoofed by renaming.

## Hosting

The bot holds one WebSocket open and never lets go. That single fact decides the
hosting: anything that scales to zero, sleeps on idle, or bills per request is
the wrong shape — it will drop the connection, and the bot is offline until
something wakes it.

**Fly.io** (recommended) — ~$2–3/month per always-on 256MB machine, and the
pair is two of them.

The worker, from [fly.toml](fly.toml):

```bash
fly launch --no-deploy --copy-config
fly volumes create state --size 1 --region ams
fly secrets set FREEQ_OWNER_DID=did:plc:xxxx \
  MODAL_TOKEN_ID=ak-xxxx MODAL_TOKEN_SECRET=as-xxxx
fly deploy
```

The requester, from [fly.requester.toml](fly.requester.toml) — same image, no
Modal token:

```bash
fly launch --no-deploy --copy-config -c fly.requester.toml
fly volumes create state --size 1 --region ams -a freeq-task-desk
fly secrets set FREEQ_OWNER_DID=did:plc:xxxx -a freeq-task-desk
fly deploy -c fly.requester.toml
```

Each app needs **its own volume**: the volume holds the did:key seed, so
sharing one would give both halves the same DID — and a worker that claims its
own offers is one bot wearing two hats, which is the thing the split exists to
prevent. Without a volume, every deploy mints a new identity.

Neither config has a `[[services]]` block, on purpose: the bot listens on no
port, so there is nothing for Fly's autostop machinery to attach to. Don't add
one. Logs: `fly logs`, `fly logs -a freeq-task-desk`.

**systemd** — for a box you already run, or when several bots share one host.
Copy the tree to `/opt/freeq-bot`, `npm ci --omit=dev`, put the environment in
`/etc/freeq-bot.env` (mode 0600), then:

```bash
sudo cp deploy/freeq-bot.service /etc/systemd/system/ && sudo systemctl enable --now freeq-bot
```

Restarts on failure, caps memory at 256M, keeps the identity seed in
`/var/lib/freeq-bot` (a `StateDirectory`, so it survives reinstalls).
Logs: `journalctl -u freeq-bot -f`.

**Docker** — `docker compose up -d`, with `.env` alongside the compose file. The
seed lives in the `state` volume; don't `down -v` it.

## Not verified

Written and typechecked, never connected to a live freeq server — it has not
registered a nick or spoken in a channel. The first run is the real test, and
the things most likely to be wrong are the parts only a server can exercise:
the DM reply target, and whether history replay lands inside the 10-second
post-JOIN window that `isReplay()` in `bot.ts` assumes.

The image has not been built and `fly deploy` has not been run — no Docker
daemon and no Fly account here. The entrypoint's volume `chown` and the
`[[restart]]` stanza are the parts of that path worth watching on first deploy.
