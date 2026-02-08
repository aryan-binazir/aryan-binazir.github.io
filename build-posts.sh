#!/usr/bin/env bash
# ─────────────────────────────────────────────
# build-posts.sh
# Reads posts/*.md, parses frontmatter, and generates
# assets/js/posts-data.js (embedded post data).
#
# Run this after adding, editing, or removing a .md file:
#   ./build-posts.sh
# ─────────────────────────────────────────────
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
POSTS_DIR="$DIR/posts"
OUT="$DIR/assets/js/posts-data.js"

# Collect .md files
files=()
for f in "$POSTS_DIR"/*.md; do
  [ -f "$f" ] || continue
  files+=("$f")
done

if [ ${#files[@]} -eq 0 ]; then
  echo "window.POSTS_DATA = [];" > "$OUT"
  echo "✓ posts-data.js updated with 0 posts"
  exit 0
fi

# Start JS file
echo "window.POSTS_DATA = [" > "$OUT"

for i in "${!files[@]}"; do
  f="${files[$i]}"
  in_frontmatter=0
  past_frontmatter=0
  title=""
  date=""
  tag=""
  excerpt=""
  body=""

  while IFS= read -r line || [ -n "$line" ]; do
    # Detect frontmatter delimiters
    if [ "$past_frontmatter" -eq 0 ] && [ "$line" = "---" ]; then
      if [ "$in_frontmatter" -eq 0 ]; then
        in_frontmatter=1
        continue
      else
        past_frontmatter=1
        continue
      fi
    fi

    # Parse frontmatter key: value
    if [ "$in_frontmatter" -eq 1 ] && [ "$past_frontmatter" -eq 0 ]; then
      key="${line%%:*}"
      val="${line#*: }"
      # Strip surrounding quotes
      val="${val#\"}"
      val="${val%\"}"
      val="${val#\'}"
      val="${val%\'}"
      case "$key" in
        title)   title="$val" ;;
        date)    date="$val" ;;
        tag)     tag="$val" ;;
        excerpt) excerpt="$val" ;;
      esac
      continue
    fi

    # Accumulate body
    if [ "$past_frontmatter" -eq 1 ]; then
      body+="$line"$'\n'
    fi
  done < "$f"

  if [ "$in_frontmatter" -eq 0 ] || [ "$past_frontmatter" -eq 0 ]; then
    echo "Error: missing or malformed frontmatter in $f" >&2
    exit 1
  fi

  # JSON-escape the body: backslashes, quotes, newlines, tabs
  escaped_body=$(printf '%s' "$body" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read())[1:-1])')
  escaped_title=$(printf '%s' "$title" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read())[1:-1])')
  escaped_date=$(printf '%s' "$date" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read())[1:-1])')
  escaped_tag=$(printf '%s' "$tag" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read())[1:-1])')
  escaped_excerpt=$(printf '%s' "$excerpt" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read())[1:-1])')

  comma=","
  if [ "$i" -eq $(( ${#files[@]} - 1 )) ]; then
    comma=""
  fi

  cat >> "$OUT" <<ENTRY
  {
    "title": "${escaped_title}",
    "date": "${escaped_date}",
    "tag": "${escaped_tag}",
    "excerpt": "${escaped_excerpt}",
    "body": "${escaped_body}"
  }${comma}
ENTRY
done

echo "];" >> "$OUT"

echo "✓ posts-data.js updated with ${#files[@]} post(s)"
