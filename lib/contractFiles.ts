// lib/contractFiles.ts
// CONTRACT-ESIGN(Tim 2026-10-29 · 2026-10-30 Q1–Q12):合同电子文件那一族的服务端共用件 —— 只在服务端用(读 assets/fonts、算 sha256、开 PDF)。
//   ① 常量:两个桶、25 MB(Q12,与桶的 file_size_limit 与 contract_file_begin 同一个数);
//   ② sha256:每一个版本的哈希都由服务端读整份对象算(Q 的范围修改第 3 条),浏览器报的不算;
//   ③ readStored:从存储里取出一个对象的字节并核对哈希 —— 对不上就不交出去(下载路由回 409,签字拒签),与 COD 的 streamStored 同一个形状;
//   ④ stampPdf:把签字样本(与选了的公司印章)盖到一份 PDF 的指定页指定位置,印一行「名字, 职衔 · 时刻 SGT · signed electronically in Evoltrya OS」
//      (Q4 · Q6),另存成一份新的 PDF —— 源文件的字节不动。带密码的 PDF 打不开 → CONTRACT_PDF_ENCRYPTED(按名拒,范围修改第 4 条)。
import 'server-only'
import { createHash } from 'node:crypto'
import { readFileSync } from 'node:fs'
import path from 'node:path'
import { PDFDocument, rgb, EncryptedPDFError, StandardFonts, type PDFFont } from 'pdf-lib'
import fontkit from '@pdf-lib/fontkit'
import sharp from 'sharp'
import type { SupabaseClient } from '@supabase/supabase-js'
import { SIGNATURE_WIDTH_OF_PAGE, STAMP_WIDTH_OF_PAGE } from '@/lib/contractSignLayout'

export const CONTRACT_FILES_BUCKET = 'contract-files'
export const SIGNING_ASSETS_BUCKET = 'signing-assets'
export const CONTRACT_FILE_MAX_BYTES = 26214400   // 25 MB(Tim Q12)

export function sha256Hex(bytes: Uint8Array): string {
    return createHash('sha256').update(bytes).digest('hex')
}

export type StoredRead = { ok: true; bytes: Uint8Array } | { ok: false; code: 'NOT_STORED' | 'HASH_MISMATCH' }

/** 取一个对象的字节,并与登记的 sha256 比一次;对不上 → HASH_MISMATCH(不交出字节) */
export async function readStored(
    supabase: SupabaseClient, bucket: string, objectPath: string, expectedSha256: string | null
): Promise<StoredRead> {
    const { data, error } = await supabase.storage.from(bucket).download(objectPath)
    if (error || !data) return { ok: false, code: 'NOT_STORED' }
    const bytes = new Uint8Array(await data.arrayBuffer())
    if (expectedSha256 !== null && sha256Hex(bytes) !== expectedSha256) return { ok: false, code: 'HASH_MISMATCH' }
    return { ok: true, bytes }
}

export function isPdfHeader(b: Uint8Array): boolean {
    return b.length >= 5 && b[0] === 0x25 && b[1] === 0x50 && b[2] === 0x44 && b[3] === 0x46 && b[4] === 0x2d
}

/** pdf-lib 带密码的那一种拒绝。★ 实测(2026-10-30):它抛出来的错误 constructor.name 是 'Error',instanceof 在打包之后不可靠 ——
 *  所以两样都认:类,或者它自己那句话(「Input document to `PDFDocument.load` is encrypted」)。 */
function isEncrypted(e: unknown): boolean {
    return e instanceof EncryptedPDFError || /\bis encrypted\b/i.test(String((e as { message?: string })?.message ?? ''))
}

export type PdfCheck = { ok: true; pages: number } | { ok: false; code: 'CONTRACT_PDF_ENCRYPTED' | 'CONTRACT_PDF_UNREADABLE' }

/** 这份 PDF 打得开、能盖章吗(带密码 → ENCRYPTED;坏的 → UNREADABLE) */
export async function checkPdf(bytes: Uint8Array): Promise<PdfCheck> {
    try {
        const doc = await PDFDocument.load(bytes, { updateMetadata: false })
        return { ok: true, pages: doc.getPageCount() }
    } catch (e) {
        return { ok: false, code: isEncrypted(e) ? 'CONTRACT_PDF_ENCRYPTED' : 'CONTRACT_PDF_UNREADABLE' }
    }
}

export type Placement = { page: number; x: number; y: number }   // page 从 1 起;x / y 是那一页可见区域里【中心点】的位置,0..1,自左上角量

export type StampInput = {
    source: Uint8Array
    specimenPng: Uint8Array
    stampPng: Uint8Array | null
    signature: Placement
    stamp: Placement | null
    signerName: string
    signerTitle: string
    signedAt: Date
}

export type StampResult =
    | { ok: true; bytes: Uint8Array }
    | { ok: false; code: 'CONTRACT_PDF_ENCRYPTED' | 'CONTRACT_PDF_UNREADABLE' | 'CONTRACT_SIGN_PAGE_OUT_OF_RANGE' | 'CONTRACT_SIGN_PAGE_ROTATED' }

/** 新加坡时间的「YYYY-MM-DD HH:mm」 */
export function sgtStamp(d: Date): string {
    const p = Object.fromEntries(new Intl.DateTimeFormat('en-GB', {
        timeZone: 'Asia/Singapore', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hour12: false,
    }).formatToParts(d).map((x) => [x.type, x.value]))
    return `${p.year}-${p.month}-${p.day} ${p.hour}:${p.minute}`
}

/** 印在签名下面的那一行(Q4) */
export function signedLine(name: string, title: string, at: Date): string {
    return `${name}, ${title} · ${sgtStamp(at)} SGT · signed electronically in Evoltrya OS`
}

let fontBytes: Uint8Array | null = null
function signingFont(): Uint8Array {
    // 中文名字要中文字形:用 PDF 那一族已经在用的 Noto Sans SC 子集(app/components/pdf/fonts.ts 同一个目录)
    if (!fontBytes) fontBytes = readFileSync(path.join(process.cwd(), 'assets', 'fonts', 'NotoSansSC-Regular.subset.ttf'))
    return fontBytes
}

/** 把一行字按宽度拆成几行(按字符拆:中英混排里没有可靠的词边界) */
function wrap(text: string, font: PDFFont, size: number, width: number): string[] {
    const lines: string[] = []
    let cur = ''
    for (const ch of Array.from(text)) {
        const next = cur + ch
        if (cur && font.widthOfTextAtSize(next, size) > width) { lines.push(cur); cur = ch.trimStart() }
        else cur = next
    }
    if (cur) lines.push(cur)
    return lines
}

export async function stampPdf(input: StampInput): Promise<StampResult> {
    let doc: PDFDocument
    try {
        doc = await PDFDocument.load(input.source, { updateMetadata: false })
    } catch (e) {
        return { ok: false, code: isEncrypted(e) ? 'CONTRACT_PDF_ENCRYPTED' : 'CONTRACT_PDF_UNREADABLE' }
    }
    const pages = doc.getPages()
    const inRange = (p: Placement) => Number.isInteger(p.page) && p.page >= 1 && p.page <= pages.length
    if (!inRange(input.signature) || (input.stamp && !inRange(input.stamp))) return { ok: false, code: 'CONTRACT_SIGN_PAGE_OUT_OF_RANGE' }
    // 一页带 /Rotate 时,预览(pdf.js 按转过的样子画)与盖章的坐标(未转的那一面)不是同一面 —— 按名拒,不盖歪(docs/known-issues.md CONTRACT-ESIGN-ROTATED-PAGES)
    const rotated = (p: Placement) => pages[p.page - 1].getRotation().angle % 360 !== 0
    if (rotated(input.signature) || (input.stamp && rotated(input.stamp))) return { ok: false, code: 'CONTRACT_SIGN_PAGE_ROTATED' }
    // 那一行全是西文(WinAnsi 认得的字)→ 内置的 Helvetica,不加一个字节的字体;有中文 → 整份嵌 Noto Sans SC 子集(约 1.4 MB)。
    //   ★ 不用 fontkit 的 subset: true:实测(2026-10-30)它把中文与大半西文字形画成空白,抽得出文字、看不见字 —— 一份签过的合同不能那样。
    const line = signedLine(input.signerName, input.signerTitle, input.signedAt)
    let font: PDFFont
    if (/^[\x20-\x7E\u00A0-\u00FF]*$/.test(line)) {
        font = await doc.embedFont(StandardFonts.Helvetica)
    } else {
        doc.registerFontkit(fontkit)
        font = await doc.embedFont(signingFont(), { subset: false })
    }

    // 一页可见区域(CropBox,没有就 MediaBox)里,自左上角量的中心点 → PDF 坐标(自左下角)
    const place = (p: Placement, widthOfPage: number, aspect: number) => {
        const page = pages[p.page - 1]
        const box = page.getCropBox()
        const w = box.width * widthOfPage
        const h = w * aspect
        const cx = box.x + box.width * p.x
        const cy = box.y + box.height * (1 - p.y)
        return { page, x: cx - w / 2, y: cy - h / 2, w, h }
    }

    if (input.stamp && input.stampPng) {
        const img = await doc.embedPng(input.stampPng)
        const s = place(input.stamp, STAMP_WIDTH_OF_PAGE, img.height / img.width)
        s.page.drawImage(img, { x: s.x, y: s.y, width: s.w, height: s.h })
    }
    const sig = await doc.embedPng(input.specimenPng)
    const g = place(input.signature, SIGNATURE_WIDTH_OF_PAGE, sig.height / sig.width)
    g.page.drawImage(sig, { x: g.x, y: g.y, width: g.w, height: g.h })
    const size = Math.max(5, Math.min(8, g.w / 30))
    const lines = wrap(line, font, size, g.w * 1.4)
    lines.forEach((line, i) => {
        g.page.drawText(line, { x: g.x, y: g.y - (i + 1) * size * 1.25, size, font, color: rgb(0.1, 0.1, 0.1) })
    })
    return { ok: true, bytes: await doc.save({ updateFieldAppearances: false }) }
}

/** 把一张上传或画出来的签字用图收拾成要存的那份 PNG(印章与样本共用) */
export async function normalisePng(input: Buffer, opts: { maxWidth: number; trim: boolean }): Promise<Buffer | null> {
    try {
        const meta = await sharp(input).metadata()
        if (!meta.width || !meta.height || !meta.format || !['png', 'jpeg', 'jpg'].includes(meta.format)) return null
        if (meta.width > 4000 || meta.height > 4000) return null
        let img = sharp(input, { limitInputPixels: 16_000_000 }).rotate().ensureAlpha()
        if (opts.trim) img = img.trim()
        const out = await img.resize({ width: opts.maxWidth, withoutEnlargement: true }).png({ compressionLevel: 9 }).toBuffer()
        return out.length > 0 ? out : null
    } catch {
        return null
    }
}
