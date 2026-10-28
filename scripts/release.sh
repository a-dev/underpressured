#!/usr/bin/env bash
# Create an unpublished local release candidate. Never uploads assets or feeds.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$ROOT/scripts/release.py" "$@"
