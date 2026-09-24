'use client'

// CONFIRM-1:重要的状态迁移原来问的是原生确认框,而【它不说这是哪一家】——
//   一张供应商编辑页上只有一家,可确认框本身答不出这件事,冒烟也点不到它。
//   ★ 只有 DESTRUCTIVE_TRANSITIONS 里那几档要确认,其余照旧直接执行 ——
//     这条判据一个字没改,只是"要确认"的那一支换了实现。
//   ★ 那条消息里的 `\n\n` / `\n` 原来靠灰盒子换行;现在它们是 details 里
//     真正的几行 <p>。**一个字都没有改写** —— 只是不再被压成一段。
import { useTransition } from 'react'
import { changeSupplierStatus } from './statusActions'
import { DESTRUCTIVE_TRANSITIONS } from './statusMachine'
import { useTranslations } from '@/lib/i18n/client'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import type { Database } from '@/lib/database.types'
import { Button } from '@/app/components/ui/button'
import { Refusal } from '@/app/components/ui/refusal'
import { showActionMessage } from '@/app/components/ui/action-message'
import { PermissionGate } from '@/app/components/ui/permission-gate'

type SupplierStatus = Database['public']['Enums']['supplier_status']

/** ROLE-1 Batch 2a:这一家此刻能走的一步 —— 由页面向 supplier_status_moves() 要来,
 *  连同【那一步要的码】与【这个人持不持有它】。本组件不自己判,只画。 */
export type SupplierStatusMove = {
    to: SupplierStatus
    code: string
    allowed: boolean
}

export default function StatusPanel({
    id,
    subject,
    currentStatus,
    moves,
}: {
    id: string
    /** CONFIRM-1:这一次改的是【哪一家】—— 供应商代号,抬头里就印着它。 */
    subject: string
    currentStatus: SupplierStatus
    /**
     * ★★ ROLE-1 Batch 2a(Tim,Q8 / Q2):此前这里是一个 `canEdit` 布尔,而一个布尔答不了
     *   "这一步归谁" —— 批准、驳回、拉黑、恢复归 CFO(action.supplier_approve),其余归
     *   module.suppliers.edit。所以每一步自带它的码与答案:持有的按得下;不持有的
     *   【看得见、按不下、说出缺哪个码】(DBLOCK-1 的规矩,PermissionGate)。
     *   ALERT-1 那条丁类的理由照旧成立 —— 理由在按之前就看得见,只是现在是逐钮的。
     */
    moves: SupplierStatusMove[]
}) {
    const t = useTranslations()
    const [isPending, startTransition] = useTransition()


    function handleClick(targetStatus: SupplierStatus) {
        startTransition(async () => {
            const result = await changeSupplierStatus(id, targetStatus)
            if (result?.error) {
                showActionMessage({
                    subject: subject,
                    headline: t('common.actionMessage.headline.notStatusChanged'),
                    body: result.error,
                    detail: result.detail,
                })
            }
        })
    }

    const deniedCodes = [...new Set(moves.filter((m) => !m.allowed).map((m) => m.code))]

    return (
        <div className="border border-gray-300 rounded p-4 mb-6 bg-gray-50">
            <div className="flex items-center justify-between mb-3">
                <div>
                    <div className="text-xs text-[color:var(--brand-muted-text)] mb-1">
                        {t('suppliers.statusPanel.current')}
                    </div>
                    <div className="text-lg font-medium leading-6">
                        {t('suppliers.status.' + currentStatus)}
                        <span className="ml-2 text-xs text-gray-400">
                            ({currentStatus})
                        </span>
                    </div>
                </div>
            </div>

            {/* ★ 丁类:一步都走不了的时候,理由出现在面板上、在【动作之前】—— 并且说出
                缺的是哪一个码。每一枚钮自己也带着它的码(PermissionGate);这一行是给
                "整块都按不下"的人的一句总话。 */}
            {moves.length > 0 && deniedCodes.length > 0 && moves.every((m) => !m.allowed) && (
                <div className="flex flex-wrap items-center gap-2 mb-3">
                    <Refusal>{t('common.restricted')}</Refusal>
                    <p className="text-sm text-[color:var(--brand-text)]" data-status-panel-denied="1">
                        {deniedCodes.length === 1 && deniedCodes[0] === 'module.suppliers.edit'
                            ? t('suppliers.statusPanel.needsEditPermission')
                            : t('suppliers.statusPanel.needsPermission', { codes: deniedCodes.join(' · ') })}
                    </p>
                </div>
            )}
            {moves.length === 0 ? (
                <p className="text-sm text-[color:var(--brand-muted-text)]">
                    {t('suppliers.statusPanel.noActions')}
                </p>
            ) : (
                <div>
                    <div className="text-xs text-[color:var(--brand-muted-text)] mb-2">
                        {t('suppliers.statusPanel.availableChanges')}
                    </div>
                    <div className="flex flex-wrap gap-2">
                        {moves.map(({ to: target, code, allowed }) => {
                            const isDestructive = DESTRUCTIVE_TRANSITIONS.has(target)
                            const face = (
                                <>
                                    {isPending
                                        ? t('suppliers.statusPanel.processing')
                                        : t('suppliers.statusAction.' + target)}
                                    <span className="ml-1 text-xs text-gray-400">
                                        → {t('suppliers.status.' + target)}
                                    </span>
                                </>
                            )
                            if (!isDestructive) {
                                return (
                                    <PermissionGate key={target} code={code} allowed={allowed} inline>
                                        <Button variant="secondary" type="button" disabled={isPending}
                                                onClick={() => handleClick(target)}>
                                            {face}
                                        </Button>
                                    </PermissionGate>
                                )
                            }
                            // 那条消息原样取出来,再按它自己的换行拆成几行 —— 词不动,只是不再被压平。
                            const blocks = t('suppliers.statusPanel.changeConfirm', {
                                action: t('suppliers.statusAction.' + target),
                                current: t('suppliers.status.' + currentStatus),
                                next: t('suppliers.status.' + target),
                            }).split('\n\n')
                            return (
                                <PermissionGate key={target} code={code} allowed={allowed} inline>
                                <ConfirmButton
                                    subject={subject}
                                    title={blocks[0]}
                                    details={
                                        blocks.length > 1 ? (
                                            <div className="space-y-1 text-sm text-[color:var(--brand-muted-text)]">
                                                {blocks.slice(1).join('\n').split('\n').map((line, i) => (
                                                    <p key={i}>{line}</p>
                                                ))}
                                            </div>
                                        ) : undefined
                                    }
                                    confirmLabel={t('suppliers.statusAction.' + target)}
                                    tier="destructive"
                                    disabled={isPending}
                                    onConfirm={() => handleClick(target)}
                                    triggerVariant="destructive"
                                >
                                    {face}
                                </ConfirmButton>
                                </PermissionGate>
                            )
                        })}
                    </div>
                </div>
            )}
        </div>
    )
}
