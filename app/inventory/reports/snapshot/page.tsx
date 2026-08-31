// RPT-1:库存快照(物料 × 库位 × 状态)+ INV-VAL-1 的金额与库龄两节。
// 【未指定库位与任何一个库位一样,是一个普通分组】—— 线上 99/106 行流水没有库位。
//
// ★【金额列对读不到价的人印【受限】,不是 0.00】★ operations 与 warehouse
// 实测有 module.inventory.view、没有 data.view_prices —— 他们正是这张报表
// 最主要的读者。一个悄悄少算的合计会被抄进决策;"受限"两个字会让人去要权限。
import { getTranslations } from '@/lib/i18n/server'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { formatAmount, formatMoneyBare } from '@/lib/format'
import Subnav from '../../Subnav'
import { fetchValuation, groupByLocation, statusKey, bucketKey } from './snapshotQuery'

export default async function SnapshotPage() {
    const denied = await requireModule(MOD.inventory)
    if (denied) return denied
    const t = await getTranslations()
    const v = await fetchValuation()
    const groups = groupByLocation(v.rows)

    // 【合计只在看得到价的时候才有意义】看不到时不印一个 0,印受限。
    const totalValue = v.prices_visible
        ? v.rows.reduce((s, r) => s + (r.value_base ?? 0), 0)
        : null
    const totalUncosted = v.rows.reduce((s, r) => s + r.uncosted_qty, 0)

    const money = (n: number | null) =>
        n === null
            ? <span className="text-gray-400">{t('valuation.priceRestricted')}</span>
            : formatMoneyBare(n, '列头「价值 (SGD)」')

    return (
        <>
            <Subnav />
            <div className="p-8">
                <div className="flex items-start justify-between mb-2">
                    <div>
                        <h1 className="text-2xl font-bold">{t('reports.snapshot.title')}</h1>
                        <p className="text-sm text-gray-500 mt-1">{t('reports.snapshot.desc')}</p>
                    </div>
                    <div className="flex gap-2 shrink-0">
                        <a href="/inventory/reports/snapshot/export"
                           className="text-sm border border-gray-300 px-3 py-1 rounded hover:bg-gray-50">{t('reports.csv')}</a>
                        <a href="/inventory/reports/snapshot/pdf" target="_blank" rel="noopener noreferrer"
                           className="text-sm border border-gray-300 px-3 py-1 rounded hover:bg-gray-50">{t('reports.pdf')}</a>
                    </div>
                </div>
                <p className="text-xs text-gray-500 mb-2">{t('reports.snapshot.derivedNote')}</p>
                <p className="text-xs text-gray-500 mb-4">{t('reports.snapshot.basisNote')}</p>

                {/* ★ 具名受限 —— 说出【缺的是哪一项权限】,而不是让人对着空格子猜 */}
                {!v.prices_visible && (
                    <div className="mb-6 border border-amber-300 bg-amber-50 text-amber-900 px-4 py-3 rounded text-sm">
                        {t('reports.snapshot.priceRestrictedNote')}
                    </div>
                )}

                {/* ── 合计条 ─────────────────────────────────────────────── */}
                <div className="mb-6 flex flex-wrap gap-6 text-sm">
                    <div>
                        <span className="text-gray-600">{t('reports.snapshot.totalValue')}:</span>{' '}
                        <span className="font-medium font-mono">
                            {totalValue === null
                                ? <span className="text-gray-400">{t('valuation.priceRestricted')}</span>
                                : formatAmount(totalValue, v.base_currency)}
                        </span>
                    </div>
                    {/* 【没有成本口径的量单独站一格】它不是"值 0 的货" */}
                    <div>
                        <span className="text-gray-600">{t('reports.snapshot.uncostedQty')}:</span>{' '}
                        <span className="font-medium font-mono">{totalUncosted}</span>
                    </div>
                </div>

                {/* ── B 节:物料 × 库位 × 状态 ───────────────────────────── */}
                {groups.length === 0 ? (
                    <p className="text-gray-500">{t('reports.snapshot.empty')}</p>
                ) : (
                    groups.map(([key, g]) => (
                        <section key={key} className="mb-8">
                            <h2 className="font-medium mb-2">
                                {g.code ? `${g.code} — ${g.name ?? ''}` : t('reports.unspecifiedLocation')}
                            </h2>
                            {!g.code && (
                                <p className="text-xs text-gray-500 mb-2">{t('reports.unspecifiedLocationNote')}</p>
                            )}
                            <table className="w-full border-collapse border border-gray-300 text-sm">
                                <thead className="bg-gray-100">
                                    <tr>
                                        <th className="border border-gray-300 px-3 py-2 text-left">{t('reports.colMaterial')}</th>
                                        <th className="border border-gray-300 px-3 py-2 text-left">{t('reports.colBatchKind')}</th>
                                        <th className="border border-gray-300 px-3 py-2 text-left">{t('reports.colStatus')}</th>
                                        <th className="border border-gray-300 px-3 py-2 text-right">{t('reports.colQty')}</th>
                                        <th className="border border-gray-300 px-3 py-2 text-right">{t('reports.colValue')}</th>
                                        <th className="border border-gray-300 px-3 py-2 text-right">{t('reports.colUncostedQty')}</th>
                                    </tr>
                                </thead>
                                <tbody>
                                    {g.rows.map((r, i) => (
                                        <tr key={i}>
                                            <td className="border border-gray-300 px-3 py-2">
                                                <span className="font-mono text-xs">{r.material_code}</span> {r.material_name}
                                            </td>
                                            <td className="border border-gray-300 px-3 py-2">
                                                {t(r.batch_kind === 'inbound' ? 'reports.kindInbound' : 'reports.kindOutput')}
                                            </td>
                                            <td className="border border-gray-300 px-3 py-2">{t(statusKey(r.stock_status))}</td>
                                            <td className="border border-gray-300 px-3 py-2 text-right">{r.qty} {r.unit}</td>
                                            <td className="border border-gray-300 px-3 py-2 text-right">{money(r.value_base)}</td>
                                            <td className="border border-gray-300 px-3 py-2 text-right">
                                                {r.uncosted_qty !== 0 ? `${r.uncosted_qty} ${r.unit}` : '—'}
                                            </td>
                                        </tr>
                                    ))}
                                </tbody>
                            </table>
                        </section>
                    ))
                )}

                {/* ── C 节:库龄。档位定义在 DB 的 aging_bucket,这里只翻译 ── */}
                <section className="mb-8">
                    <h2 className="font-medium mb-2">{t('reports.snapshot.ageingTitle')}</h2>
                    <p className="text-xs text-gray-500 mb-2">{t('reports.snapshot.ageingNote')}</p>
                    <table className="w-full border-collapse border border-gray-300 text-sm">
                        <thead className="bg-gray-100">
                            <tr>
                                <th className="border border-gray-300 px-3 py-2 text-left">{t('reports.colAgeingBand')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-right">{t('reports.colBatches')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-right">{t('reports.colQty')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-right">{t('reports.colValue')}</th>
                            </tr>
                        </thead>
                        <tbody>
                            {v.ageing.map((a) => (
                                <tr key={a.bucket}>
                                    <td className="border border-gray-300 px-3 py-2">{t(bucketKey(a.bucket))}</td>
                                    <td className="border border-gray-300 px-3 py-2 text-right">{a.batches}</td>
                                    <td className="border border-gray-300 px-3 py-2 text-right">{a.qty}</td>
                                    <td className="border border-gray-300 px-3 py-2 text-right">{money(a.value_base)}</td>
                                </tr>
                            ))}
                        </tbody>
                    </table>
                </section>

                {/* ── 产出侧:三种状态必须长得不一样(R6) ────────────────── */}
                <section className="mb-8">
                    <h2 className="font-medium mb-2">{t('reports.snapshot.producedTitle')}</h2>
                    <p className="text-xs text-gray-500 mb-2">
                        {t('reports.snapshot.producedNote', {
                            n: String(v.produced.never_costed_batches),
                            qty: String(v.produced.never_costed_qty),
                            total: String(v.produced.on_hand_qty),
                        })}
                    </p>
                    <div className="flex flex-wrap gap-6 text-sm">
                        <div>
                            <span className="text-gray-600">{t('reports.snapshot.producedCosted')}:</span>{' '}
                            <span className="font-medium font-mono">{money(v.produced.costed_value_base)}</span>
                        </div>
                        <div>
                            <span className="text-gray-600">{t('reports.snapshot.producedNeverCosted')}:</span>{' '}
                            {/* ★【从未分摊渲染 '—',不是 0.00】不适用不是值零 */}
                            <span className="font-medium font-mono">
                                — <span className="text-gray-500">({v.produced.never_costed_qty})</span>
                            </span>
                        </div>
                    </div>
                </section>

                {/* ── 这张报表看不见什么 —— 逐条具名 ─────────────────────── */}
                <section className="mb-4">
                    <h2 className="font-medium mb-2">{t('reports.snapshot.cannotSeeTitle')}</h2>
                    <ul className="list-disc pl-6 text-xs text-gray-600 space-y-1">
                        {Object.entries(v.cannotSee).map(([k, val]) => (
                            <li key={k}>
                                <span className="font-mono">{k}</span>: {Array.isArray(val) ? val.join(' · ') : String(val)}
                            </li>
                        ))}
                    </ul>
                </section>
            </div>
        </>
    )
}
