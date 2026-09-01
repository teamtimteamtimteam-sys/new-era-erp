// app/inbound/sourceReasonQuery.ts
// RECV-SOURCE-1:无单收货的理由字典(inbound_source_reasons)。
// 【字典不敏感,表级授权,直读】—— 与 inbound_safety_states 等五张同一处置。
// requiresExplanation 是【规则列】:other(以及将来任何要求说明的理由)必须带
// 一句书面说明 —— 表单据此把说明框标成必填;真正的拒绝在库里
// (guard_receipt_source_stated 读同一列),这里只是把答案提前说出来。

import type { SupabaseClient } from '@supabase/supabase-js'
import type { Database } from '@/lib/database.types'
import { mustRows } from '@/lib/db-helpers'

export type SourceReasonOption = {
    code: string
    label: string
    requiresExplanation: boolean
}

export async function loadSourceReasons(
    supabase: SupabaseClient<Database>,
    locale: string
): Promise<SourceReasonOption[]> {
    const res = await supabase
        .from('inbound_source_reasons')
        .select('code, name_en, name_zh, requires_explanation')
        .eq('is_active', true)
        .order('sort_order')
    return mustRows(res, 'inbound_source_reasons').map((r) => ({
        code: r.code,
        // 双语列【选一个】,不拼(GST-FIX-3 那一课)
        label: locale === 'zh' ? r.name_zh : r.name_en,
        requiresExplanation: r.requires_explanation,
    }))
}
