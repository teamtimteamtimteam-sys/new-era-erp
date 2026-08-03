// app/finance/fx/fxQuery.ts
// 汇率列表的查询逻辑(币种筛选 / 排序 / 软删除过滤 / 分页),端口自 metalPricesQuery。
// 语义:1 单位外币 = rate_sgd_per_unit 新元;SGD(本位币)无需行(表单里也不给选)。

// 允许排序的列白名单(只含本表列)。
export const FX_SORTABLE = ['rate_date', 'currency', 'rate_type', 'rate_sgd_per_unit'] as const
export type FxSortCol = (typeof FX_SORTABLE)[number]

export interface FxListParams {
    currency: string // '' 表示不按币种过滤
    sort: FxSortCol
    dir: 'asc' | 'desc'
}

export const FX_PAGE_SIZE = 20

export function parseFxPage(value: string | undefined): number {
    const n = Number(value)
    return Number.isInteger(n) && n >= 1 ? n : 1
}

// 币种参数不做白名单(选项来自 currencies 表,服务端 .eq 天然无注入),空 = 不过滤。
export function parseFxListParams(sp: {
    currency?: string
    sort?: string
    dir?: string
}): FxListParams {
    const currency = sp.currency?.trim() ?? ''
    const sort: FxSortCol = (FX_SORTABLE as readonly string[]).includes(sp.sort ?? '')
        ? (sp.sort as FxSortCol)
        : 'rate_date'
    const dir: 'asc' | 'desc' = sp.dir === 'asc' ? 'asc' : 'desc'
    return { currency, sort, dir }
}

// supabase filter builder 的最小链式子集(避免引入其深泛型)。
interface FxQueryChain {
    is(column: string, value: null): FxQueryChain
    eq(column: string, value: string): FxQueryChain
    order(column: string, options: { ascending: boolean }): FxQueryChain
}

// 套用 软删除过滤 / 币种过滤 / 排序;默认视图 = rate_date DESC, currency ASC。
export function applyFxFilters<T>(query: T, params: FxListParams): T {
    const { currency, sort, dir } = params
    let chain = query as unknown as FxQueryChain
    chain = chain.is('deleted_at', null)
    if (currency) {
        chain = chain.eq('currency', currency)
    }
    chain = chain.order(sort, { ascending: dir === 'asc' })
    if (sort !== 'currency') {
        chain = chain.order('currency', { ascending: true })
    }
    return chain as unknown as T
}
