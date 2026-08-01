'use server'

// app/hr/claims/actions.ts
import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
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
    claimId: string, expenseDate: string, supplierId: string
): Promise<ClaimState & { expenseCode?: string }> {
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('pay_medical_claim', {
        p_claim_id: claimId,
        p_expense_date: expenseDate,
        p_supplier_id: supplierId,
    })
    if (error) return { error: await localizeLeaveError(error.message) }
    revalidatePath('/hr/claims')
    revalidatePath('/finance/expenses')
    return { success: true, expenseCode: (data as { expense_code?: string })?.expense_code }
}
