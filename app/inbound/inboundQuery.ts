// app/inbound/inboundQuery.ts
// 进料批次列表的查询逻辑(搜索 code / 阶段 stage / 供应商 / 物料 / 排序 / 软删除过滤)集中在这里。
// 列表页 page.tsx 和 CSV 导出 export/route.ts 都调用这里 —— 过滤条件只有一份定义,两边不漂移。
//
// 事务表与主数据表的关键不同:这里有外键(supplier_id / material_id)。
//   * 关联方筛选用【FK-id 下拉】—— .eq('supplier_id', id) / .eq('material_id', id),
//     不做跨嵌入关系的自由文本搜索(那需要 !inner join + 多关系 .or(),复杂)。
//   * 嵌入(materials(name) / suppliers(legal_name))只用于展示;过滤都打在本表的列上,
//     所以 applyInboundFilters 既能套在"带嵌入的 select"上(列表/导出),也能套在 'id' 上(count)。
//
// 跨关联方搜索(按物料名 / 供应商名)用【先查 id、再 OR 本表 FK 列】的两步法:
//   不做 join —— 所以不会把无供应商的行误删,count/range/sort/export 都照常工作。
import type { createClient } from '@/lib/supabase/server'
import { STAGE_OPTIONS } from './options'
import { parseDateRange } from '@/lib/dateFilter'

// page.tsx 和 route.ts 都是服务端,这里只借用 server client 的"类型",不引入它的运行时。
type ServerSupabase = Awaited<ReturnType<typeof createClient>>

// 合法的 stage 规范值集合(校验下拉传入的值)
const STAGE_VALUES: readonly string[] = STAGE_OPTIONS.map((o) => o.value)

// 允许排序的列白名单(只含本表列;不排序嵌入的供应商/物料名 —— 那需要 referencedTable 排序)。
export const INBOUND_SORTABLE = [
    'code',
    'arrival_date',
    'created_at',
    'quantity',
    'remaining_qty',
] as const
export type InboundSortCol = (typeof INBOUND_SORTABLE)[number]

// 定价状态(cut 5a 起的本表列):'' 表示不筛选
export const PRICING_STATUS_VALUES = ['unpriced', 'provisional', 'final'] as const

export interface InboundListParams {
    q: string
    stage: string // '' 表示不按阶段过滤
    supplierId: string // '' 表示不按供应商过滤
    materialId: string // '' 表示不按物料过滤
    dateFrom: string // '' 表示不按 arrival_date 起始过滤
    dateTo: string // '' 表示不按 arrival_date 结束过滤
    pricingStatus: string // '' 表示不按定价状态过滤
    sort: InboundSortCol
    dir: 'asc' | 'desc'
}

// 列表每页行数。集中成常量,方便调整(改这一处即可)。
export const INBOUND_PAGE_SIZE = 20

// 解析并校验 page 参数(1-based;非法/缺省一律按第 1 页)。
// 注意:分页只用于列表页;CSV 导出忽略 page,永远返回全部匹配行。
export function parseInboundPage(value: string | undefined): number {
    const n = Number(value)
    return Number.isInteger(n) && n >= 1 ? n : 1
}

// 解析并校验原始 URL searchParams,全部给安全默认值。
export function parseInboundListParams(sp: {
    q?: string
    stage?: string
    supplier_id?: string
    material_id?: string
    date_from?: string
    date_to?: string
    pricing_status?: string
    sort?: string
    dir?: string
}): InboundListParams {
    const q = (sp.q ?? '').trim()
    const { dateFrom, dateTo } = parseDateRange(sp)
    // 只接受 STAGE_OPTIONS 里的规范值;其它按"不筛选"处理
    const stage = sp.stage && STAGE_VALUES.includes(sp.stage) ? sp.stage : ''
    // FK-id:原样透传(.eq 是参数化的,注入安全);空串表示不筛选
    const supplierId = (sp.supplier_id ?? '').trim()
    const materialId = (sp.material_id ?? '').trim()
    const sort: InboundSortCol = (INBOUND_SORTABLE as readonly string[]).includes(
        sp.sort ?? ''
    )
        ? (sp.sort as InboundSortCol)
        : 'created_at'
    const dir: 'asc' | 'desc' = sp.dir === 'asc' ? 'asc' : 'desc'
    // 只接受三个规范值;其它按"不筛选"处理
    const pricingStatus = (PRICING_STATUS_VALUES as readonly string[]).includes(sp.pricing_status ?? '')
        ? sp.pricing_status!
        : ''
    return { q, stage, supplierId, materialId, dateFrom, dateTo, pricingStatus, sort, dir }
}

// 关联方搜索:把匹配 q 的物料 / 供应商 id 查出来(各一条 ilike 查询,仅在 q 非空时执行)。
// q 为空时不发查询,直接返回空数组 —— 常态(无搜索)零额外开销。
export interface InboundSearchIds {
    materialIds: string[]
    supplierIds: string[]
}

export async function resolveInboundSearchIds(
    supabase: ServerSupabase,
    q: string
): Promise<InboundSearchIds> {
    if (!q) return { materialIds: [], supplierIds: [] }
    const pattern = `%${q}%`
    const [matRes, supRes] = await Promise.all([
        supabase.from('materials').select('id').is('deleted_at', null).ilike('name', pattern),
        supabase
            .from('suppliers')
            .select('id')
            .is('deleted_at', null)
            .ilike('legal_name', pattern),
    ])
    return {
        materialIds: (matRes.data ?? []).map((r) => r.id),
        supplierIds: (supRes.data ?? []).map((r) => r.id),
    }
}

// 构造搜索用的 .or() 表达式(全部打在本表自有列上):
//   始终包含 code.ilike.%q%;当匹配到物料/供应商 id 时,各加一段 *_id.in.("uuid"...)。
//   绝不输出空的 in.() ；UUID 双引号包裹。q 为空 → 返回 null(不加搜索过滤)。
export function buildInboundSearchOr(q: string, ids: InboundSearchIds): string | null {
    if (!q) return null
    // 去掉会破坏 PostgREST or() 表达式的字符(逗号 / 括号),再做 ilike 模糊匹配
    const safe = q.replace(/[,()]/g, ' ')
    const arms = [`code.ilike.%${safe}%`]
    if (ids.materialIds.length) {
        arms.push(`material_id.in.(${ids.materialIds.map((id) => `"${id}"`).join(',')})`)
    }
    if (ids.supplierIds.length) {
        arms.push(`supplier_id.in.(${ids.supplierIds.map((id) => `"${id}"`).join(',')})`)
    }
    return arms.join(',')
}

// supabase filter builder 上我们用到的几个链式方法(都返回自身)。
// 只声明最小子集,避免引入 supabase 那套很深的泛型 —— 否则 tsc 会因类型实例化过深而 OOM。
interface InboundQueryChain {
    is(column: string, value: null): InboundQueryChain
    or(filters: string): InboundQueryChain
    eq(column: string, value: string): InboundQueryChain
    gte(column: string, value: string): InboundQueryChain
    lte(column: string, value: string): InboundQueryChain
    order(column: string, options: { ascending: boolean }): InboundQueryChain
}

// 在调用方已 .select(...) 好的查询上,套用 软删除过滤 / 搜索 / 阶段 / 供应商 / 物料 / 排序。
// searchOr 由 buildInboundSearchOr 预先算好(code + 匹配的物料/供应商 id),为 null 时不加搜索。
// 用泛型 T 透传调用方的具体查询类型(保留返回行类型,包括嵌入),内部只借助 InboundQueryChain 最小接口。
// 注意:这里不做分页 —— 列表页另行 .range(),导出则取全部匹配行。
export function applyInboundFilters<T>(
    query: T,
    params: InboundListParams,
    searchOr: string | null
): T {
    const { stage, supplierId, materialId, dateFrom, dateTo, pricingStatus, sort, dir } = params

    let chain = query as unknown as InboundQueryChain

    // 软删除过滤
    chain = chain.is('deleted_at', null)

    // 到货日期区间(arrival_date)
    if (dateFrom) {
        chain = chain.gte('arrival_date', dateFrom)
    }
    if (dateTo) {
        chain = chain.lte('arrival_date', dateTo)
    }

    // 搜索:code + 匹配到的物料/供应商 id,全部在本表自有列上做 OR(无 join)
    if (searchOr) {
        chain = chain.or(searchOr)
    }

    if (stage) {
        chain = chain.eq('stage', stage)
    }

    if (supplierId) {
        chain = chain.eq('supplier_id', supplierId)
    }

    if (materialId) {
        chain = chain.eq('material_id', materialId)
    }

    if (pricingStatus) {
        chain = chain.eq('pricing_status', pricingStatus)
    }

    chain = chain.order(sort, { ascending: dir === 'asc' })

    return chain as unknown as T
}
