'use client'

// AUDEL-2:同 inbound —— 删除前先问为什么;软删保留记录并写一条 writeoff 流水。
// ★ BTN-4:从 ReasonPrompt 折进 <ConfirmButton reason>。主语(批号)进对话框
//   自己那一格,标题退回成不含主语的问话;拒绝显示在按钮旁边。
//   两处的取舍与理由,见 app/inbound/DeleteButton.tsx 抬头 —— 同一次折叠的同一课。
import { useState, useTransition } from 'react'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { softDeleteOutput } from './actions'
import { useTranslations } from '@/lib/i18n/client'

export default function DeleteButton({ id, code }: { id: string; code: string }) {
    const t = useTranslations()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')

    return (
        <span className="inline-flex flex-col items-start">
            <ConfirmButton
                subject={code}
                title={t('output.deleteConfirmTitle')}
                body={t('output.deleteConsequence')}
                confirmLabel={t('common.delete')}
                tier="destructive"
                reason={{ placeholder: t('output.deleteReasonPlaceholder') }}
                triggerVariant="destructive"
                triggerSize="inline"
                disabled={isPending}
                onConfirm={(reason) => {
                    setError('')
                    startTransition(async () => {
                        const res = await softDeleteOutput(id, reason)
                        if (res && 'error' in res && res.error) setError(res.error)
                    })
                }}
            >
                {isPending ? t('common.deleting') : t('common.delete')}
            </ConfirmButton>
            {error && <span className="mt-1 text-xs text-destructive-text">{error}</span>}
        </span>
    )
}
