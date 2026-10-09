'use client'

// MES-5b-3:放行与取消一份配料计划(Q19)。
//   【两种"按不动"分开说】缺码 → PermissionGate 点名那个码;建单人 → releaseBlockedReason 说出是哪一条(那不是管理员给得了的);
//   状态不对 → 一行字说当前是什么状态。三者不拼进同一个布尔(DBLOCK-1 第二条边界)。
//   取消的理由空着不给按,服务端【独立】拒空(BLEND_CANCEL_REASON_REQUIRED)。
import { CONTROL_INPUT } from '@/app/components/ui/control-style'
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { Refusal } from '@/app/components/ui/refusal'
import { releaseBlendingPlan, cancelBlendingPlan } from '../actions'

export default function BlendingPlanActions({ id, status, canRelease, canManage, releaseBlockedReason }: {
    id: string; status: string; canRelease: boolean; canManage: boolean; releaseBlockedReason: string | null
}) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')
    const [reason, setReason] = useState('')

    function run(fn: () => Promise<{ error?: string }>) {
        setError('')
        startTransition(async () => {
            const res = await fn()
            if (res?.error) { setError(res.error); return }
            router.refresh()
        })
    }
    const statusLabel = t('blending.status.' + status)
    const releaseWhy = status !== 'draft' ? t('blending.blocked.releaseNotDraft', { status: statusLabel }) : ''
    const cancelWhy = !['draft', 'released'].includes(status) ? t('blending.blocked.cancelTerminal', { status: statusLabel }) : ''
    const selfWhy = releaseWhy === '' ? releaseBlockedReason : null

    return (
        <div className="space-y-3" data-control="blending-plan-actions">
            {error && <p className="text-sm text-red-600">{error}</p>}
            <div className="flex flex-wrap items-center gap-3">
                <PermissionGate code="action.wo_release" allowed={canRelease} inline className="flex-wrap">
                    <Button variant="secondary" type="button" disabled={isPending || releaseWhy !== '' || selfWhy !== null}
                            onClick={() => run(() => releaseBlendingPlan(id))}>
                        {t('blending.actions.release')}
                    </Button>
                </PermissionGate>
                {releaseWhy
                    ? <span className="text-xs text-amber-700">{releaseWhy}</span>
                    : <span className="text-xs text-[color:var(--brand-muted-text)]">{t('blending.actions.releaseWhy')}</span>}
                {canRelease && selfWhy && (
                    <Refusal why={selfWhy} className="whitespace-normal text-left font-normal">{selfWhy}</Refusal>
                )}
            </div>
            <div className="flex flex-wrap items-center gap-3">
                {/* flex-wrap:输入框、按钮与缺码那一句在手机上折行,不横着撑破页面(390px 实测 +107px → 0) */}
                <PermissionGate code="action.wo_create" allowed={canManage} inline className="flex-wrap">
                    <input type="text" value={reason} placeholder={t('blending.actions.cancelReasonPlaceholder')}
                           onChange={(e) => setReason(e.target.value)} disabled={cancelWhy !== ''}
                           className={`${CONTROL_INPUT} min-w-0 basis-full sm:basis-72`} />
                    <Button variant="destructive" type="button" disabled={isPending || cancelWhy !== '' || reason.trim() === ''}
                            onClick={() => run(() => cancelBlendingPlan(id, reason))}>
                        {t('blending.actions.cancel')}
                    </Button>
                </PermissionGate>
                {cancelWhy && <span className="text-xs text-amber-700">{cancelWhy}</span>}
            </div>
        </div>
    )
}
