# Operations manual — how the PDF is built

**Cut** MANUAL-2 · **Draft at** `0ea22fd`
**No version number, no release note** — this cut takes neither, and neither does the PDF.

Build it with:

    python3 scripts/build-manual.py     # -> docs/Evoltrya-OS-Operations-Manual.pdf
    python3 scripts/check-manual.py     # the nine checks, against the built file

Nothing had to be installed for either. Everything below was already on the machine.

## The typeface

**The manual is set in the same faces, from the same files, as every other document this
system prints:** Google Sans with Noto Sans SC behind it, out of `assets/fonts/`. That is the
stack `DOC_FONT_STACK` resolves to in `app/components/pdf/fonts.ts`, which is what the
invoices, the statements and the purchase orders are printed in. A manual set in some other
face would be the one document a customer or a member of staff receives that does not look
like the rest.

Noto carries three Chinese words, in the passage in 3.6 about the inbound CSV export, and
nothing else in the manual. It stays in the stack after those words go — see
`docs/manual-known-gaps.md`.

### There is no italic, and the quotations are set upright

Neither face has an italic, and no italic is declared anywhere in the stylesheet. That is
deliberate, because declaring one licenses the renderer to invent one. Both of its inventions
were measured before the decision was taken:

* with a generic family anywhere in the stack, Chromium silently substitutes **Times New
  Roman** — a serif face, in a document that has none;
* with a single family, it **synthesises a slant** by shearing the upright.

The manual quotes on-screen refusal text in 42 places. All but one of those quotations already
carry double quotation marks, which is what marks them as quoted; the remaining one names a
state that is given in bold two lines above it. So they are set upright and the punctuation
does the work. Nothing is added around them — no background, no rule, no change of indent.

## The page

A4 portrait, 20 mm outer margins. Body 10 pt, tables 8.5 pt. Palette from the brand guide:
Hawaiian Ocean `#008EBC` for headings, Forest Green `#6B8D54` for the third level and the
cover rule, `#F1F9FE` as the page ground, `#E1F5FF` behind inline-code spans, `#182B4B` for text.

* **Cover** — the colour wordmark `public/brand/evoltrya-wordmark.svg`, the same file the login
  page and the home page use, in the upper third; `evoltrya-sphere.svg` faint behind it, bleeding
  off the lower outer corner; the title, and nothing else. No date, no version, no author, no
  address. The sphere is on it under the LOGIN-1 ruling of 2026-09-02, which places the sphere
  on printed matter; a manual PDF is printed matter.
* **Contents** — every Part, and every numbered subsection under it, with real page numbers.
* **Running headers** — the Part's name at the left of the header, the right side empty.
* **Page numbers** — footer, centred. The cover and the contents carry neither.
  **Page 1 is the first page of Part 1.**
* **Tables** — a column whose widest cell is 32 characters or fewer is a *value* column: it is
  set `nowrap` and never breaks. Wider columns are prose in a cell and wrap as prose. A table
  that runs past the foot of a page repeats its header row at the top of the continuation.
* **Inline code** — every one of the 199 spans takes the accent block, in the body face, never
  monospace, and `nowrap` so the background cannot break across a line.

## Why the build runs Chromium twice

The route is markdown → HTML → PDF, rendered by the Chrome for Testing already in the
puppeteer cache, driven from the command line. Four things were measured on it before any of
this was written, because the spec depends on all four:

| | |
|---|---|
| embeds a local font file | **yes** — subset and embedded from a `file://` reference |
| `@page` size, margins, margin boxes, `counter(page)` | **yes** |
| repeats a table header row on continuation | **yes** |
| `target-counter()` for contents page numbers | **no — produces nothing** |
| `string-set` / `content: string()` for running headers | **no — renders an empty box** |
| `counter-reset: page` | **no — ignored** |

The last three shape the build.

**Running headers** are done with CSS *named pages* instead, which Chromium does support:
each Part declares `@page pN` with its own literal header text and claims it with `page: pN`.

**Contents page numbers** have to be measured out of a rendered PDF and written back. The
usual trap there is circular — numbering the contents changes its length, which moves the
body, which changes the numbers. This build does not have that problem, because **the front
matter is a separate document from the body**. The body is rendered once, alone, and its page
numbers are final the moment it exists. The front matter is then rendered against numbers that
can no longer move, and merged in front with pypdf. Nothing iterates and nothing converges; the
numbers are right on the first pass or the build fails and says which heading it could not find.

Separating the two documents is also what puts page 1 on Part 1. Chromium ignores
`counter-reset: page`, so a single-document build cannot restart the count after the front
matter; two documents make the body's own count start at 1 with nothing to reset.

**Metadata.** Chromium stamps `/Producer (Skia/PDF m152)` and `/Creator (Chromium)` into
everything it prints. Both name a tool, so both are overwritten with the company name rather
than blanked, and any XMP packet is dropped.

## Why there is a converter in the repo instead of a library call

There is no markdown library installed here in any language. That turned out to be the right
situation rather than a gap, because three of the manual's requirements need control a general
converter does not offer: every inline-code span has to be marked so it can be made unbreakable,
each Part has to be wrapped in its own named-page section, and table columns are set to wrap or
not per column after measuring the widest cell in each. The manual uses a narrow subset — no
HTML, no links, no blockquotes, two list levels — so the converter is small and total over that
subset. It raises on anything it does not recognise rather than passing it through, because
silently emitting unhandled markdown is how a document ships with `**bold**` printed on page 40.

## The checks

`scripts/check-manual.py` runs the nine STEP 5 checks **against the built PDF**, not against the
stylesheet that produced it. A check that reads the CSS only proves the CSS says something.

The overflow check decodes glyph positions out of the page content streams, because "does any
text cross the right margin" has no answer in extracted text — extracted text has no
coordinates. Two things about that were wrong at first and are worth knowing, because both
failed in a way that looked like a real document fault:

* **The page CTM was ignored.** Chromium draws through `.24 0 0 -.24 0 841.92 cm` and then
  `3.125 ... cm`. Comparing raw stream x against a margin in points reported every page as
  overflowing by about a hundred points — including the cover, which is what gave it away.
* **Advance widths were merged across fonts.** `/G5` in Google Sans Regular and `/G7` in Google
  Sans Bold are different glyphs sharing small integer codes, so one merged table returns
  whichever face was parsed last. It reported ordinary prose lines as overflowing by two to
  five points — small enough to read as a genuinely tight fit rather than a bug. Widths are
  resolved through each page's own `/Resources /Font` dict now.

Two further checks needed the same care. Text extracted from the PDF returns `待加⼯` where the
source has `待加工`: Noto Sans SC draws U+5DE5 and U+2F27 with one glyph, so the ToUnicode map
sends it back as the Kangxi radical. The page is right; the comparison was not, and is NFKC-folded
now. And scanning extracted text for personal names does not work at all, because the PDF joins
text across cell boundaries — a table whose cells ended "Calculator" and began "Tools" produced
the name-shaped pair "Calculator Tools", which the manual never wrote. Names are checked in the
source, where adjacency is real; the PDF is checked only for having introduced no word the
source does not contain.
