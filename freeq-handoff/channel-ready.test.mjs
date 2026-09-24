import assert from 'node:assert/strict';
import test from 'node:test';
import { EventEmitter } from 'node:events';
import { waitForChannelJoin } from './channel-ready.mjs';

test('waits for the requested channel, not an unrelated join', async () => {
  const bot = new EventEmitter();
  const ready = waitForChannelJoin(bot, '#tasks', 100);

  bot.emit('channelJoined', '#other');
  bot.emit('channelJoined', '#tasks');

  await ready;
});

test('fails clearly when the requested channel cannot be joined', async () => {
  const bot = new EventEmitter();
  await assert.rejects(waitForChannelJoin(bot, '#tasks', 1), /timed out joining FreeQ channel #tasks/);
});
