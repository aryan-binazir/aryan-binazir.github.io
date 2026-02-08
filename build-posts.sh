#!/usr/bin/env bash
# ─────────────────────────────────────────────
# build-posts.sh
# Reads posts/*.md, parses frontmatter, and:
#   1. Generates blog/<slug>/index.html for each post
#   2. Generates assets/js/posts-data.js (listing metadata only)
#
# Run after adding, editing, or removing a .md file:
#   ./build-posts.sh
# ─────────────────────────────────────────────
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
POSTS_DIR="$DIR/posts"
BLOG_DIR="$DIR/blog"
DATA_OUT="$DIR/assets/js/posts-data.js"
SITE_URL="https://aryanbinazir.dev"
MANIFEST_FILE="$BLOG_DIR/.generated-post-slugs"

if ! command -v python3 >/dev/null 2>&1; then
  echo "✗ python3 is required to build blog posts." >&2
  exit 1
fi

# ── Slug from filename ──
make_slug() {
  local name
  name="$(basename "$1" .md)"
  # lowercase, spaces/underscores to hyphens, strip unsafe chars, collapse hyphens
  echo "$name" | tr '[:upper:]' '[:lower:]' | tr ' _' '-' | sed 's/[^a-z0-9-]//g; s/--*/-/g; s/^-//; s/-$//'
}

# ── HTML-escape ──
html_escape() {
  python3 -c "
import sys, html
print(html.escape(sys.stdin.read(), quote=True), end='')
" <<< "$1"
}

# ── JSON-escape ──
json_escape() {
  printf '%s' "$1" | python3 -c '
import sys, json
s = json.dumps(sys.stdin.read())[1:-1]
s = s.replace("<", "\\u003c").replace(">", "\\u003e").replace("&", "\\u0026")
s = s.replace("\u2028", "\\u2028").replace("\u2029", "\\u2029")
print(s, end="")
'
}

# ── Collect posts ──
files=()
for f in "$POSTS_DIR"/*.md; do
  [ -f "$f" ] || continue
  files+=("$f")
done

if [ ${#files[@]} -eq 0 ]; then
  echo "window.POSTS_DATA = [];" > "$DATA_OUT"
  echo "⚠ No .md files found in posts/"
  exit 0
fi

# ── Parse all posts, check for errors and duplicate slugs ──
declare -A seen_slugs
all_titles=()
all_dates=()
all_tags=()
all_excerpts=()
all_slugs=()
all_bodies=()

for f in "${files[@]}"; do
  in_fm=0; past_fm=0
  line_no=0
  title=""; date=""; tag=""; excerpt=""; body=""

  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))

    if [ "$past_fm" -eq 0 ] && [ "$line" = "---" ]; then
      if [ "$in_fm" -eq 0 ]; then in_fm=1; continue; else past_fm=1; continue; fi
    fi
    if [ "$in_fm" -eq 1 ] && [ "$past_fm" -eq 0 ]; then
      if [[ "$line" =~ ^[[:space:]]*$ ]] || [[ "$line" =~ ^[[:space:]]*# ]]; then
        continue
      fi
      if [[ "$line" =~ ^[[:space:]]+ ]]; then
        echo "✗ $(basename "$f") has unsupported indented/multiline frontmatter at line $line_no" >&2
        exit 1
      fi
      if [[ "$line" != *:* ]]; then
        echo "✗ $(basename "$f") has malformed frontmatter at line $line_no: '$line'" >&2
        exit 1
      fi

      key="${line%%:*}"
      raw_val="${line#*:}"
      key="${key%"${key##*[![:space:]]}"}"
      val="${raw_val#"${raw_val%%[![:space:]]*}"}"

      if [ -z "$key" ]; then
        echo "✗ $(basename "$f") has empty frontmatter key at line $line_no" >&2
        exit 1
      fi
      if [[ "$val" == "|" || "$val" == ">" || "$val" == "|-" || "$val" == "|+" || "$val" == ">-" || "$val" == ">+" ]]; then
        echo "✗ $(basename "$f") uses unsupported multiline frontmatter for '$key' at line $line_no" >&2
        exit 1
      fi

      if [[ "$val" =~ ^\".*\"$ ]]; then
        val="${val:1:${#val}-2}"
      elif [[ "$val" =~ ^\'.*\'$ ]]; then
        val="${val:1:${#val}-2}"
      fi

      case "$key" in
        title)   title="$val" ;;
        date)    date="$val" ;;
        tag)     tag="$val" ;;
        excerpt) excerpt="$val" ;;
      esac
      continue
    fi
    if [ "$past_fm" -eq 1 ]; then body+="$line"$'\n'; fi
  done < "$f"

  if [ "$in_fm" -eq 0 ]; then
    echo "✗ $(basename "$f") is missing opening frontmatter delimiter '---'" >&2
    exit 1
  fi
  if [ "$past_fm" -eq 0 ]; then
    echo "✗ $(basename "$f") is missing closing frontmatter delimiter '---'" >&2
    exit 1
  fi

  # Validate required fields
  fname="$(basename "$f")"
  missing=""
  [ -z "$title" ]   && missing+="title "
  [ -z "$date" ]    && missing+="date "
  [ -z "$tag" ]     && missing+="tag "
  [ -z "$excerpt" ] && missing+="excerpt "
  if [ -n "$missing" ]; then
    echo "✗ $fname is missing required frontmatter: $missing" >&2
    exit 1
  fi
  if ! [[ "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    echo "✗ $fname has invalid date '$date' (expected YYYY-MM-DD)" >&2
    exit 1
  fi

  slug="$(make_slug "$f")"
  if [ -z "$slug" ]; then
    echo "✗ $fname produced an empty slug" >&2
    exit 1
  fi
  if [ -n "${seen_slugs[$slug]+x}" ]; then
    echo "✗ Duplicate slug '$slug' from $fname (conflicts with ${seen_slugs[$slug]})" >&2
    exit 1
  fi
  seen_slugs[$slug]="$fname"

  all_titles+=("$title")
  all_dates+=("$date")
  all_tags+=("$tag")
  all_excerpts+=("$excerpt")
  all_slugs+=("$slug")
  all_bodies+=("$body")
done

# ── Clean old generated blog dirs (tracked via manifest) ──
if [ -f "$MANIFEST_FILE" ]; then
  while IFS= read -r old_slug || [ -n "$old_slug" ]; do
    [ -n "$old_slug" ] || continue
    if [[ "$old_slug" =~ ^[a-z0-9-]+$ ]] && [ -d "$BLOG_DIR/$old_slug" ]; then
      rm -rf "$BLOG_DIR/$old_slug"
    fi
  done < "$MANIFEST_FILE"
fi
mkdir -p "$BLOG_DIR"

# ── Generate pages ──
for i in "${!all_slugs[@]}"; do
  slug="${all_slugs[$i]}"
  title="${all_titles[$i]}"
  date="${all_dates[$i]}"
  tag="${all_tags[$i]}"
  excerpt="${all_excerpts[$i]}"
  body="${all_bodies[$i]}"

  # Escaped versions for HTML attributes / content
  title_h="$(html_escape "$title")"
  excerpt_h="$(html_escape "$excerpt")"
  tag_h="$(html_escape "$tag")"
  body_json="$(json_escape "$body")"

  # Format display date
  display_date="$(python3 - "$date" <<'__DISPLAY_DATE_PY_EOF__'
from datetime import datetime
import sys

date_str = sys.argv[1]
try:
    dt = datetime.strptime(date_str, "%Y-%m-%d")
except ValueError:
    sys.stderr.write(f"Invalid date '{date_str}' (expected YYYY-MM-DD).\n")
    sys.exit(1)

months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
          "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
print(f"{months[dt.month - 1]} {dt.day}, {dt.year}")
__DISPLAY_DATE_PY_EOF__
)"

  post_dir="$BLOG_DIR/$slug"
  mkdir -p "$post_dir"

  cat > "$post_dir/index.html" <<__POST_TEMPLATE_ARYAN_BINAZIR_EOF__
<!DOCTYPE html>
<html lang="en">
  <head>
    <title>${title_h} &ndash; Aryan Binazir</title>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <meta name="description" content="${excerpt_h}" />
    <link rel="canonical" href="${SITE_URL}/blog/${slug}/" />
    <!-- Open Graph -->
    <meta property="og:type" content="article" />
    <meta property="og:title" content="${title_h}" />
    <meta property="og:description" content="${excerpt_h}" />
    <meta property="og:url" content="${SITE_URL}/blog/${slug}/" />
    <meta property="article:published_time" content="${date}" />
    <!-- Twitter -->
    <meta name="twitter:card" content="summary" />
    <meta name="twitter:title" content="${title_h}" />
    <meta name="twitter:description" content="${excerpt_h}" />
    <link rel="icon" type="image/x-icon" href="../../images/Favicon.ico" />
    <link rel="icon" type="image/svg+xml" href="../../images/favicon.svg" />
    <link rel="preconnect" href="https://fonts.googleapis.com" />
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
    <link
      href="https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@400;500;600;700&family=Sora:wght@300;400;500;600;700&display=swap"
      rel="stylesheet"
    />
    <link rel="stylesheet" href="../../assets/css/fontawesome-all.min.css" />
    <style>
      :root {
        --bg: #0b0f14; --bg-alt: #111823; --ink: #e8edf2; --muted: #a1a9b5;
        --accent: #d28c62; --accent-2: #6fb8c9; --card: #141d28;
        --border: #2a3443; --panel: #101720;
        --shadow: 0 24px 60px rgba(0,0,0,0.55);
        --shadow-soft: 0 12px 32px rgba(0,0,0,0.35);
        --scroll-offset: 84px;
      }
      *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
      html { font-size: 86%; scroll-behavior: smooth; }
      body {
        min-height: 100vh; font-family: 'Sora', sans-serif; color: var(--ink);
        background: linear-gradient(140deg, var(--bg) 0%, #0f151d 45%, var(--bg-alt) 100%);
        line-height: 1.65;
      }
      body::before, body::after {
        content: ''; position: fixed; inset: 0; pointer-events: none; z-index: 0;
      }
      body::before { background: radial-gradient(600px circle at 12% 0%, rgba(210,140,98,0.14), transparent 60%); }
      body::after  { background: radial-gradient(700px circle at 85% 8%, rgba(111,184,201,0.12), transparent 55%); }
      img { max-width: 100%; display: block; }
      a { color: inherit; text-decoration: none; }
      ul { list-style: none; }
      .page {
        position: relative; z-index: 1;
        background-image: radial-gradient(rgba(255,255,255,0.025) 0.6px, transparent 0.6px);
        background-size: 18px 18px;
      }
      .container { width: min(1120px, 92vw); margin: 0 auto; }

      /* ── HEADER ── */
      .site-header {
        position: sticky; top: 0; z-index: 10;
        background: rgba(11,15,20,0.9); border-bottom: 1px solid var(--border);
        backdrop-filter: blur(12px); -webkit-backdrop-filter: blur(12px);
      }
      .header-inner { display: flex; align-items: center; justify-content: space-between; padding: 0.85rem 0; }
      .header-brand { font-family: 'Space Grotesk', sans-serif; font-size: 1.15rem; font-weight: 700; color: var(--ink); letter-spacing: -0.01em; white-space: nowrap; }
      .header-right { display: flex; align-items: center; gap: 1.5rem; }
      .text-nav { display: flex; gap: 1.6rem; }
      .text-nav a { font-size: 0.9rem; font-weight: 500; color: var(--muted); transition: color 0.2s; }
      .text-nav a:hover { color: var(--accent-2); }
      .text-nav a.active { color: var(--accent-2); }
      .nav-divider { width: 1px; height: 22px; background: var(--border); }
      .icon-nav { display: flex; align-items: center; gap: 0.65rem; }
      .icon-nav li { display: flex; }
      .icon-nav .icon {
        position: relative; display: inline-flex; align-items: center; justify-content: center;
        width: 38px; height: 38px; border-radius: 999px; border: 1px solid var(--border);
        background: rgba(20,29,40,0.92); box-shadow: var(--shadow-soft); font-size: 0.95rem;
        transition: transform 0.2s, box-shadow 0.2s, border-color 0.2s;
      }
      .icon-nav .icon:hover { transform: translateY(-2px); box-shadow: var(--shadow); border-color: rgba(111,184,201,0.6); }
      .icon-nav .label { position: absolute; width: 1px; height: 1px; padding: 0; margin: -1px; overflow: hidden; clip: rect(0,0,0,0); white-space: nowrap; border: 0; }

      /* ── POST LAYOUT ── */
      .post-header { padding: clamp(3rem, 6vw, 5rem) 0 clamp(1.5rem, 3vw, 2rem); }
      .back-link { display: inline-flex; align-items: center; gap: 0.4rem; font-size: 0.9rem; font-weight: 500; color: var(--accent-2); margin-bottom: 1.5rem; transition: color 0.2s, gap 0.2s; }
      .back-link:hover { color: var(--accent); gap: 0.6rem; }
      .post-header h1 {
        font-family: 'Space Grotesk', sans-serif; font-size: clamp(2rem, 3.5vw, 3rem);
        line-height: 1.15; letter-spacing: -0.02em; margin-bottom: 0.75rem; max-width: 40ch;
      }
      .post-header .post-meta { display: flex; align-items: center; gap: 1rem; font-size: 0.85rem; color: var(--muted); }
      .post-tag {
        display: inline-block; padding: 0.2rem 0.7rem; border-radius: 999px;
        border: 1px solid var(--border); background: var(--panel);
        font-size: 0.78rem; font-weight: 500; color: var(--accent-2);
      }

      /* ── POST BODY ── */
      .post-content { padding: 0 0 clamp(4rem, 7vw, 6rem); }
      .post-body { color: var(--muted); font-size: 0.98rem; line-height: 1.75; max-width: 72ch; }
      .post-body h2 { font-family: 'Space Grotesk', sans-serif; color: var(--ink); font-size: 1.25rem; margin: 1.8rem 0 0.6rem; }
      .post-body h3 { font-family: 'Space Grotesk', sans-serif; color: var(--ink); font-size: 1.1rem; margin: 1.4rem 0 0.5rem; }
      .post-body p { margin: 0.8rem 0; }
      .post-body code { background: var(--panel); border: 1px solid var(--border); border-radius: 6px; padding: 0.15rem 0.45rem; font-size: 0.88rem; color: var(--accent); }
      .post-body pre { background: var(--panel); border: 1px solid var(--border); border-radius: 14px; padding: 1.2rem 1.5rem; overflow-x: auto; margin: 1.2rem 0; }
      .post-body pre code { background: none; border: none; padding: 0; font-size: 0.86rem; color: var(--ink); }
      .post-body ul, .post-body ol { list-style: disc; padding-left: 1.5rem; margin: 0.8rem 0; }
      .post-body ol { list-style: decimal; }
      .post-body li { margin-bottom: 0.4rem; }
      .post-body blockquote { border-left: 3px solid var(--accent-2); padding: 0.8rem 1.2rem; margin: 1.2rem 0; background: rgba(111,184,201,0.05); border-radius: 0 12px 12px 0; font-style: italic; color: var(--ink); }
      .post-body a { color: var(--accent-2); text-decoration: underline; text-underline-offset: 2px; }
      .post-body a:hover { color: var(--accent); }
      .post-body hr { border: none; border-top: 1px solid var(--border); margin: 2rem 0; }
      .post-body img { border-radius: 14px; margin: 1.2rem 0; }

      /* ── FOOTER ── */
      .site-footer { border-top: 1px solid var(--border); padding: 2.8rem 0 3.5rem; background: rgba(11,15,20,0.65); }
      .footer-inner { display: flex; align-items: center; justify-content: space-between; gap: 1.5rem; flex-wrap: wrap; }
      .footer-meta { display: flex; gap: 1.5rem; color: var(--muted); font-size: 0.95rem; }

      /* ── RESPONSIVE ── */
      @media (max-width: 960px) { .header-inner { justify-content: center; } .header-brand { display: none; } .header-right { width: 100%; justify-content: center; } }
      @media (max-width: 700px) { .icon-nav { flex-wrap: wrap; justify-content: center; } .text-nav { gap: 1rem; } .text-nav a { font-size: 0.82rem; } .nav-divider { display: none; } .site-header { position: static; } .header-right { flex-wrap: wrap; justify-content: center; gap: 0.75rem; } .footer-inner { justify-content: center; } }
      @media (prefers-reduced-motion: reduce) { html { scroll-behavior: auto; } }
    </style>
  </head>
  <body class="site">
    <div class="page">
      <header class="site-header">
        <div class="container header-inner">
          <a href="../../index.html" class="header-brand">Aryan Binazir</a>
          <div class="header-right">
            <nav class="text-nav" aria-label="Main navigation">
              <a href="../../index.html#triage">Triage</a>
              <a href="../../index.html#projects">Projects</a>
              <a href="../../blog.html" class="active">Blog</a>
            </nav>
            <span class="nav-divider"></span>
            <nav class="icon-nav" aria-label="Social links">
              <a target="_blank" rel="noopener noreferrer" href="https://www.linkedin.com/in/aryanbinazir/" class="icon fab fa-linkedin-in" aria-label="LinkedIn" title="LinkedIn"><span class="label">LinkedIn</span></a>
              <a target="_blank" rel="noopener noreferrer" href="https://github.com/aryan-binazir" class="icon fab fa-github" aria-label="GitHub" title="GitHub"><span class="label">GitHub</span></a>
              <a target="_blank" rel="noopener noreferrer" href="../../assets/Aryan-Binazir-Resume.pdf" class="icon fas fa-file-alt" aria-label="Resume" title="Resume"><span class="label">Resume</span></a>
              <a href="mailto:abinazir@gmail.com" class="icon fas fa-envelope" aria-label="Email" title="Email"><span class="label">Email</span></a>
            </nav>
          </div>
        </div>
      </header>

      <main>
        <section class="post-header">
          <div class="container">
            <a href="../../blog.html" class="back-link">&larr; All posts</a>
            <h1>${title_h}</h1>
            <div class="post-meta">
              <span class="post-tag">${tag_h}</span>
              <time datetime="${date}">${display_date}</time>
            </div>
          </div>
        </section>
        <section class="post-content">
          <div class="container">
            <div class="post-body" id="post-body"></div>
          </div>
        </section>
      </main>

      <footer class="site-footer">
        <div class="container footer-inner">
          <ul class="icon-nav" aria-label="Footer social links">
            <li><a target="_blank" rel="noopener noreferrer" href="https://www.linkedin.com/in/aryanbinazir/" class="icon fab fa-linkedin-in" aria-label="LinkedIn" title="LinkedIn"><span class="label">LinkedIn</span></a></li>
            <li><a target="_blank" rel="noopener noreferrer" href="https://github.com/aryan-binazir" class="icon fab fa-github" aria-label="GitHub" title="GitHub"><span class="label">GitHub</span></a></li>
            <li><a target="_blank" rel="noopener noreferrer" href="../../assets/Aryan-Binazir-Resume.pdf" class="icon fas fa-file-alt" aria-label="Resume" title="Resume"><span class="label">Resume</span></a></li>
            <li><a href="mailto:abinazir@gmail.com" class="icon fas fa-envelope" aria-label="Email" title="Email"><span class="label">Email</span></a></li>
          </ul>
          <ul class="footer-meta"><li>&copy; Aryan Binazir</li></ul>
        </div>
      </footer>
    </div>

    <script src="../../assets/js/marked.min.js"></script>
    <script>
      (() => {
        const markdownSource = "${body_json}";

        function isSafeUrl(urlValue) {
          if (!urlValue) return false;
          if (
            urlValue.startsWith('#') ||
            urlValue.startsWith('/') ||
            urlValue.startsWith('./') ||
            urlValue.startsWith('../')
          ) return true;
          try {
            const parsed = new URL(urlValue, window.location.href);
            return ['http:', 'https:', 'mailto:', 'tel:'].includes(parsed.protocol);
          } catch {
            return false;
          }
        }

        function sanitizeHtml(inputHtml) {
          const template = document.createElement('template');
          template.innerHTML = inputHtml;

          template.content.querySelectorAll('script, iframe, object, embed, meta, link, base, form, style').forEach((node) => {
            node.remove();
          });

          template.content.querySelectorAll('*').forEach((element) => {
            Array.from(element.attributes).forEach((attribute) => {
              const name = attribute.name.toLowerCase();
              const value = attribute.value.trim();

              if (name.startsWith('on')) {
                element.removeAttribute(attribute.name);
                return;
              }

              if (name === 'style' || name === 'srcdoc' || name === 'srcset') {
                element.removeAttribute(attribute.name);
                return;
              }

              if (name === 'href' || name === 'src' || name === 'xlink:href') {
                if (!isSafeUrl(value)) {
                  element.removeAttribute(attribute.name);
                }
              }
            });
          });

          return template.innerHTML;
        }

        const renderedHtml = marked.parse(markdownSource);
        document.getElementById('post-body').innerHTML = sanitizeHtml(renderedHtml);
      })();
    </script>
  </body>
</html>
__POST_TEMPLATE_ARYAN_BINAZIR_EOF__

  echo "  ✓ blog/$slug/index.html"
done

# Track generated slugs so future builds only delete generated post dirs.
{
  for slug in "${all_slugs[@]}"; do
    echo "$slug"
  done
} > "$MANIFEST_FILE"

# ── Generate listing data (metadata only, no body) ──
echo "window.POSTS_DATA = [" > "$DATA_OUT"
for i in "${!all_slugs[@]}"; do
  comma=","
  if [ "$i" -eq $(( ${#all_slugs[@]} - 1 )) ]; then comma=""; fi

  escaped_title="$(json_escape "${all_titles[$i]}")"
  escaped_date="$(json_escape "${all_dates[$i]}")"
  escaped_tag="$(json_escape "${all_tags[$i]}")"
  escaped_excerpt="$(json_escape "${all_excerpts[$i]}")"

  cat >> "$DATA_OUT" <<__POSTS_DATA_JSON_ITEM_EOF__
  {
    "title": "${escaped_title}",
    "date": "${escaped_date}",
    "tag": "${escaped_tag}",
    "excerpt": "${escaped_excerpt}",
    "slug": "${all_slugs[$i]}",
    "url": "blog/${all_slugs[$i]}/index.html"
  }${comma}
__POSTS_DATA_JSON_ITEM_EOF__
done
echo "];" >> "$DATA_OUT"

echo "✓ ${#all_slugs[@]} post(s) built → blog/*/index.html + assets/js/posts-data.js"
