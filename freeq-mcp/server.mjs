#!/usr/bin/env node
/**
 * FreeQ MCP connector for Claude Code.
 *
 * Claude Code launches this over stdio for the life of a session. The first
 * handoff connects one signed FreeQ bot (a did:key delegated by
 * FREEQ_OWNER_DID); it stays connected so claims, progress, and results from
 * workers in the channel are tracked until the session ends.
 *
 * A handoff publishes the checkout's committed HEAD to a fresh AgentGit
 * exchange, then posts an open `handoff/offer` any capable bot may claim.
 * Workers push their result to the exchange's `worker` branch, which
 * `fetch_worker_branch` brings back for review.
 */
import { execFile } from 'node:child_process';
import { resolve } from 'node:path';
import { promisify } from 'node:util';
import { FreeqBot } from '@freeq/bot-kit';
import { actTags } from '@freeq/sdk';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { z } from 'zod';
import { waitForChannelJoin } from '../freeq-handoff/channel-ready.mjs';
import { offerFields } from '../freeq-handoff/offer-fields.mjs';
import {
  DEFAULT_CAPABILITY, DEFAULT_CHANNEL, DEFAULT_SERVER, TERMINAL,
  applyAct, applyAudit, isExchangeUrl, newExchangeUrl, restOrigin,
  summarizeManifests, workerContext,
} from './core.mjs';

const run = promisify(execFile);
const serverUrl = process.env.FREEQ_SERVER || DEFAULT_SERVER;
const origin = restOrigin(serverUrl);
const log = (...parts) => console.error('[freeq-mcp]', ...parts);

/** taskId -> handoff record, for everything offered in this session. */
const handoffs = new Map();
const waiters = new Set();
let botPromise;
const joined = new Set();

function notifyWaiters() {
  for (const wake of waiters) wake();
}

async function connectBot() {
  const ownerDid = process.env.FREEQ_OWNER_DID;
  if (!ownerDid?.startsWith('did:')) {
    throw new Error('FREEQ_OWNER_DID must be set to the AT Protocol DID this bot acts for');
  }
  const bot = await FreeqBot.create({
    name: process.env.FREEQ_BOT_NAME || 'claude-code',
    ownerDid,
    nick: process.env.FREEQ_BOT_NICK || 'claude-code',
    url: serverUrl,
    ...(process.env.FREEQ_BOT_ROOT ? { root: process.env.FREEQ_BOT_ROOT } : {}),
    ...(process.env.FREEQ_CREATOR_KEY ? { creatorKeyPath: process.env.FREEQ_CREATOR_KEY } : {}),
    actorClass: 'agent',
    initialState: 'idle',
    initialStatus: 'Claude Code handoff requester',
    // Several Claude Code sessions may share one identity; never fight over a nick.
    onNickCollision: 'random-suffix',
  });
  bot.on('channelJoined', (channel) => joined.add(channel));
  bot.on('actEvent', (event) => {
    if (event.kind !== 'handoff') return;
    const handoff = handoffs.get(event.taskId);
    if (!handoff) return;
    const note = event.fields?.['act-note'] || event.fields?.['act-ctx'] || '';
    const actor = event.from || event.did || event.fields?.['act-from'] || '';
    if (applyAct(handoff, event.verb, actor, note)) {
      log(`handoff ${event.taskId} ${handoff.status}${actor ? ` by ${actor}` : ''}`);
      notifyWaiters();
    }
  });
  await bot.start();
  log(`connected to ${serverUrl} as ${bot.identity.did}`);
  return bot;
}

async function ensureChannel(channel) {
  botPromise ??= connectBot().catch((error) => { botPromise = undefined; throw error; });
  const bot = await botPromise;
  if (!joined.has(channel)) {
    const ready = waitForChannelJoin(bot, channel);
    bot.client.join(channel);
    await ready;
  }
  return bot;
}

async function git(cwd, ...args) {
  const { stdout } = await run('git', ['-C', cwd, ...args], { timeout: 300_000, maxBuffer: 16 * 1024 * 1024 });
  return stdout;
}

async function fetchJson(url) {
  const response = await fetch(url, { signal: AbortSignal.timeout(15_000) });
  if (!response.ok) throw new Error(`${url} returned HTTP ${response.status}`);
  return response.json();
}

async function refreshFromAudit(handoff) {
  const channel = encodeURIComponent(handoff.channel.replace(/^#/, ''));
  const audit = await fetchJson(`${origin}/api/v1/channels/${channel}/audit?ref_id=${encodeURIComponent(handoff.taskId)}`);
  applyAudit(handoff, audit.timeline);
}

const ok = (value) => ({ content: [{ type: 'text', text: JSON.stringify(value, null, 2) }] });
const failure = (error) => ({ content: [{ type: 'text', text: `FreeQ error: ${error.message ?? error}` }], isError: true });
const guarded = (handler) => async (args) => {
  try { return ok(await handler(args)); } catch (error) { return failure(error); }
};

const server = new McpServer({ name: 'freeq', version: '0.1.0' });

server.registerTool('list_bots', {
  description: 'List FreeQ bots that publish agent manifests, with the capabilities they claim. '
    + `The code-editor worker in ${DEFAULT_CHANNEL} claims '${DEFAULT_CAPABILITY}'.`,
  inputSchema: {},
}, guarded(async () => ({ bots: summarizeManifests(await fetchJson(`${origin}/api/v1/agents/manifests`)) })));

server.registerTool('handoff', {
  description: `Offer a task to the FreeQ bots in a channel (default ${DEFAULT_CHANNEL}). `
    + 'The repository must be clean: commit first. Its HEAD is pushed to a new public AgentGit '
    + 'exchange that expires in 24 hours, so never hand off secrets. Any bot with the capability '
    + 'may claim it; the worker pushes its result to the exchange\'s `worker` branch. Returns '
    + 'immediately with a taskId; use handoff_status to follow it and fetch_worker_branch to review.',
  inputSchema: {
    title: z.string().min(1).max(500).describe('Short task summary.'),
    context: z.string().min(1).describe('Self-contained instructions: goal, relevant files, constraints, '
      + 'and how to verify. The worker cannot see this conversation.'),
    capability: z.string().default(DEFAULT_CAPABILITY).describe('Capability a bot must claim.'),
    channel: z.string().regex(/^#/).default(DEFAULT_CHANNEL).describe('FreeQ channel.'),
    repo_path: z.string().optional().describe('Repository to hand off (default: current directory).'),
  },
}, guarded(async ({ title, context, capability, channel, repo_path }) => {
  const cwd = resolve(repo_path || process.cwd());
  const root = (await git(cwd, 'rev-parse', '--show-toplevel')).trim();
  if ((await git(root, 'status', '--porcelain')).trim()) {
    throw new Error('the repository has uncommitted changes; commit or stash them before handing off');
  }
  const head = (await git(root, 'rev-parse', 'HEAD')).trim();
  const exchangeUrl = newExchangeUrl();
  await git(root, 'push', '--quiet', exchangeUrl, 'HEAD:refs/heads/main');
  const bot = await ensureChannel(channel);
  const taskId = await bot.client.sendAct(
    channel,
    actTags('handoff', 'offer', undefined, bot.identity.did, offerFields({
      title, capability, exchangeUrl, context: workerContext(exchangeUrl, context),
    })),
  );
  const handoff = {
    taskId, channel, capability, title, exchangeUrl, repository: root, head,
    status: 'offered', actor: '', note: '', createdAt: new Date().toISOString(),
  };
  handoffs.set(taskId, handoff);
  bot.setState('waiting', `handoff ${taskId} offered`);
  log(`offered ${taskId} in ${channel} (${capability})`);
  return handoff;
}));

server.registerTool('handoff_status', {
  description: 'Report a FreeQ handoff\'s status (offered, claimed, complete, fail, decline, timeout), '
    + 'the claiming bot, and its latest note. Optionally wait for a change.',
  inputSchema: {
    task_id: z.string().optional().describe('Task id from handoff; omit to list this session\'s handoffs.'),
    channel: z.string().regex(/^#/).default(DEFAULT_CHANNEL).describe('Channel, for tasks from earlier sessions.'),
    wait_seconds: z.number().int().min(0).max(600).default(0)
      .describe('Block up to this long for the status to change or finish.'),
  },
}, guarded(async ({ task_id, channel, wait_seconds }) => {
  if (!task_id) return { handoffs: [...handoffs.values()] };
  const handoff = handoffs.get(task_id)
    ?? { taskId: task_id, channel, status: 'offered', actor: '', note: '', untracked: true };
  if (handoff.untracked || !botPromise) await refreshFromAudit(handoff).catch((error) => log(error.message));
  const before = handoff.status;
  if (wait_seconds && !TERMINAL.has(before) && !handoff.untracked) {
    await new Promise((done) => {
      const wake = () => { if (handoff.status !== before) finish(); };
      const timer = setTimeout(() => finish(), wait_seconds * 1000);
      function finish() { clearTimeout(timer); waiters.delete(wake); done(); }
      waiters.add(wake);
    });
  }
  return handoff;
}));

server.registerTool('fetch_worker_branch', {
  description: 'Fetch a completed handoff\'s `worker` branch from its AgentGit exchange into a local '
    + 'ref (refs/freeq/<task>) and return its commits and diff stat against HEAD. Nothing is merged; '
    + 'review the ref, then merge or cherry-pick it yourself if the user agrees.',
  inputSchema: {
    task_id: z.string().optional().describe('Task id from this session.'),
    exchange_url: z.string().optional().describe('AgentGit exchange URL, for tasks from earlier sessions.'),
    repo_path: z.string().optional().describe('Repository to fetch into (default: current directory).'),
  },
}, guarded(async ({ task_id, exchange_url, repo_path }) => {
  const handoff = task_id ? handoffs.get(task_id) : undefined;
  const exchangeUrl = exchange_url || handoff?.exchangeUrl;
  if (!isExchangeUrl(exchangeUrl)) throw new Error('pass exchange_url or the task_id of a handoff from this session');
  const cwd = resolve(repo_path || handoff?.repository || process.cwd());
  const name = (task_id || exchangeUrl.split('/').pop().replace(/\.git$/, '')).replace(/[^A-Za-z0-9._-]/g, '-');
  const ref = `refs/freeq/${name}`;
  await git(cwd, 'fetch', '--no-tags', '--quiet', exchangeUrl, `+refs/heads/worker:${ref}`);
  const [log_, stat] = await Promise.all([
    git(cwd, 'log', '--oneline', `HEAD..${ref}`),
    git(cwd, 'diff', '--stat', `HEAD...${ref}`),
  ]);
  return { ref, commits: log_.trim().split('\n').filter(Boolean), diffStat: stat.trim(), review: `git diff HEAD...${ref}` };
}));

async function shutdown() {
  if (botPromise) {
    try { await (await botPromise).stop({ reason: 'Claude Code session ended' }); } catch {}
  }
  process.exit(0);
}
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
process.stdin.on('close', shutdown);

await server.connect(new StdioServerTransport());
log(`ready (${serverUrl})`);
