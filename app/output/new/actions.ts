'use server'

import { createClient } from '@/lib/supabase/server'
import type { InsertRow } from '@/lib/db-helpers'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'

export type CreateOutputState = {
    error?: string
    fieldErrors?: Record<string, string>
}

export async function createOutput(
    _prevState: CreateOutputState,
    formData: FormData
): Promise<CreateOutputState> {
    // 1. 取字段
    const material_id = (formData.get('material_id') as string) || ''
    const customer_id = (formData.get('customer_id') as string) || ''
    const quantity_raw = (formData.get('quantity') as string) || ''
    const unit = (formData.get('unit') as string)?.trim() || 'kg'
    const output_date = (formData.get('output_date') as string)?.trim() || null
    const state = (formData.get('state') as string)?.trim() || '库存中'
    const purity = (formData.get('purity') as string)?.trim() || null
    const notes = (formData.get('notes') as string)?.trim() || null

    // 2. 校验(客户可选,不校验)
    const fieldErrors: Record<string, string> = {}
    if (!material_id) fieldErrors.material_id = '请选择物料'

    let quantity: number | null = null
    if (!quantity_raw) {
        fieldErrors.quantity = '数量是必填的'
    } else {
        const n = Number(quantity_raw)
        if (Number.isNaN(n) || n <= 0) {
            fieldErrors.quantity = '数量必须是大于0的数字'
        } else {
            quantity = n
        }
    }

    if (Object.keys(fieldErrors).length > 0) {
        return { fieldErrors }
    }

    // 3. 写入
    const supabase = await createClient()
    const {
        data: { user },
    } = await supabase.auth.getUser()

    const { error } = await supabase.from('output_batches').insert({
        material_id,
        customer_id: customer_id || null, // 可选
        quantity,
        unit,
        remaining_qty: quantity, // 剩余可售量初始 = 数量
        output_date,
        state,
        purity,
        notes,
        created_by: user?.id ?? null,
        updated_by: user?.id ?? null,
        // code 不传,用触发器自动生成
        // status 不传,用数据库默认值 'draft'
    } as InsertRow<'output_batches'>)

    if (error) {
        return { error: `保存失败: ${error.message}` }
    }

    revalidatePath('/output')
    redirect('/output')
}
