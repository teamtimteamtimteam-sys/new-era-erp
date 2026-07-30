'use client'

// 重新打开已对账报表:内联理由输入 + window.confirm,再调 unreconcileStatement。
// 理由必填(DB 侧 REASON_REQUIRED 兜底),成功后 revalidate 让页面回到 open 状态。
import { useState, useTransition } from 'react'
import { unreconcileStatement } from './actions'
import { useTranslations } from '@/lib/i18n/client'

export default function UnreconcileControl({ statementId }: { statementId: string }) {
    const t = useTranslations()
    const [isPending, startTransition] = useTransition()
    const [open, setOpen] = useState(false)
    const [reason, setReason] = useState('')

    function handleSubmit() {
        if (!window.confirm(t('bank.unreconcileConfirm'))) return
        startTransition(async () => {
            const result = await unreconcileStatement(statementId, reason.trim())
            if (result?.error) {
                alert(result.error)
            } else {
                setOpen(false)
                setReason('')
            }
        })
    }

    if (!open) {
        return (
            <button
                type="button"
                onClick={() => setOpen(true)}
                className="border border-gray-300 px-3 py-1 rounded hover:bg-gray-50 text-sm"
            >
                {t('bank.unreconcile')}
            </button>
        )
    }

    return (
        <span className="flex flex-wrap items-center gap-2">
            <input
                type="text"
                value={reason}
                onChange={(e) => setReason(e.target.value)}
                placeholder={t('bank.unreconcileReasonPlaceholder')}
                className="border border-gray-300 px-3 py-1 rounded text-sm min-w-[16rem]"
            />
            <button
                type="button"
                disabled={!reason.trim() || isPending}
                onClick={handleSubmit}
                className="bg-gray-700 text-white px-3 py-1 rounded hover:bg-gray-800 disabled:bg-gray-400 text-sm"
            >
                {t('bank.unreconcile')}
            </button>
            <button
                type="button"
                onClick={() => setOpen(false)}
                className="text-gray-600 hover:underline text-sm"
            >
                {t('common.cancel')}
            </button>
        </span>
    )
}
