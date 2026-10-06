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
// U1-B(Q25):这句说明就是关单的理由 —— 存进 close_reason / closed_by,不再追加进备注。
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
// ★【U1-B(UNBLOCK-1 Q20,2026-10-05):它从直连 UPDATE 改走一支 RPC —— 上面那段
//   "为什么不是 RPC"的理由已经不成立,所以删掉而不是留着】★
//   APR-10 起 purchase_order_lines 只经函数写(guard_po_direct_write 按名拒
//   PO_THROUGH_FUNCTION_ONLY),于是这个控件从那天起【一次都没存进去过】。
//   set_po_line_deep_discharge 是它的门:module.purchasing.edit;作废的单拒
//   (PO_CANCELLED);找不到的行拒(PO_LINE_NOT_FOUND);空拒
//   (DEEP_DISCHARGE_JUDGEMENT_REQUIRED —— NULL 的意思是"早于这条轴",
//   "看过了但没下判断"要选 not_assessed);字典里没有的码拒
//   (DEEP_DISCHARGE_JUDGEMENT_UNKNOWN)。四条都经 localizePurchasingError 说人话。
//   【空串原样送下去】不在这里拦 —— 拒绝的权威是函数,界面那一道是不画空选项。
export async function setDeepDischargeJudgement(
    poId: string,
    lineId: string,
    code: string,
): Promise<{ error?: string }> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('set_po_line_deep_discharge', {
        p_line_id: lineId,
        p_code: code,
    })
    if (error) {
        return { error: await localizePurchasingError(error.message) }
    }
    revalidatePath(`/purchasing/orders/${poId}`)
    revalidatePath('/purchasing/discrepancies')
    return {}
}

// ═══ EQP-PAY-1(R6):质保金放款【确认】═══════════════════════════════════════
//
// ★【到期不付款,到期【提示】】★ 这支 action 是那句"由人确认"的落点。库里没有
// 任何一条到期自动结算的路径 —— 质保金的意义就在于它扣得下来,自动放款等于把它废掉。
//
// 【为什么放多少、扣多少都要人填,而不给默认值】给一个"全额放款"的默认值,
// 等于把"这台机器没出过毛病"这个判断替人做了 —— 而那正是这次确认要问的唯一问题。
// 服务端两条都按名拒:不填(RETENTION_RELEASE_AMOUNTS_REQUIRED)、
// 加起来对不上总额(RETENTION_RELEASE_DOES_NOT_BALANCE)。
export async function releaseRetention(
    poId: string,
    retentionId: string,
    releasedAmount: string,
    withheldAmount: string,
    reason: string,
): Promise<{ error?: string }> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('release_purchase_order_retention', {
        p_retention_id: retentionId,
        // 空串照传成 null —— 由 DB 按名拒"两个金额都要明说",
        // 而不是在这里悄悄补一个 0(那会把"没填"变成"扣了 0")。
        // 【空串照传成 null,由 DB 按名拒】不要在这里补一个 0 ——
        // 那会把"没填"变成"扣了 0",而那是两个不同的事实。
        // 类型上用 as never 越过生成类型里的 NOT NULL 形状:PostgREST 的类型
        // 说的是【参数的类型】,不是【必须给值】;拒绝的判据在函数体里,
        // 而那正是本仓库要的位置(屏幕不替服务端做判断)。
        p_released_amount_ccy: (releasedAmount.trim() === '' ? null : Number(releasedAmount)) as never,
        p_withheld_amount_ccy: (withheldAmount.trim() === '' ? null : Number(withheldAmount)) as never,
        p_withholding_reason: (reason.trim() === '' ? null : reason.trim()) as never,
    })
    if (error) {
        return { error: await localizePurchasingError(error.message) }
    }
    revalidatePath(`/purchasing/orders/${poId}`)
    return {}
}
