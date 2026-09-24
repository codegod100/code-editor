#!/usr/bin/env node
/**
 * The editor's dedicated FreeQ handoff worker.
 *
 * The browser editor posts a signed, open handoff offer. This process is the
 * long-lived counterpart: it claims only the configured capability, dispatches
 * it to the configured Modal task function, and publishes the lifecycle back
 * to the same channel. It deliberately accepts no IRC commands and never
 * creates offers, so the editor remains the sole requester.
 */

import { FreeqBot } from "@freeq/bot-kit";
import { actTags } from "@freeq/sdk";
import { handoffPrompt, verifyAgentGitExchange } from "./handoff.ts";
import { capacity, proofUrl, runTask } from "./prime.ts";

const CAPABILITY = required("FREEQ_CAPABILITY");
const ownerDid = required("FREEQ_OWNER_DID");
const nick = required("FREEQ_NICK");
const server = required("FREEQ_SERVER");
const channels = required("FREEQ_CHANNELS")
  .split(",")
  .map((channel) => channel.trim())
  .filter(Boolean);

if (channels.length === 0 || channels.some((channel) => !channel.startsWith("#"))) {
  throw new Error("FREEQ_CHANNELS must contain one or more channel names beginning with #");
}
if (!/^[a-z][a-z0-9_]{0,63}$/.test(CAPABILITY)) {
  throw new Error("FREEQ_CAPABILITY must be a lowercase identifier");
}
const channelCapabilities = channels.map(
  (channel) => JSON.stringify(channel) + " = [" + JSON.stringify(CAPABILITY) + "]",
);

function required(key: string): string {
  const value = process.env[key]?.trim();
  if (!value) throw new Error(key + " is required");
  return value;
}

const bot = await FreeqBot.create({
  name: nick,
  ownerDid,
  nick,
  url: server,
  ...(process.env.FREEQ_STATE_DIR ? { root: process.env.FREEQ_STATE_DIR } : {}),
  ...(process.env.FREEQ_CREATOR_KEY ? { creatorKeyPath: process.env.FREEQ_CREATOR_KEY } : {}),
  channels,
  actorClass: "agent",
  initialState: "idle",
  initialStatus: "editor handoff worker · caps=" + CAPABILITY,
  manifest: [
    "[agent]",
    'actor_class = "agent"',
    'display_name = "Code Editor Prime Worker"',
    'description = "Claims Code Editor FreeQ handoffs and dispatches them to the configured task runner."',
    'source_repo = "https://github.com/codegod100/code-editor"',
    'version = "0.1.0"',
    "",
    "[provenance]",
    'origin_type = "custom"',
    "creator_did = " + JSON.stringify(ownerDid),
    "revocation_authority = " + JSON.stringify(ownerDid),
    'authority_basis = "Operated by the Code Editor owner"',
    "",
    "[capabilities]",
    "default = [" + JSON.stringify(CAPABILITY) + "]",
    "",
    "[capabilities.channels]",
    ...channelCapabilities,
    "",
    "[presence]",
    "heartbeat_interval_seconds = 30",
  ].join("\n"),
});

bot.on("channelJoined", (channel) => console.error("[worker] joined " + channel));
bot.on("connectionStateChanged", (state) => console.error("[worker] transport " + state));
bot.on("authError", (error) => {
  console.error("[worker] authentication failed:", error);
  process.exit(1);
});

const maxOfferAgeMs = integerEnv("MAX_OFFER_AGE_MS", 120_000);
const claimed = new Set<string>();
let providerProbeRunning = false;

function integerEnv(key: string, fallback: number): number {
  const raw = process.env[key];
  if (raw === undefined) return fallback;
  const value = Number(raw);
  if (!Number.isInteger(value) || value <= 0) {
    throw new Error(key + " must be a positive integer");
  }
  return value;
}

function stale(timestamp: string | undefined): boolean {
  if (!timestamp) return false;
  const parsed = Date.parse(timestamp);
  return Number.isFinite(parsed) && Date.now() - parsed > maxOfferAgeMs;
}

async function publish(
  channel: string,
  verb: "claim" | "progress" | "complete" | "fail",
  taskId: string,
  fields: Record<string, string>,
): Promise<void> {
  await bot.client.sendAct(
    channel,
    actTags("handoff", verb, taskId, bot.identity.did, fields),
    { taskId },
  );
}

bot.on("actEvent", async (event) => {
  if (event.kind !== "handoff" || event.verb !== "offer") return;
  if (stale(event.tags?.time)) return;
  if (claimed.has(event.taskId)) return;
  if (event.fields["act-to"] || event.did === bot.identity.did) return;
  if (event.fields["act-caps"] !== CAPABILITY) return;

  const title = event.fields["act-title"]?.trim() ?? "";
  const prompt = handoffPrompt(event.fields);
  if (!prompt) {
    console.error("[worker] ignored " + event.taskId + ": no title or context");
    return;
  }
  if (capacity.full) {
    console.error("[worker] passed on " + event.taskId + ": at capacity");
    return;
  }

  claimed.add(event.taskId);
  capacity.acquire();
  bot.setState("executing", title.slice(0, 80));
  console.error("[worker] claimed " + event.taskId);

  try {
    await publish(event.channel, "claim", event.taskId, { note: "dispatching to the editor task runner" });
    const result = await runTask(prompt, {
      taskId: event.taskId,
      onProgress: (note) =>
        void publish(event.channel, "progress", event.taskId, { note: note.slice(0, 200) }).catch(
          (error) => console.error("[worker] could not publish progress:", error),
        ),
    });
    if (result.exitCode !== 0) {
      throw new Error("editor task runner exited with code " + result.exitCode);
    }
    if (!result.text) {
      throw new Error("editor task runner returned no completion report");
    }
    const agentGitUrl = event.fields["act-agentgit-url"]?.trim();
    if (agentGitUrl) await verifyAgentGitExchange(agentGitUrl);
    await publish(event.channel, "complete", event.taskId, {
      note: Math.round(result.elapsedMs / 1000) + "s in " + result.sandboxId,
      ctx: result.text.slice(0, 400),
    });
    console.error("[worker] completed " + event.taskId + " — " + proofUrl(event.taskId));
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    await publish(event.channel, "fail", event.taskId, { note: message.slice(0, 400) });
    console.error("[worker] failed " + event.taskId + ":", error);
  } finally {
    capacity.release();
    if (capacity.inFlight === 0) bot.setState("idle");
  }
});

/**
 * An operator sends SIGUSR1 through Fly SSH to test the exact provider path
 * without starting a second Node process on this 256 MiB worker.
 */
process.on("SIGUSR1", () => {
  if (providerProbeRunning) {
    console.error("[healthcheck] ignored: provider probe already running");
    return;
  }
  if (capacity.full) {
    console.error("[healthcheck] unavailable: worker is at task capacity");
    return;
  }

  providerProbeRunning = true;
  capacity.acquire();
  console.error("[healthcheck] started");
  void runTask("Reply with exactly: health check ok", {
    onProgress: (note) => console.error("[healthcheck] " + note),
  })
    .then((result) => {
      if (!result.text) throw new Error("prime-agent completed without an answer");
      console.error(
        "[healthcheck] provider-accepted-request " +
          JSON.stringify({ sandboxId: result.sandboxId, elapsedMs: result.elapsedMs, answer: result.text }),
      );
    })
    .catch((error: unknown) => {
      const message = error instanceof Error ? error.message : String(error);
      const status = /\b429\b|rate.?limit|too many requests/i.test(message)
        ? "provider-rate-limited"
        : "task-dispatch-failed";
      console.error("[healthcheck] " + status + " " + message);
    })
    .finally(() => {
      capacity.release();
      providerProbeRunning = false;
    });
});

await bot.start();
console.error(
  "[worker] ready as " + bot.client.nick + " (" + bot.identity.did + ") — caps=" +
    CAPABILITY + " on " + channels.join(", "),
);

const shutdown = (signal: string) =>
  bot.stop(signal).then(() => process.exit(0), () => process.exit(1));
process.once("SIGINT", () => shutdown("SIGINT"));
process.once("SIGTERM", () => shutdown("SIGTERM"));
