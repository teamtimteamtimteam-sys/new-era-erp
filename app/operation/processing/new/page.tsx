// app/operation/processing/new/page.tsx
// 服务端组件:抓取可选投料批次 + 物料列表,渲染客户端表单
import { createClient } from '@/lib/supabase/server'
import NewProcessingForm, {
    type InboundBatchOption, type OperationOption, type FieldOption, type ShiftOption, type WeighingOption, type DeviceOption,
} from './NewProcessingForm'
import { getTranslations } from '@/lib/i18n/server'
import { mustOne, mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { can } from '@/lib/permissions'
import { loadMaterialNames } from '../materialNames'

export default async function NewProcessingPage({
    searchParams,
}: {
    searchParams: Promise<{ corrects?: string }>
}) {
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
            .select('id, code, remaining_qty, unit, material_id')
            .is('deleted_at', null)
            .gt('remaining_qty', 0) // 只看还有库存的批次
            .order('code'),
        // FIN-25:再加工 —— 有库存的产出批也可投料
        // (ROLE-1 Batch 3b:两处批次都不再嵌 materials ( name ),名字在下面从 material_lookup 映射)
        supabase
            .from('output_batches')
            .select('id, code, remaining_qty, unit, material_id')
            .is('deleted_at', null)
            .gt('remaining_qty', 0)
            .order('code'),
        // ROLE-1 Batch 3b:仓库持 processing.view 但不持 materials.view —— 读查名视图,不读基表。
        supabase
            .from('material_lookup')
            .select('id, code, name')
            .is('deleted_at', null)
            .order('name'),
        supabase.from('finance_settings_lookup').select('default_allocation_basis').maybeSingle(),
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
                <h1 className="mb-4">{t('processing.newTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('processing.dropdownLoadError')}</p>
                    <details className="mt-2">
                        <summary className="cursor-pointer text-xs">{t('common.actionMessage.technicalDetail')}</summary>
                        <pre className="mt-1 text-xs">{JSON.stringify(err, null, 2)}</pre>
                    </details>
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
    // MES-4a(Q9 · Q10–Q16):每道工序挂着的机器、它的字段、它在用的配方的各个版本 —— 一并读,按工序归位。
    const [linksRes, fieldsRes, recipesRes, versionsRes, shiftsRes, weighRes, devicesRes] = await Promise.all([
        supabase.from('operation_type_equipment').select('operation_type_code, fixed_asset_id'),
        supabase.from('operation_type_fields')
            .select('operation_type_code, field_code, name_en, name_zh, kind, value_type, unit, is_required, range_min, range_max')
            .eq('is_active', true).order('sort_order'),
        supabase.from('process_recipes').select('id, operation_type_code, code').eq('is_active', true).order('code'),
        supabase.from('process_recipe_versions').select('id, recipe_id, version, param_values').order('version', { ascending: false }),
        supabase.from('shifts').select('code, name_en, name_zh, starts_at, ends_at').eq('is_active', true).order('sort_order'),
        supabase.from('run_weighing_options')
            .select('weighing_id, weight_kg, device_code, captured_at, calibration_status')
            .order('captured_at', { ascending: false }).limit(200),
        supabase.from('devices').select('id, code, name, kind, retired_at')
            .is('retired_at', null).in('kind', ['scale', 'weighbridge', 'meter', 'inline_instrument']).order('code'),
    ])
    const links = mustRows(linksRes, 'operation_type_equipment')
    const fieldRows = mustRows(fieldsRes, 'operation_type_fields')
    const recipeRows = mustRows(recipesRes, 'process_recipes')
    const versionRows = mustRows(versionsRes, 'process_recipe_versions')
    const fieldsOf = (code: string): FieldOption[] => fieldRows.filter((f) => f.operation_type_code === code).map((f) => ({
        code: f.field_code, name_en: f.name_en, name_zh: f.name_zh, kind: f.kind, value_type: f.value_type, unit: f.unit,
        is_required: f.is_required, range_min: f.range_min, range_max: f.range_max,
    }))
    const recipesOf = (code: string) => recipeRows.filter((r) => r.operation_type_code === code).flatMap((r) =>
        versionRows.filter((v) => v.recipe_id === r.id).map((v) => ({
            version_id: v.id, label: `${r.code} v${v.version}`,
            param_values: (v.param_values ?? {}) as Record<string, unknown>,
        })))
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
        // 只算没处置的那几台 —— 与 assert_run_equipment 同一个判据(处置了的不让这条规则生效);下面 equipment 已滤掉处置的。
        machine_ids: links.filter((l) => l.operation_type_code === o.code).map((l) => l.fixed_asset_id),
        fields: fieldsOf(o.code),
        recipes: recipesOf(o.code),
    }))

    // ROLE-1 Batch 3b:批次行只带 material_id,名字按 id 从 material_lookup 取一次再映射回去
    type BatchFetchRow = Omit<InboundBatchOption, 'materials' | 'available_qty'> & { material_id: string | null }
    const inboundRows = mustRows(batchesRes, 'inbound_batches') as unknown as BatchFetchRow[]
    const outputRows = mustRows(outputBatchesRes, 'output_batches') as unknown as BatchFetchRow[]
    const nameOf = await loadMaterialNames(supabase, [...inboundRows, ...outputRows].map((b) => b.material_id))
    const withAvailable = (rows: BatchFetchRow[]): InboundBatchOption[] =>
        rows.map(({ material_id, ...b }) => ({
            ...b,
            materials: material_id && nameOf.has(material_id) ? { name: nameOf.get(material_id) as string } : null,
            available_qty: availByBatch.get(b.id) ?? 0,
        }))
    // UNBLOCK-1 Q21:「用了哪台机器」的选项。读 equipment_usage(属主权限视图,
    // 财务或加工两个模块任一即可读 —— 机器卡在财务,干活的人在加工)。
    // 【已处置的不列】commit_processing_run 会按名拒(EQUIPMENT_DISPOSED),
    // 这里不画一个必然被拒的选项。尚未购入那一条(EQUIPMENT_NOT_ACQUIRED)取决于
    // 加工日期,而日期在表单里会变 —— 那一条留给服务端说,不在这里预判。
    const equipment = (mustRows(
        await supabase
            .from('equipment_usage')
            .select('equipment_id, equipment_code, equipment_description')
            .neq('equipment_status', 'disposed')
            .order('equipment_code'),
        'equipment_usage'
    ) as unknown as { equipment_id: string; equipment_code: string; equipment_description: string | null }[])
        .map((e) => ({ id: e.equipment_id, code: e.equipment_code, description: e.equipment_description }))

    // 挂着的机器里处置了的不算 —— 把 machine_ids 收窄到下拉里真的有的那几台(与服务端判据同一条)。
    const liveMachineIds = new Set(equipment.map((e) => e.id))
    for (const o of operations) o.machine_ids = o.machine_ids.filter((id) => liveMachineIds.has(id))

    // MES-4a(Q31):从一张已回滚的单上点进来 —— 只认【已回滚、还没被更正过】的那一张;别的情形不画横幅(服务端照样按名拒)。
    const correctsId = (await searchParams).corrects ?? null
    let corrects: { id: string; code: string } | null = null
    if (correctsId) {
        const c = mustOne(await supabase.from('processing_runs_masked').select('id, code, status')
            .eq('id', correctsId).maybeSingle(), 'processing_runs_masked') as { id: string | null; code: string | null; status: string | null } | null
        const takenBy = mustRows(await supabase.from('processing_runs_masked').select('id')
            .eq('corrects_run_id', correctsId), 'processing_runs_masked')
        if (c && c.status === 'reversed' && takenBy.length === 0 && c.id && c.code) corrects = { id: c.id, code: c.code }
    }

    // ROLE-1 Batch 3b:建加工单 = commit_processing_run;没有收货码的人,「先去建收货单」那条链接也按不动
    const [canCommit, canReceive] = await Promise.all([can('action.processing_commit'), can('action.receive_goods')])

    return (
        <NewProcessingForm
            inboundBatches={withAvailable(inboundRows)}
            outputBatches={withAvailable(outputRows)}
            // material_lookup 是视图,生成的类型每列都可空;id / code / name 在基表上都是 NOT NULL
            materials={mustRows(materialsRes) as unknown as { id: string; code: string; name: string }[]}
            defaultAllocationBasis={
                mustOne(settingsRes, 'finance_settings')?.default_allocation_basis ?? 'metal_value'
            }
            workOrders={mustRows(workOrdersRes, 'work_orders') as unknown as
                { id: string; code: string; scheduled_date: string | null }[]}
            operations={operations}
            equipment={equipment}
            shifts={mustRows(shiftsRes, 'shifts') as ShiftOption[]}
            weighingOptions={mustRows(weighRes, 'run_weighing_options') as unknown as WeighingOption[]}
            devices={(mustRows(devicesRes, 'devices') as unknown as DeviceOption[])}
            corrects={corrects}
            canCommit={canCommit}
            canReceive={canReceive}
        />
    )
}
