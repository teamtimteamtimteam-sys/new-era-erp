#!/usr/bin/env node
// CONTRACT-ESIGN · the signing path's PDF half, proven locally (Tim 2026-10-30: the signing path is proven on the local rebuild, not on live).
//   Runs the real lib/contractFiles.ts stampPdf (via jiti; 'server-only' mapped to an empty module) on a real two-page PDF, with a drawn-like
//   PNG signature and a PNG stamp: page 2, signature at the default (0.75, 0.88), stamp at (0.52, 0.88); a Latin name (Helvetica) and a Chinese
//   name (Noto Sans SC, embedded whole). Then: the source bytes are unchanged; the output opens; page count is the same; the output's sha256;
//   a password-protected PDF is refused by name; page 3 of a 2-page file is refused by name; a /Rotate 90 page is refused by name.
//   Writes the stamped PDFs to $OUT_DIR for a visual check. No database, no network.
import { createJiti } from 'jiti'
import { writeFileSync, mkdirSync } from 'node:fs'
import { join } from 'node:path'
import { createHash } from 'node:crypto'
const ROOT = new URL('../../../', import.meta.url).pathname
const OUT = process.env.OUT_DIR || '/tmp/ces-stamp-local'
mkdirSync(OUT, { recursive: true })
writeFileSync(join(OUT, 'server-only.js'), '')
const jiti = createJiti(import.meta.url, { alias: { '@': ROOT.replace(/\/$/, ''), 'server-only': join(OUT, 'server-only.js') } })
const lib = await jiti.import(join(ROOT, 'lib/contractFiles.ts'))
const { PDFDocument, degrees } = await jiti.import('pdf-lib')
const sharp = (await jiti.import('sharp')).default
const sha = (b) => createHash('sha256').update(b).digest('hex')
let bad = 0
const ok = (c, w) => { console.log(`${c ? 'PASS' : 'FAIL'}|${w}`); if (!c) bad++ }

const d = await PDFDocument.create()
for (let i = 1; i <= 2; i++) { const p = d.addPage([595, 842]); p.drawText(`Supply agreement — page ${i}`, { x: 60, y: 780, size: 18 }); p.drawText('For and on behalf of the Company: ______________________', { x: 60, y: 120, size: 11 }) }
const source = await d.save()
const sourceSha = sha(source)
// a signature-like PNG (transparent, dark stroke) and a red round stamp, made with sharp from SVG
const sig = await sharp(Buffer.from('<svg xmlns="http://www.w3.org/2000/svg" width="600" height="200"><path d="M20 150 C 120 20, 180 190, 260 90 S 420 40, 580 130" stroke="#111827" stroke-width="10" fill="none"/></svg>')).png().toBuffer()
const stamp = await sharp(Buffer.from('<svg xmlns="http://www.w3.org/2000/svg" width="300" height="300"><circle cx="150" cy="150" r="135" stroke="#c0392b" stroke-width="14" fill="none"/><text x="150" y="165" font-size="40" text-anchor="middle" fill="#c0392b">COMPANY</text></svg>')).png().toBuffer()

for (const [label, name] of [['latin', 'Probe Director Lee'], ['chinese', '签署人 甲']]) {
    const r = await lib.stampPdf({ source, specimenPng: sig, stampPng: stamp, signature: { page: 2, x: 0.75, y: 0.88 }, stamp: { page: 2, x: 0.52, y: 0.88 },
        signerName: name, signerTitle: 'Director', signedAt: new Date('2026-10-30T14:05:00Z') })
    ok(r.ok, `${label}: stampPdf returned a PDF`)
    if (!r.ok) continue
    const out = Buffer.from(r.bytes)
    writeFileSync(join(OUT, `signed-${label}.pdf`), out)
    const back = await PDFDocument.load(out)
    ok(back.getPageCount() === 2 && sha(source) === sourceSha && sha(out) !== sourceSha,
       `${label}: output opens, 2 pages, source bytes unchanged (${sourceSha.slice(0, 12)}…), output ${out.length} bytes sha256 ${sha(out).slice(0, 16)}…`)
}
// a well-formed PDF whose trailer names an /Encrypt dictionary (what a password-protected file looks like to a parser)
const ed = await PDFDocument.create(); ed.addPage()
const enc = Buffer.from(Buffer.from(await ed.save({ useObjectStreams: false })).toString('latin1')
    .replace(/trailer\s*<</, 'trailer\n<<\n/Encrypt << /Filter /Standard /V 1 /R 2 /O (x) /U (y) /P -4 >>'), 'latin1')
const e = await lib.stampPdf({ source: enc, specimenPng: sig, stampPng: null, signature: { page: 1, x: 0.5, y: 0.5 }, stamp: null, signerName: 'x', signerTitle: 'y', signedAt: new Date() })
ok(!e.ok && e.code === 'CONTRACT_PDF_ENCRYPTED', `a password-protected PDF → ${e.ok ? 'stamped' : e.code}`)
const p3 = await lib.stampPdf({ source, specimenPng: sig, stampPng: null, signature: { page: 3, x: 0.5, y: 0.5 }, stamp: null, signerName: 'x', signerTitle: 'y', signedAt: new Date() })
ok(!p3.ok && p3.code === 'CONTRACT_SIGN_PAGE_OUT_OF_RANGE', `page 3 of a 2-page file → ${p3.ok ? 'stamped' : p3.code}`)
const rd = await PDFDocument.load(source); rd.getPages()[1].setRotation(degrees(90)); const rotated = await rd.save()
const rr = await lib.stampPdf({ source: rotated, specimenPng: sig, stampPng: null, signature: { page: 2, x: 0.5, y: 0.5 }, stamp: null, signerName: 'x', signerTitle: 'y', signedAt: new Date() })
ok(!rr.ok && rr.code === 'CONTRACT_SIGN_PAGE_ROTATED', `a /Rotate 90 page → ${rr.ok ? 'stamped' : rr.code}`)
const chk = await lib.checkPdf(enc)
ok(!chk.ok && chk.code === 'CONTRACT_PDF_ENCRYPTED', `checkPdf (the upload's finish step) on the password-protected PDF → ${chk.ok ? 'accepted' : chk.code}`)
console.log(`STAMP_LOCAL_EXIT=${bad ? 1 : 0}`)
process.exit(bad ? 1 : 0)
