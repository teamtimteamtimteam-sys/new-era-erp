'use server'

// 对账工作台的服务端动作:逐笔匹配 / 取消匹配 / 忽略 / 恢复 / 完成对账。
// 全部校验(方向、币种、科目、金额相等、行状态、报表状态)都在 3a 的 DB 函数内,
// 这里只负责调用 + 本地化错误 + revalidate。完成对账后跳报表详情(只读)。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { redirect } from 'next/navigation'
import { localizeBankError } from '../../../../bankErrorCodes'

export type BankActionState = { error?: string }

// 匹配工作台三处路径都要刷新:工作台自身、报表详情、银行首页(未匹配计数/差额)
async function revalidateBank(statementId: string) {
    revalidatePath('/finance/bank')
    revalidatePath('/finance/bank/statements')
    revalidatePath(`/finance/bank/statements/${statementId}`)
    revalidatePath(`/finance/bank/statements/${statementId}/reconcile`)
}

export async function matchLine(
    statementId: string,
    statementLineId: string,
    journalLineIds: string[]
): Promise<BankActionState> {
    const supabase = await createClient()

    const { error } = await supabase.rpc('match_bank_line', {
        p_statement_line_id: statementLineId,
        p_journal_line_ids: journalLineIds,
    })

    if (error) {
        return { error: await localizeBankError(error.message) }
    }

    await revalidateBank(statementId)
    return {}
}

export async function unmatchLine(
    statementId: string,
    statementLineId: string
): Promise<BankActionState> {
    const supabase = await createClient()

    const { error } = await supabase.rpc('unmatch_bank_line', {
        p_statement_line_id: statementLineId,
    })

    if (error) {
        return { error: await localizeBankError(error.message) }
    }

    await revalidateBank(statementId)
    return {}
}

export async function ignoreLine(
    statementId: string,
    statementLineId: string,
    reason: string
): Promise<BankActionState> {
    const supabase = await createClient()

    const { error } = await supabase.rpc('ignore_bank_line', {
        p_statement_line_id: statementLineId,
        p_reason: reason,
    })

    if (error) {
        return { error: await localizeBankError(error.message) }
    }

    await revalidateBank(statementId)
    return {}
}

export async function unignoreLine(
    statementId: string,
    statementLineId: string
): Promise<BankActionState> {
    const supabase = await createClient()

    const { error } = await supabase.rpc('unignore_bank_line', {
        p_statement_line_id: statementLineId,
    })

    if (error) {
        return { error: await localizeBankError(error.message) }
    }

    await revalidateBank(statementId)
    return {}
}

export async function completeReconciliation(statementId: string): Promise<BankActionState> {
    const supabase = await createClient()

    const { error } = await supabase.rpc('reconcile_statement', {
        p_statement_id: statementId,
    })

    if (error) {
        return { error: await localizeBankError(error.message) }
    }

    await revalidateBank(statementId)
    redirect(`/finance/bank/statements/${statementId}`)
}
