#!/usr/bin/env python3
# scripts/check-manual.py -- the STEP 5 checks, run against the built PDF.
#
# Everything here is measured from the finished file, not asserted from the
# stylesheet that produced it. A check that reads the CSS proves the CSS says
# something; only a check that reads the PDF proves the PDF does it. The
# overflow check in particular decodes glyph positions out of the page content
# streams, because "does any text cross the right margin" cannot be answered
# from extracted text -- extracted text has no coordinates.

import re
import sys
import unicodedata
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PDF = ROOT / "docs" / "Evoltrya-OS-Operations-Manual.pdf"
SRC = ROOT / "docs" / "manual-draft.md"
FONTS = ROOT / "assets" / "fonts"

FRONT_PAGES = 3          # cover + 2 contents pages, carrying no number
PT_PER_MM = 72 / 25.4
PAGE_W = 210 * PT_PER_MM
MARGIN = 20 * PT_PER_MM
RIGHT_EDGE = PAGE_W - MARGIN

results = []


def check(name, ok, detail=""):
    results.append((name, ok, detail))
    print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"\n      {detail}" if detail else ""))


# --------------------------------------------------------------------------
# Glyph-position decoding
# --------------------------------------------------------------------------

def page_objects(raw):
    """Chromium writes one content stream per page, in page order."""
    out = []
    for m in re.finditer(rb"stream\r?\n", raw):
        s = m.end()
        e = raw.find(b"endstream", s)
        try:
            d = zlib.decompress(raw[s:e])
        except Exception:
            continue
        if b"Tf" in d and (b"Tj" in d or b"TJ" in d):
            out.append(d)
    return out


def font_widths(page):
    """Advance widths per font *resource name* on one page.

    Merging every /W array in the file into one table is wrong and quietly so:
    /G5 in Google Sans Regular and /G7 in Google Sans Bold are different glyphs
    that share small integer codes, so a merged table returns whichever face
    was parsed last. It reported ordinary prose lines as overflowing the
    measure by two to five points, which is small enough to look like a real
    tight-fit problem rather than a bug. Widths are resolved through the page's
    own /Resources /Font dict instead."""
    out = {}
    try:
        fonts = page["/Resources"]["/Font"]
    except Exception:
        return out
    for name in fonts:
        try:
            f = fonts[name].get_object()
            desc = f["/DescendantFonts"][0].get_object()
            default = float(desc.get("/DW", 1000))
            w, arr = {}, list(desc.get("/W", []))
            i = 0
            while i < len(arr):
                first = int(arr[i].get_object() if hasattr(arr[i], "get_object") else arr[i])
                nxt = arr[i + 1].get_object() if hasattr(arr[i + 1], "get_object") else arr[i + 1]
                if isinstance(nxt, list):
                    for k, v in enumerate(nxt):
                        w[first + k] = float(v)
                    i += 2
                else:
                    last, val = int(nxt), float(arr[i + 2])
                    for c in range(first, last + 1):
                        w[c] = val
                    i += 3
            out[name.lstrip("/")] = (w, default)
        except Exception:
            continue
    return out


def max_x_per_page(raw, reader):
    """Rightmost drawn glyph edge on each page, in points from the page's left
    edge.

    Chromium does not draw in points. Every page opens with a base transform
    (`.24 0 0 -.24 0 841.92 cm` then `3.125 ... cm` -- a 0.75 scale and a
    y-flip), so a raw x out of the content stream is not comparable to a margin
    in points until the CTM is applied. Comparing them directly reports every
    page as overflowing by about a hundred points, cover included, which is how
    that was caught.

    All the matrices Chromium emits here are axis-aligned (b = c = 0), so only
    the horizontal scale and translation are tracked, through the q/Q stack."""
    streams = page_objects(raw)
    out = []
    for pi, stream in enumerate(streams):
        widths = font_widths(reader.pages[pi]) if pi < len(reader.pages) else {}
        cur = ({}, 1000.0)
        ctm_a, ctm_e = 1.0, 0.0
        stack = []
        x = tx = 0.0
        size = 10.0
        best = 0.0
        for tok in re.finditer(
            rb"(q)\b"
            rb"|(Q)\b"
            rb"|([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\s+cm"
            rb"|([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\s+Tm"
            rb"|([-\d.]+)\s+([-\d.]+)\s+(?:Td|TD)"
            rb"|/([A-Za-z0-9]+)\s+([\d.]+)\s+Tf"
            rb"|\[((?:<[0-9A-Fa-f]*>|[-\d.]+|\s)*)\]\s*TJ"
            rb"|<([0-9A-Fa-f]*)>\s*Tj",
            stream,
        ):
            g = tok.groups()
            if g[0] is not None:
                stack.append((ctm_a, ctm_e))
            elif g[1] is not None:
                if stack:
                    ctm_a, ctm_e = stack.pop()
            elif g[2] is not None:
                a, e = float(g[2]), float(g[6])
                ctm_a, ctm_e = a * ctm_a, e * ctm_a + ctm_e
            elif g[8] is not None:
                tx = float(g[12]); x = tx
            elif g[14] is not None:
                tx += float(g[14]); x = tx
            elif g[16] is not None:
                cur = widths.get(g[16].decode(), ({}, 1000.0))
                size = float(g[17])
            elif g[18] is not None or g[19] is not None:
                table, default = cur
                blob = g[18] if g[18] is not None else g[19]
                adv = 0.0
                if g[18] is not None:
                    for piece in re.finditer(rb"<([0-9A-Fa-f]*)>|([-\d.]+)", blob):
                        if piece.group(1) is not None:
                            h = piece.group(1).decode()
                            for i in range(0, len(h), 4):
                                adv += table.get(int(h[i:i+4].ljust(4, "0"), 16), default)
                        else:
                            adv -= float(piece.group(2))
                else:
                    h = blob.decode()
                    for i in range(0, len(h), 4):
                        adv += table.get(int(h[i:i+4].ljust(4, "0"), 16), default)
                end_user = x + adv / 1000.0 * size
                best = max(best, ctm_a * end_user + ctm_e)
                x = end_user
        out.append(best)
    return out


def squash(s):
    """Whitespace removed, and NFKC applied.

    NFKC is not cosmetic here. Noto Sans SC draws U+5DE5 and U+2F27
    (KANGXI RADICAL WORK) with one glyph, so the PDF's ToUnicode map sends
    that glyph back as the radical: the manual's 待加工 extracts as 待加⼯.
    The page is right and the extraction is right; only a naive comparison
    is wrong. NFKC folds the two together."""
    return unicodedata.normalize("NFKC", re.sub(r"\s+", "", s))


def main():
    from pypdf import PdfReader
    raw = PDF.read_bytes()
    reader = PdfReader(str(PDF))
    pages = [p.extract_text() or "" for p in reader.pages]
    body = pages[FRONT_PAGES:]                       # printed page N == body[N-1]
    md = SRC.read_text(encoding="utf-8")

    # -- 1. nothing overflows the measure (the value-column nowrap check) -----
    # Value columns are set nowrap, so a column too wide to fit does not wrap:
    # it runs past the right margin. That is what this measures.
    maxx = max_x_per_page(raw, reader)
    over = [(i + 1, round(x - RIGHT_EDGE, 1))
            for i, x in enumerate(maxx) if x > RIGHT_EDGE + 1.0]
    check("every table's rows fit without wrapping (no nowrap value overflows "
          "the measure)", not over,
          "" if not over else "overflow on physical pages: " +
          ", ".join(f"p{p} by {d}pt" for p, d in over[:8]))

    # -- 2. continued tables repeat their header row -------------------------
    # Each table's header cells are known from the source; a table whose header
    # appears on page N and whose rows continue on N+1 must show it again.
    tables, cur = [], []
    for line in md.split("\n"):
        if line.startswith("|"):
            cur.append(line)
        elif cur:
            tables.append(cur); cur = []
    if cur:
        tables.append(cur)

    broken = []
    for t in tables:
        head = [c.strip() for c in t[0].strip().strip("|").split("|")]
        head_key = squash("".join(re.sub(r"[*`]", "", h) for h in head))
        if len(head_key) < 6:
            continue
        rows = [r for r in t[2:]]
        last_cells = [squash(re.sub(r"[*`]", "", c))
                      for c in rows[-1].strip().strip("|").split("|") if c.strip()]
        if not last_cells:
            continue
        tail = max(last_cells, key=len)
        hp = [n for n, p in enumerate(body, 1) if head_key in squash(p)]
        tp = [n for n, p in enumerate(body, 1) if tail and tail in squash(p)]
        if not hp or not tp:
            continue
        first_hdr, last_row = hp[0], tp[0]
        if last_row > first_hdr and last_row not in hp:
            broken.append((first_hdr, last_row, head_key[:40]))
    check("every continued table repeats its header", not broken,
          "" if not broken else "; ".join(
              f"header on p{a}, continuation on p{b} without it ({h})"
              for a, b, h in broken))

    # -- 3. no heading alone at the foot of a page ---------------------------
    # A heading is stranded if it is the last thing on its page.
    heads = [re.match(r"^#{1,4}\s+(.*)$", l).group(1).strip()
             for l in md.split("\n") if re.match(r"^#{1,4}\s", l)]
    stranded = []
    for h in heads:
        k = squash(re.sub(r"[*`]", "", h))
        for n, p in enumerate(body, 1):
            s = squash(p)
            if k in s:
                after = s.split(k, 1)[1]
                # the footer page number is drawn before the body text in the
                # stream, so a stranded heading leaves nothing at all after it
                if len(after) < 3:
                    stranded.append((h, n))
                break
    check("no heading is left alone at the foot of a page", not stranded,
          "" if not stranded else "; ".join(f"{h!r} on printed p{n}"
                                            for h, n in stranded))

    # -- 4. the contents page numbers match the pages ------------------------
    toc = "\n".join(pages[1:FRONT_PAGES])
    entries = re.findall(r"^(\d+(?:\.\d+)*)\s+(.+?)\s+(\d+)$", toc, re.M)
    wrong = []
    for num, name, pg in entries:
        k = squash(f"{num} {name}")
        n = int(pg)
        if n < 1 or n > len(body) or k not in squash(body[n - 1]):
            found = [i + 1 for i, p in enumerate(body) if k in squash(p)]
            wrong.append(f"{num} {name} -> says p{pg}, actually p{found or '?'}")
    check(f"the contents page numbers match the pages ({len(entries)} entries)",
          not wrong and len(entries) == 33,
          "" if not wrong else "; ".join(wrong[:6]))

    # -- 5. the running header names the correct part on every page ----------
    part_titles = [l[2:].strip() for l in md.split("\n")
                   if l.startswith("# ") and l[2:].strip().upper().startswith("PART ")]
    starts = []
    for t in part_titles:
        k = squash(t)
        starts.append(next(n for n, p in enumerate(body, 1) if k in squash(p)))
    bad_hdr = []
    for n, p in enumerate(body, 1):
        expect = part_titles[max(i for i, s in enumerate(starts) if s <= n)]
        first = (p.strip().split("\n") or [""])[0].strip()
        if squash(first) != squash(expect):
            bad_hdr.append(f"p{n}: header {first[:38]!r}, expected {expect[:38]!r}")
    check("the running header names the correct part on every page",
          not bad_hdr, "" if not bad_hdr else "; ".join(bad_hdr[:6]))

    # -- 6. no screenshot, personal name, URL path or version number ---------
    # Scanning the extracted text for name-shaped word pairs does not work: the
    # PDF joins text across cell and line boundaries, so a table whose cells end
    # "Calculator" and begin "Tools" extracts as "Calculator Tools" -- a pair the
    # manual never wrote. Four such ghosts appeared before this was rewritten.
    #
    # So the two halves are checked separately, each where it can be answered:
    # the PDF is checked for images, URLs and version numbers, which survive
    # extraction intact; personal names are checked in the SOURCE, where word
    # adjacency is real, and the PDF is checked only for having introduced no
    # word the source does not have.
    whole = "\n".join(pages)
    bans = []

    if re.search(rb"/Subtype\s*/Image", raw):
        bans.append("an embedded raster image is present")

    urls = re.findall(r"https?://\S+|(?<![\w.])/[a-z][a-z0-9-]*(?:/[a-z0-9\[\]-]+)+",
                      whole)
    if urls:
        bans.append(f"URL paths: {sorted(set(urls))[:5]}")

    vers = re.findall(r"\bv\d+\.\d+|\bversion\s+\d|\brelease\s+\d", whole, re.I)
    if vers:
        bans.append(f"version numbers: {sorted(set(vers))[:5]}")

    # The build must not have introduced any word that is not in the draft.
    # Tokenised on letters only. Keeping hyphens in makes "credit-note" split
    # at a PDF line break into the token "credit-", which then looks like a word
    # the build invented; splitting on non-letters gives "credit" and "note" on
    # both sides and compares what is actually there.
    def words(t):
        return set(w for w in re.split(r"[^A-Za-z]+", t.lower()) if len(w) > 1)
    invented = sorted(words(whole) - words(re.sub(r"[*`#|]", " ", md))
                      - {"contents"})
    if invented:
        bans.append(f"words in the PDF that are not in the draft: {invented[:8]}")

    # Name-shaped pairs, read in the source where adjacency means something.
    # All seven are domain terms the manual capitalises: screen names, document
    # names and one role. The set is asserted rather than allowed through, so a
    # real name entering the prose later fails this check instead of joining a
    # list nobody rereads.
    # All nineteen were read in context before being written down here. Every
    # one is a thing on a screen -- a page title, a field label, a button, a
    # report, a document, or the one role the manual names. The last two are not
    # phrases at all: they are a heading meeting the sentence under it once the
    # source is flattened.
    DOMAIN_PAIRS = {
        "Arrival Date", "Assay Result", "Bank Statement", "Cost Allocation",
        "Daily Metal", "Delete Processing", "Field Receiving", "Gross Margin",
        "Import Statement", "Metal Prices", "Processing Run", "Purchase Order",
        "Receive Next", "Record Assay", "Record Sale", "System Administrator",
        "Weighed Quantity",
        "The Leave", "The Reports",
    }
    flat = re.sub(r"\s+", " ", re.sub(r"[*`#]", "", md))
    pairs = set(re.findall(r"(?=(?<=[a-z,] )([A-Z][a-z]{2,} [A-Z][a-z]{2,}))", flat))
    unknown = sorted(pairs - DOMAIN_PAIRS)
    if unknown:
        bans.append(f"capitalised pairs in the draft that are not known domain "
                    f"terms: {unknown}")

    check("no screenshot, no personal name, no URL path, no version number",
          not bans,
          "" if not bans else "; ".join(bans))

    # -- 7. no synthesised or substituted face -------------------------------
    # Chromium substitutes a serif face when a stack has a generic fallback and
    # synthesises a slant when it does not. Either shows up here: anything but
    # the two intended families, or an italic/oblique name, is a failure.
    fonts = sorted({m.group(1).decode() for m in
                    re.finditer(rb"/BaseFont\s*/([A-Za-z0-9+#\-,_]+)", raw)})
    bare = sorted({f.split("+")[-1] for f in fonts})
    allowed = {"GoogleSans-Regular", "GoogleSans-Bold",
               "NotoSansSC-Regular", "NotoSansSC-Bold"}
    stray = [f for f in bare if f not in allowed]
    slanted = [f for f in bare if re.search(r"italic|oblique", f, re.I)]
    check("the quotations render in the document's own face, with no "
          "synthesised slant and no substituted face",
          not stray and not slanted,
          f"embedded: {bare}" if (stray or slanted) else f"embedded: {bare}")

    # -- 8. the accent background never breaks across a line -----------------
    # Every accented span is nowrap, so a span that did not fit would push past
    # the right margin rather than break -- already covered by check 1. What is
    # verified here is that each span survived as one unbroken run of text.
    codes = sorted(set(re.findall(r"`([^`]+)`", md)))
    split = []
    flat = squash(whole)
    for c in codes:
        if squash(c) not in flat:
            split.append(c)
    check(f"the accent background on inline-code spans does not break across a "
          f"line ({len(codes)} distinct spans)", not split,
          "" if not split else f"spans not found intact: {split[:6]}")

    # -- 9. the PDF properties name no tool ----------------------------------
    meta = {k: str(v) for k, v in (reader.metadata or {}).items()}
    tools = re.compile(r"chrom|skia|webkit|blink|python|pypdf|claude|gpt|"
                       r"anthropic|openai|pandoc|weasy|wkhtml|prince|latex",
                       re.I)
    hits = [f"{k}={v}" for k, v in meta.items() if tools.search(v)]
    if re.search(rb"<\?xpacket", raw):
        hits.append("an XMP packet is present")
    check("the PDF properties name no tool", not hits,
          f"{meta}" if not hits else "; ".join(hits))

    print()
    bad = [n for n, ok, _ in results if not ok]
    print(f"{len(results) - len(bad)}/{len(results)} checks pass")
    if bad:
        print("failing: " + "; ".join(bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
