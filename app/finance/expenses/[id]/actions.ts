'use server'

// 冲销开支:调 reverse_expense(冲其分录 + 生成镜像开支单,核销自动失效),
// 成功跳镜像单详情;错误本地化(PERIOD_LOCKED / EXPENSE_ALREADY_REVERSED 等)。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { redirect } from 'next/navigation'
import { localizeExpenseError } from '../../expenseErrorCodes'
import { refuseFromCoded } from '@/lib/action-refusal'

export type ReverseExpenseState = { error?: string; detail?: string }

// MES-6a-1(Q33–Q37):冲销要一句理由。理由空着时对话框的确认钮按不下去;这里不另判空白 —— 服务端【独立】拒空
//   (EXPENSE_REVERSAL_REASON_REQUIRED,在权限之后、任何别的检查之前),绕过界面直接调也一样。
export async function reverseExpense(expenseId: string, reason: string): Promise<ReverseExpenseState> {
    const supabase = await createClient()

    const { data, error } = await supabase.rpc('reverse_expense', {
        p_expense_id: expenseId,
        p_memo: reason,
    })

    if (error) {
        return await refuseFromCoded(error.message, localizeExpenseError)
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
