// app/sales/customers/customerQuery.ts
// 客户列表的查询逻辑(搜索 q / 排序 sort+dir / 软删除过滤)集中在这里。
// 列表页 page.tsx 和 CSV 导出 export/route.ts 都调用这里 —— 过滤条件只有一份定义,两边不漂移。
// 对照 suppliers:客户没有状态机/状态枚举(status 是单一死值 'draft'),所以【没有状态筛选】。

// 允许排序的列白名单(防止任意列名进入 .order())。
// 不含 status:客户状态目前是单一死值,按它排序无意义(详见模块说明)。
export const CUSTOMER_SORTABLE = ['legal_name', 'code', 'created_at'] as const
export type CustomerSortCol = (typeof CUSTOMER_SORTABLE)[number]

export interface CustomerListParams {
    q: string
    sort: CustomerSortCol
    dir: 'asc' | 'desc'
}

// 列表每页行数。集中成常量,方便调整(改这一处即可)。
export const CUSTOMER_PAGE_SIZE = 20

// 解析并校验 page 参数(1-based;非法/缺省一律按第 1 页)。
// 注意:分页只用于列表页;CSV 导出忽略 page,永远返回全部匹配行。
export function parseCustomerPage(value: string | undefined): number {
    const n = Number(value)
    return Number.isInteger(n) && n >= 1 ? n : 1
}

// 解析并校验原始 URL searchParams,全部给安全默认值。
export function parseCustomerListParams(sp: {
    q?: string
    sort?: string
    dir?: string
}): CustomerListParams {
    const q = (sp.q ?? '').trim()
    const sort: CustomerSortCol = (CUSTOMER_SORTABLE as readonly string[]).includes(
        sp.sort ?? ''
    )
        ? (sp.sort as CustomerSortCol)
        : 'created_at'
    const dir: 'asc' | 'desc' = sp.dir === 'asc' ? 'asc' : 'desc'
    return { q, sort, dir }
}

// supabase filter builder 上我们用到的几个链式方法(都返回自身)。
// 只声明最小子集,避免引入 supabase 那套很深的泛型 —— 否则 tsc 会因类型实例化过深而 OOM。
interface CustomerQueryChain {
    is(column: string, value: null): CustomerQueryChain
    or(filters: string): CustomerQueryChain
    order(column: string, options: { ascending: boolean }): CustomerQueryChain
}

// 在调用方已 .select(...) 好的查询上,套用 软删除过滤 / 搜索 / 排序。
// 用泛型 T 透传调用方的具体查询类型(保留返回行类型),内部只借助 CustomerQueryChain 这一最小接口。
// 注意:这里不做分页 —— 列表页另行 .range(),导出则取全部匹配行。
export function applyCustomerFilters<T>(query: T, params: CustomerListParams): T {
    const { q, sort, dir } = params

    let chain = query as unknown as CustomerQueryChain

    // 软删除过滤
    chain = chain.is('deleted_at', null)

    if (q) {
        // 去掉会破坏 PostgREST or() 表达式的字符(逗号 / 括号),再做 ilike 模糊匹配
        const safe = q.replace(/[,()]/g, ' ')
        const pattern = `%${safe}%`
        chain = chain.or(
            `code.ilike.${pattern},legal_name.ilike.${pattern},short_name.ilike.${pattern},tax_id.ilike.${pattern},country.ilike.${pattern}`
        )
    }

    chain = chain.order(sort, { ascending: dir === 'asc' })

    return chain as unknown as T
}
