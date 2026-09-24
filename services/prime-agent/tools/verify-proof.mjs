#!/usr/bin/env node
/**
 * Verify that a job really ran the Sandboxes it claims.
 *
 *   node tools/verify-proof.mjs <task-id> [proof-base-url]
 *
 * Needs no Modal account, no credentials, and no trust in the bot that posted
 * the claim. Each Sandbox carries a JWT signed by Modal naming its container,
 * app and workspace; Modal publishes the verifying key at oidc.modal.com. This
 * checks the signatures and counts the distinct containers.
 *
 * What a pass means: Modal attests that these containers existed, in that
 * workspace, at that time. What it does not mean: that they did the work
 * described — the token names the container, not its output.
 */

const DEFAULT_BASE = "https://codegod100--prime-agent-proof.modal.run";
const DISCOVERY = "https://oidc.modal.com/.well-known/openid-configuration";

const [taskId, base = DEFAULT_BASE] = process.argv.slice(2);
if (!taskId) {
  console.error("usage: verify-proof.mjs <task-id> [proof-base-url]");
  process.exit(2);
}

const b64url = (s) => Buffer.from(s.replace(/-/g, "+").replace(/_/g, "/"), "base64");

async function getJson(url) {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`${url} → ${res.status}`);
  return res.json();
}

/** Import one JWK and check one token's signature over its own header.payload. */
async function verify(token, keys) {
  const [h, p, sig] = token.split(".");
  if (!sig) throw new Error("not a JWT");
  const header = JSON.parse(b64url(h));
  const jwk = keys.find((k) => k.kid === header.kid);
  if (!jwk) throw new Error(`no key for kid ${header.kid}`);

  const { subtle } = globalThis.crypto;
  // RS256 is what Modal signs with; reject anything else rather than trusting
  // the token's own header to pick the algorithm for us.
  if (header.alg !== "RS256") throw new Error(`unexpected alg ${header.alg}`);
  const key = await subtle.importKey(
    "jwk", { ...jwk, alg: "RS256", ext: true }, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false, ["verify"],
  );
  const ok = await subtle.verify(
    "RSASSA-PKCS1-v1_5", key, b64url(sig), new TextEncoder().encode(`${h}.${p}`),
  );
  if (!ok) throw new Error("signature does not verify");
  return JSON.parse(b64url(p));
}

const manifest = await getJson(`${base}/proof/${encodeURIComponent(taskId)}`);
const discovery = await getJson(DISCOVERY);
const { keys } = await getJson(discovery.jwks_uri);

console.log(`task ${manifest.task_id} — completed ${manifest.completed_at}`);
console.log(`issuer ${discovery.issuer}\n`);

const containers = new Set();
let failures = 0;

for (const entry of manifest.sandboxes ?? []) {
  if (!entry.identity_token) {
    console.log(`✗ ${entry.sandbox_id}: no identity token`);
    failures += 1;
    continue;
  }
  try {
    const c = await verify(entry.identity_token, keys);
    containers.add(c.container_id);
    const issued = new Date(c.iat * 1000).toISOString();
    console.log(`✓ ${entry.sandbox_id}`);
    console.log(`    container  ${c.container_id}`);
    console.log(`    app        ${c.app_name} (${c.app_id})`);
    console.log(`    workspace  ${c.workspace_id} / ${c.environment_name}`);
    console.log(`    issued     ${issued}`);
  } catch (err) {
    console.log(`✗ ${entry.sandbox_id}: ${err.message}`);
    failures += 1;
  }
}

console.log(
  `\n${containers.size} distinct container(s) attested by ${discovery.issuer}` +
    (failures ? `, ${failures} entr(ies) failed` : ""),
);
process.exit(failures ? 1 : 0);
