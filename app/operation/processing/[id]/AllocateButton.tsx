'use client'

import { useState, useTransition } from 'react'
import { runAllocation } from './allocationActions'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'

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
            <Button
                type="button"
                onClick={handleClick}
                disabled={isPending}
                variant="default" size="default"
            >
                {isPending ? t('processing.allocation.running') : t('processing.allocation.button')}
            </Button>
            {error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mt-3">
                    {error}
                </div>
            )}
        </div>
    )
}
