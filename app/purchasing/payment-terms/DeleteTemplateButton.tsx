'use client'

// 模板软删按钮(window.confirm)。已套用过的 PO 持有行的副本,不受影响。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { deleteTemplate } from './actions'

export default function DeleteTemplateButton({ templateId, name }: { templateId: string; name: string }) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')

    function onDelete() {
        if (!window.confirm(t('purchasing.deleteTemplateConfirm', { 0: name }))) return
        startTransition(async () => {
            const res = await deleteTemplate(templateId)
            if (res.error) setError(res.error)
            else router.refresh()
        })
    }

    return (
        <>
            <button
                type="button"
                onClick={onDelete}
                disabled={isPending}
                className="text-red-600 hover:underline disabled:text-gray-400"
            >
                {isPending ? t('common.deleting') : t('common.delete')}
            </button>
            {error && <span className="ml-2 text-xs text-red-600">{error}</span>}
        </>
    )
}
