#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// INPUT-2(2026-09-10)· 行高比对器 —— 把一次新读数对着 docs/row-height-baseline.md 比
// ════════════════════════════════════════════════════════════════════════════
// 【它为什么存在,一句话】
//   控件那一族改的是**会推动行高**的东西,而表格那一族逐张判过「390px 上哪几列
//   装得下」—— 判的依据是**今天的行高**。一次说不出「哪一行长了多少」的施工,
//   说不出它有没有推翻那些判断。
//   ☞ INPUT-1 的 scratch 版比对器**第一跑就报了一个假的行高变化**(它按表头签名
//     用 .find() 取第一个命中,而 /finance/processing-costs 上两张表的签名逐字相同)。
//     所以这一支进仓库:INPUT-3 是这一族最险的一刀,它要用的必须是同一支。
//
// 【它不是一道闸】它不在 npm run build 里,也不该进去 —— 它要一次真实渲染的读数。
//   退出码沿用本仓库三档:0 干净 / 1 找到了差别 / 2 **量具自己坏了**。
//
// ════════════════════════════════════════════════════════════════════════════
// 【瞄准 · AIM】
//   我读的是      :① `docs/row-height-baseline.md` 里那三个 ```json 机读块
//                   (§6.1 首屏 · §6.2 `<EditableTable>` 编辑态 · §6.3 今天的溢出)
//                   的**文本**;② `scripts/survey-controls.mjs` 写出的读数 JSON 里
//                   **phone 视口**那一半的 `tables` / `docScrollW` / `docClientW`。
//                   两边都是**已经量好的数**,我自己**不开浏览器、不量任何东西**。
//   我声称管的是   :「自基线那一天起,含控件的表的**表头高度 / 行数 / 最大行高 /
//                   滚动壳内容宽**有没有变;390px 的**整页横向溢出**有没有新增或长大;
//                   **已按裁定横滚的表**有没有多出滚动范围。」
//   两者不同之处   :★★ 这一段是本支最重要的几行 ★★
//
//     ① **我比的是【最大行高】,不是每一行。** 基线 §5 ②b 记着:73 条行里 24 条的
//        `rowFirstCell` 是空的(第一格就是控件),那三张表上行的身份只能退回下标。
//        逐行比会在**数据换了一行**时报一次假差别。**最大行高 + 行数**这两个数
//        对「一行被推高了」是灵敏的,而对「换了一批数据的行序」是钝的。
//        ☞ 代价说清楚:**一行升、另一行降、而最大值没变**的组合我看不见。
//
//     ② **表的身份是三样合起来的:(路由, 表头文字签名, 同签名里的第几个)。**
//        单靠签名不够 —— `/finance/processing-costs` 上两张表的签名逐字相同。
//        单靠 `idx` 也不够 —— 页面上多一张表就整体错位。
//        撞到同路由重名签名时**打印一行警告**,因为那时排序一旦不稳,
//        两张表会被静默错配成一次假的行高变化。
//
//     ③ **我只看 phone(390px)。** 基线量的就是 390px;desktop 的读数基线里
//        只作附录,本支不比。
//
//     ④ **基线里没有的表,我报成「新出现」,不当作干净。** 反之基线有而读数里
//        没有的,报成「不见了」。两个方向都红。
// ════════════════════════════════════════════════════════════════════════════
//
// Usage:
//   node scripts/check-row-height-baseline.mjs --now=.survey-out/controls-drift-X.json
//                                             [--edit=.survey-out/controls-edit-X.json]
//                                             [--baseline=docs/row-height-baseline.md]

import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { assertPopulation, assertPinned } from './lib/selfproof.mjs'

const SELF = 'check-row-height-baseline'
const ROOT = process.cwd()
const arg = (k) => { const a = process.argv.find((x) => x.startsWith(k + '=')); return a ? a.slice(k.length + 1) : null }

const NOW_FILE = arg('--now')
const EDIT_FILE = arg('--edit')
const BASE_FILE = arg('--baseline') || join(ROOT, 'docs/row-height-baseline.md')

if (!NOW_FILE) {
    console.error('用法:node scripts/check-row-height-baseline.mjs --now=<drift 读数.json> [--edit=<edit 读数.json>]')
    process.exit(2)
}

// ── 基线:从 markdown 里把那三个 ```json 块原样取出来 ────────────────────────
// 【为什么解析 markdown 而不是读 .survey-out】`.survey-out/` 是生成物、被 .gitignore
// 忽略、而且上一刀已经覆盖过一次。**耐久的那份基线在 git 里**,所以判据也读那一份。
function jsonBlocks(md) {
    const out = []
    const re = /```json\n([\s\S]*?)\n```/g
    let m
    while ((m = re.exec(md))) out.push(m[1])
    return out
}

const md = readFileSync(BASE_FILE, 'utf8')
const blocks = jsonBlocks(md)
// ── 覆盖断言 ①:基线必须解析出三个块;少一个,下面每一条判据都空转 ──────────
assertPinned(SELF, 'docs/row-height-baseline.md 里的 ```json 机读块',
    blocks.length, 3, '§6.1 首屏 · §6.2 编辑态 · §6.3 溢出 —— 少一个就说明基线的形状变了,而本支还照老样子读。')

let BASE_FIRST, BASE_EDIT, BASE_OVERFLOW
try {
    BASE_FIRST = JSON.parse(blocks[0])
    BASE_EDIT = JSON.parse(blocks[1])
    BASE_OVERFLOW = JSON.parse(blocks[2])
} catch (e) {
    console.error(`✗ ${SELF}:**覆盖断言失败** —— 基线的 json 块解析不了:${e.message}`)
    process.exit(2)
}

// ── 覆盖断言 ②:两条独立的路数同一个总体 ────────────────────────────────────
// 一条走 JSON.parse 的数组长度,一条走 markdown 文本里 `"route":` 的出现次数。
const routeKeyCount = (blocks[0].match(/"route":/g) || []).length
assertPopulation(SELF, '基线 §6.1 里的表', BASE_FIRST.length)
assertPinned(SELF, '基线 §6.1:解析出的表 ↔ 文本里 "route": 的处数',
    BASE_FIRST.length, routeKeyCount, '对不上就是解析器漏读或多读了一条。')
assertPopulation(SELF, '基线 §6.3 的整页溢出条目', BASE_OVERFLOW.documentOverflow390.length)
assertPopulation(SELF, '基线 §6.3 的横滚表', BASE_OVERFLOW.tableShellOverflow390.length)

// ── 读数 ────────────────────────────────────────────────────────────────────
const now = JSON.parse(readFileSync(NOW_FILE, 'utf8'))
if (!now.routes || !now.routes.phone) {
    console.error(`✗ ${SELF}:**覆盖断言失败** —— 读数里没有 phone 视口。基线量的是 390px。`)
    process.exit(2)
}
const PH = now.routes.phone
assertPopulation(SELF, '读数里 phone 视口走到的路由', Object.keys(PH).length)

// ready 不是 ok 的路由 = 一个空洞,不是一次干净
const notReady = Object.entries(PH).filter(([, r]) => r && r.ready !== 'ok').map(([k]) => k)
if (notReady.length) {
    console.error(`✗ ${SELF}:**覆盖断言失败** —— phone 上有 ${notReady.length} 条路由没有 ready=ok:`)
    for (const r of notReady) console.error(`    · ${r}  (ready=${PH[r] && PH[r].ready})`)
    console.error('  ☞ 一条没渲染出来的路由在比对里长得跟「这一页没有表」一模一样。先补齐(--only=<路由>),再比。')
    process.exit(2)
}

// ── 身份:(route, key, 同签名里的第几个) ─────────────────────────────────────
function indexTables(tablesByRoute) {
    const map = new Map()          // "route\x00key\x00ord" -> table
    const dupWarn = []
    for (const [route, rec] of Object.entries(tablesByRoute)) {
        const tables = (rec && rec.tables) || []
        const seen = new Map()
        const sigCount = new Map()
        for (const t of tables) sigCount.set(t.key, (sigCount.get(t.key) || 0) + 1)
        for (const [sig, n] of sigCount) if (n > 1) dupWarn.push({ route, sig, n })
        for (const t of tables) {
            const ord = seen.get(t.key) || 0
            seen.set(t.key, ord + 1)
            map.set(`${route}\x00${t.key}\x00${ord}`, { ...t, route, ord })
        }
    }
    return { map, dupWarn }
}

const { map: NOWT, dupWarn } = indexTables(PH)

// 基线那一侧:同一条 (route,key) 里按它自己的 idx 排,再取序数
const baseSorted = [...BASE_FIRST].sort((a, b) => (a.route === b.route ? (a.idx - b.idx) : (a.route < b.route ? -1 : 1)))
const BASET = new Map()
{
    const seen = new Map()
    const sigCount = new Map()
    for (const t of baseSorted) {
        const rk = `${t.route}\x00${t.key}`
        sigCount.set(rk, (sigCount.get(rk) || 0) + 1)
    }
    for (const [rk, n] of sigCount) if (n > 1) {
        const [route, sig] = rk.split('\x00')
        if (!dupWarn.find((d) => d.route === route && d.sig === sig)) dupWarn.push({ route, sig, n, side: 'baseline' })
    }
    for (const t of baseSorted) {
        const rk = `${t.route}\x00${t.key}`
        const ord = seen.get(rk) || 0
        seen.set(rk, ord + 1)
        BASET.set(`${t.route}\x00${t.key}\x00${ord}`, { ...t, ord })
    }
}

if (dupWarn.length) {
    for (const d of dupWarn) {
        console.error(`⚠ ${d.route} 上有 ${d.n} 张表的表头签名逐字相同(${d.sig})`
            + `${d.side === 'baseline' ? ' —— 基线那一侧' : ''} —— 身份退回【同签名里的第几个】。`)
    }
    console.error('  ☞ 只按签名比会把它们静默错配,报出一次【假的】行高变化(INPUT-1 §6.3 踩过)。')
}

// ── 比:表头高 / 行数 / 最大行高 / 滚动壳内容宽 ──────────────────────────────
const max = (a) => (a && a.length ? Math.round(Math.max(...a) * 100) / 100 : null)
const diffs = []
let compared = 0

for (const [id, b] of BASET) {
    const n = NOWT.get(id)
    const [route, sig, ord] = id.split('\x00')
    if (!n) { diffs.push({ route, sig, ord, what: '整张表不见了', from: `${b.bodyRows} 行`, to: '(没有这张表)' }); continue }
    compared++
    const pairs = [
        ['表头高', b.headH, n.headH],
        ['行数', b.bodyRows, n.nBodyRows],
        ['最大行高', max(b.rowH), max(n.rowH)],
        ['滚动壳内容宽', b.shellScrollW, n.shellScrollW],
    ]
    for (const [what, from, to] of pairs) {
        if (from !== to) diffs.push({ route, sig, ord, what, from, to })
    }
}
for (const [id, n] of NOWT) {
    if (!BASET.has(id)) {
        const [route, sig, ord] = id.split('\x00')
        // 只报【含控件】的新表 —— 基线管的就是这一族
        if (n.nControls > 0) diffs.push({ route, sig, ord, what: '基线里没有这张表', from: '(不在基线里)', to: `${n.nBodyRows} 行 · ${n.nControls} 个控件` })
    }
}

// ── 覆盖断言 ③:比过的表数必须与基线的表数对得上(不含"不见了"的) ──────────
assertPinned(SELF, '基线里的表 ↔ 真的逐项比过的 + 报成不见了的',
    BASET.size, compared + diffs.filter((d) => d.what === '整张表不见了').length,
    '对不上就是上面那个循环漏掉了表。')

// ── 整页横向溢出(390px) ───────────────────────────────────────────────────
const baseOv = new Map(BASE_OVERFLOW.documentOverflow390.map((o) => [o.route, o.docScrollW - o.docClientW]))
const nowOv = new Map()
for (const [route, rec] of Object.entries(PH)) {
    if (!rec) continue
    const over = (rec.docScrollW || 0) - (rec.docClientW || 0)
    if (over > 0) nowOv.set(route, over)
}
const ovDiffs = []
for (const [route, over] of nowOv) {
    if (!baseOv.has(route)) ovDiffs.push({ route, what: '★ 新增的整页横向溢出', from: 0, to: over })
    else if (over > baseOv.get(route)) ovDiffs.push({ route, what: '★ 整页横向溢出长大了', from: baseOv.get(route), to: over })
}
for (const [route, over] of baseOv) {
    if (!nowOv.has(route)) ovDiffs.push({ route, what: '整页横向溢出没有了(不是回归,但要知道)', from: over, to: 0, benign: true })
    else if (nowOv.get(route) < over) ovDiffs.push({ route, what: '整页横向溢出变小了(不是回归,但要知道)', from: over, to: nowOv.get(route), benign: true })
}
assertPopulation(SELF, '基线 §6.3 里记着的整页溢出路由', baseOv.size)

// ── 已按裁定横滚的表:滚动范围不许长 ─────────────────────────────────────────
const scrollDiffs = []
for (const s of BASE_OVERFLOW.tableShellOverflow390) {
    const rec = PH[s.route]
    const tables = (rec && rec.tables) || []
    const same = tables.filter((t) => t.idx === s.idx)
    const t = same[0]
    if (!t) { scrollDiffs.push({ route: s.route, idx: s.idx, what: '这张横滚的表不见了', from: s.shellScrollW, to: null }); continue }
    const wasRange = s.shellScrollW - s.shellW
    const nowRange = (t.shellScrollW || 0) - (t.shellW || 0)
    if (nowRange > wasRange) scrollDiffs.push({ route: s.route, idx: s.idx, what: '★ 滚动范围长了', from: wasRange, to: nowRange })
    else if (nowRange !== wasRange) scrollDiffs.push({ route: s.route, idx: s.idx, what: '滚动范围变小了(不是回归)', from: wasRange, to: nowRange, benign: true })
}
assertPopulation(SELF, '基线 §6.3 里记着的横滚表', BASE_OVERFLOW.tableShellOverflow390.length)

// ── 编辑态(可选) ──────────────────────────────────────────────────────────
const editDiffs = []
let editCompared = 0
if (EDIT_FILE) {
    const ed = JSON.parse(readFileSync(EDIT_FILE, 'utf8'))
    const eph = (ed.routes && ed.routes.phone) || {}
    for (const b of BASE_EDIT) {
        const rec = eph[b.route]
        const tables = (rec && rec.tables) || []
        const t = tables.filter((x) => x.key === b.key)[b.idx] || tables[b.idx]
        if (!t) { editDiffs.push({ route: b.route, what: '编辑态这张表不见了' }); continue }
        editCompared++
        // 基线 §6.2 的字段名是 rowH_editing / shellScrollW_editing;
        // 读数(--mode=edit)量的就是点开之后那一态,所以它那边是裸的 rowH / shellScrollW。
        const pairs = [
            ['编辑态最大行高', max(b.rowH_editing), max(t.rowH)],
            ['编辑态行数', b.rowH_editing.length, t.nBodyRows],
            ['编辑态表头高', b.headH ?? null, t.headH ?? null],
            ['编辑态滚动壳内容宽', b.shellScrollW_editing, t.shellScrollW],
        ]
        for (const [what, from, to] of pairs) if (from !== to) editDiffs.push({ route: b.route, what, from, to })
    }
    assertPinned(SELF, '基线 §6.2 里的编辑态表 ↔ 真的比过的 + 不见了的',
        BASE_EDIT.length, editCompared + editDiffs.filter((d) => d.what === '编辑态这张表不见了').length,
        '对不上就是编辑态那一段漏判了。')
}

// ── 报 ──────────────────────────────────────────────────────────────────────
const hard = [...diffs, ...ovDiffs.filter((d) => !d.benign), ...scrollDiffs.filter((d) => !d.benign), ...editDiffs]
const soft = [...ovDiffs.filter((d) => d.benign), ...scrollDiffs.filter((d) => d.benign)]

console.log('')
console.log(`· 比过的表:${compared} / 基线 ${BASET.size} 张`
    + (EDIT_FILE ? `;编辑态 ${editCompared} / ${BASE_EDIT.length} 张` : ';编辑态 (未给 --edit,没有比)'))
console.log(`· 整页溢出:基线 ${baseOv.size} 条,读数 ${nowOv.size} 条`)
console.log(`· 已裁定横滚的表:${BASE_OVERFLOW.tableShellOverflow390.length} 张`)

if (soft.length) {
    console.log('')
    console.log('· 变小了的(不是回归,登记在案):')
    for (const d of soft) console.log(`    · ${d.route}${d.idx !== undefined ? ' #' + d.idx : ''}:${d.what} ${d.from} → ${d.to}`)
}

if (hard.length) {
    console.error('')
    console.error(`✗ ${SELF}:${hard.length} 处与基线不同`)
    for (const d of hard) {
        const where = `${d.route}${d.ord !== undefined ? ` #${d.ord}` : (d.idx !== undefined ? ` #${d.idx}` : '')}`
        console.error(`   · ${where}:${d.what}  ${d.from} → ${d.to}`)
        if (d.sig) console.error(`       签名 ${d.sig}`)
    }
    console.error('')
    console.error('☞ 委托书 D.3:【不要】回退、不要调表、不要改列宽 —— 停手,把这份读数交回。')
    process.exit(1)
}

console.log('')
console.log(`✓ ${SELF}:${compared} 张含控件的表逐项与基线相同(表头高 · 行数 · 最大行高 · 滚动壳内容宽);`
    + `390px 整页溢出没有新增也没有长大;${BASE_OVERFLOW.tableShellOverflow390.length} 张已裁定横滚的表一张都没有多出滚动范围。`)
