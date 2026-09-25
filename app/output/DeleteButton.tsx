'use client'

// AUDEL-2:同 inbound —— 删除前先问为什么;软删保留记录并写一条 writeoff 流水。
// ★ BTN-4:从 ReasonPrompt 折进 <ConfirmButton reason>。主语(批号)进对话框
//   自己那一格,标题退回成不含主语的问话;拒绝显示在按钮旁边。
//   两处的取舍与理由,见 app/inbound/DeleteButton.tsx 抬头 —— 同一次折叠的同一课。
import { useState, useTransition } from 'react'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { softDeleteOutput } from './actions'
import { useTranslations } from '@/lib/i18n/client'
import { PermissionGate } from '@/app/components/ui/permission-gate'

// ★ ROLE-1 Batch 3b:注销(软删)归 action.batch_write_off(仓库、管理员);库里 soft_delete_output_batch 按码拒。
//   canWriteOff 由页面用 can() 算好传下来 —— 缺码时看得见、按不动、点名那个码。
export default function DeleteButton({ id, code, canWriteOff }: { id: string; code: string; canWriteOff: boolean }) {
    const t = useTranslations()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')

    return (
        <span className="inline-flex flex-col items-start">
            <PermissionGate code="action.batch_write_off" allowed={canWriteOff} inline>
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
            </PermissionGate>
            {error && <span className="mt-1 text-xs text-destructive-text">{error}</span>}
        </span>
    )
}
