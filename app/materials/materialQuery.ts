// app/materials/materialQuery.ts
// 物料列表的查询逻辑(搜索 q / 分类 category / 排序 sort+dir / 软删除过滤)集中在这里。
// 列表页 page.tsx 和 CSV 导出 export/route.ts 都调用这里 —— 过滤条件只有一份定义,两边不漂移。
// 对照 suppliers:这里的"分类筛选"对应 suppliers 的"状态筛选",但 category 不是 DB 枚举,
// 而是 app 层用 options.ts(CATEGORY_OPTIONS)约束的值;且 CustomSelect 允许自由文本,
// 所以自由文本的 category 行无法被下拉选中(可接受 —— 仍可被搜索命中)。
import { CATEGORY_OPTIONS } from './options'

// 合法的 category 规范值集合(用于校验下拉传入的值,挡掉乱填的 URL 参数)
const CATEGORY_VALUES: readonly string[] = CATEGORY_OPTIONS.map((o) => o.value)

// 允许排序的列白名单(防止任意列名进入 .order())。
// 不含 category(按中文规范值排序无意义)、不含 status(单一死值)。
export const MATERIAL_SORTABLE = ['code', 'name', 'created_at'] as const
export type MaterialSortCol = (typeof MATERIAL_SORTABLE)[number]

// 空字符串表示"不按分类过滤"
export type MaterialCategoryFilter = string

export interface MaterialListParams {
    q: string
    category: MaterialCategoryFilter
    sort: MaterialSortCol
    dir: 'asc' | 'desc'
}

// 列表每页行数。集中成常量,方便调整(改这一处即可)。
export const MATERIAL_PAGE_SIZE = 20

// 解析并校验 page 参数(1-based;非法/缺省一律按第 1 页)。
// 注意:分页只用于列表页;CSV 导出忽略 page,永远返回全部匹配行。
export function parseMaterialPage(value: string | undefined): number {
    const n = Number(value)
    return Number.isInteger(n) && n >= 1 ? n : 1
}

// 解析并校验原始 URL searchParams,全部给安全默认值。
export function parseMaterialListParams(sp: {
    q?: string
    category?: string
    sort?: string
    dir?: string
}): MaterialListParams {
    const q = (sp.q ?? '').trim()
    // 只接受 CATEGORY_OPTIONS 里的规范值;其它(含自由文本/乱填)按"不筛选"处理
    const category: MaterialCategoryFilter =
        sp.category && CATEGORY_VALUES.includes(sp.category) ? sp.category : ''
    const sort: MaterialSortCol = (MATERIAL_SORTABLE as readonly string[]).includes(
        sp.sort ?? ''
    )
        ? (sp.sort as MaterialSortCol)
        : 'created_at'
    const dir: 'asc' | 'desc' = sp.dir === 'asc' ? 'asc' : 'desc'
    return { q, category, sort, dir }
}

// supabase filter builder 上我们用到的几个链式方法(都返回自身)。
// 只声明最小子集,避免引入 supabase 那套很深的泛型 —— 否则 tsc 会因类型实例化过深而 OOM。
interface MaterialQueryChain {
    is(column: string, value: null): MaterialQueryChain
    or(filters: string): MaterialQueryChain
    eq(column: string, value: string): MaterialQueryChain
    order(column: string, options: { ascending: boolean }): MaterialQueryChain
}

// 在调用方已 .select(...) 好的查询上,套用 软删除过滤 / 搜索 / 分类 / 排序。
// 用泛型 T 透传调用方的具体查询类型(保留返回行类型),内部只借助 MaterialQueryChain 这一最小接口。
// 注意:这里不做分页 —— 列表页另行 .range(),导出则取全部匹配行。
export function applyMaterialFilters<T>(query: T, params: MaterialListParams): T {
    const { q, category, sort, dir } = params

    let chain = query as unknown as MaterialQueryChain

    // 软删除过滤
    chain = chain.is('deleted_at', null)

    if (q) {
        // 去掉会破坏 PostgREST or() 表达式的字符(逗号 / 括号),再做 ilike 模糊匹配
        const safe = q.replace(/[,()]/g, ' ')
        const pattern = `%${safe}%`
        chain = chain.or(
            `code.ilike.${pattern},name.ilike.${pattern},spec.ilike.${pattern}`
        )
    }

    if (category) {
        chain = chain.eq('category', category)
    }

    chain = chain.order(sort, { ascending: dir === 'asc' })

    return chain as unknown as T
}
