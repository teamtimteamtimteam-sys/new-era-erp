#!/usr/bin/env node
// scripts/check-search-registry.mjs
// ════════════════════════════════════════════════════════════════════════════
// SEARCH-2b · document_types 里那些【声明】,由这里核对
// ════════════════════════════════════════════════════════════════════════════
//
// 【为什么是声明 + 闸,而不是推导】round 6 实测过推导这条路:一支按"谁查这张表"
// 推导 route 的脚本,31 张里【至少 8 张错】(employees → /operation/processing/[id]、
// purchase_orders → /finance/payments/[id]……)—— 它找到的是 JOIN 到这张表的页面,
// 不是【关于】这张表的页面。SEARCH-0 早就量过:今天没有机读的"本页主语"。
// ☞ 所以 route / link_mode 由人声明,由这支脚本核对。
//   而声明会错 —— 本刀开工当天它就错了一处,由本判据的前身当场抓到:
//   **shipment 的 route 写作 `/sales/shipments`,而那条路径在导航注册表里没有条目**
//   (它只有 `[id]/page.tsx`,没有列表页)。那一处不是笔误,是 link_mode='detail'
//   的正确形状 —— 于是判据本身被改对了:**detail 型看 `[id]/page.tsx`,
//   不看注册表**。一条抓到了真东西、然后把自己改对了的判据,比一条从没红过的可信。
//
// 三条判据:
//   ① route 指向的页面【真的存在】——
//        link_mode='detail'          → app/<route>/[id]/page.tsx
//        link_mode='list' | 'list_q' → app/<route>/page.tsx
//   ② link_mode='list_q' 的那些,列表页【真的读 q】——
//        否则 `?q=<code>` 是一个看起来像落点、实际什么都不做的地址。
//   ③ 覆盖率本身是一条断言:读到的行数必须是 40。
//      **一个瞎掉的解析器和一份干净的登记表都打印 EXIT 0**,所以它必须先说出
//      自己看了多少行,数出 0(或者不是 40)就是失败,不是"没发现问题"。
//
// 【读的是镜像,不是线上】db/tables/document_types.sql 是仓库这一侧的真相,
// 而"镜像与线上一致"由 db/check_mirrors.py 的 SEED_TABLES 逐行比对负责。
// 两支各管一半,谁都不冒充对方。
// ════════════════════════════════════════════════════════════════════════════
// 【瞄准 · AIM】
//   我读的是      :`db/tables/document_types.sql` 里那段种子 INSERT 的**文本**,
//                   逐行用一条正则拆出 (key, prefix, table, numbering, route, link_mode);
//                   以及 `app/` 下**文件系统上**是否存在对应的 `page.tsx` / `[id]/page.tsx`。
//   我声称管的是   :**线上 `document_types` 那 40 行的 route / link_mode 声明是不是真的**。
//   两者不同之处   :★ 我读的是【镜像】,不是线上。两者一致由
//                   `db/check_mirrors.py` 的 SEED_TABLES 逐行比对负责 —— 它在,
//                   所以这条差别今天是被人看着的;**它若被摘掉,我就会对着一份
//                   过期的登记表报绿,而我自己看不出来。**
//                   ☞ 第二处:我只问页面【文件在不在】,不问它渲染得出来 ——
//                   那是 `scripts/smoke-routes.mjs` 的活,不是我的。
// ════════════════════════════════════════════════════════════════════════════
import { readFileSync, existsSync } from 'node:fs'
import { join } from 'node:path'

const ROOT = new URL('..', import.meta.url).pathname
const MIRROR = join(ROOT, 'db/tables/document_types.sql')
const EXPECTED_ROWS = 40

const sql = readFileSync(MIRROR, 'utf8')
const insertAt = sql.indexOf('INSERT INTO public.document_types')
if (insertAt < 0) {
    console.error(`✗ ${MIRROR} 里找不到种子 INSERT —— 判据瞎了,不是登记表干净了`)
    process.exit(1)
}

// 一行一条:('key', 'PFX', 'table', 'numbering', seq, 'route', 'link_mode', label, cols)
const rows = []
for (const line of sql.slice(insertAt).split('\n')) {
    const m = line.match(/^\s*\('([^']+)',\s*'([^']+)',\s*'([^']+)',\s*'([^']+)',\s*(NULL|'[^']*'),\s*'([^']+)',\s*'([^']+)'/)
    if (m) rows.push({ key: m[1], prefix: m[2], table: m[3], numbering: m[4], route: m[6], linkMode: m[7] })
}

const problems = []

// ── 覆盖断言 ① —— 先跑,因为覆盖率是断言,不是前提 ─────────────────────────
// 【为什么这一段在最前面】一个瞎掉的解析器和一份干净的登记表**都打印 EXIT 0**。
// 所以先说出"我这次到底看了多少行",数出 0(或者不是 40)就是失败。
if (rows.length !== EXPECTED_ROWS) {
    problems.push(`覆盖断言 ①:解析出 ${rows.length} 行,期待 ${EXPECTED_ROWS} —— `
        + `判据瞎了(或者登记表真的变了,那就同时改这个数与切次报告)`)
}

// ── 覆盖断言 ② —— 两条【独立的路】各数一遍,不一致就是失败 ────────────────
// 上面那条正则拆的是整行;这一条只数 `('key',` 的出现次数。两条都瞎、而且
// 瞎得一模一样的可能性,比一条瞎掉小得多 —— NARROW-COVERAGE-1 的做法。
const keyLines = (sql.slice(insertAt).match(/^\s*\('[a-z_]+',/gm) ?? []).length
if (keyLines !== rows.length) {
    problems.push(`覆盖断言 ②:两条路数出来不一样多(整行正则 ${rows.length} · `
        + `只数 key ${keyLines})—— 至少有一条在漏读`)
}

for (const r of rows) {
    // ── 判据 ① route 指向的页面真的存在 ─────────────────────────────────────
    const dir = join(ROOT, 'app', r.route.replace(/^\//, ''))
    const detailPage = join(dir, '[id]', 'page.tsx')
    const listPage = join(dir, 'page.tsx')
    if (r.linkMode === 'detail') {
        if (!existsSync(detailPage)) {
            problems.push(`${r.key}: link_mode='detail' 但 app${r.route}/[id]/page.tsx 不存在`)
        }
    } else {
        if (!existsSync(listPage)) {
            problems.push(`${r.key}: link_mode='${r.linkMode}' 但 app${r.route}/page.tsx 不存在`)
        }
        // ── 判据 ② list_q 的列表页必须真的读 q ──────────────────────────────
        if (r.linkMode === 'list_q' && existsSync(listPage)) {
            const page = readFileSync(listPage, 'utf8')
            // searchParams 里的 q:两种写法都认(解构 / 点取),但必须【出现】。
            const readsQ = /\bq\b\s*[,}:]/.test(page) || /searchParams[^\n]*\bq\b/.test(page)
                || /\['q'\]|\.q\b/.test(page)
            if (!readsQ) {
                problems.push(`${r.key}: link_mode='list_q',但 app${r.route}/page.tsx 里看不出它读 q`
                    + ` —— 那样 ?q=<code> 是一个看起来像落点、实际什么都不做的地址`)
            }
        }
    }
}

const byMode = rows.reduce((a, r) => ((a[r.linkMode] = (a[r.linkMode] ?? 0) + 1), a), {})
console.log(`search registry: 覆盖断言 两条路各读到 ${rows.length}/${keyLines} 行 · detail ${byMode.detail ?? 0}`
    + ` · list ${byMode.list ?? 0} · list_q ${byMode.list_q ?? 0}`)

if (problems.length > 0) {
    console.error(`✗ ${problems.length} 处:`)
    for (const p of problems) console.error(`  ${p}`)
    process.exit(1)
}
console.log('✓ 每一条 route 都落在一个真的页面上;每一个 list_q 的列表页都读 q')
