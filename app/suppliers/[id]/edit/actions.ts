'use server'

import { createClient } from '@/lib/supabase/server'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'

export type UpdateSupplierState = {
    error?: string
    fieldErrors?: Record<string, string>
}

export async function updateSupplier(
    id: string,
    _prevState: UpdateSupplierState,
    formData: FormData
): Promise<UpdateSupplierState> {
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
    const supplier_types = formData.getAll('supplier_types') as string[]

    // 2. 校验
    const fieldErrors: Record<string, string> = {}
    if (!legal_name) fieldErrors.legal_name = '法人名是必填的'
    if (!country) fieldErrors.country = '国家是必填的'
    if (country && country.length !== 2) {
        fieldErrors.country = '国家应该是 2 个字母的代码,例如 SG / CN / DE'
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
            payment_terms,
            incoterm,
            credit_rating,
            notes,
        })
        .eq('id', id)
        .is('deleted_at', null) // 已软删除的不能改

    if (error) {
        return { error: `保存失败: ${error.message}` }
    }

    // 4. 刷新缓存 + 跳回列表页
    revalidatePath('/suppliers')
    revalidatePath(`/suppliers/${id}/edit`)
    redirect('/suppliers')
}