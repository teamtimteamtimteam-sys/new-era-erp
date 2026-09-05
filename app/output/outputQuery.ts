// app/output/outputQuery.ts
// 产出批次列表的查询逻辑(搜索 code / 状态 state / 客户 / 物料 / 排序 / 软删除过滤)集中在这里。
// 列表页 page.tsx 和 CSV 导出 export/route.ts 都调用这里 —— 过滤条件只有一份定义,两边不漂移。
// 端口自 inbound:supplier→customer、stage→state。
//   * 关联方筛选用【FK-id 下拉】—— .eq('customer_id', id) / .eq('material_id', id)。
//   * 嵌入(materials(name) / customers(legal_name))只用于展示;过滤都打在本表列上。
//   * 注意:customer_id 可空(库存中的批次还没指派客户)—— 选了某客户时,null 客户的行自然不匹配。
//
// 跨关联方搜索(按物料名 / 客户名)用【先查 id、再 OR 本表 FK 列】的两步法:
//   不做 join —— 所以【未售出(customer 为空)的行不会被误删】,只是不匹配"客户名"那一段;
//   count/range/sort/export 都照常工作。
import type { createClient } from '@/lib/supabase/server'
import { STATE_OPTIONS } from '../inbound/options'
import { parseDateRange } from '@/lib/dateFilter'
import { mustRows } from '@/lib/db-helpers'

// page.tsx 和 route.ts 都是服务端,这里只借用 server client 的"类型",不引入它的运行时。
type ServerSupabase = Awaited<ReturnType<typeof createClient>>

// 合法的 state 规范值集合(校验下拉传入的值)
const STATE_VALUES: readonly string[] = STATE_OPTIONS.map((o) => o.value)

// 允许排序的列白名单(只含本表列;不排序嵌入的客户/物料名)。
export const OUTPUT_SORTABLE = [
    'code',
    'output_date',
    'created_at',
    'quantity',
    'remaining_qty',
] as const
export type OutputSortCol = (typeof OUTPUT_SORTABLE)[number]

export interface OutputListParams {
    q: string
    state: string // '' 表示不按状态过滤
    customerId: string // '' 表示不按客户过滤
    materialId: string // '' 表示不按物料过滤
    dateFrom: string // '' 表示不按 output_date 起始过滤
    dateTo: string // '' 表示不按 output_date 结束过滤
    sort: OutputSortCol
    dir: 'asc' | 'desc'
}

// 列表每页行数。集中成常量,方便调整(改这一处即可)。
export const OUTPUT_PAGE_SIZE = 20

// 解析并校验 page 参数(1-based;非法/缺省一律按第 1 页)。
// 注意:分页只用于列表页;CSV 导出忽略 page,永远返回全部匹配行。
export function parseOutputPage(value: string | undefined): number {
    const n = Number(value)
    return Number.isInteger(n) && n >= 1 ? n : 1
}

// 解析并校验原始 URL searchParams,全部给安全默认值。
export function parseOutputListParams(sp: {
    q?: string
    state?: string
    customer_id?: string
    material_id?: string
    date_from?: string
    date_to?: string
    sort?: string
    dir?: string
}): OutputListParams {
    const q = (sp.q ?? '').trim()
    const { dateFrom, dateTo } = parseDateRange(sp)
    // 只接受 STATE_OPTIONS 里的规范值;其它按"不筛选"处理
    const state = sp.state && STATE_VALUES.includes(sp.state) ? sp.state : ''
    // FK-id:原样透传(.eq 是参数化的,注入安全);空串表示不筛选
    const customerId = (sp.customer_id ?? '').trim()
    const materialId = (sp.material_id ?? '').trim()
    const sort: OutputSortCol = (OUTPUT_SORTABLE as readonly string[]).includes(
        sp.sort ?? ''
    )
        ? (sp.sort as OutputSortCol)
        : 'created_at'
    const dir: 'asc' | 'desc' = sp.dir === 'asc' ? 'asc' : 'desc'
    return { q, state, customerId, materialId, dateFrom, dateTo, sort, dir }
}

// 关联方搜索:把匹配 q 的物料 / 客户 id 查出来(各一条 ilike 查询,仅在 q 非空时执行)。
// q 为空时不发查询,直接返回空数组 —— 常态(无搜索)零额外开销。
export interface OutputSearchIds {
    materialIds: string[]
    customerIds: string[]
}

export async function resolveOutputSearchIds(
    supabase: ServerSupabase,
    q: string
): Promise<OutputSearchIds> {
    if (!q) return { materialIds: [], customerIds: [] }
    const pattern = `%${q}%`
    const [matRes, custRes] = await Promise.all([
        supabase.from('material_lookup').select('id').is('deleted_at', null).ilike('name', pattern),
        supabase
            .from('customer_lookup')
            .select('id')
            .is('deleted_at', null)
            .ilike('legal_name', pattern),
    ])
    // 视图列在生成类型里一律可空;行进了视图即非空 —— 取用处本地锁死。
    type IdRow = { id: string }
    return {
        materialIds: (mustRows(matRes) as unknown as IdRow[]).map((r) => r.id),
        customerIds: (mustRows(custRes) as unknown as IdRow[]).map((r) => r.id),
    }
}

// 构造搜索用的 .or() 表达式(全部打在本表自有列上):
//   始终包含 code.ilike.%q%;当匹配到物料/客户 id 时,各加一段 *_id.in.("uuid"...)。
//   绝不输出空的 in.() ;UUID 双引号包裹。q 为空 → 返回 null(不加搜索过滤)。
//   未售出(customer_id 为 null)的行:不匹配 customer_id.in 那段,但因无 join 不会被删除。
export function buildOutputSearchOr(q: string, ids: OutputSearchIds): string | null {
    if (!q) return null
    // 去掉会破坏 PostgREST or() 表达式的字符(逗号 / 括号),再做 ilike 模糊匹配
    const safe = q.replace(/[,()]/g, ' ')
    const arms = [`code.ilike.%${safe}%`]
    if (ids.materialIds.length) {
        arms.push(`material_id.in.(${ids.materialIds.map((id) => `"${id}"`).join(',')})`)
    }
    if (ids.customerIds.length) {
        arms.push(`customer_id.in.(${ids.customerIds.map((id) => `"${id}"`).join(',')})`)
    }
    return arms.join(',')
}

// supabase filter builder 上我们用到的几个链式方法(都返回自身)。
// 只声明最小子集,避免引入 supabase 那套很深的泛型 —— 否则 tsc 会因类型实例化过深而 OOM。
interface OutputQueryChain {
    is(column: string, value: null): OutputQueryChain
    or(filters: string): OutputQueryChain
    eq(column: string, value: string): OutputQueryChain
    gte(column: string, value: string): OutputQueryChain
    lte(column: string, value: string): OutputQueryChain
    order(column: string, options: { ascending: boolean }): OutputQueryChain
}

// 在调用方已 .select(...) 好的查询上,套用 软删除过滤 / 搜索 / 状态 / 客户 / 物料 / 排序。
// searchOr 由 buildOutputSearchOr 预先算好(code + 匹配的物料/客户 id),为 null 时不加搜索。
// 用泛型 T 透传调用方的具体查询类型(保留返回行类型,包括嵌入),内部只借助 OutputQueryChain 最小接口。
// 注意:这里不做分页 —— 列表页另行 .range(),导出则取全部匹配行。
export function applyOutputFilters<T>(
    query: T,
    params: OutputListParams,
    searchOr: string | null
): T {
    const { state, customerId, materialId, dateFrom, dateTo, sort, dir } = params

    let chain = query as unknown as OutputQueryChain

    // 软删除过滤
    chain = chain.is('deleted_at', null)

    // 产出日期区间(output_date)
    if (dateFrom) {
        chain = chain.gte('output_date', dateFrom)
    }
    if (dateTo) {
        chain = chain.lte('output_date', dateTo)
    }

    // 搜索:code + 匹配到的物料/客户 id,全部在本表自有列上做 OR(无 join,未售出行不受影响)
    if (searchOr) {
        chain = chain.or(searchOr)
    }

    if (state) {
        chain = chain.eq('state', state)
    }

    if (customerId) {
        chain = chain.eq('customer_id', customerId)
    }

    if (materialId) {
        chain = chain.eq('material_id', materialId)
    }

    chain = chain.order(sort, { ascending: dir === 'asc' })

    return chain as unknown as T
}
