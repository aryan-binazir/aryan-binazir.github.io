#!/usr/bin/env python3
"""Build static findings pages and metadata from posts/*.md.

Frontmatter format is intentionally strict and line-oriented:
- opening delimiter on the first line: ---
- closing delimiter line: ---
- only single-line key:value entries (no YAML multiline blocks)
- no indentation in frontmatter lines

Supported keys:
- title (required)
- date (required, YYYY-MM-DD and semantically valid)
- tag (required)
- excerpt (required)
- published (optional boolean; defaults to true)
"""

from __future__ import annotations

import argparse
import calendar
import html
import json
import re
import shutil
import sys
import unicodedata
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Iterable

SITE_URL = "https://aryanbinazir.dev"
GENERATED_MARKER = "GENERATED_BY_BUILD_POSTS_SH"
MANIFEST_FILENAME = ".generated-post-slugs"
DATE_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
SLUG_RE = re.compile(r"^[a-z0-9-]+$")
MULTILINE_MARKERS = {"|", ">", "|-", "|+", ">-", ">+"}
MAX_TITLE_LENGTH = 120
MAX_EXCERPT_LENGTH = 300
MAX_TAG_LENGTH = 50


class BuildError(Exception):
    """Expected build validation error."""


@dataclass
class ParsedPost:
    source_path: Path
    source_name: str
    slug: str
    title: str
    date_iso: str
    display_date: str
    tag: str
    excerpt: str
    body_markdown: str
    published: bool


def make_slug(path: Path) -> str:
    normalized = unicodedata.normalize("NFKD", path.stem)
    ascii_name = normalized.encode("ascii", "ignore").decode("ascii")
    name = ascii_name.lower().replace(" ", "-").replace("_", "-")
    name = re.sub(r"[^a-z0-9-]", "", name)
    name = re.sub(r"-+", "-", name).strip("-")
    return name


def parse_boolean(value: str, source_name: str, line_no: int, key: str) -> bool:
    lowered = value.strip().lower()
    mapping = {
        "true": True,
        "false": False,
        "yes": True,
        "no": False,
        "1": True,
        "0": False,
    }
    if lowered not in mapping:
        raise BuildError(
            f"✗ {source_name} has invalid boolean for '{key}' at line {line_no}: '{value}' "
            "(expected true/false)"
        )
    return mapping[lowered]


def parse_frontmatter_value(raw_value: str, source_name: str, line_no: int, key: str) -> str:
    value = raw_value.lstrip().rstrip()

    if value in MULTILINE_MARKERS:
        raise BuildError(
            f"✗ {source_name} uses unsupported multiline frontmatter for '{key}' at line {line_no}"
        )

    if not value:
        return ""

    if value.startswith('"'):
        if len(value) < 2 or not value.endswith('"'):
            raise BuildError(
                f"✗ {source_name} has unmatched double quote for '{key}' at line {line_no}"
            )
        try:
            parsed = json.loads(value)
        except json.JSONDecodeError as exc:
            raise BuildError(
                f"✗ {source_name} has invalid quoted value for '{key}' at line {line_no}: {exc.msg}"
            ) from exc
        if not isinstance(parsed, str):
            raise BuildError(
                f"✗ {source_name} has non-string quoted value for '{key}' at line {line_no}"
            )
        return parsed

    if value.startswith("'"):
        if len(value) < 2 or not value.endswith("'"):
            raise BuildError(f"✗ {source_name} has unmatched single quote for '{key}' at line {line_no}")
        # YAML single-quoted strings escape apostrophes by doubling them.
        return value[1:-1].replace("''", "'")

    return value


def parse_display_date(date_value: str, source_name: str) -> str:
    if not DATE_RE.fullmatch(date_value):
        raise BuildError(f"✗ {source_name} has invalid date '{date_value}' (expected YYYY-MM-DD)")
    try:
        dt = datetime.strptime(date_value, "%Y-%m-%d")
    except ValueError:
        raise BuildError(f"✗ {source_name} has invalid calendar date '{date_value}'")
    return f"{calendar.month_abbr[dt.month]} {dt.day}, {dt.year}"


def validate_field_length(value: str, field: str, max_length: int, source_name: str) -> None:
    if len(value) > max_length:
        raise BuildError(
            f"✗ {source_name} field '{field}' exceeds {max_length} characters "
            f"(got {len(value)})"
        )


def parse_post(path: Path) -> ParsedPost:
    source_name = path.name
    try:
        raw = path.read_text(encoding="utf-8")
    except UnicodeDecodeError as exc:
        raise BuildError(f"✗ {source_name} has invalid UTF-8 encoding: {exc}") from exc
    lines = raw.splitlines(keepends=True)

    if not lines or lines[0].rstrip("\r\n") != "---":
        raise BuildError(f"✗ {source_name} is missing opening frontmatter delimiter '---'")

    closing_index = None
    for idx in range(1, len(lines)):
        if lines[idx].rstrip("\r\n") == "---":
            closing_index = idx
            break

    if closing_index is None:
        raise BuildError(f"✗ {source_name} is missing closing frontmatter delimiter '---'")

    values: dict[str, str] = {
        "title": "",
        "date": "",
        "tag": "",
        "excerpt": "",
    }
    published = True
    seen_keys: set[str] = set()

    for idx, raw_line in enumerate(lines[1:closing_index], start=2):
        line = raw_line.rstrip("\r\n")

        if not line.strip() or line.lstrip().startswith("#"):
            continue

        if re.match(r"^[\t ]+", line):
            raise BuildError(
                f"✗ {source_name} has unsupported indented/multiline frontmatter at line {idx}"
            )

        if ":" not in line:
            raise BuildError(f"✗ {source_name} has malformed frontmatter at line {idx}: '{line}'")

        key_part, _, value_part = line.partition(":")
        key = key_part.strip()

        if not key:
            raise BuildError(f"✗ {source_name} has empty frontmatter key at line {idx}")

        if key in seen_keys:
            raise BuildError(f"✗ {source_name} has duplicate frontmatter key '{key}' at line {idx}")
        seen_keys.add(key)

        value = parse_frontmatter_value(value_part, source_name, idx, key)

        if key in values:
            values[key] = value
            continue

        if key == "published":
            published = parse_boolean(value, source_name, idx, key)
            continue

        raise BuildError(f"✗ {source_name} has unsupported frontmatter key '{key}' at line {idx}")

    missing = [name for name, val in values.items() if not val.strip()]
    if missing:
        missing_fields = " ".join(missing)
        raise BuildError(f"✗ {source_name} is missing required frontmatter: {missing_fields}")

    validate_field_length(values["title"], "title", MAX_TITLE_LENGTH, source_name)
    validate_field_length(values["excerpt"], "excerpt", MAX_EXCERPT_LENGTH, source_name)
    validate_field_length(values["tag"], "tag", MAX_TAG_LENGTH, source_name)

    display_date = parse_display_date(values["date"], source_name)

    slug = make_slug(path)
    if not slug:
        raise BuildError(f"✗ {source_name} produced an empty slug")

    body_markdown = "".join(lines[closing_index + 1 :])
    if not body_markdown.strip():
        raise BuildError(f"✗ {source_name} has an empty markdown body")

    return ParsedPost(
        source_path=path,
        source_name=source_name,
        slug=slug,
        title=values["title"],
        date_iso=values["date"],
        display_date=display_date,
        tag=values["tag"],
        excerpt=values["excerpt"],
        body_markdown=body_markdown,
        published=published,
    )


def cleanup_generated_findings_dirs(findings_dir: Path, manifest_file: Path, keep_slugs: set[str]) -> None:
    findings_dir.mkdir(parents=True, exist_ok=True)

    if manifest_file.exists():
        try:
            manifest_lines = manifest_file.read_text(encoding="utf-8").splitlines()
        except (OSError, UnicodeDecodeError) as exc:
            print(f"⚠ Could not read manifest {manifest_file}: {exc}", file=sys.stderr)
            manifest_lines = []
        for old_slug in manifest_lines:
            old_slug = old_slug.strip()
            if not old_slug:
                continue
            if old_slug in keep_slugs:
                continue
            if not SLUG_RE.fullmatch(old_slug):
                continue
            old_dir = findings_dir / old_slug
            if old_dir.is_dir():
                shutil.rmtree(old_dir)

    for child in findings_dir.iterdir():
        if not child.is_dir():
            continue
        slug = child.name
        if not SLUG_RE.fullmatch(slug):
            continue
        if slug in keep_slugs:
            continue

        index_html = child / "index.html"
        if not index_html.is_file():
            continue

        try:
            contents = index_html.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue

        if GENERATED_MARKER in contents:
            shutil.rmtree(child)


def render_post_html(post: ParsedPost) -> str:
    title_h = html.escape(post.title, quote=True)
    excerpt_h = html.escape(post.excerpt, quote=True)
    tag_h = html.escape(post.tag, quote=True)
    body_markdown_h = html.escape(post.body_markdown)

    lines = [
        "<!DOCTYPE html>",
        f"<!-- {GENERATED_MARKER} -->",
        "<html lang=\"en\">",
        "  <head>",
        f"    <title>{title_h} &ndash; Aryan Binazir</title>",
        "    <meta charset=\"utf-8\" />",
        "    <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\" />",
        "    <meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; img-src 'self' https:; object-src 'none'; base-uri 'self'\" />",
        f"    <meta name=\"description\" content=\"{excerpt_h}\" />",
        f"    <link rel=\"canonical\" href=\"{SITE_URL}/findings/{post.slug}/\" />",
        "    <!-- Open Graph -->",
        "    <meta property=\"og:type\" content=\"article\" />",
        f"    <meta property=\"og:title\" content=\"{title_h}\" />",
        f"    <meta property=\"og:description\" content=\"{excerpt_h}\" />",
        f"    <meta property=\"og:url\" content=\"{SITE_URL}/findings/{post.slug}/\" />",
        f"    <meta property=\"article:published_time\" content=\"{post.date_iso}\" />",
        "    <!-- Twitter -->",
        "    <meta name=\"twitter:card\" content=\"summary\" />",
        f"    <meta name=\"twitter:title\" content=\"{title_h}\" />",
        f"    <meta name=\"twitter:description\" content=\"{excerpt_h}\" />",
        "    <link rel=\"icon\" type=\"image/x-icon\" href=\"../../images/Favicon.ico\" />",
        "    <link rel=\"icon\" type=\"image/svg+xml\" href=\"../../images/favicon.svg\" />",
        "    <link rel=\"preconnect\" href=\"https://fonts.googleapis.com\" />",
        "    <link rel=\"preconnect\" href=\"https://fonts.gstatic.com\" crossorigin />",
        "    <link",
        "      href=\"https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@400;500;600;700&family=Sora:wght@300;400;500;600;700&display=swap\"",
        "      rel=\"stylesheet\"",
        "    />",
        "    <link rel=\"stylesheet\" href=\"../../assets/css/fontawesome-all.min.css\" />",
        "    <link rel=\"stylesheet\" href=\"../../assets/css/site-shared.css\" />",
        "    <link rel=\"stylesheet\" href=\"../../assets/css/findings-post.css\" />",
        "  </head>",
        "  <body class=\"site\">",
        "    <div class=\"page\">",
        "      <header class=\"site-header\">",
        "        <div class=\"container header-inner\">",
        "          <a href=\"../../index.html\" class=\"header-brand\">Aryan Binazir</a>",
        "          <div class=\"header-right\">",
        "            <nav class=\"text-nav\" aria-label=\"Main navigation\">",
        "              <a href=\"../../findings.html\" class=\"active\">Findings</a>",
        "              <a href=\"../../index.html#triage\">Triage</a>",
        "              <a href=\"../../index.html#projects\">Projects</a>",
        "            </nav>",
        "            <span class=\"nav-divider\"></span>",
        "            <nav class=\"icon-nav\" aria-label=\"Social links\">",
        "              <a target=\"_blank\" rel=\"noopener noreferrer\" href=\"https://www.linkedin.com/in/aryanbinazir/\" class=\"icon fab fa-linkedin-in\" aria-label=\"LinkedIn\" title=\"LinkedIn\"><span class=\"label\">LinkedIn</span></a>",
        "              <a target=\"_blank\" rel=\"noopener noreferrer\" href=\"https://github.com/aryan-binazir\" class=\"icon fab fa-github\" aria-label=\"GitHub\" title=\"GitHub\"><span class=\"label\">GitHub</span></a>",
        "              <a target=\"_blank\" rel=\"noopener noreferrer\" href=\"../../assets/Aryan-Binazir-Resume.pdf\" class=\"icon fas fa-file-alt\" aria-label=\"Resume\" title=\"Resume\"><span class=\"label\">Resume</span></a>",
        "              <a href=\"mailto:abinazir@gmail.com\" class=\"icon fas fa-envelope\" aria-label=\"Email\" title=\"Email\"><span class=\"label\">Email</span></a>",
        "            </nav>",
        "          </div>",
        "        </div>",
        "      </header>",
        "",
        "      <main>",
        "        <section class=\"post-header\">",
        "          <div class=\"container\">",
        "            <a href=\"../../findings.html\" class=\"back-link\">&larr; All posts</a>",
        f"            <h1>{title_h}</h1>",
        "            <div class=\"post-meta\">",
        f"              <span class=\"post-tag\">{tag_h}</span>",
        f"              <time datetime=\"{post.date_iso}\">{post.display_date}</time>",
        "            </div>",
        "          </div>",
        "        </section>",
        "        <section class=\"post-content\">",
        "          <div class=\"container\">",
        f"            <textarea id=\"post-markdown-source\" hidden>{body_markdown_h}</textarea>",
        "            <div class=\"post-body\" id=\"post-body\"></div>",
        "          </div>",
        "        </section>",
        "      </main>",
        "",
        "      <footer class=\"site-footer\">",
        "        <div class=\"container footer-inner\">",
        "          <ul class=\"icon-nav\" aria-label=\"Footer social links\">",
        "            <li><a target=\"_blank\" rel=\"noopener noreferrer\" href=\"https://www.linkedin.com/in/aryanbinazir/\" class=\"icon fab fa-linkedin-in\" aria-label=\"LinkedIn\" title=\"LinkedIn\"><span class=\"label\">LinkedIn</span></a></li>",
        "            <li><a target=\"_blank\" rel=\"noopener noreferrer\" href=\"https://github.com/aryan-binazir\" class=\"icon fab fa-github\" aria-label=\"GitHub\" title=\"GitHub\"><span class=\"label\">GitHub</span></a></li>",
        "            <li><a target=\"_blank\" rel=\"noopener noreferrer\" href=\"../../assets/Aryan-Binazir-Resume.pdf\" class=\"icon fas fa-file-alt\" aria-label=\"Resume\" title=\"Resume\"><span class=\"label\">Resume</span></a></li>",
        "            <li><a href=\"mailto:abinazir@gmail.com\" class=\"icon fas fa-envelope\" aria-label=\"Email\" title=\"Email\"><span class=\"label\">Email</span></a></li>",
        "          </ul>",
        "          <ul class=\"footer-meta\"><li>&copy; Aryan Binazir</li></ul>",
        "        </div>",
        "      </footer>",
        "    </div>",
        "",
        "    <script src=\"../../assets/js/marked.min.js\"></script>",
        "    <script src=\"../../assets/js/markdown-renderer.js\"></script>",
        "    <script src=\"../../assets/js/findings-post-page.js\"></script>",
        "  </body>",
        "</html>",
        "",
    ]
    return "\n".join(lines)


def write_posts_data(posts: Iterable[ParsedPost], destination: Path) -> None:
    payload = [
        {
            "title": post.title,
            "date": post.date_iso,
            "tag": post.tag,
            "excerpt": post.excerpt,
            "slug": post.slug,
            "url": f"findings/{post.slug}/index.html",
        }
        for post in posts
    ]
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(
        "window.POSTS_DATA = " + json.dumps(payload, ensure_ascii=False, indent=2) + ";\n",
        encoding="utf-8",
    )


def write_manifest(manifest_file: Path, slugs: Iterable[str]) -> None:
    contents = "\n".join(slugs)
    if contents:
        contents += "\n"
    manifest_file.write_text(contents, encoding="utf-8")


def collect_posts(posts_dir: Path) -> list[Path]:
    if not posts_dir.is_dir():
        raise BuildError(f"✗ Posts directory not found: {posts_dir}")
    return sorted(path for path in posts_dir.glob("*.md") if path.is_file())


def build(root: Path) -> int:
    posts_dir = root / "posts"
    findings_dir = root / "findings"
    data_out = root / "assets" / "js" / "posts-data.js"
    manifest_file = findings_dir / MANIFEST_FILENAME

    source_files = collect_posts(posts_dir)

    parsed_posts: list[ParsedPost] = []
    seen_slugs: dict[str, str] = {}

    for source_file in source_files:
        post = parse_post(source_file)
        previous = seen_slugs.get(post.slug)
        if previous:
            raise BuildError(
                f"✗ Duplicate slug '{post.slug}' from {post.source_name} (conflicts with {previous})"
            )
        seen_slugs[post.slug] = post.source_name
        parsed_posts.append(post)

    published_posts = [post for post in parsed_posts if post.published]
    keep_slugs = {post.slug for post in published_posts}

    if not source_files:
        cleanup_generated_findings_dirs(findings_dir, manifest_file, keep_slugs)
        write_manifest(manifest_file, [])
        write_posts_data([], data_out)
        print("⚠ No .md files found in posts/")
        return 0

    if not published_posts:
        cleanup_generated_findings_dirs(findings_dir, manifest_file, keep_slugs)
        write_manifest(manifest_file, [])
        write_posts_data([], data_out)
        print("⚠ No published posts (all posts have published: false)")
        return 0

    for post in published_posts:
        post_dir = findings_dir / post.slug
        post_dir.mkdir(parents=True, exist_ok=True)
        (post_dir / "index.html").write_text(render_post_html(post), encoding="utf-8")
        print(f"  ✓ findings/{post.slug}/index.html")

    cleanup_generated_findings_dirs(findings_dir, manifest_file, keep_slugs)
    write_manifest(manifest_file, [post.slug for post in published_posts])
    write_posts_data(published_posts, data_out)

    print(
        f"✓ {len(published_posts)} post(s) built → "
        "findings/*/index.html + assets/js/posts-data.js"
    )
    return 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Build static findings pages from markdown posts.")
    parser.add_argument(
        "--root",
        default=None,
        help="Project root directory. Defaults to repository root next to this script.",
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.root:
        root = Path(args.root).resolve()
    else:
        root = Path(__file__).resolve().parents[1]

    try:
        return build(root)
    except BuildError as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
