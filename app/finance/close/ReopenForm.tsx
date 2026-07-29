'use client'

// 行内重开:原因输入 + window.confirm 后调 reopenPeriod,失败 alert。
// 原因为空时按钮禁用(DB 端 REASON_REQUIRED 是第二道防线)。
import { useState, useTransition } from 'react'
import { reopenPeriod } from './actions'
import { useTranslations } from '@/lib/i18n/client'

export default function ReopenForm({ periodEnd }: { periodEnd: string }) {
    const t = useTranslations()
    const [reason, setReason] = useState('')
    const [isPending, startTransition] = useTransition()

    function handleClick() {
        const confirmed = window.confirm(t('finance.reopenConfirm'))
        if (!confirmed) return

        startTransition(async () => {
            const result = await reopenPeriod(periodEnd, reason)
            if (result?.error) {
                alert(result.error)
            } else {
                setReason('')
            }
        })
    }

    return (
        <div className="flex items-center gap-2">
            <input
                type="text"
                value={reason}
                onChange={(e) => setReason(e.target.value)}
                placeholder={t('finance.reopenReason')}
                className="w-40 border border-gray-300 px-2 py-1 rounded text-sm"
            />
            <button
                onClick={handleClick}
                disabled={isPending || !reason.trim()}
                className="border border-red-300 text-red-600 px-3 py-1 rounded hover:bg-red-50 disabled:opacity-50"
            >
                {isPending ? t('common.saving') : t('finance.reopenButton')}
            </button>
        </div>
    )
}
