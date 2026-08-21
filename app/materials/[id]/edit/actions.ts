'use server'

import { KIND_UNCHOSEN, parseProcessableField } from '../../materialKindOptions'
import { parseAxisField } from '../../materialAxesOptions'
import { localizeMaterialError } from '../../materialErrorCodes'
import { createClient } from '@/lib/supabase/server'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { getTranslations } from '@/lib/i18n/server'
import { parseWasteClassField } from '../../wasteClassOptions'

export type UpdateMaterialState = {
    error?: string
    fieldErrors?: Record<string, string>
}

export async function updateMaterial(
    id: string,
    _prevState: UpdateMaterialState,
    formData: FormData
): Promise<UpdateMaterialState> {
    const t = await getTranslations()

    // 1. 取字段
    const name = (formData.get('name') as string)?.trim()
    // PROC-1:见 new/actions.ts 抬头 —— 两列都必须明说,三层拒空。
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
    // MAT-1:分类可以被改回【未分类】—— 那是一个正当的动作(录错了要能撤回),
    // 而不是一个应当被拦住的状态。
    const waste_classification_code = parseWasteClassField(formData.get('waste_classification_code'))
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
    const notes = (formData.get('notes') as string)?.trim() || null

    // 2. 校验
    const fieldErrors: Record<string, string> = {}
    if (!name) fieldErrors.name = t('materials.form.errName')
    if (!kind_code) fieldErrors.kind_code = t('materials.form.errKind')
    if (may_be_processed === null) fieldErrors.may_be_processed = t('materials.form.errProcessable')
    // 【不在这里判"该不该填"】那条规矩要看字典(种类有没有状态轴、形态要不要拆解),
    // 而在 TS 里再实现一遍就是第二份实现 —— 让库拒,句子由 localizeMaterialError
    // 按【具名码】翻(PROC-2 的四条守卫都带名字)。

    if (safety_stock_qty !== null && Number.isNaN(safety_stock_qty)) {
        fieldErrors.safety_stock_qty = t('materials.form.errSafetyStock')
    }
    if (Object.keys(fieldErrors).length > 0) {
        return { fieldErrors }
    }

    // 3. 更新数据库(不更新 code 和 status)
    const supabase = await createClient()
    const {
        data: { user },
    } = await supabase.auth.getUser()

    const { error } = await supabase
        .from('materials')
        .update({
            name,
            kind_code,
            may_be_processed,
            form_code,
            source_code,
            size_format_code,
            chemistry,
            waste_classification_code,
            unit,
            spec,
            safety_stock_qty,
            notes,
            updated_by: user?.id ?? null,
        })
        .eq('id', id)
        .is('deleted_at', null) // 已软删除的不能改

    if (error) {
        return { error: await localizeMaterialError(error.message) }
    }

    revalidatePath('/materials')
    revalidatePath(`/materials/${id}/edit`)
    redirect('/materials')
}
