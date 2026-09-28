/** Pure helpers for the FreeQ MCP connector, kept free of I/O for testing. */
import { randomBytes } from 'node:crypto';

export const DEFAULT_SERVER = 'wss://irc.freeq.at/irc';
export const DEFAULT_CHANNEL = '#tasks';
// The long-lived worker in services/freeq-bot claims only this capability.
export const DEFAULT_CAPABILITY = 'prime_agent';
export const TERMINAL = new Set(['complete', 'fail', 'decline', 'timeout']);

/** The REST origin that serves manifests and audit trails for a server URL. */
export function restOrigin(serverUrl) {
  const url = new URL(serverUrl);
  if (!['wss:', 'ws:'].includes(url.protocol)) throw new Error('FreeQ server must be a ws(s):// URL');
  return `${url.protocol === 'wss:' ? 'https' : 'http'}://${url.host}`;
}

/** A fresh, unguessable AgentGit exchange for one handoff. */
export function newExchangeUrl() {
  return `https://agentgit.co/claude-code-${randomBytes(10).toString('hex')}.git`;
}

export function isExchangeUrl(value) {
  return typeof value === 'string'
    && /^https:\/\/agentgit\.co\/[A-Za-z0-9._-]+\.git$/.test(value);
}

/** A repository a hosted server may clone: public https only, no credentials. */
export function isSourceRepoUrl(value) {
  if (typeof value !== 'string') return false;
  try {
    const url = new URL(value);
    return url.protocol === 'https:' && !url.username && !url.password;
  } catch {
    return false;
  }
}

/** Instructions the worker needs regardless of the task, mirroring the editor. */
export function workerContext(exchangeUrl, context = '') {
  const repository = `Repository exchange: ${exchangeUrl}\n`
    + 'Clone this AgentGit repository into /work/code-editor before inspecting or editing. '
    + 'Work only in that clone. After validating changes, commit them and run '
    + '`git push origin HEAD:refs/heads/worker`. Do not modify main. AgentGit exchanges are public '
    + `and expire after 24 hours. Put \`AgentGit exchange: ${exchangeUrl}\` as the first line `
    + 'of your final report, followed by the files changed and a concise diff summary.';
  return [repository, String(context).trim().slice(0, 4000)].filter(Boolean).join('\n\n');
}

/** Summarize the public agent manifest feed. */
export function summarizeManifests(discovered) {
  const bots = [];
  for (const item of discovered?.manifests ?? []) {
    const manifest = item?.manifest;
    if (!manifest || typeof manifest !== 'object') continue;
    const agent = manifest.agent ?? {};
    bots.push({
      did: item.agent_did ?? '',
      name: agent.display_name || item.agent_did || 'unknown bot',
      description: agent.description || '',
      capabilities: manifest.capabilities?.default ?? [],
      channels: manifest.capabilities?.channels ?? {},
      version: agent.version || '',
    });
  }
  return bots;
}

/** Fold one lifecycle act into a tracked handoff. Returns true if it changed. */
export function applyAct(handoff, verb, actor, note) {
  let status;
  if (verb === 'claim' || verb === 'accept') status = 'claimed';
  else if (verb === 'progress') status = handoff.status === 'offered' ? 'claimed' : handoff.status;
  else if (TERMINAL.has(verb)) status = verb;
  else return false;
  if (TERMINAL.has(handoff.status)) return false;
  handoff.status = status;
  if (actor) handoff.actor = actor;
  if (note) handoff.note = note;
  if (verb === 'progress' && note) handoff.progress = note;
  // A finished handoff has no live progress; keep the last note in `note`.
  if (TERMINAL.has(status)) delete handoff.progress;
  handoff.updatedAt = new Date().toISOString();
  return true;
}

/** Replay a channel audit timeline for one task onto a handoff record. */
export function applyAudit(handoff, timeline) {
  for (const event of timeline ?? []) {
    if (!event || typeof event !== 'object') continue;
    const details = event.details && typeof event.details === 'object' ? event.details : {};
    applyAct(
      handoff,
      String(event.event ?? ''),
      event.actor_name || event.actor_did || '',
      String(details.note || details.ctx || ''),
    );
  }
  return handoff;
}
