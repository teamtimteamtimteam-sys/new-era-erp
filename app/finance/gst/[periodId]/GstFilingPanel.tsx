'use client'

// app/finance/gst/[periodId]/GstFilingPanel.tsx
// ★ APR-10(Tim 2026-09-27,grilling Q1 · Q2 · Q3 · Q4):GST 申报 —— 财务提,CFO 批【报出去之前的那一组数】,
//   批准之后财务才去 IRAS 报。这一块住在期间页上(看板 gst_filing_pending 指到 #gst-filing):
//   在等的那一张 —— 谁提的、冻结的每一格;★ 那一季的数此刻若与冻结的不一样(current_matches = false),先说出来:
//   批准会被 GST_RETURN_CHANGED_SINCE_REQUEST 拒;★ 更正件(F7)逐格给出原件【报出去的】那一份与差(Q2)。
//   然后 批准(当场写快照,期间 → approved)/ 驳回(要理由)/ 撤回。下面是最近了结的几张。
//
// 【谁能批,这里不预判】二级审批角色、而且不是提单人(按人认)—— 两条都只有数据库知道。
// 【权限码的那一半看得见、按不动、带理由】(DBLOCK-1):批 / 驳要 module.finance.view + data.view_prices;
// 撤回要 module.finance.edit,提单人本人除外。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { showActionMessage } from '@/app/components/ui/action-message'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { Button } from '@/app/components/ui/button'
import { CONTROL_INPUT } from '@/app/components/ui/control-style'
import { DatePicker } from '@/app/components/ui/date-picker'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import { decideGstFiling, withdrawGstFiling, submitGstFiling, recordGstFiling } from '../actions'

export type GstBoxLine = {
    box: string
    label: string
    frozen: number
    now: number | null
    original: number | null
}

export type GstFilingView = {
    id: string
    status: 'submitted' | 'approved' | 'rejected' | 'withdrawn'
    label: string
    lines: GstBoxLine[]
    currentMatches: boolean | null
    originalCode: string | null
    note: string | null
    createdText: string
    raisedBy: string | null
    raisedByMe: boolean
    decidedBy: string | null
    decisionNotes: string | null
    withdrawReason: string | null
}

const n2 = (v: number | null) => (v === null ? '—' : v.toFixed(2))

function BoxesTable({ lines, showOriginal }: { lines: GstBoxLine[]; showOriginal: boolean }) {
    const t = useTranslations()
    const showNow = lines.some((l) => l.now !== null && l.now !== l.frozen)
    const columns: Column<GstBoxLine>[] = [
        { key: 'box', header: t('gstFiling.colBox'), priority: true,
          render: (l) => <>{l.box.replace('box', '')} · {l.label}</> },
        { key: 'frozen', header: t('gstFiling.colFrozen'), priority: true, align: 'right',
          render: (l) => n2(l.frozen) },
        ...(showNow ? [{ key: 'now', header: t('gstFiling.colNow'), align: 'right' as const,
          render: (l: GstBoxLine) => (
              <span className={l.now !== l.frozen ? 'text-red-700 font-medium' : undefined}>{n2(l.now)}</span>
          ) }] : []),
        ...(showOriginal ? [
            { key: 'original', header: t('gstFiling.colOriginal'), align: 'right' as const,
              render: (l: GstBoxLine) => n2(l.original) },
            { key: 'difference', header: t('gstFiling.colDifference'), align: 'right' as const,
              render: (l: GstBoxLine) => (l.original === null ? '—' : (l.frozen - l.original).toFixed(2)) },
        ] : []),
    ]
    return <DataTable rows={lines} columns={columns} rowKey={(l) => l.box} phone={{ mode: 'columns' }} />
}

export default function GstFilingPanel({
    periodId, periodCode, periodStatus, open, history, blockedWhy, canEdit, canDecide, holdsDecideView,
}: {
    periodId: string
    /** 这一期的编号 —— 提交那一步的确认框说的就是它 */
    periodCode: string
    periodStatus: 'open' | 'approved' | 'filed'
    open: GstFilingView[]
    history: GstFilingView[]
    /** 提交被挡住的【具体】理由(没关账 · 已批准 · 已申报 · 已有一张在等);undefined = 提得了 */
    blockedWhy?: string
    /** module.finance.edit —— 提、撤回(提单人本人除外)、记下申报 */
    canEdit: boolean
    /** module.finance.view 且 data.view_prices(决定的门;谁是二级、谁是提单人由库裁) */
    canDecide: boolean
    /** 读者持 module.finance.view —— 缺的是哪一个码,用它点名 */
    holdsDecideView: boolean
}) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [note, setNote] = useState('')
    const [filedOn, setFiledOn] = useState('')
    // DATE-PICK-1:记下申报靠按钮 onClick 提交(不走原生表单)—— 框里是敲错的日子时把按钮关掉
    const [filedOnBad, setFiledOnBad] = useState(false)
    const [reference, setReference] = useState('')
    const [err, setErr] = useState('')
    const notDone = t('common.actionMessage.headline.notDecided')

    function run(subject: string, fn: () => Promise<{ error?: string }>) {
        start(async () => {
            const r = await fn()
            if (r?.error) {
                showActionMessage({ subject, headline: notDone, body: r.error })
                return
            }
            router.refresh()
        })
    }

    return (
        <section id="gst-filing" className="mb-8 space-y-3 scroll-mt-24" aria-label={t('gstFiling.panelTitle')}>
            <h2>{t('gstFiling.panelTitle')}</h2>
            <p className="text-xs text-[color:var(--brand-muted-text)]">{t('gstFiling.howItWorks')}</p>

            {open.map((r) => (
                <div key={r.id} id={`gfr-${r.id}`}
                     className="rounded border border-amber-300 bg-amber-50 p-4 space-y-3 scroll-mt-24"
                     data-gst-filing-request={r.label}>
                    <h3>{t('gstFiling.openTitle')}</h3>
                    <p className="text-sm">
                        <span className="font-mono">{r.label}</span> · {r.createdText}
                        {r.raisedBy && <> · {t('gstFiling.raisedBy', { who: r.raisedBy })}</>}
                    </p>
                    {r.note && <p className="text-sm whitespace-pre-line">{r.note}</p>}
                    {r.originalCode && (
                        <p className="text-sm">{t('gstFiling.correctsOriginal', { code: r.originalCode })}</p>
                    )}
                    <BoxesTable lines={r.lines} showOriginal={r.originalCode !== null} />
                    {r.currentMatches === false && (
                        <p className="text-sm font-medium text-red-700">{t('gstFiling.changedSince')}</p>
                    )}
                    <p className="text-xs text-[color:var(--brand-text)]">{t('gstFiling.decideHint')}</p>

                    <PermissionGate code={holdsDecideView ? 'data.view_prices' : 'module.finance.view'}
                        allowed={canDecide}>
                        <div className="flex flex-wrap items-start gap-3">
                            <ConfirmButton
                                subject={r.label}
                                title={t('gstFiling.approveConfirm')}
                                body={t('gstFiling.approveBody')}
                                confirmLabel={t('gstFiling.approve')}
                                tier="destructive"
                                triggerVariant="default"
                                disabled={pending}
                                onConfirm={() => run(r.label, () => decideGstFiling(periodId, r.id, true, ''))}
                            >
                                {pending ? t('common.saving') : t('gstFiling.approve')}
                            </ConfirmButton>
                            <ConfirmButton
                                subject={r.label}
                                title={t('gstFiling.rejectConfirm')}
                                body={t('gstFiling.rejectBody')}
                                confirmLabel={t('gstFiling.reject')}
                                tier="destructive"
                                triggerVariant="destructive"
                                reason={{ placeholder: t('gstFiling.rejectPlaceholder') }}
                                disabled={pending}
                                onConfirm={(why) => run(r.label, () => decideGstFiling(periodId, r.id, false, why))}
                            >
                                {t('gstFiling.reject')}
                            </ConfirmButton>
                        </div>
                    </PermissionGate>

                    <PermissionGate code="module.finance.edit" allowed={r.raisedByMe || canEdit}>
                        <ConfirmButton
                            subject={r.label}
                            title={t('gstFiling.withdrawConfirm')}
                            body={t('gstFiling.withdrawBody')}
                            confirmLabel={t('gstFiling.withdraw')}
                            tier="reversal"
                            triggerVariant="outline"
                            disabled={pending}
                            onConfirm={() => run(r.label, () => withdrawGstFiling(periodId, r.id))}
                        >
                            {t('gstFiling.withdraw')}
                        </ConfirmButton>
                    </PermissionGate>
                </div>
            ))}

            {/* ── 提:只有 open 的期间、没有一张在等时 ── */}
            {periodStatus === 'open' && open.length === 0 && (
                <div className="space-y-2">
                    <h3>{t('gstFiling.submitTitle')}</h3>
                    {blockedWhy ? (
                        <div className="inline-flex flex-col items-start">
                            <Button type="button" disabled>{t('gstFiling.submit')}</Button>
                            <span className="text-xs text-amber-700 mt-1">{blockedWhy}</span>
                        </div>
                    ) : (
                        <div className="flex flex-wrap items-end gap-3">
                            <div className="flex-1 min-w-[16rem]">
                                <label className="block mb-1">{t('gstFiling.note')}</label>
                                <input value={note} onChange={(e) => setNote(e.target.value)}
                                       placeholder={t('gstFiling.notePlaceholder')}
                                       className={`${CONTROL_INPUT} w-full`} />
                            </div>
                            <PermissionGate code="module.finance.edit" allowed={canEdit}>
                                <ConfirmButton
                                    subject={periodCode}
                                    title={t('gstFiling.submitConfirm')}
                                    body={t('gstFiling.submitBody')}
                                    confirmLabel={t('gstFiling.submit')}
                                    tier="default"
                                    triggerVariant="default"
                                    disabled={pending}
                                    onConfirm={() => run(periodCode, async () => {
                                        const r = await submitGstFiling(periodId, note)
                                        if (!r.error) setNote('')
                                        return r
                                    })}
                                >
                                    {pending ? t('common.saving') : t('gstFiling.submit')}
                                </ConfirmButton>
                            </PermissionGate>
                        </div>
                    )}
                </div>
            )}

            {/* ── 记下申报:只有 CFO 批准过的期间 ── */}
            {periodStatus === 'approved' && (
                <div className="space-y-2">
                    <h3>{t('gst.recordFiling')}</h3>
                    <p className="text-xs text-[color:var(--brand-muted-text)]">{t('gstFiling.recordHint')}</p>
                    <div className="flex flex-wrap items-end gap-3">
                        <div>
                            <label className="block mb-1">{t('gst.filedOn')}</label>
                            <DatePicker value={filedOn} onChange={setFiledOn} onInvalidChange={setFiledOnBad} />
                        </div>
                        <div>
                            <label className="block mb-1">{t('gst.filedReference')}</label>
                            <input value={reference} onChange={(e) => setReference(e.target.value)}
                                   placeholder={t('gst.filedReferenceHint')}
                                   className={CONTROL_INPUT} />
                        </div>
                        {!filedOn && <p className="text-sm text-amber-700 self-center">{t('gst.blockedNeedFiledOn')}</p>}
                        <PermissionGate code="module.finance.edit" allowed={canEdit}>
                            <Button type="button" disabled={!filedOn || pending || filedOnBad}
                                    onClick={() => start(async () => {
                                        const r = await recordGstFiling(periodId, filedOn, reference)
                                        if (r.error) setErr(r.error); else { setErr(''); router.refresh() }
                                    })}>
                                {pending ? t('common.saving') : t('gst.recordFiling')}
                            </Button>
                        </PermissionGate>
                        {err && <p className="text-sm text-red-700 w-full">{err}</p>}
                    </div>
                </div>
            )}

            {history.length > 0 && (
                <div>
                    <h3 className="mb-1">{t('gstFiling.history')}</h3>
                    <ul className="text-sm space-y-1">
                        {history.map((h) => (
                            <li key={h.id}>
                                <span className="font-mono">{h.label}</span> · {t('gstFiling.status.' + h.status)} ·{' '}
                                {h.createdText}
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
