'use client'

// ★ APR-6(Tim 2026-09-25):手工凭证与它的冲销要 CFO 批准才过账。
//   凭证列表页顶上这一块把【在等的】申请逐张摆出来 —— 一张手工凭证在批准之前还没有分录,
//   所以它没有自己的详情页,住在这里(看板 journal_request_pending 指到 #jr-<id>)。
//   每一张给:要过的那几行(冲销申请给要冲的那张分录)、金额、冻结的日期、「贷银行账户」、
//   日期落进已锁期间时的那一句;以及 批准(当场过账)/ 驳回(要理由)/ 撤回。下面是最近了结的几张。
//
// 【谁能批,这里不预判】二级审批角色、而且不是提单人(按人认)—— 两条都只有数据库知道
// (decide_journal_request → 二级审批人 + forbid_self_approval)。与 InvoiceRequestPanel 同一条:
// 钮亮着,拒绝由库出,就地说成人话。
// 【权限码的那一半看得见、按不动、带理由】(DBLOCK-1)—— 批 / 驳要 data.view_prices(能进这一页的人
// 已经持 module.finance.view,那是门的另一半);撤回要 module.finance.edit,提单人本人除外。
import { useTransition } from 'react'
import Link from 'next/link'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { showActionMessage } from '@/app/components/ui/action-message'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { formatAmount } from '@/lib/format'
import { decideJournalRequest, withdrawJournalRequest } from './requestActions'

export type JournalRequestLineView = {
    key: string
    accountText: string
    debitText: string
    creditText: string
    memo: string
}

export type JournalRequestView = {
    id: string
    label: string
    kind: 'entry' | 'reversal'
    status: 'submitted' | 'approved' | 'rejected' | 'withdrawn'
    entryDateText: string
    memo: string
    amountBase: number
    creditsBank: boolean
    /** 冻结的日期落在已锁的期间里 —— 批准会被引擎按 PERIOD_LOCKED 拒(Q4:锁永远赢) */
    periodLocked: boolean
    lines: JournalRequestLineView[]
    targetEntry: { id: string; code: string } | null
    resultEntry: { id: string; code: string } | null
    decisionNotes: string | null
    withdrawReason: string | null
    createdText: string
    raisedByMe: boolean
}

export default function JournalRequestsPanel({
    open,
    history,
    canDecide,
    canWithdraw,
    baseCurrency,
    lockedBeforeText,
}: {
    open: JournalRequestView[]
    history: JournalRequestView[]
    canDecide: boolean
    canWithdraw: boolean
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

    if (open.length === 0 && history.length === 0) return null

    return (
        <section className="mb-6 space-y-3" aria-label={t('finance.journalRequest.title')}>
            <h2>{t('finance.journalRequest.title')}</h2>
            {open.length === 0 && (
                <p className="text-sm text-[color:var(--brand-muted-text)]">{t('finance.journalRequest.noneWaiting')}</p>
            )}
            {open.map((r) => (
                <div
                    key={r.id}
                    id={`jr-${r.id}`}
                    className="rounded border border-amber-300 bg-amber-50 p-4 space-y-3 scroll-mt-24"
                    data-journal-request={r.label}
                >
                    <h3>{t('finance.journalRequest.openTitle.' + r.kind)}</h3>
                    <dl className="text-sm grid grid-cols-[max-content_1fr] gap-x-4 gap-y-1">
                        <dt className="text-[color:var(--brand-muted-text)]">{t('finance.journalRequest.request')}</dt>
                        <dd>
                            <span className="font-mono">{r.label}</span> · {t('finance.journalRequest.kind.' + r.kind)} · {r.createdText}
                        </dd>
                        <dt className="text-[color:var(--brand-muted-text)]">{t('finance.journalRequest.amount')}</dt>
                        <dd>{formatAmount(r.amountBase, baseCurrency)}</dd>
                        <dt className="text-[color:var(--brand-muted-text)]">{t('finance.journalRequest.date.' + r.kind)}</dt>
                        <dd>{r.entryDateText}</dd>
                        {r.targetEntry && (
                            <>
                                <dt className="text-[color:var(--brand-muted-text)]">{t('finance.journalRequest.target')}</dt>
                                <dd>
                                    <Link href={`/finance/journal/${r.targetEntry.id}`} className="hover:underline app-link app-link-inline font-mono">
                                        {r.targetEntry.code}
                                    </Link>
                                </dd>
                            </>
                        )}
                        <dt className="text-[color:var(--brand-muted-text)]">{t('finance.journalRequest.memo.' + r.kind)}</dt>
                        <dd className="whitespace-pre-line">{r.memo}</dd>
                    </dl>

                    {r.lines.length > 0 && (
                        // 行预览:一个四列的网格,不是手搓 <table>(check-component-library 的棘轮)——
                        // 它只读、几行、不排序,DataTable 的分页 / 手机卡片在这里买不到任何东西。
                        <div className="text-sm grid grid-cols-[minmax(0,2fr)_max-content_max-content_minmax(0,1fr)] gap-x-4 gap-y-0.5 max-w-2xl">
                            <span className="text-[color:var(--brand-muted-text)]">{t('finance.colAccount')}</span>
                            <span className="text-[color:var(--brand-muted-text)] text-right">{t('finance.debit')}</span>
                            <span className="text-[color:var(--brand-muted-text)] text-right">{t('finance.credit')}</span>
                            <span className="text-[color:var(--brand-muted-text)]">{t('finance.lineMemo')}</span>
                            {r.lines.map((l) => (
                                <div key={l.key} className="contents">
                                    <span className="break-words">{l.accountText}</span>
                                    <span className="text-right">{l.debitText}</span>
                                    <span className="text-right">{l.creditText}</span>
                                    <span className="break-words">{l.memo}</span>
                                </div>
                            ))}
                        </div>
                    )}

                    {r.creditsBank && (
                        <p className="text-sm font-medium text-amber-900">{t('finance.journalRequest.creditsBank')}</p>
                    )}
                    {r.periodLocked && lockedBeforeText && (
                        <p className="text-sm text-red-700">
                            {t('finance.journalRequest.periodLocked', { date: lockedBeforeText })}
                        </p>
                    )}
                    <p className="text-xs text-[color:var(--brand-text)]">{t('finance.journalRequest.decideHint')}</p>

                    <PermissionGate code="data.view_prices" allowed={canDecide}>
                        <div className="flex flex-wrap items-start gap-3">
                            <ConfirmButton
                                subject={r.label}
                                title={t('finance.journalRequest.approveConfirm.' + r.kind)}
                                body={t('finance.journalRequest.approveBody.' + r.kind)}
                                confirmLabel={t('finance.journalRequest.approve')}
                                tier="default"
                                triggerVariant="default"
                                disabled={pending}
                                onConfirm={() => run(r.label, () => decideJournalRequest(r.id, true, '', r.targetEntry?.id ?? null))}
                            >
                                {pending ? t('common.saving') : t('finance.journalRequest.approve')}
                            </ConfirmButton>
                            <ConfirmButton
                                subject={r.label}
                                title={t('finance.journalRequest.rejectConfirm')}
                                body={t('finance.journalRequest.rejectBody')}
                                confirmLabel={t('finance.journalRequest.reject')}
                                tier="destructive"
                                triggerVariant="destructive"
                                reason={{ placeholder: t('finance.journalRequest.rejectPlaceholder') }}
                                disabled={pending}
                                onConfirm={(reason) => run(r.label, () => decideJournalRequest(r.id, false, reason, r.targetEntry?.id ?? null))}
                            >
                                {t('finance.journalRequest.reject')}
                            </ConfirmButton>
                        </div>
                    </PermissionGate>

                    <PermissionGate code="module.finance.edit" allowed={canWithdraw || r.raisedByMe}>
                        <ConfirmButton
                            subject={r.label}
                            title={t('finance.journalRequest.withdrawConfirm')}
                            body={t('finance.journalRequest.withdrawBody')}
                            confirmLabel={t('finance.journalRequest.withdraw')}
                            tier="reversal"
                            triggerVariant="outline"
                            disabled={pending}
                            onConfirm={() => run(r.label, () => withdrawJournalRequest(r.id, '', r.targetEntry?.id ?? null))}
                        >
                            {t('finance.journalRequest.withdraw')}
                        </ConfirmButton>
                    </PermissionGate>
                </div>
            ))}

            {history.length > 0 && (
                <div>
                    <h3 className="mb-1">{t('finance.journalRequest.history')}</h3>
                    <ul className="text-sm space-y-1">
                        {history.map((h) => (
                            <li key={h.id}>
                                <span className="font-mono">{h.label}</span> · {t('finance.journalRequest.kind.' + h.kind)} ·{' '}
                                {formatAmount(h.amountBase, baseCurrency)} · {t('finance.journalRequest.status.' + h.status)} · {h.createdText}
                                {h.resultEntry && (
                                    <>
                                        {' '}·{' '}
                                        <Link href={`/finance/journal/${h.resultEntry.id}`} className="hover:underline app-link app-link-inline font-mono">
                                            {h.resultEntry.code}
                                        </Link>
                                    </>
                                )}
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
