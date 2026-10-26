// lib/listSort.ts
// ════════════════════════════════════════════════════════════════════════════
// TABLE-FEATURES-1(Tim 2026-10-25 Q9)· 在数据库里排序的列表 —— 解析 `?sort=&dir=`、按白名单下 ORDER BY
// ════════════════════════════════════════════════════════════════════════════
// 分页或「只画前 N 行」的列表(36 张)排序【必须在数据库里排】:页面手里只有一部分,在浏览器里排只排得了这一屏
// —— 那正是 data-table.tsx 抬头 A1 那条裁定要拦的谎(「这一屏里最大的」冒充「全体里最大的」)。
// 早先 8 页(inbound · output · materials · suppliers · customers · fx · metal-prices · processing)各自手写了同一个形状;
// 这里把那个形状写成一份,新转换的页面都用它。那 8 页原样留着(它们是对的),不为统一而重写。
//
// 规矩(每一张转换的表都要守):
//  ① **白名单**:列键 → 读取那一张关系(视图 / 表)上的【真实列名】。白名单外的 `?sort=` 一律退回默认,不报错 ——
//     一条手改出来的地址不该把页面变成 500。
//  ② **排的是页面读的那一张关系上的列**。读 `*_masked` 视图的页面就按视图上那一列排:读者看不见的值在那里是 NULL,
//     所以排序【不会】泄露一个被遮住的数的大小。不许按一张读者看不见的基表的列去排。
//  ③ 由别处查出来的列(名字查找、算出来的数、拼出来的文字)**不可排**:数据库里没有那一列,
//     而在浏览器里排它又只排得了这一屏。
//  ④ 每一个排序之后都跟【稳定的平局键】(通常是 id),否则同一个值的几行在翻页之间会跳来跳去。
//  ⑤ 导出路由读【同一份】参数(TABLE-EXPORT-1 Q2:导出按当前的筛选与排序取全体)。
// ════════════════════════════════════════════════════════════════════════════

/**
 * 线上 PostgREST 的 `max_rows`(TABLE-EXPORT-1 实测)。一次不翻页的读取拿到这么多行,就不能当成全体 ——
 * 在浏览器里排序的表此时关掉排序(Tim 2026-10-25 Q9)。写在这里(不是客户端模块里),服务端页面也读得到同一个数。
 */
export const READ_ROW_LIMIT = 1000

export type SortDir = 'asc' | 'desc'
export type ListSort<K extends string = string> = { key: K; dir: SortDir }

/**
 * 读 `?<prefix>sort=` 与 `?<prefix>dir=`。`prefix` 给一页上有两张在数据库里排的表时用(例如 `pending_`)。
 * 键不在白名单里 → 默认;dir 不是 asc/desc → 默认那一个的方向(键也退回默认时)或 desc。
 */
export function parseListSort<K extends string>(
    sp: Record<string, string | string[] | undefined>,
    keys: readonly K[],
    dflt: ListSort<K>,
    prefix = '',
): ListSort<K> {
    const one = (v: string | string[] | undefined) => (Array.isArray(v) ? v[0] : v)
    const rawKey = one(sp[`${prefix}sort`])
    const rawDir = one(sp[`${prefix}dir`])
    if (!rawKey || !(keys as readonly string[]).includes(rawKey)) return dflt
    return { key: rawKey as K, dir: rawDir === 'asc' ? 'asc' : rawDir === 'desc' ? 'desc' : dflt.dir }
}

/** 一个 PostgREST 查询能做的那一件事:`.order(col, { ascending, nullsFirst })`。 */
interface OrderChain {
    order(column: string, options: { ascending: boolean; nullsFirst?: boolean }): OrderChain
}

/**
 * 按选中的列排,再按平局键排。`columns` 是 列键 → 关系上的列名(规矩 ①②)。
 * 空值一律排在最后(与浏览器里排序同一条:一个空格子不是"最小的数")。
 * `tiebreak` 里与选中列相同的那一项会跳过(不重复排同一列)。
 */
export function applyListSort<T, K extends string>(
    query: T,
    sort: ListSort<K>,
    columns: Readonly<Record<K, string>>,
    tiebreak: ReadonlyArray<readonly [string, SortDir]>,
): T {
    let chain = query as unknown as OrderChain
    const col = columns[sort.key]
    chain = chain.order(col, { ascending: sort.dir === 'asc', nullsFirst: false })
    for (const [c, d] of tiebreak) {
        if (c === col) continue
        chain = chain.order(c, { ascending: d === 'asc', nullsFirst: false })
    }
    return chain as unknown as T
}

/** 把排序写进一条地址(导出路由的地址、翻页链接)。与默认相同也照写 —— 地址说得清自己是什么顺序。 */
export function setSortParams(params: URLSearchParams, sort: ListSort, prefix = ''): URLSearchParams {
    params.set(`${prefix}sort`, sort.key)
    params.set(`${prefix}dir`, sort.dir)
    return params
}

/**
 * TABLE-FEATURES-3(Tim 2026-10-26 Q1):一张【浏览器里排】的表,从地址里读它自己那一对 `<prefix>sort` / `<prefix>dir`。
 * 交给 DataTable 的 `sorting.url.initial`;键对不对由 DataTable 对着自己的列判(这里不知道有哪些列)。没有、或 dir 不是 asc/desc → null(不排)。
 */
export function parseClientSort(
    sp: Record<string, string | string[] | undefined>,
    prefix = '',
): ListSort | null {
    const one = (v: string | string[] | undefined) => (Array.isArray(v) ? v[0] : v)
    const key = one(sp[`${prefix}sort`])
    const dir = one(sp[`${prefix}dir`])
    if (!key || (dir !== 'asc' && dir !== 'desc')) return null
    return { key, dir }
}

/** 同一件事的浏览器那一侧:表组件用 useSearchParams() 读,交给 DataTable 的 `sorting.url`(服务端首屏读到的也是同一个地址)。 */
export function clientSortUrl(sp: { get(key: string): string | null }, prefix = ''): { prefix: string; initial: ListSort | null } {
    const key = sp.get(`${prefix}sort`)
    const dir = sp.get(`${prefix}dir`)
    return { prefix, initial: key && (dir === 'asc' || dir === 'desc') ? { key, dir } : null }
}
