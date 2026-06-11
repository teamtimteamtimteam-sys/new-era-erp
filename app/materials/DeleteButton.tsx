'use client'

import { useTransition } from 'react'
import { softDeleteMaterial } from './actions'

export default function DeleteButton({
    id,
    name,
}: {
    id: string
    name: string
}) {
    const [isPending, startTransition] = useTransition()

    function handleClick() {
        const confirmed = window.confirm(
            `确定要删除"${name}"吗?\n\n(软删除:数据保留在数据库中,可以恢复。)`
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
            {isPending ? '删除中...' : '删除'}
        </button>
    )
}
