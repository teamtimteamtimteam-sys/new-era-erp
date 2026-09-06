'use client'

// 冲销按钮(danger outline;端口自 ReversePaymentButton):确认对话框后调
// reverseExpense,失败 alert;成功由 action 重定向到镜像单详情。
import { useTransition } from 'react'
import { reverseExpense } from './actions'
import { useTranslations } from '@/lib/i18n/client'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'

export default function ReverseExpenseButton({ expenseId, subject }: { expenseId: string; subject: string }) {
    const t = useTranslations()
    const [isPending, startTransition] = useTransition()

    function doReverse() {
        startTransition(async () => {
            const result = await reverseExpense(expenseId)
            if (result?.error) {
                alert(result.error)
            }
        })
    }

    // CONFIRM-1:★ 撤销档,不是破坏档 —— 冲销【不删任何东西】,原件与冲销件
    //   都留在账上,审计痕迹完整。BTN-1 为此另开了这一档,而确认钮取的正是
    //   【它所确认的那个动作】的档位。主语 = 单据代号(抬头里就印着它)。
    return (
        <ConfirmButton
            subject={subject}
            title={t('expense.reverseConfirm')}
            confirmLabel={t('expense.reverse')}
            tier="reversal"
            triggerVariant="reversal"
            triggerSize="sm"
            disabled={isPending}
            onConfirm={doReverse}
        >
            {isPending ? t('common.saving') : t('expense.reverse')}
        </ConfirmButton>
    )
}
