// RPT-1:安全库存总览 —— 复用 SS-1 的 material_stock_available,不新建视图。
import { createClient } from '@/lib/supabase/server'
import { mustRows } from '@/lib/db-helpers'

export type SafetyRow = {
    material_id: string; code: string; name: string; unit: string
    safety_stock_qty: number | null; available_qty: number
}

// 【只列被监控的】—— 未监控的物料不是"合格",它是没有人做过这个决定,
// 混进来会让这张表看起来像"全部物料都盯着"。页面用空状态把这件事说清楚。
export async function fetchSafety() {
    const supabase = await createClient()
    const rows = mustRows(
        await supabase.from('material_stock_available')
            .select('material_id, code, name, unit, safety_stock_qty, available_qty')
            .not('safety_stock_qty', 'is', null)
            .order('code'),
        'material_stock_available'
    ) as SafetyRow[]
    const monitored = rows.length
    const below = rows.filter((r) => r.available_qty < (r.safety_stock_qty ?? 0)).length
    return { rows, monitored, below }
}
