'use client'

// 培训记录软删(window.confirm)。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { deleteTraining } from './actions'

export default function DeleteTrainingButton({ id, name }: { id: string; name: string }) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')

    function onDelete() {
        if (!window.confirm(t('hr.deleteTrainingConfirm', { 0: name }))) return
        setError('')
        startTransition(async () => {
            const res = await deleteTraining(id)
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
