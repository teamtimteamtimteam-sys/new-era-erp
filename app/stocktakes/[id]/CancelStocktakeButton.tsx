'use client'

// app/stocktakes/[id]/CancelStocktakeButton.tsx
// 取消盘点(danger):window.confirm 后调 cancel_stocktake,失败 alert(端口自 inbound/DeleteButton)。
// 成功后不跳转 —— revalidate 让详情页原地变成只读 cancelled 视图。
import { useTransition } from 'react'
import { cancelStocktake } from '../actions'
import { useTranslations } from '@/lib/i18n/client'

export default function CancelStocktakeButton({ stocktakeId }: { stocktakeId: string }) {
    const t = useTranslations()
    const [isPending, startTransition] = useTransition()

    function handleClick() {
        const confirmed = window.confirm(t('stocktakes.cancelConfirm'))
        if (!confirmed) return

        startTransition(async () => {
            const result = await cancelStocktake(stocktakeId)
            if (result?.error) {
                alert(result.error)
            }
        })
    }

    return (
        <button
            onClick={handleClick}
            disabled={isPending}
            className="border border-red-300 text-red-600 text-base font-medium rounded px-4 py-3 min-h-[48px] hover:bg-red-50 disabled:opacity-50"
        >
            {isPending ? t('common.saving') : t('stocktakes.cancel')}
        </button>
    )
}
