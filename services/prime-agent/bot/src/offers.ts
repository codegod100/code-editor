/**
 * The requester's side of a handoff: post an offer, then say what became of it.
 *
 * An offer is not a request/response — it goes to the channel, and whichever
 * worker wants it claims it. So the person who asked has no handle on the
 * work, and without something following the task they get a task id and then
 * silence. This keeps that thread: one line when a worker claims it, the
 * progress the worker reports, and the outcome.
 *
 * It follows only tasks this process posted. Other people's offers are none of
 * its business, and reporting on them would put two voices on one task.
 */

import type { ActEventPayload } from "@freeq/sdk";

/** How long to wait for a claim before saying nobody took it. */
const CLAIM_GRACE_MS = Number(process.env.CLAIM_GRACE_MS ?? 45_000);
/** Forget a task this long after it ends, so the map can't grow forever. */
const FORGET_AFTER_MS = Number(process.env.FORGET_AFTER_MS ?? 10 * 60_000);

export interface Pending {
  taskId: string;
  /** Where to report back — the channel it was asked in, or a nick for a DM. */
  target: string;
  /** Who asked, so the report names them in a busy channel. */
  from: string;
  title: string;
  postedAt: number;
  claimedBy?: string;
  /** Cleared when a claim arrives; fires once if none does. */
  graceTimer?: ReturnType<typeof setTimeout>;
}

export class OfferBook {
  private readonly pending = new Map<string, Pending>();

  constructor(private readonly say: (target: string, text: string) => void) {}

  /** Start following a task we just posted. */
  track(entry: Omit<Pending, "postedAt" | "graceTimer">): void {
    const record: Pending = { ...entry, postedAt: Date.now() };
    record.graceTimer = setTimeout(() => {
      if (!this.pending.get(record.taskId)?.claimedBy) {
        this.say(
          record.target,
          `${record.from}: nobody claimed ${short(record.taskId)} in ${
            Math.round(CLAIM_GRACE_MS / 1000)
          }s — is a worker in the channel?`,
        );
      }
    }, CLAIM_GRACE_MS);
    // An unref'd timer must not be the reason the process stays alive.
    record.graceTimer.unref?.();
    this.pending.set(record.taskId, record);
  }

  /**
   * Report on an act about one of our tasks. Returns true if it was ours.
   *
   * The verbs come from whatever claimed the work, so treat them as data:
   * notes are clamped, and an unknown verb is reported as itself rather than
   * assumed to be one of the four we expect.
   */
  handle(event: ActEventPayload): boolean {
    const entry = this.pending.get(event.taskId);
    if (!entry || event.kind !== "handoff") return false;
    if (event.verb === "offer") return true; // our own posting, echoed back

    const note = (event.fields["act-note"] ?? "").slice(0, 200);
    const who = event.from;

    switch (event.verb) {
      case "claim":
        entry.claimedBy = who;
        clearTimeout(entry.graceTimer);
        this.say(entry.target, `${entry.from}: ${who} claimed ${short(event.taskId)}${suffix(note)}`);
        return true;
      case "progress":
        // The worker already posts these as acts; relaying every one would
        // double them in the channel. Only worth a line in a DM, where the
        // asker cannot see the act traffic.
        if (!entry.target.startsWith("#") && note) {
          this.say(entry.target, `${short(event.taskId)}: ${note}`);
        }
        return true;
      case "complete":
        this.finish(entry, `done in ${elapsed(entry)}${suffix(note)}`);
        return true;
      case "fail":
        this.finish(entry, `failed after ${elapsed(entry)}${suffix(note)}`);
        return true;
      default:
        this.say(entry.target, `${entry.from}: ${short(event.taskId)} → ${event.verb}${suffix(note)}`);
        return true;
    }
  }

  private finish(entry: Pending, line: string): void {
    clearTimeout(entry.graceTimer);
    this.say(entry.target, `${entry.from}: ${short(entry.taskId)} ${line}`);
    // The worker posts the answer itself; we only keep the entry around long
    // enough to attribute a late act, then let it go.
    const forget = setTimeout(() => this.pending.delete(entry.taskId), FORGET_AFTER_MS);
    forget.unref?.();
  }

  get size(): number {
    return this.pending.size;
  }
}

/** Task ids are ULIDs — long enough to be unreadable in a chat line. */
const short = (taskId: string) => taskId.slice(-6);
const suffix = (note: string) => (note ? ` — ${note}` : "");
const elapsed = (entry: Pending) => `${Math.round((Date.now() - entry.postedAt) / 1000)}s`;
