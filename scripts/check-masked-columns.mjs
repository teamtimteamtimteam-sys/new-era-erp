#!/usr/bin/env node
// scripts/check-masked-columns.mjs
//
// ════════════════════════════════════════════════════════════════════════════
// 【它回答一个问题,而且只回答那一个】
//     **仓库里每一张【被遮蔽的表】,有哪一列既不在它的 _masked 视图里、
//       也不在它的列级授权清单里?**
//
// 也就是说:它问的是【仓库这一份副本】自洽不自洽 —— 不问线上,不连数据库。
//
// ────────────────────────────────────────────────────────────────────────────
// 【与另外两个同族判词的分工 —— 三个名字必须分得开,CHECK-1 特意点名】
//
//   ① db/gate.py 的 **colgrant**(GRANT_GAP_SQL)
//        问【线上目录】与【本地重建】:列授权与 _masked 视图对不对得上。
//        它一直是对的,而且从来没有瞎过 —— CHECK-1 实测确认:三次(实为四次)
//        「遮蔽表加列漏了伴生」它每一次都会红。它的问题只有一个:**红得太晚** ——
//        gate 是收尾的门,那时 DDL 已经在线上了。
//
//   ② db/preflight_migration.py 的 **masked**(CHECK-1 新增)
//        问【这一支还没执行的迁移】:它 ADD 的列有没有在同一支里进 _masked。
//        判据与 ① 逐字相同,只是把钟拨早到 DDL 落地【之前】,并且【拒绝】。
//        它买回的正是那三次(四次)事故本身。
//
//   ③ 本文件 **masked-columns**(CHECK-1 新增)
//        问【仓库里的 db/tables 与 db/views】。它看的是 ① 和 ② 都看不见的那一半:
//        **一次改动落到了线上、却没有写回仓库的镜像文件**。那时线上是对的、
//        迁移也是对的,而【重建出来的库】少一列在视图里 —— 全新安装从第一天起
//        就带着这个缺陷,而没有任何人在看重建。
//        (gate 的 colgrant 确实也问重建那一侧,但那要先起一个本地 postgres 集群
//         并重放整个仓库,几分钟起步;本文件是纯文本,进 `npm run build`,秒级。)
//
//   一句话:**① 线上,晚;② 迁移,早,拒;③ 仓库,快。** 谁也不能当成谁。
//
// ────────────────────────────────────────────────────────────────────────────
// 【判据 —— 与 gate 的 colgrant 逐字相同,一个字都不加严】
//     (granted OR in_view) AND (has_view → in_view)
// 起点是"哪些表被遮蔽",由建表文件里的 `REVOKE SELECT ON <表> FROM authenticated` 说了算。
// 于是判据分成两支,而【两支都是同一条式子】:
//   * 有 <表>_masked 伴生(24 张)→ has_view 真 → 收敛成 **每一列都必须在视图里**;
//   * 没有伴生、只用列清单(3 张:approval_log / notifications / po_issues)
//                                → in_view 恒假 → 收敛成 **每一列都必须在 GRANT 里**。
// 第二支不是加严,是同一条式子的另一半 —— 漏掉它就会漏掉那三张表。
//
// ★【授权缺失【不是】缺陷 —— 这一条要写死在这里,免得有人"顺手加严"】★
//   CHECK-1 的委托书原本要求"列不在列级授权里就失败"。**那会把每一列刻意遮蔽的
//   价格列都判红** —— 一列价格【本来就该是没授权的】,它靠视图里的
//   has_permission CASE 呈现。授权与否是【第二个问题】:
//       授了 = 原样透出   ·   没授 = 视图里用 CASE 遮住
//   两者都合规。不合规的只有一种:**这一列压根不在视图里。**
//
//   而且更要紧的是:一支比 gate 更严的检查,会拦下 gate 本来会放行的东西 ——
//   于是人学到的不是"写对",是"绕过这道检查"。**一个被人关掉的检查比没有检查更坏。**
//
// ────────────────────────────────────────────────────────────────────────────
// 【它看得见什么】
//   ✓ db/tables/*.sql 里每一张【收回了表级 SELECT】的表 —— 起点在这一侧,
//     所以【删掉一张视图文件】会变红,而不是安静地少比一张表(第一版就是这么绿的)
//   ✓ db/tables/<表>.sql 里 CREATE TABLE 的列,以及同文件里 ALTER TABLE ADD COLUMN 的列
//   ✓ 视图文件的【顶层 SELECT 列表】—— 按顶层逗号切,不按行切
//   ✓ 建表文件里的 GRANT SELECT (…) 列清单(没有伴生视图的那一族)
//
// 【它看不见什么 —— 点名,不含糊】
//   ✗ **线上**。仓库两份文件彼此自洽,不代表它们等于线上 —— 那是 gate 的活(①)。
//     本检查绿,只说明【重建出来的库】在这一条上自洽。
//   ✗ **列该不该遮**。它不判断一列是不是敏感数据;它只问"在不在视图里"。
//     一列薪水原样透出、没有 CASE 包住,本检查【看不见】,gate 也看不见。
//   ✗ **视图里那个 CASE 用对了哪个权限**。has_permission('data.view_prices') 写成
//     另一个权限码,本检查一样是绿的。
//   ✗ **db/tables 里没写的列**。若一列既没进 db/tables 也没进视图,两边都没有它,
//     本检查判它一致 —— 那是"仓库整体落后于线上",归 gate 的 types / colgrant 管。
//   ✗ 动态 DDL、被注释掉的列定义(整行 -- 注释已剥掉)。
// ════════════════════════════════════════════════════════════════════════════
import { readFileSync, readdirSync, existsSync } from 'node:fs'
import { join } from 'node:path'

const ROOT = process.cwd()
const TABLES_DIR = join(ROOT, 'db/tables')
const VIEWS_DIR = join(ROOT, 'db/views')

// 整行 `--` 注释剥掉:注释里提一句列名不是一次定义
// (与 preflight_migration.py 的 noncomment() 同一条规矩)。
const noncomment = (sql) =>
    sql.split('\n').filter((l) => !l.trimStart().startsWith('--')).join('\n')

// ── 顶层逗号切分:括号内的逗号不算,字符串字面量整段跳过 ─────────────────────
function splitTopLevel(body) {
    const out = []
    let depth = 0, cur = '', i = 0
    while (i < body.length) {
        const ch = body[i]
        if (ch === "'") {
            cur += ch; i++
            while (i < body.length && body[i] !== "'") { cur += body[i]; i++ }
            if (i < body.length) { cur += body[i]; i++ }
            continue
        }
        if (ch === '(') depth++
        else if (ch === ')') depth--
        else if (ch === ',' && depth === 0) { out.push(cur); cur = ''; i++; continue }
        cur += ch; i++
    }
    out.push(cur)
    return out
}

// 取 `CREATE TABLE public.<t> (` 之后配平的那一段
function balancedBody(sql, startIdx) {
    let depth = 0, i = startIdx
    for (; i < sql.length; i++) {
        if (sql[i] === '(') { depth++; if (depth === 1) { startIdx = i + 1 } }
        else if (sql[i] === ')') { depth--; if (depth === 0) return sql.slice(startIdx, i) }
    }
    return null
}

// 表约束不是列 —— 这些开头的项跳过
const CONSTRAINT_HEAD = /^(CONSTRAINT|PRIMARY|UNIQUE|FOREIGN|CHECK|EXCLUDE|LIKE)\b/i

function tableColumns(sql) {
    const cols = []
    const m = /CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(?:public\s*\.\s*)?[a-zA-Z_][\w$]*\s*\(/i.exec(sql)
    if (m) {
        const body = balancedBody(sql, m.index)
        if (body) {
            for (const item of splitTopLevel(body)) {
                const t = item.trim()
                if (!t || CONSTRAINT_HEAD.test(t)) continue
                const c = /^([a-zA-Z_][\w$]*)/.exec(t)
                if (c) cols.push(c[1].toLowerCase())
            }
        }
    }
    // 同一个文件里后续 ALTER TABLE ... ADD COLUMN 的列(镜像文件常这么追加)
    for (const a of sql.matchAll(
        /\bALTER\s+TABLE\s+(?:ONLY\s+)?(?:public\s*\.\s*)?[a-zA-Z_][\w$]*([^;]*);/gi)) {
        for (const c of a[1].matchAll(/\bADD\s+COLUMN\s+(?:IF\s+NOT\s+EXISTS\s+)?([a-zA-Z_][\w$]*)/gi)) {
            cols.push(c[1].toLowerCase())
        }
    }
    return [...new Set(cols)]
}

// 视图的【输出列】—— 与 db/preflight_migration.py:_view_output_columns 同一套判据
function viewOutputColumns(sql) {
    const m = /\bSELECT\b/i.exec(sql)
    if (!m) return new Set()
    const rest = sql.slice(m.index + m[0].length)
    // 顶层 FROM 截断
    let depth = 0, end = rest.length
    for (let i = 0; i < rest.length; i++) {
        const ch = rest[i]
        if (ch === "'") { i++; while (i < rest.length && rest[i] !== "'") i++; continue }
        if (ch === '(') depth++
        else if (ch === ')') depth--
        else if (depth === 0 && /^FROM\b/i.test(rest.slice(i, i + 5))
            && !/[\w$]/.test(rest[i - 1] ?? ' ')) { end = i; break }
    }
    const cols = new Set()
    for (let item of splitTopLevel(rest.slice(0, end))) {
        item = item.trim()
        if (!item) continue
        const alias = /\bAS\s+([a-zA-Z_][\w$]*)\s*$/is.exec(item)
        if (alias) { cols.add(alias[1].toLowerCase()); continue }
        const idents = item.match(/[a-zA-Z_][\w$]*/g)
        if (idents) cols.add(idents[idents.length - 1].toLowerCase())
    }
    return cols
}

// 列级授权清单:GRANT SELECT (a, b, c) ON public.<t> —— 可能有多条,取并集
function grantedColumns(sql) {
    const cols = new Set()
    for (const m of sql.matchAll(/\bGRANT\s+SELECT\s*\(([^)]*)\)/gi)) {
        for (const c of m[1].split(',')) {
            const t = c.trim().toLowerCase()
            if (t) cols.add(t)
        }
    }
    return cols
}

// 这张表【被遮蔽】吗:表级 SELECT 被收回,就是"它有列不给 authenticated 直读"的意思。
// 与 check-masked-reads / gen-masked-tables 的判据同源 —— 只是那两个问的是线上生成的
// 类型,本文件问的是仓库里的建表文件(不连数据库,这是它存在的理由)。
const REVOKE_RE = /\bREVOKE\s+SELECT\s+ON\s+(?:TABLE\s+)?(?:public\s*\.\s*)?([a-zA-Z_][\w$]*)\s+FROM\b/i

// ── 走一遍 ───────────────────────────────────────────────────────────────────
const problems = []
let nViewTables = 0, nGrantTables = 0, nCols = 0, nSkipped = 0

// 【从 db/tables 这一侧走,不从 db/views 走】——【CHECK-1 的红/绿演示逼出来的】
// 第一版遍历 db/views/*_masked.sql:把一张视图文件【删掉】,这个检查只是少比一张表,
// 然后照样报"✓ 一致"。**那正是它要消灭的那种绿。** 判据的起点必须是"哪些表被遮蔽"
// (建表文件里的 REVOKE 说了算),而不是"有哪些视图文件在"。
const tableFiles = readdirSync(TABLES_DIR).filter((f) => /\.sql$/.test(f)).sort()
const maskedTables = []
for (const f of tableFiles) {
    const sql = noncomment(readFileSync(join(TABLES_DIR, f), 'utf8'))
    if (REVOKE_RE.test(sql)) maskedTables.push({ table: f.replace(/\.sql$/, ''), sql })
}

// 【解析出 0 张不是"没有遮蔽表"】—— 零必须是测量,不是缺席。
if (maskedTables.length === 0) {
    console.error('✗ check-masked-columns:db/tables/ 里一张带 REVOKE SELECT 的表都没找到。')
    console.error('  找不到【不是】没有遮蔽表。先确认目录与写法没变。')
    process.exit(2)
}

for (const { table, sql: tableSql } of maskedTables) {
    const cols = tableColumns(tableSql)
    if (cols.length === 0) {
        nSkipped++
        problems.push({ table, msg: `db/tables/${table}.sql 解析出 0 列 —— 解析器坏了,不是这张表没有列。` })
        continue
    }

    const vf = `${table}_masked.sql`
    const hasView = existsSync(join(VIEWS_DIR, vf))

    if (hasView) {
        // has_view → in_view:每一列都必须在伴生视图里(授权与否是第二个问题)
        const inView = viewOutputColumns(noncomment(readFileSync(join(VIEWS_DIR, vf), 'utf8')))
        if (inView.size === 0) {
            nSkipped++
            problems.push({ table, msg: `db/views/${vf} 解析出 0 个输出列 —— 解析器坏了,不是这张视图没有列。` })
            continue
        }
        nViewTables++
        nCols += cols.length
        const missing = cols.filter((c) => !inView.has(c))
        if (missing.length) {
            problems.push({ table,
                msg: `${table}:${missing.join(', ')} 在 db/tables/${table}.sql 里,`
                    + `却不在 db/views/${vf} 的输出列里。` })
        }
    } else {
        // 没有伴生视图 → 判据收敛成 granted:每一列都必须在列级授权清单里。
        // 【这不是加严,是同一条判据的另一支】(granted OR in_view),此处 in_view 恒假。
        // approval_log / notifications / po_issues 就是这一族:只用列清单遮蔽,没有视图。
        const granted = grantedColumns(tableSql)
        if (granted.size === 0) {
            nSkipped++
            problems.push({ table,
                msg: `db/tables/${table}.sql 收回了表级 SELECT,却解析不出任何 GRANT SELECT (…) 列清单 ——`
                    + ` 也没有 db/views/${vf}。这张表的每一列对 authenticated 都读不到。` })
            continue
        }
        nGrantTables++
        nCols += cols.length
        const missing = cols.filter((c) => !granted.has(c))
        if (missing.length) {
            problems.push({ table,
                msg: `${table}:${missing.join(', ')} 在 db/tables/${table}.sql 里,`
                    + `却既不在列级授权清单里,也没有 db/views/${vf} 可以呈现它们。` })
        }
    }
}

console.log('== 遮蔽表的列:仓库镜像自洽性(db/tables ↔ db/views)==')
console.log('   判词:**一张被遮蔽的表,它的每一列都必须【呈现得出来】** ——')
console.log('         有 _masked 伴生的,每列都要在视图里;只用列清单的,每列都要在 GRANT 里。')
console.log('   它【不】问线上(那是 db/gate.py 的 colgrant),也【不】问某一支迁移')
console.log('   (那是 db/preflight_migration.py 的 masked)。三者的分工见本文件抬头。')
console.log(`   比对了 ${nViewTables + nGrantTables} 张遮蔽表 / ${nCols} 列`
    + ` —— ${nViewTables} 张有 _masked 伴生(判据:每列都在视图里),`
    + `${nGrantTables} 张只用列清单(判据:每列都在 GRANT 里)`
    + (nSkipped ? `,${nSkipped} 张比不了(见下)` : ''))

if (problems.length === 0) {
    console.log('✓ 仓库镜像里没有【加了列却没让它呈现出来】的遮蔽表。')
    process.exit(0)
}

console.log('')
console.log('✗ 仓库镜像不自洽:')
for (const p of problems) console.log(`     ${p.msg}`)
console.log('')
console.log('【为什么它非红不可】重建出来的库会照着 db/views/ 建那张视图。少一列,')
console.log('全新安装从第一天起就是:那一列写得进、【每一个登录用户都读不出】,')
console.log('而屏幕上它长得和「未填写」一模一样 —— 一个字的报错都不会有。')
console.log('这正是 2026-08-30/31 三天里【四次】重演的那个形状')
console.log('(CMPL-1 fu2 · PROC-WIRE-1B-i fu1 · PROC-1B-iii fu1,以及本条抓到的那一次)。')
console.log('')
console.log('【怎么改】有伴生视图的,把缺的列补进 db/views/<表>_masked.sql;')
console.log('没有伴生视图的(只用列清单遮蔽),把它加进 db/tables/<表>.sql 的 GRANT SELECT (…)。')
console.log('前一种的两条路:')
console.log('  · 不敏感 → 原样列出,并确认 db/tables/<表>.sql 的 GRANT SELECT (…) 里也有它;')
console.log('  · 敏感   → CASE WHEN has_permission(\'<权限码>\') THEN <列> ELSE NULL END AS <列>,')
console.log('             这一列【不】进 GRANT —— 没授权是它的正常状态。')
process.exit(1)
