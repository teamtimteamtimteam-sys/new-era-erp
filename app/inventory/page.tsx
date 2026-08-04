// app/inventory/page.tsx
// 库存与物料平衡(只读,JS 聚合)
// cut 5:估值 —— 原料按 unit_price(加权均价 + 库存价值),成品按产出腿成本 + 金属市价。
// 快照页,不做日期筛选(既定约定)。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { CATEGORY_OPTIONS, UNIT_OPTIONS, labelKeyForValue } from '@/app/materials/options'
import { formatMoney } from '@/lib/format'
import { latestPriceByMetal, marketValuePerKg } from '@/lib/valuation'
import { maskedRows } from '@/lib/maskedRows'
import type { Tables } from '@/lib/database.types'

type MaterialEmbed = { name: string; category: string } | null

// FK 嵌入运行时是对象;显式类型 + cast 锁住。
type InboundStockRow = {
    material_id: string
    remaining_qty: number
    unit: string
    unit_price: number | null
    materials: MaterialEmbed
}

type OutputStockRow = {
    id: string
    material_id: string
    remaining_qty: number
    unit: string
    materials: MaterialEmbed
}

type InventoryRow = {
    material_id: string
    name: string | null
    category: string | null
    unit: string
    inboundStock: number
    outputStock: number
    pricedQty: number // 已计价进料批次的剩余合计(加权均价分母)
    stockValue: number | null // Σ 剩余 × 单价;该物料无已计价批次为 null
    costValue: number | null // Σ 剩余 × 产出腿单位成本;无成本批次为 null
    marketValue: number | null // Σ 批次市价;无可市价批次为 null
}

// 混合单位的内部 sentinel(聚合逻辑用,显示时映射到 i18n)
const MIXED_UNIT = '⚠️混合'

export default async function InventoryPage() {
    const supabase = await createClient()
    const t = await getTranslations()

    const todayYmd = new Date().toISOString().slice(0, 10)

    const [inboundRes, outputRes, runsRes, legsRes, metalsRes, pricesRes, unpricedRes] = await Promise.all([
        supabase
            .from('inbound_batches_masked')
            .select('material_id, remaining_qty, unit, unit_price, materials ( name, category )')
            .is('deleted_at', null)
            .gt('remaining_qty', 0),
        supabase
            .from('output_batches')
            .select('id, material_id, remaining_qty, unit, materials ( name, category )')
            .is('deleted_at', null)
            .gt('remaining_qty', 0),
        supabase
            .from('processing_runs')
            .select('total_input, total_output, loss_qty')
            .is('deleted_at', null),
        // 产出腿:批次 → 单位成本(一个批次至多一条产出腿)
        supabase
            .from('processing_outputs_masked')
            .select('output_batch_id, unit_cost_base'),
        // 金属含量(assay):批次 → 各金属含量
        supabase
            .from('output_batch_metals')
            .select('output_batch_id, metal, content_pct'),
        // 每金属的最新有效价(只取今天及以前,忽略预登的未来价)
        supabase
            .from('metal_prices')
            .select('metal, price_usd_per_tonne, price_date')
            .is('deleted_at', null)
            .lte('price_date', todayYmd),
        // 未计价的在册进料批次数(与进料列表页同口径的提示徽标)
        supabase
            .from('inbound_batches_masked')
            .select('id', { count: 'exact', head: true })
            .is('deleted_at', null)
            .is('unit_price', null),
    ])

    if (inboundRes.error || outputRes.error || runsRes.error || legsRes.error || metalsRes.error || pricesRes.error) {
        const err =
            inboundRes.error ?? outputRes.error ?? runsRes.error ??
            legsRes.error ?? metalsRes.error ?? pricesRes.error
        return (
            <div className="p-8">
                <h1 className="text-2xl font-bold mb-4">{t('inventory.listTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('inventory.loadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(err, null, 2)}</pre>
                </div>
            </div>
        )
    }

    const inbound = (inboundRes.data as unknown as InboundStockRow[] | null) ?? []
    const output = (outputRes.data as unknown as OutputStockRow[] | null) ?? []
    const runs = runsRes.data ?? []

    // 批次 → 单位成本 / 金属含量;金属 → 最新价
    const legCostByBatch = new Map<string, number>()
    // unit_cost_base 会被遮蔽(没有 data.view_prices 时为 null);其余列不会。
    for (const leg of maskedRows<Tables<'processing_outputs'>, 'unit_cost_base'>(legsRes.data)) {
        if (leg.unit_cost_base !== null) legCostByBatch.set(leg.output_batch_id, leg.unit_cost_base)
    }
    const metalsByBatch = new Map<string, { metal: string; content_pct: number }[]>()
    for (const m of metalsRes.data ?? []) {
        const list = metalsByBatch.get(m.output_batch_id)
        if (list) list.push(m)
        else metalsByBatch.set(m.output_batch_id, [m])
    }
    const priceByMetal = latestPriceByMetal(pricesRes.data ?? [])

    // 按 material_id 聚合
    const rowsByMaterial = new Map<string, InventoryRow>()

    function ensureRow(
        materialId: string,
        embed: MaterialEmbed,
        unit: string
    ): InventoryRow {
        const existing = rowsByMaterial.get(materialId)
        if (existing) {
            if (existing.unit !== MIXED_UNIT && existing.unit !== unit) {
                existing.unit = MIXED_UNIT
            }
            return existing
        }
        const fresh: InventoryRow = {
            material_id: materialId,
            name: embed?.name ?? null,
            category: embed?.category ?? null,
            unit,
            inboundStock: 0,
            outputStock: 0,
            pricedQty: 0,
            stockValue: null,
            costValue: null,
            marketValue: null,
        }
        rowsByMaterial.set(materialId, fresh)
        return fresh
    }

    for (const b of inbound) {
        const row = ensureRow(b.material_id, b.materials, b.unit)
        row.inboundStock += b.remaining_qty
        if (b.unit_price !== null) {
            row.pricedQty += b.remaining_qty
            row.stockValue = (row.stockValue ?? 0) + b.remaining_qty * b.unit_price
        }
    }
    for (const b of output) {
        const row = ensureRow(b.material_id, b.materials, b.unit)
        row.outputStock += b.remaining_qty

        const unitCost = legCostByBatch.get(b.id)
        if (unitCost !== undefined) {
            row.costValue = (row.costValue ?? 0) + b.remaining_qty * unitCost
        }
        const perKg = marketValuePerKg(metalsByBatch.get(b.id) ?? [], priceByMetal)
        if (perKg !== null) {
            row.marketValue = (row.marketValue ?? 0) + b.remaining_qty * perKg
        }
    }

    const rows = Array.from(rowsByMaterial.values())
    rows.sort((a, b) => (a.name ?? '').localeCompare(b.name ?? '', 'zh-CN'))

    // 估值合计(三个口径分开:原料按单价、成品按成本、成品按市价)
    const totalInboundValue = rows.reduce((s, r) => s + (r.stockValue ?? 0), 0)
    const totalCostValue = rows.reduce((s, r) => s + (r.costValue ?? 0), 0)
    const totalMarketValue = rows.reduce((s, r) => s + (r.marketValue ?? 0), 0)

    // 物料平衡合计
    const balInput = runs.reduce((s, r) => s + (r.total_input ?? 0), 0)
    const balOutput = runs.reduce((s, r) => s + (r.total_output ?? 0), 0)
    const balLoss = runs.reduce((s, r) => s + (r.loss_qty ?? 0), 0)
    const lossRate = balInput > 0 ? ((balLoss / balInput) * 100).toFixed(1) : null

    // 类别存储值反查成本地化文案;自定义/未知值原样显示
    const categoryLabel = (value: string | null) => {
        if (!value) return '—'
        const key = labelKeyForValue(CATEGORY_OPTIONS, value)
        return key ? t(key) : value
    }

    // 单位:混合 sentinel → i18n;真实单位 → units.* 反查;未知值原样
    const unitLabel = (value: string) => {
        if (value === MIXED_UNIT) return t('inventory.mixedUnit')
        const key = labelKeyForValue(UNIT_OPTIONS, value)
        return key ? t(key) : value
    }

    return (
        <div className="p-8 space-y-6">
            <div>
                <h1 className="text-2xl font-bold">{t('inventory.listTitle')}</h1>
                <p className="text-sm text-gray-500 mt-1">{t('inventory.ledgerNote')}</p>
            </div>

            {/* 物料平衡 */}
            <section>
                <h2 className="text-lg font-semibold mb-2">{t('inventory.balanceSectionHeader')}</h2>
                <div className="bg-gray-50 rounded p-4 flex flex-wrap gap-8 text-sm">
                    <div>
                        <span className="text-gray-600">{t('inventory.balTotalInput')}</span>{' '}
                        <span className="font-medium">{balInput}</span>
                    </div>
                    <div>
                        <span className="text-gray-600">{t('inventory.balTotalOutput')}</span>{' '}
                        <span className="font-medium">{balOutput}</span>
                    </div>
                    <div>
                        <span className="text-gray-600">{t('inventory.balTotalLoss')}</span>{' '}
                        <span className="font-medium">{balLoss}</span>
                        {lossRate && (
                            <span className="text-gray-500"> ({lossRate}%)</span>
                        )}
                    </div>
                    <div>
                        <span className="text-gray-600">{t('inventory.balRunCount')}</span>{' '}
                        <span className="font-medium">{runs.length}</span>
                    </div>
                </div>
            </section>

            {/* 当前库存 */}
            <section>
                <h2 className="text-lg font-semibold mb-2">{t('inventory.stockSectionHeader')}</h2>

                {/* 估值合计条 */}
                <div className="bg-gray-50 rounded p-4 flex flex-wrap gap-8 text-sm mb-3">
                    <div>
                        <span className="text-gray-600">{t('valuation.totalInboundValue')}:</span>{' '}
                        <span className="font-medium font-mono">{formatMoney(totalInboundValue)}</span>
                    </div>
                    <div>
                        <span className="text-gray-600">{t('valuation.totalCostValue')}:</span>{' '}
                        <span className="font-medium font-mono">{formatMoney(totalCostValue)}</span>
                    </div>
                    <div>
                        <span className="text-gray-600">{t('valuation.totalMarketValue')}:</span>{' '}
                        <span className="font-medium font-mono">{formatMoney(totalMarketValue)}</span>
                    </div>
                    {(unpricedRes.count ?? 0) > 0 && (
                        <div className="text-gray-400">
                            {t('inbound.unpricedBadge', { n: unpricedRes.count ?? 0 })}
                        </div>
                    )}
                </div>

                <table className="w-full border-collapse border border-gray-300">
                    <thead className="bg-gray-100">
                        <tr>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('inventory.colMaterial')}</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('inventory.colCategory')}</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('inventory.colInboundStock')}</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('valuation.colAvgPrice')}</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('valuation.colStockValue')}</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('inventory.colOutputStock')}</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('valuation.colCostValue')}</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('valuation.colMarketValue')}</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('inventory.colUnit')}</th>
                        </tr>
                    </thead>
                    <tbody>
                        {rows.map((r) => (
                            <tr key={r.material_id}>
                                <td className="border border-gray-300 px-4 py-2">{r.name ?? '—'}</td>
                                <td className="border border-gray-300 px-4 py-2">{categoryLabel(r.category)}</td>
                                <td className="border border-gray-300 px-4 py-2">
                                    {r.inboundStock > 0 ? (
                                        <Link
                                            href={`/inventory/inbound/${r.material_id}`}
                                            className="text-blue-600 hover:underline"
                                        >
                                            {r.inboundStock}
                                        </Link>
                                    ) : (
                                        r.inboundStock
                                    )}
                                </td>
                                <td className="border border-gray-300 px-4 py-2">
                                    {r.pricedQty > 0 && r.stockValue !== null
                                        ? formatMoney(r.stockValue / r.pricedQty)
                                        : '—'}
                                </td>
                                <td className="border border-gray-300 px-4 py-2">
                                    {r.stockValue !== null ? formatMoney(r.stockValue) : '—'}
                                </td>
                                <td className="border border-gray-300 px-4 py-2">
                                    {r.outputStock > 0 ? (
                                        <Link
                                            href={`/inventory/output/${r.material_id}`}
                                            className="text-blue-600 hover:underline"
                                        >
                                            {r.outputStock}
                                        </Link>
                                    ) : (
                                        r.outputStock
                                    )}
                                </td>
                                <td className="border border-gray-300 px-4 py-2">
                                    {r.costValue !== null ? formatMoney(r.costValue) : '—'}
                                </td>
                                <td className="border border-gray-300 px-4 py-2">
                                    {r.marketValue !== null ? formatMoney(r.marketValue) : '—'}
                                </td>
                                <td className="border border-gray-300 px-4 py-2">{unitLabel(r.unit)}</td>
                            </tr>
                        ))}
                        {rows.length === 0 && (
                            <tr>
                                <td
                                    colSpan={9}
                                    className="border border-gray-300 px-4 py-8 text-center text-gray-500"
                                >
                                    {t('inventory.emptyState')}
                                </td>
                            </tr>
                        )}
                    </tbody>
                </table>
                <p className="text-xs text-gray-500 mt-2">
                    {t('inventory.footerNote')}
                </p>
            </section>
        </div>
    )
}
