#!/usr/bin/env bash
set -euo pipefail

command -v python3 >/dev/null 2>&1 || {
  echo "python3 not found in PATH" >&2
  exit 1
}

DIR="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$DIR/scripts/build_posts.py" "$@"
