'use server'

// 软删对账单(坏导入丢弃)。DB 守卫触发器拒绝删除【已对账】的报表
// (STATEMENT_RECONCILED)—— 这里本地化后回给按钮展示。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { redirect } from 'next/navigation'
import { localizeBankError } from '../../../bankErrorCodes'

export type DeleteStatementState = { error?: string }

export async function deleteStatement(statementId: string): Promise<DeleteStatementState> {
    const supabase = await createClient()

    const { error } = await supabase
        .from('bank_statements')
        .update({ deleted_at: new Date().toISOString() })
        .eq('id', statementId)
        .is('deleted_at', null)

    if (error) {
        return { error: await localizeBankError(error.message) }
    }

    revalidatePath('/finance/bank')
    revalidatePath('/finance/bank/statements')
    redirect('/finance/bank/statements')
}
