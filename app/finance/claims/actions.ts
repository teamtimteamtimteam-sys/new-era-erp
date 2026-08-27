'use server'

// app/finance/claims/actions.ts
// CLAIM-1:报销的服务端动作 —— 全部只是转发,一行会计都没有。
// 成本记在哪、欠款何时成立、职责分离、凭据、税码,全部住在
// decide_expense_claim 里;屏幕【问库它会怎样】,不在这里重写一遍
// (AGENTS.md 那条,这个仓库为它付过四次账)。
import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { localizeExpenseClaimError } from './claimErrorCodes'

export type ClaimState = { error?: string; success?: boolean; claimId?: string }

export async function submitClaim(input: {
    employeeId: string; spendDate: string; amount: string; currency: string
    description: string; noReceiptReason?: string | null
}): Promise<ClaimState> {
    const supabase = await createClient()
    const reason = (input.noReceiptReason ?? '').trim()
    const { data, error } = await supabase.rpc('submit_expense_claim', {
        p_employee_id: input.employeeId,
        p_spend_date: input.spendDate,
        p_amount: Number(input.amount),
        p_currency: input.currency,
        p_description: input.description,
        ...(reason !== '' ? { p_no_receipt_reason: reason } : {}),
    })
    if (error) return { error: await localizeExpenseClaimError(error.message) }
    revalidatePath('/me'); revalidatePath('/finance/claims')
    return { success: true, claimId: (data as { claim_id?: string } | null)?.claim_id }
}

export async function withdrawClaim(claimId: string): Promise<ClaimState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('withdraw_expense_claim', { p_claim_id: claimId })
    if (error) return { error: await localizeExpenseClaimError(error.message) }
    revalidatePath('/me'); revalidatePath('/finance/claims')
    return { success: true }
}

export async function decideClaim(input: {
    claimId: string; approve: boolean
    accountCode?: string | null; taxCode?: string | null
    postingDate?: string | null; notes?: string | null
}): Promise<ClaimState> {
    const supabase = await createClient()
    const acct = (input.accountCode ?? '').trim()
    const tax = (input.taxCode ?? '').trim()
    const post = (input.postingDate ?? '').trim()
    const notes = (input.notes ?? '').trim()
    const { error } = await supabase.rpc('decide_expense_claim', {
        p_claim_id: input.claimId,
        p_approve: input.approve,
        ...(acct !== '' ? { p_account_code: acct } : {}),
        ...(tax !== '' ? { p_tax_code: tax } : {}),
        ...(post !== '' ? { p_posting_date: post } : {}),
        ...(notes !== '' ? { p_notes: notes } : {}),
    })
    if (error) return { error: await localizeExpenseClaimError(error.message) }
    revalidatePath('/me'); revalidatePath('/finance/claims')
    return { success: true }
}
