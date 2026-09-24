#!/usr/bin/env bash
# Create (or explicitly rotate) the cookie-signing secret for the Modal app.
set -euo pipefail

if [[ "${1:-}" == "--replace" ]]; then
  force=(--force)
elif [[ $# -eq 0 ]]; then
  force=()
else
  printf 'Usage: %s [--replace]\n' "$0" >&2
  exit 2
fi

command -v modal >/dev/null || {
  printf 'Modal CLI is required. Install it and authenticate first.\n' >&2
  exit 1
}
command -v openssl >/dev/null || {
  printf 'OpenSSL is required to generate SESSION_SECRET.\n' >&2
  exit 1
}

# Keep the value out of terminal output and shell history.
session_secret="$(openssl rand -base64 48 | tr -d '\n')"
modal secret create --env main "${force[@]}" code-editor-session \
  "SESSION_SECRET=${session_secret}"

printf 'Modal session secret configured. Deploy to apply it.\n'
if [[ ${#force[@]} -ne 0 ]]; then
  printf 'Existing browser sessions will be invalidated after the next deployment.\n'
fi
