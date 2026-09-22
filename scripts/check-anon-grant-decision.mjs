#!/usr/bin/env node
// scripts/check-anon-grant-decision.mjs — 【一张新表必须对 anon 表态,不许沉默】
//
// ════════════════════════════════════════════════════════════════════════════
// 【它防的那个坑,两天之内被踩了两次,而两次的教训都写在【下一个建表的人不会读的地方】】
// ════════════════════════════════════════════════════════════════════════════
// 线上 public 架构有【两套】默认权限:
//     supabase_admin 建的表 → postgres + anon + authenticated + service_role
//     ★ postgres 建的表     → postgres + authenticated + service_role(**没有 anon**)
// 而 db/apply_migration.sh 是以 postgres 直连的,所以**迁移落下的新表本来就没有 anon**;
// 本地重建的 prelude 复刻的是【前一套】,于是重建出来的表**多了 anon** —— 镜像对不上。
//
// FA-HIST-1(2026-09-20)与 APR-1(2026-09-22)**两天之内各踩了一次**,
// 两次的处置逐字相同(取严的那一边:镜像里显式 REVOKE ALL ... FROM anon,
// 基线那一行**撤掉** —— 往一份「只许缩小」的基线里加一行,方向就反了)。
// ★ 而 APR-1 的交回报告自己写着:那两次的教训住在两份表镜像的注释里,
//   **那是一个「碰巧打开那个文件的人」才读得到的地方**,不是「下一个会撞上它的人」。
//   它同时照直记下「这一条没有闸,不假装写下来就等于解决了」。**这支脚本就是那道闸。**
//
// ════════════════════════════════════════════════════════════════════════════
// 【为什么现有的三样东西都看不见它 —— 逐个点名,免得有人把本脚本当重复退休掉】
// ════════════════════════════════════════════════════════════════════════════
//   · db/check_grants.py(gate 的判词六)断言的是**线上 ⊆ 基线,而基线只许缩小**。
//     这个坑的方向【正好相反】:线上少一条、重建多一条。线上仍然是基线的子集,
//     所以它全绿 —— 它管的是"anon 够得着的东西有没有变多",不是"镜像对不对"。
//   · db/check_mirrors.py 在它自己的【不比】清单里白纸黑字写着:**不比 GRANT**。
//     那句话是准确的,也正是这个缺口的由来。
//   · db/gate.py 的整门【会】在重建之后抓到它 —— 而那已经是**迁移之后**了,
//     也就是每一次都要多付一次破窗里的往返。**本脚本把同一个问题提到开跑前问**,
//     与 AGENTS.md「一条正确的检查放错了相位,就是一条慢检查」是同一条。
//
// ════════════════════════════════════════════════════════════════════════════
// 【判据:一张表必须【显式表过态】,两种表态都算】
// ════════════════════════════════════════════════════════════════════════════
//   ① 镜像里有一句【点名这张表】的 REVOKE ... FROM ... anon;或者
//   ② db/anon-grants-baseline.tsv 里有一行 `relation<TAB><表名>`。
// 两样都没有 = **没有人想过这件事**,而那正是两次事故的形状。
// ★ 它【不】规定该选哪一种 —— 那是一次业务判断(这张表该不该对互联网可见)。
//   它只拒绝【沉默】。一条比 gate 更严的判据会拒掉 gate 会放行的迁移,
//   而人会学会把它关掉(AGENTS.md:一个人会关掉的检查比没有检查更坏)。
//
// 【落地时是绿的 —— 这是它能这么严的全部理由】实测 2026-09-22:
//   222 张表 · 34 张带点名的 REVOKE · 216 张在基线里 · **0 张没表态**。
//   一支上线当天就红 222 行的检查,教给人的只有怎么跳过这道门。
//
// 退出码 0 = 每一张表都表过态;1 = 有表沉默;2 = 量具坏了。
// ════════════════════════════════════════════════════════════════════════════
import { readFileSync, readdirSync } from 'node:fs'
import { join } from 'node:path'
import { assertPopulation, assertPinned } from './lib/selfproof.mjs'

const SCRIPT = 'check-anon-grant-decision'
const ROOT = new URL('..', import.meta.url).pathname
const TABLES_DIR = join(ROOT, 'db', 'tables')
const BASELINE = join(ROOT, 'db', 'anon-grants-baseline.tsv')

//
// ==========================================================================
// 【瞄准 · AIM】
//   我读的是      :`db/tables/*.sql` 这些**镜像文件的文本**,加上
//                   `db/anon-grants-baseline.tsv` 的 relation 行。
//   我声称管的是   :**每一张迁移建出来的表,都对 anon 显式表过态。**
//   两者不同之处   :★ **我读的是镜像,不是线上,也不是迁移。**
//                   ① 一张【建在线上、镜像却没跟上】的表我完全看不见 ——
//                      那是 check_mirrors 的判词,不是我的;
//                   ② 我判的是"表过态",**不判那个态对不对** ——
//                      一张该对 anon 关着、却被写进基线的表,我会放行。
//                      那个判断是 db/check_grants.py 的事(线上 ⊆ 基线),
//                      而"该不该"本身是一次业务判断,没有机器答得了。
//                   ③ 我按【表】数,不按【文件】数:两份镜像各定义了两张表
//                      (freight_documents / kpi_position_templates),
//                      按文件数会漏掉后一张。
// ==========================================================================
//

// ── 解析:基线 ──────────────────────────────────────────────────────────
// 【读不到必须抛,绝不当成空基线】—— 一份读成空的基线会让每一张表都"没表态",
// 而那是一次响亮的误报;更坏的反面是:若判据写反了,空基线会让一切通过。
// db/check_grants.py 的两格常驻注入里有逐字同一条。
function readBaselineRelations(path) {
    const txt = readFileSync(path, 'utf8') // 抛,不 catch
    const out = new Set()
    for (const line of txt.split('\n')) {
        if (!line || line.startsWith('#')) continue
        const tab = line.indexOf('\t')
        if (tab < 0) continue
        if (line.slice(0, tab) !== 'relation') continue
        out.add(line.slice(tab + 1).trim())
    }
    return out
}

// ── 解析:表的总体,两条独立的路 ────────────────────────────────────────
// 路 A:行首的 CREATE TABLE(注释都以 `--` 开头,所以行锚天然避开它们)。
// 路 B:先剥掉注释,再在任何位置找。
// 两条会在【缩进的 CREATE TABLE】或【被注释掉的 CREATE TABLE】上分道扬镳 ——
// 那正是"有一种写法我没想到"的信号,所以它红,而不是静静地取其一。
const RE_A = /^CREATE TABLE (?:IF NOT EXISTS )?public\.([a-z0-9_]+)/gm
const RE_B = /CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?public\.([a-z0-9_]+)/g

function stripSqlComments(s) {
    return s.replace(/--[^\n]*/g, '').replace(/\/\*[\s\S]*?\*\//g, '')
}

function tablesInA(src) {
    return [...src.matchAll(RE_A)].map((m) => m[1])
}
function tablesInB(src) {
    return [...stripSqlComments(src).matchAll(RE_B)].map((m) => m[1])
}

// ── 解析:点名这张表的 REVOKE ... FROM ... anon ─────────────────────────
// 【为什么要点名】一份镜像可以定义两张表。一句不点名的 REVOKE 会被读成
// "这个文件里的表都表过态了",而它其实只管一张。
// 【为什么排除 FUNCTION】树里有 3 句 `REVOKE EXECUTE ON FUNCTION public.x() FROM PUBLIC, anon`
// 住在表镜像里(表镜像里也定义函数)。那是一次关于**函数**的表态,
// 与这张表对 anon 开不开没有关系 —— 认了它就会放过一张真的沉默的表。
const RE_REVOKE =
    /^[ \t]*REVOKE\b(?![^;]*\bFUNCTION\b)[^;]*\bON\s+public\.([a-z0-9_]+)\b[^;]*\bFROM\b[^;]*\banon\b/gim

function revokedTables(src) {
    return [...src.matchAll(RE_REVOKE)].map((m) => m[1])
}

// ════════════════════════════════════════════════════════════════════════
// ★★ 常驻的故障注入 —— 每一次运行都跑,不靠谁记得 ★★
// 它们喂的是**合成文本**,不碰树。任一格行为不对,本脚本在检查任何真东西
// 【之前】就红 —— 与 db/check_grants.py 的两格同形。
// ════════════════════════════════════════════════════════════════════════
function selfTest() {
    const cells = []
    const cell = (name, ok) => cells.push({ name, ok })

    // ① 沉默的表必须被认出来(这是本脚本存在的全部理由)
    const silent = 'CREATE TABLE public.zz_probe_silent (\n    id uuid\n);\n'
    cell('沉默的表 → 认得出',
        tablesInA(silent).length === 1 && revokedTables(silent).length === 0)

    // ② 点名的 REVOKE 必须算作表态
    const spoken = silent + 'REVOKE ALL ON public.zz_probe_silent FROM anon;\n'
    cell('点名的 REVOKE → 算表态', revokedTables(spoken).includes('zz_probe_silent'))

    // ③ ★ REVOKE EXECUTE ON FUNCTION 【不算】一张表的表态
    const fnOnly = silent + 'REVOKE EXECUTE ON FUNCTION public.zz_probe_fn() FROM PUBLIC, anon;\n'
    cell('函数的 REVOKE → 不算表态', revokedTables(fnOnly).length === 0)

    // ④ 不点名这张表的 REVOKE 不算(另一张表的表态不能替它说话)
    const otherTable = silent + 'REVOKE ALL ON public.zz_probe_other FROM anon;\n'
    cell('别的表的 REVOKE → 不算这一张', !revokedTables(otherTable).includes('zz_probe_silent'))

    // ⑤ 一份镜像里的第二张表必须被数到
    const twoTables = silent + '\nCREATE TABLE public.zz_probe_second (\n    id uuid\n);\n'
    cell('一份镜像两张表 → 都数到', tablesInA(twoTables).length === 2)

    // ⑥ ★ 基线读不到必须【抛】,不许读成空集合
    let threw = false
    try { readBaselineRelations(join(ROOT, 'db', 'zz-no-such-baseline.tsv')) } catch { threw = true }
    cell('基线读不到 → 抛,不是空集合', threw)

    // ⑦ 注释掉的 CREATE TABLE:路 A 不认(行首是 `--`),路 B 也不认(剥了注释)
    const commented = '-- CREATE TABLE public.zz_probe_commented (\n'
    cell('注释掉的建表 → 两条路都不认',
        tablesInA(commented).length === 0 && tablesInB(commented).length === 0)

    const bad = cells.filter((c) => !c.ok)
    if (bad.length) {
        console.error(`✗ ${SCRIPT}:**常驻故障注入有 ${bad.length} 格不对 —— 本脚本自己坏了,它这一次什么都没有验证。**`)
        for (const c of bad) console.error(`    ✗ ${c.name}`)
        process.exit(2)
    }
    return cells.length
}

// ════════════════════════════════════════════════════════════════════════
const cellsRun = selfTest()

const files = readdirSync(TABLES_DIR).filter((f) => f.endsWith('.sql')).sort()
assertPopulation(SCRIPT, 'db/tables 下的镜像文件', files.length)

const byTableA = new Map()   // 表名 → 镜像文件
const setB = new Set()
const revoked = new Map()    // 表名 → 镜像文件

for (const f of files) {
    const src = readFileSync(join(TABLES_DIR, f), 'utf8')
    for (const t of tablesInA(src)) byTableA.set(t, f)
    for (const t of tablesInB(src)) setB.add(t)
    for (const t of revokedTables(src)) revoked.set(t, f)
}

// 【总体:两条独立的路必须给出同一个数,不然就是有一种写法我没想到】
assertPinned(
    SCRIPT, 'db/tables 里的表总数',
    byTableA.size, setB.size,
    '路 A 是行首锚定的 CREATE TABLE,路 B 是剥掉注释之后任意位置的 —— ' +
    '差额通常意味着一句【缩进的】或【被注释掉的】建表语句。',
)
assertPopulation(SCRIPT, 'db/tables 里的表', byTableA.size)

const baseline = readBaselineRelations(BASELINE)
assertPopulation(SCRIPT, 'anon 基线里的 relation 行', baseline.size)

const silent = []
for (const [table, file] of [...byTableA].sort()) {
    if (revoked.has(table)) continue
    if (baseline.has(table)) continue
    silent.push({ table, file })
}

if (silent.length) {
    console.error(`✗ ${SCRIPT}:${silent.length} 张表【对 anon 一个字都没说】。`)
    console.error(`  这不是"它错了",是"没有人想过这件事" —— 而 FA-HIST-1 与 APR-1 两天之内`)
    console.error(`  各在这里栽过一次,两次都是在【迁移之后】由整门抓到的。`)
    for (const s of silent) {
        console.error(`    · public.${s.table}   (db/tables/${s.file})`)
    }
    console.error(`\n  ☞ 两种表态,选一种,**在建这张表的那个提交里**:`)
    console.error(`    ① anon 够不着它(★ 迁移以 postgres 落表时的默认,也是绝大多数情况)`)
    console.error(`       → 在镜像里加一句: REVOKE ALL ON public.<表> FROM anon;`)
    console.error(`         **这一句是给【重建】看的** —— 它让本地重建长成线上的样子。`)
    console.error(`         ⚠ 不要往 db/anon-grants-baseline.tsv 里加行:那份基线记的是`)
    console.error(`           "anon 够得着的东西",而 anon 够不着它;加一行是把基线【放大】,`)
    console.error(`           而那个文件只许缩小。`)
    console.error(`    ② anon 【真的】要够得着它(本仓库至今 0 张表走这一支)`)
    console.error(`       → 加一行 \`relation\\t<表名>\` 到 db/anon-grants-baseline.tsv,`)
    console.error(`         **并把理由写进那次迁移的抬头**。`)
    process.exit(1)
}

console.log(
    `✓ ${SCRIPT}:${byTableA.size} 张表,每一张都对 anon 显式表过态 ` +
    `(${revoked.size} 张带点名的 REVOKE · ${[...byTableA.keys()].filter((t) => baseline.has(t)).length} 张在基线里) ` +
    `· 常驻注入 ${cellsRun} 格全过`,
)
