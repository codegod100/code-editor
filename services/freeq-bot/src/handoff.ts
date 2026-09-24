import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

/** Build the prompt passed to the remote task runner for a claimed offer. */
export function handoffPrompt(fields: Record<string, string | undefined>): string {
  const title = fields["act-title"]?.trim() ?? "";
  const context = fields["act-ctx"]?.trim() ?? "";
  const agentGitUrl = fields["act-agentgit-url"]?.trim() ?? "";
  // The repository is an explicit offer field, rather than merely prose in
  // ctx, so the dispatched agent always receives the exact clone target.
  const repository = agentGitUrl
    ? "AgentGit repository (clone this exact URL): " + agentGitUrl
    : "";
  return [title, repository, context].filter(Boolean).join("\n\n");
}

export function validateAgentGitRefs(output: string): void {
  const refs = new Map<string, string>();
  for (const line of output.split("\n")) {
    const [oid, ref] = line.trim().split(/\s+/, 2);
    if (oid && ref) refs.set(ref, oid);
  }

  const main = refs.get("refs/heads/main");
  const worker = refs.get("refs/heads/worker");
  if (!main) throw new Error("AgentGit exchange is missing refs/heads/main");
  if (!worker) throw new Error("worker did not push refs/heads/worker to the AgentGit exchange");
  if (worker === main) throw new Error("AgentGit worker branch does not contain any changes");
}

/** Refuse to attest completion until the public exchange proves work was pushed. */
export async function verifyAgentGitExchange(url: string): Promise<void> {
  let exchange: URL;
  try {
    exchange = new URL(url);
  } catch {
    throw new Error("offer contains an invalid AgentGit exchange URL");
  }
  if (
    exchange.protocol !== "https:" ||
    exchange.hostname !== "agentgit.co" ||
    exchange.username ||
    exchange.password ||
    !exchange.pathname.endsWith(".git")
  ) {
    throw new Error("offer contains an invalid AgentGit exchange URL");
  }
  const { stdout } = await execFileAsync(
    "git",
    ["ls-remote", "--heads", url, "refs/heads/main", "refs/heads/worker"],
    { timeout: 30_000, maxBuffer: 1024 * 1024 },
  );
  validateAgentGitRefs(stdout);
}
