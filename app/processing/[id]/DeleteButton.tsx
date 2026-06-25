'use client'

import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { deleteProcessingRun } from './actions'
import { useTranslations } from '@/lib/i18n/client'

export default function DeleteButton({ runId }: { runId: string }) {
    const t = useTranslations()
    const router = useRouter()
    const [confirming, setConfirming] = useState(false)
    const [error, setError] = useState<string | null>(null)
    const [isPending, startTransition] = useTransition()

    function handleDelete() {
        setError(null)
        startTransition(async () => {
            const result = await deleteProcessingRun(runId)
            if (result.error) {
                setError(result.error)
                setConfirming(false)
            } else {
                router.push('/processing')
            }
        })
    }

    if (!confirming) {
        return (
            <div className="flex flex-col items-end gap-2">
                <button
                    onClick={() => setConfirming(true)}
                    className="text-sm border border-red-300 text-red-600 px-3 py-1 rounded hover:bg-red-50"
                >
                    {t('processing.delete.triggerButton')}
                </button>
                {error && (
                    <p className="text-sm text-red-600 max-w-md text-right">{error}</p>
                )}
            </div>
        )
    }

    return (
        <div className="flex flex-col items-end gap-2">
            <div className="bg-red-50 border border-red-200 rounded p-3 max-w-md">
                <p className="text-sm text-red-800 mb-3">
                    {t('processing.delete.confirmText')}
                </p>
                <div className="flex gap-2 justify-end">
                    <button
                        onClick={() => setConfirming(false)}
                        disabled={isPending}
                        className="text-sm border border-gray-300 px-3 py-1 rounded hover:bg-gray-50 disabled:opacity-50"
                    >
                        {t('common.cancel')}
                    </button>
                    <button
                        onClick={handleDelete}
                        disabled={isPending}
                        className="text-sm bg-red-600 text-white px-3 py-1 rounded hover:bg-red-700 disabled:opacity-50"
                    >
                        {isPending ? t('processing.delete.deleting') : t('processing.delete.confirmDelete')}
                    </button>
                </div>
            </div>
        </div>
    )
}
