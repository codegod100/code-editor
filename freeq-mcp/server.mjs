#!/usr/bin/env node
/**
 * FreeQ MCP connector for Claude Code, over stdio.
 *
 * Claude Code launches this for the life of a session (see .mcp.json). The
 * tools act on the session's own checkout; http.mjs serves the hosted variant.
 */
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { createFreeqServer, log, serverUrl, stopBot } from './tools.mjs';

async function shutdown() {
  await stopBot('Claude Code session ended');
  process.exit(0);
}
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
process.stdin.on('close', shutdown);

await createFreeqServer().connect(new StdioServerTransport());
log(`ready (${serverUrl})`);
