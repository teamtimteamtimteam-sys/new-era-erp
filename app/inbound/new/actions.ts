'use server'

import { createClient } from '@/lib/supabase/server'
import type { InsertRow } from '@/lib/db-helpers'
import { getTranslations } from '@/lib/i18n/server'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { localizePurchasingError } from '@/app/purchasing/purchasingErrorCodes'

export type CreateInboundState = {
    error?: string
    fieldErrors?: Record<string, string>
}

export async function createInbound(
    _prevState: CreateInboundState,
    formData: FormData
): Promise<CreateInboundState> {
    const t = await getTranslations()

    // 1. 取字段
    const material_id = (formData.get('material_id') as string) || ''
    const supplier_id = (formData.get('supplier_id') as string) || ''
    const quantity_raw = (formData.get('quantity') as string) || ''
    const unit = (formData.get('unit') as string)?.trim() || 'kg'
    const arrival_date = (formData.get('arrival_date') as string)?.trim() || null
    const stage = (formData.get('stage') as string)?.trim() || '待加工'
    const unit_price_raw = (formData.get('unit_price') as string) || ''
    const notes = (formData.get('notes') as string)?.trim() || null
    // 关联采购单(cut 4c,可选;成对出现 —— 表单只在选了行时才携带)
    const purchase_order_id = (formData.get('purchase_order_id') as string) || null
    const purchase_order_line_id = (formData.get('purchase_order_line_id') as string) || null

    // 2. 校验
    const fieldErrors: Record<string, string> = {}
    if (!material_id) fieldErrors.material_id = t('inbound.form.errMaterial')
    if (!supplier_id) fieldErrors.supplier_id = t('inbound.form.errSupplier')

    let quantity: number | null = null
    if (!quantity_raw) {
        fieldErrors.quantity = t('inbound.form.errQuantity')
    } else {
        const n = Number(quantity_raw)
        if (Number.isNaN(n) || n <= 0) {
            fieldErrors.quantity = t('inbound.form.errQuantityPositive')
        } else {
            quantity = n
        }
    }

    let unit_price: number | null = null
    if (unit_price_raw) {
        const n = Number(unit_price_raw)
        if (Number.isNaN(n)) {
            fieldErrors.unit_price = t('inbound.form.errUnitPrice')
        } else {
            unit_price = n
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

    const { error } = await supabase.from('inbound_batches').insert({
        material_id,
        supplier_id,
        quantity,
        unit,
        remaining_qty: quantity, // 剩余量初始 = 数量
        arrival_date,
        stage,
        unit_price,
        notes,
        purchase_order_id,
        purchase_order_line_id,
        created_by: user?.id ?? null,
        updated_by: user?.id ?? null,
        // code 不传,用触发器自动生成
        // status 不传,用数据库默认值 'draft'
    } as InsertRow<'inbound_batches'>)

    if (error) {
        // PO 关联触发器的编码错误(PO_NOT_RECEIVABLE / PO_LINE_MISMATCH)本地化;
        // 其余仍走原样的 saveError
        if (/PO_NOT_RECEIVABLE|PO_LINE_MISMATCH/.test(error.message)) {
            return { error: await localizePurchasingError(error.message) }
        }
        return { error: t('inbound.form.saveError', { message: error.message }) }
    }

    revalidatePath('/inbound')
    revalidatePath('/purchasing/orders')
    redirect('/inbound')
}
