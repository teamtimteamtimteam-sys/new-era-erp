// app/materials/materialQuery.ts
// 物料列表的查询逻辑(搜索 q / 分类 category / 排序 sort+dir / 软删除过滤)集中在这里。
// 列表页 page.tsx 和 CSV 导出 export/route.ts 都调用这里 —— 过滤条件只有一份定义,两边不漂移。
// 【PROC-1:筛的是 kind_code,不再是 category】
// 旧的分类筛选读的是一列【自由文本】,而它的合法取值住在 app 的 options.ts ——
// 第三份命名权威。实测后果:线上四行里有两行(NiH / black_mass)的值不在那份
// 清单里,于是【那个下拉根本选不中它们】,而没有任何东西说过这件事。
// 现在 kind_code 有外键,合法取值就是 material_kinds 的行 —— 校验因此交给数据库,
// 这里只做一件事:把乱填的 URL 参数当作"不筛选"。

// 允许排序的列白名单(防止任意列名进入 .order())。
// 不含 category(按中文规范值排序无意义)、不含 status(单一死值)。
export const MATERIAL_SORTABLE = ['code', 'name', 'created_at'] as const
export type MaterialSortCol = (typeof MATERIAL_SORTABLE)[number]

// 空字符串表示"不按种类过滤"
export type MaterialKindFilter = string

export interface MaterialListParams {
    q: string
    kind: MaterialKindFilter
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
    kind?: string
    sort?: string
    dir?: string
}): MaterialListParams {
    const q = (sp.q ?? '').trim()
    // 【合法性由外键保证,这里只挡形状】一个不存在的 code 会筛出零行,
    // 而"零行"与"不筛选"是两回事 —— 所以照传,由页面显示零行,不静默改成全量。
    const kind: MaterialKindFilter = (sp.kind ?? '').trim()
    const sort: MaterialSortCol = (MATERIAL_SORTABLE as readonly string[]).includes(
        sp.sort ?? ''
    )
        ? (sp.sort as MaterialSortCol)
        : 'created_at'
    const dir: 'asc' | 'desc' = sp.dir === 'asc' ? 'asc' : 'desc'
    return { q, kind, sort, dir }
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
    const { q, kind, sort, dir } = params

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

    if (kind) {
        chain = chain.eq('kind_code', kind)
    }

    chain = chain.order(sort, { ascending: dir === 'asc' })

    return chain as unknown as T
}
