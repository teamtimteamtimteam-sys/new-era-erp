// app/suppliers/supplierQuery.ts
// 供应商列表的查询逻辑(搜索 q / 状态 status / 排序 sort+dir / 软删除过滤)集中在这里。
// 列表页 page.tsx 和 CSV 导出 export/route.ts 都调用这里 —— 过滤条件只有一份定义,
// 两边永远一致,不会因为各自维护而漂移。新增可导出/可筛选模块时按同样模式抽 *Query 文件。
import { SUPPLIER_STATUSES } from './[id]/edit/statusMachine'

// 允许排序的列白名单(防止任意列名进入 .order())
export const SUPPLIER_SORTABLE = ['legal_name', 'code', 'status', 'created_at'] as const
export type SupplierSortCol = (typeof SUPPLIER_SORTABLE)[number]

// 空字符串表示"不按状态过滤"
export type SupplierStatusFilter = (typeof SUPPLIER_STATUSES)[number] | ''

export interface SupplierListParams {
    q: string
    status: SupplierStatusFilter
    sort: SupplierSortCol
    dir: 'asc' | 'desc'
}

// 列表每页行数。集中成常量,方便调整(改这一处即可)。
export const SUPPLIER_PAGE_SIZE = 20

// 解析并校验 page 参数(1-based;非法/缺省一律按第 1 页)。
// 注意:分页只用于列表页;CSV 导出忽略 page,永远返回全部匹配行。
export function parseSupplierPage(value: string | undefined): number {
    const n = Number(value)
    return Number.isInteger(n) && n >= 1 ? n : 1
}

// 解析并校验原始 URL searchParams,全部给安全默认值。
export function parseSupplierListParams(sp: {
    q?: string
    status?: string
    sort?: string
    dir?: string
}): SupplierListParams {
    const q = (sp.q ?? '').trim()
    const status: SupplierStatusFilter =
        sp.status && (SUPPLIER_STATUSES as readonly string[]).includes(sp.status)
            ? (sp.status as SupplierStatusFilter)
            : ''
    const sort: SupplierSortCol = (SUPPLIER_SORTABLE as readonly string[]).includes(
        sp.sort ?? ''
    )
        ? (sp.sort as SupplierSortCol)
        : 'created_at'
    const dir: 'asc' | 'desc' = sp.dir === 'asc' ? 'asc' : 'desc'
    return { q, status, sort, dir }
}

// supabase filter builder 上我们用到的几个链式方法(都返回自身)。
// 只声明最小子集,避免引入 supabase 那套很深的泛型 —— 否则 tsc 会因类型实例化过深而 OOM。
interface SupplierQueryChain {
    is(column: string, value: null): SupplierQueryChain
    or(filters: string): SupplierQueryChain
    eq(column: string, value: string): SupplierQueryChain
    order(column: string, options: { ascending: boolean }): SupplierQueryChain
}

// 在调用方已 .select(...) 好的查询上,套用 软删除过滤 / 搜索 / 状态 / 排序。
// 用泛型 T 透传调用方的具体查询类型(从而保留它的返回行类型),内部只借助
// SupplierQueryChain 这一最小接口链式调用 —— 过滤逻辑单点维护,且不拖垮类型检查。
// 注意:这里不做分页 —— 列表页和导出都拿"全部匹配行"。
export function applySupplierFilters<T>(query: T, params: SupplierListParams): T {
    const { q, status, sort, dir } = params

    let chain = query as unknown as SupplierQueryChain

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

    if (status) {
        chain = chain.eq('status', status)
    }

    chain = chain.order(sort, { ascending: dir === 'asc' })

    return chain as unknown as T
}
