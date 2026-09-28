import assert from 'node:assert/strict';
import test from 'node:test';
import {
  applyAct, applyAudit, isExchangeUrl, isSourceRepoUrl, newExchangeUrl, restOrigin, summarizeManifests, workerContext,
} from './core.mjs';

test('derives the REST origin from the IRC websocket', () => {
  assert.equal(restOrigin('wss://irc.freeq.at/irc'), 'https://irc.freeq.at');
  assert.throws(() => restOrigin('https://irc.freeq.at'));
});

test('mints valid, unique exchange URLs', () => {
  const a = newExchangeUrl();
  assert.ok(isExchangeUrl(a));
  assert.notEqual(a, newExchangeUrl());
  assert.equal(isExchangeUrl('https://evil.example/x.git'), false);
});

test('hosted handoffs clone only credential-free https repositories', () => {
  assert.ok(isSourceRepoUrl('https://github.com/codegod100/code-editor.git'));
  assert.equal(isSourceRepoUrl('https://user:secret@github.com/x/y.git'), false);
  assert.equal(isSourceRepoUrl('file:///etc'), false);
  assert.equal(isSourceRepoUrl('ext::sh -c id'), false);
  assert.equal(isSourceRepoUrl('git@github.com:x/y.git'), false);
});

test('worker context leads with the exact clone target', () => {
  const text = workerContext('https://agentgit.co/x.git', 'Fix the bug');
  assert.match(text, /^Repository exchange: https:\/\/agentgit\.co\/x\.git/);
  assert.match(text, /refs\/heads\/worker/);
  assert.ok(text.endsWith('Fix the bug'));
});

test('summarizes manifests and skips malformed entries', () => {
  const bots = summarizeManifests({ manifests: [
    { agent_did: 'did:key:a', manifest: { agent: { display_name: 'Worker' }, capabilities: { default: ['prime_agent'] } } },
    { agent_did: 'did:key:b' },
  ] });
  assert.deepEqual(bots.map((b) => [b.name, b.capabilities]), [['Worker', ['prime_agent']]]);
});

test('lifecycle acts advance a handoff and stop at a terminal state', () => {
  const h = { status: 'offered' };
  assert.ok(applyAct(h, 'claim', 'freeq-bot', ''));
  assert.equal(h.status, 'claimed');
  assert.ok(applyAct(h, 'progress', '', 'running tests'));
  assert.equal(h.progress, 'running tests');
  assert.ok(applyAct(h, 'complete', 'freeq-bot', 'done'));
  assert.equal(applyAct(h, 'fail', 'freeq-bot', 'late'), false);
  assert.deepEqual([h.status, h.note], ['complete', 'done']);
  assert.equal(h.progress, undefined);
  assert.equal(applyAct({ status: 'offered' }, 'offer', '', ''), false);
});

test('replays the audit trail', () => {
  const h = applyAudit({ status: 'offered' }, [
    { event: 'offer' },
    { event: 'accept', actor_name: 'freeq-bot' },
    { event: 'decline', actor_did: 'did:key:w', details: { note: 'busy' } },
  ]);
  assert.deepEqual([h.status, h.actor, h.note], ['decline', 'did:key:w', 'busy']);
});
