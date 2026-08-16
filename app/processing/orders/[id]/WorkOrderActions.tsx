'use client'

// WO-1c:放行 / 收工 / 取消 / 改单。
//
// 【每一个禁用条件都把理由写在控件旁边】(CMP-2)—— 一个按不下去、又不说为什么的
// 按钮,读起来像是坏了。一张 closed 的工单,四个动作【各说各的理由】,
// 而不是整块消失:消失掉的动作与"这里本来就没有这个功能"长得一模一样。
//
// 【理由必填的两个动作,输入框空着就不给按】而服务端【独立】拒空
// (WO_CLOSE_REASON_REQUIRED / WO_CANCEL_REASON_REQUIRED),界面这道不是保护。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { releaseWorkOrder, closeWorkOrder, cancelWorkOrder } from '../actions'

export default function WorkOrderActions({
    id, status, canEdit, hasRuns,
}: {
    id: string; status: string; canEdit: boolean; hasRuns: boolean
}) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')
    const [closeReason, setCloseReason] = useState('')
    const [cancelReason, setCancelReason] = useState('')

    function run(fn: () => Promise<{ error?: string }>) {
        setError('')
        startTransition(async () => {
            const res = await fn()
            if (res?.error) { setError(res.error); return }
            router.refresh()
        })
    }

    // 每个动作:能不能做,以及【为什么不能】—— 两者一起算出来,免得有一个分支
    // 只画了禁用而没画理由。
    const noPerm = !canEdit ? `${t('common.restricted')} — ${t('processing.wo.needsEdit')}` : ''
    const releaseWhy = noPerm || (status !== 'draft' ? t('processing.wo.blocked.releaseNotDraft', { status: t('processing.wo.status.' + status) }) : '')
    const closeWhy   = noPerm || (status !== 'released' ? t('processing.wo.blocked.closeNotReleased', { status: t('processing.wo.status.' + status) }) : '')
    const cancelWhy  = noPerm || (!['draft', 'released'].includes(status)
        ? t('processing.wo.blocked.cancelTerminal', { status: t('processing.wo.status.' + status) })
        : hasRuns ? t('processing.wo.blocked.cancelHasRuns') : '')

    return (
        <div className="space-y-3">
            {error && <p className="text-sm text-red-600">{error}</p>}

            <div className="flex flex-wrap items-center gap-3">
                <button type="button" disabled={isPending || releaseWhy !== ''}
                        onClick={() => run(() => releaseWorkOrder(id))}
                        className="text-sm border border-gray-400 px-3 py-1 rounded hover:bg-gray-50 disabled:opacity-50">
                    {t('processing.wo.actions.release')}
                </button>
                {releaseWhy && <span className="text-xs text-amber-700">{releaseWhy}</span>}
            </div>

            <div className="flex flex-wrap items-center gap-3">
                <input type="text" value={closeReason} placeholder={t('processing.wo.actions.closeReasonPlaceholder')}
                       onChange={(e) => setCloseReason(e.target.value)} disabled={closeWhy !== ''}
                       className="border border-gray-300 px-2 py-1 rounded text-sm w-72 disabled:bg-gray-100" />
                <button type="button"
                        disabled={isPending || closeWhy !== '' || closeReason.trim() === ''}
                        onClick={() => run(() => closeWorkOrder(id, closeReason))}
                        className="text-sm border border-gray-400 px-3 py-1 rounded hover:bg-gray-50 disabled:opacity-50">
                    {t('processing.wo.actions.close')}
                </button>
                {closeWhy
                    ? <span className="text-xs text-amber-700">{closeWhy}</span>
                    : <span className="text-xs text-gray-500">{t('processing.wo.actions.closeWhy')}</span>}
            </div>

            <div className="flex flex-wrap items-center gap-3">
                <input type="text" value={cancelReason} placeholder={t('processing.wo.actions.cancelReasonPlaceholder')}
                       onChange={(e) => setCancelReason(e.target.value)} disabled={cancelWhy !== ''}
                       className="border border-gray-300 px-2 py-1 rounded text-sm w-72 disabled:bg-gray-100" />
                <button type="button"
                        disabled={isPending || cancelWhy !== '' || cancelReason.trim() === ''}
                        onClick={() => run(() => cancelWorkOrder(id, cancelReason))}
                        className="text-sm border border-gray-400 px-3 py-1 rounded hover:bg-gray-50 disabled:opacity-50">
                    {t('processing.wo.actions.cancel')}
                </button>
                {cancelWhy && <span className="text-xs text-amber-700">{cancelWhy}</span>}
            </div>
        </div>
    )
}
