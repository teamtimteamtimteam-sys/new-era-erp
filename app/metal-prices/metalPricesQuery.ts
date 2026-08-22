// app/metal-prices/metalPricesQuery.ts
// 金属价格列表的查询逻辑(金属筛选 / 排序 / 软删除过滤 / 分页)集中在这里。
// 端口自 inboundQuery,但刻意精简:单表、无外键、无搜索、无导出 —— 这是一张 7 金属参考表。
// PROC-4:这一支是【纯参数解析】,没有 supabase 也不该有 —— 所以合法集合
// 由调用方(页面)读好字典传进来。这样它仍然是一个可测的纯函数,
// 而"哪些物质合法"这件事只有一个真源。

// 允许排序的列白名单(只含本表列)。
export const METAL_PRICES_SORTABLE = [
    'price_date',
    'metal',
    'price_usd_per_tonne',
] as const
export type MetalPricesSortCol = (typeof METAL_PRICES_SORTABLE)[number]

export interface MetalPricesListParams {
    metal: string // '' 表示不按金属过滤
    sort: MetalPricesSortCol
    dir: 'asc' | 'desc'
}

// 列表每页行数。集中成常量,方便调整(改这一处即可)。
export const METAL_PRICES_PAGE_SIZE = 20

// 解析并校验 page 参数(1-based;非法/缺省一律按第 1 页)。
export function parseMetalPricesPage(value: string | undefined): number {
    const n = Number(value)
    return Number.isInteger(n) && n >= 1 ? n : 1
}

// 解析并校验原始 URL searchParams,全部给安全默认值。默认排序 price_date DESC。
export function parseMetalPricesListParams(sp: {
    metal?: string
    sort?: string
    dir?: string
}, allowedMetals: readonly string[]): MetalPricesListParams {
    // 只接受字典里的码;其它按"不筛选"处理(PROC-4:七个写死的值没了)
    const metal = sp.metal && allowedMetals.includes(sp.metal) ? sp.metal : ''
    const sort: MetalPricesSortCol = (METAL_PRICES_SORTABLE as readonly string[]).includes(
        sp.sort ?? ''
    )
        ? (sp.sort as MetalPricesSortCol)
        : 'price_date'
    const dir: 'asc' | 'desc' = sp.dir === 'asc' ? 'asc' : 'desc'
    return { metal, sort, dir }
}

// supabase filter builder 上我们用到的最小链式子集(避免引入 supabase 那套很深的泛型)。
interface MetalPricesQueryChain {
    is(column: string, value: null): MetalPricesQueryChain
    eq(column: string, value: string): MetalPricesQueryChain
    order(column: string, options: { ascending: boolean }): MetalPricesQueryChain
}

// 在调用方已 .select(...) 好的查询上,套用 软删除过滤 / 金属过滤 / 排序。
// 默认(按 price_date)时追加次级排序 metal ASC —— 满足"price_date DESC then metal ASC"。
// 用泛型 T 透传调用方的具体查询类型;内部只借助最小接口。不做分页(列表页另行 .range())。
export function applyMetalPricesFilters<T>(
    query: T,
    params: MetalPricesListParams
): T {
    const { metal, sort, dir } = params

    let chain = query as unknown as MetalPricesQueryChain

    // 软删除过滤
    chain = chain.is('deleted_at', null)

    if (metal) {
        chain = chain.eq('metal', metal)
    }

    chain = chain.order(sort, { ascending: dir === 'asc' })

    // 次级排序:非"按金属"排序时,同值再按 metal ASC 稳定排序(默认视图 = price_date DESC, metal ASC)
    if (sort !== 'metal') {
        chain = chain.order('metal', { ascending: true })
    }

    return chain as unknown as T
}
