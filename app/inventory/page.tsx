// app/inventory/page.tsx
// 库存与物料平衡(只读,JS 聚合)
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { CATEGORY_OPTIONS, UNIT_OPTIONS, labelKeyForValue } from '@/app/materials/options'

type MaterialEmbed = { name: string; category: string } | null

// FK 嵌入运行时是对象;显式类型 + cast 锁住。
type StockRow = {
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
}

// 混合单位的内部 sentinel(聚合逻辑用,显示时映射到 i18n)
const MIXED_UNIT = '⚠️混合'

export default async function InventoryPage() {
    const supabase = await createClient()
    const t = await getTranslations()

    const [inboundRes, outputRes, runsRes] = await Promise.all([
        supabase
            .from('inbound_batches')
            .select('material_id, remaining_qty, unit, materials ( name, category )')
            .is('deleted_at', null)
            .gt('remaining_qty', 0),
        supabase
            .from('output_batches')
            .select('material_id, remaining_qty, unit, materials ( name, category )')
            .is('deleted_at', null)
            .gt('remaining_qty', 0),
        supabase
            .from('processing_runs')
            .select('total_input, total_output, loss_qty')
            .is('deleted_at', null),
    ])

    if (inboundRes.error || outputRes.error || runsRes.error) {
        const err = inboundRes.error ?? outputRes.error ?? runsRes.error
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

    const inbound = (inboundRes.data as unknown as StockRow[] | null) ?? []
    const output = (outputRes.data as unknown as StockRow[] | null) ?? []
    const runs = runsRes.data ?? []

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
        }
        rowsByMaterial.set(materialId, fresh)
        return fresh
    }

    for (const b of inbound) {
        const row = ensureRow(b.material_id, b.materials, b.unit)
        row.inboundStock += b.remaining_qty
    }
    for (const b of output) {
        const row = ensureRow(b.material_id, b.materials, b.unit)
        row.outputStock += b.remaining_qty
    }

    const rows = Array.from(rowsByMaterial.values())
    rows.sort((a, b) => (a.name ?? '').localeCompare(b.name ?? '', 'zh-CN'))

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
            <h1 className="text-2xl font-bold">{t('inventory.listTitle')}</h1>

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
                <table className="w-full border-collapse border border-gray-300">
                    <thead className="bg-gray-100">
                        <tr>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('inventory.colMaterial')}</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('inventory.colCategory')}</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('inventory.colInboundStock')}</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('inventory.colOutputStock')}</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('inventory.colUnit')}</th>
                        </tr>
                    </thead>
                    <tbody>
                        {rows.map((r) => (
                            <tr key={r.material_id}>
                                <td className="border border-gray-300 px-4 py-2">{r.name ?? '—'}</td>
                                <td className="border border-gray-300 px-4 py-2">{categoryLabel(r.category)}</td>
                                <td className="border border-gray-300 px-4 py-2">{r.inboundStock}</td>
                                <td className="border border-gray-300 px-4 py-2">{r.outputStock}</td>
                                <td className="border border-gray-300 px-4 py-2">{unitLabel(r.unit)}</td>
                            </tr>
                        ))}
                        {rows.length === 0 && (
                            <tr>
                                <td
                                    colSpan={5}
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
