'use client'

// ★ APR-7(Tim 2026-09-25):注销批次、加工回滚、作废销毁证书 —— 仓库提,CFO 批每一张,批准之前什么都不发生。
//   库存页顶上这一块把【在等的】申请逐张摆出来(看板 warehouse_request_pending 指到 #wr-<id>):
//   提了什么、谁提的、为什么;批次与数量、加工日;★ 回滚落在已锁期间时的那一句、会被一并作废的证书号
//   (grilling Q5 —— 批之前要看得见);金额(没有 data.view_prices 的读者看到「受限」,不是 0.00)。
//   然后 批准(当场生效)/ 驳回(要理由)/ 撤回。下面是最近了结的几张。
//
// 【谁能批,这里不预判】二级审批角色、而且不是提单人(按人认)—— 两条都只有数据库知道。
// 【权限码的那一半看得见、按不动、带理由】(DBLOCK-1):批 / 驳要 module.finance.view + data.view_prices;
// 撤回要那一种的码(注销 action.batch_write_off · 回滚 action.processing_rollback · 作废 action.issue_cod),
// 提单人本人除外。
import { useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { showActionMessage } from '@/app/components/ui/action-message'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { formatAmount } from '@/lib/format'
import {
    decideWarehouseRequest, withdrawWarehouseRequest, type WarehouseRequestKind,
} from '@/app/components/inventory/warehouseRequestActions'

export type WarehouseRequestView = {
    id: string
    kind: WarehouseRequestKind
    status: 'submitted' | 'approved' | 'rejected' | 'withdrawn'
    label: string
    subjectCode: string
    reason: string
    /** 没有 data.view_prices 的读者:null —— 画「受限」,不画 0.00 */
    amountBase: number | null
    materialText: string | null
    supplierText: string | null
    quantityText: string | null
    processDateText: string | null
    lockedPeriod: boolean
    outputs: string[]
    inputs: string[]
    codsVoided: string[]
    createdText: string
    raisedBy: string | null
    raisedByMe: boolean
    decidedBy: string | null
    decisionNotes: string | null
    withdrawReason: string | null
}

const KIND_CODE: Record<WarehouseRequestKind, string> = {
    write_off_inbound: 'action.batch_write_off',
    write_off_output: 'action.batch_write_off',
    rollback: 'action.processing_rollback',
    cod_void: 'action.issue_cod',
}

export default function WarehouseRequestsPanel({
    open, history, canSeeFinance, canViewPrices, kindCodesHeld, baseCurrency, lockedBeforeText,
}: {
    open: WarehouseRequestView[]
    history: WarehouseRequestView[]
    canSeeFinance: boolean
    canViewPrices: boolean
    /** 读者持有的那几个提单码(撤回用) */
    kindCodesHeld: string[]
    baseCurrency: string
    lockedBeforeText: string | null
}) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const notDone = t('common.actionMessage.headline.notDecided')

    function run(subject: string, fn: () => Promise<{ error?: string; detail?: string }>) {
        start(async () => {
            const r = await fn()
            if (r?.error) {
                showActionMessage({ subject, headline: notDone, body: r.error, detail: r.detail })
                return
            }
            router.refresh()
        })
    }

    const amountText = (v: number | null) => (v === null ? t('common.restricted') : formatAmount(v, baseCurrency))

    if (open.length === 0 && history.length === 0) return null

    return (
        <section className="space-y-3" aria-label={t('warehouseRequest.panelTitle')}>
            <h2>{t('warehouseRequest.panelTitle')}</h2>
            {open.length === 0 && (
                <p className="text-sm text-[color:var(--brand-muted-text)]">{t('warehouseRequest.noneWaiting')}</p>
            )}
            {open.map((r) => (
                <div
                    key={r.id}
                    id={`wr-${r.id}`}
                    className="rounded border border-amber-300 bg-amber-50 p-4 space-y-3 scroll-mt-24"
                    data-warehouse-request={r.label}
                >
                    <h3>{t('warehouseRequest.openTitle.' + r.kind)}</h3>
                    <dl className="text-sm grid grid-cols-[max-content_1fr] gap-x-4 gap-y-1">
                        <dt className="text-[color:var(--brand-muted-text)]">{t('warehouseRequest.request')}</dt>
                        <dd>
                            <span className="font-mono">{r.label}</span> · {r.createdText}
                            {r.raisedBy && <> · {t('warehouseRequest.raisedBy', { who: r.raisedBy })}</>}
                        </dd>
                        <dt className="text-[color:var(--brand-muted-text)]">{t('warehouseRequest.subject.' + r.kind)}</dt>
                        <dd className="font-mono">{r.subjectCode}</dd>
                        {r.materialText && (
                            <>
                                <dt className="text-[color:var(--brand-muted-text)]">{t('warehouseRequest.material')}</dt>
                                <dd>{r.materialText}</dd>
                            </>
                        )}
                        {r.supplierText && (
                            <>
                                <dt className="text-[color:var(--brand-muted-text)]">{t('warehouseRequest.supplier')}</dt>
                                <dd>{r.supplierText}</dd>
                            </>
                        )}
                        {r.quantityText && (
                            <>
                                <dt className="text-[color:var(--brand-muted-text)]">{t('warehouseRequest.quantity')}</dt>
                                <dd>{r.quantityText}</dd>
                            </>
                        )}
                        {r.processDateText && (
                            <>
                                <dt className="text-[color:var(--brand-muted-text)]">{t('warehouseRequest.processDate')}</dt>
                                <dd>{r.processDateText}</dd>
                            </>
                        )}
                        {r.outputs.length > 0 && (
                            <>
                                <dt className="text-[color:var(--brand-muted-text)]">{t('warehouseRequest.outputs')}</dt>
                                <dd className="font-mono break-words">{r.outputs.join(', ')}</dd>
                            </>
                        )}
                        {r.inputs.length > 0 && (
                            <>
                                <dt className="text-[color:var(--brand-muted-text)]">{t('warehouseRequest.inputs')}</dt>
                                <dd className="font-mono break-words">{r.inputs.join(', ')}</dd>
                            </>
                        )}
                        <dt className="text-[color:var(--brand-muted-text)]">{t('warehouseRequest.amount')}</dt>
                        <dd>{amountText(r.amountBase)}</dd>
                        <dt className="text-[color:var(--brand-muted-text)]">{t('warehouseRequest.reason')}</dt>
                        <dd className="whitespace-pre-line">{r.reason}</dd>
                    </dl>

                    {r.lockedPeriod && (
                        <p className="text-sm font-medium text-amber-900">
                            {t('warehouseRequest.lockedPeriod', { date: lockedBeforeText ?? '—' })}
                        </p>
                    )}
                    {r.codsVoided.length > 0 && (
                        <p className="text-sm font-medium text-red-700">
                            {t('warehouseRequest.codsVoided', { codes: r.codsVoided.join(', ') })}
                        </p>
                    )}
                    <p className="text-xs text-[color:var(--brand-text)]">{t('warehouseRequest.decideHint')}</p>

                    <PermissionGate code={canSeeFinance ? 'data.view_prices' : 'module.finance.view'}
                        allowed={canSeeFinance && canViewPrices}>
                        <div className="flex flex-wrap items-start gap-3">
                            <ConfirmButton
                                subject={r.label}
                                title={t('warehouseRequest.approveConfirm.' + r.kind)}
                                body={t('warehouseRequest.approveBody.' + r.kind)}
                                confirmLabel={t('warehouseRequest.approve')}
                                tier="destructive"
                                triggerVariant="default"
                                disabled={pending}
                                onConfirm={() => run(r.label, () => decideWarehouseRequest(r.id, true, ''))}
                            >
                                {pending ? t('common.saving') : t('warehouseRequest.approve')}
                            </ConfirmButton>
                            <ConfirmButton
                                subject={r.label}
                                title={t('warehouseRequest.rejectConfirm')}
                                body={t('warehouseRequest.rejectBody')}
                                confirmLabel={t('warehouseRequest.reject')}
                                tier="destructive"
                                triggerVariant="destructive"
                                reason={{ placeholder: t('warehouseRequest.rejectPlaceholder') }}
                                disabled={pending}
                                onConfirm={(reason) => run(r.label, () => decideWarehouseRequest(r.id, false, reason))}
                            >
                                {t('warehouseRequest.reject')}
                            </ConfirmButton>
                        </div>
                    </PermissionGate>

                    <PermissionGate code={KIND_CODE[r.kind]} allowed={r.raisedByMe || kindCodesHeld.includes(KIND_CODE[r.kind])}>
                        <ConfirmButton
                            subject={r.label}
                            title={t('warehouseRequest.withdrawConfirm')}
                            body={t('warehouseRequest.withdrawBody')}
                            confirmLabel={t('warehouseRequest.withdraw')}
                            tier="reversal"
                            triggerVariant="outline"
                            disabled={pending}
                            onConfirm={() => run(r.label, () => withdrawWarehouseRequest(r.id))}
                        >
                            {t('warehouseRequest.withdraw')}
                        </ConfirmButton>
                    </PermissionGate>
                </div>
            ))}

            {history.length > 0 && (
                <div>
                    <h3 className="mb-1">{t('warehouseRequest.history')}</h3>
                    <ul className="text-sm space-y-1">
                        {history.map((h) => (
                            <li key={h.id}>
                                <span className="font-mono">{h.label}</span> · {amountText(h.amountBase)} ·{' '}
                                {t('warehouseRequest.status.' + h.status)} · {h.createdText}
                                {h.decidedBy && <> · {h.decidedBy}</>}
                                {(h.decisionNotes || h.withdrawReason) && (
                                    <span className="text-[color:var(--brand-muted-text)] whitespace-pre-line">
                                        {' '}— {h.decisionNotes ?? h.withdrawReason}
                                    </span>
                                )}
                            </li>
                        ))}
                    </ul>
                </div>
            )}
        </section>
    )
}
