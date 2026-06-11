'use client'

import { useTransition } from 'react'
import { softDeleteInbound } from './actions'

export default function DeleteButton({
    id,
    code,
}: {
    id: string
    code: string
}) {
    const [isPending, startTransition] = useTransition()

    function handleClick() {
        const confirmed = window.confirm(
            `确定要删除进料批次"${code}"吗?\n\n(软删除:数据保留在数据库中,可以恢复。)`
        )
        if (!confirmed) return

        startTransition(async () => {
            const result = await softDeleteInbound(id)
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
