// RPT-1:分类违规报表的取数。
//
// 【三态在页面上也是三段,而不是一个数字】违规是【有人做过决定、而货与它冲突】;
// 未配置的库位与未分类的物料是【还没有人决定过】—— 它们不是违规,永远不进违规
// 计数。把三者加在一起报一个"合规问题:N",就是把系统的沉默说成人的意志
// (IOD-2 表头那条,报表这一侧的对应物)。
import { createClient } from '@/lib/supabase/server'
import { mustRows } from '@/lib/db-helpers'

export type ViolationRow = {
    material_id: string; material_code: string; class_code: string
    location_id: string; location_code: string; qty: number
}
export type UndecidedRow = { code: string; name: string; qty: number; unit: string; other: string }

export async function fetchViolations() {
    const supabase = await createClient()

    const violations = mustRows(
        await supabase.from('stock_class_violations')
            .select('material_id, material_code, class_code, location_id, location_code, qty')
            .order('location_code'),
        'stock_class_violations'
    ) as ViolationRow[]

    // 两段【未决定】:从快照里现算 —— 与违规同一份存量,不同的判据。
    const snap = mustRows(
        await supabase.from('stock_snapshot')
            .select('material_id, material_code, material_name, unit, location_id, location_code, location_name, stock_status, qty')
            .eq('stock_status', 'available'),
        'stock_snapshot'
    ) as { material_id: string; material_code: string; material_name: string; unit: string
           location_id: string | null; location_code: string | null; location_name: string | null; qty: number }[]

    const mats = mustRows(
        await supabase.from('material_lookup').select('id, waste_classification_code').is('deleted_at', null),
        'materials'
    ) as { id: string; waste_classification_code: string | null }[]
    const unclassified = new Set(mats.filter((m) => !m.waste_classification_code).map((m) => m.id))

    const configuredRows = mustRows(
        await supabase.from('storage_location_allowed_classes').select('location_id'),
        'storage_location_allowed_classes'
    ) as { location_id: string }[]
    const configured = new Set(configuredRows.map((r) => r.location_id))

    // 未配置的库位上有货(未指定库位不算 —— 那不是一个"没配置的库位",它根本不是库位)
    const unconfigured: UndecidedRow[] = snap
        .filter((r) => r.location_id !== null && !configured.has(r.location_id) && r.qty > 0)
        .map((r) => ({ code: r.location_code ?? '', name: r.location_name ?? '',
                       qty: r.qty, unit: r.unit, other: `${r.material_code} ${r.material_name}` }))

    // 未分类的物料有货(在哪都算 —— 分类是物料自己的属性)
    const unclassifiedRows: UndecidedRow[] = snap
        .filter((r) => unclassified.has(r.material_id) && r.qty > 0)
        .map((r) => ({ code: r.material_code, name: r.material_name, qty: r.qty, unit: r.unit,
                       other: r.location_code ?? '' }))

    return { violations, unconfigured, unclassified: unclassifiedRows }
}
