import assert from "node:assert/strict";
import test from "node:test";
import { handoffPrompt } from "./handoff.ts";

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
