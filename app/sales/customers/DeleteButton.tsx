'use client'

import { useTransition } from 'react'
import { softDeleteCustomer } from './actions'
import { useTranslations } from '@/lib/i18n/client'

export default function DeleteButton({
    id,
    legalName,
}: {
    id: string
    legalName: string
}) {
    const t = useTranslations()
    const [isPending, startTransition] = useTransition()

    function handleClick() {
        const confirmed = window.confirm(
            t('customers.deleteConfirm', { name: legalName })
        )
        if (!confirmed) return

        startTransition(async () => {
            const result = await softDeleteCustomer(id)
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
