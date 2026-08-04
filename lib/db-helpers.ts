import type { Database } from '@/lib/database.types'

type Tables = Database['public']['Tables']

// ════════════════════════════════════════════════════════════════════════════
// 【查询失败 ≠ 没有数据】—— 与 scripts/smoke-routes.mjs 的 restRows 是同一条政策,
// 也与 check-i18n 的"解析出 0 个后缀是坏,不是空集"是同一条政策。写在三处,是一条。
//
// 反面教材就在本仓库:/finance/processing-costs 的查询因列权限缺口 42501,页面
// 用 `entriesRes.data ?? []` 把错误变成空数组,于是渲染出 HTTP 200 的
// 「Nothing outstanding」—— 页面看着好好的,月结却少了一整步,几周没人发现。
// 冒烟测试也抓不到:它断言 2xx,而这页确实是 2xx。
//
// 所以:读不出来的页面【必须报错】,不许渲染一个诚实模样的空状态。
// 空数组只有一个合法来源 —— 查询成功且真的没有行。
//
// 用法:const list = mustRows(entriesRes)      // 失败即抛,Next 渲染错误边界
//       const row  = mustOne(periodRes)        // 失败即抛;成功但无行 → null
// 【不要】用在:已取回行上的嵌套关系字段、Map.get() 的默认值、客户端状态 ——
// 那些 `?? []` 是对的,与查询错误无关。
// ════════════════════════════════════════════════════════════════════════════
type QueryResult<T> = { data: T | null; error: { message: string; code?: string } | null }

function fail(error: { message: string; code?: string }, what: string): never {
    throw new Error(`查询失败(${what}): ${error.code ?? ''} ${error.message}`.trim())
}

/** 列表查询:失败即抛;成功无行 → []。 */
export function mustRows<T>(res: QueryResult<T[]>, what = 'list'): T[] {
    if (res.error) fail(res.error, what)
    return res.data ?? []
}

/** 单行查询(single / maybeSingle):失败即抛;成功无行 → null(这是合法状态)。 */
export function mustOne<T>(res: QueryResult<T>, what = 'row'): T | null {
    if (res.error) fail(res.error, what)
    return res.data
}

/** 计数查询:失败即抛,绝不悄悄读成 0 —— 0 会让"还有多少件没做"看起来是"做完了"。 */
export function mustCount(res: { count: number | null; error: { message: string; code?: string } | null },
                      what = 'count'): number {
    if (res.error) fail(res.error, what)
    return res.count ?? 0
}

// 取某张表的 Insert 类型。code 由 BEFORE INSERT 触发器自动生成，
// 前端插入时用 as 断言成这个类型即可（运行时 code 必被触发器填充）。
export type InsertRow<T extends keyof Tables> = Tables[T]['Insert']
