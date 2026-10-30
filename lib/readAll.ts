// ════════════════════════════════════════════════════════════════════════════
// GOLIVE-2 第 10 行(Tim 2026-10-22 TABLE-EXPORT-2 Q3 · 2026-10-30 Q1)· 一次读取【不许悄悄停在第 1,000 行】
// ════════════════════════════════════════════════════════════════════════════
// 线上 PostgREST `max_rows = 1000`(TABLE-EXPORT-1 实测)。一条既不翻页也不封顶的读取拿到第 1,000 行就停,不报错 ——
//   屏幕上由它算出来的数(固定资产的累计折旧、每期工资的人数、加班批的合计、费用筛选的合计……)就悄悄偏小。
// Tim Q1:一律翻页读,一个共用的读法 —— 就是这一支。
//
//   readAll(() => <与原来一字不差的那条查询>, { label, key })
//   readAllIn(ids, (chunk) => <那条查询,.in(列, chunk)>, { label, key })
//
// 【返回的形状与原来 await 那条查询逐字相同】({ data, error, … }),所以 mustRows(…) / 解构 / Promise.all 原样不动 ——
//   换掉的只有"它最多给几行"。
// 【一页读得完(< 1,000 行)】只发一次请求,与原来同一个请求加一个 Range —— 今天线上每一张表都在这一支(GOLIVE-2 Step 0 量过,
//   最大的 journal_lines 226 行)。
// 【读满 1,000 行】从头按一个稳定的次序再读:原来的 .order(…) 在前,再按 key(默认 'id';没有 id 的关系由调用方给)破并列 ——
//   按一个有并列的次序翻页,同一行会出现两次、另一行一次都不出现(AGENTS.md「取最新那一行要先问」)。多花的只是被丢掉的第一页。
//   关系上没有那一列 → PostgREST 当场报错 → mustRows 抛 —— 响亮,不是一个错数。
// 【超过 50,000 行】按名拒:error = READ_TOO_MANY_ROWS|<label>|… —— 与导出的上限同一个数(lib/export/serverRows.ts 的 EXPORT_CAP)。
// 【停在哪】一页不满 READ_PAGE 就停。★ 这依赖线上 max_rows ≥ READ_PAGE(今天 = 1000,实测)—— 有人把 max_rows 调小,
//   这一支会在第一页之后就停,又是一次悄悄的截断。导出路由(fetchAllPages)停在【拿到 0 行】,多一次空请求换这条依赖;
//   屏幕上的每一次读取都多一次往返太贵,所以这里取前者,并把依赖写在这里。
// 【.in(列, 很长的一组)】那一组是写进 URL 的,几百个 uuid 就会撞上地址长度 —— readAllIn 每 IN_CHUNK 个一批,逐批 readAll,
//   首尾相接。★ 分了批,原来那条查询的 .order(…) 只在【每一批之内】成立;一组不超过 IN_CHUNK 个时(今天的每一处)次序与原来逐字相同。
// 构建闸:scripts/check-unpaged-reads.mjs —— 一张会长的表上新写一条不翻页的读取,构建红。
// ════════════════════════════════════════════════════════════════════════════

export const READ_PAGE = 1000
export const READ_CAP = 50_000
export const IN_CHUNK = 100

type Resp = { data: unknown; error: unknown }
/** 一条 supabase-js 的读取:.range(…) 之后 await 得到 { data, error }(PostgrestFilterBuilder / PostgrestTransformBuilder 都是) */
type Pageable = PromiseLike<Resp> & { range(from: number, to: number): PromiseLike<Resp> }
type Opts = { label?: string; key?: string | readonly string[] }

function tooMany(label: string) {
    return {
        message: `READ_TOO_MANY_ROWS|${label}|more than ${READ_CAP} rows — narrow the filter`,
        code: 'READ_TOO_MANY_ROWS', details: '', hint: '',
    }
}

/** 以一个稳定的次序取第 from..to 行:原来的 .order(…) 在前,key 破并列。 */
function ordered(b: Pageable, keys: readonly string[], from: number): PromiseLike<Resp> {
    // supabase-js 的 .order 有好几个重载,结构类型写不全;这里只调它的第一种形状(列名 + { ascending })。
    let q = b as unknown as { order(col: string, o: { ascending: boolean }): unknown }
    for (const k of keys) q = q.order(k, { ascending: true }) as typeof q
    return (q as unknown as Pageable).range(from, from + READ_PAGE - 1)
}

export async function readAll<B extends Pageable>(build: () => B, opts: Opts = {}): Promise<Awaited<B>> {
    const label = opts.label ?? 'read'
    const first = (await build().range(0, READ_PAGE - 1)) as Awaited<B>
    const firstData = (first as Resp).data
    if ((first as Resp).error || !Array.isArray(firstData) || firstData.length < READ_PAGE) return first
    const keys = typeof opts.key === 'string' ? [opts.key] : (opts.key ?? ['id'])
    const out: unknown[] = []
    for (let from = 0; ; from += READ_PAGE) {
        const r = (await ordered(build(), keys, from)) as Awaited<B>
        const d = (r as Resp).data
        if ((r as Resp).error || !Array.isArray(d)) return r
        out.push(...d)
        if (out.length > READ_CAP) return { ...(r as object), data: null, error: tooMany(label) } as Awaited<B>
        if (d.length < READ_PAGE) return { ...(r as object), data: out } as Awaited<B>
    }
}

export async function readAllIn<I, B extends Pageable>(ids: readonly I[] | null | undefined,
                                                      build: (chunk: I[]) => B, opts: Opts = {}): Promise<Awaited<B>> {
    const uniq = [...new Set(ids ?? [])]
    if (uniq.length <= IN_CHUNK) return readAll(() => build(uniq), opts)
    const label = opts.label ?? 'read'
    const out: unknown[] = []
    let last: Awaited<B> | null = null
    for (let i = 0; i < uniq.length; i += IN_CHUNK) {
        const chunk = uniq.slice(i, i + IN_CHUNK)
        const r = await readAll(() => build(chunk), opts)
        const d = (r as Resp).data
        if ((r as Resp).error || !Array.isArray(d)) return r
        out.push(...d)
        if (out.length > READ_CAP) return { ...(r as object), data: null, error: tooMany(label) } as Awaited<B>
        last = r
    }
    return { ...(last as object), data: out } as Awaited<B>
}
