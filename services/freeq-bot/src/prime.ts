/**
 * One command → one Modal Function call → one Sandbox → one answer.
 *
 * The bot never creates the Sandbox itself. It calls `run_task` in the
 * `prime-agent` app (see ../../modal_app.py), and that Function — running in a
 * container that already has a Modal identity — creates the Sandbox, runs Prime
 * Agent inside it, and tears it down. The bot only needs to ask and wait.
 *
 *   MODAL_TOKEN_ID / MODAL_TOKEN_SECRET   required, read by the SDK from env
 *   MODAL_APP        required Modal app name
 *   MODAL_FUNCTION   required function name
 *   TASK_TIMEOUT_MS  required maximum wait for an answer
 *   PROOF_BASE_URL   required public proof endpoint
 */

import { FunctionTimeoutError, ModalClient, TimeoutError, type Function_ } from "modal";

function required(key: string): string {
  const value = process.env[key]?.trim();
  if (!value) throw new Error(key + " is required");
  return value;
}

function positiveInteger(key: string): number {
  const value = Number(required(key));
  if (!Number.isInteger(value) || value <= 0) {
    throw new Error(key + " must be a positive integer");
  }
  return value;
}

const APP = required("MODAL_APP");
const FUNCTION = required("MODAL_FUNCTION");
const TASK_TIMEOUT_MS = positiveInteger("TASK_TIMEOUT_MS");
const PROOF_BASE_URL = required("PROOF_BASE_URL");

/** Where anyone — no Modal account needed — can verify what this task ran. */
export const proofUrl = (taskId: string) => `${PROOF_BASE_URL}/proof/${encodeURIComponent(taskId)}`;
/** Poll in chunks so a long run can report that it is still alive. */
const POLL_MS = 30_000;

/** Sandboxes cost money and the bot is one connection: cap how many run at
 *  once rather than letting a busy channel fan out without limit. Commands and
 *  claimed offers draw on the same budget — they cost the same sandbox. */
const MAX_CONCURRENT = positiveInteger("MAX_CONCURRENT_TASKS");
let inFlight = 0;

export const capacity = {
  get inFlight() {
    return inFlight;
  },
  get full() {
    return inFlight >= MAX_CONCURRENT;
  },
  acquire() {
    inFlight += 1;
  },
  release() {
    inFlight = Math.max(0, inFlight - 1);
  },
};

export interface TaskResult {
  /** The agent's final assistant text. */
  text: string;
  sandboxId: string;
  elapsedMs: number;
  /** Where the time went: Sandbox creation vs the agent run itself. */
  createMs: number;
  agentMs: number;
  /** Tool calls the agent made, in order — a cheap trace for the channel. */
  toolCalls: string[];
  exitCode: number;
}

/** What `run_task` returns, in Python's naming. */
interface RunTaskResult {
  ok?: boolean;
  text?: string;
  sandbox_id?: string;
  elapsed_ms?: number;
  create_ms?: number;
  agent_ms?: number;
  tool_calls?: string[];
  exit_code?: number;
}

// The lookup is a network round-trip and the Function doesn't move, so do it
// once and reuse it for the life of the process.
let cached: Promise<Function_> | undefined;

function lookup(): Promise<Function_> {
  cached ??= new ModalClient().functions.fromName(APP, FUNCTION).catch((err) => {
    cached = undefined; // a failed lookup must not be cached as the answer
    throw err;
  });
  return cached;
}

/**
 * Dispatch one task and wait for it.
 *
 * `spawn` rather than `remote`: the call id exists the moment the task starts,
 * so a run that outlives a poll — or a bot restart — is still a task we could
 * pick back up, rather than a request we lost the only handle to.
 */
export async function runTask(
  prompt: string,
  opts: { onProgress?: (note: string) => void; taskId?: string } = {},
): Promise<TaskResult> {
  const fn = await lookup();
  // The task id keys the proof manifest. Without one the work still runs, it
  // just leaves nothing anyone can check afterwards.
  const call = await fn.spawn([prompt, opts.taskId ?? null]);
  opts.onProgress?.(`dispatched ${call.functionCallId}`);

  const deadline = Date.now() + TASK_TIMEOUT_MS;
  for (;;) {
    const remaining = deadline - Date.now();
    if (remaining <= 0) {
      throw new Error(`task ${call.functionCallId} still running after ${TASK_TIMEOUT_MS}ms`);
    }
    try {
      const result = (await call.get({ timeoutMs: Math.min(POLL_MS, remaining) })) as RunTaskResult;
      return {
        text: (result.text ?? "").trim(),
        sandboxId: result.sandbox_id ?? "(unknown)",
        elapsedMs: result.elapsed_ms ?? 0,
        createMs: result.create_ms ?? 0,
        agentMs: result.agent_ms ?? 0,
        toolCalls: result.tool_calls ?? [],
        exitCode: result.exit_code ?? 0,
      };
    } catch (err) {
      // A poll that times out means "not finished yet", not "failed". The SDK
      // raises FunctionTimeoutError for an elapsed `timeoutMs` — distinct from
      // the TimeoutError it uses elsewhere, and catching only the latter ends
      // every run at the first poll.
      if (!(err instanceof FunctionTimeoutError || err instanceof TimeoutError)) throw err;
      opts.onProgress?.(`still running (${Math.round((Date.now() - (deadline - TASK_TIMEOUT_MS)) / 1000)}s)`);
    }
  }
}
