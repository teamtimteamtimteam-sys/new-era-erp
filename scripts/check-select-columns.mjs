#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// BUGFIX-1a(2026-09-12)· 每一处 .from('表').select('列…') 都要对得上镜像
// ════════════════════════════════════════════════════════════════════════════
// 【它为什么存在,一句话】
//   `app/tools/calendar/sources.ts` 读了 `containers.container_no` —— 一列
//   **从来没有存在过**的列(TOOLS-1 一出生就拼错)。它活了 8 天,而这棵树上的
//   三道闸**没有一道结构上看得见它**:
//     · 路由冒烟断言 2xx,而那一页照规矩接住了 error、画了一个红框 —— **HTTP 200**;
//     · `db/gate.py` 不读应用 SQL(`grep 'app/' db/gate.py` = 0 行);
//     · 类型检查**本来抓得到**,而挡住它的是那一支查询上的 6 句 `as never`。
//   ☞ 这一支是那道**结构上看得见它**的闸,而且它不碰网络、秒级。
//
// 【它与类型检查的关系 —— 照直说】`as never` 已经拿掉了,于是 `tsc` 今天也抓得到
//   这一条(实测:把 `container_no` 放回去,`next build` 当场报 TS2322/SelectQueryError)。
//   ★ **两道闸的差别在【下一次】**:再有人为了让类型过关而加一句 cast,
//     `tsc` 就再次失明,而这一支不会 —— 它读的是**源码文本**,不是类型。
//
// 【它是一道闸】进 `npm run build`。退出码三档:0 干净 / 1 找到了违规 / 2 量具坏了。
//
// ════════════════════════════════════════════════════════════════════════════
// 【瞄准 · AIM】
//   我读的是      :① `app/` 与 `lib/` 下 `.ts`/`.tsx` 的**源码文本** —— 每一处
//                   `.from('<表>')`,以及沿【链】往后第一个调用:`.select(<列串>)`
//                   (列串是字面量,或者一个解析得出来的 `const`),或者
//                   `.insert/.update/.upsert(<对象字面量>)` 的**顶层键名**;
//                   ② `lib/database.types.ts` 里 `Tables` 与 `Views` 两节每一个
//                   关系的 `Row` / `Insert` / `Update` 键名。**两边都是文本,我不连数据库。**
//   我声称管的是   :「这棵树上每一处查询点的名的列 —— 读的列与写的键 —— 在镜像里都存在。」
//   两者不同之处   :★★ 这几行要读完再看那个零 ★★
//
//     ① ★ **【写】那一半只覆盖得到【字面量对象】的那些键。**
//        实测本树 **130** 处写入点(insert 47 · update 74 · upsert 9;委托书里
//        那个 55 **是错的**,本刀重量过)。其中 **102** 处的实参是一个花括号字面量
//        (含 9 处带展开的 —— 展开只会【多】出键,它挡不住我读那几个写出来的),
//        另 **28** 处实参是一个变量或表达式(`payload` / `row` / `row as never`),
//        ☞ **那 28 处我读不出来,而我把它们逐条列出来并计数** ——
//          缺口另登记在 `docs/known-issues.md`(`SELECT-COLS-WRITE-KEYS-UNCOVERED`)。
//
//     ② ★ **镜像不是数据库。** `lib/database.types.ts` 由 `db/gate.py` 钉住,
//        而钉住它的是**另一道闸**。镜像自己漂了,我会跟着漂 —— 我说的是
//        「对得上镜像」,不是「对得上线上」。
//
//     ③ ★ **读不准的形状我【列出来并计数】,不当作通过。** `.select(变量)`、
//        带 `${}` 的模板串、链断了取不到 `.select` 的 `.from()` —— 每一类都有
//        自己的计数,印在输出里。**一个读不准的站点不是一个干净的站点。**
//
//     ④ **`select('*')` 按定义没有列可查**,单独计数。
// ════════════════════════════════════════════════════════════════════════════
import { readFileSync, existsSync, readdirSync } from 'node:fs'
import { dirname, resolve as presolve, relative, join } from 'node:path'
import { assertPopulation, assertPinned, assertAllowlistLive } from './lib/selfproof.mjs'

const SELF = 'check-select-columns'
const ROOT = process.cwd()
const MIRROR = 'lib/database.types.ts'

// ── ① 镜像:Tables + Views 的每一个 Row 列名 ─────────────────────────────────
// 按【缩进】读,不按花括号配平:生成出来的这份文件缩进是规则的,而一个配平器
// 会把 `Relationships` 里的对象也当成列。缩进这条路更窄,也更容易说清楚。
function readMirror(kind) {
    const lines = readFileSync(MIRROR, 'utf8').split('\n')
    const rels = new Map()          // 关系名 -> Set(键名)
    let section = null              // 'Tables' | 'Views'
    let rel = null, inBlock = false
    const head = new RegExp(`^ {8}${kind}: \\{$`)
    for (const line of lines) {
        let m
        if ((m = /^ {4}(Tables|Views|Functions|Enums|CompositeTypes): \{$/.exec(line))) {
            section = (m[1] === 'Tables' || m[1] === 'Views') ? m[1] : null
            rel = null; inBlock = false; continue
        }
        if (!section) continue
        if ((m = /^ {6}([A-Za-z0-9_]+): \{$/.exec(line))) { rel = m[1]; inBlock = false; if (!rels.has(rel)) rels.set(rel, new Set()); continue }
        if (!rel) continue
        if (head.test(line)) { inBlock = true; continue }
        if (/^ {8}[A-Za-z]+:/.test(line) || /^ {8}\}$/.test(line)) { inBlock = false; continue }
        if (inBlock && (m = /^ {10}([A-Za-z0-9_]+)(\?)?: /.exec(line))) rels.get(rel).add(m[1])
    }
    return rels
}
const MIRROR_RELS = readMirror('Row')
const MIRROR_INSERT = readMirror('Insert')
const MIRROR_UPDATE = readMirror('Update')
// 第二条【独立】的路数同一个总体:直接数 `Row: {` 出现了几次(它每个关系恰好一处)。
const rowBlocks = (readFileSync(MIRROR, 'utf8').match(/^ {8}Row: \{$/gm) || []).length
assertPopulation(SELF, `${MIRROR} 里的表与视图`, MIRROR_RELS.size)
assertPinned(SELF, '按缩进读出的关系 ↔ 文件里 `Row: {` 的块数', MIRROR_RELS.size, rowBlocks,
    '对不上就是缩进解析漏了(或多读了)一个关系,于是下面每一次"这一列不存在"都不作数。')

// ── ② 源码:.from('T') → 链上第一个 .select(...) ────────────────────────────
// ★【走文件系统,不走 `git ls-files`】本刀第一次写的是后者,而故障注入当场证明
//   它是瞎的:一个**还没有加进索引**的新文件(正是一次改动最常见的样子)
//   它一个字都看不见,照样报「全部对得上」。
//   ☞ 一道闸要看的是【这棵树现在是什么样】,不是【索引里记着什么】。
function walkTs(dir) {
    const out = []
    for (const e of readdirSync(dir, { withFileTypes: true })) {
        if (e.name === 'node_modules' || e.name.startsWith('.')) continue
        const p = join(dir, e.name)
        if (e.isDirectory()) out.push(...walkTs(p))
        else if (/\.tsx?$/.test(e.name)) out.push(p)
    }
    return out
}
const files = [...walkTs('app'), ...walkTs('lib')].sort()
assertPopulation(SELF, 'app/ 与 lib/ 下的 .ts/.tsx 源文件', files.length, 100)
const SRC = new Map(files.map((f) => [f, readFileSync(f, 'utf8')]))

// 列清单常量【按文件收】,不按名字收:同一个名字(EXPORT_COLUMNS)在好几个文件里
// 各有一份,一张全局表 first-wins 会把别的模块的列记到这张表头上。
const constsByFile = new Map(), exportedByFile = new Map()
for (const [f, src] of SRC) {
    const local = new Map(), exp = new Map()
    const re = /(export\s+)?const\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?::\s*string\s*)?=\s*(['"`])([\s\S]*?)\3/g
    let m
    while ((m = re.exec(src))) { local.set(m[2], m[4]); if (m[1]) exp.set(m[2], m[4]) }
    constsByFile.set(f, local); exportedByFile.set(f, exp)
}
function resolveImported(file, name) {
    const src = SRC.get(file)
    const re = /import\s*\{([^}]*)\}\s*from\s*(['"])([^'"]+)\2/g
    let m
    while ((m = re.exec(src))) {
        if (!m[1].split(',').some((x) => x.trim().split(/\s+as\s+/)[0].trim() === name)) continue
        const spec = m[3]
        const base = spec.startsWith('@/') ? presolve(ROOT, spec.slice(2))
            : spec.startsWith('.') ? presolve(ROOT, dirname(file), spec) : null
        if (!base) return null
        for (const ext of ['.ts', '.tsx', '/index.ts', '/index.tsx']) {
            const cand = base + ext
            if (existsSync(cand)) {
                const e = exportedByFile.get(relative(ROOT, cand))
                if (e && e.has(name)) return e.get(name)
            }
        }
        return null
    }
    return null
}
/** 从 idx 起沿链走,返回第一个链式调用的名字与实参文本;链一断就返回 null。 */
function chainCall(src, idx) {
    let i = idx
    for (;;) {
        while (i < src.length && /\s/.test(src[i])) i++
        if (src.startsWith('//', i)) { i = src.indexOf('\n', i); if (i < 0) return null; continue }
        if (src.startsWith('/*', i)) { i = src.indexOf('*/', i); if (i < 0) return null; i += 2; continue }
        if (src[i] !== '.') return null
        i++
        const nm = /^[A-Za-z0-9_]+/.exec(src.slice(i))
        if (!nm) return null
        i += nm[0].length
        while (i < src.length && /\s/.test(src[i])) i++
        if (src[i] !== '(') return null
        const argStart = i + 1
        let d = 0, j = i, q = null
        for (; j < src.length; j++) {
            const c = src[j]
            if (q) { if (c === '\\') j++; else if (c === q) q = null; continue }
            if (c === "'" || c === '"' || c === '`') { q = c; continue }
            if (c === '(') d++
            else if (c === ')') { d--; if (d === 0) break }
        }
        if (j >= src.length) return null
        if (['select', 'insert', 'update', 'upsert', 'delete'].includes(nm[0])) return { name: nm[0], args: src.slice(argStart, j), end: j + 1 }
        i = j + 1
    }
}

/**
 * 一个对象字面量的**顶层**键名。
 * 【为什么自己走一遍而不是按逗号切】值里可以有对象、数组、三元、模板串与函数调用,
 * 每一样里都可能有逗号与冒号。按逗号切开会把 `{ a: f(1, 2) }` 读成两个键。
 */
function topLevelKeys(body) {
    const inner = body.trim().replace(/^\{/, '').replace(/\}$/, '')
    const keys = []
    let depth = 0, q = null, buf = '', atKey = true
    for (let i = 0; i < inner.length; i++) {
        const c = inner[i]
        if (q) { if (c === '\\') i++; else if (c === q) q = null; continue }
        if (c === "'" || c === '"' || c === '`') { q = c; continue }
        if ('({['.includes(c)) { depth++; continue }
        if (')}]'.includes(c)) { depth--; continue }
        if (c === ',' && depth === 0) {
            if (atKey) { const k = /^\s*([A-Za-z0-9_]+)\s*$/.exec(buf); if (k) keys.push(k[1]) }   // 简写 { a, b }
            buf = ''; atKey = true; continue
        }
        if (c === ':' && depth === 0 && atKey) {
            const k = /^\s*([A-Za-z0-9_]+)\s*$/.exec(buf); if (k) keys.push(k[1])
            atKey = false; buf = ''; continue
        }
        buf += c
    }
    if (atKey) { const k = /^\s*([A-Za-z0-9_]+)\s*$/.exec(buf); if (k) keys.push(k[1]) }
    return keys
}

const UNREADABLE = { chainBroke: [], selectVar: [], templated: [], star: [], writeVar: [] }
const sites = []
const writeSites = []          // { file, line, table, op, keys }
let fromSites = 0, writeTotal = 0, writeWithSpread = 0
for (const [f, src] of SRC) {
    const lineOf = (i) => src.slice(0, i).split('\n').length
    const fromRe = /\.from\(\s*(['"`])([A-Za-z0-9_]+)\1\s*\)/g
    let m
    while ((m = fromRe.exec(src))) {
        fromSites++
        const table = m[2], line = lineOf(m.index)
        let call = chainCall(src, m.index + m[0].length)
        if (call === null) { UNREADABLE.chainBroke.push(`${f}:${line} .from('${table}') —— 链上没有一个认得的调用`); continue }
        if (call.name !== 'select' && call.name !== 'delete') {
            // ── 写:.insert / .update / .upsert 的顶层键名 ──────────────────
            writeTotal++
            const w = call.args.trim()
            if (!w.startsWith('{')) UNREADABLE.writeVar.push(`${f}:${line} .from('${table}').${call.name}(${w.slice(0, 36)}…) —— 实参不是对象字面量`)
            else {
                if (/\.\.\./.test(w)) writeWithSpread++
                writeSites.push({ file: f, line, table, op: call.name, keys: topLevelKeys(w) })
            }
            // ★ 一次写【后面还可以跟一个 .select()】(`.insert({…}).select('id, code')`)——
            //   那仍然是一次读,它的列照样要查。链继续走。
            call = chainCall(src, call.end)
        }
        if (call === null || call.name === 'delete') continue      // 没有要查的列了
        if (call.name !== 'select') continue
        const a = call.args.trim()
        let raw = null
        if (a[0] === "'" || a[0] === '"' || a[0] === '`') {
            const q = a[0]
            let k = 1
            for (; k < a.length; k++) { if (a[k] === '\\') { k++; continue } if (a[k] === q) break }
            raw = a.slice(1, k)
        } else {
            const id = /^([A-Za-z_][A-Za-z0-9_]*)\s*(?:,|$)/.exec(a)
            const local = constsByFile.get(f)
            const got = id && local && local.has(id[1]) ? local.get(id[1]) : id ? resolveImported(f, id[1]) : null
            if (got == null) { UNREADABLE.selectVar.push(`${f}:${line} .from('${table}').select(${a.slice(0, 40)})`); continue }
            raw = got
        }
        if (raw.trim() === '*') { UNREADABLE.star.push(`${f}:${line} .from('${table}').select('*')`); continue }
        if (/\$\{/.test(raw)) { UNREADABLE.templated.push(`${f}:${line} .from('${table}')`); continue }
        sites.push({ file: f, line, table, raw })
    }
}
// 独立的第二条路:直接数 `.from('` 的文本出现次数。它不走链行走器。
const textFrom = [...SRC.values()].reduce((n, s) => n + (s.match(/\.from\(\s*['"`][A-Za-z0-9_]+['"`]\s*\)/g) || []).length, 0)
assertPopulation(SELF, "源码里的 .from('表') 站点", fromSites)
assertPinned(SELF, "链行走器数出的 .from 站点 ↔ 纯文本数出的", fromSites, textFrom,
    '对不上就是扫描那一层漏了文件或漏了站点。')

// ── ③ 列串 → 表×列。别名、内嵌关系、`::` 转型、`->` 取 JSON 都要认得 ──────────
function parseCols(raw) {
    const out = []; let buf = ''; const relStack = []; const bad = []
    const clean = (t) => t.trim()
        .replace(/^[A-Za-z0-9_]+\s*:\s*/, '')      // 别名 alias:col
        .split('::')[0].trim()                      // ::type 转型
        .split(/->>?/)[0].trim()                    // -> / ->> 取 JSON
        .replace(/\s*!\s*[A-Za-z0-9_]+$/, '')       // !fk_hint / !inner
        .replace(/\.{3}/, '')                       // spread
    const flush = () => {
        const t = clean(buf); buf = ''
        if (!t || t === '*') return
        if (t.includes('${')) { bad.push(t); return }
        if (!/^[A-Za-z0-9_]+$/.test(t)) { bad.push(t); return }
        out.push({ rel: relStack[relStack.length - 1] ?? null, col: t })
    }
    for (const c of raw) {
        if (c === '(') { relStack.push(clean(buf)); buf = '' }
        else if (c === ')') { flush(); relStack.pop() }
        else if (c === ',') flush()
        else buf += c
    }
    flush()
    return { cols: out, bad }
}

const pairs = []
const unparsedTokens = []
sites.forEach((s, siteIdx) => {
    const { cols, bad } = parseCols(s.raw)
    for (const b of bad) unparsedTokens.push(`${s.file}:${s.line} .from('${s.table}') 读不出的片段 \`${b}\``)
    for (const p of cols) pairs.push({ ...s, siteIdx, table: p.rel || s.table, col: p.col, embedded: !!p.rel })
})
assertPopulation(SELF, '表×列对', pairs.length)

// 第二条独立的路,跑在一个说得清的子总体上:**不含括号的**列串按逗号切开,
// 逐个数出来的列数,必须等于 char 行走器在同一批站点上数出来的。
const flatIdx = new Set(sites.map((s, i) => (s.raw.includes('(') ? -1 : i)).filter((i) => i >= 0))
const flatWalker = pairs.filter((p) => flatIdx.has(p.siteIdx)).length
const flatSplit = [...flatIdx].reduce((n, i) => n + sites[i].raw.split(',').map((x) => x.trim()).filter((x) => x && x !== '*').length, 0)
assertPopulation(SELF, '不含内嵌关系的 select 站点(钉住用的子总体)', flatIdx.size)
assertPinned(SELF, '不含括号的列串:char 行走器 ↔ 按逗号切开', flatWalker, flatSplit,
    '对不上就是列串解析那一层自己漂了。')

// 【必须查得出来】的探针 —— 名单命不中就是镜像读法塌了,不是树干净了。
assertAllowlistLive(SELF, '必须在镜像里查得到的表×列', [
    ['containers', 'container_number'], ['containers', 'code'],
    ['leave_calendar', 'legal_name'], ['tasks', 'due_date'],
], ([t, c]) => MIRROR_RELS.get(t)?.has(c), ([t, c]) => `${t}.${c}`)

// ── ④ 写入点的键 ────────────────────────────────────────────────────────────
const writeKeys = []
for (const w of writeSites) for (const k of w.keys) writeKeys.push({ ...w, key: k })
assertPopulation(SELF, '读得出来的写入键', writeKeys.length)
// 第二条独立的路:键的总数 = 每个站点自己那份键数组长度之和(不经过上面这次展开)。
assertPinned(SELF, '展开出来的写入键 ↔ 各站点键数之和',
    writeKeys.length, writeSites.reduce((n, w) => n + w.keys.length, 0),
    '对不上就是展开那一步丢了站点。')

// ── ⑤ 判据 ──────────────────────────────────────────────────────────────────
const missingCols = [], unknownRels = [], missingKeys = []
for (const p of pairs) {
    const cols = MIRROR_RELS.get(p.table)
    if (!cols) { unknownRels.push(`${p.file}:${p.line} ${p.table}${p.embedded ? '(内嵌关系)' : ''}`); continue }
    if (!cols.has(p.col)) missingCols.push(`${p.file}:${p.line} ${p.table}.${p.col} —— 镜像里没有这一列`)
}
for (const w of writeKeys) {
    const set = (w.op === 'update' ? MIRROR_UPDATE : MIRROR_INSERT).get(w.table)
    if (!set) { unknownRels.push(`${w.file}:${w.line} ${w.table}(${w.op} 的目标)`); continue }
    if (!set.has(w.key)) missingKeys.push(`${w.file}:${w.line} ${w.table}.${w.key} —— 镜像的 ${w.op === 'update' ? 'Update' : 'Insert'} 里没有这个键`)
}
const uniqPairs = new Set(pairs.map((p) => `${p.table}|${p.col}`))
const unreadable = UNREADABLE.chainBroke.length + UNREADABLE.selectVar.length + UNREADABLE.templated.length

console.log(`· 镜像 ${MIRROR}:${MIRROR_RELS.size} 个表与视图`)
console.log(`· 源码 ${files.length} 个文件里 ${fromSites} 处 .from('表')`)
console.log(`    · 读得准并查过的站点        ${sites.length}`)
console.log(`    · select('*')(没有列可查)  ${UNREADABLE.star.length}`)
console.log(`    · 链断了,取不到 .select()   ${UNREADABLE.chainBroke.length}`)
console.log(`    · .select(变量),解析不出   ${UNREADABLE.selectVar.length}`)
console.log(`    · 列串里有 \${},读不准      ${UNREADABLE.templated.length}`)
console.log(`· 查过的表×列对 ${pairs.length}(去重 ${uniqPairs.size}),其中内嵌关系上的 ${pairs.filter((p) => p.embedded).length}`)
console.log(`· 写入点 ${writeTotal} 处(insert/update/upsert):读得出键的 ${writeSites.length}(其中 ${writeWithSpread} 处带展开,` +
    `展开只会多出键,挡不住那几个写出来的)· 读不出的 ${UNREADABLE.writeVar.length} 处`)
console.log(`· 查过的写入键 ${writeKeys.length}(去重 ${new Set(writeKeys.map((w) => `${w.table}|${w.key}`)).size})`)
for (const [k, label] of [['chainBroke', '链断了'], ['selectVar', 'select(变量)'], ['templated', '模板串'], ['writeVar', '写入实参不是对象字面量']]) {
    if (UNREADABLE[k].length) { console.log(`  ⚠ ${label}(${UNREADABLE[k].length} 处,逐条):`); for (const x of UNREADABLE[k]) console.log(`      · ${x}`) }
}
if (unparsedTokens.length) { console.log(`  ⚠ 列串里读不出的片段(${unparsedTokens.length} 处,逐条):`); for (const x of unparsedTokens) console.log(`      · ${x}`) }

const problems = [...missingCols, ...missingKeys, ...unknownRels.map((r) => `${r} —— 这个关系不在镜像的 Tables/Views 里`)]
if (problems.length) {
    console.error(`\n✗ ${SELF}:${problems.length} 处对不上(分母:${pairs.length} 个表×列对 + ${writeKeys.length} 个写入键)`)
    for (const p of problems) console.error(`   · ${p}`)
    console.error('')
    console.error('【怎么读这个结果】一列在镜像里不存在,只有三种可能:')
    console.error('  ① 查询把列名拼错了(item a 就是这一种,而它活了 8 天);')
    console.error('  ② 库里改过而镜像没跟上 —— 那是 db/gate.py 的事,先跑它;')
    console.error('  ③ 那不是一处【读】,是这一支读错了形状 —— 照直说出来,不要改判据去凑。')
    process.exit(1)
}
console.log(`\n✓ ${SELF}:${pairs.length} 个表×列对(去重 ${uniqPairs.size})与 ${writeKeys.length} 个写入键` +
    `全部对得上 ${MIRROR};另有 ${UNREADABLE.star.length} 处 select('*')、` +
    `${unreadable} 处读不准的读站点与 ${UNREADABLE.writeVar.length} 处读不准的写站点,已逐条列出。`)
