'use client'

// 期间锁表单:日期 + 设置(confirm)/ 解除(confirm)。失败 alert,成功由 revalidate 刷新展示。
import { useState, useTransition } from 'react'
import { setPeriodLock } from './actions'
import { useTranslations } from '@/lib/i18n/client'

export default function LockForm({ lockedBefore }: { lockedBefore: string | null }) {
    const t = useTranslations()
    const [isPending, startTransition] = useTransition()
    const [date, setDate] = useState(lockedBefore ?? '')

    function submit(value: string | null, confirmKey: string) {
        if (!window.confirm(t(confirmKey))) return
        startTransition(async () => {
            const result = await setPeriodLock(value)
            if (result?.error) {
                alert(result.error)
            }
        })
    }

    return (
        <div className="flex flex-wrap items-end gap-3">
            <div>
                <label className="block text-sm font-medium mb-1">{t('finance.lockedBefore')}</label>
                <input
                    type="date"
                    value={date}
                    onChange={(e) => setDate(e.target.value)}
                    className="border border-gray-300 px-3 py-2 rounded"
                />
            </div>
            <button
                onClick={() => date && submit(date, 'finance.lockConfirm')}
                disabled={isPending || !date}
                className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 disabled:bg-gray-400"
            >
                {isPending ? t('common.saving') : t('finance.setLock')}
            </button>
            {lockedBefore && (
                <button
                    onClick={() => submit(null, 'finance.unlockConfirm')}
                    disabled={isPending}
                    className="border border-red-300 text-red-600 px-4 py-2 rounded hover:bg-red-50 disabled:opacity-50"
                >
                    {t('finance.unlock')}
                </button>
            )}
        </div>
    )
}
