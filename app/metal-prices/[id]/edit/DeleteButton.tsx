'use client'

import { useTransition } from 'react'
import { softDeleteMetalPrice } from './actions'
import { useTranslations } from '@/lib/i18n/client'

export default function DeleteButton({ id }: { id: string }) {
    const t = useTranslations()
    const [isPending, startTransition] = useTransition()

    function handleClick() {
        if (!window.confirm(t('metalPrices.deleteConfirm'))) return
        startTransition(async () => {
            // 成功时服务端 redirect 接管;仅失败时才会返回带 error 的对象。
            const result = await softDeleteMetalPrice(id)
            if (result?.error) {
                alert(result.error)
            }
        })
    }

    return (
        <button
            type="button"
            onClick={handleClick}
            disabled={isPending}
            className="text-sm border border-red-300 text-red-600 px-3 py-1 rounded hover:bg-red-50 disabled:opacity-50"
        >
            {isPending ? t('common.deleting') : t('common.delete')}
        </button>
    )
}
