'use client'

// app/hr/leave/[id]/DecideControls.tsx
// 审批 / 驳回 / 取消。
// 【余额可能在提交之后变过】,所以批准按钮旁边先给一句提示,真正的拦截仍由
// decide_leave_request 抛 INSUFFICIENT_BALANCE 完成 —— 界面上的提示只是让人少白跑一趟。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { decideLeave, cancelLeave } from '../actions'
import { Button } from '@/app/components/ui/button'

export default function DecideControls({
    requestId,
    status,
    available,
    requested,
}: {
    requestId: string
    status: string
    available: number | null
    requested: number
}) {
    const t = useTranslations()
    const router = useRouter()
    const [notes, setNotes] = useState('')
    const [error, setError] = useState<string | null>(null)
    const [pending, startTransition] = useTransition()

    const short = available !== null && available < requested

    function act(fn: () => Promise<{ error?: string }>) {
        setError(null)
        startTransition(async () => {
            const r = await fn()
            if (r.error) setError(r.error)
            else router.refresh()
        })
    }

    if (status === 'rejected' || status === 'cancelled') {
        return <p className="text-sm text-gray-500">{t(`leave.finalState_${status}`)}</p>
    }

    return (
        <div className="rounded border border-gray-200 p-4">
            {error && (
                <div className="mb-3 rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800">
                    {error}
                </div>
            )}

            {status === 'pending' && short && (
                <div className="mb-3 rounded border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">
                    {t('leave.warnShortBalance', { 0: String(available), 1: String(requested) })}
                </div>
            )}

            <label className="block text-sm mb-3">
                {t('leave.decisionNotes')}
                <input
                    value={notes}
                    onChange={(e) => setNotes(e.target.value)}
                    className="mt-1 w-full border border-gray-300 rounded px-2 py-1 text-sm"
                />
            </label>

            <div className="flex gap-3 flex-wrap">
                {status === 'pending' && (
                    <>
                        <Button size="sm"
                            type="button"
                            disabled={pending}
                            onClick={() => act(() => decideLeave(requestId, true, notes || null))}
                        >
                            {pending ? t('common.saving') : t('leave.approve')}
                        </Button>
                        <button
                            type="button"
                            disabled={pending}
                            onClick={() => act(() => decideLeave(requestId, false, notes || null))}
                            className="border border-gray-300 px-4 py-1.5 rounded text-sm disabled:opacity-50"
                        >
                            {t('leave.reject')}
                        </button>
                    </>
                )}
                {status === 'approved' && (
                    <button
                        type="button"
                        disabled={pending}
                        onClick={() => act(() => cancelLeave(requestId, notes || null))}
                        className="border border-red-300 text-red-700 px-4 py-1.5 rounded text-sm disabled:opacity-50"
                    >
                        {t('leave.cancel')}
                    </button>
                )}
            </div>
            {status === 'approved' && (
                <p className="mt-2 text-xs text-gray-500">{t('leave.cancelHint')}</p>
            )}
        </div>
    )
}
