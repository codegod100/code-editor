#!/bin/sh
# Launch the FreeQ MCP connector, installing its dependencies on first use.
# stdout carries the MCP protocol, so everything else goes to stderr.
set -e
dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ ! -d "$dir/node_modules/@modelcontextprotocol/sdk" ]; then
  npm ci --prefix "$dir" --omit=dev --no-audit --no-fund >&2
fi
exec node "$dir/server.mjs"
