/**
 * The bot's command table — the only file you need to touch to give it
 * something to say. Each handler returns the reply text, or null to stay
 * silent.
 *
 * Every command is addressed: `@nick cmd` (or `nick: cmd`, or a bare `nick
 * cmd`) in a channel, or just `cmd` in a DM. There is no `!` prefix, and that
 * is deliberate now that two of these sit in one channel — an unaddressed
 * command has no addressee, so both would answer it and both would correct
 * your typos.
 *
 * The table depends on the role: only the requester can post offers, only the
 * worker can spend money running one. See roles.ts.
 *
 * Handlers may be async; whatever they return is sent to the channel or DM the
 * command came from. Throwing is fine too — bot.ts catches and reports it.
 */

export interface CommandContext {
  /** Everything after the command word, trimmed. */
  args: string;
  /** Nick that sent it. */
  from: string;
  /** Channel name, or the sender's nick for a DM. */
  target: string;
  /** Sender's DID, or null for guests and unresolvable senders. */
  senderDid: string | null;
  /** True when the sender is the DID in FREEQ_OWNER_DID. */
  isOwner: boolean;
  /** Send a line to wherever the command came from. For work that outlives the
   *  reply — dispatch now, answer in a few minutes. */
  say(text: string): void;
  /** Post an open handoff offer and follow it. Requester only: bot.ts supplies
   *  it for that role and leaves it undefined for the worker, which has no
   *  business creating work for itself. */
  postOffer?(title: string, ctx?: string): Promise<string>;
  /** How many posted tasks have not finished. Requester only; 0 elsewhere. */
  pendingCount: number;
}

export interface Command {
  help: string;
  /** Only the owner may run it. */
  ownerOnly?: boolean;
  run(ctx: CommandContext): string | null | Promise<string | null>;
}

import { capacity, runTask } from "./prime.ts";
import { isRequester, isWorker, role } from "./roles.ts";

const startedAt = Date.now();

function humanDuration(ms: number): string {
  const s = Math.floor(ms / 1000);
  const parts: string[] = [];
  if (s >= 86400) parts.push(`${Math.floor(s / 86400)}d`);
  if (s >= 3600) parts.push(`${Math.floor(s / 3600) % 24}h`);
  if (s >= 60) parts.push(`${Math.floor(s / 60) % 60}m`);
  parts.push(`${s % 60}s`);
  return parts.join(" ");
}

const shared: Record<string, Command> = {
  ping: {
    help: "pong",
    run: () => "pong",
  },

  uptime: {
    help: "how long this process has been running",
    run: () => humanDuration(Date.now() - startedAt),
  },

  echo: {
    help: "echo <text> — say it back",
    run: ({ args }) => args || null,
  },

  whoami: {
    help: "report the DID the server attributes to you",
    run: ({ from, senderDid }) => `${from} — ${senderDid ?? "no DID (guest)"}`,
  },

};

/** Worker only: the direct path, bypassing the offer it would otherwise wait
 *  for. Kept because it is the fastest way to tell whether the sandbox side
 *  works when the channel is quiet — but it is the requester's job to create
 *  work, so this stays reachable only by addressing the worker itself. */
const workerOnly: Record<string, Command> = {
  run: {
    help: "run <task> — hand it straight to Prime Agent in a fresh Modal Sandbox",
    run: async ({ args, from, say }) => {
      if (!args) return "run what? e.g. run summarize https://modal.com/docs/guide";
      if (capacity.full) {
        return `busy — ${capacity.inFlight} sandboxes already running, try again shortly`;
      }

      capacity.acquire();
      // The answer is minutes away, so acknowledge now and post it when it
      // lands. Returning it would leave the channel silent the whole time.
      say(`${from}: dispatching to a sandbox…`);
      try {
        const result = await runTask(args, {
          onProgress: (note) => console.error(`[run] ${note}`),
        });
        const trace = result.toolCalls.length ? ` · ${result.toolCalls.join(", ")}` : "";
        say(`${from}: ${result.text}`);
        const s = (ms: number) => `${(ms / 1000).toFixed(1)}s`;
        say(
          `— ${s(result.elapsedMs)} (sandbox ${s(result.createMs)}, agent ${s(result.agentMs)})` +
            ` in ${result.sandboxId}${trace}`,
        );
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        say(`${from}: sandbox failed — ${message.slice(0, 300)}`);
      } finally {
        capacity.release();
      }
      return null;
    },
  },

};

/** Requester only: it holds no Modal token, so asking is all it can do. */
const requesterOnly: Record<string, Command> = {
  offer: {
    help: "offer <task> — post it to the channel for a worker to claim",
    run: async ({ args, from, postOffer }) => {
      if (!args) return "offer what? e.g. offer summarize https://modal.com/docs/guide";
      if (!postOffer) return "this bot cannot post offers";
      // A `|` splits the ask from its context, which is a separate act field:
      // the title is what the channel reads, the context is what the agent
      // gets handed. Without the split a URL-heavy ask becomes an unreadable
      // channel line.
      const [title, ...rest] = args.split("|");
      const taskId = await postOffer(title.trim(), rest.join("|").trim() || undefined);
      return `${from}: posted ${taskId.slice(-6)} — waiting for a worker to claim it`;
    },
  },

  pending: {
    help: "pending — tasks posted and not yet finished",
    run: ({ pendingCount }) =>
      pendingCount ? `${pendingCount} task(s) in flight` : "nothing in flight",
  },
};

export const commands: Record<string, Command> = {
  ...shared,
  ...(isWorker ? workerOnly : {}),
  ...(isRequester ? requesterOnly : {}),
};

commands.help = {
  help: "list commands",
  run: ({ isOwner }) =>
    [`${role}:`]
      .concat(
        Object.entries(commands)
          .filter(([, c]) => isOwner || !c.ownerOnly)
          .map(([name, c]) => `  ${name} — ${c.help}`),
      )
      .join("\n"),
};
