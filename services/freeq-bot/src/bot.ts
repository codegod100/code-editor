#!/usr/bin/env node
/**
 * A small freeq bot: connects, joins channels, answers when addressed.
 *
 * It is one long-lived WebSocket and a command table (see commands.ts) — no
 * database, no HTTP server, no inbound ports. That is the whole point: it runs
 * happily on the cheapest VPS you can rent, under systemd or Docker.
 *
 * Two of these run in #tasks, and FREEQ_ROLE says which one this is: the
 * `requester` takes asks from people and posts offers, the `worker` claims
 * offers and runs them in a Modal Sandbox. See roles.ts for why the powers are
 * split rather than combined.
 *
 * Config comes from the environment (see .env.example):
 *   FREEQ_ROLE          'worker' (default) or 'requester'
 *   FREEQ_OWNER_DID     required — DID the bot acts on behalf of
 *   FREEQ_NICK          default per role: 'freeq-bot' / 'task-desk'
 *   FREEQ_SERVER        default wss://irc.freeq.at/irc
 *   FREEQ_CHANNELS      comma-separated, default '#tasks'
 *   FREEQ_STATE_DIR     default '~/.freeq/bots' — holds the bot's did:key seed
 *   FREEQ_CREATOR_KEY   optional — owner's ed25519 seed, signs the delegation
 */

import { FreeqBot } from "@freeq/bot-kit";
import { actTags } from "@freeq/sdk";
import { commands, type CommandContext } from "./commands.ts";
import { OfferBook } from "./offers.ts";
import { capacity, proofUrl, runTask } from "./prime.ts";
import { defaultNick, isRequester, isWorker, role } from "./roles.ts";
/** The capability we answer offers for. An offer asking for anything else is
 *  someone else's job. */
const CAPABILITY = process.env.FREEQ_CAPABILITY ?? "prime_agent";
/** IRC is a chat line, not a transcript: keep replies short enough to read. */
const MAX_REPLY = 1000;

/** IRC is a chat line, not a transcript. */
const clamp = (text: string) => (text.length > MAX_REPLY ? `${text.slice(0, MAX_REPLY)}…` : text);

function env(key: string, fallback?: string): string {
  const value = process.env[key] ?? fallback;
  if (value === undefined) {
    console.error(`[bot] missing required env ${key}`);
    process.exit(1);
  }
  return value;
}

const ownerDid = env("FREEQ_OWNER_DID");
const nick = env("FREEQ_NICK", defaultNick);
const channels = env("FREEQ_CHANNELS", "#tasks")
  .split(",")
  .map((c) => c.trim())
  .filter(Boolean);

const bot = await FreeqBot.create({
  name: nick,
  ownerDid,
  nick,
  url: env("FREEQ_SERVER", "wss://irc.freeq.at/irc"),
  ...(process.env.FREEQ_STATE_DIR ? { root: process.env.FREEQ_STATE_DIR } : {}),
  ...(process.env.FREEQ_CREATOR_KEY ? { creatorKeyPath: process.env.FREEQ_CREATOR_KEY } : {}),
  channels,
  actorClass: "agent",
  initialState: "idle",
  initialStatus: isWorker
    ? `worker · caps=${CAPABILITY} · claims offers`
    : `requester · ${Object.keys(commands).join(" ")}`,
  // Every command is an explicit address, so the mention cooldown would only
  // get in the way of someone typing two of them.
  mention: { cooldownMs: 0, matcher: matchAddress },
});

// Joining a channel replays its recent history through 'message'. Without a
// guard the bot would answer every command it missed while it was down, every
// time it restarts — and again on every reconnect, since a rejoin replays too.
//
// The replay lands in a burst right after the JOIN, so each channel only
// distrusts old timestamps for a few seconds after joining. Comparing against
// the clock forever would be worse than useless: a server clock running behind
// ours would silently drop *live* messages and the bot would go deaf with no
// sign of why. This way a skewed clock costs at most one burst.
const REPLAY_WINDOW_MS = 10_000;
const processStartedAt = Date.now();
const joinedAt = new Map<string, number>();

bot.on("channelJoined", (channel) => {
  joinedAt.set(channel, Date.now());
  // Proof of actual membership. The startup line only reports what we *asked*
  // to join, which is not the same thing — a channel can refuse us.
  console.error(`[bot] joined ${channel}`);
});

function isReplay(channel: string, msg: { timestamp: Date }): boolean {
  // DMs arrive without a JOIN; the process start is the best anchor we have.
  const anchor = joinedAt.get(channel) ?? processStartedAt;
  if (Date.now() > anchor + REPLAY_WINDOW_MS) return false;
  return msg.timestamp.getTime() < anchor;
}

/**
 * Decide whether a channel line is addressed to us, and strip the address off.
 *
 * bot-kit's default matcher handles `@nick` and `nick:`/`nick,`, but two shapes
 * people actually type fall through it. `@nick: cmd` — the @ and the colon
 * together, which is what several clients autocomplete to — strips only the
 * `@nick`, leaving a stray colon where the command should be. And a bare
 * `nick cmd` doesn't match at all: the default deliberately ignores it so that
 * talking *about* a bot in the third person doesn't summon it.
 *
 * That last concern doesn't apply here. We only ever act on a word that is
 * already in the command table, so "freeq-bot wrote that" is ignored on the
 * command lookup regardless. Accepting the bare form costs nothing and is what
 * someone typing at a bot expects.
 */
function matchAddress(text: string, nick: string): string | null {
  const n = nick.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  // `@nick` anywhere in the line; a bare `nick` only at the start, where it
  // reads as address rather than reference. Either may carry a `:` or `,`.
  // `\\b` is too loose for a nick end: it treats the hyphen in `freeq-bot-2`
  // as a boundary, so a sibling bot's name would match ours.
  const end = "(?![\\w-])";
  for (const re of [
    new RegExp(`(?:^|\\s)@${n}${end}[:,]?\\s*`, "i"),
    new RegExp(`^\\s*${n}${end}[:,]?\\s*`, "i"),
  ]) {
    if (re.test(text)) return text.replace(re, " ").replace(/\s+/g, " ").trim();
  }
  return null;
}

/**
 * Pull a command out of a line, or return null.
 *
 * Commands must be addressed: `@bot ping` (or `bot: ping`, or `bot ping`) in a
 * channel, or a bare `ping` in a DM, where there is nobody else to be talking
 * to. There is no channel-wide prefix on purpose — two of these bots read the
 * same channel, and an unaddressed `!ping` belongs to both of them, so both
 * would answer it. Addressing also means neither one has to guess whether a
 * line was meant for it.
 */
function parse(text: string, channel: string): { name: string; args: string } | null {
  let line = text.trim();
  if (channel.startsWith("#")) {
    const mention = bot.checkMention(channel, line);
    if (mention.kind !== "respond") return null;
    line = mention.stripped.trim();
  }
  if (!line) return null;
  const [name, ...rest] = line.split(/\s+/);
  return { name: name.toLowerCase(), args: rest.join(" ").trim() };
}

// ── The requester's book of posted tasks ─────────────────────────────────
// Only built for the requester role; the worker never posts an offer, so it
// has nothing to follow.
const offers = isRequester
  ? new OfferBook((target, text) => bot.client.sendMessage(target, clamp(text)))
  : null;

/**
 * Post an open offer, and start following it.
 *
 * `act-to` is deliberately absent: the offer goes to the channel, not to a
 * named worker. Anyone with the capability may take it, which is the property
 * that makes the worker's refusal to accept typed orders safe — work it does
 * is work the channel watched being asked for.
 */
async function postOffer(
  channel: string,
  from: string,
  title: string,
  ctx?: string,
  reportTo?: string,
): Promise<string> {
  const taskId = await bot.client.sendAct(
    channel,
    actTags("handoff", "offer", undefined, bot.identity.did, {
      title,
      caps: CAPABILITY,
      ...(ctx ? { ctx } : {}),
    }),
  );
  // The offer has to go to a channel — there is nobody in a DM to claim it —
  // but the report goes wherever it was asked for.
  offers?.track({ taskId, target: reportTo ?? channel, from, title });
  console.error(`[offer] posted ${taskId} on ${channel} — caps=${CAPABILITY}`);
  return taskId;
}

/** Set FREEQ_DEBUG=1 to log every inbound line and why it was or wasn't acted on. */
const debug = process.env.FREEQ_DEBUG === "1";

bot.on("message", async (channel, msg) => {
  if (debug) {
    console.error(
      `[bot] rx ${channel} <${msg.from}> ${JSON.stringify(msg.text)}` +
        ` self=${!!msg.isSelf} system=${!!msg.isSystem} replay=${isReplay(channel, msg)}`,
    );
  }
  if (msg.isSelf || msg.isSystem) return;
  if (isReplay(channel, msg)) return;

  const parsed = parse(msg.text, channel);
  if (debug) console.error(`[bot] parsed ${JSON.stringify(parsed)}`);
  if (!parsed) return;
  const command = commands[parsed.name];
  // Getting here means we were addressed — `!`-prefixed, @-mentioned, or in a
  // DM. Silence would read as broken, and this bot has no chat to fall back
  // on, so say what it does know.
  if (!command) {
    bot.client.sendMessage(
      channel.startsWith("#") ? channel : msg.from,
      `no such command: ${parsed.name} — try ${Object.keys(commands).join(" ")}`,
    );
    return;
  }

  // DMs arrive with the sender's nick where a channel name would be.
  const target = channel.startsWith("#") ? channel : msg.from;
  const senderDid = await bot.resolveSenderDid(msg);
  if (command.ownerOnly && senderDid !== ownerDid) {
    bot.client.sendMessage(target, `${parsed.name} is owner-only`);
    return;
  }

  const ctx: CommandContext = {
    args: parsed.args,
    from: msg.from,
    target,
    senderDid,
    isOwner: senderDid === ownerDid,
    say: (text) => bot.client.sendMessage(target, clamp(text)),
    pendingCount: offers?.size ?? 0,
    // Asked in a channel, the offer goes there. Asked in a DM, it goes to the
    // first channel we joined — an offer nobody can see is an offer nobody can
    // claim — and the reports come back to the DM.
    ...(isRequester
      ? {
          postOffer: (title: string, offerCtx?: string) =>
            channel.startsWith("#")
              ? postOffer(channel, msg.from, title, offerCtx)
              : postOffer(channels[0], msg.from, title, offerCtx, msg.from),
        }
      : {}),
  };

  bot.setState("executing", parsed.name);
  try {
    const reply = await command.run(ctx);
    if (reply) bot.client.sendMessage(target, clamp(reply));
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    bot.client.sendMessage(target, `${parsed.name} failed: ${message.slice(0, 200)}`);
    console.error(`[bot] ${parsed.name} failed:`, err);
  } finally {
    bot.setState("idle");
  }
});

// The SDK reconnects on its own and bot-kit re-runs the announce sequence; log
// the transitions so a flapping link is visible in `journalctl`.
bot.on("connectionStateChanged", (state) => console.error(`[bot] transport ${state}`));
bot.on("authError", (error) => {
  console.error(`[bot] auth failed: ${error}`);
  process.exit(1);
});

/** An offer older than this is history, not work. */
const MAX_OFFER_AGE_MS = Number(process.env.MAX_OFFER_AGE_MS ?? 120_000);
const claimed = new Set<string>();

/** True when the act's server timestamp is too old to act on. Unparseable or
 *  missing times fail open — better to consider a live offer than to go deaf
 *  if the server stops stamping them — which is what `claimed` guards. */
function isStale(time: string | undefined): boolean {
  if (!time) return false;
  const at = Date.parse(time);
  return Number.isFinite(at) && Date.now() - at > MAX_OFFER_AGE_MS;
}

// ── Acts ─────────────────────────────────────────────────────────────────
// Both roles listen, for opposite reasons. The worker is looking for offers to
// claim; the requester is following the tasks it posted, and claims nothing.
bot.on("actEvent", async (event) => {
  // Acts are rare and every skip below is silent, so one line per act is the
  // difference between "the bot ignored my offer" and knowing why.
  console.error(
    `[act] ${event.kind}/${event.verb} task=${event.taskId} replayed=${event.replayed}` +
      ` from=${event.from} time=${event.tags?.time ?? "-"} fields=${JSON.stringify(event.fields)}`,
  );
  if (isRequester) {
    // Its own task or nobody's business. No claiming, ever: this process holds
    // no Modal token and creating work it then served itself would collapse
    // the split the two roles exist for.
    offers?.handle(event);
    return;
  }

  if (event.kind !== "handoff" || event.verb !== "offer") return;
  // History replays through this handler too — every rejoin re-reads the
  // channel — and claiming an offer that is hours dead, already served, or
  // whose asker has left helps nobody.
  //
  // `event.replayed` is the obvious guard and it does not work here: this
  // server stamps a `time` tag on live lines as well, which is what the SDK
  // reads, so everything arrives marked replayed. Age is the honest test.
  if (isStale(event.tags?.time)) return;
  // Belt and braces: a reconnect can redeliver an offer still inside the
  // window, and claiming the same task twice is worse than missing it.
  if (claimed.has(event.taskId)) return;
  if (event.fields["act-to"]) return; // addressed to a specific worker
  if (event.did === bot.identity.did) return; // our own offer
  if (event.fields["act-caps"] !== CAPABILITY) return;

  const send = (verb: string, fields: Record<string, string>) =>
    bot.client.sendAct(
      event.channel,
      actTags("handoff", verb, event.taskId, bot.identity.did, fields),
      { taskId: event.taskId },
    );

  const title = event.fields["act-title"] ?? "";
  const prompt = [title, event.fields["act-ctx"] ?? ""].filter(Boolean).join("\n\n");
  if (!prompt) {
    console.error(`[offer] ignoring ${event.taskId}: no title or context`);
    return;
  }

  // Refuse by staying quiet rather than claiming: an unclaimed offer stays open
  // for another worker, but one we claim and then queue helps nobody.
  if (capacity.full) {
    console.error(`[offer] passing on ${event.taskId}: ${capacity.inFlight} sandboxes running`);
    return;
  }

  // First valid claim wins; the task's home server orders competing claims.
  claimed.add(event.taskId);
  await send("claim", { note: "dispatching to a sandbox" });
  capacity.acquire();
  bot.setState("executing", title.slice(0, 80) || "thinking");
  console.error(`[offer] claimed ${event.taskId}`);

  try {
    const result = await runTask(prompt, {
      taskId: event.taskId,
      // Progress is part of the act lifecycle, and it tells an observer the
      // task is alive through a run that takes minutes.
      onProgress: (note) => void send("progress", { note: note.slice(0, 200) }).catch(() => {}),
    });
    await send("complete", {
      note: `${Math.round(result.elapsedMs / 1000)}s in ${result.sandboxId}`.slice(0, 400),
      // act-ctx is a tag, so it carries a digest; the answer goes to the channel.
      ctx: result.text.slice(0, 400),
    });
    bot.client.sendMessage(event.channel, clamp(result.text));
    // The claim and the evidence travel together, or nobody checks it.
    bot.client.sendMessage(event.channel, `proof: ${proofUrl(event.taskId)}`);
    console.error(`[offer] completed ${event.taskId} in ${result.elapsedMs}ms`);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    await send("fail", { note: message.slice(0, 400) });
    console.error(`[offer] failed ${event.taskId}: ${message}`);
  } finally {
    capacity.release();
    if (capacity.inFlight === 0) bot.setState("idle");
  }
});

await bot.start();
console.error(
  `[bot] up as ${bot.client.nick} (${bot.identity.did}) — caps=${CAPABILITY} on ${channels.join(", ")}`,
);

const shutdown = (signal: string) =>
  bot.stop(signal).then(() => process.exit(0), () => process.exit(1));
process.once("SIGINT", () => shutdown("SIGINT"));
process.once("SIGTERM", () => shutdown("SIGTERM"));
