'use server'

// RECV-SOURCE-1(3e):事后给一张无单收货补理由 —— 【走门】,不直接 UPDATE。
//
// 门是 explain_inbound_source():它把说明与出处(谁、什么时候)一笔写完。
// 直接 UPDATE 本表写理由会被 guard_receipt_source_stated 按名拒
// (SOURCE_PROVENANCE_REQUIRED)—— 一个没有作者的断言不许落库。
// R4:这条路是给 Tim【哪天知道了答案】用的;它绝不预填、绝不猜。

import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { localizePurchasingError } from '@/app/purchasing/purchasingErrorCodes'
import { localizeMaterialError } from '@/app/materials/materialErrorCodes'

export async function explainSource(
    batchId: string,
    reasonCode: string,
    note: string,
): Promise<{ error?: string; success?: boolean }> {
    const supabase = await createClient()
    const trimmed = note.trim()
    const { error } = await supabase.rpc('explain_inbound_source', {
        p_batch_id: batchId,
        p_reason_code: reasonCode,
        ...(trimmed === '' ? {} : { p_note: trimmed }),
    })
    if (error) {
        // 具名拒绝翻成人话:来源家族在 purchasing 表里(与收货触发器的其余拒绝同住),
        // INBOUND_NOT_FOUND 在 materials 表里 —— 两张都问过再原样返回。
        const viaPurchasing = await localizePurchasingError(error.message)
        if (viaPurchasing !== error.message.trim()) return { error: viaPurchasing }
        const viaMaterial = await localizeMaterialError(error.message)
        if (viaMaterial !== error.message.trim()) return { error: viaMaterial }
        return { error: error.message }
    }
    revalidatePath(`/inbound/${batchId}/edit`)
    revalidatePath('/inbound')
    return { success: true }
}
