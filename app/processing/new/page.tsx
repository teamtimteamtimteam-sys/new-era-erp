// app/processing/new/page.tsx
// 服务端组件:抓取可选投料批次 + 物料列表,渲染客户端表单
import { createClient } from '@/lib/supabase/server'
import NewProcessingForm, { type InboundBatchOption, type OperationOption } from './NewProcessingForm'
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
    const [batchesRes, outputBatchesRes, materialsRes, settingsRes, workOrdersRes] = await Promise.all([
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
        // WO-1c:【只列已放行的工单】草稿是还没答应的事,已收工/已取消是已经结束的事 ——
        // 服务端会按名拒(WO_NOT_RELEASED),而这里不把一个必然被拒的选项画出来
        // (AGENTS.md:页面不该提供一个服务端保证会拒绝的动作)。
        supabase.from('work_orders').select('id, code, scheduled_date')
            .eq('status', 'released').order('code'),
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
    // PROC-WIRE-1B-i:五道工序,连同它们【收什么形态】与【产不产批】。
    // 【嵌进来读,不在这里写死】加一道工序或者改它收什么,是加一行数据。
    const operationsRes = await supabase
        .from('operation_types')
        .select('code, name_en, name_zh, operation_kinds ( produces_outputs ), ' +
                'operation_type_input_forms ( material_forms ( code, name_en, name_zh ) )')
        .eq('is_active', true)
        .order('sort_order')
    const operations: OperationOption[] = (mustRows(operationsRes, 'operation_types') as unknown as {
        code: string; name_en: string; name_zh: string
        operation_kinds: { produces_outputs: boolean } | null
        operation_type_input_forms: { material_forms: { code: string; name_en: string; name_zh: string } | null }[]
    }[]).map((o) => ({
        code: o.code,
        name_en: o.name_en,
        name_zh: o.name_zh,
        // 【读不到种类就当它产出】与服务端的默认方向一致(没有工序类型 = 今天的行为),
        // 而真正的权威是 commit_processing_run,不是这一屏。
        produces_outputs: o.operation_kinds?.produces_outputs ?? true,
        input_forms: o.operation_type_input_forms
            .map((r) => r.material_forms)
            .filter((f): f is { code: string; name_en: string; name_zh: string } => f !== null),
    }))

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
            workOrders={mustRows(workOrdersRes, 'work_orders') as unknown as
                { id: string; code: string; scheduled_date: string | null }[]}
            operations={operations}
        />
    )
}
