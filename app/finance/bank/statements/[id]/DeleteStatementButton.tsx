'use client'

// 删除对账单按钮(danger outline;端口自 ReversePaymentButton):window.confirm 后调
// deleteStatement,失败 alert(已对账的报表会被 DB 守卫拒绝);成功由 action 跳列表。
import { useTransition } from 'react'
import { deleteStatement } from './actions'
import { useTranslations } from '@/lib/i18n/client'

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
        <button
            onClick={handleClick}
            disabled={isPending}
            className="border border-red-300 text-red-600 px-3 py-1 rounded hover:bg-red-50 disabled:opacity-50"
        >
            {isPending ? t('common.deleting') : t('common.delete')}
        </button>
    )
}
