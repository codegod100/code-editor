/** The signed fields for an editor-originated FreeQ handoff offer. */
export function offerFields(input) {
  return {
    title: input.title,
    caps: input.capability,
    // Keep this out of free-form ctx: consumers need a reliable clone target.
    'agentgit-url': input.exchangeUrl,
    ctx: input.context || '',
  };
}
