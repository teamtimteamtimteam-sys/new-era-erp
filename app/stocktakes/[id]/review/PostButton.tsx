'use client'

// app/stocktakes/[id]/review/PostButton.tsx
// 确认过账:window.confirm 后调 post_stocktake;错误内联展示(已本地化),
// 成功由 action 重定向回详情页(只读 posted 视图)。
import { useState, useTransition } from 'react'
import { postStocktake } from '../../actions'
import { useTranslations } from '@/lib/i18n/client'

export default function PostButton({ stocktakeId }: { stocktakeId: string }) {
    const t = useTranslations()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState<string | null>(null)

    function handleClick() {
        const confirmed = window.confirm(t('stocktakes.postConfirm'))
        if (!confirmed) return

        setError(null)
        startTransition(async () => {
            const result = await postStocktake(stocktakeId)
            if (result?.error) {
                setError(result.error)
            }
        })
    }

    return (
        <div>
            {error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-3">
                    {error}
                </div>
            )}
            <button
                onClick={handleClick}
                disabled={isPending}
                className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 disabled:bg-gray-400"
            >
                {isPending ? t('common.saving') : t('stocktakes.postButton')}
            </button>
        </div>
    )
}
