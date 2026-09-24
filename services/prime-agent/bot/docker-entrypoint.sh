#!/bin/sh
# Take ownership of the state volume, then run the bot as an unprivileged user.
# Fly (and a fresh Docker volume) hands us /data owned by root; the bot only
# ever writes its did:key seed and delegation cert there.
set -e
mkdir -p "${FREEQ_STATE_DIR:-/data}"
chown -R node:node "${FREEQ_STATE_DIR:-/data}"
exec su-exec node "$@"
