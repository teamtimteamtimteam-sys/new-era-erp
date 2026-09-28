#!/usr/bin/env node
// scripts/check-change-log-coverage.mjs
//
// ════════════════════════════════════════════════════════════════════════════
// HISTORY-1(Tim 的 Q12,2026-09-28)
// 【它回答一个问题】仓库里的每一张 public 表,是不是【要么被通用变更记录绑着、要么在豁免名单上带着理由】?
//
//   被绑着 = db/views/zzz_change_log_triggers.sql 里有它的两条触发器:
//            zzz_change_log(行级)与 zzz_change_log_truncate(TRUNCATE)
//   豁免   = db/functions/change_log_exclusions.sql 的 VALUES 里有它一行,且理由非空
//
// 【与 gate 的 changelog 那一行的分工】
//   gate 问【线上目录】与【本地重建】(change_log_coverage_gaps(),还看触发器是不是停着) —— 准,但晚:
//     那时建表的迁移已经在线上了。
//   本文件问【仓库文件】,不连库,进 `npm run build`,毫秒级 —— 一个人刚写完建表的镜像、
//     还没碰线上的时候就红。它看不见"线上的触发器被停掉了"那一种,那一种归 gate。
//
// 【缺口三种,与库里那支函数逐字同名】
//   unbound            —— 没绑也没豁免
//   excluded_but_bound —— 豁免了却绑着(两边说的不是一件事)
//   excluded_unknown   —— 豁免名单点了一张仓库里不存在的表(change_log 本身例外:它由 db/tables/change_log.sql 建)
//   另加仓库这一侧才有的一种:
//   binding_unknown    —— 绑定清单里有一张仓库里不存在的表
//   half_bound         —— 只有两条里的一条
//
// 【覆盖率本身是一条断言】(AGENTS.md「★★★ 覆盖率本身必须是一条断言」)
//   · 表:按 `public.<名字>` 解析出的表数,必须等于【非注释行里 `CREATE TABLE` 这个词出现的次数】
//     —— 两条独立的路;对不上 = 有一种建表写法解析器不认识,当场红,不报"干净"。
//   · 绑定:解析出的触发器数,必须等于非注释行里 `CREATE TRIGGER` 出现的次数。
//   · 看见的表少于 200 张 → 红(一个瞎掉的解析器会报出一个很小的"干净")。
//
// 【每一次运行都自己注入三格】(与 db/check_grants.py 同一个做法)
//   ① 从内存里的绑定清单删掉一张表 → 必须报 unbound;
//   ② 给一张豁免的表凭空加两条绑定 → 必须报 excluded_but_bound;
//   ③ 把表清单清空 → 必须因为"看见的表 < 200"而红。
//   任何一格没有红,本脚本退 3,并且【不给判词】—— 它不知道自己还看不看得见。
//
// 【瞄准 · AIM】
//   我读的是      :db/tables/*.sql 里的 `CREATE TABLE public.<名>`、db/views/zzz_change_log_triggers.sql 里的
//                   两种 `CREATE TRIGGER zzz_change_log…`、db/functions/change_log_exclusions.sql 的 VALUES ——
//                   【仓库文件的文本】,剥掉注释之后。
//   我声称管的是   :每一张 public 表都被通用变更记录绑着,或者在豁免名单上带着理由。
//   两者不同之处   :★ 我答的是【仓库】里的声明对不对得上,不是【线上】的触发器在不在、是不是启用着 ——
//                   那一半归 db/gate.py 的 changelog(change_log_coverage_gaps(),两侧都问)。
//                   一条写在迁移里、却没写回镜像的绑定,我看不见;gate 看得见。
//
// 退出码:0 干净 · 1 有缺口 · 3 自检失败(本脚本瞎了)
// ════════════════════════════════════════════════════════════════════════════
import fs from 'node:fs'
import path from 'node:path'

const ROOT = process.cwd()
const TABLES_DIR = path.join(ROOT, 'db', 'tables')
const BINDINGS = path.join(ROOT, 'db', 'views', 'zzz_change_log_triggers.sql')
const EXCLUSIONS = path.join(ROOT, 'db', 'functions', 'change_log_exclusions.sql')
const FLOOR = 200

// 只剥【整行注释】与行尾 `-- …`(不在字符串里的那种);镜像里的建表与建触发器语句没有跨引号的 `--`。
function stripComments(src) {
    return src
        .split('\n')
        .map((l) => {
            if (/^\s*--/.test(l)) return ''
            let q = false
            for (let i = 0; i < l.length - 1; i++) {
                if (l[i] === "'") q = !q
                if (!q && l[i] === '-' && l[i + 1] === '-') return l.slice(0, i)
            }
            return l
        })
        .join('\n')
}

function readTables() {
    const names = []
    let keyword = 0
    for (const f of fs.readdirSync(TABLES_DIR).filter((x) => x.endsWith('.sql')).sort()) {
        const code = stripComments(fs.readFileSync(path.join(TABLES_DIR, f), 'utf8'))
        for (const m of code.matchAll(/CREATE TABLE\s+(?:IF NOT EXISTS\s+)?public\.([a-z0-9_]+)\s*\(/g)) names.push(m[1])
        keyword += (code.match(/\bCREATE TABLE\b/g) || []).length
    }
    return { names, keyword }
}

function readBindings() {
    const code = stripComments(fs.readFileSync(BINDINGS, 'utf8'))
    const row = [...code.matchAll(/CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public\.([a-z0-9_]+)\s+FOR EACH ROW EXECUTE FUNCTION public\.change_log_capture\(/g)].map((m) => m[1])
    const trunc = [...code.matchAll(/CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public\.([a-z0-9_]+)\s+FOR EACH STATEMENT EXECUTE FUNCTION public\.change_log_capture\(\)/g)].map((m) => m[1])
    const keyword = (code.match(/\bCREATE TRIGGER\b/g) || []).length
    return { row, trunc, keyword }
}

function readExclusions() {
    const src = stripComments(fs.readFileSync(EXCLUSIONS, 'utf8'))
    const body = src.split(/\bVALUES\b/).pop() ?? ''
    const out = []
    for (const m of body.matchAll(/\(\s*'([a-z0-9_]+)'(?:::text)?\s*,\s*'((?:[^']|'')*)'(?:::text)?\s*\)/g)) {
        out.push({ table: m[1], reason: m[2].trim() })
    }
    return out
}

/** 判据本身 —— 入参就是读取层的全部输出(FONT-2 那条:读到了却没进参数表的字段,当场看得见)。 */
function judge({ tables, row, trunc, exclusions }) {
    const gaps = []
    const T = new Set(tables)
    const R = new Set(row)
    const TR = new Set(trunc)
    const X = new Map(exclusions.map((e) => [e.table, e.reason]))
    if (tables.length < FLOOR) gaps.push(`floor: only ${tables.length} tables seen (< ${FLOOR}) — the parser is blind, not clean`)
    for (const t of [...T].sort()) {
        const bound = R.has(t) && TR.has(t)
        const half = R.has(t) !== TR.has(t)
        if (X.has(t)) {
            if (R.has(t) || TR.has(t)) gaps.push(`excluded_but_bound:${t}`)
        } else if (half) gaps.push(`half_bound:${t}`)
        else if (!bound) gaps.push(`unbound:${t}`)
    }
    for (const [t, why] of X) {
        if (!T.has(t)) gaps.push(`excluded_unknown:${t}`)
        if (!why) gaps.push(`exclusion_without_reason:${t}`)
    }
    for (const t of new Set([...R, ...TR])) if (!T.has(t)) gaps.push(`binding_unknown:${t}`)
    return gaps
}

const t = readTables()
const b = readBindings()
const exclusions = readExclusions()
const coverage = []
if (t.names.length !== t.keyword)
    coverage.push(`tables: parsed ${t.names.length} names but saw ${t.keyword} CREATE TABLE keywords — a table form the parser does not read`)
if (b.row.length + b.trunc.length !== b.keyword)
    coverage.push(`bindings: parsed ${b.row.length + b.trunc.length} triggers but saw ${b.keyword} CREATE TRIGGER keywords`)
if (exclusions.length === 0) coverage.push('exclusions: parsed 0 entries — the parser is broken, the list is not empty')

const input = { tables: t.names, row: b.row, trunc: b.trunc, exclusions }

// ── 每一次运行的自检注入 ──────────────────────────────────────────────────
const victim = b.row.find((x) => !exclusions.some((e) => e.table === x))
const excluded = exclusions.find((e) => t.names.includes(e.table))?.table
const selftest = [
    ['drop one binding → unbound', { ...input, row: input.row.filter((x) => x !== victim), trunc: input.trunc.filter((x) => x !== victim) }, `unbound:${victim}`],
    ['bind an excluded table → excluded_but_bound', { ...input, row: [...input.row, excluded], trunc: [...input.trunc, excluded] }, `excluded_but_bound:${excluded}`],
    ['blind the table parser → floor', { ...input, tables: [] }, 'floor:'],
]
const blind = []
for (const [name, inj, expect] of selftest) {
    const g = judge(inj)
    if (!victim || !excluded || !g.some((x) => x.startsWith(expect))) blind.push(name)
}
if (blind.length) {
    console.error(`check-change-log-coverage: ✗ 自检失败 —— 这几格注入没有变红:${blind.join(' · ')}`)
    console.error('   本脚本因此【不知道】自己还看不看得见,不给判词。')
    process.exit(3)
}

const gaps = [...coverage, ...judge(input)]
const boundBoth = t.names.filter((x) => b.row.includes(x) && b.trunc.includes(x)).length
if (gaps.length) {
    console.error(`check-change-log-coverage: ✗ ${gaps.length} 处缺口(${t.names.length} 张表 · ${boundBoth} 张绑定 · ${exclusions.length} 张豁免):`)
    for (const g of gaps) console.error('   ' + g)
    console.error('   每一张新表:在 db/views/zzz_change_log_triggers.sql 里加它的两条绑定(db/scripts/gen_change_log_bindings.py --only <表>),')
    console.error('   或者在 db/functions/change_log_exclusions.sql 里加一行带理由的豁免。见 docs/change-log.md。')
    process.exit(1)
}
console.log(`check-change-log-coverage: ✓ ${t.names.length} 张表 · ${boundBoth} 张绑定 · ${exclusions.length} 张豁免,零缺口(自检 3/3 格变红)`)
