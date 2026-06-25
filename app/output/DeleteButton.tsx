'use client'

import { useTransition } from 'react'
import { softDeleteOutput } from './actions'
import { useTranslations } from '@/lib/i18n/client'

export default function DeleteButton({
    id,
    code,
}: {
    id: string
    code: string
}) {
    const t = useTranslations()
    const [isPending, startTransition] = useTransition()

    function handleClick() {
        const confirmed = window.confirm(
            t('output.deleteConfirm', { code })
        )
        if (!confirmed) return

        startTransition(async () => {
            const result = await softDeleteOutput(id)
            if (result?.error) {
                alert(result.error)
            }
        })
    }

    return (
        <button
            onClick={handleClick}
            disabled={isPending}
            className="text-red-600 hover:underline disabled:text-gray-400"
        >
            {isPending ? t('common.deleting') : t('common.delete')}
        </button>
    )
}
