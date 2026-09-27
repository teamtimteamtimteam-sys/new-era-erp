'use server'

// app/finance/gst/actions.ts
// GST 期间的动作(开期间 · APR-10 起:提申报申请 / 批 / 驳 / 撤回 / 记下申报 · 更正)。校验【全部】在数据库里 —— 页面不重复判断一遍
// (页面与服务端各写一份同一条规矩,是本仓库付过四次账的形状)。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { localizeFinanceError } from '../financeErrorCodes'

export async function openGstPeriod(periodStart: string): Promise<{ error?: string }> {
    const supabase = await createClient()
    // 期末由数据库按季推;这里只传期初,少一个可以填错的格子。
    const start = new Date(periodStart + 'T00:00:00Z')
    const end = new Date(Date.UTC(start.getUTCFullYear(), start.getUTCMonth() + 3, 0))
    const { error } = await supabase.rpc('open_gst_period', {
        p_period_start: periodStart,
        p_period_end: end.toISOString().slice(0, 10),
    })
    if (error) return { error: await localizeFinanceError(error.message) }
    revalidatePath('/finance/gst')
    return {}
}

// ★ APR-10(Tim 2026-09-27,grilling Q1 · Q2 · Q4):申报从此是一张申请 —— 财务提(冻结那一季 F5 每一格)、
//   CFO 批(再算一遍、相等才写快照,期间 → approved)、财务去 IRAS 报之后一步记下申报日与参考号。
//   谁能批这里不预判(二级、不是提单人 —— 按人认),拒绝由库出、就地说成人话。
//   审批关着时申请生下来就是 approved —— 返回里的 status 说的是哪一种。
function refreshGst(periodId: string) {
    revalidatePath('/finance/gst')
    revalidatePath(`/finance/gst/${periodId}`)
    revalidatePath('/')
}

export async function submitGstFiling(
    periodId: string, note: string,
): Promise<{ error?: string; status?: 'submitted' | 'approved' }> {
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('submit_gst_filing_request', {
        p_period_id: periodId,
        ...(note.trim() ? { p_note: note.trim() } : {}),
    })
    if (error) return { error: await localizeFinanceError(error.message) }
    refreshGst(periodId)
    return { status: (data as { status?: 'submitted' | 'approved' } | null)?.status }
}

export async function decideGstFiling(
    periodId: string, requestId: string, approve: boolean, notes: string,
): Promise<{ error?: string }> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('decide_gst_filing_request', {
        p_request_id: requestId,
        p_approve: approve,
        ...(notes.trim() ? { p_notes: notes.trim() } : {}),
    })
    if (error) return { error: await localizeFinanceError(error.message) }
    refreshGst(periodId)
    return {}
}

export async function withdrawGstFiling(periodId: string, requestId: string): Promise<{ error?: string }> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('withdraw_gst_filing_request', { p_request_id: requestId })
    if (error) return { error: await localizeFinanceError(error.message) }
    refreshGst(periodId)
    return {}
}

export async function recordGstFiling(
    periodId: string, filedOn: string, reference: string
): Promise<{ error?: string }> {
    const supabase = await createClient()
    // 【申报日必填,且不给默认值】它决定这份记录说的是哪一天报的 ——
    // 一个 CURRENT_DATE 默认会把"忘了填"悄悄变成"今天报的"(FIN-10 那一课)。
    // 没填就【干脆不传】,由数据库那条具名拒绝答话(GST_FILED_DATE_REQUIRED)。
    // 送 '' 会在 cast 成 date 时炸出一个没有名字的错;在这里先判一次空,
    // 又成了同一条规矩的第二处实现 —— 两者都不要,所以参数有 DEFAULT NULL(GST-1-fu2)。
    const { error } = await supabase.rpc('record_gst_filing', {
        p_period_id: periodId,
        ...(filedOn ? { p_filed_on: filedOn } : {}),
        ...(reference.trim() ? { p_reference: reference.trim() } : {}),
    })
    if (error) return { error: await localizeFinanceError(error.message) }
    refreshGst(periodId)
    return {}
}

export async function correctGstReturn(
    periodId: string, reason: string
): Promise<{ error?: string }> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('correct_gst_return', {
        p_original_period_id: periodId,
        p_reason: reason.trim(),
    })
    if (error) return { error: await localizeFinanceError(error.message) }
    revalidatePath('/finance/gst')
    return {}
}
