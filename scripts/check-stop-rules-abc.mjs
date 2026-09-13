#!/usr/bin/env node
// scripts/check-stop-rules-abc.mjs
// ════════════════════════════════════════════════════════════════════════════
// SEARCH-1 · 停止条件 (a)(b)(c) 的比对器 —— 读两份 `--mode=drift` 的读数
// ════════════════════════════════════════════════════════════════════════════
//
// 【为什么它进仓库,而它的前四个同类没有】BTN-SIZE-1 的交回报告 §8.4 记着:
//   「这已经是第五支一次性探针」—— round 1 · FONT-1 · INPUT-3 · POLISH-1 r3 ·
//   BTN-SIZE-1,**五刀各写一遍同一个比对器,五次都没有进仓库**。
//   而这一族的停止条件(a)(b)(c) 是**每一刀都要跑的**,它们的判据也一字未变。
//   ☞ 一件每刀都要做、而且每刀都重写一遍的事,该被写成机制。这一支就是。
//
// 【它读什么】`scripts/survey-controls.mjs --mode=drift` 产出的两份 JSON
//   (`controls-drift-baseline.json`)。它自己【不开浏览器、不连库、不持锁】,
//   所以它可以在任何时候重跑,也可以对着历史读数重跑。
//
// ── 三条判据,逐字来自委托书 ────────────────────────────────────────────────
//   (a) 一条 390px 上【本来 0 溢出】的路由,溢出升到 0 以上;
//   (b) 【本来就在溢出】的那几条里,任何一条【长大】;
//   (c) 一张【不横滚】的表开始横滚,或者一张【已经在横滚】的表【滚动范围变大】。
//
// ★【(a) 与 (b) 是同一个量的两侧,所以它们由【改前的读数】分组,不由一张名单分组】★
//   写死一张"这 5 条本来就在溢出"的名单,会在下一刀树变了的时候悄悄过期
//   —— 而它过期的样子是:一条新溢出的路由被当成"本来就在溢出的那一条",
//   于是 (a) 放它过去。**分组由改前那份读数当场算出来。**
//
// ════════════════════════════════════════════════════════════════════════════
// 【瞄准 · AIM】
//   我读的是      :两份 `--mode=drift` 的 JSON —— 每条路由每个视口的
//                   `docScrollW` / `docClientW`,以及每张表的
//                   `overflowsShell` / `shellScrollW` / `shellW` / `tableW`。
//   我声称管的是   :(a)(b)(c) 三条停止条件,在【两份读数都覆盖到的那些路由】上。
//   两者不同之处   :★ **我的分母是那两份 JSON,不是"全站"。**
//                   `--mode=drift` 只走静态路由(58 条带 [id] 的一条都不走),
//                   而且只量首屏 —— 一个点开之后才溢出的面板,它看不见。
//                   ★ 我也**不判它好不好看**:三条都是机制,不是品味。
// ════════════════════════════════════════════════════════════════════════════
//
// 用法:node scripts/check-stop-rules-abc.mjs --a=<改前.json> --b=<改后.json>
// 退出码:0 一条都没踩 · 1 踩了 · 2 量具自己坏了(覆盖断言失败)
import { readFileSync } from 'node:fs'
import { assertPopulation, assertPinned } from './lib/selfproof.mjs'

const SELF = 'check-stop-rules-abc'
const arg = (k) => (process.argv.find((a) => a.startsWith(k + '=')) || '').split('=')[1]
const fa = arg('--a'), fb = arg('--b')
if (!fa || !fb) {
    console.error('用法:node scripts/check-stop-rules-abc.mjs --a=<改前.json> --b=<改后.json>')
    process.exit(2)
}
const A = JSON.parse(readFileSync(fa, 'utf8'))
const B = JSON.parse(readFileSync(fb, 'utf8'))

/** 这条路由这个视口,整页横向溢出多少像素。量不到就是 null。 */
function overflowOf(r) {
    if (!r || r.failed) return null
    if (typeof r.docScrollW !== 'number' || typeof r.docClientW !== 'number') return null
    return Math.max(0, r.docScrollW - r.docClientW)
}

/** 一张表的身份 = 它自己的签名(表头文字),**不是序号** ——
 *  序号会因为页面上多一张表而整体错位,于是"这张表变了"读成"每一张都变了"。 */
const tableKeyOf = (t) => t.key

const problems = []
const notes = []
let routesCompared = 0
let tablesCompared = 0
let fieldComparisons = 0
let blindRoutes = 0

const viewports = [...new Set([...Object.keys(A.routes || {}), ...Object.keys(B.routes || {})])]
assertPopulation(SELF, '两份读数里的视口', viewports.length)

// ★【(b) 的名单是【算出来的】】改前 >0 的那些,就是"本来就在溢出"的那些。
const alreadyOverflowing = new Map() // `${vp}|${route}` -> px
for (const vp of viewports) {
    for (const [route, r] of Object.entries(A.routes?.[vp] ?? {})) {
        const o = overflowOf(r)
        if (o !== null && o > 0) alreadyOverflowing.set(`${vp}|${route}`, o)
    }
}

for (const vp of viewports) {
    const ra = A.routes?.[vp] ?? {}
    const rb = B.routes?.[vp] ?? {}
    const routes = [...new Set([...Object.keys(ra), ...Object.keys(rb)])]
    for (const route of routes) {
        const a = ra[route], b = rb[route]
        // ★ 一条只有一侧量到的路由【不是"没变"】—— 它是"我没量到",两者必须分开。
        if (!a || !b || a.failed || b.failed) {
            blindRoutes++
            notes.push(`${vp} ${route}:只有一侧量到(改前 ${a ? (a.failed ? 'failed' : 'ok') : '缺'} · 改后 ${b ? (b.failed ? 'failed' : 'ok') : '缺'})—— 这一格【不作数】,不是"没变"`)
            continue
        }
        routesCompared++

        // ── (a)(b) 整页横向溢出 ────────────────────────────────────────────
        const oa = overflowOf(a), ob = overflowOf(b)
        fieldComparisons++
        if (oa !== null && ob !== null) {
            if (oa === 0 && ob > 0) {
                problems.push({
                    rule: '(a)',
                    msg: `${vp} ${route}:整页横向溢出 0 → ${ob}px —— 一条本来不横滚的路由开始横滚了。`,
                })
            } else if (oa > 0 && ob > oa) {
                problems.push({
                    rule: '(b)',
                    msg: `${vp} ${route}:整页横向溢出 ${oa} → ${ob}px(+${ob - oa})—— 一条本来就在溢出的路由长大了。`,
                })
            } else if (oa > 0 && ob < oa) {
                notes.push(`${vp} ${route}:整页横向溢出 ${oa} → ${ob}px(−${oa - ob})—— 变小了,不是停止条件,记一笔。`)
            }
        }

        // ── (c) 表:开始横滚 / 滚动范围变大 ────────────────────────────────
        const ta = new Map((a.tables ?? []).map((t) => [tableKeyOf(t), t]))
        const tb = new Map((b.tables ?? []).map((t) => [tableKeyOf(t), t]))
        for (const [key, t1] of ta) {
            const t2 = tb.get(key)
            if (!t2) {
                notes.push(`${vp} ${route}:表「${key.slice(0, 48)}」改后不在了 —— 这一格不作数`)
                continue
            }
            tablesCompared++
            // ① 不横滚 → 横滚
            fieldComparisons++
            if (t1.overflowsShell === false && t2.overflowsShell === true) {
                problems.push({
                    rule: '(c)',
                    msg: `${vp} ${route}:表「${key.slice(0, 48)}」从【不横滚】变成【横滚】。`,
                })
            }
            // ② 已经在横滚 → 滚动范围变大
            const r1 = (typeof t1.shellScrollW === 'number' && typeof t1.shellW === 'number')
                ? Math.max(0, t1.shellScrollW - t1.shellW) : null
            const r2 = (typeof t2.shellScrollW === 'number' && typeof t2.shellW === 'number')
                ? Math.max(0, t2.shellScrollW - t2.shellW) : null
            fieldComparisons++
            if (r1 !== null && r2 !== null && r1 > 0 && r2 > r1) {
                problems.push({
                    rule: '(c)',
                    msg: `${vp} ${route}:表「${key.slice(0, 48)}」滚动范围 ${r1} → ${r2}px(+${r2 - r1})。`,
                })
            }
        }
    }
}

// ════════════════════════════════════════════════════════════════════════════
// ★★【覆盖率本身是一条断言 —— 一个瞎掉的比对器必须说「我瞎了」】★★
// ════════════════════════════════════════════════════════════════════════════
//   AGENTS.md:「凡是『扫一遍、抽出 N 处、逐处判』的检查,N 本身必须是一条断言。」
//   这里的 N 有三个,而它们【各自独立地】会掉到 0:
//     · routesCompared —— 两份 JSON 的路由集合对不上,或者结构变了;
//     · tablesCompared —— tables 那一段没解析到(比如字段改名);
//     · fieldComparisons —— 上面两者任一为 0 时它也为 0,但它还能抓住
//       "路由在、表在、而每一格比较都被跳过了"那一种。
// ════════════════════════════════════════════════════════════════════════════
// ★★★【SEARCH-3(2026-09-13):(b) 点名的那几条,必须【逐条证明它被量过】】★★★
// ════════════════════════════════════════════════════════════════════════════
//   SEARCH-2b 实测撞上过这一幕,而它当时是靠**人眼读 notes** 接住的:
//   改后那一趟 `phone /finance/freight/new` 整格 `failed`(渲染器卡死),
//   于是它落进 `blindRoutes`、只出现在 notes 里,**而退出码照样是 0**。
//   ☞ 那个 0 的意思是「比过的都没踩」,**不是**「那条路由没长大」——
//     而 `/finance/freight/new` 正是 (b) 点名的 5 条之一。
//
//   ★ 本仓库对这一族有明文:**一份「0 个不合规」的读数,它的分母是【它量过的
//     那些】**;以及「覆盖率本身必须是一条断言 —— 一个瞎掉的检查必须说『我瞎了』」。
//   ☞ 所以这里不再只是打印一行提示:**改前已经在溢出的每一条路由,两侧都必须
//     量到。少一条 → 退 2(量具瞎了),而不是退 0(干净)。**
//   ⚠ 判据用的是【改前那份读数算出来的名单】,不是一张写死的 5 条清单 ——
//     写死的名单会在树变了的那天悄悄过期,而它过期的样子正是这条断言要防的。
const notMeasured = [...alreadyOverflowing.keys()].filter((k) => {
    const [vp, route] = [k.slice(0, k.indexOf('|')), k.slice(k.indexOf('|') + 1)]
    const a = A.routes?.[vp]?.[route], b = B.routes?.[vp]?.[route]
    return !a || !b || a.failed || b.failed
})
if (notMeasured.length) {
    console.error(`✗ ${SELF}:**覆盖断言失败 —— 这一次读数不作数。**`)
    console.error(`    (b) 点名的「改前就在溢出」的路由共 ${alreadyOverflowing.size} 条,`
        + `其中 ${notMeasured.length} 条【只有一侧量到】:`)
    for (const k of notMeasured) console.error(`      · ${k}`)
    console.error(`  ☞ 一个绿色的退出码在这里会读成「它没长大」,而真相是「我没量它」。`)
    console.error(`  ☞ 修法:对这几条定点复读(survey-controls --mode=drift --only=…)再合并回来。`)
    process.exit(2)
}
console.log(`   ★ (b) 点名的 ${alreadyOverflowing.size} 条【两侧都量到了】—— 逐条断言过,不是打印过。`)

assertPopulation(SELF, '两侧都量到的路由×视口', routesCompared)
assertPopulation(SELF, '两侧都量到的表', tablesCompared)
assertPopulation(SELF, '字段比较次数', fieldComparisons)
// ★ 双向钉住:比对到的路由数,对上一条【不经过比对循环】的独立计数。
const independentRouteCount = viewports.reduce(
    (n, vp) => n + Object.keys(A.routes?.[vp] ?? {}).filter(
        (r) => B.routes?.[vp]?.[r] && !A.routes[vp][r].failed && !B.routes[vp][r].failed).length, 0)
assertPinned(SELF, '两侧都量到的路由×视口', routesCompared, independentRouteCount,
    '比对循环与一条不经过它的粗计数必须给出同一个数。')

console.log(`== 停止条件 (a)(b)(c) ==`)
console.log(`   视口 ${viewports.length} 个(${viewports.join(' / ')})`)
console.log(`   路由×视口 ${routesCompared} 组比过 · 表 ${tablesCompared} 张比过 · 字段比较 ${fieldComparisons} 次`)
console.log(`   改前就在溢出的:${alreadyOverflowing.size} 组 —— ${[...alreadyOverflowing].map(([k, v]) => `${k}=${v}px`).join(' · ') || '(无)'}`)
if (blindRoutes) console.log(`   ⚠ 只有一侧量到、因此【不作数】的:${blindRoutes} 组`)
for (const n of notes) console.log(`   · ${n}`)

if (problems.length === 0) {
    console.log(`\n✓ (a)(b)(c) 一条都没踩。`)
    process.exit(0)
}
console.log('')
console.error(`✗ 踩了 ${problems.length} 处停止条件:`)
for (const p of problems) console.error(`   [${p.rule}] ${p.msg}`)
process.exit(1)
