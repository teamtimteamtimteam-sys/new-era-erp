'use client'

// 模板软删按钮。已套用过的 PO 持有行的副本,不受影响。
// CONFIRM-1:确认从原生确认框换成 <ConfirmButton> —— 名字进了对话框自己那一格。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { deleteTemplate } from './actions'

export default function DeleteTemplateButton({ templateId, name }: { templateId: string; name: string }) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')

    return (
        <>
            <ConfirmButton
                subject={name}
                title={t('purchasing.deleteTemplateConfirmTitle')}
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
            {error && <span className="ml-2 text-xs text-red-600">{error}</span>}
        </>
    )
}
