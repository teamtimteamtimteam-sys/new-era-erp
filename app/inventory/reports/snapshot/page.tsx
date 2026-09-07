// RPT-1:库存快照(物料 × 库位 × 状态)+ INV-VAL-1 的金额与库龄两节。
// 【未指定库位与任何一个库位一样,是一个普通分组】—— 线上 99/106 行流水没有库位。
//
// CONV-5:B 节与 C 节两张表换成 DataTable;产出侧与「看不见什么」两节是报告体,
// 不是登记簿,保持原样(Tim 在 CONV-5 Q2 的裁定)。
// ★ 这一页按库位分的组【不是】CONV-4 §⑨-2 那个缺口 —— 理由写在 SnapshotTables.tsx
//   抬头,一句话:它是"一段一张完整的表",不是"一张表里夹分组行与小计行"。
// ★ state 恒为 'ok' —— 合计条、受限告示与两句 note 必须无条件出现。
//
// ★【金额列对读不到价的人印【受限】,不是 0.00】★ operations 与 warehouse
// 实测有 module.inventory.view、没有 data.view_prices —— 他们正是这张报表
// 最主要的读者。一个悄悄少算的合计会被抄进决策;"受限"两个字会让人去要权限。
import { getTranslations } from '@/lib/i18n/server'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { formatAmount, formatMoneyBare } from '@/lib/format'
import { fetchValuation, groupByLocation, statusKey, bucketKey } from './snapshotQuery'
import { ListPage } from '@/app/components/ui/list-page'
import { SnapshotGroupTable, AgeingTable, type SnapshotRow, type AgeingRow } from './SnapshotTables'
import { Button } from '@/app/components/ui/button'

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
        <ListPage
            title={t('reports.snapshot.title')}
            intro={t('reports.snapshot.desc')}
            actions={
                <div className="flex gap-2">
                    <Button asChild variant="outline" size="sm">
                        <a href="/inventory/reports/snapshot/export">{t('reports.csv')}</a>
                    </Button>
                    <Button asChild variant="outline" size="sm">
                        <a href="/inventory/reports/snapshot/pdf" target="_blank" rel="noopener noreferrer">{t('reports.pdf')}</a>
                    </Button>
                </div>
            }
            state={{ kind: 'ok' }}
        >
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
                            <SnapshotGroupTable
                                rows={g.rows.map((r, i): SnapshotRow => ({
                                    key: String(i),
                                    materialCode: r.material_code,
                                    materialName: r.material_name,
                                    kindLabel: t(r.batch_kind === 'inbound' ? 'reports.kindInbound' : 'reports.kindOutput'),
                                    statusLabel: t(statusKey(r.stock_status)),
                                    qty: `${r.qty} ${r.unit}`,
                                    value: money(r.value_base),
                                    uncosted: r.uncosted_qty !== 0 ? `${r.uncosted_qty} ${r.unit}` : '—',
                                }))}
                            />
                        </section>
                    ))
                )}

                {/* ── C 节:库龄。档位定义在 DB 的 aging_bucket,这里只翻译 ── */}
                <section className="mb-8">
                    <h2 className="font-medium mb-2">{t('reports.snapshot.ageingTitle')}</h2>
                    <p className="text-xs text-gray-500 mb-2">{t('reports.snapshot.ageingNote')}</p>
                    <AgeingTable
                        rows={v.ageing.map((a): AgeingRow => ({
                            bucket: a.bucket,
                            bandLabel: t(bucketKey(a.bucket)),
                            batches: a.batches,
                            qty: String(a.qty),
                            value: money(a.value_base),
                        }))}
                    />
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
        </ListPage>
    )
}
