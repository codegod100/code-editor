import assert from "node:assert/strict";
import test from "node:test";
import { handoffPrompt, validateAgentGitRefs } from "./handoff.ts";

test("includes the structured AgentGit URL in the dispatched prompt", () => {
  const exchangeUrl = "https://agentgit.co/code-editor-example.git";
  const prompt = handoffPrompt({
    "act-title": "make an edit to test.txt",
    "act-agentgit-url": exchangeUrl,
    "act-ctx": "Commit the change to the worker branch.",
  });

  assert.ok(prompt.includes(`clone this exact URL): ${exchangeUrl}`));
  assert.ok(prompt.indexOf(exchangeUrl) < prompt.indexOf("Commit the change"));
});

test("accepts a changed AgentGit worker branch", () => {
  assert.doesNotThrow(() =>
    validateAgentGitRefs(
      "aaaaaaaa\trefs/heads/main\n" +
        "bbbbbbbb\trefs/heads/worker\n",
    ),
  );
});

test("rejects an AgentGit exchange with no worker branch", () => {
  assert.throws(
    () => validateAgentGitRefs("aaaaaaaa\trefs/heads/main\n"),
    /did not push refs\/heads\/worker/,
  );
});

test("rejects an AgentGit exchange with no main branch", () => {
  assert.throws(
    () => validateAgentGitRefs("bbbbbbbb\trefs/heads/worker\n"),
    /missing refs\/heads\/main/,
  );
});

test("rejects an unchanged AgentGit worker branch", () => {
  assert.throws(
    () =>
      validateAgentGitRefs(
        "aaaaaaaa\trefs/heads/main\n" +
          "aaaaaaaa\trefs/heads/worker\n",
      ),
    /does not contain any changes/,
  );
});
