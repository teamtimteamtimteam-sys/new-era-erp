'use server'

import { createClient } from '@/lib/supabase/server'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { getTranslations } from '@/lib/i18n/server'

export type UpdateSupplierState = {
    error?: string
    fieldErrors?: Record<string, string>
}

export async function updateSupplier(
    id: string,
    _prevState: UpdateSupplierState,
    formData: FormData
): Promise<UpdateSupplierState> {
    const t = await getTranslations()

    // 1. 取出字段
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
    const supplier_types = formData.getAll('supplier_types') as string[]
    // SUP-TYPE-1b:未勾选的 checkbox【什么都不发】—— 所以判据是"这个字段在不在",
    // 不是"它的值真不真"。用 formData.get(...) !== null 而不是 Boolean(值):
    // 后者会把 value="on" 之外的任何写法悄悄读成 false。
    // LOG-1a:派生列写不得,写类型本身。
    const counterparty_type = String(formData.get('counterparty_type') ?? '')

    // 2. 校验
    const fieldErrors: Record<string, string> = {}
    if (!legal_name) fieldErrors.legal_name = t('suppliers.form.errLegalName')
    if (!country) fieldErrors.country = t('suppliers.form.errCountry')
    if (country && country.length !== 2) {
        fieldErrors.country = t('suppliers.form.errCountryFormat')
    }

    if (Object.keys(fieldErrors).length > 0) {
        return { fieldErrors }
    }

    // 3. 更新数据库(注意:不更新 code 和 status)
    const supabase = await createClient()
    const { error } = await supabase
        .from('suppliers')
        .update({
            legal_name,
            short_name,
            country,
            tax_id,
            address,
            supplier_types,
        counterparty_type,
            payment_terms,
            incoterm,
            credit_rating,
            notes,
            default_payment_term_template_id,
        })
        .eq('id', id)
        .is('deleted_at', null) // 已软删除的不能改

    if (error) {
        return { error: t('suppliers.form.saveError', { message: error.message }) }
    }

    // 4. 刷新缓存 + 跳回列表页
    revalidatePath('/suppliers')
    revalidatePath(`/suppliers/${id}/edit`)
    redirect('/suppliers')
}