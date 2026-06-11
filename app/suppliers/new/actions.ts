'use server'

import { createClient } from '@/lib/supabase/server'
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

    // 多选 checkbox:用 getAll 拿所有勾选的值
    const supplier_types = formData.getAll('supplier_types') as string[]

    // 2. 基本校验
    const fieldErrors: Record<string, string> = {}
    if (!legal_name) fieldErrors.legal_name = '法人名是必填的'
    if (!country) fieldErrors.country = '国家是必填的'
    if (country && country.length !== 2) {
        fieldErrors.country = '国家应该是 2 个字母的代码,例如 SG / CN / DE'
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
        payment_terms,
        incoterm,
        credit_rating,
        notes,
        // status 不传,用数据库默认值 'draft'
        // code 不传,用触发器自动生成
    })

    if (error) {
        return { error: `保存失败: ${error.message}` }
    }

    // 4. 让 /suppliers 列表页重新读取数据(否则会显示缓存的旧数据)
    revalidatePath('/suppliers')

    // 5. 跳回列表页
    redirect('/suppliers')
}