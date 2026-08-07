'use client'

// 结束 / 重新打开采购单(cut 4c)。
// 结束:有未抵扣预付时把金额醒目摆出来,说明必填,填了才让按 —— 那是躺在 1300 里
// 的真钱,这张单不会再吸收它了,不许无声搁浅。没有未抵扣预付时,一次 confirm 即可。
// 重新打开:内联原因 + confirm。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { formatMoney } from '@/lib/format'
import { closeOrder, reopenOrder } from './actions'

export function CloseOrderControl({
    poId,
    unappliedPrepayment,
}: {
    poId: string
    /** OPS-14:null = 读者没有 module.finance.view,【未抵扣预付未知】。
     *  未知按"有"处理 —— 关单说明是给未抵扣预付留的记录,漏掉它比多写一句糟。 */
    unappliedPrepayment: number | null
}) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [open, setOpen] = useState(false)
    const [notes, setNotes] = useState('')
    const [error, setError] = useState('')

    const needsNotes = unappliedPrepayment === null || unappliedPrepayment > 0
    const canSubmit = !needsNotes || notes.trim() !== ''

    function onClose() {
        if (!window.confirm(t('purchasing.closeConfirm'))) return
        startTransition(async () => {
            const res = await closeOrder(poId, notes)
            if (res.error) setError(res.error)
            else router.refresh()
        })
    }

    if (!open) {
        return (
            <button
                type="button"
                onClick={() => setOpen(true)}
                className="border border-gray-300 px-3 py-1.5 rounded hover:bg-gray-50 text-sm"
            >
                {t('purchasing.close')}
            </button>
        )
    }

    return (
        <div className="border border-gray-300 rounded p-3 text-sm space-y-2 max-w-md">
            {needsNotes && (
                <p className="text-amber-800 bg-amber-50 border border-amber-300 rounded px-3 py-2">
                    {unappliedPrepayment === null
                        ? t('purchasing.closeWithPrepaymentUnknown')
                        : t('purchasing.closeWithPrepaymentWarning', {
                              amount: formatMoney(unappliedPrepayment),
                          })}
                </p>
            )}
            <div>
                <label className="block text-xs text-gray-600 mb-1">{t('purchasing.closeNotes')}</label>
                <input
                    type="text"
                    value={notes}
                    onChange={(e) => setNotes(e.target.value)}
                    className="w-full border border-gray-300 px-3 py-1.5 rounded"
                />
            </div>
            {error && <p className="text-red-600">{error}</p>}
            <div className="flex gap-2">
                <button
                    type="button"
                    onClick={onClose}
                    disabled={isPending || !canSubmit}
                    className="bg-blue-600 text-white px-3 py-1.5 rounded hover:bg-blue-700 disabled:bg-gray-400"
                >
                    {t('purchasing.close')}
                </button>
                <button
                    type="button"
                    onClick={() => setOpen(false)}
                    className="border border-gray-300 px-3 py-1.5 rounded hover:bg-gray-50"
                >
                    {t('common.cancel')}
                </button>
            </div>
        </div>
    )
}

export function ReopenOrderControl({ poId }: { poId: string }) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [reason, setReason] = useState('')
    const [error, setError] = useState('')

    function onReopen() {
        if (!window.confirm(t('purchasing.reopenConfirm'))) return
        startTransition(async () => {
            const res = await reopenOrder(poId, reason)
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
                placeholder={t('purchasing.reopenReason')}
                className="border border-gray-300 px-3 py-1.5 rounded text-sm"
            />
            <button
                type="button"
                onClick={onReopen}
                disabled={isPending || reason.trim() === ''}
                className="border border-gray-300 px-3 py-1.5 rounded hover:bg-gray-50 text-sm disabled:opacity-50"
            >
                {t('purchasing.reopen')}
            </button>
            {error && <span className="text-sm text-red-600">{error}</span>}
        </div>
    )
}
