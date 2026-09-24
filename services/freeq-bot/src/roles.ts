/**
 * Which half of the pair this process is.
 *
 * Two bots sit in #tasks, and they are not one program's two moods: they hold
 * different credentials and different powers.
 *
 *   requester  takes input from people, posts open `handoff` offers, and
 *              reports what becomes of them. Talks to freeq and nothing else —
 *              no Modal token, no sandbox, no way to spend the account's
 *              money. Compromise it and you get noise in a channel.
 *   worker     watches for offers with caps=prime_agent, claims one, runs it
 *              in a Modal Sandbox, answers with the result and a proof link.
 *              Holds the Modal token, and takes no orders from anyone.
 *
 * The asymmetry is the design. Anyone may ask for work; only the worker can
 * pay for it, and only for an offer posted in the open where the channel can
 * see who asked for what — never for a line typed at it.
 *
 * One image, one FREEQ_ROLE, two Fly apps (fly.toml, fly.requester.toml), two
 * volumes, two DIDs.
 */

export type Role = "requester" | "worker";

const ROLES: Role[] = ["requester", "worker"];

function parseRole(raw: string | undefined): Role {
  // Defaulting to worker keeps an existing single-bot deployment on the
  // identity already written to its volume: say nothing, get what was there.
  const value = (raw ?? "worker").trim().toLowerCase();
  if (!ROLES.includes(value as Role)) {
    console.error(
      `[bot] FREEQ_ROLE must be ${ROLES.join(" or ")}, got ${JSON.stringify(raw)}`,
    );
    process.exit(1);
  }
  return value as Role;
}

export const role: Role = parseRole(process.env.FREEQ_ROLE);
export const isRequester = role === "requester";
export const isWorker = role === "worker";

/** Default nick per role. The worker's is the historical one, so an existing
 *  deployment that sets no nick keeps its DID. */
export const defaultNick = isRequester ? "task-desk" : "freeq-bot";
