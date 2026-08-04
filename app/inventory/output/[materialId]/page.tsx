// app/inventory/output/[materialId]/page.tsx
// 库存钻取:某物料的在库产出批次(未软删 + remaining_qty > 0),按 remaining_qty 降序。
// cut 5:成本估值(产出腿的 unit_cost_base)+ 市价估值(assay 含量 × 最新金属价)+ 库龄。
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { STATE_OPTIONS, labelKeyForValue } from '@/app/inbound/options'
import { getTranslations } from '@/lib/i18n/server'
import { formatMoney, formatUnitCost } from '@/lib/format'
import { mustRows } from '@/lib/db-helpers'
import {
    agingDays,
    agingTone,
    AGING_TONE_CLASSES,
    latestPriceByMetal,
    marketValuePerKg,
} from '@/lib/valuation'

type Row = {
    id: string
    code: string
    quantity: number
    remaining_qty: number
    unit: string
    state: string
    output_date: string | null
    customers: { legal_name: string } | null
    // 反向 FK 嵌入是数组:一个批次至多一条产出腿;金属含量 0..n 条
    processing_outputs: { unit_cost_base: number | null }[]
    output_batch_metals: { metal: string; content_pct: number }[]
}

export default async function OutputDrillPage({
    params,
}: {
    params: Promise<{ materialId: string }>
}) {
    const { materialId } = await params
    const supabase = await createClient()
    const t = await getTranslations()

    const todayYmd = new Date().toISOString().slice(0, 10)

    const [matRes, batchesRes, pricesRes] = await Promise.all([
        supabase.from('materials').select('name').eq('id', materialId).single(),
        supabase
            .from('output_batches')
            .select(
                'id, code, quantity, remaining_qty, unit, state, output_date, customers ( legal_name ), processing_outputs ( unit_cost_base ), output_batch_metals ( metal, content_pct )'
            )
            .eq('material_id', materialId)
            .is('deleted_at', null)
            .gt('remaining_qty', 0)
            .order('remaining_qty', { ascending: false }),
        // 每金属的最新有效价(只取今天及以前,忽略预登的未来价)
        supabase
            .from('metal_prices')
            .select('metal, price_usd_per_tonne, price_date')
            .is('deleted_at', null)
            .lte('price_date', todayYmd),
    ])

    if (matRes.error || !matRes.data) {
        notFound()
    }

    const rows = (batchesRes.data as unknown as Row[] | null) ?? []
    const priceByMetal = latestPriceByMetal(mustRows(pricesRes))

    // 每行估值:成本 = 剩余 × 产出腿单位成本;市价 = 剩余 × 每公斤金属市价
    const valued = rows.map((r) => {
        const unitCost = r.processing_outputs[0]?.unit_cost_base ?? null
        const perKg = marketValuePerKg(r.output_batch_metals, priceByMetal)
        return {
            ...r,
            unitCost,
            costValue: unitCost !== null ? r.remaining_qty * unitCost : null,
            marketValue: perKg !== null ? r.remaining_qty * perKg : null,
            ageDays: agingDays(r.output_date),
        }
    })

    const total = valued.reduce((s, r) => s + r.remaining_qty, 0)
    const totalCostValue = valued.reduce((s, r) => s + (r.costValue ?? 0), 0)
    const totalMarketValue = valued.reduce((s, r) => s + (r.marketValue ?? 0), 0)
    const noCostCount = valued.filter((r) => r.costValue === null).length
    const noMarketCount = valued.filter((r) => r.marketValue === null).length

    const stateLabel = (v: string) => {
        const k = labelKeyForValue(STATE_OPTIONS, v)
        return k ? t(k) : v
    }

    return (
        <div className="p-8">
            <div className="mb-6">
                <Link href="/inventory" className="text-blue-600 hover:underline text-sm">
                    {t('inventory.drill.back')}
                </Link>
            </div>

            <h1 className="text-2xl font-bold mb-4">
                {matRes.data.name} · {t('inventory.drill.title')}
            </h1>

            {/* 汇总行:剩余合计 + 成本价值 + 市价价值(+ 无成本/无市价批数) */}
            <p className="text-sm mb-3">
                <span className="text-gray-600 mr-1">{t('inventory.drill.sumLabel')}:</span>
                <span className="font-mono">{total}</span>
                <span className="mx-2 text-gray-300">·</span>
                <span className="text-gray-600 mr-1">{t('valuation.colCostValue')}:</span>
                <span className="font-mono">{formatMoney(totalCostValue)}</span>
                <span className="mx-2 text-gray-300">·</span>
                <span className="text-gray-600 mr-1">{t('valuation.colMarketValue')}:</span>
                <span className="font-mono">{formatMoney(totalMarketValue)}</span>
                {noCostCount > 0 && (
                    <span className="ml-2 text-gray-400">
                        {t('valuation.noCostCount', { n: noCostCount })}
                    </span>
                )}
                {noMarketCount > 0 && (
                    <span className="ml-2 text-gray-400">
                        {t('valuation.noMarketCount', { n: noMarketCount })}
                    </span>
                )}
            </p>

            <table className="w-full border-collapse border border-gray-300">
                <thead className="bg-gray-100">
                    <tr>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('output.colCode')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('output.colCustomer')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('output.colQuantity')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('output.colRemaining')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('output.colState')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('output.colOutputDate')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('valuation.colUnitCost')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('valuation.colCostValue')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('valuation.colMarketValue')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('valuation.colAge')}</th>
                    </tr>
                </thead>
                <tbody>
                    {valued.map((r) => {
                        const tone = agingTone(r.ageDays)
                        return (
                            <tr key={r.id}>
                                <td className="border border-gray-300 px-4 py-2 font-mono text-sm">
                                    <Link href={`/output/${r.id}/edit`} className="text-blue-600 hover:underline">
                                        {r.code}
                                    </Link>
                                </td>
                                <td className="border border-gray-300 px-4 py-2">{r.customers?.legal_name ?? '—'}</td>
                                <td className="border border-gray-300 px-4 py-2">{r.quantity} {r.unit}</td>
                                <td className="border border-gray-300 px-4 py-2">{r.remaining_qty} {r.unit}</td>
                                <td className="border border-gray-300 px-4 py-2">
                                    <span className="px-2 py-1 bg-gray-200 rounded text-xs">{stateLabel(r.state)}</span>
                                </td>
                                <td className="border border-gray-300 px-4 py-2">{r.output_date ?? '—'}</td>
                                <td className="border border-gray-300 px-4 py-2">
                                    {r.unitCost !== null ? `${formatUnitCost(r.unitCost)} /kg` : '—'}
                                </td>
                                <td className="border border-gray-300 px-4 py-2">
                                    {r.costValue !== null ? formatMoney(r.costValue) : '—'}
                                </td>
                                <td className="border border-gray-300 px-4 py-2">
                                    {r.marketValue !== null ? formatMoney(r.marketValue) : '—'}
                                </td>
                                <td className="border border-gray-300 px-4 py-2">
                                    {r.ageDays !== null && tone !== null ? (
                                        <span className={'px-2 py-1 rounded text-xs ' + AGING_TONE_CLASSES[tone]}>
                                            {r.ageDays}
                                        </span>
                                    ) : (
                                        '—'
                                    )}
                                </td>
                            </tr>
                        )
                    })}
                    {valued.length === 0 && (
                        <tr>
                            <td colSpan={10} className="border border-gray-300 px-4 py-8 text-center text-gray-500">
                                {t('inventory.emptyState')}
                            </td>
                        </tr>
                    )}
                </tbody>
            </table>
        </div>
    )
}
