#!/usr/bin/env node
/** Connect for one open handoff's lifecycle, then exit. */
import { FreeqBot } from '@freeq/bot-kit';
import { actTags } from '@freeq/sdk';

const input = JSON.parse(await new Promise((resolve, reject) => {
  let value = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (chunk) => value += chunk);
  process.stdin.on('end', () => resolve(value));
  process.stdin.on('error', reject);
}));

for (const key of ['channel', 'title', 'capability', 'serverUrl']) {
  if (typeof input[key] !== 'string' || !input[key].trim()) {
    throw new Error(`handoff ${key} is required`);
  }
}
for (const key of ['FREEQ_OWNER_DID', 'FREEQ_BOT_NICK', 'FREEQ_BOT_ROOT']) {
  if (!process.env[key]) throw new Error(`${key} is required`);
}

const bot = await FreeqBot.create({
  name: 'cloud-code-editor',
  ownerDid: process.env.FREEQ_OWNER_DID,
  nick: process.env.FREEQ_BOT_NICK,
  root: process.env.FREEQ_BOT_ROOT,
  url: input.serverUrl,
  channels: [input.channel],
});

const timeoutMs = Number(input.timeoutMs || 15 * 60_000);
let taskId;
let finish;
const terminal = new Promise((resolve) => { finish = resolve; });

bot.on('actEvent', (event) => {
  if (event.kind !== 'handoff' || event.taskId !== taskId) return;
  const note = event.fields?.['act-note'] || event.fields?.['act-ctx'] || '';
  const actor = event.did || event.fields?.['act-from'] || '';
  // The canonical Fly worker uses claim; tolerate the older accept verb too.
  if (['claim', 'accept'].includes(event.verb)) {
    bot.setState('executing', `handoff ${taskId} claimed`);
    process.stdout.write(JSON.stringify({ type: 'claimed', taskId, actor, note }) + '\n');
  }
  if (['complete', 'fail', 'decline'].includes(event.verb)) {
    finish({ type: 'terminal', taskId, status: event.verb, actor, note });
  }
});

try {
  await bot.start();
  // No `to`: any capable bot in this channel can claim the offer. The offer
  // event id is the task id used by every later accept/complete/fail act.
  taskId = await bot.client.sendAct(
    input.channel,
    actTags('handoff', 'offer', undefined, bot.identity.did, {
      title: input.title,
      caps: input.capability,
      ctx: input.context || '',
    }),
  );
  process.stdout.write(JSON.stringify({ type: 'offered', taskId }) + '\n');
  const outcome = await Promise.race([
    terminal,
    new Promise((resolve) => setTimeout(() => resolve({ type: 'terminal', taskId, status: 'timeout', actor: '', note: 'No bot completed the handoff before its deadline.' }), timeoutMs)),
  ]);
  process.stdout.write(JSON.stringify(outcome) + '\n');
} finally {
  await bot.stop('handoff session ended');
}
