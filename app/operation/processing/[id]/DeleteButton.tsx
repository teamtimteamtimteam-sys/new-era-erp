'use client'

// AUDEL-2:回滚前先问【为什么】,而且把后果摆在按下之前。
// 这不是"删掉一条记录":它还原投入、作废产出、写一整串冲销流水。
//
// ★ BTN-4:折进 <ConfirmButton reason>。后果那一段(consequence)进 body ——
//   它必须在按下之前就在眼前,而 body 正是对话框里放这句话的地方。
//   ☞ 主语是加工单号(code),由父组件传进来:原来只拿到 runId。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { deleteProcessingRun } from './actions'
import { useTranslations } from '@/lib/i18n/client'
import { PermissionGate } from '@/app/components/ui/permission-gate'

// ★ ROLE-1 Batch 3b:回滚(rollback_processing_run)归 action.processing_rollback(仓库、管理员)。
//   canRollback 由页面 can() 算好传进来;缺码时看得见、按不动、点名那个码。
export default function DeleteButton({ runId, code, canRollback }: { runId: string; code: string; canRollback: boolean }) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')

    return (
        <div className="inline-flex flex-col items-end">
            <PermissionGate code="action.processing_rollback" allowed={canRollback} className="items-end">
            <ConfirmButton
                subject={code}
                title={t('processing.delete.confirmTitle')}
                body={t('processing.delete.consequence')}
                confirmLabel={t('processing.delete.confirmButton')}
                tier="destructive"
                reason={{ placeholder: t('processing.delete.reasonPlaceholder') }}
                triggerVariant="destructive"
                disabled={isPending}
                onConfirm={(reason) => {
                    setError('')
                    startTransition(async () => {
                        const res = await deleteProcessingRun(runId, reason)
                        if (res && 'error' in res && res.error) setError(res.error)
                        else router.push('/operation/processing')
                    })
                }}
            >
                {isPending ? t('common.saving') : t('processing.delete.triggerButton')}
            </ConfirmButton>
            </PermissionGate>
            {error && <p className="mt-1 max-w-md text-xs text-destructive-text">{error}</p>}
        </div>
    )
}
