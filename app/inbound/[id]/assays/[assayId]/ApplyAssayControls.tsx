'use client'

// 化验详情页的两个动作:立即应用 / 撤销应用。
// 撤销带内联原因 + window.confirm,并挂着醒目的提醒:撤销【不回价】。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { applyAssay, unapplyAssay } from '../actions'

export function ApplyNowButton({ assayId, batchId }: { assayId: string; batchId: string }) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')

    function onApply() {
        startTransition(async () => {
            const res = await applyAssay(assayId, batchId)
            if (res.error) setError(res.error)
            else router.refresh()
        })
    }

    return (
        <div className="flex flex-wrap items-center gap-3">
            <button
                type="button"
                onClick={onApply}
                disabled={isPending}
                className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 disabled:bg-gray-400"
            >
                {isPending ? t('common.saving') : t('assay.applyNow')}
            </button>
            {error && <span className="text-sm text-red-600">{error}</span>}
        </div>
    )
}

export function UnapplyControl({ assayId, batchId }: { assayId: string; batchId: string }) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [reason, setReason] = useState('')
    const [error, setError] = useState('')

    function onUnapply() {
        if (!window.confirm(t('assay.unapplyConfirm'))) return
        startTransition(async () => {
            const res = await unapplyAssay(assayId, batchId, reason)
            if (res.error) setError(res.error)
            else router.refresh()
        })
    }

    return (
        <div className="space-y-2">
            <p className="text-xs text-gray-500">{t('assay.unapplyNote')}</p>
            <div className="flex flex-wrap items-center gap-2">
                <input
                    type="text"
                    value={reason}
                    onChange={(e) => setReason(e.target.value)}
                    placeholder={t('assay.unapplyReason')}
                    className="border border-gray-300 px-3 py-1.5 rounded text-sm"
                />
                <button
                    type="button"
                    onClick={onUnapply}
                    disabled={isPending || reason.trim() === ''}
                    className="border border-red-300 text-red-600 px-3 py-1.5 rounded hover:bg-red-50 text-sm disabled:opacity-50"
                >
                    {t('assay.unapply')}
                </button>
                {error && <span className="text-sm text-red-600">{error}</span>}
            </div>
        </div>
    )
}
