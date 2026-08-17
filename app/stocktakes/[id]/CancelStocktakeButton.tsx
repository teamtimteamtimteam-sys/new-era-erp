'use client'

// app/stocktakes/[id]/CancelStocktakeButton.tsx
// AUDEL-2:取消前先问【为什么】。成功后不跳转 —— revalidate 让详情页原地变成
// 只读的 cancelled 视图,而理由与人就印在那上面。
import { useRouter } from 'next/navigation'
import ReasonPrompt from '@/app/components/ReasonPrompt'
import { cancelStocktake } from '../actions'
import { useTranslations } from '@/lib/i18n/client'

export default function CancelStocktakeButton({ stocktakeId }: { stocktakeId: string }) {
    const t = useTranslations()
    const router = useRouter()
    return (
        <ReasonPrompt
            triggerLabel={t('stocktakes.cancel')}
            title={t('stocktakes.cancelConfirm')}
            consequence={t('stocktakes.cancelConsequence')}
            confirmLabel={t('stocktakes.cancel')}
            placeholder={t('stocktakes.cancelReasonPlaceholder')}
            action={(reason) => cancelStocktake(stocktakeId, reason)}
            onDone={() => router.refresh()}
        />
    )
}
