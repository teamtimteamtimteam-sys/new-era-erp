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
    input: { lane_id: string; amount_ccy: string; currency: string; valid_from: string
             valid_to: string; free_days: string }
): Promise<Result> {
    const supabase = await createClient()
    // ════════════════════════════════════════════════════════════════════════
    // LOG-5c:【空 ≠ 0,而这一行就是那条区别活下来的地方】
    // 列注释把它写死了:NULL =「这份报价没写免柜期」→ 告警沉默;
    // 0 =「零个免费天」→ 从到港当天起计滞港费。
    // 所以【绝不能】写成 Number(input.free_days) —— Number('') 是 0,
    // 那一句会把"没写"静默地变成"写了零天",而后果是每个到港的箱子从第一天起报警。
    // 也不能写成 Number(x) || null —— 那把【真正的 0】变成 NULL,方向相反、
    // 后果更贵:一个真的在烧钱的箱子从此一声不吭。
    // 判据只能是【那个框里有没有东西】,不是那个数是不是真值。
    const raw = input.free_days.trim()
    const freeDays = raw === '' ? null : Number(raw)
    if (freeDays !== null && (!Number.isInteger(freeDays) || freeDays < 0)) {
        return fail('FREE_DAYS_INVALID')
    }
    const { error } = await supabase.from('forwarder_rate_quotes').insert({
        supplier_id: supplierId,
        lane_id: input.lane_id,
        amount_ccy: Number(input.amount_ccy),
        currency: input.currency,
        valid_from: input.valid_from,
        valid_to: input.valid_to,
        free_days: freeDays,
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
