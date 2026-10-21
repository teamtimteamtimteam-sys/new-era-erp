'use server'

// app/finance/claims/actions.ts
// CLAIM-1:报销的服务端动作 —— 全部只是转发,一行会计都没有。
// 成本记在哪、欠款何时成立、职责分离、凭据、税码,全部住在
// decide_expense_claim_items 里;屏幕【问库它会怎样】,不在这里重写一遍
// (AGENTS.md 那条,这个仓库为它付过四次账)。
// ★ EXPENSE-MULTILINE-1(Tim 2026-10-20):一张报销单是表头(用途 · 币种)+ 明细(日期 · 金额 · 说明 · 无收据理由);
//   提交走 submit_expense_claim_items,决定走 decide_expense_claim_items(财务逐笔给科目与税码,驳回整张)。
import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { localizeExpenseClaimError } from './claimErrorCodes'

export type ClaimState = { error?: string; success?: boolean; claimId?: string; code?: string; items?: { line_no: number; item_id: string }[] }

export type ClaimItemInput = { spendDate: string; amount: string; description: string; noReceiptReason?: string | null }

export async function submitClaim(input: {
    employeeId: string; currency: string; purpose: string; items: ClaimItemInput[]
}): Promise<ClaimState> {
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('submit_expense_claim_items', {
        p_employee_id: input.employeeId,
        p_currency: input.currency,
        p_purpose: input.purpose,
        // 原样转交:日期、金额、说明、理由的每一条规矩都在函数里(带第几笔的码)
        p_items: input.items.map((it) => ({
            spend_date: it.spendDate,
            amount: it.amount,
            description: it.description,
            no_receipt_reason: (it.noReceiptReason ?? '').trim(),
        })),
    })
    if (error) return { error: await localizeExpenseClaimError(error.message) }
    revalidatePath('/me'); revalidatePath('/finance/claims')
    // CLAIM-RECEIPTS-1(Q12):带回每一笔的 id —— 表单紧接着给每一笔传它的收据
    const d = data as { claim_id?: string; code?: string; items?: { line_no: number; item_id: string }[] } | null
    return { success: true, claimId: d?.claim_id, code: d?.code, items: d?.items ?? [] }
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
    // 逐笔:每一笔明细财务给的科目与税码(Step 0b Q1 —— 什么都不预选)
    items?: { lineNo: number; accountCode: string; taxCode: string }[]
    postingDate?: string | null; notes?: string | null
}): Promise<ClaimState> {
    const supabase = await createClient()
    const post = (input.postingDate ?? '').trim()
    const notes = (input.notes ?? '').trim()
    const { error } = await supabase.rpc('decide_expense_claim_items', {
        p_claim_id: input.claimId,
        p_approve: input.approve,
        ...(input.approve && input.items
            ? { p_items: input.items.map((i) => ({ line_no: i.lineNo, account_code: i.accountCode.trim(), tax_code: i.taxCode.trim() })) }
            : {}),
        ...(post !== '' ? { p_posting_date: post } : {}),
        ...(notes !== '' ? { p_notes: notes } : {}),
    })
    if (error) return { error: await localizeExpenseClaimError(error.message) }
    revalidatePath('/me'); revalidatePath('/finance/claims')
    return { success: true }
}
