'use server'

import { parseNeaCategoryField } from '@/app/materials/neaCategoryOptions'
import { parseDgField, parseHsField } from '@/app/materials/dgOptions'
import { KIND_UNCHOSEN, parseProcessableField } from '../materialKindOptions'
import { parseAxisField } from '../materialAxesOptions'
import { localizeMaterialError } from '../materialErrorCodes'
import { createClient } from '@/lib/supabase/server'
import type { InsertRow } from '@/lib/db-helpers'
import { getTranslations } from '@/lib/i18n/server'
import { parseWasteClassField } from '../wasteClassOptions'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'

export type CreateMaterialState = {
    error?: string
    fieldErrors?: Record<string, string>
}

export async function createMaterial(
    _prevState: CreateMaterialState,
    formData: FormData
): Promise<CreateMaterialState> {
    const t = await getTranslations()

    // 1. 取字段
    const name = (formData.get('name') as string)?.trim()
    // PROC-1:两列都【必须是明说出来的选择】。哨兵值 / null 由 materialKindOptions
    // 解析,而不是用空串 —— 空串在 FormData 里与"没提交"分不开。
    const kindRaw = String(formData.get('kind_code') ?? '').trim()
    const kind_code = kindRaw === '' || kindRaw === KIND_UNCHOSEN ? null : kindRaw
    const may_be_processed = parseProcessableField(formData.get('may_be_processed'))
    // PROC-2b:三条状态轴。**适用与否由字典回答,所以这里【不判断】适不适用** ——
    // 判断在 guard_material_condition_axes 上,两个方向都拦。这里只做两件事:
    // 把哨兵值翻成 NULL,以及在服务端【独立】拒一次空(表单是第一道,库是第三道)。
    const form_code = parseAxisField(formData.get('form_code'))
    const source_code = parseAxisField(formData.get('source_code'))
    const size_format_code = parseAxisField(formData.get('size_format_code'))
    const chemistry = (formData.get('chemistry') as string)?.trim() || null
    // MAT-1:受控废物分类。【未分类 → NULL】,而 NULL 的意思是"没有人分过类",
    // 不是"非受控" —— 一个合规判断会踩在这个区别上。
    const waste_classification_code = parseWasteClassField(formData.get('waste_classification_code'))
    // MES-3a(V29):NEA 废物类别 —— 空 = 没人分过(收货照收,记 category_not_set)
    const nea_waste_category_code = parseNeaCategoryField(formData.get('nea_waste_category_code'))
    // MES-3b(V35 · V31):危险品 UN 编号(空 = 没人选过)与 HS 编码(空 = 没给;形状由表上的 CHECK 判)
    const dg_code = parseDgField(formData.get('dg_code'))
    const hs_code = parseHsField(formData.get('hs_code'))
    const unit = (formData.get('unit') as string)?.trim() || 'kg'
    const spec = (formData.get('spec') as string)?.trim() || null
    // SS-1:安全库存阈值。【留空 = 不监控】,所以空字符串必须落成 NULL 而不是 0 ——
    // 0 会让告警永远不响,却看起来像"设过了",正是这一列的注释在防的那件事。
    const safety_raw = (formData.get('safety_stock_qty') as string)?.trim() || ''
    let safety_stock_qty: number | null = null
    if (safety_raw !== '') {
        const n = Number(safety_raw)
        // 与 CHECK 同一条判据(NULL 或 > 0)—— 界面先说人话,数据库仍然兜底。
        safety_stock_qty = Number.isNaN(n) || n <= 0 ? NaN : n
    }
    // MES-5a-1(V9):放电通过电压 —— 空 = 没设(NULL,结论"判不了");与表上的 CHECK 同一条(NULL 或 > 0)
    const dpv_raw = (formData.get('discharge_pass_voltage_v') as string)?.trim() || ''
    const discharge_pass_voltage_v: number | null = dpv_raw === '' ? null : (Number(dpv_raw) > 0 ? Number(dpv_raw) : NaN)
    const notes = (formData.get('notes') as string)?.trim() || null

    // 2. 校验
    const fieldErrors: Record<string, string> = {}
    if (!name) fieldErrors.name = t('materials.form.errName')
    // 【服务端独立拒空】—— 表单那一层是第一道,这里是第二道,表上的
    // materials_kind_stated 是第三道。三层都要在(AGENTS.md 那条决定期间的日期的规矩,
    // 同一个形状:提交控件禁用 + 服务端独立拒 + 数据库兜底)。
    if (!kind_code) fieldErrors.kind_code = t('materials.form.errKind')
    if (may_be_processed === null) fieldErrors.may_be_processed = t('materials.form.errProcessable')
    // 【不在这里判"该不该填"】那条规矩要看字典(种类有没有状态轴、形态要不要拆解),
    // 而在 TS 里再实现一遍就是第二份实现 —— 让库拒,句子由 localizeMaterialError
    // 按【具名码】翻(PROC-2 的四条守卫都带名字)。

    if (safety_stock_qty !== null && Number.isNaN(safety_stock_qty)) {
        fieldErrors.safety_stock_qty = t('materials.form.errSafetyStock')
    }
    if (discharge_pass_voltage_v !== null && Number.isNaN(discharge_pass_voltage_v)) {
        fieldErrors.discharge_pass_voltage_v = t('materials.form.errDischargePassV')
    }
    if (Object.keys(fieldErrors).length > 0) {
        return { fieldErrors }
    }

    // 3. 写入
    const supabase = await createClient()
    const {
        data: { user },
    } = await supabase.auth.getUser()

    const { error } = await supabase.from('materials').insert({
        name,
        kind_code,
        may_be_processed,
        form_code,
        source_code,
        size_format_code,
        chemistry,
        waste_classification_code,
        nea_waste_category_code,
        dg_code,
        hs_code,
        unit,
        spec,
        safety_stock_qty,
        discharge_pass_voltage_v,
        notes,
        created_by: user?.id ?? null,
        updated_by: user?.id ?? null,
        // code 不传,用触发器自动生成
        // status 不传,用数据库默认值 'draft'
    } as InsertRow<'materials'>)

    if (error) {
        return { error: await localizeMaterialError(error.message) }
    }

    revalidatePath('/materials')
    redirect('/materials')
}
