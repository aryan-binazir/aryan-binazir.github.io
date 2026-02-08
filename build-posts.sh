#!/usr/bin/env bash
# ─────────────────────────────────────────────
# build-posts.sh
# Scans posts/*.md and regenerates posts/posts.json
# Run this after adding or removing a .md file:
#   ./build-posts.sh
# ─────────────────────────────────────────────
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
POSTS_DIR="$DIR/posts"
OUT="$POSTS_DIR/posts.json"

# Collect all .md filenames (basename only)
files=()
for f in "$POSTS_DIR"/*.md; do
  [ -f "$f" ] || continue
  files+=("$(basename "$f")")
done

# Write JSON array
echo "[" > "$OUT"
for i in "${!files[@]}"; do
  comma=","
  if [ "$i" -eq $(( ${#files[@]} - 1 )) ]; then
    comma=""
  fi
  echo "  \"${files[$i]}\"$comma" >> "$OUT"
done
echo "]" >> "$OUT"

echo "✓ posts.json updated with ${#files[@]} post(s)"
