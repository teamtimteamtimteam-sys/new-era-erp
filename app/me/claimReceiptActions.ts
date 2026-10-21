'use server'

// app/me/claimReceiptActions.ts
// CLAIM-RECEIPTS-1(Tim 2026-10-21,Step 0 Q1 · Q4 · Q5 · Q12):报销单每一笔的收据 —— 服务端那几步,全部只是转发。
//   谁能传、单在不在 submitted、上限、900 MB 的存储余量,全部住在库里(claim_receipt_begin);这里不另判一遍。
//   【字节不经过这里】浏览器把文件直传私有桶 claim-receipts(MES-9c 的路由那一半不适用:Vercel 的函数请求体有上限,
//   一张手机照片会超过它 —— docs/surveys/CLAIM-RECEIPTS-1/step0-survey.md §4)。这里只做:
//   begin(库先判,给出路径)· finish(按文件头认类型 —— 库读不到字节,所以这一步在这里 —— 对得上才让库确认)·
//   abandon(没传成)· remove(Q5)· link(60 秒的签名链接,Tim 接受的那条决定)。
import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { localizeExpenseClaimError } from '@/app/finance/claims/claimErrorCodes'

const BUCKET = 'claim-receipts'

export type ReceiptSlot = { error?: string; id?: string; path?: string }
export type ReceiptResult = { error?: string; success?: boolean }

function refresh() {
    revalidatePath('/me'); revalidatePath('/finance/claims')
}

export async function beginReceipt(input: { itemId: string; fileName: string; fileType: string; fileSize: number }): Promise<ReceiptSlot> {
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('claim_receipt_begin', {
        p_item_id: input.itemId, p_file_name: input.fileName, p_file_type: input.fileType, p_file_size: input.fileSize,
    })
    if (error) return { error: await localizeExpenseClaimError(error.message) }
    const slot = data as { id: string; bucket: string; path: string }
    return { id: slot.id, path: slot.path }
}

/** 按文件头认类型 —— 不信浏览器报的(MES-9c 那一条:一个改名成 .pdf 的 GIF 就是这样溜进来的)。认不出回 null。 */
function sniffType(b: Uint8Array): string | null {
    if (b.length >= 5 && b[0] === 0x25 && b[1] === 0x50 && b[2] === 0x44 && b[3] === 0x46 && b[4] === 0x2d) return 'application/pdf'
    if (b.length >= 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return 'image/jpeg'
    if (b.length >= 8 && b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47
        && b[4] === 0x0d && b[5] === 0x0a && b[6] === 0x1a && b[7] === 0x0a) return 'image/png'
    return null
}

export async function finishReceipt(receiptId: string): Promise<ReceiptResult> {
    const supabase = await createClient()
    const { data: row, error: readErr } = await supabase.from('expense_claim_receipts')
        .select('storage_path, file_type, status').eq('id', receiptId).maybeSingle()
    if (readErr) return { error: await localizeExpenseClaimError(readErr.message) }
    if (!row) return { error: await localizeExpenseClaimError('CLAIM_RECEIPT_NOT_FOUND') }
    // 只取文件头那几个字节(Range),不把整份文件拉进函数里
    const signed = await supabase.storage.from(BUCKET).createSignedUrl(row.storage_path, 60)
    if (signed.error || !signed.data?.signedUrl) {
        await supabase.rpc('claim_receipt_abandon', { p_receipt_id: receiptId })
        return { error: await localizeExpenseClaimError('CLAIM_RECEIPT_NOT_STORED') }
    }
    let head: Uint8Array
    try {
        const r = await fetch(signed.data.signedUrl, { headers: { Range: 'bytes=0-15' } })
        if (!r.ok) throw new Error(`HTTP ${r.status}`)
        head = new Uint8Array(await r.arrayBuffer()).slice(0, 16)
    } catch {
        await supabase.rpc('claim_receipt_abandon', { p_receipt_id: receiptId })
        return { error: await localizeExpenseClaimError('CLAIM_RECEIPT_NOT_STORED') }
    }
    const sniffed = sniffType(head)
    if (sniffed !== row.file_type) {
        await supabase.rpc('claim_receipt_abandon', { p_receipt_id: receiptId })
        return { error: await localizeExpenseClaimError(`CLAIM_RECEIPT_TYPE_NOT_ACCEPTED|${sniffed ?? 'application/octet-stream'}`) }
    }
    const { error } = await supabase.rpc('claim_receipt_finish', { p_receipt_id: receiptId })
    if (error) {
        await supabase.rpc('claim_receipt_abandon', { p_receipt_id: receiptId })
        return { error: await localizeExpenseClaimError(error.message) }
    }
    refresh()
    return { success: true }
}

export async function abandonReceipt(receiptId: string): Promise<ReceiptResult> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('claim_receipt_abandon', { p_receipt_id: receiptId })
    if (error) return { error: await localizeExpenseClaimError(error.message) }
    return { success: true }
}

export async function removeReceipt(receiptId: string): Promise<ReceiptResult> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('claim_receipt_remove', { p_receipt_id: receiptId })
    if (error) return { error: await localizeExpenseClaimError(error.message) }
    refresh()
    return { success: true }
}

/** 私有桶 —— 每次点开现生成一个 60 秒的签名链接(Tim 2026-10-21 接受的那条决定)。读规则在存储策略里(claim_receipt_can_read)。 */
export async function receiptLink(receiptId: string): Promise<{ error?: string; url?: string }> {
    const supabase = await createClient()
    const { data: row, error: readErr } = await supabase.from('expense_claim_receipts')
        .select('storage_path').eq('id', receiptId).maybeSingle()
    if (readErr) return { error: await localizeExpenseClaimError(readErr.message) }
    if (!row) return { error: await localizeExpenseClaimError('CLAIM_RECEIPT_NOT_FOUND') }
    const { data, error } = await supabase.storage.from(BUCKET).createSignedUrl(row.storage_path, 60)
    if (error || !data?.signedUrl) return { error: await localizeExpenseClaimError('CLAIM_RECEIPT_NOT_STORED') }
    return { url: data.signedUrl }
}
