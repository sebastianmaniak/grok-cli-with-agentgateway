#!/usr/bin/env bash
# Start standalone agentgateway. The real xAI key stays in a 600 file
# and is exported into this process only. Do not commit that file.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

SECRET="${AGW_SECRET_FILE:-$ROOT/.secrets/xai.env}"

if [[ ! -f "$SECRET" ]]; then
  echo "missing $SECRET" >&2
  echo "create it with mode 600 and one line: export XAI_API_KEY=..." >&2
  exit 1
fi

# shellcheck disable=SC1090
set -a
# source the 600 file
. "$SECRET"
set +a

if [[ -z "${XAI_API_KEY:-}" ]]; then
  echo "XAI_API_KEY is empty after sourcing $SECRET" >&2
  exit 1
fi

exec agentgateway -f "$ROOT/agentgateway.yaml"
