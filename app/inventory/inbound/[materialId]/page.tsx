// app/inventory/inbound/[materialId]/page.tsx
// 库存钻取:某物料的在库进料批次(未软删 + remaining_qty > 0),按 remaining_qty 降序。
// cut 5:估值(单价 × 剩余)+ 库龄(距到货日,上色提示)。
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { STAGE_OPTIONS, labelKeyForValue } from '@/app/inbound/options'
import { getTranslations } from '@/lib/i18n/server'
import { formatMoneyBare } from '@/lib/format'
import { toneForBucket, AGING_TONE_CLASSES } from '@/lib/valuation'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

type Row = {
    id: string
    code: string
    quantity: number
    remaining_qty: number
    unit: string
    stage: string
    arrival_date: string | null
    suppliers: { legal_name: string } | null
}

// INV-VAL-1:估值视图的一行。landed_* 在没有 data.view_prices 时是 null
// (受限),而 unpriced 说的是"这批货有没有价" —— 两个判据,不许合并。
type Val = {
    id: string
    landed_unit_cost: number | null
    landed_value_base: number | null
    unpriced: boolean
    aging_days: number | null
    aging_bucket: string | null
}

export default async function InboundDrillPage({
    params,
}: {
    params: Promise<{ materialId: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.inventory)
    if (denied) return denied

    const { materialId } = await params
    const supabase = await createClient()
    const t = await getTranslations()

    // INV-VAL-1:行数据仍从遮蔽表取(供应商要内嵌,而视图没有外键),
    // 【钱与库龄档从估值视图取】—— 口径与注销/盘点/勾稽同一份,
    // 档位是 aging_bucket 的结果,屏幕不再自己划边界。
    const [matRes, batchesRes, valRes] = await Promise.all([
        supabase.from('materials').select('name').eq('id', materialId).single(),
        supabase
            .from('inbound_batches_masked')
            .select('id, code, quantity, remaining_qty, unit, stage, arrival_date, suppliers ( legal_name )')
            .eq('material_id', materialId)
            .is('deleted_at', null)
            .gt('remaining_qty', 0)
            .order('remaining_qty', { ascending: false }),
        supabase
            .from('inbound_batch_valuation')
            .select('id, landed_unit_cost, landed_value_base, unpriced, aging_days, aging_bucket')
            .eq('material_id', materialId)
            .gt('remaining_qty', 0),
    ])

    if (matRes.error || !matRes.data) {
        notFound()
    }

    const rows = (batchesRes.data as unknown as Row[] | null) ?? []
    const valById = new Map<string, Val>()
    for (const v of (valRes.data as unknown as Val[] | null) ?? []) valById.set(v.id, v)
    const total = rows.reduce((s, r) => s + r.remaining_qty, 0)
    // 估值汇总:只累计【拿得到到岸成本】的批次;未计价的单独计数提示。
    const totalValue = rows.reduce(
        (s, r) => s + (valById.get(r.id)?.landed_value_base ?? 0),
        0
    )
    // 【判据是 unpriced,不是"金额取不到"】受限读者的 landed_* 全是 null,
    // 拿它当未计价,这个徽标会对 operations 报出"全部未计价"—— 一句假话。
    const unpricedCount = rows.filter((r) => valById.get(r.id)?.unpriced === true).length

    const stageLabel = (v: string) => {
        const k = labelKeyForValue(STAGE_OPTIONS, v)
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

            {/* 汇总行:剩余合计 + 库存价值(已计价部分)+ 未计价批数 */}
            <p className="text-sm mb-3">
                <span className="text-gray-600 mr-1">{t('inventory.drill.sumLabel')}:</span>
                <span className="font-mono">{total}</span>
                <span className="mx-2 text-gray-300">·</span>
                <span className="text-gray-600 mr-1">{t('valuation.colStockValue')}:</span>
                <span className="font-mono">{formatMoneyBare(totalValue, '紧挨着的行标签「库存价值 (SGD)」')}</span>
                {unpricedCount > 0 && (
                    <span className="ml-2 text-gray-400">
                        {t('valuation.unpricedCount', { n: unpricedCount })}
                    </span>
                )}
            </p>

            <table className="w-full border-collapse border border-gray-300">
                <thead className="bg-gray-100">
                    <tr>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('inbound.colCode')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('inbound.colSupplier')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('inbound.colQuantity')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('inbound.colRemaining')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('inbound.colStage')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('inbound.colArrivalDate')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('valuation.colUnitPrice')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('valuation.colBatchValue')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('valuation.colAge')}</th>
                    </tr>
                </thead>
                <tbody>
                    {rows.map((r) => {
                        const v = valById.get(r.id)
                        const days = v?.aging_days ?? null
                        const tone = toneForBucket(v?.aging_bucket ?? null)
                        return (
                            <tr key={r.id}>
                                <td className="border border-gray-300 px-4 py-2 font-mono text-sm">
                                    <Link href={`/inbound/${r.id}/edit`} className="text-blue-600 hover:underline">
                                        {r.code}
                                    </Link>
                                </td>
                                <td className="border border-gray-300 px-4 py-2">{r.suppliers?.legal_name ?? '—'}</td>
                                <td className="border border-gray-300 px-4 py-2">{r.quantity} {r.unit}</td>
                                <td className="border border-gray-300 px-4 py-2">{r.remaining_qty} {r.unit}</td>
                                <td className="border border-gray-300 px-4 py-2">
                                    <span className="px-2 py-1 bg-gray-200 rounded text-xs">{stageLabel(r.stage)}</span>
                                </td>
                                <td className="border border-gray-300 px-4 py-2">{r.arrival_date ?? '—'}</td>
                                <td className="border border-gray-300 px-4 py-2">
                                    {v?.landed_unit_cost != null ? (
                                        formatMoneyBare(v.landed_unit_cost, '列头「到岸单位成本 (SGD)」')
                                    ) : (
                                        <span className="text-gray-400">
                                            {v?.unpriced ? t('valuation.unpriced') : t('valuation.priceRestricted')}
                                        </span>
                                    )}
                                </td>
                                <td className="border border-gray-300 px-4 py-2">
                                    {v?.landed_value_base != null
                                        ? formatMoneyBare(v.landed_value_base, '列头「批次价值 (SGD)」')
                                        : '—'}
                                </td>
                                <td className="border border-gray-300 px-4 py-2">
                                    {days !== null && tone !== null ? (
                                        <span className={'px-2 py-1 rounded text-xs ' + AGING_TONE_CLASSES[tone]}>
                                            {days}
                                        </span>
                                    ) : (
                                        '—'
                                    )}
                                </td>
                            </tr>
                        )
                    })}
                    {rows.length === 0 && (
                        <tr>
                            <td colSpan={9} className="border border-gray-300 px-4 py-8 text-center text-gray-500">
                                {t('inventory.emptyState')}
                            </td>
                        </tr>
                    )}
                </tbody>
            </table>
        </div>
    )
}
