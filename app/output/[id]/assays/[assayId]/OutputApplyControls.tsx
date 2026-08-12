'use client'

// 产出化验详情页的两个动作:立即应用 / 撤销应用。
// 进料侧 ApplyAssayControls 是形状的出处;撤销带内联原因 + window.confirm,
// 并挂着提醒:撤销【不回含量】—— 含量退到哪一版是新化验或手工格子的显式动作。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { applyOutputAssayAction, unapplyOutputAssayAction } from '../actions'

// blocked:试算已经报出应用会拒的理由(与应用同一串拒绝 —— fixture 54 I 臂)。
// 理由横幅由页面渲染,这里只让按钮跟着它走。
export function ApplyOutputAssayButton({
    assayId,
    batchId,
    blocked = false,
}: {
    assayId: string
    batchId: string
    blocked?: boolean
}) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')

    function onApply() {
        startTransition(async () => {
            const res = await applyOutputAssayAction(assayId, batchId)
            if (res.error) setError(res.error)
            else router.refresh()
        })
    }

    return (
        <div className="flex flex-wrap items-center gap-3">
            <button
                type="button"
                onClick={onApply}
                disabled={isPending || blocked}
                className={
                    blocked
                        ? 'border border-gray-300 px-4 py-2 rounded disabled:text-gray-400'
                        : 'bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 disabled:bg-gray-400'
                }
            >
                {isPending ? t('common.saving') : t('assay.applyNow')}
            </button>
            {error && <span className="text-sm text-red-600">{error}</span>}
        </div>
    )
}

export function UnapplyOutputAssayControl({ assayId, batchId }: { assayId: string; batchId: string }) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [reason, setReason] = useState('')
    const [error, setError] = useState('')

    function onUnapply() {
        if (!window.confirm(t('assay.output.unapplyConfirm'))) return
        startTransition(async () => {
            const res = await unapplyOutputAssayAction(assayId, batchId, reason)
            if (res.error) setError(res.error)
            else router.refresh()
        })
    }

    return (
        <div className="space-y-2">
            <p className="text-xs text-gray-500">{t('assay.output.unapplyNote')}</p>
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
