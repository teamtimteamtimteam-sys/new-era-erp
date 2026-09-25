'use client'

// ★ ROLE-1 Batch 4b(Tim 2026-09-25):一个收货价格只有 CFO 批了才进账。
//   定价面板 · 按承诺条款改价 · 收货台带价 · 应用化验,四扇门都只【提一张申请】;这一块把那张在等的
//   申请摆出来,并给 批准(当场过账)/ 驳回(要理由)/ 撤回 三个动作。
//
// 【谁能批,这里不预判】二级审批角色、而且不是提单人(按人认)—— 两条都只有数据库知道
// (decide_receipt_price_request → require_approver_for(2) + forbid_self_approval)。与工资申请的
// PayrollRequestPanel 同一条:钮亮着,拒绝由库出,就地说成人话。
// 【权限码的那一半看得见、按不动、带理由】(DBLOCK-1)—— 批 / 驳要 data.view_purchase_prices
// (能进这一页的人已经持 module.inbound.view,那是门的另一半);撤回要 action.price_receipts,
// 提单人本人除外(同一个账号这里认得出;同一个人的另一个账号由库认)。
import { useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { showActionMessage } from '@/app/components/ui/action-message'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { formatAmount, formatUnitCost } from '@/lib/format'
import { decideReceiptPriceRequest, withdrawReceiptPriceRequest } from './pricingActions'

export type ReceiptPriceRequestView = {
    id: string
    label: string
    source: 'manual' | 'committed_terms' | 'desk' | 'assay'
    status: 'submitted' | 'approved' | 'rejected' | 'withdrawn'
    unitPriceCcy: number
    currency: string
    oldUnitPrice: number | null
    amountBase: number
    notes: string | null
    decisionNotes: string | null
    withdrawReason: string | null
    assayCode: string | null
    createdText: string
    raisedByMe: boolean
}

export default function ReceiptPriceRequestPanel({
    batchId,
    subject,
    open,
    history,
    canDecide,
    canWithdraw,
    rejectedAssayCode,
    baseCurrency,
}: {
    batchId: string
    /** CONFIRM-1:动的是【哪一张收货】。 */
    subject: string
    open: ReceiptPriceRequestView | null
    history: ReceiptPriceRequestView[]
    canDecide: boolean
    canWithdraw: boolean
    /** Tim 的 Q8:最近一张申请来自一份仍在生效的化验、而它被驳回了 —— 那份化验的编号。 */
    rejectedAssayCode: string | null
    baseCurrency: string
}) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const notDone = t('common.actionMessage.headline.notDecided')

    function run(fn: () => Promise<{ error?: string }>) {
        start(async () => {
            const r = await fn()
            if (r?.error) {
                showActionMessage({ subject, headline: notDone, body: r.error })
                return
            }
            router.refresh()
        })
    }

    if (!open && history.length === 0 && !rejectedAssayCode) return null

    return (
        <div className="mb-4 space-y-3" aria-label={t('inbound.priceRequest.title')}>
            {rejectedAssayCode && !open && (
                <p className="text-sm border-l-4 border-amber-500 pl-3" data-state-note="assay-price-rejected">
                    {t('inbound.priceRequest.assayRejected', { assay: rejectedAssayCode })}
                </p>
            )}

            {open && (
                <div className="rounded border border-amber-300 bg-amber-50 p-4 space-y-3" data-price-request={open.label}>
                    <h3>{t('inbound.priceRequest.openTitle')}</h3>
                    <dl className="text-sm grid grid-cols-[max-content_1fr] gap-x-4 gap-y-1">
                        <dt className="text-[color:var(--brand-muted-text)]">{t('inbound.priceRequest.request')}</dt>
                        <dd>
                            <span className="font-mono">{open.label}</span> · {t('inbound.priceRequest.source.' + open.source)}
                            {open.assayCode ? ` ${open.assayCode}` : ''} · {open.createdText}
                        </dd>
                        <dt className="text-[color:var(--brand-muted-text)]">{t('inbound.priceRequest.price')}</dt>
                        <dd>{formatUnitCost(open.unitPriceCcy)} {open.currency}</dd>
                        <dt className="text-[color:var(--brand-muted-text)]">{t('inbound.priceRequest.current')}</dt>
                        <dd>{open.oldUnitPrice === null ? t('inbound.pricing.notSet') : `${formatUnitCost(open.oldUnitPrice)} ${baseCurrency}`}</dd>
                        <dt className="text-[color:var(--brand-muted-text)]">{t('inbound.priceRequest.change')}</dt>
                        <dd>{formatAmount(open.amountBase, baseCurrency)}</dd>
                        {open.notes && (
                            <>
                                <dt className="text-[color:var(--brand-muted-text)]">{t('inbound.priceRequest.notes')}</dt>
                                <dd className="whitespace-pre-line">{open.notes}</dd>
                            </>
                        )}
                    </dl>
                    <p className="text-xs text-[color:var(--brand-text)]">{t('inbound.priceRequest.decideHint')}</p>

                    <PermissionGate code="data.view_purchase_prices" allowed={canDecide}>
                        <div className="flex flex-wrap items-start gap-3">
                            <ConfirmButton
                                subject={`${subject} · ${open.label}`}
                                title={t('inbound.priceRequest.approveConfirm')}
                                body={t('inbound.priceRequest.approveBody')}
                                confirmLabel={t('inbound.priceRequest.approve')}
                                tier="default"
                                triggerVariant="default"
                                disabled={pending}
                                onConfirm={() => run(() => decideReceiptPriceRequest(batchId, open.id, true, ''))}
                            >
                                {pending ? t('common.saving') : t('inbound.priceRequest.approve')}
                            </ConfirmButton>
                            <ConfirmButton
                                subject={`${subject} · ${open.label}`}
                                title={t('inbound.priceRequest.rejectConfirm')}
                                body={t('inbound.priceRequest.rejectBody')}
                                confirmLabel={t('inbound.priceRequest.reject')}
                                tier="destructive"
                                triggerVariant="destructive"
                                reason={{ placeholder: t('inbound.priceRequest.rejectPlaceholder') }}
                                disabled={pending}
                                onConfirm={(reason) => run(() => decideReceiptPriceRequest(batchId, open.id, false, reason))}
                            >
                                {t('inbound.priceRequest.reject')}
                            </ConfirmButton>
                        </div>
                    </PermissionGate>

                    <PermissionGate code="action.price_receipts" allowed={canWithdraw || open.raisedByMe}>
                        <ConfirmButton
                            subject={`${subject} · ${open.label}`}
                            title={t('inbound.priceRequest.withdrawConfirm')}
                            body={t('inbound.priceRequest.withdrawBody')}
                            confirmLabel={t('inbound.priceRequest.withdraw')}
                            tier="reversal"
                            triggerVariant="outline"
                            disabled={pending}
                            onConfirm={() => run(() => withdrawReceiptPriceRequest(batchId, open.id, ''))}
                        >
                            {t('inbound.priceRequest.withdraw')}
                        </ConfirmButton>
                    </PermissionGate>
                </div>
            )}

            {history.length > 0 && (
                <div>
                    <h3 className="mb-1">{t('inbound.priceRequest.history')}</h3>
                    <ul className="text-sm space-y-1">
                        {history.map((h) => (
                            <li key={h.id}>
                                <span className="font-mono">{h.label}</span> · {t('inbound.priceRequest.source.' + h.source)}
                                {h.assayCode ? ` ${h.assayCode}` : ''} · {formatUnitCost(h.unitPriceCcy)} {h.currency} ·{' '}
                                {t('inbound.priceRequest.status.' + h.status)} · {h.createdText}
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
        </div>
    )
}
