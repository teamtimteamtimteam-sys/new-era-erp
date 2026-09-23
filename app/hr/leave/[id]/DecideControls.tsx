'use client'

// app/hr/leave/[id]/DecideControls.tsx
// 审批 / 驳回 / 取消。
// 【余额可能在提交之后变过】,所以批准按钮旁边先给一句提示,真正的拦截仍由
// decide_leave_request 抛 INSUFFICIENT_BALANCE 完成 —— 界面上的提示只是让人少白跑一趟。
import { CONTROL_INPUT } from '@/app/components/ui/control-style'
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { decideLeave, cancelLeave } from '../actions'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'

export default function DecideControls({
    requestId,
    status,
    available,
    requested,
    canDecide,
}: {
    requestId: string
    status: string
    available: number | null
    requested: number
    // ★ ROLE-1(Tim 的矩阵,2026-09-23):决定请假的门是 action.decide_hr_requests(finance 与 cfo)。
    //   此前这两颗按钮对任何进得了 /hr 的人都画着、靠服务端拒;按 DBLOCK-1 改成看得见、按不动、说出码。
    //   【取消】不在门里:cancel_leave_request 是 module.hr.edit 或本人,另一扇门。
    canDecide: boolean
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
        return <p className="text-sm text-[color:var(--brand-muted-text)]">{t(`leave.finalState_${status}`)}</p>
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

            <label className="block mb-3">
                {t('leave.decisionNotes')}
                <input
                    value={notes}
                    onChange={(e) => setNotes(e.target.value)}
                    className={`${CONTROL_INPUT} mt-1 w-full`}
                />
            </label>

            <div className="flex gap-3 flex-wrap">
                {status === 'pending' && (
                    <PermissionGate code="action.decide_hr_requests" allowed={canDecide} inline>
                        <Button
                            type="button"
                            disabled={pending}
                            onClick={() => act(() => decideLeave(requestId, true, notes || null))}
                        >
                            {pending ? t('common.saving') : t('leave.approve')}
                        </Button>
                        <Button
                            type="button"
                            disabled={pending}
                            onClick={() => act(() => decideLeave(requestId, false, notes || null))}
                            variant="secondary"
                        >
                            {t('leave.reject')}
                        </Button>
                    </PermissionGate>
                )}
                {status === 'approved' && (
                    <Button variant="destructive"
                        type="button"
                        disabled={pending}
                        onClick={() => act(() => cancelLeave(requestId, notes || null))}>
                        {t('leave.cancel')}
                    </Button>
                )}
            </div>
            {status === 'approved' && (
                <p className="mt-2 text-xs text-[color:var(--brand-muted-text)]">{t('leave.cancelHint')}</p>
            )}
        </div>
    )
}
