'use client'

// app/stocktakes/[id]/review/PostButton.tsx
// 确认过账:确认对话框后调 post_stocktake;错误内联展示(已本地化),
// 成功由 action 重定向回详情页(只读 posted 视图)。
import { useState, useTransition } from 'react'
import { postStocktake } from '../../actions'
import { useTranslations } from '@/lib/i18n/client'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'

export default function PostButton({ stocktakeId, subject }: { stocktakeId: string; subject: string }) {
    const t = useTranslations()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState<string | null>(null)

    function doPost() {
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
            <ConfirmButton
                subject={subject}
                title={t('stocktakes.postConfirm')}
                confirmLabel={t('stocktakes.postButton')}
                tier="destructive"
                triggerVariant="default"
                disabled={isPending}
                onConfirm={doPost}
            >
                {isPending ? t('common.saving') : t('stocktakes.postButton')}
            </ConfirmButton>
        </div>
    )
}
