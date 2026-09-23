'use server'

// app/finance/wht/actions.ts
// WHT-1:汇缴动作。校验【全部】在数据库里 —— 页面不重复判断一遍
// (页面与服务端各写一份同一条规矩,是本仓库付过四次账的形状)。
//
// ★ PAY-REQ-1 · Batch B(Tim 2026-09-23 的 Q15 / Q3):代扣税缴纳【不再直接记】—— 这里提的是
//   一张【缴纳申请】(submit_wht_remittance_request),冻结提交那一刻推导出来的欠款;CFO 批准后
//   由财务在申请页上执行并给出实际缴纳日。remit_wht 从此按名拒(PAYMENT_REQUEST_REQUIRED|wht_remittance)。
//   更正一笔缴纳同理:requestWhtReversal 提一张冲销申请(理由必填)—— 通用冲销口对它关了门。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { redirect } from 'next/navigation'
import { getTranslations } from '@/lib/i18n/server'
import { localizeWhtError } from '../whtErrorCodes'
import { localizePaymentError } from '../paymentErrorCodes'
import { refuseFromCoded } from '@/lib/action-refusal'

export async function submitWhtRemittanceRequest(
    periodMonth: string, plannedOn: string, reference: string,
    bankAccount: string, notes: string,
): Promise<{ error?: string; detail?: string }> {
    const supabase = await createClient()
    // 【日期不给默认值,空就【干脆不传】】由数据库那条具名拒绝答话
    // (WHT_REMIT_DATE_REQUIRED)。送 '' 会在 cast 成 date 时炸出一个没有名字的
    // 错;在这里先判一次空,又成了同一条规矩的第二处实现 —— 两者都不要。
    // 与 fileGstReturn 逐字同一种处置(那一支的注释写着它是 fu2 才改对的)。
    const { data, error } = await supabase.rpc('submit_wht_remittance_request', {
        p_period_month: periodMonth,
        ...(plannedOn ? { p_planned_date: plannedOn } : {}),
        ...(reference.trim() ? { p_filed_reference: reference.trim() } : {}),
        ...(bankAccount ? { p_bank_account: bankAccount } : {}),
        ...(notes.trim() ? { p_notes: notes.trim() } : {}),
    })
    if (error) return await refuseFromCoded(error.message, localizeWhtError)
    revalidatePath('/finance/wht')
    revalidatePath('/finance/payment-requests')
    const requestId = (data as { request_id?: string } | null)?.request_id
    if (requestId) redirect(`/finance/payment-requests/${requestId}`)
    return {}
}

export async function requestWhtReversal(remittanceId: string, reason: string): Promise<{ error?: string; detail?: string }> {
    // 理由必填 —— 对话框已经挡了空白,这里独立再挡一道(库里还有第三道)。
    if (reason.trim() === '') {
        return { error: (await getTranslations())('finance.requestReversalReasonRequired') }
    }
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('submit_wht_remittance_reversal_request', {
        p_remittance_id: remittanceId,
        p_notes: reason.trim(),
    })
    // localizePaymentError 把 WHT_* 转给 localizeWhtError —— 这一支两族的码都会冒出来
    if (error) return await refuseFromCoded(error.message, localizePaymentError)
    revalidatePath('/finance/wht')
    revalidatePath('/finance/payment-requests')
    const requestId = (data as { request_id?: string } | null)?.request_id
    if (requestId) redirect(`/finance/payment-requests/${requestId}`)
    return {}
}
