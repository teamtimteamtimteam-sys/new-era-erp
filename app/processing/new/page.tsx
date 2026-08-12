// app/processing/new/page.tsx
// 服务端组件:抓取可选投料批次 + 物料列表,渲染客户端表单
import { createClient } from '@/lib/supabase/server'
import NewProcessingForm, { type InboundBatchOption } from './NewProcessingForm'
import { getTranslations } from '@/lib/i18n/server'
import { mustOne, mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

export default async function NewProcessingPage() {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.processing)
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()

    // FIN-36:分摊基准的【预选值】来自配置,不是编在代码里的常量 ——
    // 与 fy_end_month / system_start_date 同一形状。表单显示它、允许改,
    // 并把选中的值显式送给 commit_processing_run(那边必填)。
    const [batchesRes, outputBatchesRes, materialsRes, settingsRes] = await Promise.all([
        supabase
            .from('inbound_batches')
            .select('id, code, remaining_qty, unit, materials ( name )')
            .is('deleted_at', null)
            .gt('remaining_qty', 0) // 只看还有库存的批次
            .order('code'),
        // FIN-25:再加工 —— 有库存的产出批也可投料
        supabase
            .from('output_batches')
            .select('id, code, remaining_qty, unit, materials ( name )')
            .is('deleted_at', null)
            .gt('remaining_qty', 0)
            .order('code'),
        supabase
            .from('materials')
            .select('id, code, name')
            .is('deleted_at', null)
            .order('name'),
        supabase.from('finance_settings').select('default_allocation_basis').maybeSingle(),
    ])

    if (batchesRes.error || outputBatchesRes.error || materialsRes.error) {
        const err = batchesRes.error ?? outputBatchesRes.error ?? materialsRes.error
        return (
            <div className="p-8 max-w-2xl">
                <h1 className="text-2xl font-bold mb-4">{t('processing.newTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('processing.dropdownLoadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(err, null, 2)}</pre>
                </div>
            </div>
        )
    }

    // IOD-1:每个批次的【可用】(available 桶之和)。投得进去的是可用,不是
    // 物理剩余 —— 被扣住的货还在批次里但不可动用。表单必须显示可用,否则人
    // 按 remaining 填了数,提交才被 IOD_CONSUME_EXCEEDS_AVAILABLE 拦下,
    // 而屏幕上此前没有任何提示。问库,页面不算账。
    const availRows = mustRows(
        await supabase
            .from('stock_by_status')
            .select('inbound_batch_id, output_batch_id, qty')
            .eq('stock_status', 'available'),
        'stock_by_status'
    ) as unknown as { inbound_batch_id: string | null; output_batch_id: string | null; qty: number }[]
    const availByBatch = new Map<string, number>()
    for (const r of availRows) {
        const k = r.inbound_batch_id ?? r.output_batch_id
        if (k) availByBatch.set(k, (availByBatch.get(k) ?? 0) + Number(r.qty))
    }
    const withAvailable = (rows: InboundBatchOption[] | null) =>
        (rows ?? []).map((b) => ({ ...b, available_qty: availByBatch.get(b.id) ?? 0 }))

    return (
        <NewProcessingForm
            inboundBatches={withAvailable(batchesRes.data as unknown as InboundBatchOption[] | null)}
            outputBatches={withAvailable(outputBatchesRes.data as unknown as InboundBatchOption[] | null)}
            materials={mustRows(materialsRes)}
            defaultAllocationBasis={
                mustOne(settingsRes, 'finance_settings')?.default_allocation_basis ?? 'metal_value'
            }
        />
    )
}
