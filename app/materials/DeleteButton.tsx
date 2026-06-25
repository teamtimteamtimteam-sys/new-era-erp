'use client'

import { useTransition } from 'react'
import { softDeleteMaterial } from './actions'
import { useTranslations } from '@/lib/i18n/client'

export default function DeleteButton({
    id,
    name,
}: {
    id: string
    name: string
}) {
    const t = useTranslations()
    const [isPending, startTransition] = useTransition()

    function handleClick() {
        const confirmed = window.confirm(
            t('materials.deleteConfirm', { name })
        )
        if (!confirmed) return

        startTransition(async () => {
            const result = await softDeleteMaterial(id)
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
