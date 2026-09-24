# Handoff — deploy this bot

**Historical. Superseded: this was written before the bot ran, and before the
freeq side moved to Fly.** `README.md` describes what actually runs. Kept for
the reasoning in "Two things not to fix", which still holds.

The instruction that has since become actively wrong is step 2 below: there is
no Modal-side bot to start any more, and starting a second freeq connection
alongside the Fly one makes two claimants for every offer.

## Blocked on two secrets

Only you can create these — they hold your credentials:

```bash
modal secret create cloudflare-ai CLOUDFLARE_API_KEY=... CLOUDFLARE_ACCOUNT_ID=...
```

```bash
modal secret create freeq-bot FREEQ_OWNER_DID=did:plc:ngokl2gnmpbvuvrfckja3g7p FREEQ_CHANNELS='#tasks'
```

That DID is `nandi.uk`, resolved via AT Protocol. Confirm with `modal secret list`.

## Then

1. Smoke-test with no freeq involved — also warms the Sandbox image build, which
   takes several minutes the first time:
   `modal run modal_app.py --prompt "What is a did:key, in two sentences?"`
2. ~~`modal run --detach modal_app.py::harness`~~ — gone. `modal deploy
   modal_app.py` is the whole Modal step; `run_task` is called on demand.
3. The bot itself deploys to Fly: see `bot/README.md`. Confirm it is *live on
   the network*, not merely deployed — `modal app logs prime-agent` shows
   dispatches, and freeq whois shows the nick.

## Likely first failures

- Prime Agent's first `ipython` call pulls a managed CPython via uv. The image
  bakes in uv, not the interpreter.
- The exact JSON `message_end` shape that `_parse_events` in `modal_app.py` reads
  for the final answer. Unit-checked against a synthetic stream only.
- Whether GLM 5.3 Flash can drive Prime Agent's tool loop. If it stalls or loops,
  `PRIME_AGENT_MODEL=@cf/zai-org/glm-5.3` is the full model.

## Two things not to "fix"

- **Sandbox creation is in Python on purpose.** A Modal container authenticates
  to Modal as itself (`CLIENT_TYPE_CONTAINER`, no token); the Modal JS SDK has no
  container mode and would need a full-rights workspace token in a process that
  takes jobs from the network. The Python/Node loopback seam exists to avoid that.
- **Access is open on purpose.** Asked directly, the owner chose no authorization
  gating: any DID that can post to `#tasks` gets arbitrary code execution in a
  Sandbox on their account. Budget caps and `MAX_CONCURRENT_TASKS` are the only
  limits. If gating is wanted later: `bot.resolveSenderDid()` plus a DID allowlist
  via `createDidMap`, as in upstream `freeq-bot-kit-js/examples/gated-bot.ts`.
