'use client'

// AUDEL-2:删除前先问【为什么】—— AUDEL-1b 把理由做成必填,而当时没有输入框,
// 这个按钮从那时起一直被数据库按名拒。本文件是那个缺口的修补。
// 【软删,不是硬删】它保留记录、写一条 writeoff 流水,并记下谁与为什么。
import ReasonPrompt from '@/app/components/ReasonPrompt'
import { softDeleteInbound } from './actions'
import { useTranslations } from '@/lib/i18n/client'

export default function DeleteButton({ id, code }: { id: string; code: string }) {
    const t = useTranslations()
    return (
        <ReasonPrompt
            variant="link"
            triggerLabel={t('common.delete')}
            title={t('inbound.deleteConfirm', { code })}
            consequence={t('inbound.deleteConsequence')}
            confirmLabel={t('common.delete')}
            placeholder={t('inbound.deleteReasonPlaceholder')}
            action={(reason) => softDeleteInbound(id, reason)}
        />
    )
}
