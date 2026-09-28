/**
 * FreeQ MCP tools, shared by the stdio entry (server.mjs) and the hosted HTTP
 * entry (http.mjs).
 *
 * The first handoff connects one signed FreeQ bot (a did:key delegated by
 * FREEQ_OWNER_DID); it stays connected so claims, progress, and results from
 * workers in the channel are tracked for the life of the process.
 *
 * A handoff publishes a repository revision to a fresh AgentGit exchange, then
 * posts an open `handoff/offer` any capable bot may claim. Workers push their
 * result to the exchange's `worker` branch, which `fetch_worker_branch` brings
 * back for review.
 *
 * Locally the revision is the checkout's committed HEAD and the worker branch
 * is fetched into that checkout. A hosted server has no checkout of its own, so
 * it takes a public https repository (or an exchange the caller already pushed
 * to) and reports the worker branch for the caller to fetch.
 */
import { execFile } from 'node:child_process';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { promisify } from 'node:util';
import { FreeqBot } from '@freeq/bot-kit';
import { actTags } from '@freeq/sdk';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { z } from 'zod';
import { waitForChannelJoin } from '../freeq-handoff/channel-ready.mjs';
import { offerFields } from '../freeq-handoff/offer-fields.mjs';
import {
  DEFAULT_CAPABILITY, DEFAULT_CHANNEL, DEFAULT_SERVER, TERMINAL,
  applyAct, applyAudit, isExchangeUrl, isSourceRepoUrl, newExchangeUrl, restOrigin,
  summarizeManifests, workerContext,
} from './core.mjs';

const run = promisify(execFile);
export const serverUrl = process.env.FREEQ_SERVER || DEFAULT_SERVER;
const origin = restOrigin(serverUrl);
export const log = (...parts) => console.error('[freeq-mcp]', ...parts);

/** taskId -> handoff record, for everything offered by this process. */
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

// Git only ever talks https, so a caller cannot reach local files or
// transport helpers through a repository URL.
const gitEnv = { ...process.env, GIT_ALLOW_PROTOCOL: 'https', GIT_TERMINAL_PROMPT: '0' };

async function git(cwd, ...args) {
  const { stdout } = await run('git', ['-C', cwd, ...args], {
    timeout: 300_000, maxBuffer: 16 * 1024 * 1024, env: gitEnv,
  });
  return stdout;
}

/** Run `work` in a scratch bare repository that is removed afterwards. */
async function withScratchRepo(work) {
  const dir = await mkdtemp(join(tmpdir(), 'freeq-mcp-'));
  try {
    await git(dir, 'init', '--quiet', '--bare');
    return await work(dir);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
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

/** Publish a local checkout's committed HEAD; returns its provenance. */
async function publishLocal(repoPath, exchangeUrl) {
  const root = (await git(resolve(repoPath || process.cwd()), 'rev-parse', '--show-toplevel')).trim();
  if ((await git(root, 'status', '--porcelain')).trim()) {
    throw new Error('the repository has uncommitted changes; commit or stash them before handing off');
  }
  const head = (await git(root, 'rev-parse', 'HEAD')).trim();
  await git(root, 'push', '--quiet', exchangeUrl, 'HEAD:refs/heads/main');
  return { repository: root, head };
}

/** Publish a public https repository's revision; returns its provenance. */
async function publishRemote(sourceRepo, ref, exchangeUrl) {
  if (!isSourceRepoUrl(sourceRepo)) throw new Error('source_repo must be a public https:// git URL');
  return withScratchRepo(async (dir) => {
    await git(dir, 'fetch', '--quiet', '--no-tags', sourceRepo, ref);
    const head = (await git(dir, 'rev-parse', 'FETCH_HEAD')).trim();
    await git(dir, 'push', '--quiet', exchangeUrl, `${head}:refs/heads/main`);
    return { repository: sourceRepo, ref, head };
  });
}

/** Confirm a caller-populated exchange has a main branch; returns its provenance. */
async function useExistingExchange(exchangeUrl) {
  const line = (await git(tmpdir(), 'ls-remote', exchangeUrl, 'refs/heads/main')).trim();
  if (!line) throw new Error(`${exchangeUrl} has no main branch; push the revision to refs/heads/main first`);
  return { repository: exchangeUrl, head: line.split(/\s+/)[0] };
}

const ok = (value) => ({ content: [{ type: 'text', text: JSON.stringify(value, null, 2) }] });
const failure = (error) => ({ content: [{ type: 'text', text: `FreeQ error: ${error.message ?? error}` }], isError: true });
const guarded = (handler) => async (args) => {
  try { return ok(await handler(args)); } catch (error) { return failure(error); }
};

/**
 * Build an MCP server exposing the FreeQ tools. All servers in a process share
 * one bot and one handoff registry, so a hosted deployment can create a server
 * per request.
 */
export function createFreeqServer({ hosted = false } = {}) {
  const server = new McpServer({ name: 'freeq', version: '0.2.0' });
  // Hosted HTTP requests are cut off by the platform well before ten minutes.
  const maxWait = hosted ? 120 : 600;

  server.registerTool('list_bots', {
    description: 'List FreeQ bots that publish agent manifests, with the capabilities they claim. '
      + `The code-editor worker in ${DEFAULT_CHANNEL} claims '${DEFAULT_CAPABILITY}'.`,
    inputSchema: {},
  }, guarded(async () => ({ bots: summarizeManifests(await fetchJson(`${origin}/api/v1/agents/manifests`)) })));

  if (hosted) {
    server.registerTool('new_exchange', {
      description: 'Mint a fresh, empty AgentGit exchange URL. Push the revision to hand off with '
        + '`git push <url> HEAD:refs/heads/main`, then call handoff with exchange_url. Use this for '
        + 'private repositories, which this server cannot clone. Exchanges are public for 24 hours.',
      inputSchema: {},
    }, guarded(async () => ({ exchangeUrl: newExchangeUrl() })));
  }

  const sourceSchema = hosted
    ? {
      source_repo: z.string().optional().describe('Public https:// git URL to hand off; this server clones it.'),
      ref: z.string().min(1).default('HEAD').describe('Branch, tag, or commit of source_repo.'),
      exchange_url: z.string().optional().describe('An exchange from new_exchange that you already pushed '
        + 'to refs/heads/main. Use instead of source_repo for private repositories.'),
    }
    : { repo_path: z.string().optional().describe('Repository to hand off (default: current directory).') };

  server.registerTool('handoff', {
    description: `Offer a task to the FreeQ bots in a channel (default ${DEFAULT_CHANNEL}). `
      + (hosted
        ? 'Pass source_repo (a public https repository this server clones) or exchange_url (from '
          + 'new_exchange, already pushed). '
        : 'The repository must be clean: commit first; its HEAD is handed off. ')
      + 'The revision is published to a public AgentGit exchange that expires in 24 hours, so never '
      + 'hand off secrets. Any bot with the capability may claim it; the worker pushes its result to '
      + 'the exchange\'s `worker` branch. Returns immediately with a taskId; use handoff_status to '
      + 'follow it and fetch_worker_branch to review.',
    inputSchema: {
      title: z.string().min(1).max(500).describe('Short task summary.'),
      context: z.string().min(1).describe('Self-contained instructions: goal, relevant files, constraints, '
        + 'and how to verify. The worker cannot see this conversation.'),
      capability: z.string().default(DEFAULT_CAPABILITY).describe('Capability a bot must claim.'),
      channel: z.string().regex(/^#/).default(DEFAULT_CHANNEL).describe('FreeQ channel.'),
      ...sourceSchema,
    },
  }, guarded(async ({ title, context, capability, channel, repo_path, source_repo, ref, exchange_url }) => {
    let exchangeUrl;
    let source;
    if (!hosted) {
      exchangeUrl = newExchangeUrl();
      source = await publishLocal(repo_path, exchangeUrl);
    } else if (exchange_url) {
      if (!isExchangeUrl(exchange_url)) throw new Error('exchange_url must be an https://agentgit.co/<name>.git URL');
      exchangeUrl = exchange_url;
      source = await useExistingExchange(exchangeUrl);
    } else if (source_repo) {
      exchangeUrl = newExchangeUrl();
      source = await publishRemote(source_repo, ref, exchangeUrl);
    } else {
      throw new Error('pass source_repo (public https repository) or exchange_url (from new_exchange)');
    }
    const bot = await ensureChannel(channel);
    const taskId = await bot.client.sendAct(
      channel,
      actTags('handoff', 'offer', undefined, bot.identity.did, offerFields({
        title, capability, exchangeUrl, context: workerContext(exchangeUrl, context),
      })),
    );
    const handoff = {
      taskId, channel, capability, title, exchangeUrl, ...source,
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
      task_id: z.string().optional().describe(hosted
        ? 'Task id from handoff; omit to list handoffs this server is tracking.'
        : 'Task id from handoff; omit to list this session\'s handoffs.'),
      channel: z.string().regex(/^#/).default(DEFAULT_CHANNEL).describe('Channel, for tasks from earlier sessions.'),
      wait_seconds: z.number().int().min(0).max(maxWait).default(0)
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

  if (hosted) {
    server.registerTool('fetch_worker_branch', {
      description: 'Summarize a handoff\'s `worker` branch on its AgentGit exchange: commits and diff stat '
        + 'against the handed-off main. This server cannot write to your checkout, so it returns the '
        + '`git fetch` command to bring the branch into your repository for review. Nothing is merged.',
      inputSchema: {
        task_id: z.string().optional().describe('Task id from handoff.'),
        exchange_url: z.string().optional().describe('AgentGit exchange URL, for tasks this server is not tracking.'),
      },
    }, guarded(async ({ task_id, exchange_url }) => {
      const exchangeUrl = exchange_url || (task_id && handoffs.get(task_id)?.exchangeUrl);
      if (!isExchangeUrl(exchangeUrl)) throw new Error('pass exchange_url or the task_id of a handoff this server made');
      const name = (task_id || exchangeUrl.split('/').pop().replace(/\.git$/, '')).replace(/[^A-Za-z0-9._-]/g, '-');
      const ref = `refs/freeq/${name}`;
      return withScratchRepo(async (dir) => {
        await git(dir, 'fetch', '--no-tags', '--quiet', exchangeUrl,
          '+refs/heads/main:refs/heads/main', '+refs/heads/worker:refs/heads/worker');
        const [log_, stat] = await Promise.all([
          git(dir, 'log', '--oneline', 'main..worker'),
          git(dir, 'diff', '--stat', 'main...worker'),
        ]);
        return {
          exchangeUrl,
          commits: log_.trim().split('\n').filter(Boolean),
          diffStat: stat.trim(),
          fetch: `git fetch --no-tags ${exchangeUrl} +refs/heads/worker:${ref}`,
          review: `git diff HEAD...${ref}`,
        };
      });
    }));
  } else {
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
  }

  return server;
}

/** Disconnect the FreeQ bot, if one was started. */
export async function stopBot(reason) {
  if (!botPromise) return;
  try { await (await botPromise).stop({ reason }); } catch {}
}
