'use client'

// AUDEL-2:同 inbound —— 删除前先问为什么;软删保留记录并写一条 writeoff 流水。
import ReasonPrompt from '@/app/components/ReasonPrompt'
import { softDeleteOutput } from './actions'
import { useTranslations } from '@/lib/i18n/client'

export default function DeleteButton({ id, code }: { id: string; code: string }) {
    const t = useTranslations()
    return (
        <ReasonPrompt
            variant="link"
            triggerLabel={t('common.delete')}
            title={t('output.deleteConfirm', { code })}
            consequence={t('output.deleteConsequence')}
            confirmLabel={t('common.delete')}
            placeholder={t('output.deleteReasonPlaceholder')}
            action={(reason) => softDeleteOutput(id, reason)}
        />
    )
}
