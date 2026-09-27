'use client'

// app/finance/assets/AssetDisposalRequestsPanel.tsx
// ★ APR-9(Tim 2026-09-27,grilling Q7 · Q8 · Q10):固定资产处置 —— 财务提,CFO 批每一张,批准当场处置。
//   资产页顶上这一块把【在等的】处置申请逐张摆出来(看板 asset_disposal_pending 指到 #adr-<id>):
//   哪一台、谁提的、为什么;收款与银行科目(提交时冻结);★ 提交时试跑出来的那一组(成本、累计折旧、损益)——
//   而处置日是【批准那一天】,累计折旧与损益按批准那一刻重算,所以这一组是估算,批准后在下面并排给出真的那一组。
//   卡在等待中变了(current_matches = false)→ 先说出来:批准会被 ASSET_CHANGED_SINCE_REQUEST 拒。
//   然后 批准(当场处置)/ 驳回(要理由)/ 撤回。下面是最近了结的几张(估算 → 实际)。
//
// 【谁能批,这里不预判】二级审批角色、而且不是提单人(按人认)—— 两条都只有数据库知道。
// 【权限码的那一半看得见、按不动、带理由】(DBLOCK-1):批 / 驳要 module.finance.view + data.view_prices;
// 撤回要 module.finance.edit,提单人本人除外。
import { useTransition } from 'react'
import { useRouter } from 'next/navigation'
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { showActionMessage } from '@/app/components/ui/action-message'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { formatAmount } from '@/lib/format'
import { decideDisposalRequest, withdrawDisposalRequest } from './disposalRequestActions'

export type DisposalFigures = {
    dateText: string | null
    costRelieved: number | null
    accumRelieved: number | null
    proceeds: number | null
    gainLoss: number | null
}

export type DisposalRequestView = {
    id: string
    status: 'submitted' | 'approved' | 'rejected' | 'withdrawn'
    label: string
    assetCode: string
    assetDescription: string
    proceeds: number
    bankAccount: string | null
    reason: string
    estimate: DisposalFigures
    result: DisposalFigures | null
    resultEntryId: string | null
    resultEntryCode: string | null
    currentMatches: boolean
    createdText: string
    raisedBy: string | null
    raisedByMe: boolean
    decidedBy: string | null
    decisionNotes: string | null
    withdrawReason: string | null
}

export default function AssetDisposalRequestsPanel({
    open, history, canDecide, holdsDecideView, canEdit, baseCurrency,
}: {
    open: DisposalRequestView[]
    history: DisposalRequestView[]
    /** module.finance.view 且 data.view_prices(决定的门;谁是二级、谁是提单人由库裁) */
    canDecide: boolean
    /** 读者持 module.finance.view —— 缺的是哪一个码,用它点名 */
    holdsDecideView: boolean
    /** module.finance.edit —— 撤回(提单人本人除外) */
    canEdit: boolean
    baseCurrency: string
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

    const money = (v: number | null) => (v === null ? '—' : formatAmount(v, baseCurrency))
    const gain = (v: number | null) => v === null ? '—'
        : v > 0 ? t('assetDisposal.gain', { amount: money(v) })
        : v < 0 ? t('assetDisposal.loss', { amount: money(-v) })
        : money(0)

    function Figures({ f, title }: { f: DisposalFigures; title: string }) {
        return (
            <div>
                <p className="text-xs font-medium text-[color:var(--brand-muted-text)] mb-1">{title}</p>
                <dl className="text-sm grid grid-cols-[max-content_1fr] gap-x-4 gap-y-0.5">
                    <dt className="text-[color:var(--brand-muted-text)]">{t('assetDisposal.date')}</dt>
                    <dd>{f.dateText ?? '—'}</dd>
                    <dt className="text-[color:var(--brand-muted-text)]">{t('assetDisposal.costRelieved')}</dt>
                    <dd className="tabular-nums">{money(f.costRelieved)}</dd>
                    <dt className="text-[color:var(--brand-muted-text)]">{t('assetDisposal.accumRelieved')}</dt>
                    <dd className="tabular-nums">{money(f.accumRelieved)}</dd>
                    <dt className="text-[color:var(--brand-muted-text)]">{t('assetDisposal.proceeds')}</dt>
                    <dd className="tabular-nums">{money(f.proceeds)}</dd>
                    <dt className="text-[color:var(--brand-muted-text)]">{t('assetDisposal.gainLoss')}</dt>
                    <dd className="tabular-nums">{gain(f.gainLoss)}</dd>
                </dl>
            </div>
        )
    }

    if (open.length === 0 && history.length === 0) return null

    return (
        <section className="mb-8 space-y-3" aria-label={t('assetDisposal.panelTitle')}>
            <h2>{t('assetDisposal.panelTitle')}</h2>
            {open.length === 0 && (
                <p className="text-sm text-[color:var(--brand-muted-text)]">{t('assetDisposal.noneWaiting')}</p>
            )}
            {open.map((r) => (
                <div
                    key={r.id}
                    id={`adr-${r.id}`}
                    className="rounded border border-amber-300 bg-amber-50 p-4 space-y-3 scroll-mt-24"
                    data-asset-disposal-request={r.label}
                >
                    <h3>{t('assetDisposal.openTitle')}</h3>
                    <dl className="text-sm grid grid-cols-[max-content_1fr] gap-x-4 gap-y-1">
                        <dt className="text-[color:var(--brand-muted-text)]">{t('assetDisposal.request')}</dt>
                        <dd>
                            <span className="font-mono">{r.label}</span> · {r.createdText}
                            {r.raisedBy && <> · {t('assetDisposal.raisedBy', { who: r.raisedBy })}</>}
                        </dd>
                        <dt className="text-[color:var(--brand-muted-text)]">{t('assetDisposal.asset')}</dt>
                        <dd><span className="font-mono">{r.assetCode}</span> · {r.assetDescription}</dd>
                        <dt className="text-[color:var(--brand-muted-text)]">{t('assetDisposal.proceeds')}</dt>
                        <dd className="tabular-nums">
                            {money(r.proceeds)}
                            {r.bankAccount && <> · {t('assetDisposal.intoBank', { account: r.bankAccount })}</>}
                        </dd>
                        <dt className="text-[color:var(--brand-muted-text)]">{t('assetDisposal.reason')}</dt>
                        <dd className="whitespace-pre-line">{r.reason}</dd>
                    </dl>
                    <Figures f={r.estimate} title={t('assetDisposal.estimateTitle')} />
                    {!r.currentMatches && (
                        <p className="text-sm font-medium text-red-700">{t('assetDisposal.changedSince')}</p>
                    )}
                    <p className="text-xs text-[color:var(--brand-text)]">{t('assetDisposal.decideHint')}</p>

                    <PermissionGate code={holdsDecideView ? 'data.view_prices' : 'module.finance.view'}
                        allowed={canDecide}>
                        <div className="flex flex-wrap items-start gap-3">
                            <ConfirmButton
                                subject={r.label}
                                title={t('assetDisposal.approveConfirm')}
                                body={t('assetDisposal.approveBody', { code: r.assetCode })}
                                confirmLabel={t('assetDisposal.approve')}
                                tier="destructive"
                                triggerVariant="default"
                                disabled={pending}
                                onConfirm={() => run(r.label, () => decideDisposalRequest(r.id, true, ''))}
                            >
                                {pending ? t('common.saving') : t('assetDisposal.approve')}
                            </ConfirmButton>
                            <ConfirmButton
                                subject={r.label}
                                title={t('assetDisposal.rejectConfirm')}
                                body={t('assetDisposal.rejectBody')}
                                confirmLabel={t('assetDisposal.reject')}
                                tier="destructive"
                                triggerVariant="destructive"
                                reason={{ placeholder: t('assetDisposal.rejectPlaceholder') }}
                                disabled={pending}
                                onConfirm={(why) => run(r.label, () => decideDisposalRequest(r.id, false, why))}
                            >
                                {t('assetDisposal.reject')}
                            </ConfirmButton>
                        </div>
                    </PermissionGate>

                    <PermissionGate code="module.finance.edit" allowed={r.raisedByMe || canEdit}>
                        <ConfirmButton
                            subject={r.label}
                            title={t('assetDisposal.withdrawConfirm')}
                            body={t('assetDisposal.withdrawBody')}
                            confirmLabel={t('assetDisposal.withdraw')}
                            tier="reversal"
                            triggerVariant="outline"
                            disabled={pending}
                            onConfirm={() => run(r.label, () => withdrawDisposalRequest(r.id))}
                        >
                            {t('assetDisposal.withdraw')}
                        </ConfirmButton>
                    </PermissionGate>
                </div>
            ))}

            {history.length > 0 && (
                <div>
                    <h3 className="mb-1">{t('assetDisposal.history')}</h3>
                    <ul className="text-sm space-y-2">
                        {history.map((h) => (
                            <li key={h.id}>
                                <span className="font-mono">{h.label}</span> · {t('assetDisposal.status.' + h.status)} ·{' '}
                                {h.createdText}
                                {h.decidedBy && <> · {h.decidedBy}</>}
                                {h.resultEntryId && h.resultEntryCode && (
                                    <> · <Link href={`/finance/journal/${h.resultEntryId}`} className="underline">{h.resultEntryCode}</Link></>
                                )}
                                {(h.decisionNotes || h.withdrawReason) && (
                                    <span className="text-[color:var(--brand-muted-text)] whitespace-pre-line">
                                        {' '}— {h.decisionNotes ?? h.withdrawReason}
                                    </span>
                                )}
                                {h.result && (
                                    <div className="mt-1 grid gap-4 sm:grid-cols-2">
                                        <Figures f={h.estimate} title={t('assetDisposal.estimateTitle')} />
                                        <Figures f={h.result} title={t('assetDisposal.resultTitle')} />
                                    </div>
                                )}
                            </li>
                        ))}
                    </ul>
                </div>
            )}
        </section>
    )
}
