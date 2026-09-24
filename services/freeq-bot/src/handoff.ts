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
