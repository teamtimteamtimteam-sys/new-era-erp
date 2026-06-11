// app/inventory/page.tsx
// 库存与物料平衡(只读,JS 聚合)
import { createClient } from '@/lib/supabase/server'

type MaterialEmbed = { name: string; category: string } | null

type InventoryRow = {
    material_id: string
    name: string | null
    category: string | null
    unit: string
    inboundStock: number
    outputStock: number
}

export default async function InventoryPage() {
    const supabase = await createClient()

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
                <h1 className="text-2xl font-bold mb-4">库存与物料平衡 (Inventory)</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">读取失败</p>
                    <pre className="text-xs mt-2">{JSON.stringify(err, null, 2)}</pre>
                </div>
            </div>
        )
    }

    const inbound = inboundRes.data ?? []
    const output = outputRes.data ?? []
    const runs = runsRes.data ?? []

    // 注意:Supabase 把 M:1 嵌入资源有时推断为对象,有时为数组。
    // 如果 TS 报错说 b.materials 是数组,把 b.materials 改成 b.materials?.[0]。

    // 按 material_id 聚合
    const rowsByMaterial = new Map<string, InventoryRow>()

    function ensureRow(
        materialId: string,
        embed: MaterialEmbed,
        unit: string
    ): InventoryRow {
        const existing = rowsByMaterial.get(materialId)
        if (existing) {
            if (existing.unit !== '⚠️混合' && existing.unit !== unit) {
                existing.unit = '⚠️混合'
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

    return (
        <div className="p-8 space-y-6">
            <h1 className="text-2xl font-bold">库存与物料平衡 (Inventory)</h1>

            {/* 物料平衡 */}
            <section>
                <h2 className="text-lg font-semibold mb-2">物料平衡(全部加工单)</h2>
                <div className="bg-gray-50 rounded p-4 flex flex-wrap gap-8 text-sm">
                    <div>
                        <span className="text-gray-600">总投入:</span>{' '}
                        <span className="font-medium">{balInput}</span>
                    </div>
                    <div>
                        <span className="text-gray-600">总产出:</span>{' '}
                        <span className="font-medium">{balOutput}</span>
                    </div>
                    <div>
                        <span className="text-gray-600">总损耗:</span>{' '}
                        <span className="font-medium">{balLoss}</span>
                        {lossRate && (
                            <span className="text-gray-500"> ({lossRate}%)</span>
                        )}
                    </div>
                    <div>
                        <span className="text-gray-600">加工单数:</span>{' '}
                        <span className="font-medium">{runs.length}</span>
                    </div>
                </div>
            </section>

            {/* 当前库存 */}
            <section>
                <h2 className="text-lg font-semibold mb-2">当前库存(按物料)</h2>
                <table className="w-full border-collapse border border-gray-300">
                    <thead className="bg-gray-100">
                        <tr>
                            <th className="border border-gray-300 px-4 py-2 text-left">物料</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">类别</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">原料库存</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">成品库存</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">单位</th>
                        </tr>
                    </thead>
                    <tbody>
                        {rows.map((r) => (
                            <tr key={r.material_id}>
                                <td className="border border-gray-300 px-4 py-2">{r.name ?? '—'}</td>
                                <td className="border border-gray-300 px-4 py-2">{r.category ?? '—'}</td>
                                <td className="border border-gray-300 px-4 py-2">{r.inboundStock}</td>
                                <td className="border border-gray-300 px-4 py-2">{r.outputStock}</td>
                                <td className="border border-gray-300 px-4 py-2">{r.unit}</td>
                            </tr>
                        ))}
                        {rows.length === 0 && (
                            <tr>
                                <td
                                    colSpan={5}
                                    className="border border-gray-300 px-4 py-8 text-center text-gray-500"
                                >
                                    暂无库存
                                </td>
                            </tr>
                        )}
                    </tbody>
                </table>
                <p className="text-xs text-gray-500 mt-2">
                    原料库存 = 进料批次剩余量合计;成品库存 = 产出批次剩余量合计(剩余量 &gt; 0 的批次)
                </p>
            </section>
        </div>
    )
}
