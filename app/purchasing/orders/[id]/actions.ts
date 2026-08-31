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

// ── PROC-1B-iii(R1):采购行上的那个判断 —— 这批料能不能深度放电 ──────────────
//
// ★【为什么它是一次【直接 UPDATE】,而不是一支 RPC】★
//   这条轴【没有任何守卫要执行】—— R3 明令它不拦收货,而它与到货实际的关系是
//   "两个值都活着,谁也不覆盖谁"。给一件没有规则要守的事包一支 SECURITY DEFINER
//   函数,只会让下一个人以为那里有一条规则(而去找它、找不到、然后加一条)。
//   写入的门是 purchase_order_lines 的 UPDATE 策略(module.purchasing.edit),
//   那正是这条判断该有的那道门:做这个判断的人就是买货的人。
//
// 【空串 = 清掉这条轴】而"看过了但没下判断"要选 not_assessed —— 那是一个
//   **记下来的事实**,不是一个空值。两者在库里是两个不同的东西,在这里也是。
export async function setDeepDischargeJudgement(
    poId: string,
    lineId: string,
    code: string,
): Promise<{ error?: string }> {
    const supabase = await createClient()
    const { error } = await supabase
        .from('purchase_order_lines')
        .update({ deep_discharge_judgement_code: code === '' ? null : code })
        .eq('id', lineId)
    if (error) {
        return { error: await localizePurchasingError(error.message) }
    }
    revalidatePath(`/purchasing/orders/${poId}`)
    revalidatePath('/purchasing/discrepancies')
    return {}
}
