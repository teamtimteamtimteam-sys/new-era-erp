'use client'

// app/stocktakes/[id]/CancelStocktakeButton.tsx
// AUDEL-2:取消前先问【为什么】。成功后不跳转 —— revalidate 让详情页原地变成
// 只读的 cancelled 视图,而理由与人就印在那上面。
//
// ★ BTN-4:从 ReasonPrompt 折进 <ConfirmButton reason>。
//   ☞ 主语是盘点单号(code),由父组件传进来 —— 原来这个控件只拿到 id,
//     而【一个只有 id 的控件说不出它在取消哪一张单】,那正是 CONFIRM-1 立
//     subject 这一格的理由。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { cancelStocktake } from '../actions'
import { useTranslations } from '@/lib/i18n/client'

export default function CancelStocktakeButton({ stocktakeId, code }: {
    stocktakeId: string
    code: string
}) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')

    return (
        <div className="inline-flex flex-col items-start">
            <ConfirmButton
                subject={code}
                title={t('stocktakes.cancelConfirm')}
                body={t('stocktakes.cancelConsequence')}
                confirmLabel={t('stocktakes.cancel')}
                tier="destructive"
                reason={{ placeholder: t('stocktakes.cancelReasonPlaceholder') }}
                triggerVariant="destructive"
                triggerSize="sm"
                disabled={isPending}
                onConfirm={(reason) => {
                    setError('')
                    startTransition(async () => {
                        const res = await cancelStocktake(stocktakeId, reason)
                        if (res && 'error' in res && res.error) setError(res.error)
                        else router.refresh()
                    })
                }}
            >
                {isPending ? t('common.saving') : t('stocktakes.cancel')}
            </ConfirmButton>
            {error && <p className="mt-1 text-xs text-destructive-text">{error}</p>}
        </div>
    )
}
