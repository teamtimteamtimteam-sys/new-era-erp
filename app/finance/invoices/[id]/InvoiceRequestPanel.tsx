'use client'

// ★ APR-5a(Tim 2026-09-25):贷项通知与作废发票要 CFO 批准。
//   「开贷项通知」与「作废」两个钮都只【提一张申请】;这一块把那张在等的申请摆出来,
//   并给 批准(当场过账,按冻结的日期)/ 驳回(要理由)/ 撤回 三个动作,以及这张发票上申请的历史。
//
// 【谁能批,这里不预判】二级审批角色、而且不是提单人(按人认)—— 两条都只有数据库知道
// (decide_invoice_request → 二级审批人 + forbid_self_approval)。与 ReceiptPriceRequestPanel 同一条:
// 钮亮着,拒绝由库出,就地说成人话。
// 【权限码的那一半看得见、按不动、带理由】(DBLOCK-1)—— 批 / 驳要 data.view_prices(能进这一页的人
// 已经持 module.finance.view,那是门的另一半);撤回要 module.finance.edit,提单人本人除外
// (同一个账号这里认得出;同一个人的另一个账号由库认)。
import { useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { showActionMessage } from '@/app/components/ui/action-message'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { formatAmount } from '@/lib/format'
import { decideInvoiceRequest, withdrawInvoiceRequest } from './actions'

export type InvoiceRequestView = {
    id: string
    label: string
    kind: 'credit_note' | 'void'
    status: 'submitted' | 'approved' | 'rejected' | 'withdrawn'
    docDateText: string | null
    reason: string
    lineCount: number
    amountBase: number
    decisionNotes: string | null
    withdrawReason: string | null
    createdText: string
    raisedByMe: boolean
}

export default function InvoiceRequestPanel({
    invoiceId,
    subject,
    open,
    history,
    canDecide,
    canWithdraw,
    baseCurrency,
}: {
    invoiceId: string
    /** CONFIRM-1:动的是【哪一张发票】。 */
    subject: string
    open: InvoiceRequestView | null
    history: InvoiceRequestView[]
    canDecide: boolean
    canWithdraw: boolean
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

    if (!open && history.length === 0) return null

    return (
        <div className="mb-4 space-y-3" aria-label={t('finance.invoiceRequest.title')}>
            {open && (
                <div className="rounded border border-amber-300 bg-amber-50 p-4 space-y-3" data-invoice-request={open.label}>
                    <h3>{t('finance.invoiceRequest.openTitle.' + open.kind)}</h3>
                    <dl className="text-sm grid grid-cols-[max-content_1fr] gap-x-4 gap-y-1">
                        <dt className="text-[color:var(--brand-muted-text)]">{t('finance.invoiceRequest.request')}</dt>
                        <dd>
                            <span className="font-mono">{open.label}</span> · {t('finance.invoiceRequest.kind.' + open.kind)} · {open.createdText}
                        </dd>
                        <dt className="text-[color:var(--brand-muted-text)]">{t('finance.invoiceRequest.amount')}</dt>
                        <dd>{formatAmount(open.amountBase, baseCurrency)}</dd>
                        <dt className="text-[color:var(--brand-muted-text)]">{t('finance.invoiceRequest.docDate.' + open.kind)}</dt>
                        <dd>{open.docDateText ?? t('finance.invoiceRequest.noEntry')}</dd>
                        {open.kind === 'credit_note' && (
                            <>
                                <dt className="text-[color:var(--brand-muted-text)]">{t('finance.invoiceRequest.lines')}</dt>
                                <dd>{open.lineCount}</dd>
                            </>
                        )}
                        <dt className="text-[color:var(--brand-muted-text)]">{t('finance.invoiceRequest.reason')}</dt>
                        <dd className="whitespace-pre-line">{open.reason}</dd>
                    </dl>
                    <p className="text-xs text-[color:var(--brand-text)]">{t('finance.invoiceRequest.decideHint')}</p>

                    <PermissionGate code="data.view_prices" allowed={canDecide}>
                        <div className="flex flex-wrap items-start gap-3">
                            <ConfirmButton
                                subject={`${subject} · ${open.label}`}
                                title={t('finance.invoiceRequest.approveConfirm.' + open.kind)}
                                body={t('finance.invoiceRequest.approveBody.' + open.kind)}
                                confirmLabel={t('finance.invoiceRequest.approve')}
                                tier="default"
                                triggerVariant="default"
                                disabled={pending}
                                onConfirm={() => run(() => decideInvoiceRequest(invoiceId, open.id, true, ''))}
                            >
                                {pending ? t('common.saving') : t('finance.invoiceRequest.approve')}
                            </ConfirmButton>
                            <ConfirmButton
                                subject={`${subject} · ${open.label}`}
                                title={t('finance.invoiceRequest.rejectConfirm')}
                                body={t('finance.invoiceRequest.rejectBody')}
                                confirmLabel={t('finance.invoiceRequest.reject')}
                                tier="destructive"
                                triggerVariant="destructive"
                                reason={{ placeholder: t('finance.invoiceRequest.rejectPlaceholder') }}
                                disabled={pending}
                                onConfirm={(reason) => run(() => decideInvoiceRequest(invoiceId, open.id, false, reason))}
                            >
                                {t('finance.invoiceRequest.reject')}
                            </ConfirmButton>
                        </div>
                    </PermissionGate>

                    <PermissionGate code="module.finance.edit" allowed={canWithdraw || open.raisedByMe}>
                        <ConfirmButton
                            subject={`${subject} · ${open.label}`}
                            title={t('finance.invoiceRequest.withdrawConfirm')}
                            body={t('finance.invoiceRequest.withdrawBody')}
                            confirmLabel={t('finance.invoiceRequest.withdraw')}
                            tier="reversal"
                            triggerVariant="outline"
                            disabled={pending}
                            onConfirm={() => run(() => withdrawInvoiceRequest(invoiceId, open.id, ''))}
                        >
                            {t('finance.invoiceRequest.withdraw')}
                        </ConfirmButton>
                    </PermissionGate>
                </div>
            )}

            {history.length > 0 && (
                <div>
                    <h3 className="mb-1">{t('finance.invoiceRequest.history')}</h3>
                    <ul className="text-sm space-y-1">
                        {history.map((h) => (
                            <li key={h.id}>
                                <span className="font-mono">{h.label}</span> · {t('finance.invoiceRequest.kind.' + h.kind)} ·{' '}
                                {formatAmount(h.amountBase, baseCurrency)} · {t('finance.invoiceRequest.status.' + h.status)} · {h.createdText}
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
