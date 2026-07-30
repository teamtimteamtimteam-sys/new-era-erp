'use server'

// 冲销开支:调 reverse_expense(冲其分录 + 生成镜像开支单,核销自动失效),
// 成功跳镜像单详情;错误本地化(PERIOD_LOCKED / EXPENSE_ALREADY_REVERSED 等)。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { redirect } from 'next/navigation'
import { localizeExpenseError } from '../../expenseErrorCodes'

export type ReverseExpenseState = { error?: string }

export async function reverseExpense(expenseId: string): Promise<ReverseExpenseState> {
    const supabase = await createClient()

    const { data, error } = await supabase.rpc('reverse_expense', {
        p_expense_id: expenseId,
    })

    if (error) {
        return { error: await localizeExpenseError(error.message) }
    }

    const reversalId = (data as { reversal_expense_id?: string } | null)?.reversal_expense_id

    revalidatePath('/finance')
    revalidatePath('/finance/journal')
    revalidatePath('/finance/payables')
    revalidatePath('/finance/expenses')
    revalidatePath(`/finance/expenses/${expenseId}`)

    if (reversalId) {
        redirect(`/finance/expenses/${reversalId}`)
    }
    return {}
}
