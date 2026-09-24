#!/usr/bin/env node
/**
 * Post one open `handoff` offer with caps=prime_agent, then exit.
 *
 * The end-to-end test of the path the bot actually serves: an offer posted by
 * someone else, claimed from the channel, run, completed. `!run` skips that
 * whole mechanism — it dispatches straight to a Sandbox — so it cannot tell
 * you whether claiming works.
 *
 * This is a client, not a second bot: it posts as its own DID (delegated by
 * --owner), never claims anything, and disconnects when it's done. The one
 * long-lived freeq connection stays the bot's alone.
 *
 *   npm run offer -- --owner did:plc:<you> --title 'say hello'
 *   npm run offer -- --owner did:plc:<you> --title 'summarize this' \
 *     --ctx 'https://modal.com/docs/guide' --channel '#tasks'
 */

import { FreeqBot } from "@freeq/bot-kit";
import { actTags } from "@freeq/sdk";
import { parseArgs } from "node:util";

const { values } = parseArgs({
  options: {
    server: { type: "string", default: process.env.FREEQ_SERVER ?? "wss://irc.freeq.at/irc" },
    channel: { type: "string", default: "#tasks" },
    nick: { type: "string", default: "offer-firer" },
    caps: { type: "string", default: "prime_agent" },
    owner: { type: "string", default: process.env.FREEQ_OWNER_DID },
    title: { type: "string" },
    ctx: { type: "string", default: "" },
  },
  strict: true,
});

if (!values.owner || !values.title) {
  console.error(
    "Usage: npm run offer -- --owner did:plc:<you> --title '<task>'" +
      " [--ctx '<context>'] [--channel '#tasks'] [--caps prime_agent]",
  );
  process.exit(1);
}

const bot = await FreeqBot.create({
  name: "offer-firer",
  ownerDid: values.owner,
  nick: values.nick!,
  url: values.server!,
  channels: [values.channel!],
  // A human posting work, not an agent offering to do it — which is also what
  // keeps this out of the way of anything that claims offers.
  actorClass: "human",
});

await bot.start();

const taskId = await bot.client.sendAct(
  values.channel!,
  actTags("handoff", "offer", undefined, bot.identity.did, {
    title: values.title!,
    caps: values.caps!,
    ...(values.ctx ? { ctx: values.ctx } : {}),
  }),
);

console.error(`[fire-offer] posted ${taskId} on ${values.channel} — caps=${values.caps}`);
await bot.stop("offer fired");
process.exit(0);
