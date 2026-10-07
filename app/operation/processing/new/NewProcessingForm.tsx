'use client'

import { CONTROL_INPUT, CONTROL_SELECT, CONTROL_TEXTAREA } from '@/app/components/ui/control-style'
import { useRef, useState, useTransition } from 'react'
import Link from 'next/link'
import {
    commitProcessingRun,
    type CommitProcessingPayload,
} from './actions'
import { useTranslations, useLocale } from '@/lib/i18n/client'
import DecimalInput from '../../../components/forms/DecimalInput'
import { Button } from '@/app/components/ui/button'
import { DatePicker } from '@/app/components/ui/date-picker'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { formatDate, formatDateTime } from '@/lib/dates'
import ScanField from '@/app/components/scan/ScanField'
import type { ScanResult } from '@/app/components/scan/actions'

export type InboundBatchOption = {
    id: string
    code: string
    remaining_qty: number
    // IOD-1:可投的是可用,不是物理剩余(被扣住的货不可动用)
    available_qty: number
    unit: string
    // ROLE-1 Batch 3b:物料名由页面从 material_lookup 映射进来(仓库读不了 materials 基表,不再嵌入)
    materials: { name: string } | null
    /** MES-4b(Q4 · Q5):这一批的电芯结构 —— applicable = 它的形态装电芯(或没有形态);label 空 = 没记;determined = 卷绕或叠片 */
    cell: { applicable: boolean; label: string | null; determined: boolean }
}

// FIN-25:再加工 —— 可投料的产出批(同形;value 前缀区分来源)
export type OutputBatchOption = InboundBatchOption

// PROC-WIRE-1B-i:一道工序,连同它【收什么形态】与【产不产批】。
export type OperationOption = {
    code: string
    name_en: string
    name_zh: string
    produces_outputs: boolean
    input_forms: { code: string; name_en: string; name_zh: string }[]
    /** MES-4b(Q5):这道工序的每一批投料都必须带确定的电芯结构(服务端 INPUT_CELL_CONSTRUCTION_REQUIRED) */
    requires_cell_construction: boolean
    /** MES-4a(Q9):挂在这道工序上的、没处置的机器。非空 → 这一炉【必须】选其中一台(服务端 EQUIPMENT_REQUIRED_FOR_OPERATION)。 */
    machine_ids: string[]
    /** MES-4a(Q10–Q13):这道工序的参数与指标(只列在用的)。 */
    fields: FieldOption[]
    /** MES-4a(Q16):这道工序在用的配方的每一个版本(固定的、带编号的)。 */
    recipes: RecipeVersionOption[]
}

// MES-4a:一个字段的定义 —— 照它画输入框;越界只标出来,不拒(Q12)。
export type FieldOption = {
    code: string; name_en: string; name_zh: string
    kind: string; value_type: string; unit: string | null
    is_required: boolean; range_min: number | null; range_max: number | null
}
export type RecipeVersionOption = { version_id: string; label: string; param_values: Record<string, unknown> }
export type ShiftOption = { code: string; name_en: string; name_zh: string; starts_at: string | null; ends_at: string | null }
export type WeighingOption = {
    weighing_id: string; weight_kg: number; device_code: string | null
    captured_at: string; calibration_status: string
}
export type DeviceOption = { id: string; code: string; name: string }

type MaterialOption = {
    id: string
    code: string
    name: string
}

type InputRowState = {
    key: number
    // FIN-25:'in:<id>'(进料批)或 'out:<id>'(产出批再加工)
    batch_ref: string
    quantity_consumed: string
}

// MES-4a(Q24–Q25):每一条产出腿都是【称出来的】—— 挑一条现成的称重,或在这里敲一个重量(会记成一次手工称重)。
//   单位只能是 kg(服务端 OUTPUT_UNIT_NOT_KG),所以这里不再给单位下拉。
type OutputRowState = {
    key: number
    material_id: string
    mode: 'pick' | 'type'
    weighing_id: string
    weight_kg: string
    device_id: string
    purity: string
}

const blankOutput = (key: number): OutputRowState =>
    ({ key, material_id: '', mode: 'pick', weighing_id: '', weight_kg: '', device_id: '', purity: '' })

/** 一个字段的值,照它的类型从输入框的字符串翻成 JSON;空 = 没记。 */
function encodeValue(f: FieldOption, raw: string): unknown {
    const v = raw.trim()
    if (v === '') return null
    if (f.value_type === 'number' || f.value_type === 'count') return Number(v)
    if (f.value_type === 'yes_no') return v === 'true'
    return v
}
/** 配方里存的值 → 输入框里的字符串(与 encodeValue 互逆)。 */
function recipeString(v: unknown): string {
    if (v === null || v === undefined) return ''
    if (typeof v === 'boolean') return v ? 'true' : 'false'
    return String(v)
}

function todayIsoLocal(): string {
    const d = new Date()
    const yyyy = d.getFullYear()
    const mm = String(d.getMonth() + 1).padStart(2, '0')
    const dd = String(d.getDate()).padStart(2, '0')
    return `${yyyy}-${mm}-${dd}`
}

export default function NewProcessingForm({
    inboundBatches,
    outputBatches,
    materials,
    defaultAllocationBasis,
    workOrders,
    operations,
    equipment,
    shifts,
    weighingOptions,
    devices,
    corrects,
    canCommit,
    canReceive,
}: {
    inboundBatches: InboundBatchOption[]
    outputBatches: OutputBatchOption[]
    materials: MaterialOption[]
    /** 预选值,来自 finance_settings.default_allocation_basis(FIN-36)*/
    defaultAllocationBasis: string
    /** WO-1c:【只有已放行的】—— 服务端也拒(WO_NOT_RELEASED),这里不画必然被拒的选项 */
    workOrders: { id: string; code: string; scheduled_date: string | null }[]
    /** PROC-WIRE-1B-i:五道工序(R2),带它收什么形态、产不产批。
     *  **accepts / produces 都是从字典读来的**,不是在这里写死的 —— 加一道工序
     *  或者改它收什么,是加一行数据,这一屏不必改。 */
    operations: OperationOption[]
    /** UNBLOCK-1 Q21:可选的机器 —— 页面已滤掉已处置的(服务端也拒,EQUIPMENT_DISPOSED)。 */
    equipment: { id: string; code: string; description: string | null }[]
    /** MES-4a(Q8):班次 —— 必选。 */
    shifts: ShiftOption[]
    /** MES-4a(Q24):挑得到的称重(run_weighing_options —— 与提交时的判据同一组)。 */
    weighingOptions: WeighingOption[]
    /** MES-4a:敲重量时可以说是哪一台秤(可选;没说就标"没有记录仪器")。 */
    devices: DeviceOption[]
    /** MES-4a(Q31):这一炉是在【更正】哪一张已回滚的单(从那张单上的链接进来)。 */
    corrects: { id: string; code: string } | null
    /** ROLE-1 Batch 3b:提交 = commit_processing_run,归 action.processing_commit(页面 can() 算好传进来) */
    canCommit: boolean
    /** ROLE-1 Batch 3b:「先去建收货单」那条链接归 action.receive_goods */
    canReceive: boolean
}) {
    const t = useTranslations()
    const locale = useLocale()
    // FIN-36:成本分摊基准是【选出来的】。预选自公司配置,但屏幕上看得见、改得动 ——
    // 与它取代的那个 schema 默认值的区别全在这里。选中的值会显式送给
    // commit_processing_run(那边必填),所以"这一单用了什么方法"是记录,不是推断。
    const [allocationBasis, setAllocationBasis] = useState(defaultAllocationBasis)
    // WO-1c:照哪张工单做的。【默认不选】—— 临时起意的加工是合法的,而
    // 预选一张工单等于替人做了一个"这次是照计划做的"的判断。
    const [workOrderId, setWorkOrderId] = useState('')
    // UNBLOCK-1 Q21:用了哪台机器。【默认「未记录」】—— 预选一台机器等于替人
    // 断言这一炉在哪台机器上跑。
    const [equipmentId, setEquipmentId] = useState('')
    // PROC-WIRE-1B-i:【默认不选】—— 预选一道工序等于替人断言这一炉在跑哪台机器。
    const [operationCode, setOperationCode] = useState('')
    const operation = operations.find((o) => o.code === operationCode) ?? null
    // 【产不产批由字典说了算】不是"是不是深度放电"这种写死的判断。
    const producesOutputs = operation ? operation.produces_outputs : true
    // MES-4a(Q9):机器下拉只列这道工序挂着的那几台;一台都没挂时与服务端同一条规则 —— 任何一台都收,于是照旧全列。
    const linkedMachines = operation && operation.machine_ids.length > 0
        ? equipment.filter((m) => operation.machine_ids.includes(m.id))
        : null
    const machineOptions = linkedMachines ?? equipment
    // MES-4a(Q7–Q8):开始、结束、班次 —— 新单必填,服务端按名拒(RUN_TIMES_REQUIRED / RUN_SHIFT_REQUIRED)。
    const [startedAt, setStartedAt] = useState('')
    const [endedAt, setEndedAt] = useState('')
    const [shiftCode, setShiftCode] = useState('')
    // MES-4a(Q16):配方版本 —— 选了就把它的参数预填进下面的值;改了的值照记,并标出与配方的差。
    const [recipeVersionId, setRecipeVersionId] = useState('')
    const recipe = operation?.recipes.find((r) => r.version_id === recipeVersionId) ?? null
    const [values, setValues] = useState<Record<string, string>>({})
    function pickOperation(code: string) {
        setOperationCode(code)
        // 换工序:机器、配方、值都是那道工序的 —— 清掉,不留一个挂在别的工序上的选择。
        setEquipmentId(''); setRecipeVersionId(''); setValues({})
    }
    function pickRecipe(id: string) {
        setRecipeVersionId(id)
        const r = operation?.recipes.find((x) => x.version_id === id)
        if (!r) return
        const next: Record<string, string> = { ...values }
        for (const [k, v] of Object.entries(r.param_values)) next[k] = recipeString(v)
        setValues(next)
    }
    const keyCounter = useRef(0)
    const nextKey = () => keyCounter.current++

    const [inputRows, setInputRows] = useState<InputRowState[]>(() => [
        { key: nextKey(), batch_ref: '', quantity_consumed: '' },
    ])
    const [outputRows, setOutputRows] = useState<OutputRowState[]>(() => [blankOutput(nextKey())])
    const [processDate, setProcessDate] = useState(todayIsoLocal)
    const [notes, setNotes] = useState('')
    const [error, setError] = useState<string | null>(null)
    const [isPending, startTransition] = useTransition()
    // MES-3b(Q23):每一行投料一个扫码框 —— 扫到的批次在这张表单的选项里才选得上(有剩余、可投);不在就说为什么。
    //   投料的闸一条都没有搬到这里:可不可投、状态允不允许、够不够,照旧在提交时由 commit_processing_run / guard_processing_input 判。
    const [scanMiss, setScanMiss] = useState<Record<number, string>>({})
    function scanInto(key: number, r: ScanResult) {
        const ref = r.kind === 'inbound_batch' ? 'in:' + r.id : r.kind === 'output_batch' ? 'out:' + r.id : ''
        const listed = r.kind === 'inbound_batch' ? inboundBatches.some((b) => b.id === r.id) : outputBatches.some((b) => b.id === r.id)
        if (ref && listed) {
            updateInputRow(key, { batch_ref: ref })
            setScanMiss((m) => ({ ...m, [key]: '' }))
        } else {
            setScanMiss((m) => ({ ...m, [key]: t('processing.form.scanNotFeedable', { code: r.code ?? '' }) }))
        }
    }

    // 派生值(每次渲染重算)
    const totalInput = inputRows.reduce((sum, r) => {
        const n = Number(r.quantity_consumed)
        return Number.isNaN(n) || n <= 0 ? sum : sum + n
    }, 0)
    // MES-4a:一条腿的重量就是那次称重的公斤数 —— 挑的读称重本身,敲的读敲进来的数。
    const legKg = (r: OutputRowState): number => {
        if (r.mode === 'pick') return weighingOptions.find((w) => w.weighing_id === r.weighing_id)?.weight_kg ?? 0
        const n = Number(r.weight_kg)
        return Number.isNaN(n) || n <= 0 ? 0 : n
    }
    const totalOutput = producesOutputs ? outputRows.reduce((sum, r) => sum + legKg(r), 0) : 0
    // MES-4a(Q17):损耗【就是】投入 − 产出,由数据库算出来记下;这里只是把那个数先给人看,不能改。
    const autoLoss = totalInput - totalOutput

    // 投入行操作
    function updateInputRow(key: number, patch: Partial<InputRowState>) {
        setInputRows((rows) =>
            rows.map((r) => (r.key === key ? { ...r, ...patch } : r))
        )
    }
    function addInputRow() {
        setInputRows((rows) => [
            ...rows,
            { key: nextKey(), batch_ref: '', quantity_consumed: '' },
        ])
    }
    function removeInputRow(key: number) {
        setInputRows((rows) => {
            // 至少保留一行;最后一行就地清空
            if (rows.length === 1) {
                return [{ key: rows[0].key, batch_ref: '', quantity_consumed: '' }]
            }
            return rows.filter((r) => r.key !== key)
        })
    }

    // 产出行操作
    function updateOutputRow(key: number, patch: Partial<OutputRowState>) {
        setOutputRows((rows) =>
            rows.map((r) => (r.key === key ? { ...r, ...patch } : r))
        )
    }
    function addOutputRow() {
        setOutputRows((rows) => [...rows, blankOutput(nextKey())])
    }
    function removeOutputRow(key: number) {
        setOutputRows((rows) => {
            if (rows.length === 1) return [blankOutput(rows[0].key)]
            return rows.filter((r) => r.key !== key)
        })
    }

    function handleSubmit(e: React.FormEvent) {
        e.preventDefault()
        setError(null)

        const validRows = inputRows.filter((r) => r.batch_ref && Number(r.quantity_consumed) > 0)
        const validInputs = validRows.map((r) => ({
            ...(r.batch_ref.startsWith('out:')
                ? { output_batch_id: r.batch_ref.slice(4) }
                : { inbound_batch_id: r.batch_ref.slice(3) }),
            quantity_consumed: Number(r.quantity_consumed),
        }))

        if (validInputs.length === 0) {
            setError(t('processing.validation.needValidInput'))
            return
        }

        const seen = new Set<string>()
        for (const r of validRows) {
            if (seen.has(r.batch_ref)) {
                setError(t('processing.validation.duplicateInputClient'))
                return
            }
            seen.add(r.batch_ref)
        }

        for (const r of validRows) {
            const pool = r.batch_ref.startsWith('out:') ? outputBatches : inboundBatches
            const batch = pool.find((b) => b.id === r.batch_ref.slice(r.batch_ref.indexOf(':') + 1))
            if (batch && Number(r.quantity_consumed) > batch.available_qty) {
                setError(t('processing.validation.consumeExceedsClient', { code: batch.code }))
                return
            }
            // MES-4b(Q5):分极片的工序要知道电芯是卷绕还是叠片 —— 与服务端同一句判据(没记或"未知"都过不去);权威仍是服务端
            if (batch && operation?.requires_cell_construction && !batch.cell.determined) {
                setError(t('processing.validation.cellConstructionRequired', { code: batch.code }))
                return
            }
        }

        // MES-4a(Q4):【只有产出批的工序才要产出】—— 深度放电那一类不产批,从前这一行把它挡在了页面上。
        const filled = outputRows.filter((r) => r.material_id && (r.mode === 'pick' ? r.weighing_id : Number(r.weight_kg) > 0))
        const validOutputs = producesOutputs ? filled.map((r) => ({
            material_id: r.material_id,
            unit: 'kg',
            purity: r.purity.trim() || null,
            ...(r.mode === 'pick'
                ? { weighing_id: r.weighing_id }
                : { weight_kg: Number(r.weight_kg), device_id: r.device_id || null }),
        })) : []

        if (producesOutputs && validOutputs.length === 0) {
            setError(t('processing.validation.needValidOutput'))
            return
        }

        const inSum = validInputs.reduce((s, r) => s + r.quantity_consumed, 0)
        if (producesOutputs && totalOutput > inSum) {
            setError(t('processing.validation.outputExceedsInputClient'))
            return
        }

        // MES-4a(Q11 · Q16):只送【不是照配方】的那些值 —— 配方里的由数据库记成 source = recipe,
        // 改了的、配方里没有的记成 manual。空的不送(没记 ≠ 记了一个空)。
        const p_values: Record<string, unknown> = {}
        for (const f of operation?.fields ?? []) {
            const raw = values[f.code] ?? ''
            if (raw.trim() === '') continue
            const fromRecipe = recipe && Object.prototype.hasOwnProperty.call(recipe.param_values, f.code)
                ? recipeString(recipe.param_values[f.code]) : null
            if (fromRecipe !== null && fromRecipe === raw.trim()) continue
            p_values[f.code] = encodeValue(f, raw)
        }

        const payload: CommitProcessingPayload = {
            process_date: processDate,
            notes: notes.trim() || null,
            inputs: validInputs,
            outputs: validOutputs,
            allocation_basis: allocationBasis,
            work_order_id: workOrderId || null,
            equipment_id: equipmentId || null,
            operation_type_code: operationCode || null,
            // 选择器交出的是新加坡钟面时刻 + 偏移的 ISO(与全库的日期时间框同一条);库里按新加坡日期判(Q8)。
            started_at: startedAt || null,
            ended_at: endedAt || null,
            shift_code: shiftCode || null,
            recipe_version_id: recipeVersionId || null,
            values: Object.keys(p_values).length > 0 ? p_values : null,
            corrects_run_id: corrects?.id ?? null,
        }

        startTransition(async () => {
            const result = await commitProcessingRun(payload)
            if (result?.error) setError(result.error)
            // 成功:服务端 redirect 接管
        })
    }

    return (
        <div className="p-8 max-w-3xl">
            <div className="mb-6">
                <Link
                    href="/operation/processing"
                    className="hover:underline text-sm app-link"
                >
                    {t('common.back')}
                </Link>
            </div>

            <h1 className="mb-6">{t('processing.newTitle')}</h1>

            {error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-4">
                    {error}
                </div>
            )}

            {/* MES-4a(Q31):从一张已回滚的单上点进来的 —— 这一炉是它的更正,两张单互相指着。 */}
            {corrects && (
                <div className="border border-amber-300 bg-amber-50 text-amber-900 px-4 py-3 rounded mb-4 text-sm" data-corrects={corrects.code}>
                    {t('processing.rec.correctsBanner', { code: corrects.code })}
                </div>
            )}

            <form onSubmit={handleSubmit} className="space-y-4">
                {/* 成本分摊基准(FIN-36)—— 预选自公司配置,但【必须看得见、改得动】。
                    它直接决定每个产出批次的报告毛利:同一张单按重量与按金属价值分摊,
                    单位成本可以差出一倍以上(FIN-25 量过 62.50 对 27.50)。 */}
                <div>
                    <label className="block mb-1">
                        {t('processing.form.basisLabel')}
                    </label>
                    <select
                        value={allocationBasis}
                        onChange={(e) => setAllocationBasis(e.target.value)}
                        className={`${CONTROL_SELECT} w-full`}
                    >
                        <option value="metal_value">{t('processing.allocation.basis.metal_value')}</option>
                        <option value="weight">{t('processing.allocation.basis.weight')}</option>
                    </select>
                    <p className="text-xs text-[color:var(--brand-muted-text)] mt-1">{t('processing.form.basisHint')}</p>
                </div>

                {/* WO-1c:照哪一张工单做的 —— 【可选】。
                    【为什么不从计划里预填投料】计划写的是【物料】(排计划时批次往往
                    还不存在),而这里填的是【批次】。系统挑一个批次填进去,会是一个
                    看起来很合理、而车间当天未必是这么投的答案 —— 一个似是而非的
                    错答案比留空坏得多(与 restricted-is-not-zero 同一条)。
                    挑批次是开工那天的决定,这里只问"这次算在哪张计划上"。 */}
                <div>
                    <label className="block mb-1">
                        {t('processing.form.workOrderLabel')}
                    </label>
                    <select
                        value={workOrderId}
                        onChange={(e) => setWorkOrderId(e.target.value)}
                        className={`${CONTROL_SELECT} w-full`}
                    >
                        <option value="">{t('processing.form.workOrderNone')}</option>
                        {workOrders.map((w) => (
                            <option key={w.id} value={w.id}>
                                {w.code}{w.scheduled_date ? ` — ${formatDate(w.scheduled_date, locale)}` : ''}
                            </option>
                        ))}
                    </select>
                    <p className="text-xs text-[color:var(--brand-muted-text)] mt-1">{t('processing.form.workOrderHint')}</p>
                </div>

                {/* 加工日期 —— 必填(决定分录期间)。预填今天是【便利】不是默认值:
                    记录加工的通常就是当天开工的人;清空则禁钮并在按钮旁点名。 */}
                <div>
                    <label className="block mb-1">
                        {t('processing.form.dateLabel')} <span className="text-red-600">*</span>
                    </label>
                    {/* 从前的 onBlur 回写已删:日期框的值只来自 React 状态,没有 DOM 漂移(DATE-PICK-1) */}
                    <DatePicker
                        required
                        value={processDate}
                        onChange={setProcessDate}
                        className="flex"
                    />
                </div>

                {/* PROC-WIRE-1B-i:这一炉跑哪一道工序 —— 它决定收什么料、产不产批,
                    以及那道【起火】闸受理哪些安全状态。 */}
                <div>
                    <label className="block mb-1">
                        {t('processing.form.operationLabel')} <span className="text-red-600">*</span>
                    </label>
                    <select
                        value={operationCode}
                        onChange={(e) => pickOperation(e.target.value)}
                        className={`${CONTROL_SELECT} w-full`}
                    >
                        <option value="">{t('processing.form.operationPlaceholder')}</option>
                        {operations.map((o) => (
                            <option key={o.code} value={o.code}>
                                {locale === 'zh' ? o.name_zh : o.name_en}
                            </option>
                        ))}
                    </select>
                    {/* 【收什么形态,照字典画出来】操作员不必去猜这台机器吃不吃这批料。 */}
                    {operation && (
                        <p className="text-xs text-[color:var(--brand-muted-text)] mt-1">
                            {t('processing.form.operationAccepts', {
                                forms: operation.input_forms
                                    .map((f) => (locale === 'zh' ? f.name_zh : f.name_en))
                                    .join(locale === 'zh' ? '、' : ', '),
                            })}
                        </p>
                    )}
                    {operation && !producesOutputs && (
                        <p className="text-xs text-amber-700 mt-1">
                            {t('processing.form.operationNoOutputs')}
                        </p>
                    )}
                </div>

                {/* MES-4a(Q9):用了哪台机器。这道工序挂着机器时【必选】,而且只列挂着的那几台;
                    一台都没挂时与今天一样可以留「未记录」。已处置的不列(服务端也拒,EQUIPMENT_*)。 */}
                <div>
                    <label className="block mb-1">
                        {linkedMachines ? t('processing.rec.machineRequired') : t('processing.form.machine')}
                        {linkedMachines && <span className="text-red-600"> *</span>}
                    </label>
                    <select
                        value={equipmentId}
                        onChange={(e) => setEquipmentId(e.target.value)}
                        className={`${CONTROL_SELECT} w-full`}
                        data-field="machine"
                    >
                        <option value="" disabled={!!linkedMachines}>
                            {linkedMachines ? t('processing.rec.machinePick') : t('processing.form.machineNone')}
                        </option>
                        {machineOptions.map((m) => (
                            <option key={m.id} value={m.id}>
                                {m.code}{m.description ? ` — ${m.description}` : ''}
                            </option>
                        ))}
                    </select>
                    <p className="text-xs text-[color:var(--brand-muted-text)] mt-1">
                        {linkedMachines ? t('processing.rec.machineLinkedHint') : t('processing.form.machineHint')}
                    </p>
                </div>

                {/* MES-4a(Q7–Q8):这一炉几点开始、几点结束、哪一个班。三样都必填;加工日期必须落在开始与结束的新加坡日期之间。 */}
                <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
                    <label className="block">
                        <span className="block mb-1">{t('processing.rec.startedAt')} <span className="text-red-600">*</span></span>
                        <DatePicker kind="datetime" required value={startedAt} onChange={setStartedAt} className="flex" />
                    </label>
                    <label className="block">
                        <span className="block mb-1">{t('processing.rec.endedAt')} <span className="text-red-600">*</span></span>
                        <DatePicker kind="datetime" required value={endedAt} onChange={setEndedAt} className="flex" />
                    </label>
                    <label className="block">
                        <span className="block mb-1">{t('processing.rec.shift')} <span className="text-red-600">*</span></span>
                        <select value={shiftCode} onChange={(e) => setShiftCode(e.target.value)}
                                className={`${CONTROL_SELECT} w-full`} data-field="shift_code">
                            <option value="" disabled>{t('processing.rec.shiftPick')}</option>
                            {shifts.map((sh) => (
                                <option key={sh.code} value={sh.code}>
                                    {locale === 'zh' ? sh.name_zh : sh.name_en}
                                    {sh.starts_at && sh.ends_at ? ` (${sh.starts_at.slice(0, 5)}–${sh.ends_at.slice(0, 5)})` : ''}
                                </option>
                            ))}
                        </select>
                    </label>
                </div>
                <p className="text-xs text-[color:var(--brand-muted-text)] -mt-2">{t('processing.rec.timesHint')}</p>

                {/* MES-4a(Q10–Q16):这道工序的参数与指标,以及配方。值照记,不拒:越界的只标出来,必填的到结算时才查。 */}
                {operation && operation.fields.length > 0 && (
                    <section className="border border-gray-200 rounded p-4 space-y-3" data-section="values">
                        <h2>{t('processing.rec.valuesTitle')}</h2>
                        <p className="text-xs text-[color:var(--brand-muted-text)]">{t('processing.rec.valuesIntro')}</p>
                        <label className="block">
                            <span className="block mb-1">{t('processing.rec.recipe')}</span>
                            <select value={recipeVersionId} onChange={(e) => pickRecipe(e.target.value)}
                                    className={`${CONTROL_SELECT} w-full`} data-field="recipe_version_id">
                                <option value="">{t('processing.rec.recipeNone')}</option>
                                {operation.recipes.map((r) => (
                                    <option key={r.version_id} value={r.version_id}>{r.label}</option>
                                ))}
                            </select>
                            {operation.recipes.length === 0 && (
                                <span className="text-xs text-[color:var(--brand-muted-text)]">{t('processing.rec.recipeNoneDefined')}</span>
                            )}
                        </label>
                        <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
                            {operation.fields.map((f) => {
                                const raw = values[f.code] ?? ''
                                const num = Number(raw)
                                const isNum = f.value_type === 'number' || f.value_type === 'count'
                                const outOfRange = isNum && raw.trim() !== '' && !Number.isNaN(num)
                                    && ((f.range_min !== null && num < f.range_min) || (f.range_max !== null && num > f.range_max))
                                const inRecipe = recipe && Object.prototype.hasOwnProperty.call(recipe.param_values, f.code)
                                const recipeRaw = inRecipe ? recipeString(recipe!.param_values[f.code]) : null
                                const differs = recipeRaw !== null && recipeRaw !== raw.trim()
                                const set = (v: string) => setValues({ ...values, [f.code]: v })
                                return (
                                    <div key={f.code} data-value-field={f.code}>
                                        <span className="block mb-1 text-sm">
                                            {locale === 'zh' ? f.name_zh : f.name_en}
                                            {f.unit ? ` (${f.unit})` : ''}
                                            {f.is_required && <span className="text-red-600"> *</span>}
                                            <span className="ml-2 text-xs text-[color:var(--brand-muted-text)]">
                                                {t(f.kind === 'parameter' ? 'processing.rec.kindParameter' : 'processing.rec.kindIndicator')}
                                            </span>
                                        </span>
                                        {f.value_type === 'yes_no' ? (
                                            <select value={raw} onChange={(e) => set(e.target.value)} className={`${CONTROL_SELECT} w-full`}>
                                                <option value="">{t('processing.rec.notRecorded')}</option>
                                                <option value="true">{t('common.yes')}</option>
                                                <option value="false">{t('common.no')}</option>
                                            </select>
                                        ) : isNum ? (
                                            <DecimalInput value={raw} onChange={set} className="w-full" />
                                        ) : (
                                            <input value={raw} onChange={(e) => set(e.target.value)} className={`${CONTROL_INPUT} w-full`} />
                                        )}
                                        {(f.range_min !== null || f.range_max !== null) && (
                                            <span className="block text-xs text-[color:var(--brand-muted-text)]">
                                                {t('processing.rec.range', { min: f.range_min ?? '—', max: f.range_max ?? '—' })}
                                            </span>
                                        )}
                                        {outOfRange && <span className="block text-xs text-amber-700">{t('processing.rec.outOfRange')}</span>}
                                        {differs && (
                                            <span className="block text-xs text-amber-700">
                                                {t('processing.rec.differsFromRecipe', { value: recipeRaw === '' ? '—' : recipeRaw! })}
                                            </span>
                                        )}
                                    </div>
                                )
                            })}
                        </div>
                        {operation.fields.some((f) => f.is_required) && (
                            <p className="text-xs text-[color:var(--brand-muted-text)]">{t('processing.rec.requiredHint')}</p>
                        )}
                    </section>
                )}

                {/* 投入 */}
                <section className="border border-gray-200 rounded p-4 space-y-3">
                    <div className="flex items-center justify-between">
                        <h2 className="">{t('processing.form.inputsSectionHeader')}</h2>
                        <Button
                            variant="link"
                            size="inline"
                            type="button"
                            onClick={addInputRow}
                        >
                            {t('processing.form.addInputButton')}
                        </Button>
                    </div>
                    {inputRows.map((row) => {
                        const selectedBatch = (row.batch_ref.startsWith('out:') ? outputBatches : inboundBatches)
                            .find((b) => b.id === row.batch_ref.slice(row.batch_ref.indexOf(':') + 1))
                        const qtyNum = Number(row.quantity_consumed)
                        const exceeds =
                            selectedBatch &&
                            !Number.isNaN(qtyNum) &&
                            qtyNum > selectedBatch.available_qty
                        return (
                            <div key={row.key}>
                                <ScanField context="feed" accept={['inbound_batch', 'output_batch']} compact
                                           onFound={(r) => scanInto(row.key, r)} testId={`scan-feed-${row.key}`} />
                                {scanMiss[row.key] && <p className="text-sm text-amber-700 mb-1">{scanMiss[row.key]}</p>}
                                <div className="flex flex-wrap gap-2 items-start mt-1">
                                    <select
                                        value={row.batch_ref}
                                        onChange={(e) =>
                                            updateInputRow(row.key, {
                                                batch_ref: e.target.value,
                                            })
                                        }
                                        className={`${CONTROL_SELECT} flex-1`}
                                    >
                                        <option value="" disabled>
                                            {t('processing.form.selectInboundBatch')}
                                        </option>
                                        <optgroup label={t('processing.form.groupInbound')}>
                                            {inboundBatches.map((b) => (
                                                <option key={b.id} value={'in:' + b.id}>
                                                    {t('processing.form.inboundOptionLabel', {
                                                        code: b.code,
                                                        name: b.materials?.name ?? '—',
                                                        remaining: b.available_qty,
                                                        unit: b.unit,
                                                    })}
                                                </option>
                                            ))}
                                        </optgroup>
                                        {/* FIN-25:再加工 —— 产出批喂回下一段 */}
                                        {outputBatches.length > 0 && (
                                            <optgroup label={t('processing.form.groupOutput')}>
                                                {outputBatches.map((b) => (
                                                    <option key={b.id} value={'out:' + b.id}>
                                                        {t('processing.form.inboundOptionLabel', {
                                                            code: b.code,
                                                            name: b.materials?.name ?? '—',
                                                            remaining: b.available_qty,
                                                            unit: b.unit,
                                                        })}
                                                    </option>
                                                ))}
                                            </optgroup>
                                        )}
                                    </select>
                                    <DecimalInput
                                        placeholder={t('processing.form.consumeQtyPlaceholder')}
                                        value={row.quantity_consumed}
                                        onChange={(raw) =>
                                            updateInputRow(row.key, {
                                                quantity_consumed: raw,
                                            })
                                        }
                                        className="w-32"
                                    />
                                    <Button
                                        variant="secondary"
                                        size="inline"
                                        type="button"
                                        onClick={() => removeInputRow(row.key)}
                                        className="text-sm"
                                    >
                                        {t('processing.form.rowDelete')}
                                    </Button>
                                </div>
                                {exceeds && (
                                    <p className="text-red-600 text-xs mt-1 ml-1">{t('processing.form.rowExceeds')}</p>
                                )}
                                {/* MES-4b(Q4 · Q5):这一批的电芯结构;这道工序要求而它没有确定的结构时,说出来并指到批次页 */}
                                {selectedBatch && selectedBatch.cell.applicable && (
                                    <p className={`text-xs mt-1 ml-1 ${operation?.requires_cell_construction && !selectedBatch.cell.determined ? 'text-red-600' : 'text-[color:var(--brand-muted-text)]'}`}
                                       data-cell-construction={selectedBatch.cell.determined ? 'determined' : 'missing'}>
                                        {t('cellConstruction.label')}: {selectedBatch.cell.label ?? t('cellConstruction.notRecorded')}
                                        {operation?.requires_cell_construction && !selectedBatch.cell.determined && (
                                            <>
                                                {' — '}{t('processing.form.cellConstructionNeeded')}{' '}
                                                <a href={row.batch_ref.startsWith('out:') ? `/output/${selectedBatch.id}/edit` : `/inbound/${selectedBatch.id}/edit`}
                                                   className="underline">{t('processing.form.openBatch')}</a>
                                            </>
                                        )}
                                    </p>
                                )}
                            </div>
                        )
                    })}
                    {/* ROLE-1 Batch 3b:建收货单归 action.receive_goods。缺码时这条链接换成一颗
                        按不动的钮 + PermissionGate 点名那个码(链接禁不掉)。外层从 <p> 换成 <div>:
                        PermissionGate 里有 <fieldset>,它不许出现在 <p> 里。 */}
                    {inboundBatches.length === 0 && (
                        <div className="text-xs text-amber-600">
                            {t('processing.form.noInboundHelper')}
                            {canReceive ? (
                                <Link href="/inbound/new" className="underline">
                                    {t('processing.form.noInboundLink')}
                                </Link>
                            ) : (
                                <PermissionGate code="action.receive_goods" allowed={false} inline>
                                    <Button type="button" variant="link" size="inline" disabled>
                                        {t('processing.form.noInboundLink')}
                                    </Button>
                                </PermissionGate>
                            )}
                            {t('processing.form.noInboundHelperPost')}
                        </div>
                    )}
                </section>

                {/* 产出 */}
                {/* PROC-WIRE-1B-i:不产出的工序【连产出区都不画】——
                    画一个"填了就会被拒"的区域,是在制造一个必然的错误。 */}
                {producesOutputs && (
                <section className="border border-gray-200 rounded p-4 space-y-3">
                    <div className="flex items-center justify-between">
                        <h2 className="">{t('processing.form.outputsSectionHeader')}</h2>
                        <Button
                            variant="link"
                            size="inline"
                            type="button"
                            onClick={addOutputRow}
                        >
                            {t('processing.form.addOutputButton')}
                        </Button>
                    </div>
                    <p className="text-xs text-[color:var(--brand-muted-text)]">{t('processing.rec.outputsWeighedHint')}</p>
                    {outputRows.map((row) => {
                        const takenElsewhere = new Set(outputRows.filter((r) => r.key !== row.key && r.mode === 'pick').map((r) => r.weighing_id))
                        const picked = weighingOptions.find((w) => w.weighing_id === row.weighing_id) ?? null
                        return (
                        <div key={row.key} className="border-t border-gray-100 pt-3 space-y-2" data-output-row={row.key}>
                            <div className="flex flex-wrap gap-2 items-start">
                                <select
                                    value={row.material_id}
                                    onChange={(e) => updateOutputRow(row.key, { material_id: e.target.value })}
                                    className={`${CONTROL_SELECT} flex-1 min-w-0`}
                                >
                                    <option value="" disabled>
                                        {t('processing.form.selectOutputMaterial')}
                                    </option>
                                    {materials.map((m) => (
                                        <option key={m.id} value={m.id}>
                                            {m.code} - {m.name}
                                        </option>
                                    ))}
                                </select>
                                <input
                                    type="text"
                                    placeholder={t('processing.form.purityPlaceholder')}
                                    value={row.purity}
                                    onChange={(e) => updateOutputRow(row.key, { purity: e.target.value })}
                                    className={`${CONTROL_INPUT} w-36`}
                                />
                                <Button
                                    variant="secondary"
                                    size="inline"
                                    type="button"
                                    onClick={() => removeOutputRow(row.key)}
                                    className="text-sm"
                                >
                                    {t('processing.form.rowDelete')}
                                </Button>
                            </div>
                            {/* 这一条腿的重量从哪儿来:挑一条现成的称重,或者在这里敲(会记成一次手工称重) */}
                            <div className="flex flex-wrap gap-x-4 gap-y-1 text-sm">
                                <label className="inline-flex items-center gap-1">
                                    <input type="radio" name={`mode-${row.key}`} checked={row.mode === 'pick'}
                                           onChange={() => updateOutputRow(row.key, { mode: 'pick', weight_kg: '', device_id: '' })} />
                                    {t('processing.rec.modePick')}
                                </label>
                                <label className="inline-flex items-center gap-1">
                                    <input type="radio" name={`mode-${row.key}`} checked={row.mode === 'type'}
                                           onChange={() => updateOutputRow(row.key, { mode: 'type', weighing_id: '' })} />
                                    {t('processing.rec.modeType')}
                                </label>
                            </div>
                            {row.mode === 'pick' ? (
                                <div>
                                    <select value={row.weighing_id}
                                            onChange={(e) => updateOutputRow(row.key, { weighing_id: e.target.value })}
                                            className={`${CONTROL_SELECT} w-full`} data-field="weighing_id">
                                        <option value="" disabled>{t('processing.rec.pickWeighing')}</option>
                                        {weighingOptions.filter((w) => !takenElsewhere.has(w.weighing_id)).map((w) => (
                                            <option key={w.weighing_id} value={w.weighing_id}>
                                                {t('processing.rec.weighingOption', {
                                                    kg: w.weight_kg,
                                                    device: w.device_code ?? t('processing.rec.noInstrument'),
                                                    when: formatDateTime(w.captured_at, locale),
                                                    status: t('calibration.status.' + w.calibration_status),
                                                })}
                                            </option>
                                        ))}
                                    </select>
                                    {weighingOptions.length === 0 && (
                                        <p className="text-xs text-[color:var(--brand-muted-text)] mt-1">{t('processing.rec.noWeighings')}</p>
                                    )}
                                    {picked && picked.calibration_status !== 'in_calibration' && picked.calibration_status !== 'not_recorded' && (
                                        <p className="text-xs text-red-700 mt-1">{t('processing.rec.weighingNotCalibrated')}</p>
                                    )}
                                </div>
                            ) : (
                                <div className="flex flex-wrap gap-2 items-start">
                                    <DecimalInput
                                        placeholder={t('processing.rec.weightKg')}
                                        value={row.weight_kg}
                                        onChange={(raw) => updateOutputRow(row.key, { weight_kg: raw })}
                                        className="w-32"
                                    />
                                    <span className="self-center text-sm">kg</span>
                                    <select value={row.device_id}
                                            onChange={(e) => updateOutputRow(row.key, { device_id: e.target.value })}
                                            className={`${CONTROL_SELECT} flex-1 min-w-0`}>
                                        <option value="">{t('processing.rec.deviceNone')}</option>
                                        {devices.map((d) => <option key={d.id} value={d.id}>{d.code} — {d.name}</option>)}
                                    </select>
                                </div>
                            )}
                        </div>
                        )
                    })}
                </section>
                )}

                {/* 合计 + 损耗 */}
                <div className="bg-gray-50 rounded p-4 space-y-2">
                    <div className="flex items-center gap-6 flex-wrap">
                        <div>
                            <span className="text-sm text-[color:var(--brand-muted-text)] mr-1">{t('processing.form.totalInputLabel')}</span>
                            <span className="font-medium">{totalInput}</span>
                        </div>
                        <div>
                            <span className="text-sm text-[color:var(--brand-muted-text)] mr-1">{t('processing.form.totalOutputLabel')}</span>
                            <span className="font-medium">{totalOutput}</span>
                        </div>
                        <div>
                            <span className="text-sm text-[color:var(--brand-muted-text)] mr-1">{t('processing.form.lossLabel')}</span>
                            <span className="font-medium" data-derived-loss>{Number(autoLoss.toFixed(6))}</span>
                        </div>
                    </div>
                    {/* MES-4a(Q17):损耗是投入 − 产出,不能手改 —— 少掉的去了哪儿,在单子上按类别记(损耗分类),差额在结算时写解释。 */}
                    <p className="text-xs text-[color:var(--brand-muted-text)]">{t('processing.rec.lossDerivedHint')}</p>
                    {autoLoss < 0 && (
                        <p className="text-red-600 text-xs">{t('processing.form.outputExceedsWarning')}</p>
                    )}
                </div>

                {/* 备注 */}
                <div>
                    <label className="block mb-1">{t('processing.form.notesLabel')}</label>
                    <textarea
                        value={notes}
                        onChange={(e) => setNotes(e.target.value)}
                        className={`${CONTROL_TEXTAREA} w-full`}
                    />
                </div>

                {/* 提交按钮 —— 禁用必须说出为什么(CMP-2):每个禁钮条件都有紧邻的一行字。 */}
                {!processDate && (
                    <p className="text-sm text-amber-700">{t('processing.form.blockedProcessDate')}</p>
                )}
                {(!startedAt || !endedAt || !shiftCode) && (
                    <p className="text-sm text-amber-700">{t('processing.rec.blockedHeader')}</p>
                )}
                {linkedMachines && !equipmentId && (
                    <p className="text-sm text-amber-700">{t('processing.rec.blockedMachine')}</p>
                )}
                <div className="flex gap-3 pt-4">
                    <PermissionGate code="action.processing_commit" allowed={canCommit} inline>
                        <Button
                            type="submit"
                            disabled={isPending || !processDate || !startedAt || !endedAt || !shiftCode || (!!linkedMachines && !equipmentId)}
                        >
                            {isPending ? t('processing.form.saving') : t('processing.form.saveRun')}
                        </Button>
                    </PermissionGate>
                    <Button asChild variant="secondary">
                        <Link
                            href="/operation/processing"
                        >
                            {t('common.cancel')}
                        </Link>
                    </Button>
                </div>
            </form>
        </div>
    )
}
