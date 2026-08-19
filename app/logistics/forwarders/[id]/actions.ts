'use server'

import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { localizeLogisticsError } from '../../logisticsErrorCodes'

// LOG-1c:货代详情页的服务端动作。每一处失败都经 localizeLogisticsError ——
// 重叠报价那条拒绝是数据库抛的,原样印出来是一串机器码。

export type Result = { error: string } | { success: true }

async function fail(message: string): Promise<Result> {
    return { error: await localizeLogisticsError(message) }
}

export async function saveForwarderDetails(
    supplierId: string,
    input: { main_routes: string | null; ports_served: string | null; free_time_terms: string | null; dg_classes: string | null; notes: string | null }
): Promise<Result> {
    const supabase = await createClient()
    const { error } = await supabase
        .from('forwarder_details')
        .upsert({ supplier_id: supplierId, ...input }, { onConflict: 'supplier_id' })
    if (error) return fail(error.message)
    revalidatePath(`/logistics/forwarders/${supplierId}`)
    return { success: true }
}

export async function addRateQuote(
    supplierId: string,
    input: { lane_id: string; amount_ccy: string; currency: string; valid_from: string; valid_to: string }
): Promise<Result> {
    const supabase = await createClient()
    const { error } = await supabase.from('forwarder_rate_quotes').insert({
        supplier_id: supplierId,
        lane_id: input.lane_id,
        amount_ccy: Number(input.amount_ccy),
        currency: input.currency,
        valid_from: input.valid_from,
        valid_to: input.valid_to,
    })
    if (error) return fail(error.message)
    revalidatePath(`/logistics/forwarders/${supplierId}`)
    return { success: true }
}

// 软删 —— 报价是一份说过的话,留痕比抹掉有用
export async function removeRateQuote(supplierId: string, quoteId: string): Promise<Result> {
    const supabase = await createClient()
    const { error } = await supabase
        .from('forwarder_rate_quotes')
        .update({ deleted_at: new Date().toISOString() })
        .eq('id', quoteId)
    if (error) return fail(error.message)
    revalidatePath(`/logistics/forwarders/${supplierId}`)
    return { success: true }
}
