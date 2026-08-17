'use client'

// 采购单取消控件。能否取消由服务端判定后经 props 传入;不能取消时父组件直接
// 渲染原因说明,本组件只在"可取消"时出现。
// AUDEL-2:改用共用的 ReasonPrompt —— 此前理由是一个【可以留空】的输入框,
// 而 AUDEL-1b 起服务端必填。空着提交只会换来一次拒绝,所以现在按钮直接禁用。
import { useRouter } from 'next/navigation'
import ReasonPrompt from '@/app/components/ReasonPrompt'
import { cancelOrder } from './actions'
import { useTranslations } from '@/lib/i18n/client'

export default function CancelOrderControl({ poId }: { poId: string }) {
    const t = useTranslations()
    const router = useRouter()
    return (
        <ReasonPrompt
            triggerLabel={t('purchasing.cancelOrder')}
            title={t('purchasing.cancelConfirm')}
            consequence={t('purchasing.cancelConsequence')}
            confirmLabel={t('purchasing.cancelOrder')}
            placeholder={t('purchasing.cancelReason')}
            action={(reason) => cancelOrder(poId, reason)}
            onDone={() => router.refresh()}
        />
    )
}
