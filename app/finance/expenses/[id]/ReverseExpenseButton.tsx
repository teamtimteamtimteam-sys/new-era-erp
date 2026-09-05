'use client'

// 冲销按钮(danger outline;端口自 ReversePaymentButton):window.confirm 后调
// reverseExpense,失败 alert;成功由 action 重定向到镜像单详情。
import { useTransition } from 'react'
import { reverseExpense } from './actions'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'

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
        <Button variant="reversal" size="sm"
            onClick={handleClick}
            disabled={isPending}
        >
            {isPending ? t('common.saving') : t('expense.reverse')}
        </Button>
    )
}
