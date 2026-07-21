#!/usr/bin/env python3
"""Driver documentation generation (no Node, no browser).

Subcommands:
  docs.py md2html  <input.md>   <output-dir>   # styled HTML -> <output-dir>/index.html
  docs.py html2pdf <input.html> <output.pdf>   # HTML -> PDF
  docs.py readme   <input.md>   <output.md>    # driver docs -> repo README.md

Pipeline:
  - Markdown -> HTML via markdown-it-py (GitHub-flavored, HTML passthrough),
    with syntax highlighting by Pygments. Wrapped in a vendored github-markdown
    stylesheet plus print rules and written to the driver's www/documentation
    (shipped in the driver and shown by Control4's documentation viewer).
  - HTML -> PDF via WeasyPrint, a CSS Paged Media engine. Page size/margins come
    from the @page rule; pagination is automatic and content-aware (headings
    kept with their content, tables/code never split, orphan/widow control) —
    no hand-placed page-break markers required.
  - README is the driver docs markdown with <style> blocks stripped, then
    normalized with mdformat.
"""

import re
import sys
from pathlib import Path

from markdown_it import MarkdownIt
from mdit_py_plugins.anchors import anchors_plugin
from pygments import highlight
from pygments.formatters import HtmlFormatter
from pygments.lexers import get_lexer_by_name, guess_lexer
from pygments.util import ClassNotFound

TOOLS_DIR = Path(__file__).resolve().parent
GITHUB_CSS = (TOOLS_DIR / "github-markdown.css").read_text(encoding="utf-8")
# Pygments highlight CSS, scoped under .highlight (its default wrapper class).
PYGMENTS_CSS = HtmlFormatter(style="default").get_style_defs(".highlight")

# Screen layout matches the Control4 documentation viewer; print layout matches
# the previous electron-pdf output (Letter, 0.4in margins) and adds automatic
# content-aware pagination.
LAYOUT_CSS = """
.markdown-body { box-sizing: border-box; min-width: 200px; max-width: 980px; margin: 0 auto; padding: 45px; }
@media (max-width: 767px) { .markdown-body { padding: 15px; } }
/* github-markdown-css ends its font stack with color-emoji fonts. On Linux
   (CI) fontconfig matches digit codepoints to the emoji font (it carries keycap
   digits), and WeasyPrint can't render color-emoji as text — so digits vanish.
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
   render it "loose" — each <li> wrapped in a <p> whose paragraph margins add
   large vertical gaps. Keep the index compact regardless. */
.markdown-body div[style*="font-size"] li > p { margin: 0; }
/* The browser default 3rd-level (and deeper) list marker is a heavy full-size
   black square that reads as clunky next to the level 1/2 disc & circle. Use a
   small square instead so deep index nesting stays clean. */
.markdown-body ul ul ul { list-style-type: "▪ "; }
@page { size: Letter; margin: 0.4in; }
@media print {
  .markdown-body { max-width: none; padding: 0 45px; margin: 0; }
  h1, h2, h3, h4, h5, h6 { break-after: avoid; }
  /* Keep code, images and individual rows intact, but let long tables split
     across pages (WeasyPrint repeats <thead>) — pinning the whole table with
     break-inside:avoid strands big blank gaps and orphans the heading above it. */
  pre, figure, tr { break-inside: avoid; }
  p, li { orphans: 3; widows: 3; }
}
"""


def _highlight(code: str, lang: str, _attrs) -> str:
    try:
        lexer = get_lexer_by_name(lang) if lang else guess_lexer(code)
    except ClassNotFound:
        lexer = None
    if lexer is None:
        # No known lexer: return empty so markdown-it emits its default escaped
        # <pre><code> block.
        return ""
    return highlight(code, lexer, HtmlFormatter(nowrap=False))


def _make_md() -> MarkdownIt:
    md = MarkdownIt(
        "gfm-like", {"html": True, "linkify": True, "highlight": _highlight}
    )
    md.use(anchors_plugin, max_level=6, permalink=False)
    return md


_IMG_TAG_RE = re.compile(r"<img\b[^>]*>", re.I)
_IMG_DIM_RE = re.compile(r'\s(width|height)\s*=\s*"(\d+)"', re.I)


def _img_dims_to_style(html: str) -> str:
    """Move presentational width/height attrs on <img> into inline styles.

    WeasyPrint ignores the HTML width/height *attributes* on images (it uses the
    intrinsic pixel size), so authored sizes like width="300" are lost in the
    PDF — the image renders full-bleed and only max-width:100% reins it in.
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
    `<img align>` (float) is left alone — the docs don't use it.
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
    (U+FE0F), so the shaper forces a color-emoji font — which WeasyPrint can't
    rasterize, collapsing them to illegible specks. Map to text-presentation
    glyphs (✓ ✗ ⚠, present in DejaVu/Symbola) with GitHub-style semantic colors;
    browsers render these the same, so the Control4 viewer stays consistent.
    """
    for emoji, replacement in _STATUS_SYMBOLS.items():
        html = html.replace(emoji, replacement)
    return _WARN_RE.sub('<span style="color:#9a6700">⚠</span>', html)


def md2html(input_path: Path, output_dir: Path) -> None:
    source = input_path.read_text(encoding="utf-8")
    body = _status_symbols(
        _align_to_style(_img_dims_to_style(_make_md().render(source)))
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


def readme(input_path: Path, output_path: Path) -> None:
    import mdformat

    text = input_path.read_text(encoding="utf-8")
    # Strip <style> blocks (screen-only chrome), then normalize.
    text = re.sub(r"<style\b[^>]*>.*?</style>", "", text, flags=re.S | re.I)
    text = mdformat.text(text, options={"wrap": 80}, extensions={"gfm"})
    output_path.write_text(text, encoding="utf-8")


_COMMANDS = {"md2html": md2html, "html2pdf": html2pdf, "readme": readme}


def main() -> int:
    if len(sys.argv) != 4 or sys.argv[1] not in _COMMANDS:
        print(__doc__, file=sys.stderr)
        return 1
    _COMMANDS[sys.argv[1]](Path(sys.argv[2]).resolve(), Path(sys.argv[3]).resolve())
    return 0


if __name__ == "__main__":
    sys.exit(main())
