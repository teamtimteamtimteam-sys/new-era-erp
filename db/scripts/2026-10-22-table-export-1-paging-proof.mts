// ════════════════════════════════════════════════════════════════════════════
// TABLE-EXPORT-1(Tim 2026-10-22 Q8 · Q15)· 翻页取全的证明 —— 对着一个「每次最多回 N 行」的桩
// ════════════════════════════════════════════════════════════════════════════
// 为什么是桩:那个 1,000 行的闸门是 PostgREST 的(线上 max_rows = 1000,实测),而本机没有 PostgREST、
// 也没有 docker;线上又不许为证明提交 1,000 行以上的单据(LIVE SAFETY)。所以这里证的是【翻页代码】:
//   P1  2,500 行、max_rows 1000:fetchAllPages 拿回 2,500,一行不重、一行不漏;一次不翻页的读只有 1,000(两臂分得开)
//   P2  同样的 2,500 行、max_rows 被调成 500:仍然 2,500 —— 停止条件是「拿到 0 行」,不是「不满一批」
//   P3  上限:50,001 行 → exportRowsResponse 回 413 + EXPORT_TOO_MANY_ROWS + 准确的行数,一行都不取;50,000 行 → 200 全取
//   P4  出错就抛,不当成空集
//   P5  五条专用导出的路由【静态】:行源的那两条调 fetchAllPages,值源的那三条不调(它们的形状由 fixture 291 钉住)
// 判决:最后一行 `PAGING_PROOF_EXIT=`(0 = 全过)。
// 用法:npx tsx --conditions=react-server db/scripts/2026-10-22-table-export-1-paging-proof.mts
// ════════════════════════════════════════════════════════════════════════════
import { readFileSync } from 'node:fs'
import { fetchAllPages, exportRowsResponse, EXPORT_CAP } from '../../lib/export/serverRows'

let bad = 0
const ok = (cond: boolean, what: string) => { console.log(`${cond ? 'PASS' : 'FAIL'}|${what}`); if (!cond) bad++ }

/** 一个像 PostgREST 一样的桩:range 照给,但一次最多回 maxRows 行。 */
function capped(total: number, maxRows: number) {
    const rows = Array.from({ length: total }, (_, i) => ({ id: i }))
    let calls = 0
    const page = async (from: number, to: number) => {
        calls++
        const want = Math.min(to - from + 1, maxRows)
        return { data: rows.slice(from, from + want), error: null }
    }
    return { page, calls: () => calls }
}

async function main() {
    // P1
    const s1 = capped(2500, 1000)
    const all = await fetchAllPages(s1.page, 'p1')
    const naive = (await s1.page(0, 2499)).data
    ok(all.length === 2500 && new Set(all.map((r) => r.id)).size === 2500 && all.every((r, i) => r.id === i),
       `P1: 2,500 rows behind max_rows 1000 → fetchAllPages returned ${all.length}, all distinct and in order (${s1.calls()} requests)`)
    ok(naive.length === 1000, `P1: one un-paged read of the same source returns ${naive.length} (the silent cut the paging removes)`)

    // P2
    const s2 = capped(2500, 500)
    const all2 = await fetchAllPages(s2.page, 'p2')
    ok(all2.length === 2500, `P2: max_rows lowered to 500 → still ${all2.length} rows (stop condition is an empty page, not a short one)`)

    // P3
    const s3 = capped(EXPORT_CAP + 1, 1000)
    const over = await exportRowsResponse({ label: 'p3', count: async () => EXPORT_CAP + 1, page: s3.page, shape: (r) => r })
    const overBody = await over.json()
    ok(over.status === 413 && overBody.code === 'EXPORT_TOO_MANY_ROWS' && overBody.count === EXPORT_CAP + 1 && s3.calls() === 0,
       `P3: ${EXPORT_CAP + 1} matching rows → HTTP ${over.status} ${overBody.code}, count ${overBody.count}, rows fetched: ${s3.calls()} requests`)
    const s3b = capped(EXPORT_CAP, 1000)
    const at = await exportRowsResponse({ label: 'p3b', count: async () => EXPORT_CAP, page: s3b.page, shape: (r) => r })
    const atBody = await at.json()
    ok(at.status === 200 && atBody.rows.length === EXPORT_CAP, `P3: exactly ${EXPORT_CAP} → HTTP ${at.status}, ${atBody.rows.length} rows`)

    // P4
    let threw = ''
    try { await fetchAllPages(async () => ({ data: null, error: { message: 'permission denied' } }), 'p4') }
    catch (e) { threw = (e as Error).message }
    ok(threw.startsWith('EXPORT_READ_FAILED|p4|'), `P4: a failed read throws (${threw || 'did not throw'}), never an empty set`)

    // P5
    const src = (p: string) => readFileSync(p, 'utf8')
    const paged = ['app/finance/journal/export/route.ts', 'app/finance/gst/[periodId]/export/route.ts']
    for (const p of paged) ok(/fetchAllPages\(/.test(src(p)), `P5: ${p} reads its row source through fetchAllPages`)
    const scalar: Array<[string, RegExp]> = [
        ['app/finance/receivables/export/route.ts', /readAging/],
        ['app/finance/payables/export/route.ts', /readAging/],
        ['app/finance/packs/[id]/export/route.ts', /\.single\(\)/],
    ]
    for (const [p, re] of scalar) ok(re.test(src(p)), `P5: ${p} reads a single value (shape pinned by fixture 291)`)
    ok(/rpc\(\s*\n?\s*side === 'ap' \? 'ap_aging_asof' : 'ar_aging_asof'/.test(src('app/finance/agingAsOf.ts')),
       'P5: readAging calls ar_aging_asof / ap_aging_asof (the jsonb functions fixture 291 pins)')
}

main().then(
    () => { console.log(`PAGING_PROOF_EXIT=${bad ? 1 : 0}`); process.exit(bad ? 1 : 0) },
    (e) => { console.error(e); console.log('PAGING_PROOF_EXIT=2'); process.exit(2) },
)
