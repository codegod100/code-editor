#!/usr/bin/env node
/** Durable AT Protocol OAuth bridge for the FastAPI frontend. */
import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { NodeOAuthClient } from '@atproto/oauth-client-node';
import { requestLocalLock } from '@atproto/oauth-client';

const root = process.env.ATPROTO_OAUTH_ROOT;
const appUrl = process.env.APP_URL?.replace(/\/$/, '');
if (!root || !appUrl) throw new Error('ATPROTO_OAUTH_ROOT and APP_URL are required');

const stateFile = join(root, 'states.json');
const sessionFile = join(root, 'sessions.json');

async function readStore(path) {
  try { return JSON.parse(await readFile(path, 'utf8')); } catch (error) {
    if (error.code === 'ENOENT') return {};
    throw error;
  }
}
async function writeStore(path, value) {
  await mkdir(root, { recursive: true, mode: 0o700 });
  const temporary = `${path}.next`;
  await writeFile(temporary, JSON.stringify(value), { mode: 0o600 });
  await rename(temporary, path);
}
function durableStore(path) {
  return {
    async get(key) { return (await readStore(path))[key]; },
    async set(key, value) { const all = await readStore(path); all[key] = value; await writeStore(path, all); },
    async del(key) { const all = await readStore(path); delete all[key]; await writeStore(path, all); },
  };
}

const client = new NodeOAuthClient({
  // The Node resolver's direct .well-known/DNS lookups can fail in serverless
  // networks even when a bsky.social handle is publicly resolvable. Use the
  // Bluesky entryway's com.atproto.identity.resolveHandle endpoint instead.
  handleResolver: 'https://bsky.social/',
  clientMetadata: {
    client_id: `${appUrl}/oauth-client-metadata.json`,
    client_name: 'Codex Workspace',
    client_uri: appUrl,
    redirect_uris: [`${appUrl}/auth/callback`],
    grant_types: ['authorization_code', 'refresh_token'],
    response_types: ['code'],
    scope: 'atproto',
    token_endpoint_auth_method: 'none',
    dpop_bound_access_tokens: true,
  },
  requestLock: requestLocalLock,
  stateStore: durableStore(stateFile),
  sessionStore: durableStore(sessionFile),
});

const input = JSON.parse(await new Promise((resolve, reject) => {
  let value = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (chunk) => { value += chunk; });
  process.stdin.on('end', () => resolve(value || '{}'));
  process.stdin.on('error', reject);
}));
const command = process.argv[2];
let result;
if (command === 'metadata') result = client.clientMetadata;
else if (command === 'authorize') result = { url: String(await client.authorize(input.identity, { scope: 'atproto' })) };
else if (command === 'callback') {
  const { session } = await client.callback(new URLSearchParams(input.params));
  // Identity-only login does not retain an OAuth credential after verification.
  await client.revoke(session.did);
  result = { did: session.did };
}
else throw new Error(`unknown command: ${command}`);
process.stdout.write(JSON.stringify(result));
