'use server'

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
    const category = (formData.get('category') as string)?.trim()
    const chemistry = (formData.get('chemistry') as string)?.trim() || null
    // MAT-1:受控废物分类。【未分类 → NULL】,而 NULL 的意思是"没有人分过类",
    // 不是"非受控" —— 一个合规判断会踩在这个区别上。
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
    if (!category) fieldErrors.category = t('materials.form.errCategory')

    if (safety_stock_qty !== null && Number.isNaN(safety_stock_qty)) {
        fieldErrors.safety_stock_qty = t('materials.form.errSafetyStock')
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
        category,
        chemistry,
        waste_classification_code,
        unit,
        spec,
        safety_stock_qty,
        notes,
        created_by: user?.id ?? null,
        updated_by: user?.id ?? null,
        // code 不传,用触发器自动生成
        // status 不传,用数据库默认值 'draft'
    } as InsertRow<'materials'>)

    if (error) {
        return { error: t('materials.form.saveError', { message: error.message }) }
    }

    revalidatePath('/materials')
    redirect('/materials')
}
