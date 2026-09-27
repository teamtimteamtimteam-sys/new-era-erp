// lib/poCategoryAccess.ts —— 服务端用
// ★ APR-10(Tim 的 grilling Q6):读者持哪几类采购单的开单码。品类 → 码那一份定义【只在库里】
//   (po_category_raise_code),这里逐类向它要,再用 can() 问读者 —— 不在 TS 里抄第二份对照表。
import type { SupabaseClient } from '@supabase/supabase-js'
import { can } from '@/lib/permissions'
import { PO_CATEGORIES, type PoCategory } from '@/lib/poCategory'

export async function loadPoCategoryAccess(supabase: SupabaseClient): Promise<{
    codes: Record<PoCategory, string>
    allowed: Record<PoCategory, boolean>
    any: boolean
}> {
    const codes = {} as Record<PoCategory, string>
    const allowed = {} as Record<PoCategory, boolean>
    for (const c of PO_CATEGORIES) {
        const { data, error } = await supabase.rpc('po_category_raise_code', { p_category: c })
        // 一个认不出的品类不是"没有码":它说明这份清单与库里的 CHECK 漂开了 —— 失败就是失败
        if (error || typeof data !== 'string') throw new Error(`po_category_raise_code(${c}): ${error?.message ?? 'no code'}`)
        codes[c] = data
        allowed[c] = await can(data)
    }
    return { codes, allowed, any: PO_CATEGORIES.some((c) => allowed[c]) }
}
