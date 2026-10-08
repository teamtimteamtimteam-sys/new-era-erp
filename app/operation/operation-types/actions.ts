'use server'

// MES-4a(2026-10-07,Step 0 Q1 · Q9–Q17,Tim):一道工序的配置 —— 平衡容差(V1)、参数与指标(字段)、挂着的机器、配方与版本。
//
// 【这里不重写规则】一个字段退役不删、用过之后类型与单位不许改、机器只挂设备类的资产卡、配方的码与工序定了不改、
// 一个版本写了不改 —— 全在表上的守卫与函数里(guard_operation_type_field / guard_operation_type_equipment /
// guard_process_recipe / create_recipe_version)。这里只做两件事:把输入框的字符串变成列的值(空 = NULL = 还没有人给,
// 不是 0),以及把库里的拒绝翻成人话。
// 【写码】全是 module.processing.edit —— 与这几张表的写策略同一个码;零行落地不报成功(refuseNothingChanged)。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { getTranslations } from '@/lib/i18n/server'
import type { Json, TablesUpdate } from '@/lib/database.types'
import { refuseNothingChanged } from '@/lib/action-refusal'
import { localizeProcessingError } from '../errorCodes'

export type OpState = { error?: string }

const EDIT = 'module.processing.edit'

// 表上的约束名 → 一句话(库直接抛的,不经函数)。认不出的交给加工那一支(它再交给共用兜底)。
const CONSTRAINTS = [
    'operation_type_fields_range_shape', 'operation_type_fields_field_code_check', 'operation_type_fields_pkey',
    'process_recipes_code_check', 'process_recipes_code_key', 'operation_types_balance_tolerance_pct_check',
    'operation_type_equipment_pkey', 'operation_types_electrolyte_share_pct_check',
    'operation_type_output_forms_expected_yield_pct_check',
] as const

async function opError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const hit = CONSTRAINTS.find((c) => raw.includes(`"${c}"`))
    if (hit) return (await getTranslations())('processing.opType.errors.' + hit)
    return localizeProcessingError(raw)
}

function refresh(code: string) {
    revalidatePath('/operation/operation-types')
    revalidatePath(`/operation/operation-types/${code}`)
    revalidatePath('/settings/pending-values')
}

/** 空 = NULL(还没有人给);别的形状按名拒,不猜。 */
function numOrNull(raw: string): number | null | 'bad' {
    const v = raw.trim()
    if (v === '') return null
    const n = Number(v)
    return Number.isFinite(n) ? n : 'bad'
}

/** V1:这道工序的物料平衡容差(%)。空 = 还没给 —— 那时每一炉结算都要写解释。 */
export async function setTolerance(code: string, raw: string): Promise<OpState> {
    const t = await getTranslations()
    const v = numOrNull(raw)
    if (v === 'bad' || (v !== null && v < 0)) return { error: t('processing.opType.errTolerance') }
    const supabase = await createClient()
    const { data, error } = await supabase.from('operation_types')
        .update({ balance_tolerance_pct: v }).eq('code', code).select('code')
    if (error) return { error: await opError(error.message) }
    if (!data || data.length === 0) return { error: (await refuseNothingChanged(EDIT)).error }
    refresh(code)
    return {}
}

/** MES-5b-1(V37;Step 0 Q15,Tim):这道工序 × 这一种产出形态的预期质量得率(占总投入的 %,0–100)。空 = 还没给。
 *  只标不拒:得率页把低于它的一炉、一道工序的一个月标出来。写在 operation_type_output_forms 上,写策略与容差同一个码。 */
export async function setExpectedYield(code: string, form: string, raw: string): Promise<OpState> {
    const t = await getTranslations()
    const v = numOrNull(raw)
    if (v === 'bad' || (v !== null && (v < 0 || v > 100))) return { error: t('massBalance.opType.errExpectedYield') }
    const supabase = await createClient()
    const { data, error } = await supabase.from('operation_type_output_forms')
        .update({ expected_yield_pct: v }).eq('operation_type_code', code).eq('form_code', form).select('operation_type_code')
    if (error) return { error: await opError(error.message) }
    if (!data || data.length === 0) return { error: (await refuseNothingChanged(EDIT)).error }
    refresh(code)
    revalidatePath('/operation/yield')
    return {}
}

/** MES-4b(Step 0 Q17,Tim):「Electrolyte evaporates in this step」与电解液份额(V10,投入质量的 %)。
 *  勾选标的是损耗【发生】在哪一段(不是压缩机装在哪);份额空 = 还没给 —— 那时这一段的电解液挥发只能量出来。 */
export async function setElectrolyte(code: string, applies: boolean, rawShare: string): Promise<OpState> {
    const t = await getTranslations()
    const v = numOrNull(rawShare)
    if (v === 'bad' || (v !== null && (v < 0 || v > 100))) return { error: t('processing.opType.errElectrolyteShare') }
    const supabase = await createClient()
    const { data, error } = await supabase.from('operation_types')
        .update({ electrolyte_loss_applies: applies, electrolyte_share_pct: v }).eq('code', code).select('code')
    if (error) return { error: await opError(error.message) }
    if (!data || data.length === 0) return { error: (await refuseNothingChanged(EDIT)).error }
    refresh(code)
    return {}
}

export type FieldInput = {
    field_code: string; name_en: string; name_zh: string; kind: string; value_type: string; unit: string
    is_required: boolean; has_range: boolean; range_min: string; range_max: string; sort_order: string; notes: string
}

type FieldCols = Omit<TablesUpdate<'operation_type_fields'>, 'operation_type_code' | 'field_code'> & {
    name_en: string; name_zh: string; kind: string; value_type: string
}
function fieldRow(f: FieldInput): { row: FieldCols } | { bad: 'range' } {
    const min = numOrNull(f.range_min)
    const max = numOrNull(f.range_max)
    if (min === 'bad' || max === 'bad') return { bad: 'range' }
    return {
        row: {
            name_en: f.name_en.trim(), name_zh: f.name_zh.trim(), kind: f.kind, value_type: f.value_type,
            unit: f.unit.trim() || null, is_required: f.is_required, has_range: f.has_range,
            // 没声明有范围的字段,上下限一律空(表上的约束说的是同一句话)
            range_min: f.has_range ? min : null, range_max: f.has_range ? max : null,
            sort_order: Number(f.sort_order) || 0, notes: f.notes.trim() || null,
        },
    }
}

export async function addField(code: string, f: FieldInput): Promise<OpState> {
    const t = await getTranslations()
    const fieldCode = f.field_code.trim()
    if (!/^[a-z][a-z0-9_]*$/.test(fieldCode)) return { error: t('processing.opType.errFieldCode') }
    if (!f.name_en.trim() || !f.name_zh.trim()) return { error: t('processing.opType.errBothNames') }
    const r = fieldRow(f)
    if ('bad' in r) return { error: t('processing.opType.errRange') }
    const supabase = await createClient()
    const { error } = await supabase.from('operation_type_fields')
        .insert({ ...r.row, operation_type_code: code, field_code: fieldCode })
    if (error) return { error: await opError(error.message) }
    refresh(code)
    return {}
}

/** 改名字 / 必填 / 范围 / 顺序 / 备注 / (没用过时)类型与单位。字段代号不在其中。 */
export async function updateField(code: string, f: FieldInput): Promise<OpState> {
    const t = await getTranslations()
    if (!f.name_en.trim() || !f.name_zh.trim()) return { error: t('processing.opType.errBothNames') }
    const r = fieldRow(f)
    if ('bad' in r) return { error: t('processing.opType.errRange') }
    const supabase = await createClient()
    const { data, error } = await supabase.from('operation_type_fields')
        .update(r.row).eq('operation_type_code', code).eq('field_code', f.field_code).select('field_code')
    if (error) return { error: await opError(error.message) }
    if (!data || data.length === 0) return { error: (await refuseNothingChanged(EDIT)).error }
    refresh(code)
    return {}
}

/** 退役 / 恢复一个字段。退役不删:记过的值照留,新单不再列它。 */
export async function setFieldActive(code: string, fieldCode: string, active: boolean): Promise<OpState> {
    const supabase = await createClient()
    const { data, error } = await supabase.from('operation_type_fields')
        .update({ is_active: active }).eq('operation_type_code', code).eq('field_code', fieldCode).select('field_code')
    if (error) return { error: await opError(error.message) }
    if (!data || data.length === 0) return { error: (await refuseNothingChanged(EDIT)).error }
    refresh(code)
    return {}
}

/** 把一台机器挂到这道工序上(Q9:只收设备类的资产卡 —— 表上的守卫按名拒)。 */
export async function linkMachine(code: string, assetId: string): Promise<OpState> {
    const t = await getTranslations()
    if (!assetId) return { error: t('processing.opType.errPickMachine') }
    const supabase = await createClient()
    const { error } = await supabase.from('operation_type_equipment').insert({ operation_type_code: code, fixed_asset_id: assetId })
    if (error) return { error: await opError(error.message) }
    refresh(code)
    return {}
}

/** 摘下一台机器。挂接本身是配置不是单据 —— 摘下的那一刻进变更记录,不需要理由。 */
export async function unlinkMachine(code: string, assetId: string): Promise<OpState> {
    const supabase = await createClient()
    const { data, error } = await supabase.from('operation_type_equipment')
        .delete().eq('operation_type_code', code).eq('fixed_asset_id', assetId).select('fixed_asset_id')
    if (error) return { error: await opError(error.message) }
    if (!data || data.length === 0) return { error: (await refuseNothingChanged(EDIT)).error }
    refresh(code)
    return {}
}

/** 建一个配方(码由人敲:大写、数字、- 与 _)。内容在版本里 —— 建好之后加第一版。 */
export async function addRecipe(code: string, r: { code: string; name_en: string; name_zh: string; notes: string }): Promise<OpState> {
    const t = await getTranslations()
    const rc = r.code.trim().toUpperCase()
    if (!/^[A-Z0-9][A-Z0-9_-]*$/.test(rc)) return { error: t('processing.opType.errRecipeCode') }
    if (!r.name_en.trim() || !r.name_zh.trim()) return { error: t('processing.opType.errBothNames') }
    const supabase = await createClient()
    const { error } = await supabase.from('process_recipes').insert({
        operation_type_code: code, code: rc, name_en: r.name_en.trim(), name_zh: r.name_zh.trim(), notes: r.notes.trim() || null,
    })
    if (error) return { error: await opError(error.message) }
    refresh(code)
    return {}
}

/** 停用 / 恢复一个配方。停用不删:用过它的单照指着它,新单不再能选。 */
export async function setRecipeActive(code: string, recipeId: string, active: boolean): Promise<OpState> {
    const supabase = await createClient()
    const { data, error } = await supabase.from('process_recipes')
        .update({ is_active: active }).eq('id', recipeId).select('id')
    if (error) return { error: await opError(error.message) }
    if (!data || data.length === 0) return { error: (await refuseNothingChanged(EDIT)).error }
    refresh(code)
    return {}
}

/** 给配方加一版(Q16:固定、带编号、写了不改)。值只收这道工序的参数(函数按名拒别的)。 */
export async function addRecipeVersion(code: string, recipeId: string, values: Record<string, Json>, notes: string): Promise<OpState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('create_recipe_version', {
        p_recipe_id: recipeId, p_values: values as Json, p_notes: notes.trim() || undefined,
    })
    if (error) return { error: await opError(error.message) }
    refresh(code)
    return {}
}
