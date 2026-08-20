'use client'

// LOG-4b:运费单冲销控件。
// AUDEL-2 的形状,一份实现的第六个消费者 —— 不新写一个对话框:
// 后果写在按下【之前】、理由为空时提交钮不可按、服务端仍是权威。
import { useRouter } from 'next/navigation'
import ReasonPrompt from '@/app/components/ReasonPrompt'
import { reverseFreight } from './actions'
import { useTranslations } from '@/lib/i18n/client'

export default function ReverseFreightControl({ id }: { id: string }) {
    const t = useTranslations()
    const router = useRouter()
    return (
        <ReasonPrompt
            triggerLabel={t('finance.freight.reverseButton')}
            title={t('finance.freight.reverseTitle')}
            // 【三件后果都在按下之前说清】分录镜像回零、离开应付账龄、不可撤销;
            // 外加"已被付过款的冲不了"—— 那一条与其让人按下去撞
            // FREIGHT_HAS_SETTLEMENT,不如先说。
            consequence={t('finance.freight.reverseConsequence')}
            confirmLabel={t('finance.freight.reverseButton')}
            placeholder={t('finance.freight.reverseReason')}
            action={(reason) => reverseFreight(id, reason)}
            onDone={() => router.refresh()}
        />
    )
}
