import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import DeleteButton from './DeleteButton'
import CostPanel from './CostPanel'
import LossPanel, { type LossCategory, type LossRow, type ElectrolyteSetting } from './LossPanel'
import ContaminationPanel, { type ContaminationStreamView, type ContaminationCheckView } from './ContaminationPanel'
import DischargePanel from './DischargePanel'
import { loadDischargePanel, loadSplitOrigin } from './dischargeData'
import AllocateButton from './AllocateButton'
import { type CostEntryRow } from './costTypes'
import { processingStatusLabelKey } from '../../status'
import { metalLabelKey } from '@/app/tools/pricing/metal-prices/options'
import { formatAmount, formatMoneyBare, formatUnitCost, formatTimestamp } from '@/lib/format'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { maskedRows, maskedExcept } from '@/lib/maskedRows'
import type { Tables } from '@/lib/database.types'
import { canViewPrices, can } from '@/lib/permissions'
import { openWarehouseRequestsByCode } from '@/lib/warehouseRequests'
import { MaskedValue } from '@/app/components/MaskedValue'
import { mustOne, mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { getBaseCurrency } from '@/lib/currency'
import { ListPage } from '@/app/components/ui/list-page'
import { RecordHeader } from '@/app/components/ui/record-header'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { Button } from '@/app/components/ui/button'
// LineageRow 这个名字页面自己已经用掉了(batch_lineage 的行形状),
// 所以表那一侧的行类型换个名字进来 —— 不改页面既有的那个类型。
import {
    WoVarianceTable, type WoVarianceRow,
    LineageTable, type LineageRow as LineageTableRow,
    InputsTable, type InputLegRow,
    OutputsTable, type OutputLegRow,
    RecoveryTable, type RecoveryRow,
} from './ProcessingTables'
import { formatAuditStamp, formatDate, formatDateTime } from '@/lib/dates'
import { loadActorNames } from '@/app/components/ActorName'
import { loadMaterialNames } from '../materialNames'
import AuditTrail, { trailCount } from '@/app/components/trail/AuditTrail'
import EndedBanner, { EndedFieldset } from '@/app/components/trail/EndedBanner'
import {
    ValuesPanel, type ValueRow, EventsPanel, type EventRow, BalancePanel, type BalanceView,
    HeaderCorrectionPanel, type CorrectionRow,
} from './RunRecordPanels'

// FK 嵌入运行时是对象(包括两层嵌套);显式类型 + cast 锁住。
// ROLE-1 Batch 3b:批次里不再嵌 materials ( name ) —— 仓库读不了 materials 基表,嵌入会静默成 null。
// 只带 material_id,名字由 loadMaterialNames 从 material_lookup 映射(见 ../materialNames.ts)。
type ProcessingInputRow = {
    id: string
    quantity_consumed: number
    inbound_batches: {
        id: string
        code: string
        unit: string
        deleted_at: string | null
        material_id: string | null
        cell_construction_code: string | null   // MES-4b
    } | null
    // FIN-25:再加工投料 —— 双亲恰一非空
    output_batches: {
        id: string
        code: string
        unit: string
        deleted_at: string | null
        material_id: string | null
        cell_construction_code: string | null   // MES-4b
    } | null
}

type ProcessingOutputRow = {
    id: string
    quantity_produced: number
    allocated_cost_base: number | null
    unit_cost_base: number | null
    cost_incomplete: boolean
    output_batches: {
        id: string
        code: string
        unit: string
        purity: string | null
        deleted_at: string | null
        material_id: string | null
    } | null
}

export default async function ProcessingDetailPage({
    params,
    searchParams,
}: {
    params: Promise<{ id: string }>
    searchParams: Promise<{ trail?: string | string[] }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.processing)
    if (denied) return denied

    const { id } = await params
    const supabase = await createClient()
    const t = await getTranslations()
    // CCY-1:概况块的三个成本是 *_base 而【一个币种都没写】,底下产出表的列头却写着
    // 「分摊成本 (SGD)」—— 同一页两种待遇,上面那三个就成了没人认领的数字。
    // 本位币从 currencies.is_base 取(不写死),三个数各自带上它。
    const baseCurrency = await getBaseCurrency()
    const locale = await getLocale()
    const dateLocale = locale === 'zh' ? 'zh-CN' : 'en-US'

    const [runRes, inputsRes, outputsRes, costsRes, recoveryRes] = await Promise.all([
        supabase
            // AUDIT-TRAIL-1b-1(Q21):回滚了的加工单【照常打开、只读】,不再 404。回滚把 status 改成 reversed、
            //   同一句里盖上 deleted_at —— 那两件事是同一个事实,所以这里不再按 deleted_at 过滤;
            //   下面那几块"只在已提交单上"的分支(isCommitted)从此真的走得到。
            .from('processing_runs_masked')
            .select('*')
            .eq('id', id)
            .single(),
        supabase
            .from('processing_inputs')
            .select('id, quantity_consumed, inbound_batches ( id, code, unit, deleted_at, material_id, cell_construction_code ), output_batches ( id, code, unit, deleted_at, material_id, cell_construction_code )')
            .eq('run_id', id)
            .order('created_at'),
        supabase
            .from('processing_outputs_masked')
            .select('id, quantity_produced, allocated_cost_base, unit_cost_base, cost_incomplete, output_batches ( id, code, unit, purity, deleted_at, material_id )')
            .eq('run_id', id)
            .order('created_at'),
        supabase
            .from('processing_cost_entries_masked')
            .select('id, cost_type, amount_base, is_estimate, notes, created_at, updated_at, updated_by')
            .eq('run_id', id)
            .is('deleted_at', null)
            .order('created_at'),
        supabase
            .from('processing_metal_recovery')
            // PROC-1c:两侧出处一并取 —— 守恒警告要说得出自己比的是
            // 【实验室 vs 实验室】(真异常)还是【实验室 vs 手敲】(先怀疑打错字)
            .select('metal, input_metal_kg, output_metal_kg, recovery_pct, input_measured, output_measured, recovery_blocked_by, conservation_warning, run_recovery_computable, input_source, output_source')
            .eq('run_id', id)
            .order('metal'),
    ])

    if (runRes.error || !runRes.data) {
        notFound()
    }

    if (inputsRes.error || outputsRes.error) {
        const err = inputsRes.error ?? outputsRes.error
        return (
            <div className="p-8 max-w-3xl">
                <h1 className="mb-4">{t('processing.detailTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('processing.detailLoadError')}</p>
                    <details className="mt-2">
                        <summary className="cursor-pointer text-xs">{t('common.actionMessage.technicalDetail')}</summary>
                        <pre className="mt-1 text-xs">{JSON.stringify(err, null, 2)}</pre>
                    </details>
                </div>
            </div>
        )
    }

    // cut 2b:改读遮蔽视图(select('*') 会碰到被收回的成本列)。
    const run = maskedExcept<
        Tables<'processing_runs'>,
        'material_cost_base' | 'process_cost_base' | 'total_cost_base' | 'capitalized_cost_base'
    >(runRes.data)
    const inputs = mustRows(inputsRes, 'processing_inputs') as unknown as ProcessingInputRow[]

    // FIN-25:血缘 —— 本单产出批的【全部】祖先(递归视图;security_invoker,RLS 照常)。
    // 立账公理是全链路可溯,再加工让链条真正变长,这一块是它的眼睛。
    type LineageRow = {
        output_batch_id: string; depth: number; via_run_id: string; via_run_code: string
        parent_kind: string; parent_batch_id: string; parent_code: string | null
        quantity_consumed: number
    }
    const outputs = mustRows(outputsRes, 'processing_outputs_masked') as unknown as ProcessingOutputRow[]
    const outputIds = outputs
        .map((o) => o.output_batches?.id).filter(Boolean) as string[]
    let lineage: LineageRow[] = []
    if (outputIds.length > 0) {
        const lineageRes = await supabase
            .from('batch_lineage')
            .select('output_batch_id, depth, via_run_id, via_run_code, parent_kind, parent_batch_id, parent_code, quantity_consumed')
            .in('output_batch_id', outputIds)
            .order('depth')
        lineage = (mustRows(lineageRes, 'batch_lineage') as unknown as LineageRow[])
    }
    // ROLE-1 Batch 3b:投入与产出两侧批次的物料名,一次从 material_lookup 取回
    const materialName = await loadMaterialNames(supabase, [
        ...inputs.map((l) => (l.inbound_batches ?? l.output_batches)?.material_id),
        ...outputs.map((o) => o.output_batches?.material_id),
    ])
    const nameFor = (mid: string | null | undefined) => (mid ? materialName.get(mid) : undefined) ?? '—'

    const isCommitted = run.status === 'committed'
    const ended = run.status === 'reversed' || !!run.deleted_at

    // 状态标签(未知值回退原样)
    const statusLabel = (v: string | null) => {
        const k = processingStatusLabelKey(v)
        return k ? t(k) : v ?? '—'
    }

    // 成本条目行:服务端预格式化 created_at
    const showPrices = await canViewPrices()
    // PROC-BUILD-1:损耗分类。字典【现读】—— 加一种损耗是往 loss_categories 加一行,
    // 屏幕不该是第二份权威(materials 那五条轴立的同一条先例)。
    const canEditRun = await can('module.processing.edit')
    // ROLE-1 Batch 3b:回滚归 action.processing_rollback;损耗登记(善后)归 action.processing_aftercare
    // 或 module.processing.edit(库里两者之一即可,拒的时候点名 aftercare)。成本条目仍是 processing.edit,不动。
    const [canRollback, canAftercare] = await Promise.all([
        can('action.processing_rollback'), can('action.processing_aftercare')])
    const canEditLosses = canAftercare || canEditRun
    // APR-7:一张在等 CFO 的回滚 / 注销 / 证书作废申请碰到这张单时,回滚钮按不动并说出是哪一张
    const openWarehouseRequest = await can('module.inventory.view')
        ? await openWarehouseRequestsByCode(supabase)
        : new Map<string, string>()
    // ROLE-1:分摊归财务(allocate_processing_costs 的门是 module.finance.edit)
    const canAllocate = await can('module.finance.edit')
    const [lossCatRes, lossRowRes] = await Promise.all([
        supabase.from('loss_categories')
            .select('code, name_en, name_zh, metal_fate, is_true_loss, may_be_derived')
            .eq('is_active', true).order('sort_order'),
        // MES-4a(Q28):只追加 —— 一类损耗的【当前】那一条是更正链末端(没有别的行指着它)。
        supabase.from('processing_run_losses')
            .select('id, loss_category_code, quantity, notes, corrects_id, correction_reason, basis, derived_share_pct').eq('run_id', id).order('id'),
    ])
    const lossCategories = mustRows(lossCatRes, 'loss_categories') as LossCategory[]
    const allLossRows = mustRows(lossRowRes, 'processing_run_losses')
    const supersededLoss = new Set(allLossRows.map((r) => r.corrects_id).filter((x): x is number => x !== null))
    const lossRows: LossRow[] = allLossRows.filter((r) => !supersededLoss.has(r.id)).map((r) => ({
        id: r.id, loss_category_code: r.loss_category_code, quantity: Number(r.quantity), notes: r.notes,
        corrected: r.corrects_id !== null, correction_reason: r.correction_reason,
        basis: r.basis === 'derived' ? 'derived' as const : 'measured' as const,
        derived_share_pct: r.derived_share_pct === null ? null : Number(r.derived_share_pct),
    })).sort((a, b) => a.loss_category_code.localeCompare(b.loss_category_code))

    // ── MES-4a(Step 0 Q7–Q31):抬头的时刻 / 班次 / 机器 / 配方,值、事件、平衡、更正 ──────────────────
    const canCommitRun = await can('action.processing_commit')
    const opCode = run.operation_type_code ?? null
    const [opRes, shiftRes, eqRes, linkRes, recipeRes, versionRes, valuesRes, fieldRes, eventRes, eventTypeRes,
           balanceRes, corrRes, correctedByRes] = await Promise.all([
        supabase.from('operation_types').select('code, name_en, name_zh, electrolyte_loss_applies, electrolyte_share_pct, verifies_by_unit, started_from_run_page').order('sort_order'),
        supabase.from('shifts').select('code, name_en, name_zh, is_active').order('sort_order'),
        supabase.from('equipment_usage').select('equipment_id, equipment_code, equipment_description, equipment_status').order('equipment_code'),
        supabase.from('operation_type_equipment').select('operation_type_code, fixed_asset_id'),
        supabase.from('process_recipes').select('id, code, operation_type_code, is_active'),
        supabase.from('process_recipe_versions').select('id, recipe_id, version').order('version', { ascending: false }),
        supabase.from('processing_run_values_current')
            .select('value_id, field_code, name_en, name_zh, kind, value_type, unit, is_required, value_number, value_text, value_bool, source, out_of_range, range_min_at, range_max_at, corrected, correction_reason, recipe_value, differs_from_recipe')
            .eq('run_id', id),
        opCode
            ? supabase.from('operation_type_fields')
                .select('field_code, name_en, name_zh, kind, value_type, unit, is_required, is_active, range_min, range_max, sort_order')
                .eq('operation_type_code', opCode).order('sort_order')
            : Promise.resolve({ data: [], error: null }),
        supabase.from('processing_run_events')
            .select('id, event_type_code, occurred_at, duration_min, action_taken, responsible_person, notes, withdrawn, corrects_id, correction_reason')
            .eq('run_id', id).order('occurred_at'),
        supabase.from('processing_event_types').select('code, name_en, name_zh, is_active').order('sort_order'),
        supabase.from('processing_run_balance')
            .select('balance_state, input_qty, output_qty, loss_qty, named_loss_qty, remainder_qty, tolerance_pct, within_tolerance, required_missing, outputs_unweighed, last_closure_id, last_closed_at, derived_loss_qty')
            .eq('run_id', id).maybeSingle(),
        supabase.from('processing_run_corrections')
            .select('id, field, old_value, new_value, reason, corrected_at').eq('run_id', id).order('id'),
        supabase.from('processing_runs_masked').select('id, code').eq('corrects_run_id', id),
    ])
    const ops = mustRows(opRes, 'operation_types')
    const shiftRows = mustRows(shiftRes, 'shifts')
    const eqRows = mustRows(eqRes, 'equipment_usage')
    const linkRows = mustRows(linkRes, 'operation_type_equipment')
    const recipeRows = mustRows(recipeRes, 'process_recipes')
    const versionRows = mustRows(versionRes, 'process_recipe_versions')
    const valueRowsDb = mustRows(valuesRes, 'processing_run_values_current')
    const fieldRows = mustRows(fieldRes as { data: { field_code: string; name_en: string; name_zh: string; kind: string; value_type: string; unit: string | null; is_required: boolean; is_active: boolean; range_min: number | null; range_max: number | null; sort_order: number }[] | null; error: { message: string } | null }, 'operation_type_fields')
    const eventRowsDb = mustRows(eventRes, 'processing_run_events')
    const eventTypes = mustRows(eventTypeRes, 'processing_event_types')
    const balance = mustOne(balanceRes, 'processing_run_balance')
    const corrRows = mustRows(corrRes, 'processing_run_corrections')
    const correctedBy = mustRows(correctedByRes, 'processing_runs_masked')
    const correctsRun = run.corrects_run_id
        ? mustOne<{ id: string | null; code: string | null }>(await supabase.from('processing_runs_masked').select('id, code').eq('id', run.corrects_run_id).maybeSingle(), 'processing_runs_masked')
        : null

    const nm = (r: { name_en: string | null; name_zh: string | null }) => (locale === 'zh' ? r.name_zh : r.name_en) ?? '—'
    const op = ops.find((o) => o.code === opCode) ?? null
    const shift = shiftRows.find((x) => x.code === run.shift_code) ?? null
    const machine = eqRows.find((e) => e.equipment_id === run.equipment_id) ?? null
    const versionLabel = (vid: string | null) => {
        const v = versionRows.find((x) => x.id === vid)
        const rc = v ? recipeRows.find((r) => r.id === v.recipe_id) : null
        return v && rc ? `${rc.code} v${v.version}` : null
    }
    const fmtStamp = (iso: string | null) => (iso ? formatDateTime(iso, locale) : '—')

    // ① 值:这道工序的每个在用字段一行(没记的也列,才看得见缺了什么);停用了但这一炉记过的也列。
    const fmtValue = (vt: string, n: number | null, tx: string | null, b: boolean | null): string | null =>
        vt === 'yes_no' ? (b === null ? null : b ? t('common.yes') : t('common.no'))
            : vt === 'text' ? tx : (n === null ? null : String(n))
    const rawValue = (vt: string, n: number | null, tx: string | null, b: boolean | null): string =>
        vt === 'yes_no' ? (b === null ? '' : String(b)) : vt === 'text' ? (tx ?? '') : (n === null ? '' : String(n))
    const recipeDisplay = (vt: string, v: unknown): string | null =>
        v === null || v === undefined ? null : vt === 'yes_no' ? (v === true ? t('common.yes') : t('common.no')) : String(v)
    const rangeText = (min: number | null, max: number | null) =>
        min === null && max === null ? null : t('processing.rec.range', { min: min ?? '—', max: max ?? '—' })
    const valueRows: ValueRow[] = fieldRows
        .filter((f) => f.is_active || valueRowsDb.some((v) => v.field_code === f.field_code))
        .map((f) => {
            const v = valueRowsDb.find((x) => x.field_code === f.field_code) ?? null
            return {
                field_code: f.field_code, name: nm(f), kind: f.kind, value_type: f.value_type, unit: f.unit,
                is_required: f.is_required,
                range_text: v ? rangeText(v.range_min_at, v.range_max_at) : rangeText(f.range_min, f.range_max),
                value_id: v?.value_id ?? null,
                display: v ? fmtValue(f.value_type, v.value_number, v.value_text, v.value_bool) : null,
                raw: v ? rawValue(f.value_type, v.value_number, v.value_text, v.value_bool) : '',
                source: v?.source ?? null,
                out_of_range: v?.out_of_range ?? null,
                differs_from_recipe: v?.differs_from_recipe ?? null,
                recipe_display: v ? recipeDisplay(f.value_type, v.recipe_value) : null,
                corrected: !!v?.corrected, correction_reason: v?.correction_reason ?? null,
            }
        })

    // ② 事件:更正链末端
    const supersededEv = new Set(eventRowsDb.map((e) => e.corrects_id).filter((x): x is number => x !== null))
    const typeLabel = (code: string) => { const ty = eventTypes.find((x) => x.code === code); return ty ? nm(ty) : code }
    const eventRows: EventRow[] = eventRowsDb.filter((e) => !supersededEv.has(e.id)).map((e) => ({
        id: e.id, event_type_code: e.event_type_code, type_label: typeLabel(e.event_type_code),
        occurred_display: fmtStamp(e.occurred_at), occurred_at: e.occurred_at,
        duration_min: e.duration_min === null ? null : Number(e.duration_min),
        action_taken: e.action_taken, responsible_person: e.responsible_person, notes: e.notes,
        withdrawn: e.withdrawn, corrected: e.corrects_id !== null, correction_reason: e.correction_reason,
    }))

    // ③ 平衡:状态与数都由视图给;最后一次结算的解释读那一行结算记录
    const lastClosure = balance?.last_closure_id
        ? mustOne<{ explanation: string | null }>(await supabase.from('processing_run_closures').select('explanation').eq('id', balance.last_closure_id).maybeSingle(), 'processing_run_closures')
        : null
    const q = (n: number | null | undefined) => (n === null || n === undefined ? '—' : String(Number(n)))
    const balanceView: BalanceView | null = balance ? {
        state: balance.balance_state ?? 'not_applicable',
        input: q(balance.input_qty), output: q(balance.output_qty), loss: q(balance.loss_qty),
        named: q(balance.named_loss_qty), remainder: q(balance.remainder_qty),
        derived: Number(balance.derived_loss_qty ?? 0) > 0 ? q(balance.derived_loss_qty) : null,
        tolerance: balance.tolerance_pct === null ? null : String(Number(balance.tolerance_pct)),
        within: balance.within_tolerance,
        required_missing: (balance.required_missing ?? []).map((code) => {
            const f = fieldRows.find((x) => x.field_code === code); return f ? nm(f) : code
        }),
        outputs_unweighed: Number(balance.outputs_unweighed ?? 0),
        last_closed: balance.last_closed_at ? fmtStamp(balance.last_closed_at) : null,
        last_explanation: lastClosure?.explanation ?? null,
    } : null

    // ── MES-4b(Q17 · Q18):这一炉的工序上「Electrolyte evaporates in this step」与份额(状态改变型无从谈起)──────────
    const electrolyte: ElectrolyteSetting = !op || balance?.balance_state === 'not_applicable' ? null : {
        applies: !!op.electrolyte_loss_applies,
        sharePct: op.electrolyte_share_pct === null ? null : Number(op.electrolyte_share_pct),
        operationCode: op.code,
    }

    // ── MES-4b(Q21–Q25):交叉污染 —— 流(警戒线 V11)、这一炉每条流的极片产出、这一炉的抽检(经带门的属主视图)──────────
    const [streamRes, checkRes, outFormRes, ccRes, formRes] = await Promise.all([
        supabase.from('contamination_streams').select('code, name_en, name_zh, sheet_form_code, warning_pct').eq('is_active', true).order('sort_order'),
        supabase.from('contamination_check_rows')
            .select('id, stream_code, kind, output_batch_id, output_batch_code, sample_mass_g, foreign_mass_g, rate_pct, warning_pct_at, above_warning, sampled_at, method, not_sampled_reason, corrects_id, correction_reason, is_current')
            .eq('run_id', id).order('id'),
        supabase.from('material_lookup').select('id, form_code'),
        supabase.from('cell_constructions').select('code, name_en, name_zh'),
        supabase.from('material_forms').select('code, implies_dismantling'),
    ])
    const streamRows = mustRows(streamRes, 'contamination_streams')
    const formOf = new Map((mustRows(outFormRes, 'material_lookup') as unknown as { id: string; form_code: string | null }[]).map((m) => [m.id, m.form_code]))
    const contaminationStreams: ContaminationStreamView[] = streamRows.map((s) => ({
        code: s.code, label: nm(s), warningPct: s.warning_pct === null ? null : Number(s.warning_pct),
        batches: outputs.filter((leg) => leg.output_batches && formOf.get(leg.output_batches.material_id ?? '') === s.sheet_form_code)
            .map((leg) => ({ id: leg.output_batches!.id, code: leg.output_batches!.code })),
    })).filter((s) => s.batches.length > 0)
    const streamLabel = (code: string) => { const s = streamRows.find((x) => x.code === code); return s ? nm(s) : code }
    const contaminationChecks: ContaminationCheckView[] = (mustRows(checkRes, 'contamination_check_rows') as unknown as {
        id: number; stream_code: string; kind: string; output_batch_id: string | null; output_batch_code: string | null
        sample_mass_g: number | null; foreign_mass_g: number | null; rate_pct: number | null; warning_pct_at: number | null
        above_warning: boolean | null; sampled_at: string | null; method: string | null; not_sampled_reason: string | null
        corrects_id: number | null; correction_reason: string | null; is_current: boolean
    }[]).filter((c) => c.is_current).map((c) => ({
        id: c.id, stream: c.stream_code, streamLabel: streamLabel(c.stream_code), kind: c.kind === 'not_sampled' ? 'not_sampled' : 'sampled',
        batchId: c.output_batch_id, batchCode: c.output_batch_code,
        sampleG: c.sample_mass_g === null ? null : Number(c.sample_mass_g), foreignG: c.foreign_mass_g === null ? null : Number(c.foreign_mass_g),
        ratePct: c.rate_pct === null ? null : Number(c.rate_pct), warningPctAt: c.warning_pct_at === null ? null : Number(c.warning_pct_at),
        above: c.above_warning, sampledAtIso: c.sampled_at, sampledAt: c.sampled_at ? fmtStamp(c.sampled_at) : null,
        method: c.method, notSampledReason: c.not_sampled_reason, corrected: c.corrects_id !== null, correctionReason: c.correction_reason,
    }))
    // MES-4b(Q4):投入那一格旁边说出每一批的电芯结构(没记就说没记 —— 只对装电芯的形态说)
    const ccName = new Map((mustRows(ccRes, 'cell_constructions')).map((c) => [c.code, nm(c)]))
    const dismantles = new Map(mustRows(formRes, 'material_forms').map((f) => [f.code, f.implies_dismantling]))
    /** 与库里的守卫同一个判据:装电芯的形态说;不装的不说;没有形态的照常说 */
    // ── MES-5a-1(Step 0 Q5–Q13):放电那一炉(verifies_by_unit)的逐模组结果 · 拆去隔离那一炉的来处 ──────────
    const discharge = op?.verifies_by_unit
        ? await loadDischargePanel(supabase, {
            runId: id, inputs, fmtStamp, shifts: shiftRows.filter((x) => x.is_active).map((x) => ({ value: x.code, label: nm(x) })),
        })
        : null
    const splitOrigin = op?.started_from_run_page ? await loadSplitOrigin(supabase, id) : null
    const canConfirmCapture = await can('action.confirm_capture')

    const formCarriesCells = (materialId: string | null | undefined) => {
        const form = materialId ? formOf.get(materialId) : null
        return form ? dismantles.get(form) !== false : true
    }

    // ④ 抬头更正:选项只给这道工序的(机器:挂着的那几台,一台都没挂就全部没处置的;配方:这道工序的版本)
    const linked = linkRows.filter((l) => l.operation_type_code === opCode).map((l) => l.fixed_asset_id)
    const liveEq = eqRows.filter((e) => e.equipment_status !== 'disposed')
    const machineOpts = (linked.some((idx) => liveEq.some((e) => e.equipment_id === idx))
        ? liveEq.filter((e) => linked.includes(e.equipment_id as string)) : liveEq)
        .map((e) => ({ value: e.equipment_id as string, label: `${e.equipment_code}${e.equipment_description ? ' — ' + e.equipment_description : ''}` }))
    const recipeOpts = recipeRows.filter((r) => r.operation_type_code === opCode && r.is_active).flatMap((r) =>
        versionRows.filter((v) => v.recipe_id === r.id).map((v) => ({ value: v.id, label: `${r.code} v${v.version}` })))
    const fieldLabel = (f: string) => t('processing.rec.headerField.' + f)
    const corrDisplay = (field: string, v: string | null): string => {
        if (v === null || v === '') return '—'
        if (field === 'started_at' || field === 'ended_at') return fmtStamp(v)
        if (field === 'shift_code') { const x = shiftRows.find((y) => y.code === v); return x ? nm(x) : v }
        if (field === 'equipment_id') return eqRows.find((e) => e.equipment_id === v)?.equipment_code ?? v
        if (field === 'recipe_version_id') return versionLabel(v) ?? v
        return v
    }
    const correctionRows: CorrectionRow[] = corrRows.map((c) => ({
        id: c.id, field_label: fieldLabel(c.field), old_value: corrDisplay(c.field, c.old_value),
        new_value: corrDisplay(c.field, c.new_value), reason: c.reason, when: fmtStamp(c.corrected_at),
    }))
    const headerCurrent: Record<string, string> = {
        started_at: run.started_at ?? '', ended_at: run.ended_at ?? '', shift_code: run.shift_code ?? '',
        equipment_id: run.equipment_id ?? '', recipe_version_id: run.recipe_version_id ?? '', notes: run.notes ?? '',
    }

    const rawCosts = maskedRows<Tables<'processing_cost_entries'>, 'amount_base'>(mustRows(costsRes))
    // 改过条目的操作人姓名(一次取回,不逐行查)
    const editorIds = [...new Set(rawCosts
        .filter((c) => c.updated_at !== c.created_at && c.updated_by)
        .map((c) => c.updated_by as string))]
    // ★★【FIX-2b:「谁改的」读不到时要【说出来】,不能留空】★★
    //   employees 的 RLS 是 has_permission('module.hr.view') OR 自己那一行,而
    //   operations【没有】那个码(实测:Phua 读 employees 得 1 行 —— 只有他自己)。
    //   于是这里的名字表几乎总是空的,下面 `?? null` 让 CostPanel 那一格
    //   【什么都不印】—— 屏幕上只剩「改于 X 时」,而没有人。
    //   一个没有主语的改动记录,读起来就是"系统自己改的",那正是
    //   app/components/ActorName.tsx 抬头第 ④ 条整段在防的东西。
    //
    //   ★ 为什么不是 (a):employee_lookup 的体内谓词是 hr.view OR finance.view,
    //     operations 两个都没有 —— 要用它就得放宽那张视图的谓词,而那是一次
    //     真的扩权(把整份员工名册给运营),不是换一个读法。所以走 (b):
    //     判据取一次,读不到时印一句具名的「受限」。
    const canSeeEmployees = await can('module.hr.view')
    // ★ APR-ROUTE-1 Batch B(R3):名字表改由 loadActorNames 取 —— "谁做的"只有
    //   app/components/ActorName.tsx 一份实现,而它认得【额外账号】(employee_accounts)。
    //   此前这里自己查 employees.user_id,一个人用第二个账号改过的条目会印成空。
    const editorName = (await loadActorNames(supabase, editorIds)).names

    const costRows: CostEntryRow[] = rawCosts.map((c) => ({
        id: c.id,
        cost_type: c.cost_type,
        amount_base: c.amount_base,
        is_estimate: c.is_estimate,
        notes: c.notes,
        created_at_display: formatAuditStamp(c.created_at),
        edited_at_display: c.updated_at !== c.created_at
            ? formatTimestamp(c.updated_at, dateLocale) : null,
        // 三态,与 ActorName 同形:查得到印名字 · 查不到但看得见人事 = 真的没这个人
        // (仍是 null,由面板印一个诚实的空)· 看不见人事 = 具名的「受限」。
        edited_by_name: !c.updated_by
            ? null
            : editorName.get(c.updated_by) ?? (canSeeEmployees ? null : t('common.restricted')),
    }))

    // FIN-8:分摊是否已过期 —— 改了成本条目,总账会动,批次不会自己重算。
    // 视图还告诉我们【能不能安全重跑】(已过账的 COGS 不会被重述,见迁移头注)。
    type AllocStatus = {
        allocated_at: string | null; last_cost_change: string | null
        is_stale: boolean | null; cogs_posted: number | null; safe_to_reallocate: boolean | null
    }
    const allocStatus = mustOne<AllocStatus>(await supabase.from('processing_run_allocation_status')
        .select('allocated_at, last_cost_change, is_stale, cogs_posted, safe_to_reallocate')
        .eq('run_id', id).maybeSingle(), 'processing_run_allocation_status')

    // 回收率行(视图已按 committed + 未软删过滤)
    const recoveryRows = mustRows(recoveryRes)

    // REC-1:整单的话由数据说(视图里的窗口聚合),不由页面从数字反推。
    // 【投产之后无法补救】—— 所以这句话只出现在单据上,不上看板:一盏关不掉的
    // 灯就是 hr_alerts 那盏常亮灯换个地方(预防那一半归看板的 awaiting_assay 支)。
    const recoveryComputable = recoveryRows.length === 0 || recoveryRows[0].run_recovery_computable !== false
    // 守恒提示:【只在两侧都测过】时才可能为真 —— 没测过的投入没有可守恒的对象。
    const conservationRows = recoveryRows.filter((r) => r.conservation_warning)
    const metalLabel = (v: string | null) => {
        const k = metalLabelKey(v)
        return k ? t(k) : v ?? '—'
    }

    // PROC-1c:含量出处的标签。四个取值来自视图的聚合(assay / manual / mixed /
    // unknown),NULL = 那一侧根本没测 —— 没测过的边没有出处可言,不画。
    // 【逐个字面量写死,不拼 key】:'mixed' 在视图里是字面量,另外三个是
    // min(COALESCE(content_source,'unknown')) 算出来的,check-i18n 的动态键解析
    // 取不到它们 —— 而一个解析不出后缀的动态前缀按约定是【失败】,不是放行。
    const sourceLabel = (s: string | null) =>
        s === 'assay' ? t('processing.recovery.source.assay')
            : s === 'manual' ? t('processing.recovery.source.manual')
                : s === 'mixed' ? t('processing.recovery.source.mixed')
                    : t('processing.recovery.source.unknown')

    // 守恒警告分得出自己站在哪一种情形里。两侧都测过是警告成立的前提,所以
    // 这里只在 assay/manual/mixed/unknown 之间判:
    //   * 两侧都是化验 → 真异常,值得追(拿错批、污染),不是打错字;
    //   * 任一侧出处未记 → 说不出是哪一种,照直说,不猜;
    //   * 其余(含 mixed)→ 至少有一侧不是纯化验数,先去看那一侧。
    // 顺序要紧:unknown 先判,否则 'assay' + 'unknown' 会被当成"有手敲的"。
    const anomalyCauseKey = (r: { input_source: string | null; output_source: string | null }) =>
        r.input_source === 'unknown' || r.output_source === 'unknown'
            ? 'processing.recovery.anomalyCauseUnknownSource'
            : r.input_source === 'assay' && r.output_source === 'assay'
                ? 'processing.recovery.anomalyCauseBothAssay'
                : 'processing.recovery.anomalyCauseNotBothAssay'

    // 分摊信息:上次分摊时间 + 基准标签
    // ── WO-1c:这次加工照的那张工单,以及它的差异 ───────────────────────────
    // 【差异不在这里算】两个数都取自 work_order_fulfilment —— 页面自己减一遍,
    // 就是给同一个规则留下第二处实现(AGENTS.md:一处推导,N 个消费者)。
    const woId = (run as { work_order_id?: string | null }).work_order_id ?? null
    const wo = woId
        ? (mustOne(await supabase.from('work_orders').select('id, code, status')
                    .eq('id', woId).maybeSingle(), 'work_orders') as
            { id: string; code: string; status: string } | null)
        : null
    const woVariance = woId
        ? (mustRows(await supabase.from('work_order_fulfilment')
                .select('side, material_code, material_name, planned_or_expected_qty, actual_qty, variance_qty, has_plan')
                .eq('work_order_id', woId), 'work_order_fulfilment') as {
                    side: string; material_code: string | null; material_name: string | null
                    planned_or_expected_qty: number | null; actual_qty: number
                    variance_qty: number | null; has_plan: boolean }[])
        : []

    const allocatedWhen = run.allocated_at
        ? formatTimestamp(run.allocated_at, dateLocale)
        : null
    const basisLabel =
        run.allocation_basis === 'metal_value' || run.allocation_basis === 'weight'
            ? t('processing.allocation.basis.' + run.allocation_basis)
            : run.allocation_basis

    // 分摊快照里未参与价值分摊的金属(没有价格),用于提示
    const snapshot = run.allocation_snapshot as { skipped_metals?: unknown } | null
    const skippedMetals = Array.isArray(snapshot?.skipped_metals)
        ? (snapshot!.skipped_metals as string[])
        : []

    // ── 行数据在服务端压平 ─────────────────────────────────────────────────
    // CONV-1 §① 那条:`Column.render` 是函数,过不了 RSC 边界,所以表在客户端,
    // 而【数据】在这里就变成字符串与布尔值 —— 客户端组件不碰 supabase,也不碰
    // 权限判断(showPrices 已经在这里问过了,过界的只是它的结果)。
    const varianceRows: WoVarianceRow[] = woVariance.map((v, i) => ({
        id: String(i),
        sideLabel: t(v.side === 'input' ? 'processing.wo.inputSide' : 'processing.wo.outputSide'),
        material: v.material_code ?? '—',
        plannedText: v.has_plan
            ? String(v.planned_or_expected_qty)
            : t(v.side === 'input' ? 'processing.wo.unplannedMaterial' : 'processing.wo.noExpectation'),
        plannedMuted: !v.has_plan,
        actualText: String(v.actual_qty),
        // null 是【无从相减】,不是 0 —— 表里画成灰横杠,与转换前逐字相同。
        varianceText: v.variance_qty == null
            ? null
            : (Number(v.variance_qty) > 0 ? '+' : '') + String(v.variance_qty),
        varianceNegative: v.variance_qty != null && Number(v.variance_qty) < 0,
    }))

    const lineageTableRows: LineageTableRow[] = lineage.map((l, i) => ({
        id: `${l.parent_batch_id}-${l.depth}-${i}`,
        depth: l.depth,
        viaRunCode: l.via_run_code,
        parentCode: l.parent_code ?? '—',
        parentHref: l.parent_kind === 'inbound'
            ? `/inbound/${l.parent_batch_id}/edit`
            : `/output/${l.parent_batch_id}/edit`,
        parentKindLabel: t('processing.lineage.kind_' + l.parent_kind),
        qty: String(l.quantity_consumed),
    }))

    const inputRows: InputLegRow[] = inputs.map((leg) => {
        // FIN-25:双亲投料 —— 进料批或(再加工)产出批
        const parent = leg.inbound_batches ?? leg.output_batches
        return {
            id: leg.id,
            parentCode: parent?.code ?? null,
            parentHref: leg.inbound_batches
                ? `/inbound/${leg.inbound_batches.id}/edit`
                : leg.output_batches ? `/output/${leg.output_batches.id}/edit` : null,
            parentDeleted: !!parent?.deleted_at,
            deletedMarker: t('processing.detail.deletedMarker'),
            reprocessed: !!leg.output_batches,
            material: nameFor(parent?.material_id),
            qtyText: `${leg.quantity_consumed} ${parent?.unit ?? ''}`.trim(),
            construction: parent && formCarriesCells(parent.material_id)
                ? (parent.cell_construction_code ? (ccName.get(parent.cell_construction_code) ?? parent.cell_construction_code) : t('cellConstruction.notRecorded'))
                : null,
        }
    })

    const outputRows: OutputLegRow[] = outputs.map((leg) => ({
        id: leg.id,
        batchCode: leg.output_batches?.code ?? null,
        batchHref: leg.output_batches ? `/output/${leg.output_batches.id}/edit` : null,
        batchDeleted: !!leg.output_batches?.deleted_at,
        deletedMarker: t('processing.detail.deletedMarker'),
        material: nameFor(leg.output_batches?.material_id),
        qtyText: `${leg.quantity_produced} ${leg.output_batches?.unit ?? ''}`.trim(),
        purity: leg.output_batches?.purity != null ? String(leg.output_batches.purity) : '—',
        // 遮蔽后是 null,和「尚未分摊」是两回事 —— 前者显示「受限」,后者才是「—」。
        // 两者都画成 — 会让运营以为成本没算。判断留在服务端,MaskedValue 在客户端。
        allocatedCostText: leg.allocated_cost_base === null
            ? null : formatMoneyBare(leg.allocated_cost_base, '列头「分摊成本 (SGD)」'),
        unitCostText: leg.unit_cost_base === null
            ? null : formatUnitCost(leg.unit_cost_base) + ' /kg',
        costIncomplete: !!leg.cost_incomplete,
    }))

    const recoveryTableRows: RecoveryRow[] = recoveryRows.map((r, idx) => ({
        id: String(r.metal ?? idx),
        metalLabel: metalLabel(r.metal),
        inputMeasured: !!r.input_measured,
        inputText: String(r.input_metal_kg),
        inputSource: sourceLabel(r.input_source),
        outputMeasured: !!r.output_measured,
        outputText: String(r.output_metal_kg),
        outputSource: sourceLabel(r.output_source),
        recoveryPctText: r.recovery_pct != null ? r.recovery_pct.toFixed(2) + '%' : null,
        blockedReason: t('processing.recovery.blocked.' + (r.recovery_blocked_by ?? 'input_not_measured')),
    }))

    return (
        <ListPage
            maxWidth="max-w-3xl"
            breadcrumb={
                <Link href="/operation/processing" className="hover:underline text-sm app-link">
                    {t('common.back')}
                </Link>
            }
            title={t('processing.detailTitle')}
            // ★ 出口:删除这一单。转换前它画在 h1 右边的 justify-between 里 ——
            //   actions 是同一个位置,而且画在状态分支【之前】,空态吃不掉它。
            actions={
                // 回滚了的单:回滚钮看得见、按不下去,理由是顶上那条横幅(DBLOCK-1:不藏,说为什么)
                <EndedFieldset ended={ended}>
                    <DeleteButton runId={run.id} code={run.code} canRollback={canRollback} openRequestLabel={openWarehouseRequest.get(run.code) ?? null} />
                </EndedFieldset>
            }
            notices={ended ? <EndedBanner kind="reversed" at={(run.deleted_at ?? run.updated_at) as string} by={run.deleted_by ?? null} reason={run.delete_reason ?? null} /> : undefined}
            // ★★ 详情页恒为 ok —— 这一单在不在由上面的 notFound() 回答。CONV-8 §⑤。
            state={{ kind: 'ok' }}
        >
            {/* ★ 记录抬头 —— 转换前是一块 bg-gray-50 rounded p-4 的面板(25 张里的一张)。
                单号与状态徽章转换前住在 <h1> 底下那一行 p;它们是这条记录的字段,
                所以搬进抬头,而不是留在标题里当装饰。 */}
            <RecordHeader
                fields={[
                    { label: t('processing.colCode'), value: run.code, mono: true },
                    {
                        label: t('processing.colStatus'),
                        value: (
                            <span className="px-2 py-1 rounded text-xs bg-gray-200">
                                {statusLabel(run.status)}
                            </span>
                        ),
                    },
                    { label: t('processing.detail.processDate'), value: formatDate(run.process_date, dateLocale) ?? '—' },
                    // MES-4a(Q7–Q9 · Q16):工序、机器、时刻、班次、配方。MES-4a 之前的单这几格是空的 —— 写「没有记」,不编一个。
                    { label: t('processing.rec.operation'), value: op ? nm(op) : (opCode ?? '—') },
                    { label: t('processing.rec.machineShort'), value: machine ? (machine.equipment_code ?? '—') : <span className="text-[color:var(--brand-muted-text)] italic">{t('processing.form.machineNone')}</span> },
                    { label: t('processing.rec.startedAt'), value: run.started_at ? fmtStamp(run.started_at) : <span className="text-[color:var(--brand-muted-text)] italic">{t('processing.rec.predatesField')}</span> },
                    { label: t('processing.rec.endedAt'), value: run.ended_at ? fmtStamp(run.ended_at) : <span className="text-[color:var(--brand-muted-text)] italic">{t('processing.rec.predatesField')}</span> },
                    { label: t('processing.rec.shift'), value: shift ? nm(shift) : <span className="text-[color:var(--brand-muted-text)] italic">{t('processing.rec.predatesField')}</span> },
                    { label: t('processing.rec.recipe'), value: versionLabel(run.recipe_version_id ?? null) ?? t('processing.rec.recipeNone') },
                    ...(correctsRun ? [{
                        label: t('processing.rec.corrects'),
                        value: <Link href={`/operation/processing/${correctsRun.id}`} className="hover:underline app-link app-link-inline">{correctsRun.code}</Link>,
                    }] : []),
                    ...(correctedBy.length > 0 ? [{
                        label: t('processing.rec.correctedBy'),
                        value: <Link href={`/operation/processing/${correctedBy[0].id}`} className="hover:underline app-link app-link-inline">{correctedBy[0].code}</Link>,
                    }] : []),
                    { label: t('processing.detail.totalInput'), value: run.total_input ?? '—' },
                    { label: t('processing.detail.totalOutput'), value: run.total_output ?? '—' },
                    {
                        label: t('processing.detail.loss'),
                        value: (run.loss_qty ?? '—') + (run.loss_qty != null && run.total_input
                            ? ` (${((run.loss_qty / run.total_input) * 100).toFixed(1)}%)` : ''),
                    },
                    {
                        // WO-1c:【没有就说「无计划」,不留空】—— 空白读起来像数据缺了,
                        // 而「临时起意的加工」是一个正当的类别。
                        label: t('processing.detail.workOrder'),
                        value: wo
                            ? <Link href={`/operation/orders/${wo.id}`}
                                    className="hover:underline app-link app-link-inline">{wo.code}</Link>
                            : <span className="text-[color:var(--brand-muted-text)] italic">{t('processing.noWorkOrder')}</span>,
                    },
                    {
                        label: t('processing.detail.materialCost'),
                        value: <MaskedValue value={run.material_cost_base === null ? null : formatAmount(run.material_cost_base, baseCurrency)} canView={showPrices} fallback="—" />,
                    },
                    {
                        label: t('processing.detail.processCost'),
                        value: <MaskedValue value={run.process_cost_base === null ? null : formatAmount(run.process_cost_base, baseCurrency)} canView={showPrices} fallback="—" />,
                    },
                    {
                        label: t('processing.detail.totalCost'),
                        value: <MaskedValue value={run.total_cost_base === null ? null : formatAmount(run.total_cost_base, baseCurrency)} canView={showPrices} fallback="—" />,
                    },
                    ...(run.notes ? [{ label: t('processing.detail.notes'), value: run.notes }] : []),
                ]}
            />

            {allocatedWhen && (
                <p className="mt-3 text-xs text-[color:var(--brand-muted-text)]">
                    {t('processing.allocation.lastRun', { when: allocatedWhen, basis: basisLabel })}
                </p>
            )}
            {skippedMetals.length > 0 && (
                <p className="mt-1 text-xs text-amber-600">
                    {t('processing.allocation.skippedMetals', {
                        metals: skippedMetals.map((m) => metalLabel(m)).join(locale === 'zh' ? '、' : ', '),
                    })}
                </p>
            )}

            <div className="space-y-6 mt-6">
                {/* 【差异读的是视图,不是这里算的】而且它是【整张工单】的差异,不是这一次
                    加工的 —— 一张工单可以有几次加工,差异只在工单这一层才有意义。
                    ☞ 守卫的是 wo 存不存在(记录的属性),画的是数据不是出口 —— §⑬-0c。 */}
                {wo && varianceRows.length > 0 && (
                    <section>
                        <h2 className="mb-2">
                            {t('processing.detail.varianceTitle', { code: wo.code })}
                        </h2>
                        <WoVarianceTable rows={varianceRows} />
                    </section>
                )}

                {/* 成本条目(仅已提交单) */}
                {isCommitted && <CostPanel runId={run.id} entries={costRows} canViewPrices={showPrices} />}

                {/* MES-4a(Q31):一张已回滚、还没被更正过的单 —— 从这里去记它的更正(新单指着它)。 */}
                {run.status === 'reversed' && correctedBy.length === 0 && (
                    <p className="text-sm">
                        <PermissionGate code="action.processing_commit" allowed={canCommitRun} inline>
                            {canCommitRun ? (
                                <Link href={`/operation/processing/new?corrects=${run.id}`} className="hover:underline app-link">
                                    {t('processing.rec.recordCorrection')}
                                </Link>
                            ) : (
                                <Button type="button" variant="link" size="inline" disabled>{t('processing.rec.recordCorrection')}</Button>
                            )}
                        </PermissionGate>
                    </p>
                )}

                {/* MES-4a:值、事件、平衡、抬头更正 —— 只在已提交单上能记;回滚了的单是历史。 */}
                {isCommitted && valueRows.length > 0 && <ValuesPanel runId={run.id} rows={valueRows} canEdit={canAftercare} />}
                {isCommitted && (
                    <EventsPanel runId={run.id} rows={eventRows} canEdit={canAftercare}
                                 types={eventTypes.filter((e) => e.is_active).map((e) => ({ code: e.code, label: nm(e) }))} />
                )}
                {balanceView && <BalancePanel runId={run.id} b={balanceView} canClose={canAftercare} />}
                {isCommitted && (
                    <HeaderCorrectionPanel runId={run.id} canCorrect={canCommitRun} current={headerCurrent}
                        shifts={shiftRows.filter((x) => x.is_active).map((x) => ({ value: x.code, label: nm(x) }))}
                        machines={machineOpts} recipes={recipeOpts} history={correctionRows} predates={!run.started_at} />
                )}

                {/* PROC-BUILD-1:损耗分类 —— 就记在损耗被记下来的这一页。
                    只在【已提交】单上;reversed 单是历史,不可改(与 CostPanel 同一条)。 */}
                {isCommitted && (
                    <LossPanel runId={run.id} categories={lossCategories} rows={lossRows}
                               lossQty={run.loss_qty ?? null} canEdit={canEditLosses} canDerive={canAftercare}
                               electrolyte={electrolyte} locale={locale} />
                )}

                {/* MES-4b(Q21–Q25):交叉污染抽检 —— 每一班、每一条流至少一次;只在已提交单上能记 */}
                {isCommitted && (
                    <ContaminationPanel runId={run.id} streams={contaminationStreams} checks={contaminationChecks}
                                        canRecord={canAftercare} predates={!run.started_at} />
                )}

                {/* MES-5a-1(Q5–Q13):放电那一炉 —— 每个模组一条结论;凑满了这一批才算已放电并核实;失败 · 隔离的从这里拆出去 */}
                {discharge && (
                    <DischargePanel runId={run.id} editable={isCommitted} batches={discharge.batches} results={discharge.results}
                                    channels={discharge.channels} splits={discharge.splits} canRecord={canConfirmCapture} canAftercare={canAftercare}
                                    devices={discharge.devices} locations={discharge.locations} locationsVisible={discharge.locationsVisible}
                                    shifts={discharge.shifts} processDate={run.process_date ?? ''} />
                )}
                {splitOrigin && (
                    <section className="mt-6" data-section="discharge-split-origin">
                        <h2 className="mb-1">{t('discharge.originTitle')}</h2>
                        <p className="text-sm">
                            {t('discharge.originLine', { modules: splitOrigin.modules.join(', ') })}{' '}
                            {splitOrigin.dischargeRunId
                                ? <Link href={`/operation/processing/${splitOrigin.dischargeRunId}`} className="hover:underline app-link app-link-inline">{splitOrigin.dischargeRunCode ?? '—'}</Link>
                                : '—'}
                        </p>
                    </section>
                )}

                {/* FIN-25:血缘 —— 深度 >1 才值得占版面(一段加工的直接投入上面已经列了)。
                    ☞ 这一条守卫【不是】空集守卫:depth>1 说的是「有没有多层」,
                       而单层血缘就是上面那张投入表,画出来是重复不是补充。 */}
                {lineage.some((l) => l.depth > 1) && (
                    <section>
                        <h2 className="mb-2">{t('processing.lineage.title')}</h2>
                        <LineageTable rows={lineageTableRows} />
                    </section>
                )}

                {/* 成本分摊(仅已提交单) */}
                {isCommitted && (
                    <div className="mt-8 pt-8 border-t">
                        <h2 className="mb-4">{t('processing.allocation.title')}</h2>
                        {/* 过期标记(FIN-24 起差额法):重跑把差额按处置拆 —— 在库→1220、
                            已售→5000 补 COGS、注销→5200,全记当期。已过账 COGS 不再是
                            不能重跑的理由;唯一的红 = 资本化分录被人工冲销(基线分道)。 */}
                        {(allocStatus?.is_stale
                          || (allocStatus && !allocStatus.allocated_at && allocStatus.last_cost_change)) && (
                            <div className={'mb-4 rounded border px-3 py-2 text-sm '
                                + (allocStatus.safe_to_reallocate
                                    ? 'border-amber-300 bg-amber-50 text-amber-900'
                                    : 'border-red-300 bg-red-50 text-red-900')}>
                                <p className="font-medium">
                                    {allocStatus.is_stale
                                        ? t('processing.allocation.stale')
                                        : t('processing.allocation.neverAllocated')}
                                </p>
                                <p className="mt-1 text-xs">
                                    {allocStatus.safe_to_reallocate
                                        ? t('processing.allocation.staleSafe')
                                        : t('processing.allocation.staleUnsafe')}
                                </p>
                            </div>
                        )}
                        {/* ★ 出口:重跑分摊。住 children,靠 state 恒为 'ok' 撑着;
                            它的守卫是 isCommitted —— 记录的状态,不是一个集合空不空。 */}
                        <AllocateButton runId={run.id} canAllocate={canAllocate} />
                    </div>
                )}

                {/* 投入 —— 空态由表自己说(CONV-8 §⑤ 的推论),不再自己画一行 colSpan */}
                <section>
                    <h2 className="mb-2">{t('processing.detail.inputsSectionHeader')}</h2>
                    <InputsTable rows={inputRows} />
                </section>

                {/* 产出 */}
                <section>
                    <h2 className="mb-2">{t('processing.detail.outputsSectionHeader')}</h2>
                    <OutputsTable rows={outputRows} canViewPrices={showPrices} />
                </section>

                {/* 金属回收率(仅已提交单) */}
                {isCommitted && (
                    <section>
                        <h2 className="mb-2">{t('processing.recovery.title')}</h2>
                        {!recoveryComputable && (
                            <p className="bg-amber-50 border border-amber-300 text-amber-900 px-4 py-3 rounded mb-3 text-sm">
                                {t('processing.recovery.runNotComputable')}
                            </p>
                        )}
                        {conservationRows.map((r) => (
                            <p key={'warn-' + r.metal}
                               className="bg-red-50 border border-red-300 text-red-800 px-4 py-3 rounded mb-3 text-sm">
                                <span className="font-medium">{t('processing.recovery.anomalyTitle')}</span>{' — '}
                                {Number(r.input_metal_kg) === 0
                                    ? t('processing.recovery.anomalyFromZero', {
                                          metal: metalLabel(r.metal), output: String(r.output_metal_kg),
                                      })
                                    : t('processing.recovery.anomaly', {
                                          metal: metalLabel(r.metal),
                                          input: String(r.input_metal_kg),
                                          output: String(r.output_metal_kg),
                                          pct: String(r.recovery_pct ?? '—'),
                                      })}
                                {' — '}
                                {t(anomalyCauseKey(r))}
                            </p>
                        ))}
                        {/* 空态由表自己说 —— 转换前这里是一句表外的 <p>,
                            于是「这一单没有可算的金属」和「表画不出来」长得一样。 */}
                        <RecoveryTable rows={recoveryTableRows} />
                    </section>
                )}
            </div>
            {/* AUDIT-TRAIL-1a:页底的审计记录 —— 这一单、它的投入、产出、成本条目与分摊 */}
            <AuditTrail subject="processing_run" id={id} show={trailCount((await searchParams).trail)} />
        </ListPage>
    )
}
