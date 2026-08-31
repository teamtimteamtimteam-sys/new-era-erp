// RPT-1:快照的取数 —— 页面、CSV、PDF 三处共用这一份(进料导出的规矩)。
//
// INV-VAL-1:这一份现在同时带回【金额】。取数从 stock_snapshot 换成
// inventory_valuation_snapshot,而两者【数出同样的量】是一条被断言过的性质
// (fu2:实测 by_location 合计 = stock_snapshot 合计 = 119,304)——
// 换过来正是为了让"数量表"与"金额表"不可能是两张互相矛盾的表。
//
// ★【金额读不到时是 null,不是 0】★ 没有 data.view_prices 的读者(实测:
// operations 与 warehouse)拿到 value_base = null 加一条具名 restriction。
// 三处渲染都必须把它印成【受限】,不是印成 0.00,也不是把那一行悄悄略掉 ——
// 一个少算了的合计会被人抄进决策,而"受限"两个字会让人去要权限。
import { createClient } from '@/lib/supabase/server'

export type SnapshotRow = {
    material_code: string
    material_name: string
    unit: string
    location_id: string | null
    location_code: string | null
    location_name: string | null
    stock_status: string
    // 'inbound' = 进料腿(到岸成本)· 'output' = 产出腿(分摊出来的单位成本)。
    // 两个口径写在同一张表里,而每一行说得出自己是哪一个。
    batch_kind: 'inbound' | 'output'
    qty: number
    value_base: number | null
    // 【没有成本口径的量】进料侧"没有价",产出侧"从未分摊" —— 都不是"值 0"。
    uncosted_qty: number
}

export type AgeingRow = {
    bucket: string
    batches: number
    qty: number
    value_base: number | null
}

export type Produced = {
    on_hand_batches: number
    on_hand_qty: number
    costed_value_base: number | null
    never_costed_batches: number
    never_costed_qty: number
}

export type Valuation = {
    as_of: string
    base_currency: string
    prices_visible: boolean
    restriction: string | null
    rows: SnapshotRow[]
    ageing: AgeingRow[]
    produced: Produced
    cannotSee: Record<string, unknown>
}

// 【无过滤器,也无界】理由写在 reportShared.LEDGER_DEFAULT_DAYS 的注释里:
// 这张表的行数由"有多少物料 × 多少库位 × 三种状态里非零的格子"决定,不随时间增长。
//
// 【p_as_of 传 null =「此刻」,而且【必须】由数据库来定这个"此刻"】线上 DB 的
// 时区是 Asia/Singapore,应用侧 toISOString() 给的是 UTC 日期 —— 每天
// 00:00–08:00 两者差一天,自己算会把页面拒掉八个小时(fu3 的抬头记着实测)。
export async function fetchValuation(): Promise<Valuation> {
    const supabase = await createClient()
    // 【不传 p_as_of】它在 SQL 侧 DEFAULT NULL,而 NULL 的含义是「此刻」——
    // 由数据库来定,不由应用的时区来定(fu3/fu4 的抬头记着实测)。
    const { data, error } = await supabase.rpc('inventory_valuation_snapshot')
    if (error) throw error
    const v = data as unknown as {
        as_of: string; base_currency: string; prices_visible: boolean; restriction: string | null
        by_location: SnapshotRow[]; ageing: AgeingRow[]; produced: Produced
        cannot_see: Record<string, unknown>
    }
    return {
        as_of: v.as_of,
        base_currency: v.base_currency,
        prices_visible: v.prices_visible,
        restriction: v.restriction,
        rows: v.by_location ?? [],
        ageing: v.ageing ?? [],
        produced: v.produced,
        cannotSee: v.cannot_see ?? {},
    }
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
    // SO-2:第三个桶(销售订单预留)
    committed: 'reports.statusCommitted',
}
export const statusKey = (s: string) => STATUS_KEY[s] ?? 'reports.statusUnknown'

// 库龄档 → 文案键。【同样是静态映射】档位的边界定义在 DB 的 aging_bucket,
// 这里只把它翻译成人话;'no_date' 是一个【被渲染出来的档位】,不是一个空行 ——
// 线上 4 张在库批次没有到货日,占在库价值的 58.7%。
export const BUCKET_KEY: Record<string, string> = {
    b0_30: 'reports.ageing.b0_30',
    b31_60: 'reports.ageing.b31_60',
    b61_90: 'reports.ageing.b61_90',
    b90_plus: 'reports.ageing.b90_plus',
    no_date: 'reports.ageing.noDate',
}
export const bucketKey = (b: string) => BUCKET_KEY[b] ?? 'reports.ageing.noDate'
