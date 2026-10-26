'use client'

// ★ APR-8(Tim 2026-09-26,grilling Q8):合同条款与定价公式 —— cco 提,CFO 批每一张,批准之前什么都不生效。
//   公式页与合同页上这一块把【在等的】申请逐张摆出来(看板 terms_request_pending 指到 #tr-<id>):
//   提了什么、谁提的、为什么;★ 一张逐项的差别表 —— 公式:此刻在用的条款 → 拟议的条款;
//   合同:上一次批准时的那一份 → 此刻的条款(从未批过时左列是空的);变了的那几行标出来;
//   哪些单据会用它(已承诺的不受影响 —— 它们读的是副本)。然后 批准(当场生效)/ 驳回(要理由)/ 撤回。
//   下面是最近了结的几张。
//
// 【谁能批,这里不预判】二级审批角色、而且不是提单人(按人认)—— 两条都只有数据库知道。
// 【权限码的那一半看得见、按不动、带理由】(DBLOCK-1):批 / 驳要五个门码(page 算出缺的第一个);
// 撤回要那一种的码(公式 module.pricing.edit · 合同 action.contract_terms),提单人本人除外。
import { useTransition, useState } from 'react'
import Link from 'next/link'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { showActionMessage } from '@/app/components/ui/action-message'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { decideTermsRequest, withdrawTermsRequest } from './termsRequestActions'
import type { TermsDiffRow, TermsRequestView } from './termsRequestsData'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { BulkDecisionBar, BulkCheck } from '@/app/components/ui/bulk-decision-bar'
import { xText } from '@/lib/export/cells'

export default function TermsRequestsPanel({
    open, history, missingDecideCode, withdrawCode, canWithdrawByCode, bulk = false,
}: {
    open: TermsRequestView[]
    history: TermsRequestView[]
    /** 批 / 驳要的五个门码里,读者缺的第一个;null = 五个都持(谁能批仍由库裁) */
    missingDecideCode: string | null
    /** 这一页的申请撤回要的那个码 */
    withdrawCode: string
    canWithdrawByCode: boolean
    /** TABLE-FEATURES-3(Tim 2026-10-25 Q2):批量批准 / 驳回 —— 只在两张列表页上开(/contracts · /tools/pricing/formulas);
     *  合同详情页与公式编辑页不开(grilling,Tim 2026-10-26 接受) */
    bulk?: boolean
}) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const notDone = t('common.actionMessage.headline.notDecided')
    const [selected, setSelected] = useState<Set<string>>(new Set())
    const toggle = (id: string) => setSelected((s) => { const n = new Set(s); if (n.has(id)) n.delete(id); else n.add(id); return n })
    const bulkAllowed = bulk && missingDecideCode === null

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

    // 差别表:条款 · 之前(在用 / 上一次批准时)· 之后(拟议 / 合同上此刻的);变了的那几行底色标出来。
    // 手机上留【条款】与【之后】—— CFO 批的是右边那一列。
    // TABLE-EXPORT-3c(Tim 2026-10-25):每一张在等的申请各一对导出(名字相同,About 表写明是哪一张申请)。
    //   差别表的格子本来就是【摊平成句子】的条款(一格里可能是几行、可能是数也可能是名字)—— 原样写文字。
    //   「—」= 那一边没有(新公式没有「之前」)→ 空格,不写那个横杠。
    //   变了的那几行屏幕上是底色;文件里没有底色 → 接在条款名后面「(有改动)」(FormulasTable 的 rowInactive 同形)。
    const dash = (v: string) => xText(v === '—' ? null : v)
    const diffColumns = (r: TermsRequestView): ExportableColumn<TermsDiffRow>[] => [
        { key: 'field', header: t('termsRequest.colField'), priority: true, render: (d) => d.label,
          exportAs: (d) => xText(d.changed ? `${d.label} (${t('table.export.rowChanged')})` : d.label) },
        { key: 'before', header: t('termsRequest.before.' + r.beforeIs), className: 'whitespace-pre-line break-words',
          render: (d) => d.before, exportAs: (d) => dash(d.before) },
        { key: 'after', header: t('termsRequest.after.' + r.kind), priority: true, className: 'whitespace-pre-line break-words',
          render: (d) => d.after, exportAs: (d) => dash(d.after) },
    ]

    if (open.length === 0 && history.length === 0) return null

    return (
        <section className="space-y-3" aria-label={t('termsRequest.panelTitle')}>
            <h2>{t('termsRequest.panelTitle')}</h2>
            {open.length === 0 && (
                <p className="text-sm text-[color:var(--brand-muted-text)]">{t('termsRequest.noneWaiting')}</p>
            )}
            {bulk && open.length > 0 && (
                <PermissionGate code={missingDecideCode ?? 'module.pricing.view'} allowed={missingDecideCode === null}>
                    <BulkDecisionBar
                        items={open.map((r) => ({ id: r.id, label: r.label }))}
                        selected={selected}
                        onSelectedChange={setSelected}
                        approve={{ title: t('bulk.titles.termsApprove'), act: (i) => decideTermsRequest(i.id, true, '') }}
                        reject={{ title: t('bulk.titles.termsReject'), placeholder: t('termsRequest.rejectPlaceholder'),
                                  act: (i, reason) => decideTermsRequest(i.id, false, reason) }}
                    />
                </PermissionGate>
            )}
            {open.map((r) => (
                <div
                    key={r.id}
                    id={`tr-${r.id}`}
                    className="rounded border border-amber-300 bg-amber-50 p-4 space-y-3 scroll-mt-24"
                    data-terms-request={r.label}
                >
                    <div className="flex items-center gap-2">
                        {bulkAllowed && <BulkCheck label={r.label} checked={selected.has(r.id)} onChange={() => toggle(r.id)} />}
                        <h3>{t('termsRequest.openTitle.' + r.kind)}</h3>
                    </div>
                    <dl className="text-sm grid grid-cols-[max-content_1fr] gap-x-4 gap-y-1">
                        <dt className="text-[color:var(--brand-muted-text)]">{t('termsRequest.request')}</dt>
                        <dd>
                            <span className="font-mono">{r.label}</span> · {r.createdText}
                            {r.raisedBy && <> · {t('termsRequest.raisedBy', { who: r.raisedBy })}</>}
                        </dd>
                        <dt className="text-[color:var(--brand-muted-text)]">{t('termsRequest.subject.' + r.kind)}</dt>
                        <dd>
                            {/* TERMS-EDIT-1(Q1):合同申请点得进那份合同 —— CFO 在那里看得见整份条款与它的历史 */}
                            {r.contractId
                                ? <Link href={`/contracts/${r.contractId}`} className="font-mono hover:underline app-link"
                                        data-terms-request-contract={r.subjectCode}>{r.subjectCode}</Link>
                                : <span className="font-mono">{r.subjectCode}</span>}
                            {r.subjectName && <> · {r.subjectName}</>}
                        </dd>
                        <dt className="text-[color:var(--brand-muted-text)]">{t('termsRequest.reason')}</dt>
                        <dd className="whitespace-pre-line">{r.reason}</dd>
                    </dl>

                    {r.diff === null ? (
                        <p className="text-sm">{t('termsRequest.termsRestricted')}</p>
                    ) : (
                        <DataTable<TermsDiffRow>
                            rows={r.diff}
                            columns={diffColumns(r)}
                            rowKey={(d) => d.key}
                            phone={{ mode: 'columns' }}
                            rowClassName={(d) => (d.changed ? 'bg-amber-100 font-medium' : undefined)}
                            // TABLE-FEATURES-1(Tim 2026-10-25 Q9):差别表是这张申请的全部条款行 —— 在浏览器里排;
                            //   不点表头时仍是条款原来的次序(申请本身仍按最早在等的在前,Q7)
                            sorting={{ mode: 'client', coverage: 'complete' }}
                            exportSpec={{
                                name: 'pricing-terms-request',
                                title: t('termsRequest.openTitle.' + r.kind),
                                aboutExtra: [
                                    [t('termsRequest.request'), r.label],
                                    [t('termsRequest.subject.' + r.kind), r.subjectName ? `${r.subjectCode} · ${r.subjectName}` : r.subjectCode],
                                ],
                            }}
                        />
                    )}
                    {r.usage.length > 0 && (
                        <ul className="text-sm list-disc pl-5">
                            {r.usage.map((u) => <li key={u}>{u}</li>)}
                        </ul>
                    )}
                    <p className="text-xs text-[color:var(--brand-text)]">{t('termsRequest.decideHint')}</p>

                    <PermissionGate code={missingDecideCode ?? 'module.pricing.view'} allowed={missingDecideCode === null}>
                        <div className="flex flex-wrap items-start gap-3">
                            <ConfirmButton
                                subject={r.label}
                                title={t('termsRequest.approveConfirm.' + r.kind)}
                                body={t('termsRequest.approveBody.' + r.kind)}
                                confirmLabel={t('termsRequest.approve')}
                                tier="destructive"
                                triggerVariant="default"
                                disabled={pending}
                                onConfirm={() => run(r.label, () => decideTermsRequest(r.id, true, ''))}
                            >
                                {pending ? t('common.saving') : t('termsRequest.approve')}
                            </ConfirmButton>
                            <ConfirmButton
                                subject={r.label}
                                title={t('termsRequest.rejectConfirm')}
                                body={t('termsRequest.rejectBody')}
                                confirmLabel={t('termsRequest.reject')}
                                tier="destructive"
                                triggerVariant="destructive"
                                reason={{ placeholder: t('termsRequest.rejectPlaceholder') }}
                                disabled={pending}
                                onConfirm={(reason) => run(r.label, () => decideTermsRequest(r.id, false, reason))}
                            >
                                {t('termsRequest.reject')}
                            </ConfirmButton>
                        </div>
                    </PermissionGate>

                    <PermissionGate code={withdrawCode} allowed={r.raisedByMe || canWithdrawByCode}>
                        <ConfirmButton
                            subject={r.label}
                            title={t('termsRequest.withdrawConfirm')}
                            body={t('termsRequest.withdrawBody')}
                            confirmLabel={t('termsRequest.withdraw')}
                            tier="reversal"
                            triggerVariant="outline"
                            disabled={pending}
                            onConfirm={() => run(r.label, () => withdrawTermsRequest(r.id))}
                        >
                            {t('termsRequest.withdraw')}
                        </ConfirmButton>
                    </PermissionGate>
                </div>
            ))}

            {history.length > 0 && (
                <div>
                    <h3 className="mb-1">{t('termsRequest.history')}</h3>
                    <ul className="text-sm space-y-1">
                        {history.map((h) => (
                            <li key={h.id}>
                                <span className="font-mono">{h.label}</span> ·{' '}
                                {t('termsRequest.status.' + h.status)} · {h.createdText}
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
