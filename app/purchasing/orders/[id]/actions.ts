'use server'

// 采购单取消:rpc cancel_purchase_order(已收货 / 已抵扣预付的拒绝,校验在 DB)。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { localizePurchasingError } from '../../purchasingErrorCodes'

export async function cancelOrder(
    poId: string,
    reason: string
): Promise<{ error?: string }> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('cancel_purchase_order', {
        p_id: poId,
        // AUDEL-1b:默认值已经摘掉 —— 传 undefined 等于少传一个参数,
        // 那会是一句"函数不存在"而不是"理由必填"。空串照传,由 DB 按名拒。
        p_reason: reason.trim(),
    })
    if (error) {
        return { error: await localizePurchasingError(error.message) }
    }
    revalidatePath('/purchasing/orders')
    revalidatePath(`/purchasing/orders/${poId}`)
    return {}
}

// 结束采购单(cut 4c):有未抵扣预付时说明必填 —— 校验在 DB(CLOSE_NOTES_REQUIRED)
export async function closeOrder(
    poId: string,
    notes: string
): Promise<{ error?: string }> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('close_purchase_order', {
        p_purchase_order_id: poId,
        p_notes: notes.trim() || undefined,
    })
    if (error) {
        return { error: await localizePurchasingError(error.message) }
    }
    revalidatePath('/purchasing/orders')
    revalidatePath(`/purchasing/orders/${poId}`)
    return {}
}

export async function reopenOrder(
    poId: string,
    reason: string
): Promise<{ error?: string }> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('reopen_purchase_order', {
        p_purchase_order_id: poId,
        p_reason: reason.trim(),
    })
    if (error) {
        return { error: await localizePurchasingError(error.message) }
    }
    revalidatePath('/purchasing/orders')
    revalidatePath(`/purchasing/orders/${poId}`)
    return {}
}

// ─────────────────────────────────────────────────────────────────────────────
// SOD-1:批准 / 驳回一张采购单。
//
// 【为什么这两支到今天才有】APR-2c 建了 approve_purchase_order 与
// reject_purchase_order,而 app/ 里【一个调用方都没有】(实测)。审批关着时这不显形:
// 单据提出来就是 approved,没有什么可批的。但它是一条【真的会搁死人】的路 ——
// 开关一旦打开,新单生为 draft/pending,而屏幕上没有任何地方批得了它们,
// 于是每一张新采购单都收不了货。**开得起来,不等于开了之后用得下去。**
//
// 校验全部在 DB:APPROVALS_NOT_ENABLED / PO_NOT_PENDING / SELF_APPROVAL_FORBIDDEN
// / APPROVAL_NOT_AUTHORISED / APPROVAL_* 未配。这里不重复判断 ——
// 页面与服务端对同一条规矩各写一份,是本仓库付过四次账的那个形状。
export async function approveOrder(
    poId: string,
    note: string
): Promise<{ error?: string }> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('approve_purchase_order', {
        p_po_id: poId,
        p_note: note.trim() || undefined,
    })
    if (error) {
        return { error: await localizePurchasingError(error.message) }
    }
    revalidatePath('/purchasing/orders')
    revalidatePath(`/purchasing/orders/${poId}`)
    return {}
}

// 驳回:理由【必填】,由 DB 按名拒(REJECT_REASON_REQUIRED)。
// 空串照传 —— 传 undefined 会变成"函数不存在"而不是"理由必填"(cancelOrder 的同一课)。
export async function rejectOrder(
    poId: string,
    reason: string
): Promise<{ error?: string }> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('reject_purchase_order', {
        p_po_id: poId,
        p_reason: reason.trim(),
    })
    if (error) {
        return { error: await localizePurchasingError(error.message) }
    }
    revalidatePath('/purchasing/orders')
    revalidatePath(`/purchasing/orders/${poId}`)
    return {}
}
