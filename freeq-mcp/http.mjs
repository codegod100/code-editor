#!/usr/bin/env node
/**
 * FreeQ MCP connector over Streamable HTTP, for use as a claude.ai custom
 * connector (deployed by modal_app.py).
 *
 * The endpoint is /mcp/<FREEQ_MCP_TOKEN>: anyone holding that URL can post
 * handoffs as this server's bot, so treat it as a secret. Requests are
 * stateless; the bot and handoff registry live for the life of the process.
 */
import { timingSafeEqual } from 'node:crypto';
import { createServer } from 'node:http';
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';
import { createFreeqServer, log, serverUrl, stopBot } from './tools.mjs';

const token = process.env.FREEQ_MCP_TOKEN ?? '';
if (token.length < 32) throw new Error('FREEQ_MCP_TOKEN must be set to a random secret of at least 32 characters');
const port = Number(process.env.PORT || 8000);

function authorized(path) {
  const match = /^\/mcp\/([^/?]+)\/?$/.exec(path);
  if (!match) return false;
  const given = Buffer.from(match[1]);
  const expected = Buffer.from(token);
  return given.length === expected.length && timingSafeEqual(given, expected);
}

const httpServer = createServer(async (req, res) => {
  const path = new URL(req.url, 'http://localhost').pathname;
  if (path === '/health') {
    res.writeHead(200, { 'content-type': 'text/plain' }).end('ok');
    return;
  }
  if (!authorized(path)) {
    res.writeHead(404).end();
    return;
  }
  const mcp = createFreeqServer({ hosted: true });
  const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined });
  res.on('close', () => { transport.close(); mcp.close(); });
  try {
    await mcp.connect(transport);
    await transport.handleRequest(req, res);
  } catch (error) {
    log('request failed:', error.message ?? error);
    if (!res.headersSent) res.writeHead(500).end();
  }
});

async function shutdown() {
  httpServer.close();
  await stopBot('FreeQ MCP server stopped');
  process.exit(0);
}
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);

httpServer.listen(port, '0.0.0.0', () => log(`listening on :${port} (${serverUrl})`));
