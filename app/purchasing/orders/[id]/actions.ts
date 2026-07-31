'use server'

// 采购单取消:rpc cancel_purchase_order(已收货 / 已抵扣预付的拒绝,校验在 DB)。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { localizePurchasingError } from '../../purchasingErrorCodes'

export async function cancelOrder(
    poId: string,
    reason: string
): Promise<{ error?: string }> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('cancel_purchase_order', {
        p_id: poId,
        p_reason: reason.trim() || undefined,
    })
    if (error) {
        return { error: await localizePurchasingError(error.message) }
    }
    revalidatePath('/purchasing/orders')
    revalidatePath(`/purchasing/orders/${poId}`)
    return {}
}

// 结束采购单(cut 4c):有未抵扣预付时说明必填 —— 校验在 DB(CLOSE_NOTES_REQUIRED)
export async function closeOrder(
    poId: string,
    notes: string
): Promise<{ error?: string }> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('close_purchase_order', {
        p_purchase_order_id: poId,
        p_notes: notes.trim() || undefined,
    })
    if (error) {
        return { error: await localizePurchasingError(error.message) }
    }
    revalidatePath('/purchasing/orders')
    revalidatePath(`/purchasing/orders/${poId}`)
    return {}
}

export async function reopenOrder(
    poId: string,
    reason: string
): Promise<{ error?: string }> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('reopen_purchase_order', {
        p_purchase_order_id: poId,
        p_reason: reason.trim(),
    })
    if (error) {
        return { error: await localizePurchasingError(error.message) }
    }
    revalidatePath('/purchasing/orders')
    revalidatePath(`/purchasing/orders/${poId}`)
    return {}
}
