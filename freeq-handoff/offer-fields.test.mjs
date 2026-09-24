import assert from 'node:assert/strict';
import test from 'node:test';
import { offerFields } from './offer-fields.mjs';

test('publishes the AgentGit clone URL as a structured offer field', () => {
  const exchangeUrl = 'https://agentgit.co/code-editor-example.git';

  assert.deepEqual(offerFields({
    title: 'make an edit to test.txt',
    capability: 'prime_agent',
    exchangeUrl,
    context: 'Create the file.',
  }), {
    title: 'make an edit to test.txt',
    caps: 'prime_agent',
    'agentgit-url': exchangeUrl,
    ctx: 'Create the file.',
  });
});
