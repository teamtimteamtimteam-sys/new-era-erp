#!/usr/bin/env python3
# scripts/build-manual.py — typeset docs/manual-draft.md into docs/Evoltrya-OS-Operations-Manual.pdf
#
# ============================================================================
# WHY THIS FILE EXISTS AND WHY IT IS NOT A LIBRARY CALL
# ============================================================================
# There is no markdown library installed in any language on this machine, and
# that turns out to be the right situation rather than a gap to fill. Three of
# the manual's requirements need control a general converter does not give:
#
#   1. Every inline-code span takes an accent background and must never break
#      across a line. A general converter emits <code> and leaves the rest to
#      CSS, which cannot stop a break inside a span it did not mark.
#   2. Each Part needs its own CSS *named page* so the running header can name
#      it. That means wrapping four spans of the document in <section page:pN>,
#      which is a structural decision no markdown converter makes.
#   3. Table columns are set nowrap or wrap per column, decided by measuring
#      the widest cell in each. A converter that emits <td> uniformly cannot.
#
# The manual uses a narrow subset -- no HTML, no links, no blockquotes, two
# list levels -- so the converter below is small and total over that subset.
# It raises on anything it does not recognise rather than passing it through,
# because silently emitting unstyled markdown into a PDF is how a document
# ships with `**bold**` printed literally on page 40.
#
# ============================================================================
# WHY THE BUILD RUNS CHROMIUM TWICE, AND WHY THAT IS EXACT AND NOT ITERATIVE
# ============================================================================
# The contents needs real page numbers. Chromium implements neither
# target-counter() (measured: produces nothing) nor string-set/string()
# (measured: renders an empty header box). So page numbers must be measured
# from a rendered PDF and written back.
#
# The usual trap with that is circular: adding numbers to the contents changes
# the contents' length, which moves the body, which changes the numbers. This
# build does not have that problem, because the front matter is a SEPARATE
# DOCUMENT from the body. The body is rendered once, alone, and its page
# numbers are final the moment it exists. The front matter is then rendered
# against those fixed numbers and merged in front. Nothing converges; nothing
# is iterated; the numbers are right on the first try or the build fails.
#
# Splitting the documents also delivers "page 1 is the first page of Part 1"
# for free. Chromium ignores counter-reset:page (measured), so a single-document
# build cannot restart the count after the front matter. Two documents make the
# body's own count start at 1 with nothing to reset.
#
# ============================================================================
# FONTS
# ============================================================================
# Google Sans + Noto Sans SC, from assets/fonts/ -- the same faces, from the
# same files, as every other document this system prints (see DOC_FONT_STACK
# in app/components/pdf/fonts.ts). Noto carries three Chinese words in 3.6 and
# nothing else; it stays in the stack after those words go.
#
# Neither face has an italic. Chromium's two fallbacks were both measured and
# both are unacceptable: with a generic family in the stack it silently
# substitutes Times New Roman, and with a single family it synthesises a slant.
# So the stylesheet declares no italic and the quotations are set upright --
# they carry their own quotation marks, which is what marks them.

import html
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "docs" / "manual-draft.md"
OUT = ROOT / "docs" / "Evoltrya-OS-Operations-Manual.pdf"
BUILD = ROOT / ".manual-build"
FONTS = ROOT / "assets" / "fonts"
BRAND = ROOT / "public" / "brand"

CHROME_CANDIDATES = [
    Path.home() / ".cache/puppeteer/chrome-headless-shell/mac_arm-152.0.7977.75"
    "/chrome-headless-shell-mac-arm64/chrome-headless-shell",
    Path.home() / ".cache/puppeteer/chrome-headless-shell/mac_arm-152.0.7977.54"
    "/chrome-headless-shell-mac-arm64/chrome-headless-shell",
]

# Brand_Guide.pdf palette.
OCEAN, FOREST = "#008EBC", "#6B8D54"
PAGE_BG, ACCENT, INK = "#F1F9FE", "#E1F5FF", "#182B4B"

# A column whose widest cell is at or under this many characters is a value
# column: it is set nowrap and never breaks. Anything wider is prose in a cell
# and wraps like prose. 32 was chosen by measuring all 30 tables -- it is the
# gap between "back to its previous state" (26) and the shortest description
# column (93), so no column lands near the boundary.
VALUE_COL_CHARS = 32


# --------------------------------------------------------------------------
# Inline markup
# --------------------------------------------------------------------------

def inline(text):
    """Inline markdown -> HTML. Code spans are extracted first so that the
    bold and italic passes cannot reach inside them: a permission name like
    `data.view_pay` contains an underscore, and `**` can straddle one."""
    slots = []

    def stash(m):
        slots.append(m.group(1))
        return f"\x00{len(slots) - 1}\x00"

    text = re.sub(r"`([^`]+)`", stash, text)
    text = html.escape(text, quote=False)
    text = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)
    # Single asterisks marked italics in the source. No italic face exists in
    # either family, so they are set upright; the quotation marks that are
    # already inside all but one of them are what marks them as quoted.
    text = re.sub(r"(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)", r"\1", text)
    for i, code in enumerate(slots):
        span = f'<span class="k">{html.escape(code, quote=False)}</span>'
        text = text.replace(f"\x00{i}\x00", span)
    if "*" in text or "`" in text:
        raise SystemExit(f"unconsumed markdown in: {text[:120]!r}")
    return text


# --------------------------------------------------------------------------
# Block parser
# --------------------------------------------------------------------------

def parse(md):
    lines = md.split("\n")
    blocks, i = [], 0
    while i < len(lines):
        raw = lines[i]
        line = raw.strip()

        if not line:
            i += 1
            continue

        if re.fullmatch(r"-{3,}", line):
            blocks.append(("hr", None))
            i += 1
            continue

        m = re.match(r"^(#{1,4})\s+(.*)$", line)
        if m:
            blocks.append(("h", (len(m.group(1)), m.group(2).strip())))
            i += 1
            continue

        if raw.startswith("|"):
            rows, start = [], i
            while i < len(lines) and lines[i].startswith("|"):
                rows.append(lines[i])
                i += 1
            blocks.append(("table", (rows, start + 1)))
            continue

        if re.match(r"^(\s*)(-|\d+\.)\s", raw):
            items, ordered = [], bool(re.match(r"^\s*\d+\.\s", raw))
            while i < len(lines):
                cur = lines[i]
                if not cur.strip():
                    # A blank line ends the list unless the next line is
                    # another item or a continuation of the one before it.
                    nxt = lines[i + 1] if i + 1 < len(lines) else ""
                    if not re.match(r"^(\s*)(-|\d+\.)\s|^\s{2,}\S", nxt):
                        break
                    i += 1
                    continue
                mi = re.match(r"^(\s*)(?:-|\d+\.)\s+(.*)$", cur)
                if mi:
                    level = 1 if len(mi.group(1)) >= 2 else 0
                    items.append([level, mi.group(2).strip()])
                elif re.match(r"^\s{2,}\S", cur) and items:
                    items[-1][1] += " " + cur.strip()
                else:
                    break
                i += 1
            blocks.append(("list", (ordered, items)))
            continue

        para = []
        while i < len(lines) and lines[i].strip() and not lines[i].startswith("|") \
                and not re.match(r"^#{1,4}\s|^(\s*)(-|\d+\.)\s|^-{3,}$", lines[i].strip()) \
                and not re.match(r"^(\s*)(-|\d+\.)\s", lines[i]):
            para.append(lines[i].strip())
            i += 1
        if not para:
            raise SystemExit(f"parser stalled at line {i + 1}: {lines[i]!r}")
        blocks.append(("p", " ".join(para)))
    return blocks


def plain(cell):
    return re.sub(r"[*`]", "", cell).strip()


def render_table(rows):
    grid = []
    for r in rows:
        if re.fullmatch(r"\|[\s:|-]+\|", r.strip()):
            continue
        grid.append([c.strip() for c in r.strip().strip("|").split("|")])
    ncol = max(len(r) for r in grid)
    widths = [0] * ncol
    for r in grid:
        for j, c in enumerate(r):
            widths[j] = max(widths[j], len(plain(c)))
    # Value columns never break; prose columns wrap. See VALUE_COL_CHARS.
    cls = ["v" if w <= VALUE_COL_CHARS else "w" for w in widths]

    # A table whose every column is a value column has no column that wants the
    # leftover width, so at width:100% the browser shares it out between them and
    # opens a canyon down the middle -- the prefix table in 1.4 had half a page of
    # white between "PO-" and "Purchase order". Those tables are set to their own
    # content width instead, and the leftover goes to the right margin where it
    # reads as a margin rather than as a gap.
    narrow = ' class="narrow"' if all(c == "v" for c in cls) else ""

    head, body = grid[0], grid[1:]
    out = [f'<table{narrow}><thead><tr>']
    for j, c in enumerate(head):
        out.append(f'<th class="{cls[j]}">{inline(c)}</th>')
    out.append("</tr></thead><tbody>")
    for r in body:
        out.append("<tr>")
        for j in range(ncol):
            c = r[j] if j < len(r) else ""
            out.append(f'<td class="{cls[j]}">{inline(c)}</td>')
        out.append("</tr>")
    out.append("</tbody></table>")
    return "".join(out)


def render_list(ordered, items):
    tag = "ol" if ordered else "ul"
    out, depth = [f"<{tag}>"], 0
    for level, text in items:
        while depth < level:
            out.append("<ul>")
            depth += 1
        while depth > level:
            out.append("</ul>")
            depth -= 1
        out.append(f"<li>{inline(text)}</li>")
    while depth > 0:
        out.append("</ul>")
        depth -= 1
    out.append(f"</{tag}>")
    return "".join(out)


# --------------------------------------------------------------------------
# Stylesheet
# --------------------------------------------------------------------------

def font_faces():
    """Absolute file:// URLs -- Chromium embeds a subset of each face it
    actually draws from. No italic or oblique is declared anywhere: declaring
    one would license Chromium to synthesise it."""
    def face(family, weight, filename):
        return (
            "@font-face{"
            f'font-family:"{family}";'
            f'src:url("file://{FONTS / filename}") format("truetype");'
            f"font-weight:{weight};font-style:normal;font-display:block}}"
        )
    return "".join([
        face("Google Sans", 400, "GoogleSans-Regular.ttf"),
        face("Google Sans", 700, "GoogleSans-Bold.ttf"),
        face("Noto Sans SC", 400, "NotoSansSC-Regular.ttf"),
        face("Noto Sans SC", 700, "NotoSansSC-Bold.ttf"),
    ])


STACK = '"Google Sans","Noto Sans SC"'

COMMON = f"""
*{{box-sizing:border-box}}
html,body{{margin:0;padding:0}}
body{{font-family:{STACK};font-size:10pt;line-height:1.55;color:{INK};
  -webkit-print-color-adjust:exact;print-color-adjust:exact;
  text-rendering:geometricPrecision}}
strong{{font-weight:700}}
/* Every inline-code span: accent block, body face, and it never breaks.
   nowrap is what makes the STEP 5 check "the accent background does not
   break across a line" true by construction rather than by inspection. */
.k{{background:{ACCENT};padding:0.5pt 2.5pt;border-radius:2pt;
  white-space:nowrap;font-family:{STACK};font-size:0.95em}}
"""

BODY_CSS = f"""
{font_faces()}
{COMMON}
@page{{
  size:A4 portrait;
  margin:22mm 20mm 20mm 20mm;
  background:{PAGE_BG};
  @bottom-center{{
    content:counter(page);
    font-family:{STACK};font-size:9pt;color:{INK};
    margin-top:6mm;
  }}
}}
body{{background:{PAGE_BG}}}

h1{{font-size:23pt;line-height:1.2;font-weight:700;color:{OCEAN};
  margin:0 0 2mm 0;letter-spacing:-0.01em;break-after:avoid}}
h1+.rule{{height:2.2pt;background:{FOREST};width:38mm;margin:0 0 9mm 0;
  break-after:avoid}}
h2{{font-size:15pt;line-height:1.25;font-weight:700;color:{OCEAN};
  margin:9mm 0 2.5mm 0;break-after:avoid}}
h3{{font-size:11.5pt;line-height:1.3;font-weight:700;color:{FOREST};
  margin:6mm 0 1.5mm 0;break-after:avoid}}
h4{{font-size:10.5pt;line-height:1.3;font-weight:700;color:{INK};
  margin:4.5mm 0 1mm 0;break-after:avoid}}
p{{margin:0 0 2.6mm 0;orphans:2;widows:2}}
ul,ol{{margin:0 0 2.8mm 0;padding-left:5.5mm}}
ul ul{{margin:1mm 0 0 0}}
li{{margin:0 0 1.2mm 0;orphans:2;widows:2}}
hr{{border:0;border-top:0.6pt solid {OCEAN};opacity:0.35;margin:6mm 0}}

table{{width:100%;border-collapse:collapse;font-size:8.5pt;line-height:1.35;
  margin:2mm 0 4mm 0}}
table.narrow{{width:auto;max-width:100%}}
table.narrow td.v,table.narrow th.v{{width:auto;padding-right:9mm}}
thead{{display:table-header-group}}
tr{{break-inside:avoid}}
th{{background:{ACCENT};color:{INK};font-weight:700;text-align:left;
  padding:1.6mm 2mm;border-bottom:0.9pt solid {OCEAN}}}
td{{padding:1.5mm 2mm;border-bottom:0.4pt solid rgba(24,43,75,0.16);
  vertical-align:top}}
/* Value columns never break; prose columns wrap. */
td.v,th.v{{white-space:nowrap;width:1%}}
td.w,th.w{{white-space:normal}}
td .k{{white-space:nowrap}}

section.part{{break-before:page}}
section.part:first-of-type{{break-before:auto}}
"""


def part_page_rules(parts):
    """One CSS named page per Part. Chromium supports neither string-set nor
    string(), measured -- but it does honour named pages with literal content,
    so each Part declares its own running header and claims it with page:pN."""
    css = []
    for n, (title, _) in enumerate(parts, 1):
        css.append(
            f"@page p{n}{{@top-left{{content:\"{title}\";"
            f"font-family:{STACK};font-size:8pt;color:{OCEAN};"
            f"letter-spacing:0.04em;margin-bottom:5mm}}"
            f"@top-right{{content:\"\"}}}}"
            f"section.part.p{n}{{page:p{n}}}"
        )
    return "".join(css)


FRONT_CSS = f"""
{font_faces()}
{COMMON}
/* The cover and the contents carry neither header nor page number. They are a
   separate document from the body, so there is no counter here to suppress. */
@page{{size:A4 portrait;margin:22mm 20mm 20mm 20mm;background:{PAGE_BG}}}
@page cover{{margin:0}}
body{{background:{PAGE_BG}}}

section.cover{{page:cover;break-after:page;position:relative;
  width:210mm;height:297mm;overflow:hidden;background:{PAGE_BG}}}
/* The sphere. Faint, Forest Green, bleeding off the lower outer corner --
   printed matter, which is the permitting side of the 2026-09-02 ruling. */
.cover .watermark{{position:absolute;right:-58mm;bottom:-64mm;
  width:216mm;height:216mm;opacity:0.10}}
.cover .watermark img{{width:100%;height:100%}}
.cover .wordmark{{position:absolute;left:26mm;top:64mm;width:104mm}}
.cover .wordmark img{{width:100%;display:block}}
.cover h1{{position:absolute;left:26mm;top:118mm;width:150mm;
  margin:0;font-size:25pt;line-height:1.24;font-weight:700;color:{INK};
  letter-spacing:-0.01em}}
.cover .keel{{position:absolute;left:26mm;top:108mm;
  width:34mm;height:2.4pt;background:{FOREST}}}

h2.toch{{font-size:20pt;font-weight:700;color:{OCEAN};margin:0 0 8mm 0}}
.tocpart{{font-size:10.5pt;font-weight:700;color:{FOREST};
  margin:7mm 0 2.5mm 0;letter-spacing:0.03em;break-after:avoid}}
.tocpart:first-of-type{{margin-top:0}}
.toc{{list-style:none;margin:0;padding:0}}
.toc li{{display:flex;align-items:baseline;margin:0 0 1.7mm 0;font-size:10pt}}
.toc .num{{flex:0 0 13mm;font-weight:700;color:{OCEAN}}}
.toc .name{{flex:0 1 auto}}
.toc .dots{{flex:1 1 auto;margin:0 2mm;border-bottom:0.5pt dotted
  rgba(24,43,75,0.42);transform:translateY(-1.2pt)}}
.toc .pg{{flex:0 0 auto;font-weight:700;font-variant-numeric:tabular-nums}}
"""


# --------------------------------------------------------------------------
# Document assembly
# --------------------------------------------------------------------------

def split_parts(blocks):
    """-> (manual title, [(part title, [blocks]), ...]).
    Everything before the first PART heading is the title, which belongs on
    the cover and nowhere else."""
    title, parts, cur = None, [], None
    for kind, payload in blocks:
        if kind == "h" and payload[0] == 1:
            text = payload[1]
            if text.upper().startswith("PART "):
                cur = (text, [])
                parts.append(cur)
                continue
            if cur is None:
                title = text
                continue
        if cur is None:
            if kind == "hr":
                continue
            raise SystemExit(f"content before the first PART heading: {payload!r}")
        cur[1].append((kind, payload))
    if not title or len(parts) != 4:
        raise SystemExit(f"expected a title and 4 parts, got {title!r} / {len(parts)}")
    return title, parts


TOC_NUM = re.compile(r"^(\d+(?:\.\d+)*)\s+(.*)$")


def body_html(parts):
    """The body document: four Parts, each on its own CSS named page."""
    out = [
        "<!-- built from docs/manual-draft.md -->",
        '<meta charset="utf-8">',
        f"<style>{BODY_CSS}{part_page_rules(parts)}</style>",
    ]
    for n, (ptitle, blocks) in enumerate(parts, 1):
        out.append(f'<section class="part p{n}">')
        out.append(f"<h1>{inline(ptitle)}</h1><div class=\"rule\"></div>")
        for kind, payload in blocks:
            if kind == "h":
                level, text = payload
                out.append(f"<h{level}>{inline(text)}</h{level}>")
            elif kind == "p":
                out.append(f"<p>{inline(payload)}</p>")
            elif kind == "list":
                out.append(render_list(*payload))
            elif kind == "table":
                out.append(render_table(payload[0]))
            elif kind == "hr":
                out.append("<hr>")
            else:
                raise SystemExit(f"unhandled block {kind}")
        out.append("</section>")
    return "\n".join(out)


def toc_entries(parts):
    """Parts, and every numbered subsection beneath them. Unnumbered headings
    ("Step 3 -- Record the processing run") are working subdivisions of a
    procedure, not places a reader looks up, and stay out of the contents."""
    entries = []
    for ptitle, blocks in parts:
        subs = []
        for kind, payload in blocks:
            if kind != "h":
                continue
            level, text = payload
            m = TOC_NUM.match(text)
            if m and level in (2, 3):
                subs.append((m.group(1), m.group(2), text))
        entries.append((ptitle, subs))
    return entries


def front_html(title, entries, pagemap):
    wordmark = BRAND / "evoltrya-wordmark.svg"
    sphere = BRAND / "evoltrya-sphere.svg"
    for f in (wordmark, sphere):
        if not f.exists():
            raise SystemExit(f"missing cover asset: {f}")

    out = [
        '<meta charset="utf-8">',
        f"<style>{FRONT_CSS}</style>",
        '<section class="cover">',
        f'<div class="watermark"><img src="file://{sphere}" alt=""></div>',
        f'<div class="wordmark"><img src="file://{wordmark}" alt=""></div>',
        '<div class="keel"></div>',
        f"<h1>{html.escape(title)}</h1>",
        "</section>",
        "<section><h2 class=\"toch\">Contents</h2>",
    ]
    for ptitle, subs in entries:
        out.append(f'<div class="tocpart">{html.escape(ptitle)}</div>')
        out.append('<ul class="toc">')
        for num, name, full in subs:
            pg = pagemap[full]
            out.append(
                f'<li><span class="num">{num}</span>'
                f'<span class="name">{inline(name)}</span>'
                f'<span class="dots"></span>'
                f'<span class="pg">{pg}</span></li>'
            )
        out.append("</ul>")
    out.append("</section>")
    return "\n".join(out)


# --------------------------------------------------------------------------
# Rendering and measurement
# --------------------------------------------------------------------------

def chrome():
    for c in CHROME_CANDIDATES:
        if c.exists():
            return c
    raise SystemExit("no chrome-headless-shell found in the puppeteer cache")


def render(html_text, name):
    BUILD.mkdir(exist_ok=True)
    src = BUILD / f"{name}.html"
    pdf = BUILD / f"{name}.pdf"
    src.write_text(html_text, encoding="utf-8")
    if pdf.exists():
        pdf.unlink()
    proc = subprocess.run(
        [str(chrome()), "--headless", "--disable-gpu", "--no-sandbox",
         "--no-pdf-header-footer", "--virtual-time-budget=20000",
         f"--print-to-pdf={pdf}", f"file://{src}"],
        capture_output=True, text=True,
    )
    if not pdf.exists():
        sys.stderr.write(proc.stderr)
        raise SystemExit(f"chromium produced no PDF for {name}")
    return pdf


def squash(s):
    return re.sub(r"\s+", "", s)


def page_texts(pdf):
    from pypdf import PdfReader
    return [p.extract_text() or "" for p in PdfReader(str(pdf)).pages]


def measure_pages(pdf, entries):
    """Which printed page does each contents entry land on?

    Matched on the heading text with all whitespace removed, so a heading that
    wrapped across two lines in the PDF still matches. The body is a document
    of its own, so a heading string cannot collide with its own contents entry
    -- the contents is not in this file yet."""
    texts = [squash(t) for t in page_texts(pdf)]
    pagemap, missing = {}, []
    for ptitle, subs in entries:
        for num, name, full in subs:
            needle = squash(full)
            for n, t in enumerate(texts, 1):
                if needle in t:
                    pagemap[full] = n
                    break
            else:
                missing.append(full)
    if missing:
        raise SystemExit("headings not found in the rendered body:\n  " +
                         "\n  ".join(missing))
    return pagemap


# --------------------------------------------------------------------------
# Merge and metadata
# --------------------------------------------------------------------------

COMPANY = "Evoltrya"


def merge(front_pdf, body_pdf, out):
    """Front matter, then body. Chromium stamps /Producer (Skia/PDF m152) and
    /Creator (Chromium) into everything it prints, and both name a tool. They
    are overwritten here, not blanked, so the fields carry the company rather
    than being conspicuously absent."""
    from pypdf import PdfReader, PdfWriter
    w = PdfWriter()
    for pdf in (front_pdf, body_pdf):
        for page in PdfReader(str(pdf)).pages:
            w.add_page(page)
    w.add_metadata({
        "/Title": "Evoltrya OS — Operations Manual",
        "/Author": COMPANY,
        "/Creator": COMPANY,
        "/Producer": COMPANY,
        "/Subject": "",
        "/Keywords": "",
    })
    # Chromium emits no XMP packet; if a future one does, it would carry the
    # tool name past the fields above, so it is dropped rather than trusted.
    try:
        if w._root_object.get("/Metadata") is not None:
            del w._root_object["/Metadata"]
    except Exception:
        pass
    with open(out, "wb") as fh:
        w.write(fh)


def font_coverage(md_text):
    """Every character the manual uses must be drawable by a face that is
    actually embedded. A missing glyph in Chromium is a blank, not a box, so
    nothing about the PDF would look wrong -- this is the only place it shows."""
    from fontTools.ttLib import TTFont
    covered = set()
    for f in ("GoogleSans-Regular.ttf", "GoogleSans-Bold.ttf",
              "NotoSansSC-Regular.ttf", "NotoSansSC-Bold.ttf"):
        covered |= set(TTFont(FONTS / f, lazy=True).getBestCmap().keys())
    missing = sorted({ord(c) for c in md_text
                      if c not in "\n\r\t" and ord(c) not in covered})
    return [(hex(c), chr(c)) for c in missing]


def main():
    md = SRC.read_text(encoding="utf-8")

    gaps = font_coverage(md)
    if gaps:
        raise SystemExit("characters no embedded face can draw: " + repr(gaps))

    blocks = parse(md)
    title, parts = split_parts(blocks)
    entries = toc_entries(parts)

    # Pass 1 -- the body alone. Its page numbers are final the moment it exists.
    body_pdf = render(body_html(parts), "body")
    pagemap = measure_pages(body_pdf, entries)

    # Pass 2 -- the front matter, against numbers that can no longer move.
    front_pdf = render(front_html(title, entries, pagemap), "front")

    merge(front_pdf, body_pdf, OUT)

    from pypdf import PdfReader
    nf = len(PdfReader(str(front_pdf)).pages)
    nb = len(PdfReader(str(body_pdf)).pages)
    print(f"front matter {nf} pages · body {nb} pages · {nf + nb} total")
    print(f"contents entries {sum(len(s) for _, s in entries)}")
    print(f"wrote {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
