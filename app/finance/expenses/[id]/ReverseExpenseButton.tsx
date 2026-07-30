'use client'

// 冲销按钮(danger outline;端口自 ReversePaymentButton):window.confirm 后调
// reverseExpense,失败 alert;成功由 action 重定向到镜像单详情。
import { useTransition } from 'react'
import { reverseExpense } from './actions'
import { useTranslations } from '@/lib/i18n/client'

export default function ReverseExpenseButton({ expenseId }: { expenseId: string }) {
    const t = useTranslations()
    const [isPending, startTransition] = useTransition()

    function handleClick() {
        const confirmed = window.confirm(t('expense.reverseConfirm'))
        if (!confirmed) return

        startTransition(async () => {
            const result = await reverseExpense(expenseId)
            if (result?.error) {
                alert(result.error)
            }
        })
    }

    return (
        <button
            onClick={handleClick}
            disabled={isPending}
            className="border border-red-300 text-red-600 px-3 py-1 rounded hover:bg-red-50 disabled:opacity-50"
        >
            {isPending ? t('common.saving') : t('expense.reverse')}
        </button>
    )
}
