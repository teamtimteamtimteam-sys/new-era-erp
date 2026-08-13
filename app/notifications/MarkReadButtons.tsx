'use client'

// NTF-1:标记已读的两个按钮。一个客户端组件同时服务两处 —— 带 id 是"这一条",
// 不带是"全部"。【失败要说出来】:标记失败而按钮安静地什么都不做,
// 会让人以为读过了,而它下一次刷新又回来。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { markRead, markAllRead } from './actions'

export default function MarkReadButtons({ id }: { id?: string }) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')

    function onClick() {
        setError('')
        startTransition(async () => {
            const res = id ? await markRead(id) : await markAllRead()
            if (res.error) setError(res.error)
            else router.refresh()
        })
    }

    return (
        <div className="shrink-0 text-right">
            <button
                type="button"
                onClick={onClick}
                disabled={isPending}
                className="text-xs border border-gray-300 px-2 py-1 rounded hover:bg-gray-50 disabled:opacity-50"
            >
                {isPending
                    ? t('common.saving')
                    : id
                      ? t('notifications.markRead')
                      : t('notifications.markAll')}
            </button>
            {error && <p className="text-xs text-red-600 mt-1">{error}</p>}
        </div>
    )
}
