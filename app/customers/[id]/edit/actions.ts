'use server'

import { createClient } from '@/lib/supabase/server'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { getTranslations } from '@/lib/i18n/server'

export type UpdateCustomerState = {
    error?: string
    fieldErrors?: Record<string, string>
}

export async function updateCustomer(
    id: string,
    _prevState: UpdateCustomerState,
    formData: FormData
): Promise<UpdateCustomerState> {
    const t = await getTranslations()

    // 1. 取出字段
    const legal_name = (formData.get('legal_name') as string)?.trim()
    const short_name = (formData.get('short_name') as string)?.trim() || null
    const country = (formData.get('country') as string)?.trim().toUpperCase()
    const tax_id = (formData.get('tax_id') as string)?.trim() || null
    const address = (formData.get('address') as string)?.trim() || null
    const contact_person = (formData.get('contact_person') as string)?.trim() || null
    const email = (formData.get('email') as string)?.trim() || null
    const phone = (formData.get('phone') as string)?.trim() || null
    const payment_terms = (formData.get('payment_terms') as string)?.trim() || null
    const incoterm = (formData.get('incoterm') as string)?.trim() || null
    const credit_rating = (formData.get('credit_rating') as string)?.trim() || null
    // SAL-B:【空串 → NULL(没设限,放行);'0' → 0(现款现货,拒任何赊销)】——
    // 二者相反。`|| null` 会把 '0' 吞成 null,恰好把现款现货客户放成不设限,
    // 所以这里显式区分空串与数值。
    const limit_raw = (formData.get('credit_limit_base') as string)?.trim() ?? ''
    const credit_limit_base = limit_raw === '' ? null : Number(limit_raw)
    if (credit_limit_base !== null && (!Number.isFinite(credit_limit_base) || credit_limit_base < 0)) {
        return { error: t('customers.form.errCreditLimit') }
    }
    const credit_hold = formData.get('credit_hold') === 'on'
    const notes = (formData.get('notes') as string)?.trim() || null
    const customer_types = formData.getAll('customer_types') as string[]

    // 2. 校验
    const fieldErrors: Record<string, string> = {}
    if (!legal_name) fieldErrors.legal_name = t('customers.form.errLegalName')
    if (!country) fieldErrors.country = t('customers.form.errCountry')
    if (country && country.length !== 2) {
        fieldErrors.country = t('customers.form.errCountryFormat')
    }

    if (Object.keys(fieldErrors).length > 0) {
        return { fieldErrors }
    }

    // 3. 更新数据库(注意:不更新 code 和 status)
    const supabase = await createClient()
    const {
        data: { user },
    } = await supabase.auth.getUser()

    const { error } = await supabase
        .from('customers')
        .update({
            legal_name,
            short_name,
            country,
            tax_id,
            address,
            contact_person,
            email,
            phone,
            customer_types,
            payment_terms,
            incoterm,
            credit_rating,
            credit_limit_base,
            credit_hold,
            notes,
            updated_by: user?.id ?? null,
        })
        .eq('id', id)
        .is('deleted_at', null) // 已软删除的不能改

    if (error) {
        return { error: t('customers.form.saveError', { message: error.message }) }
    }

    // 4. 刷新缓存 + 跳回列表页
    revalidatePath('/customers')
    revalidatePath(`/customers/${id}/edit`)
    redirect('/customers')
}
