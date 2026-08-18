'use server'

import { createClient } from '@/lib/supabase/server'
import type { InsertRow } from '@/lib/db-helpers'
import { getTranslations } from '@/lib/i18n/server'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'

// 表单返回的状态(用于把错误信息回传给页面)
export type CreateSupplierState = {
    error?: string
    fieldErrors?: Record<string, string>
}

export async function createSupplier(
    _prevState: CreateSupplierState,
    formData: FormData
): Promise<CreateSupplierState> {
    const t = await getTranslations()

    // 1. 从表单里取出字段
    const legal_name = (formData.get('legal_name') as string)?.trim()
    const short_name = (formData.get('short_name') as string)?.trim() || null
    const country = (formData.get('country') as string)?.trim().toUpperCase()
    const tax_id = (formData.get('tax_id') as string)?.trim() || null
    const address = (formData.get('address') as string)?.trim() || null
    const payment_terms = (formData.get('payment_terms') as string)?.trim() || null
    const incoterm = (formData.get('incoterm') as string)?.trim() || null
    const credit_rating = (formData.get('credit_rating') as string)?.trim() || null
    const notes = (formData.get('notes') as string)?.trim() || null
    // 默认付款条款模板(空 = 无;非法 id 由外键拦下)
    const default_payment_term_template_id =
        (formData.get('default_payment_term_template_id') as string)?.trim() || null

    // 多选 checkbox:用 getAll 拿所有勾选的值
    const supplier_types = formData.getAll('supplier_types') as string[]
    // SUP-TYPE-1b:未勾选的 checkbox【什么都不发】—— 所以判据是"这个字段在不在",
    // 不是"它的值真不真"。用 formData.get(...) !== null 而不是 Boolean(值):
    // 后者会把 value="on" 之外的任何写法悄悄读成 false。
    const supplies_goods = formData.get('supplies_goods') !== null

    // 2. 基本校验
    const fieldErrors: Record<string, string> = {}
    if (!legal_name) fieldErrors.legal_name = t('suppliers.form.errLegalName')
    if (!country) fieldErrors.country = t('suppliers.form.errCountry')
    if (country && country.length !== 2) {
        fieldErrors.country = t('suppliers.form.errCountryFormat')
    }

    if (Object.keys(fieldErrors).length > 0) {
        return { fieldErrors }
    }

    // 3. 写入 Supabase
    const supabase = await createClient()
    const { error } = await supabase.from('suppliers').insert({
        legal_name,
        short_name,
        country,
        tax_id,
        address,
        supplier_types,
        supplies_goods,
        payment_terms,
        incoterm,
        credit_rating,
        notes,
        default_payment_term_template_id,
        // status 不传,用数据库默认值 'draft'
        // code 不传,用触发器自动生成
    } as InsertRow<'suppliers'>)

    if (error) {
        return { error: t('suppliers.form.saveError', { message: error.message }) }
    }

    // 4. 让 /suppliers 列表页重新读取数据(否则会显示缓存的旧数据)
    revalidatePath('/suppliers')

    // 5. 跳回列表页
    redirect('/suppliers')
}