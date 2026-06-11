'use server'

import { createClient } from '@/lib/supabase/server'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'

export type UpdateInboundState = {
    error?: string
    fieldErrors?: Record<string, string>
}

export async function updateInbound(
    id: string,
    _prevState: UpdateInboundState,
    formData: FormData
): Promise<UpdateInboundState> {
    // 1. 取字段(和 createInbound 一致)
    const material_id = (formData.get('material_id') as string) || ''
    const supplier_id = (formData.get('supplier_id') as string) || ''
    const quantity_raw = (formData.get('quantity') as string) || ''
    const unit = (formData.get('unit') as string)?.trim() || 'kg'
    const arrival_date = (formData.get('arrival_date') as string)?.trim() || null
    const stage = (formData.get('stage') as string)?.trim() || '待加工'
    const unit_price_raw = (formData.get('unit_price') as string) || ''
    const notes = (formData.get('notes') as string)?.trim() || null

    // 2. 校验
    const fieldErrors: Record<string, string> = {}
    if (!material_id) fieldErrors.material_id = '请选择物料'
    if (!supplier_id) fieldErrors.supplier_id = '请选择供应商'

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

    let unit_price: number | null = null
    if (unit_price_raw) {
        const n = Number(unit_price_raw)
        if (Number.isNaN(n)) {
            fieldErrors.unit_price = '单价必须是数字'
        } else {
            unit_price = n
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
        .from('inbound_batches')
        .update({
            material_id,
            supplier_id,
            quantity,
            unit,
            arrival_date,
            stage,
            unit_price,
            notes,
            updated_by: user?.id ?? null,
        })
        .eq('id', id)
        .is('deleted_at', null) // 已软删除的不能改

    if (error) {
        return { error: `保存失败: ${error.message}` }
    }

    revalidatePath('/inbound')
    revalidatePath(`/inbound/${id}/edit`)
    redirect('/inbound')
}
