// RPT-1:快照的取数 —— 页面、CSV、PDF 三处共用这一份(进料导出的规矩)。
import { createClient } from '@/lib/supabase/server'
import { mustRows } from '@/lib/db-helpers'

export type SnapshotRow = {
    material_id: string
    material_code: string
    material_name: string
    unit: string
    location_id: string | null
    location_code: string | null
    location_name: string | null
    stock_status: string
    qty: number
}

// 【无过滤器,也无界】理由写在 reportShared.LEDGER_DEFAULT_DAYS 的注释里:
// 这张表的行数由"有多少物料 × 多少库位 × 三种状态里非零的格子"决定,不随时间增长。
export async function fetchSnapshot(): Promise<SnapshotRow[]> {
    const supabase = await createClient()
    return mustRows(
        await supabase
            .from('stock_snapshot')
            .select('material_id, material_code, material_name, unit, location_id, location_code, location_name, stock_status, qty')
            .order('material_code')
            .order('stock_status'),
        'stock_snapshot'
    ) as SnapshotRow[]
}

// 未指定库位排在最后 —— 它是一个普通分组,不是脚注,但也不该抢在真库位前面。
export function groupByLocation(rows: SnapshotRow[]) {
    const map = new Map<string, { code: string | null; name: string | null; rows: SnapshotRow[] }>()
    for (const r of rows) {
        const key = r.location_id ?? '__unspecified__'
        if (!map.has(key)) map.set(key, { code: r.location_code, name: r.location_name, rows: [] })
        map.get(key)!.rows.push(r)
    }
    return [...map.entries()].sort((a, b) => {
        if (a[0] === '__unspecified__') return 1
        if (b[0] === '__unspecified__') return -1
        return (a[1].code ?? '').localeCompare(b[1].code ?? '')
    })
}

// 状态 → 文案键。【静态映射,不是动态拼键】—— 拼出来的键要在 check-i18n 的
// MANIFEST 里登记一个新前缀;这张表里的字面量则由键样字面量收网直接验到。
export const STATUS_KEY: Record<string, string> = {
    available: 'reports.statusAvailable',
    on_hold: 'reports.statusOnHold',
}
export const statusKey = (s: string) => STATUS_KEY[s] ?? 'reports.statusUnknown'
