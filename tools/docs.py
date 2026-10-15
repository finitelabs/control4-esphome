#!/usr/bin/env python3
"""Driver documentation generation (no Node, no browser).

Subcommands:
  docs.py md2html  <input.md>   <output-dir>   # styled HTML -> <output-dir>/index.html
  docs.py html2pdf <input.html> <output.pdf>   # HTML -> PDF
  docs.py readme   <input.md>   <output.md>    # driver docs -> repo README.md
  docs.py fmt      [--check] --wrap N <md...>  # mdformat, keeping alert markers

Pipeline:
  - Markdown -> HTML via markdown-it-py (GitHub-flavored, HTML passthrough),
    with syntax highlighting by Pygments and GitHub's alerts (> [!NOTE] etc.).
    Wrapped in a vendored github-markdown stylesheet plus print rules and
    written to the driver's www/documentation (shipped in the driver and shown
    by Control4's documentation viewer).
  - HTML -> PDF via WeasyPrint, a CSS Paged Media engine. Page size/margins come
    from the @page rule; pagination is automatic and content-aware (headings
    kept with their content, tables/code never split, orphan/widow control), so
    no hand-placed page-break markers are required.
  - README is the driver docs markdown with <style> blocks stripped, then
    normalized with mdformat. Both it and `fmt` keep an alert's marker on its
    own line, where wrapping would join it to the text after.
"""

import argparse
import re
import sys
from pathlib import Path

from markdown_it import MarkdownIt
from markdown_it.common.utils import escapeHtml, unescapeAll
from markdown_it.token import Token
from mdit_py_plugins.anchors import anchors_plugin
from pygments import highlight
from pygments.formatters import HtmlFormatter
from pygments.lexers import get_lexer_by_name
from pygments.util import ClassNotFound

TOOLS_DIR = Path(__file__).resolve().parent
GITHUB_CSS = (TOOLS_DIR / "github-markdown.css").read_text(encoding="utf-8")
# Scoped to `.highlight pre` so github-markdown.css's rounded box outranks the
# square background Pygments gives its wrapper.
PYGMENTS_CSS = HtmlFormatter(style="default").get_style_defs(".highlight pre")

# Screen layout matches the Control4 documentation viewer; print layout matches
# the previous electron-pdf output (Letter, 0.4in margins) and adds automatic
# content-aware pagination.
LAYOUT_CSS = """
.markdown-body { box-sizing: border-box; min-width: 200px; max-width: 980px; margin: 0 auto; padding: 45px; }
@media (max-width: 767px) { .markdown-body { padding: 15px; } }
/* github-markdown-css ends its font stack with color-emoji fonts. On Linux
   (CI) fontconfig matches digit codepoints to the emoji font (it carries keycap
   digits), and WeasyPrint can't render color-emoji as text, so digits vanish.
   Override with a text-only stack that resolves on Linux (DejaVu/Noto) and mac.
   Symbola (monochrome) sits last so symbol chars the docs use in tables/callouts
   (check/cross/warning) render as glyphs instead of blank color-emoji boxes. */
.markdown-body {
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, "Liberation Sans", "DejaVu Sans", "Noto Sans", "Symbola", sans-serif;
}
.markdown-body code, .markdown-body pre, .markdown-body tt {
  font-family: "SFMono-Regular", Consolas, "Liberation Mono", "DejaVu Sans Mono", Menlo, monospace;
}
/* The docs index is authored in a small-font <div>. Preprocessor #ifdef blocks
   can leave a blank line in the list for some distributions, which makes markdown
   render it "loose": each <li> wrapped in a <p> whose paragraph margins add
   large vertical gaps. Keep the index compact regardless. */
.markdown-body div[style*="font-size"] li > p { margin: 0; }
/* The browser default 3rd-level (and deeper) list marker is a heavy full-size
   black square that reads as clunky next to the level 1/2 disc & circle. Use a
   small square instead so deep index nesting stays clean. */
.markdown-body ul ul ul { list-style-type: "▪ "; }
@page { size: Letter; margin: 0.4in; }
@media print {
  .markdown-body { max-width: none; padding: 0 45px; margin: 0; }
  h1, h2, h3, h4, h5, h6, .markdown-alert-title { break-after: avoid; }
  /* Keep code, images and individual rows intact, but let long tables split
     across pages (WeasyPrint repeats <thead>). Pinning the whole table with
     break-inside:avoid strands big blank gaps and orphans the heading above it. */
  pre, figure, tr { break-inside: avoid; }
  /* A page cannot scroll, so a long code line wraps instead of being cut off. */
  .markdown-body pre, .markdown-body pre > code { white-space: pre-wrap; overflow-wrap: anywhere; }
  p, li { orphans: 3; widows: 3; }
}
"""


# markdown-it wraps a `highlight` result in its own <pre><code> unless it starts
# with <pre, so GitHub's one-<pre> shape needs the fence rule itself.
def _fence(self, tokens, idx, options, env) -> str:
    token = tokens[idx]
    info = unescapeAll(token.info).strip()
    lang = info.split(maxsplit=1)[0] if info else ""
    try:
        lexer = get_lexer_by_name(lang) if lang else None
    except ClassNotFound:
        lexer = None
    if lexer is None:
        return self.fence(tokens, idx, options, env)
    code = highlight(token.content, lexer, HtmlFormatter(nowrap=True))
    lang_class = escapeHtml(lang.lower())
    return f'<div class="highlight highlight-source-{lang_class}"><pre>{code}</pre></div>\n'


# GitHub's alert types, each with the octicon GitHub puts in its title and the
# title's color in github-markdown.css.
_ALERT_ICONS = {
    "note": (
        "info",
        "#0969da",
        "M0 8a8 8 0 1 1 16 0A8 8 0 0 1 0 8Zm8-6.5a6.5 6.5 0 1 0 0 13 6.5 6.5 0 0 0 0-13ZM6.5 7.75A.75.75 0 0 1 7.25 7h1a.75.75 0 0 1 .75.75v2.75h.25a.75.75 0 0 1 0 1.5h-2a.75.75 0 0 1 0-1.5h.25v-2h-.25a.75.75 0 0 1-.75-.75ZM8 6a1 1 0 1 1 0-2 1 1 0 0 1 0 2Z",
    ),
    "tip": (
        "light-bulb",
        "#1a7f37",
        "M8 1.5c-2.363 0-4 1.69-4 3.75 0 .984.424 1.625.984 2.304l.214.253c.223.264.47.556.673.848.284.411.537.896.621 1.49a.75.75 0 0 1-1.484.211c-.04-.282-.163-.547-.37-.847a8.456 8.456 0 0 0-.542-.68c-.084-.1-.173-.205-.268-.32C3.201 7.75 2.5 6.766 2.5 5.25 2.5 2.31 4.863 0 8 0s5.5 2.31 5.5 5.25c0 1.516-.701 2.5-1.328 3.259-.095.115-.184.22-.268.319-.207.245-.383.453-.541.681-.208.3-.33.565-.37.847a.751.751 0 0 1-1.485-.212c.084-.593.337-1.078.621-1.489.203-.292.45-.584.673-.848.075-.088.147-.173.213-.253.561-.679.985-1.32.985-2.304 0-2.06-1.637-3.75-4-3.75ZM5.75 12h4.5a.75.75 0 0 1 0 1.5h-4.5a.75.75 0 0 1 0-1.5ZM6 15.25a.75.75 0 0 1 .75-.75h2.5a.75.75 0 0 1 0 1.5h-2.5a.75.75 0 0 1-.75-.75Z",
    ),
    "important": (
        "report",
        "#8250df",
        "M0 1.75C0 .784.784 0 1.75 0h12.5C15.216 0 16 .784 16 1.75v9.5A1.75 1.75 0 0 1 14.25 13H8.06l-2.573 2.573A1.458 1.458 0 0 1 3 14.543V13H1.75A1.75 1.75 0 0 1 0 11.25Zm1.75-.25a.25.25 0 0 0-.25.25v9.5c0 .138.112.25.25.25h2a.75.75 0 0 1 .75.75v2.19l2.72-2.72a.749.749 0 0 1 .53-.22h6.5a.25.25 0 0 0 .25-.25v-9.5a.25.25 0 0 0-.25-.25Zm7 2.25v2.5a.75.75 0 0 1-1.5 0v-2.5a.75.75 0 0 1 1.5 0ZM9 9a1 1 0 1 1-2 0 1 1 0 0 1 2 0Z",
    ),
    "warning": (
        "alert",
        "#9a6700",
        "M6.457 1.047c.659-1.234 2.427-1.234 3.086 0l6.082 11.378A1.75 1.75 0 0 1 14.082 15H1.918a1.75 1.75 0 0 1-1.543-2.575Zm1.763.707a.25.25 0 0 0-.44 0L1.698 13.132a.25.25 0 0 0 .22.368h12.164a.25.25 0 0 0 .22-.368Zm.53 3.996v2.5a.75.75 0 0 1-1.5 0v-2.5a.75.75 0 0 1 1.5 0ZM9 11a1 1 0 1 1-2 0 1 1 0 0 1 2 0Z",
    ),
    "caution": (
        "stop",
        "#d1242f",
        "M4.47.22A.749.749 0 0 1 5 0h6c.199 0 .389.079.53.22l4.25 4.25c.141.14.22.331.22.53v6a.749.749 0 0 1-.22.53l-4.25 4.25A.749.749 0 0 1 11 16H5a.749.749 0 0 1-.53-.22L.22 11.53A.749.749 0 0 1 0 11V5c0-.199.079-.389.22-.53Zm.84 1.28L1.5 5.31v5.38l3.81 3.81h5.38l3.81-3.81V5.31L10.69 1.5ZM8 4a.75.75 0 0 1 .75.75v3.5a.75.75 0 0 1-1.5 0v-3.5A.75.75 0 0 1 8 4Zm0 8a1 1 0 1 1 0-2 1 1 0 0 1 0 2Z",
    ),
}
# A tab after the marker stays in markdown-it's text; GitHub still shows the alert.
_ALERT_MARKER_RE = re.compile(rf"\[!({'|'.join(_ALERT_ICONS)})\][ \t]*", re.I)


def _alerts(state) -> None:
    """Render a GitHub alert (`> [!NOTE]` and the other four) as GitHub does.

    GitHub takes the marker only alone on the first line of a top-level quote
    with more after it; any other quote stays a quote. This runs after inline
    parsing, so an escaped marker or one ending in a hard break matches too.
    Around HTML it can differ from GitHub: a quote in a `<div>` or `<details>`
    block, or one whose body is only a comment, becomes an alert here, and
    `[!NOTE]<br>` does not. A marker on that first line with more after it is
    listed by line number in env["joined_alert_markers"], which `fmt` reports.
    """
    tokens = state.tokens
    for i in reversed(range(len(tokens) - 4)):
        quote, inline = tokens[i], tokens[i + 2]
        if quote.type != "blockquote_open" or quote.level:
            continue
        if tokens[i + 1].type != "paragraph_open":
            continue
        first, *rest = inline.children
        match = first.type == "text" and _ALERT_MARKER_RE.match(first.content)
        if not match:
            continue
        if match.end() < len(first.content) or (
            rest and rest[0].type not in ("softbreak", "hardbreak")
        ):
            joined = state.env.setdefault("joined_alert_markers", [])
            joined.append(tokens[i + 1].map[0] + 1)
            continue
        if not rest and tokens[i + 4].type == "blockquote_close":
            continue
        kind = match[1].lower()
        icon, color, path = _ALERT_ICONS[kind]
        title = Token("html_block", "", 0)
        # The CSS colors the icon in a browser; WeasyPrint's SVG ignores page CSS
        # and needs the fill attribute.
        title.content = (
            f'<p class="markdown-alert-title"><svg class="octicon octicon-{icon} mr-2"'
            ' viewBox="0 0 16 16" version="1.1" width="16" height="16"'
            f' aria-hidden="true" fill="{color}"><path d="{path}"></path></svg>'
            f"{kind.capitalize()}</p>\n"
        )
        close = next(
            t for t in tokens[i:] if t.type == "blockquote_close" and not t.level
        )
        quote.tag = close.tag = "div"
        quote.attrSet("class", f"markdown-alert markdown-alert-{kind}")
        if rest:
            inline.children = rest[1:]
            tokens.insert(i + 1, title)
        else:
            tokens[i + 1 : i + 4] = [title]


def _make_md() -> MarkdownIt:
    md = MarkdownIt("gfm-like", {"html": True, "linkify": True})
    md.add_render_rule("fence", _fence)
    md.use(anchors_plugin, max_level=6, permalink=False)
    md.core.ruler.push("alerts", _alerts)
    return md


_IMG_TAG_RE = re.compile(r"<img\b[^>]*>", re.I)
_IMG_DIM_RE = re.compile(r'\s(width|height)\s*=\s*"(\d+)"', re.I)


def _img_dims_to_style(html: str) -> str:
    """Move presentational width/height attrs on <img> into inline styles.

    WeasyPrint ignores the HTML width/height *attributes* on images (it uses the
    intrinsic pixel size), so authored sizes like width="300" are lost in the
    PDF: the image renders full-bleed and only max-width:100% reins it in.
    WeasyPrint does honor inline CSS, so rewrite `width="N"` -> `width: Npx`.
    Browsers honor both forms, so the on-screen docs are unaffected.
    """

    def repl(m: "re.Match[str]") -> str:
        tag = m.group(0)
        dims = _IMG_DIM_RE.findall(tag)
        if not dims:
            return tag
        tag = _IMG_DIM_RE.sub("", tag)
        css = "".join(f"{name.lower()}: {value}px; " for name, value in dims)
        style_at = re.search(r'\sstyle\s*=\s*"', tag, re.I)
        if style_at:
            i = style_at.end()
            return tag[:i] + css + tag[i:]
        return re.sub(r"^<img\b", f'<img style="{css.strip()}"', tag, flags=re.I)

    return _IMG_TAG_RE.sub(repl, html)


_ALIGN_TAG_RE = re.compile(
    r'<(?!img\b|/)[a-zA-Z][\w-]*\b[^>]*\balign\s*=\s*"[^"]*"[^>]*>', re.I
)
_ALIGN_ATTR_RE = re.compile(r'\salign\s*=\s*"(left|right|center|justify)"', re.I)


def _align_to_style(html: str) -> str:
    """Move the presentational `align` attribute into an inline text-align style.

    Like width/height, WeasyPrint ignores the `align` attribute, so authored
    `<p align="center">` blocks (centered headers, logos, captions) render
    left-aligned in the PDF. Rewrite to `text-align`, which WeasyPrint honors.
    `<img align>` (float) is left alone, since the docs don't use it.
    """

    def repl(m: "re.Match[str]") -> str:
        tag = m.group(0)
        am = _ALIGN_ATTR_RE.search(tag)
        if not am:
            return tag
        tag = _ALIGN_ATTR_RE.sub("", tag)
        css = f"text-align: {am.group(1).lower()};"
        style_at = re.search(r'\sstyle\s*=\s*"', tag, re.I)
        if style_at:
            i = style_at.end()
            return tag[:i] + css + " " + tag[i:]
        return re.sub(r"^(<[a-zA-Z][\w-]*)", rf'\1 style="{css}"', tag, flags=re.I)

    return _ALIGN_TAG_RE.sub(repl, html)


_STATUS_SYMBOLS = {
    "✅": '<span style="color:#1a7f37">✓</span>',  # ✅ -> green ✓
    "❌": '<span style="color:#cf222e">✗</span>',  # ❌ -> red ✗
}
# ⚠ optionally followed by the emoji-presentation selector U+FE0F.
_WARN_RE = re.compile("⚠️?")


def _status_symbols(html: str) -> str:
    """Render status emoji as text glyphs so the PDF shows them legibly.

    ✅/❌ carry default *emoji presentation* and ⚠️ an explicit emoji selector
    (U+FE0F), so the shaper forces a color-emoji font, which WeasyPrint can't
    rasterize, collapsing them to illegible specks. Map to text-presentation
    glyphs (✓ ✗ ⚠, present in DejaVu/Symbola) with GitHub-style semantic colors;
    browsers render these the same, so the Control4 viewer stays consistent.
    """
    for emoji, replacement in _STATUS_SYMBOLS.items():
        html = html.replace(emoji, replacement)
    return _WARN_RE.sub('<span style="color:#9a6700">⚠</span>', html)


_PAGE_BREAK_RE = re.compile(r"<div\b[^>]*\bpage-break[^>]*>\s*</div>\s*", re.I)


def _drop_manual_page_breaks(html: str) -> str:
    """Remove hand-placed page-break separators.

    Docs authored `<div style="page-break-after: always"></div>` to force breaks
    at fixed spots. Pagination is now automatic and content-aware (headings kept
    with their content, rows/images/code never split, tables split with a
    repeated header), so these hard breaks only fight the layout. Drop them.
    """
    return _PAGE_BREAK_RE.sub("", html)


def md2html(input_path: Path, output_dir: Path) -> None:
    source = input_path.read_text(encoding="utf-8")
    body = _drop_manual_page_breaks(
        _status_symbols(_align_to_style(_img_dims_to_style(_make_md().render(source))))
    )
    title = input_path.stem
    html = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>{title}</title>
<style>
{GITHUB_CSS}
{PYGMENTS_CSS}
{LAYOUT_CSS}
</style>
</head>
<body class="markdown-body">
{body}
</body>
</html>
"""
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "index.html").write_text(html, encoding="utf-8")


def html2pdf(input_path: Path, output_path: Path) -> None:
    # Imported lazily so md2html works on machines without WeasyPrint's native
    # libs (e.g. HTML-only preview).
    from weasyprint import HTML

    HTML(filename=str(input_path)).write_pdf(str(output_path))


def _keep_alert_marker_line(text: str, node, _context) -> str:
    """mdformat postprocessor: a softbreak after an alert marker stays a newline.

    Wrapping would make it a space, and GitHub reads `> [!NOTE] text` on one
    line as a plain quote.
    """
    inline = node.parent
    quote = inline.parent.parent
    first = inline.children[0]
    if (
        quote.type == "blockquote"
        and quote.children[0] is inline.parent
        and inline.children.index(node) == 1
        and first.type == "text"
        and _ALERT_MARKER_RE.fullmatch(first.content)
    ):
        return "\n"
    return text


class _AlertMarkerExtension:
    """mdformat parser extension that only adds the postprocessor above."""

    RENDERERS: dict = {}
    POSTPROCESSORS = {"softbreak": _keep_alert_marker_line}

    @staticmethod
    def update_mdit(_mdit) -> None:
        pass


def _mdformat(text: str, wrap: int) -> str:
    """mdformat with gfm, keeping each alert marker on its own line."""
    import mdformat
    import mdformat.plugins

    # mdformat finds extensions by entry point; registering here lets docs.py
    # carry this one without packaging it.
    mdformat.plugins.PARSER_EXTENSIONS["alert_marker"] = _AlertMarkerExtension
    return mdformat.text(
        text, options={"wrap": wrap}, extensions=("gfm", "alert_marker")
    )


def readme(input_path: Path, output_path: Path) -> None:
    text = input_path.read_text(encoding="utf-8")
    # Strip <style> blocks (screen-only chrome), then normalize.
    text = re.sub(r"<style\b[^>]*>.*?</style>", "", text, flags=re.S | re.I)
    output_path.write_text(_mdformat(text, 80), encoding="utf-8")


def fmt(args: list[str]) -> int:
    """Format files in place, or with --check name each one that would change.

    Either way, an alert marker joined to its text is named and its file left
    alone: splitting the line or escaping the marker would guess what was meant.
    """
    parser = argparse.ArgumentParser(prog="docs.py fmt")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--wrap", type=int, required=True)
    parser.add_argument("paths", nargs="+", type=Path)
    opts = parser.parse_args(args)
    md = _make_md()
    failed = 0
    for path in opts.paths:
        # Bytes, not read_text: a CRLF file must read as unformatted.
        original = path.read_bytes().decode()
        env: dict = {}
        md.parse(original, env)
        joined = sorted(env.get("joined_alert_markers", []))
        for line in joined:
            print(
                f'Error: File "{path.absolute()}", line {line}: put the alert marker'
                " alone on its line.",
                file=sys.stderr,
            )
            failed = 1
        formatted = _mdformat(original, opts.wrap)
        if formatted == original:
            continue
        if opts.check:
            print(f'Error: File "{path.absolute()}" is not formatted.', file=sys.stderr)
            failed = 1
        elif not joined:
            path.write_bytes(formatted.encode())
    return failed


_COMMANDS = {"md2html": md2html, "html2pdf": html2pdf, "readme": readme}


def main() -> int:
    if sys.argv[1:2] == ["fmt"]:
        return fmt(sys.argv[2:])
    if len(sys.argv) != 4 or sys.argv[1] not in _COMMANDS:
        print(__doc__, file=sys.stderr)
        return 1
    _COMMANDS[sys.argv[1]](Path(sys.argv[2]).resolve(), Path(sys.argv[3]).resolve())
    return 0


if __name__ == "__main__":
    sys.exit(main())
