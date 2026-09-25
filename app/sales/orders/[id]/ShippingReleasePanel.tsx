'use client'

// ★ APR-5b(Tim 2026-09-25):订单页上的【发货放行】—— 提(cco)、批 / 驳(CFO)、撤回、历史。
//
// 【谁能批,这里不预判】二级审批角色、而且不是提单人(按人认)—— 两条都只有数据库知道
// (decide_shipping_release → 二级审批人 + forbid_self_approval)。与 InvoiceRequestPanel 同一条:
// 钮亮着,拒绝由库出,就地说成人话。
// 【权限码的那一半看得见、按不动、带理由】(DBLOCK-1)—— 提要 action.request_shipping_release;
// 批 / 驳要 data.view_prices(能进这一页的人已经持 module.sales.view,那是门的另一半);撤回要提单码,
// 提单人本人除外(同一个账号这里认得出;同一个人的另一个账号由库认)。
// 【CFO 决定时看得见的那一块】客户的额度、冻结、敞口,这张发票收了多少,逐行毛利 —— 没有成本的
// 批次写「未计成本」,永不写 0(5b Q10)。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { showActionMessage } from '@/app/components/ui/action-message'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { Button } from '@/app/components/ui/button'
import { formatAmount } from '@/lib/format'
import { submitShippingRelease, decideShippingRelease, withdrawShippingRelease } from '../actions'

export type ReleaseView = {
    id: string
    label: string
    status: 'submitted' | 'approved' | 'rejected' | 'withdrawn'
    amountBase: number
    createdText: string
    decidedText: string | null
    note: string | null
    lines: { lineNo: number; lapsed: boolean }[]
    raisedByMe: boolean
}
export type ReleaseCandidate = { invoiceLineId: string; lineNo: number; label: string }
export type ReleaseContext = {
    customer: {
        code: string; legal_name: string; credit_limit_base: number | null; credit_hold: boolean
        exposure_base: number | null; headroom_base: number | null
    }
    invoices: { code: string; status: string; total_base: number; open_base: number | null; paid: boolean }[]
    lines: {
        line_no: number; material_code: string | null; quantity: number; invoice_voided: boolean
        invoiced_base: number | null; costed: boolean; cost_base: number | null
        margin_base: number | null; margin_pct: number | null
    }[]
}

export default function ShippingReleasePanel({
    orderId,
    orderCode,
    shippable,
    candidates,
    open,
    history,
    context,
    canRaise,
    canDecide,
    canWithdraw,
    baseCurrency,
}: {
    orderId: string
    orderCode: string
    shippable: boolean
    /** null = 这个读者读不到发票行(module.finance.view),提交交给库的默认 */
    candidates: ReleaseCandidate[] | null
    open: ReleaseView | null
    history: ReleaseView[]
    context: ReleaseContext | null
    canRaise: boolean
    canDecide: boolean
    canWithdraw: boolean
    baseCurrency: string
}) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [picked, setPicked] = useState<Record<string, boolean>>({})
    const isPicked = (id: string) => picked[id] ?? true   // 默认全选(5b Q2)

    function run(headline: string, subject: string, fn: () => Promise<{ error?: string }>) {
        start(async () => {
            const r = await fn()
            if (r?.error) {
                showActionMessage({ subject, headline, body: r.error })
                return
            }
            router.refresh()
        })
    }

    const chosen = candidates === null ? null : candidates.filter((c) => isPicked(c.invoiceLineId))
    const raiseBlocked =
        !shippable ? t('sales.release.blockedNotShippable')
        : open ? t('sales.release.blockedOpen', { label: open.label })
        : candidates !== null && candidates.length === 0 ? t('sales.release.blockedNoCandidates')
        : chosen !== null && chosen.length === 0 ? t('sales.release.blockedNonePicked')
        : null

    const money = (n: number | null | undefined) =>
        n === null || n === undefined ? t('sales.release.context.notCosted') : formatAmount(n, baseCurrency)

    return (
        <section className="mt-8" aria-label={t('sales.release.title')}>
            <h2 className="mb-1">{t('sales.release.title')}</h2>
            <p className="text-xs text-[color:var(--brand-muted-text)] mb-3">{t('sales.release.note')}</p>

            {open && (
                <div className="rounded border border-amber-300 bg-amber-50 p-4 space-y-3 mb-4" data-shipping-release={open.label}>
                    <h3>{t('sales.release.openTitle')}</h3>
                    <dl className="text-sm grid grid-cols-[max-content_1fr] gap-x-4 gap-y-1">
                        <dt className="text-[color:var(--brand-muted-text)]">{t('sales.release.request')}</dt>
                        <dd><span className="font-mono">{open.label}</span> · {open.createdText}</dd>
                        <dt className="text-[color:var(--brand-muted-text)]">{t('sales.release.lines')}</dt>
                        <dd>{open.lines.map((l) => `#${l.lineNo}`).join(' · ')}</dd>
                        <dt className="text-[color:var(--brand-muted-text)]">{t('sales.release.amount')}</dt>
                        <dd>{formatAmount(open.amountBase, baseCurrency)}</dd>
                    </dl>

                    {context && (
                        <div className="text-sm space-y-2 border-t border-amber-200 pt-3">
                            <h4 className="font-medium">{t('sales.release.context.title')}</h4>
                            <dl className="grid grid-cols-[max-content_1fr] gap-x-4 gap-y-1">
                                <dt className="text-[color:var(--brand-muted-text)]">{t('sales.release.context.customer')}</dt>
                                <dd>{context.customer.code} — {context.customer.legal_name}</dd>
                                <dt className="text-[color:var(--brand-muted-text)]">{t('sales.release.context.creditLimit')}</dt>
                                <dd>{context.customer.credit_limit_base === null
                                    ? t('sales.release.context.noLimit')
                                    : formatAmount(context.customer.credit_limit_base, baseCurrency)}</dd>
                                <dt className="text-[color:var(--brand-muted-text)]">{t('sales.release.context.hold')}</dt>
                                <dd className={context.customer.credit_hold ? 'text-red-700 font-medium' : ''}>
                                    {context.customer.credit_hold ? t('sales.release.context.onHold') : t('sales.release.context.notOnHold')}
                                </dd>
                                <dt className="text-[color:var(--brand-muted-text)]">{t('sales.release.context.exposure')}</dt>
                                <dd>{money(context.customer.exposure_base)}</dd>
                                {context.customer.headroom_base !== null && (
                                    <>
                                        <dt className="text-[color:var(--brand-muted-text)]">{t('sales.release.context.headroom')}</dt>
                                        <dd>{formatAmount(context.customer.headroom_base, baseCurrency)}</dd>
                                    </>
                                )}
                            </dl>
                            <ul className="space-y-1">
                                {context.invoices.map((i) => (
                                    <li key={i.code}>
                                        <span className="font-mono">{i.code}</span> · {formatAmount(i.total_base, baseCurrency)} ·{' '}
                                        {i.paid
                                            ? t('sales.release.context.paid')
                                            : t('sales.release.context.open', { amount: formatAmount(i.open_base ?? 0, baseCurrency) })}
                                    </li>
                                ))}
                            </ul>
                            <ul className="space-y-1">
                                {context.lines.map((l) => (
                                    <li key={l.line_no}>
                                        #{l.line_no} {l.material_code ?? ''} · {l.quantity}
                                        {l.invoice_voided && <span className="text-red-700"> · {t('sales.release.context.voided')}</span>}
                                        {' — '}{t('sales.release.context.lineMoney', {
                                            invoiced: money(l.invoiced_base),
                                            cost: l.costed ? money(l.cost_base) : t('sales.release.context.notCosted'),
                                            margin: l.costed && l.margin_base !== null
                                                ? `${formatAmount(l.margin_base, baseCurrency)}${l.margin_pct !== null ? ` (${l.margin_pct}%)` : ''}`
                                                : t('sales.release.context.notCosted'),
                                        })}
                                    </li>
                                ))}
                            </ul>
                        </div>
                    )}

                    <p className="text-xs text-[color:var(--brand-text)]">{t('sales.release.decideHint')}</p>

                    <PermissionGate code="data.view_prices" allowed={canDecide}>
                        <div className="flex flex-wrap items-start gap-3">
                            <ConfirmButton
                                subject={`${orderCode} · ${open.label}`}
                                title={t('sales.release.approveConfirm')}
                                body={t('sales.release.approveBody')}
                                confirmLabel={t('sales.release.approve')}
                                tier="default"
                                triggerVariant="default"
                                disabled={pending}
                                onConfirm={() => run(t('common.actionMessage.headline.notReleaseDecided'), `${orderCode} · ${open.label}`,
                                    () => decideShippingRelease(orderId, open.id, true, ''))}
                            >
                                {pending ? t('common.saving') : t('sales.release.approve')}
                            </ConfirmButton>
                            <ConfirmButton
                                subject={`${orderCode} · ${open.label}`}
                                title={t('sales.release.rejectConfirm')}
                                body={t('sales.release.rejectBody')}
                                confirmLabel={t('sales.release.reject')}
                                tier="destructive"
                                triggerVariant="destructive"
                                reason={{ placeholder: t('sales.release.rejectPlaceholder') }}
                                disabled={pending}
                                onConfirm={(reason) => run(t('common.actionMessage.headline.notReleaseDecided'), `${orderCode} · ${open.label}`,
                                    () => decideShippingRelease(orderId, open.id, false, reason))}
                            >
                                {t('sales.release.reject')}
                            </ConfirmButton>
                        </div>
                    </PermissionGate>

                    <PermissionGate code="action.request_shipping_release" allowed={canWithdraw || open.raisedByMe}>
                        <ConfirmButton
                            subject={`${orderCode} · ${open.label}`}
                            title={t('sales.release.withdrawConfirm')}
                            body={t('sales.release.withdrawBody')}
                            confirmLabel={t('sales.release.withdraw')}
                            tier="reversal"
                            triggerVariant="outline"
                            disabled={pending}
                            onConfirm={() => run(t('common.actionMessage.headline.notReleaseWithdrawn'), `${orderCode} · ${open.label}`,
                                () => withdrawShippingRelease(orderId, open.id, ''))}
                        >
                            {t('sales.release.withdraw')}
                        </ConfirmButton>
                    </PermissionGate>
                </div>
            )}

            <div className="border border-gray-300 rounded p-3 mb-4">
                <h3 className="mb-2">{t('sales.release.raiseTitle')}</h3>
                {candidates === null ? (
                    <p className="text-sm text-[color:var(--brand-muted-text)] mb-2">{t('sales.release.candidatesRestricted')}</p>
                ) : candidates.length > 0 && (
                    <fieldset className="mb-2 space-y-1">
                        <legend className="text-sm text-[color:var(--brand-muted-text)] mb-1">{t('sales.release.pickLines')}</legend>
                        {candidates.map((c) => (
                            <label key={c.invoiceLineId} className="flex items-center gap-2 text-sm">
                                <input type="checkbox" checked={isPicked(c.invoiceLineId)}
                                       onChange={(e) => setPicked((s) => ({ ...s, [c.invoiceLineId]: e.target.checked }))} />
                                {c.label}
                            </label>
                        ))}
                    </fieldset>
                )}
                <PermissionGate code="action.request_shipping_release" allowed={canRaise}>
                    <Button type="button" variant="secondary" disabled={pending || raiseBlocked !== null}
                            onClick={() => run(t('common.actionMessage.headline.notReleaseRaised'), orderCode,
                                () => submitShippingRelease(orderId, chosen === null ? null : chosen.map((c) => c.invoiceLineId)))}>
                        {pending ? t('common.saving') : t('sales.release.raiseAction')}
                    </Button>
                </PermissionGate>
                <p className="text-xs text-[color:var(--brand-muted-text)] mt-1">{raiseBlocked ?? t('sales.release.raiseConsequence')}</p>
            </div>

            {history.length > 0 && (
                <div>
                    <h3 className="mb-1">{t('sales.release.history')}</h3>
                    <ul className="text-sm space-y-1">
                        {history.map((h) => (
                            <li key={h.id}>
                                <span className="font-mono">{h.label}</span> · {t('sales.release.status.' + h.status)} ·{' '}
                                {h.lines.map((l) => (
                                    <span key={l.lineNo} className={l.lapsed ? 'line-through text-[color:var(--brand-muted-text)]' : ''}>
                                        #{l.lineNo}{' '}
                                    </span>
                                ))}
                                · {h.decidedText ?? h.createdText}
                                {h.lines.some((l) => l.lapsed) && (
                                    <span className="text-[color:var(--brand-muted-text)]"> — {t('sales.release.lapsedNote')}</span>
                                )}
                                {h.note && <span className="text-[color:var(--brand-muted-text)] whitespace-pre-line"> — {h.note}</span>}
                            </li>
                        ))}
                    </ul>
                </div>
            )}
        </section>
    )
}
