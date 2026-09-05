'use client'

// 删除对账单按钮(danger outline;端口自 ReversePaymentButton):window.confirm 后调
// deleteStatement,失败 alert(已对账的报表会被 DB 守卫拒绝);成功由 action 跳列表。
import { useTransition } from 'react'
import { deleteStatement } from './actions'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'

export default function DeleteStatementButton({ statementId }: { statementId: string }) {
    const t = useTranslations()
    const [isPending, startTransition] = useTransition()

    function handleClick() {
        const confirmed = window.confirm(t('bank.deleteConfirm'))
        if (!confirmed) return

        startTransition(async () => {
            const result = await deleteStatement(statementId)
            if (result?.error) {
                alert(result.error)
            }
        })
    }

    return (
        <Button variant="destructive" size="sm"
            onClick={handleClick}
            disabled={isPending}
        >
            {isPending ? t('common.deleting') : t('common.delete')}
        </Button>
    )
}
