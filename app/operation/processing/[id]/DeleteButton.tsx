'use client'

// AUDEL-2:回滚前先问【为什么】,而且把后果摆在按下之前。
// 这不是"删掉一条记录":它还原投入、作废产出、写一整串冲销流水。
import { useRouter } from 'next/navigation'
import ReasonPrompt from '@/app/components/ReasonPrompt'
import { deleteProcessingRun } from './actions'
import { useTranslations } from '@/lib/i18n/client'

export default function DeleteButton({ runId }: { runId: string }) {
    const t = useTranslations()
    const router = useRouter()
    return (
        <ReasonPrompt
            triggerLabel={t('processing.delete.triggerButton')}
            title={t('processing.delete.confirmTitle')}
            consequence={t('processing.delete.consequence')}
            confirmLabel={t('processing.delete.confirmButton')}
            placeholder={t('processing.delete.reasonPlaceholder')}
            action={(reason) => deleteProcessingRun(runId, reason)}
            onDone={() => router.push('/operation/processing')}
        />
    )
}
