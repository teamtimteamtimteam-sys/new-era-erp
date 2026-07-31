'use server'

// 现场收货:复用与 inbound/new 完全相同的建单路径(自动 code + 库存 receipt 流水 + 不变式),
// 只是把 UI 精简成移动端一步式。单位固定 kg,不收 unit_price / stage(stage 用 DB 默认 '待加工')。
import { createClient } from '@/lib/supabase/server'
import type { InsertRow } from '@/lib/db-helpers'
import { getTranslations } from '@/lib/i18n/server'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { localizePurchasingError } from '@/app/purchasing/purchasingErrorCodes'

export type ReceiveState = {
    error?: string
    fieldErrors?: Record<string, string>
}

export async function createFieldReceipt(
    _prevState: ReceiveState,
    formData: FormData
): Promise<ReceiveState> {
    const t = await getTranslations()

    const supplier_id = (formData.get('supplier_id') as string) || ''
    const material_id = (formData.get('material_id') as string) || ''
    const quantity_raw = (formData.get('quantity') as string) || ''
    const arrival_date = (formData.get('arrival_date') as string)?.trim() || null
    const notes = (formData.get('notes') as string)?.trim() || null
    // 关联采购单(cut 4c,可选;成对出现)
    const purchase_order_id = (formData.get('purchase_order_id') as string) || null
    const purchase_order_line_id = (formData.get('purchase_order_line_id') as string) || null

    const fieldErrors: Record<string, string> = {}
    if (!supplier_id) fieldErrors.supplier_id = t('receive.errSupplier')
    if (!material_id) fieldErrors.material_id = t('receive.errMaterial')

    let quantity: number | null = null
    if (!quantity_raw) {
        fieldErrors.quantity = t('receive.errQuantity')
    } else {
        const n = Number(quantity_raw)
        if (Number.isNaN(n) || n <= 0) fieldErrors.quantity = t('receive.errQuantity')
        else quantity = n
    }

    if (Object.keys(fieldErrors).length > 0) {
        return { fieldErrors }
    }

    const supabase = await createClient()
    const {
        data: { user },
    } = await supabase.auth.getUser()

    const { data, error } = await supabase
        .from('inbound_batches')
        .insert({
            material_id,
            supplier_id,
            quantity,
            remaining_qty: quantity, // 剩余量初始 = 数量
            unit: 'kg',
            arrival_date,
            notes,
            purchase_order_id,
            purchase_order_line_id,
            created_by: user?.id ?? null,
            updated_by: user?.id ?? null,
            // code 触发器自动生成;status 默认 'draft';stage 默认 '待加工'
        } as InsertRow<'inbound_batches'>)
        .select('id')
        .single()

    if (error || !data) {
        // PO 关联触发器的编码错误本地化;其余仍走原样的 saveError
        if (error && /PO_NOT_RECEIVABLE|PO_LINE_MISMATCH/.test(error.message)) {
            return { error: await localizePurchasingError(error.message) }
        }
        return { error: t('receive.saveError', { message: error?.message ?? '' }) }
    }

    revalidatePath('/inbound')
    redirect(`/inbound/receive/done/${data.id}`)
}
