'use client'

import { useState, useTransition } from 'react'
import { runAllocation } from './allocationActions'
import { useTranslations } from '@/lib/i18n/client'

export default function AllocateButton({ runId }: { runId: string }) {
    const t = useTranslations()
    const [error, setError] = useState<string | null>(null)
    const [isPending, startTransition] = useTransition()

    function handleClick() {
        setError(null)
        startTransition(async () => {
            const result = await runAllocation(runId)
            if (result?.error) setError(result.error)
        })
    }

    return (
        <div>
            <button
                type="button"
                onClick={handleClick}
                disabled={isPending}
                className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 disabled:bg-gray-400"
            >
                {isPending ? t('processing.allocation.running') : t('processing.allocation.button')}
            </button>
            {error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mt-3">
                    {error}
                </div>
            )}
        </div>
    )
}
