'use server'

import { createClient } from '@/lib/supabase/server'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'

export type UpdateOutputState = {
    error?: string
    fieldErrors?: Record<string, string>
}

export async function updateOutput(
    id: string,
    _prevState: UpdateOutputState,
    formData: FormData
): Promise<UpdateOutputState> {
    // 1. 取字段(和 createOutput 一致)
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

    // 3. 更新(不动 remaining_qty、code、status)
    const supabase = await createClient()
    const {
        data: { user },
    } = await supabase.auth.getUser()

    const { error } = await supabase
        .from('output_batches')
        .update({
            material_id,
            customer_id: customer_id || null, // 可选
            quantity: quantity ?? undefined,
            unit,
            output_date,
            state,
            purity,
            notes,
            updated_by: user?.id ?? null,
        })
        .eq('id', id)
        .is('deleted_at', null) // 已软删除的不能改

    if (error) {
        return { error: `保存失败: ${error.message}` }
    }

    revalidatePath('/output')
    revalidatePath(`/output/${id}/edit`)
    redirect('/output')
}
