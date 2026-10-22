import 'server-only'

// ════════════════════════════════════════════════════════════════════════════
// TABLE-EXPORT-1(2026-10-22)· 服务端翻页取全 —— 【永远不悄悄停在 1,000 行】
// ════════════════════════════════════════════════════════════════════════════
// 实测(TABLE-EXPORT-1 Step 0,2026-10-22,Management API /postgrest 只读出 max_rows 一个字段):
//   线上 PostgREST `max_rows = 1000`。一条不翻页的查询拿到第 1,000 行就停,**不报错、不提示**。
//   Step 0 时 14 条导出路由一条都不翻页 —— 每一条都会在 1,000 行处悄悄截断。
//
// Tim 2026-10-22 的裁定(docs/table-export.md):
//   Q8  统一导出:服务端按 1,000 一批取,上限 50,000 行;超过就拒绝,说出匹配了多少行,请人收窄筛选。
//       【绝不悄悄截断】。
//   Q15 五条保留的专用导出(GST F5 · 总账 · 应收账龄 · 应付账龄 · 管理包)也要翻页取全。
//
// ★ 停止条件是【拿到 0 行】,不是【拿到的不满一批】。
//   后者在 max_rows 被调小(比如 500)的那一天会在第一批之后就停 —— 又是一次悄悄的截断,
//   而且是被一个本来为了防截断写的循环造出来的。前者对任何 max_rows 都成立,代价是多一次空请求。
// ★ 调用方必须按一个【唯一】的键排序(AGENTS.md「取最新那一行要先问:这张表排得出先后吗」):
//   按一个有并列的列翻页,同一行可能出现两次、另一行一次都不出现。
// ════════════════════════════════════════════════════════════════════════════

export const EXPORT_BATCH = 1000
export const EXPORT_CAP = 50_000

type PageResult<R> = { data: R[] | null; error: { message: string } | null }

/**
 * 把一条查询翻页取全。`page(from, to)` 必须返回同一条查询的 `.range(from, to)`。
 * 出错就抛(一次失败不是一个空集);`cap` 给了,超过就抛 EXPORT_TOO_MANY_ROWS。
 */
export async function fetchAllPages<R>(
    page: (from: number, to: number) => PromiseLike<PageResult<R>>,
    label: string,
    cap: number = Number.POSITIVE_INFINITY,
): Promise<R[]> {
    const out: R[] = []
    for (;;) {
        const from = out.length
        const { data, error } = await page(from, from + EXPORT_BATCH - 1)
        if (error) throw new Error(`EXPORT_READ_FAILED|${label}|${error.message}`)
        if (!data) throw new Error(`EXPORT_READ_FAILED|${label}|no data and no error`)
        const got = data
        if (got.length === 0) return out
        out.push(...got)
        if (out.length > cap) throw new Error(`EXPORT_TOO_MANY_ROWS|${label}|>${cap}`)
    }
}

/**
 * 统一导出的服务端那一半:页面自己的读取,翻页取全,原样以 JSON 交回给表,由表按它自己的
 * exportAs 写成 xlsx / csv。**这里不重写任何一列** —— 列只有表上那一份定义。
 *
 *   `count` —— 与页面同一条筛选的 `count: 'exact', head: true`。先数,超过上限就不取(Q8)。
 *   `page`  —— 与页面同一条查询(同一个 select、同一套筛选、同一个排序 + 唯一键),外加 .range。
 *   `shape` —— 与页面同一个「库里的行 → 表的行」映射(可异步:有的页还要按 id 补一张表)。
 */
export async function exportRowsResponse<D, R>(o: {
    label: string
    count: () => Promise<number>
    page: (from: number, to: number) => PromiseLike<PageResult<D>>
    shape: (rows: D[]) => R[] | Promise<R[]>
}): Promise<Response> {
    const n = await o.count()
    if (n > EXPORT_CAP) {
        return Response.json({ code: 'EXPORT_TOO_MANY_ROWS', count: n, cap: EXPORT_CAP }, { status: 413 })
    }
    const raw = await fetchAllPages(o.page, o.label, EXPORT_CAP)
    return Response.json({ rows: await o.shape(raw) })
}

/** 守卫拒绝时的回答 —— 与页面同一个判据(canEnter),只是说成 JSON。 */
export function exportDenied(): Response {
    return Response.json({ code: 'EXPORT_DENIED' }, { status: 403 })
}
