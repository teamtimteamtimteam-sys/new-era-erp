'use server'

// 软删对账单(坏导入丢弃)。DB 守卫触发器拒绝删除【已对账】的报表
// (STATEMENT_RECONCILED)—— 这里本地化后回给按钮展示。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { redirect } from 'next/navigation'
import { localizeBankError } from '../../../bankErrorCodes'
import { refuseFromCoded, refuseNothingChanged } from '@/lib/action-refusal'

export type DeleteStatementState = { error?: string; detail?: string }
export type UnreconcileState = { error?: string; detail?: string }

export async function deleteStatement(statementId: string): Promise<DeleteStatementState> {
    const supabase = await createClient()

    const { data, error } = await supabase
        .from('bank_statements')
        .update({ deleted_at: new Date().toISOString() })
        .eq('id', statementId)
        .is('deleted_at', null)
        // ★ ALERT-1:见 app/materials/actions.ts 的注释。这一处成功那一支会 redirect,
        //   所以零行落地的后果是【被送回对账单列表,而那一张还在列表里】。
        //   ☞ 注意这张表【另有一条真的拒绝】:trg_bank_statements_no_delete_reconciled
        //     抛 STATEMENT_RECONCILED(已对账的不许删)。那一条走上面的 error 分支,
        //     本地化器认得它 —— 与这里的零行是两件事,不要合并。
        .select('id')

    if (error) {
        return await refuseFromCoded(error.message, localizeBankError)
    }

    if (!data || data.length === 0) {
        return await refuseNothingChanged('module.finance.edit')
    }

    revalidatePath('/finance/bank')
    revalidatePath('/finance/bank/statements')
    redirect('/finance/bank/statements')
}

// 重新打开已对账的报表(理由必填,DB 会把它追加到 notes 并清空 reconciled_at/by)。
export async function unreconcileStatement(
    statementId: string,
    reason: string
): Promise<UnreconcileState> {
    const supabase = await createClient()

    const { error } = await supabase.rpc('unreconcile_statement', {
        p_statement_id: statementId,
        p_reason: reason,
    })

    if (error) {
        return await refuseFromCoded(error.message, localizeBankError)
    }

    revalidatePath('/finance/bank')
    revalidatePath('/finance/bank/statements')
    revalidatePath(`/finance/bank/statements/${statementId}`)
    return {}
}
