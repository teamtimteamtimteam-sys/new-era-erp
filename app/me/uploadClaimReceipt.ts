// app/me/uploadClaimReceipt.ts
// CLAIM-RECEIPTS-1(Tim 2026-10-21,Step 0 Q1 · Q2 · Q3 · Q12):浏览器那一半 —— 先把一份收据准备好,再 begin → 直传 → finish。
//   只被客户端组件 import(用到 canvas / createImageBitmap / 浏览器的 Supabase 客户端);本身不带指令。
//
// 【照片先缩】(Q3)任何一张图片 —— 手机相机拍的、相册里的、HEIC(Safari 解得开)—— 都画进一张长边 ≤ 2,000 px 的画布,存成 JPEG
//   (约 0.5 MB)。于是 1 GB 的免费方案装得下一年以上的收据,而 Safari 里 iPhone 的 HEIC 照片也就变成了 JPEG。PDF 原样送。
//   解不开的图片(例如桌面 Chrome 上的 HEIC)按名拒,说出为什么、该怎么办。Word / Excel 同样按名拒。
// 【字节直传私有桶】不经过 Vercel 的函数(那里的请求体有上限,一张照片会超过它)。存储策略只放行 begin 刚登记的那一条路径。
import { createClient } from '@/lib/supabase/client'
import { abandonReceipt, beginReceipt, finishReceipt } from './claimReceiptActions'

export const RECEIPT_ACCEPT = '.pdf,.jpg,.jpeg,.png,.heic,.heif,application/pdf,image/jpeg,image/png,image/heic,image/heif'
const MAX_EDGE = 2000
const JPEG_QUALITY = 0.85

export type ReceiptLimits = { set: boolean; max_bytes: number | null; types: string[] | null }
/** 准备失败的原因 —— 页面按它选一句话(expenseClaims.receipts.*),不是库的码 */
export type PrepareFailure = 'heicUnreadable' | 'wordExcel' | 'typeNotAccepted' | 'tooLarge' | 'imageUnreadable' | 'limitsNotSet'

const isPdf = (f: File) => f.type === 'application/pdf' || /\.pdf$/i.test(f.name)
const isHeic = (f: File) => /^image\/hei[cf]$/i.test(f.type) || /\.hei[cf]$/i.test(f.name)
const isImage = (f: File) => f.type.startsWith('image/') || /\.(jpe?g|png|hei[cf])$/i.test(f.name)
const isOffice = (f: File) => /(msword|wordprocessingml|ms-excel|spreadsheetml)/i.test(f.type) || /\.(docx?|xlsx?)$/i.test(f.name)

async function decode(file: File): Promise<{ w: number; h: number; draw: (ctx: CanvasRenderingContext2D, w: number, h: number) => void }> {
    try {
        const bmp = await createImageBitmap(file)
        return { w: bmp.width, h: bmp.height, draw: (ctx, w, h) => ctx.drawImage(bmp, 0, 0, w, h) }
    } catch {
        // 有的浏览器的 createImageBitmap 不认某种格式,而 <img> 认(Safari 的 HEIC)
        const url = URL.createObjectURL(file)
        try {
            const img = await new Promise<HTMLImageElement>((ok, bad) => {
                const i = new Image()
                i.onload = () => ok(i)
                i.onerror = () => bad(new Error('decode'))
                i.src = url
            })
            return { w: img.naturalWidth, h: img.naturalHeight, draw: (ctx, w, h) => ctx.drawImage(img, 0, 0, w, h) }
        } finally {
            URL.revokeObjectURL(url)
        }
    }
}

/** 一份文件 → 要送的那一份(PDF 原样;图片缩成 JPEG),或者为什么不能送 */
export async function prepareReceipt(file: File, limits: ReceiptLimits):
    Promise<{ ok: true; blob: Blob; name: string; type: string } | { ok: false; why: PrepareFailure }> {
    if (!limits.set || limits.max_bytes == null) return { ok: false, why: 'limitsNotSet' }
    const max = limits.max_bytes
    if (isOffice(file)) return { ok: false, why: 'wordExcel' }
    if (isPdf(file)) {
        if (file.size > max) return { ok: false, why: 'tooLarge' }
        return { ok: true, blob: file, name: file.name, type: 'application/pdf' }
    }
    if (!isImage(file)) return { ok: false, why: 'typeNotAccepted' }
    let src: Awaited<ReturnType<typeof decode>>
    try {
        src = await decode(file)
    } catch {
        return { ok: false, why: isHeic(file) ? 'heicUnreadable' : 'imageUnreadable' }
    }
    if (!src.w || !src.h) return { ok: false, why: isHeic(file) ? 'heicUnreadable' : 'imageUnreadable' }
    const scale = Math.min(1, MAX_EDGE / Math.max(src.w, src.h))
    const w = Math.max(1, Math.round(src.w * scale)), h = Math.max(1, Math.round(src.h * scale))
    const canvas = document.createElement('canvas')
    canvas.width = w; canvas.height = h
    const ctx = canvas.getContext('2d')
    if (!ctx) return { ok: false, why: 'imageUnreadable' }
    ctx.fillStyle = '#ffffff'          // 透明的 PNG 截图画成白底,不是黑底
    ctx.fillRect(0, 0, w, h)
    src.draw(ctx, w, h)
    const blob = await new Promise<Blob | null>((ok) => canvas.toBlob(ok, 'image/jpeg', JPEG_QUALITY))
    if (!blob) return { ok: false, why: 'imageUnreadable' }
    if (blob.size > max) return { ok: false, why: 'tooLarge' }
    const base = (file.name || 'receipt').replace(/\.[^.]+$/, '') || 'receipt'
    return { ok: true, blob, name: `${base}.jpg`, type: 'image/jpeg' }
}

/** 一笔的一份收据:begin(库先判)→ 直传 → finish(服务端按文件头认类型,库确认)。失败回一句话(已经说成人话),成功回 null。 */
export async function uploadReceipt(itemId: string, prepared: { blob: Blob; name: string; type: string }): Promise<string | null> {
    const slot = await beginReceipt({ itemId, fileName: prepared.name, fileType: prepared.type, fileSize: prepared.blob.size })
    if (slot.error || !slot.id || !slot.path) return slot.error ?? 'begin'
    const supabase = createClient()
    const up = await supabase.storage.from('claim-receipts').upload(slot.path, prepared.blob, { contentType: prepared.type, upsert: false })
    if (up.error) {
        await abandonReceipt(slot.id)
        return up.error.message
    }
    const done = await finishReceipt(slot.id)
    return done.error ?? null
}
