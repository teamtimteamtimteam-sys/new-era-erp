'use client'

// 采购单取消控件:内联原因输入 + window.confirm → cancelOrder。
// 能否取消由服务端判定后经 props 传入;不能取消时父组件直接渲染原因说明,
// 本组件只在"可取消"时出现。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { cancelOrder } from './actions'

export default function CancelOrderControl({ poId }: { poId: string }) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [reason, setReason] = useState('')
    const [error, setError] = useState('')

    function onCancel() {
        if (!window.confirm(t('purchasing.cancelConfirm'))) return
        startTransition(async () => {
            const res = await cancelOrder(poId, reason)
            if (res.error) setError(res.error)
            else router.refresh()
        })
    }

    return (
        <div className="flex flex-wrap items-center gap-2">
            <input
                type="text"
                value={reason}
                onChange={(e) => setReason(e.target.value)}
                placeholder={t('purchasing.cancelReason')}
                className="border border-gray-300 px-3 py-1.5 rounded text-sm"
            />
            <button
                type="button"
                onClick={onCancel}
                disabled={isPending}
                className="border border-red-300 text-red-600 px-3 py-1.5 rounded hover:bg-red-50 text-sm disabled:opacity-50"
            >
                {t('purchasing.cancelOrder')}
            </button>
            {error && <span className="text-sm text-red-600">{error}</span>}
        </div>
    )
}
