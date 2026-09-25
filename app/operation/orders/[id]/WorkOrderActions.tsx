'use client'

// WO-1c:放行 / 收工 / 取消 / 改单。
//
// 【每一个禁用条件都把理由写在控件旁边】(CMP-2)—— 一个按不下去、又不说为什么的
// 按钮,读起来像是坏了。一张 closed 的工单,四个动作【各说各的理由】,
// 而不是整块消失:消失掉的动作与"这里本来就没有这个功能"长得一模一样。
//
// 【理由必填的两个动作,输入框空着就不给按】而服务端【独立】拒空
// (WO_CLOSE_REASON_REQUIRED / WO_CANCEL_REASON_REQUIRED),界面这道不是保护。
import { CONTROL_INPUT } from '@/app/components/ui/control-style'
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { releaseWorkOrder, closeWorkOrder, cancelWorkOrder } from '../actions'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { Refusal } from '@/app/components/ui/refusal'

// ROLE-1 Batch 3b:放行归 action.wo_release(财务、管理员);收工 / 取消归 action.wo_create
// 或 module.processing.edit(库里拒的时候点名 action.wo_create)。
// 两种"按不动"分开说(与 stocktakes 的 PostButton 同一个形状):
//   缺码 → PermissionGate 点名那个码;
//   开单人 → releaseBlockedReason 说出是哪一条(那不是管理员给得了的)。
// 页面只按【账号】判开单人;库那一侧按【人】判 SELF_APPROVAL_FORBIDDEN|raiser。
export default function WorkOrderActions({
    id, status, canRelease, canManage, releaseBlockedReason, hasRuns,
}: {
    id: string; status: string
    /** can('action.wo_release') */
    canRelease: boolean
    /** can('action.wo_create') || can('module.processing.edit') */
    canManage: boolean
    /** 看的人就是开单人时的那句话;否则 null */
    releaseBlockedReason: string | null
    hasRuns: boolean
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
    // 权限那一半交给 PermissionGate(见上),这里只算【状态】那一半的理由 ——
    // 不把两种原因拼进同一个布尔(AGENTS.md DBLOCK-1 第二条边界)。
    const releaseWhy = status !== 'draft' ? t('processing.wo.blocked.releaseNotDraft', { status: t('processing.wo.status.' + status) }) : ''
    const closeWhy   = status !== 'released' ? t('processing.wo.blocked.closeNotReleased', { status: t('processing.wo.status.' + status) }) : ''
    const cancelWhy  = !['draft', 'released'].includes(status)
        ? t('processing.wo.blocked.cancelTerminal', { status: t('processing.wo.status.' + status) })
        : hasRuns ? t('processing.wo.blocked.cancelHasRuns') : ''
    // 开单人那一条只在【状态允许放行】时才是那个原因;状态不允许时说状态。
    const selfWhy = releaseWhy === '' ? releaseBlockedReason : null

    return (
        <div className="space-y-3">
            {error && <p className="text-sm text-red-600">{error}</p>}

            <div className="flex flex-wrap items-center gap-3">
                <PermissionGate code="action.wo_release" allowed={canRelease} inline>
                    <Button variant="secondary" type="button" disabled={isPending || releaseWhy !== '' || selfWhy !== null}
                            onClick={() => run(() => releaseWorkOrder(id))}>
                        {t('processing.wo.actions.release')}
                    </Button>
                </PermissionGate>
                {releaseWhy && <span className="text-xs text-amber-700">{releaseWhy}</span>}
                {canRelease && selfWhy && (
                    <Refusal why={selfWhy} className="whitespace-normal text-left font-normal">
                        {selfWhy}
                    </Refusal>
                )}
            </div>

            <div className="flex flex-wrap items-center gap-3">
                <PermissionGate code="action.wo_create" allowed={canManage} inline>
                    <input type="text" value={closeReason} placeholder={t('processing.wo.actions.closeReasonPlaceholder')}
                           onChange={(e) => setCloseReason(e.target.value)} disabled={closeWhy !== ''}
                           className={`${CONTROL_INPUT} w-72`} />
                    <Button variant="secondary" type="button"
                            disabled={isPending || closeWhy !== '' || closeReason.trim() === ''}
                            onClick={() => run(() => closeWorkOrder(id, closeReason))}>
                        {t('processing.wo.actions.close')}
                    </Button>
                </PermissionGate>
                {closeWhy
                    ? <span className="text-xs text-amber-700">{closeWhy}</span>
                    : <span className="text-xs text-[color:var(--brand-muted-text)]">{t('processing.wo.actions.closeWhy')}</span>}
            </div>

            <div className="flex flex-wrap items-center gap-3">
                <PermissionGate code="action.wo_create" allowed={canManage} inline>
                    <input type="text" value={cancelReason} placeholder={t('processing.wo.actions.cancelReasonPlaceholder')}
                           onChange={(e) => setCancelReason(e.target.value)} disabled={cancelWhy !== ''}
                           className={`${CONTROL_INPUT} w-72`} />
                    <Button variant="destructive" type="button"
                            disabled={isPending || cancelWhy !== '' || cancelReason.trim() === ''}
                            onClick={() => run(() => cancelWorkOrder(id, cancelReason))}>
                        {t('processing.wo.actions.cancel')}
                    </Button>
                </PermissionGate>
                {cancelWhy && <span className="text-xs text-amber-700">{cancelWhy}</span>}
            </div>
        </div>
    )
}
