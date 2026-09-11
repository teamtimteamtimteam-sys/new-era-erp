'use client'

// 模板软删按钮。已套用过的 PO 持有行的副本,不受影响。
// CONFIRM-1:确认从原生确认框换成 <ConfirmButton> —— 名字进了对话框自己那一格。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { deleteTemplate } from './actions'
import { PermissionGate } from '@/app/components/ui/permission-gate'

export default function DeleteTemplateButton({ templateId, name ,
canEdit
}: { templateId: string; name: string 
canEdit: boolean
}) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')

    return (
        <>
            <PermissionGate code="module.purchasing.edit" allowed={canEdit}>
            <ConfirmButton
                subject={name}
                title={t('purchasing.deleteTemplateConfirmTitle')}
                body={t('common.softDeleteNote')}
                details={
                    <p className="text-sm font-medium text-[color:var(--brand-text)]">
                        {t('purchasing.deleteTemplateConsequence')}
                    </p>
                }
                confirmLabel={t('common.delete')}
                tier="destructive"
                disabled={isPending}
                className="text-red-600 hover:underline disabled:text-gray-400"
                onConfirm={() => {
                    setError('')
                    startTransition(async () => {
                        const res = await deleteTemplate(templateId)
                        if (res.error) setError(res.error)
                        else router.refresh()
                    })
                }}
            >
                {isPending ? t('common.deleting') : t('common.delete')}
            </ConfirmButton>
            </PermissionGate>
            {error && <span className="ml-2 text-xs text-red-600">{error}</span>}
        </>
    )
}
