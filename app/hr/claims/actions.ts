'use server'

// app/hr/claims/actions.ts
import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { localizeLeaveError } from '../leave/actions'

export type ClaimState = { error?: string; success?: boolean; code?: string }

export async function submitClaim(form: {
    employeeId: string
    claimDate: string
    amountSgd: number
    description: string | null
    receiptRef: string | null
}): Promise<ClaimState> {
    const supabase = await createClient()
    // 【必填】这个日期决定过账期间/取哪天的汇率 —— 界面禁用是第一道,这是第二道:
    // 绕过界面也进不去。函数侧的 CURRENT_DATE 默认值已由 FIN-10 一并删除。
    if (!form.claimDate) return { error: (await getTranslations())('claims.errClaimDateRequired') }
    const { data, error } = await supabase.rpc('submit_medical_claim', {
        p_employee_id: form.employeeId,
        p_claim_date: form.claimDate,
        p_amount_sgd: form.amountSgd,
        p_description: form.description ?? undefined,
        p_receipt_ref: form.receiptRef ?? undefined,
    })
    if (error) return { error: await localizeLeaveError(error.message) }
    revalidatePath('/hr/claims')
    revalidatePath('/me')
    return { success: true, code: (data as { code?: string })?.code }
}

export async function decideClaim(claimId: string, approve: boolean, notes: string | null): Promise<ClaimState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('decide_medical_claim', {
        p_claim_id: claimId, p_approve: approve, p_notes: notes ?? undefined,
    })
    if (error) return { error: await localizeLeaveError(error.message) }
    revalidatePath('/hr/claims')
    return { success: true }
}

// 【建费用是财务的动作】—— 函数要 module.finance.edit。
// HR 审核在前(claim 必须已 approved),财务在后,两步两人。
export async function payClaim(
    claimId: string, expenseDate: string
): Promise<ClaimState & { expenseCode?: string }> {
    const supabase = await createClient()
    // 【必填】这个日期决定过账期间/取哪天的汇率 —— 界面禁用是第一道,这是第二道:
    // 绕过界面也进不去。函数侧的 CURRENT_DATE 默认值已由 FIN-10 一并删除。
    if (!expenseDate) return { error: (await getTranslations())('claims.errExpenseDateRequired') }
    const { data, error } = await supabase.rpc('pay_medical_claim', {
        p_claim_id: claimId,
        p_expense_date: expenseDate,
        // PAYEE-1a:报销的收款人【就是提交报销的那个员工】,函数自己从报销单取。
        // p_supplier_id 已从函数签名里删掉 —— 传它会 404。
    })
    if (error) return { error: await localizeLeaveError(error.message) }
    revalidatePath('/hr/claims')
    revalidatePath('/finance/expenses')
    return { success: true, expenseCode: (data as { expense_code?: string })?.expense_code }
}
