'use client'

// 冲销按钮(danger outline):window.confirm 后调 reverseEntry,失败 alert
// (端口自 inbound/DeleteButton);成功由 action 重定向到冲销单详情。
import { useTransition } from 'react'
import { reverseEntry } from './actions'
import { useTranslations } from '@/lib/i18n/client'

export default function ReverseButton({ entryId }: { entryId: string }) {
    const t = useTranslations()
    const [isPending, startTransition] = useTransition()

    function handleClick() {
        const confirmed = window.confirm(t('finance.reverseConfirm'))
        if (!confirmed) return

        startTransition(async () => {
            const result = await reverseEntry(entryId)
            if (result?.error) {
                alert(result.error)
            }
        })
    }

    return (
        <button
            onClick={handleClick}
            disabled={isPending}
            className="border border-red-300 text-red-600 px-3 py-1 rounded hover:bg-red-50 disabled:opacity-50"
        >
            {isPending ? t('common.saving') : t('finance.reverse')}
        </button>
    )
}
