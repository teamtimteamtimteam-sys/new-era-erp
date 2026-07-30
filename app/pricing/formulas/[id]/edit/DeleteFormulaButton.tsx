'use client'

// 软删定价公式(danger outline;端口自 ReversePaymentButton):window.confirm 后调
// deleteFormula,失败 alert;成功由 action 跳回列表。
import { useTransition } from 'react'
import { deleteFormula } from '../../actions'
import { useTranslations } from '@/lib/i18n/client'

export default function DeleteFormulaButton({ formulaId }: { formulaId: string }) {
    const t = useTranslations()
    const [isPending, startTransition] = useTransition()

    function handleClick() {
        if (!window.confirm(t('pricing.deleteConfirm'))) return
        startTransition(async () => {
            const result = await deleteFormula(formulaId)
            if (result?.error) alert(result.error)
        })
    }

    return (
        <button
            type="button"
            onClick={handleClick}
            disabled={isPending}
            className="border border-red-300 text-red-600 px-3 py-2 rounded hover:bg-red-50 disabled:opacity-50"
        >
            {isPending ? t('common.deleting') : t('common.delete')}
        </button>
    )
}
