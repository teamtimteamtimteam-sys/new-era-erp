// app/output/[id]/edit/TraceabilitySection.tsx
// AUD-2:客户审计报告(可追溯报告)—— 屏幕那一半。
//
// 【地面说的"批次页"就是这一张】/output/[id] 不存在;产出批的单据主页是
// /output/[id]/edit(首页那几支的 itemHref 也指它,见 app/page.tsx 的 TILES 注释:
// URL 里有 /edit 不代表它是一张纯表单)。
//
// ── 管着每一个格子的那条规矩 ──────────────────────────────────────────────
// **出处跟着数字走。** 每一行回收率都带着 input_source / output_source;
// 算不出的回收率印它的【具名原因】(input_not_measured 等),绝不印 0、绝不留空;
// 'unknown' 就印 unknown,不抹平成 assay。
// 这三条不是显示偏好,是 REC-1 与 PROC-1 两刀的全部要点:【测出来是零】与
// 【根本没测】导向相反的结论,而回收率是拿两侧相除的 —— 不说出除的是哪一种数,
// 这个百分比就没有意义。
// 单元格文案与 PDF 共用 app/output/traceabilityShared.ts,一份实现两个消费者。
//
// 【NOTHING_TO_REPORT 是一个具名的空状态,不是一张空表】线上真实用例:
// OUT-2026-0001 / OUT-2026-0002 —— 在册、却零支生产单。
import Link from 'next/link'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import IssuePanel from '@/app/components/IssuePanel'
import { localizeTraceabilityError } from '@/app/output/traceabilityErrorCodes'
import {
    recoveryText,
    sourceText,
    kgText,
    type TraceabilityReport,
} from '@/app/output/traceabilityShared'

export type IssueRow = { code: string; version: number; issued_at: string; sha256: string }

export default async function TraceabilitySection({
    batchId,
    report,
    issues,
    issuesRestricted = false,
}: {
    batchId: string
    /** traceability_report_data 的答复,或者它的【具名拒绝】—— 两者都要说出来 */
    report: TraceabilityReport | { error: string }
    issues: IssueRow[]
    /** ★ FIX-2b:签发档的零行有两种意思;只有页面答得出是哪一种。 */
    issuesRestricted?: boolean
}) {
    const t = await getTranslations()
    const locale = await getLocale()
    const dl = locale === 'zh' ? 'zh-CN' : 'en-SG'
    const pdfHref = `/output/${batchId}/traceability/pdf`

    const failed = 'error' in report
    const blockedReason = failed ? await localizeTraceabilityError(report.error) : ''

    return (
        <section className="mt-8 pt-8 border-t">
            <h2 className="text-xl font-bold mb-1">{t('traceability.title')}</h2>
            <p className="text-sm text-gray-600 mb-3">{t('traceability.intro')}</p>

            {failed ? (
                // 【具名的空状态】—— 不是一张空表让人猜是没数据还是没加载出来。
                <div className="bg-gray-50 border border-gray-300 text-gray-700 px-4 py-4 rounded mb-4 text-sm">
                    {blockedReason}
                </div>
            ) : (
                <>
                    {/* ── 血缘链:供应商 → 收货 → 每一支加工单 → 这一批 ─────────── */}
                    <h3 className="font-medium mb-2">{t('traceability.chainHeading')}</h3>
                    <div className="overflow-x-auto mb-6">
                        <table className="w-full border-collapse border border-gray-300 text-sm">
                            <thead className="bg-gray-100">
                                <tr>
                                    <th className="border border-gray-300 px-3 py-2 text-right">{t('traceability.colStep')}</th>
                                    <th className="border border-gray-300 px-3 py-2 text-left">{t('traceability.colRun')}</th>
                                    <th className="border border-gray-300 px-3 py-2 text-left">{t('traceability.colParent')}</th>
                                    <th className="border border-gray-300 px-3 py-2 text-right">{t('traceability.colQtyConsumed')}</th>
                                    <th className="border border-gray-300 px-3 py-2 text-left">{t('traceability.colSupplier')}</th>
                                    <th className="border border-gray-300 px-3 py-2 text-left">{t('traceability.colArrival')}</th>
                                </tr>
                            </thead>
                            <tbody>
                                {report.chain.map((c) => (
                                    <tr key={`${c.depth}-${c.via_run_id}-${c.parent_batch_id}`}>
                                        <td className="border border-gray-300 px-3 py-2 text-right font-mono">{c.depth}</td>
                                        <td className="border border-gray-300 px-3 py-2 font-mono text-xs">
                                            <Link href={`/operation/processing/${c.via_run_id}`} className="text-blue-600 hover:underline">
                                                {c.via_run_code}
                                            </Link>
                                        </td>
                                        <td className="border border-gray-300 px-3 py-2 text-xs">
                                            <span className="text-gray-500 mr-1">
                                                {c.parent_kind === 'inbound'
                                                    ? t('traceability.kindInbound')
                                                    : t('traceability.kindOutput')}
                                            </span>
                                            <Link
                                                href={
                                                    c.parent_kind === 'inbound'
                                                        ? `/inbound/${c.parent_batch_id}/edit`
                                                        : `/output/${c.parent_batch_id}/edit`
                                                }
                                                className="font-mono text-blue-600 hover:underline"
                                            >
                                                {c.parent_code ?? '—'}
                                            </Link>
                                        </td>
                                        <td className="border border-gray-300 px-3 py-2 text-right font-mono">{c.quantity_consumed}</td>
                                        {/* 供应商只在链末的进料父上有 —— 上游那几段的父是自家的产出批 */}
                                        <td className="border border-gray-300 px-3 py-2 text-xs">
                                            {c.supplier_name ? (
                                                <>
                                                    <span className="font-mono">{c.supplier_code}</span> {c.supplier_name}
                                                </>
                                            ) : (
                                                '—'
                                            )}
                                        </td>
                                        <td className="border border-gray-300 px-3 py-2 font-mono text-xs">{c.arrival_date ?? '—'}</td>
                                    </tr>
                                ))}
                            </tbody>
                        </table>
                    </div>

                    {/* ── 回收率:每支加工单 × 金属,出处跟着数字走 ───────────────── */}
                    <h3 className="font-medium mb-2">{t('traceability.recoveryHeading')}</h3>
                    <div className="overflow-x-auto mb-3">
                        <table className="w-full border-collapse border border-gray-300 text-sm">
                            <thead className="bg-gray-100">
                                <tr>
                                    <th className="border border-gray-300 px-3 py-2 text-left">{t('traceability.colRun')}</th>
                                    <th className="border border-gray-300 px-3 py-2 text-left">{t('traceability.colMetal')}</th>
                                    <th className="border border-gray-300 px-3 py-2 text-right">{t('traceability.colInputKg')}</th>
                                    <th className="border border-gray-300 px-3 py-2 text-right">{t('traceability.colOutputKg')}</th>
                                    <th className="border border-gray-300 px-3 py-2 text-right">{t('traceability.colRecovery')}</th>
                                    <th className="border border-gray-300 px-3 py-2 text-left">{t('traceability.colInputSource')}</th>
                                    <th className="border border-gray-300 px-3 py-2 text-left">{t('traceability.colOutputSource')}</th>
                                </tr>
                            </thead>
                            <tbody>
                                {report.recovery.map((r) => (
                                    <tr key={`${r.run_id}-${r.metal}`}>
                                        <td className="border border-gray-300 px-3 py-2 font-mono text-xs">{r.run_code}</td>
                                        <td className="border border-gray-300 px-3 py-2">{t('metals.' + r.metal)}</td>
                                        <td className="border border-gray-300 px-3 py-2 text-right font-mono text-xs">
                                            {kgText(r.input_metal_kg, t)}
                                        </td>
                                        <td className="border border-gray-300 px-3 py-2 text-right font-mono text-xs">
                                            {kgText(r.output_metal_kg, t)}
                                        </td>
                                        {/* 【算不出就说原因】—— 灰字,与一个真的百分比在视觉上分得开 */}
                                        <td
                                            className={
                                                'border border-gray-300 px-3 py-2 text-right text-xs ' +
                                                (r.recovery_pct === null ? 'text-gray-500' : 'font-mono')
                                            }
                                        >
                                            {recoveryText(r, t)}
                                            {r.conservation_warning && (
                                                <span className="ml-2 text-amber-700">
                                                    {t('traceability.conservationFlag')}
                                                </span>
                                            )}
                                        </td>
                                        {/* 【出处跟着数字走】unknown 印成 unknown */}
                                        <td className="border border-gray-300 px-3 py-2 text-xs">
                                            {sourceText(r.input_source, t)}
                                        </td>
                                        <td className="border border-gray-300 px-3 py-2 text-xs">
                                            {sourceText(r.output_source, t)}
                                        </td>
                                    </tr>
                                ))}
                            </tbody>
                        </table>
                    </div>

                    {/* 【一句人话,而它也进 PDF】客户只拿到那张纸时,同样读得到这句。 */}
                    <p className="text-sm text-gray-700 bg-gray-50 border border-gray-200 rounded px-3 py-2 mb-4">
                        {t('traceability.estimateNote')}
                    </p>
                </>
            )}

            {/* ── 签发:与另外六个单据【同一个公共件】(EXT-1)───────────────── */}
            <h3 className="font-medium mb-2">{t('traceability.issuesHeading')}</h3>
            <p className="text-xs text-gray-500 mb-2">{t('traceability.issuesNote')}</p>
            <IssuePanel
                pdfHref={pdfHref}
                previewLabel={t('traceability.previewPdf')}
                issueLabel={t('traceability.issuePdf')}
                // 没有可报的东西就不给签发 —— 理由就是服务端那句具名拒绝,
                // 原样摆在按钮旁边(不另写一句)。
                canIssue={!failed}
                blockedReason={blockedReason}
            />
            {/* ★★ FIX-2b:【「从未签发」是这一块最不能撒的谎】★★
                页面上方那句注释已经写着这件事(客户手里可能已经有一份),而它当时
                只防住了【查询失败】(mustRows)。它防不住的是**一次权限答复**:
                traceability_report_issues 的策略是
                has_any_permission(['module.sales.view','module.processing.view']),
                而 finance 与 warehouse 【两个码都没有】(实测:Choo Er 0 行、
                Fu Sheng 0 行、Phua 1 行)—— 零行于是照直渲染成「从未签发」。
                权限先答,次序不能反。 */}
            {issuesRestricted ? (
                <p className="text-sm text-gray-600">{t('traceability.issuesRestricted')}</p>
            ) : issues.length === 0 ? (
                <p className="text-sm text-gray-500">{t('traceability.neverIssued')}</p>
            ) : (
                <ul className="text-sm space-y-1">
                    {issues.map((iss) => (
                        <li key={iss.version} className="font-mono text-xs">
                            <a
                                href={`${pdfHref}?version=${iss.version}`}
                                target="_blank"
                                rel="noopener noreferrer"
                                className="text-blue-600 hover:underline"
                            >
                                {iss.code} v{iss.version}
                            </a>
                            {' · '}
                            {new Date(iss.issued_at).toLocaleString(dl)} · {iss.sha256.slice(0, 12)}…
                        </li>
                    ))}
                </ul>
            )}
        </section>
    )
}
