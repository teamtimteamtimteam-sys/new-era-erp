#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// BUGFIX-1a(2026-09-12)· 生成出来的 CSS 必须【解析得过】
// ════════════════════════════════════════════════════════════════════════════
// 【它为什么存在,一句话】
//   FONT-2 之后 `next dev` 的**每一条路由都是 HTTP 500**,而弄坏它的不是任何
//   一个页面 —— 是 `docs/handbacks/FONT-2.md` 里的**一句散文**。Tailwind v4 的
//   自动源探测把整个项目(含 `docs/*.md`)当类名来源,于是那句散文被当成一个
//   任意值工具类生成了出来,产出一条 `color:` 值里带着裸星号的非法声明。
//   ☞ **生产构建把同一条降级成一句 warning 就放过了** —— 所以线上是好的,
//     而开发服务器(冒烟与版式探针都跑在它上面)整棵树起不来,**没有任何一道闸
//     问过它**。这一支就是那道闸:**把那句 warning 变成一次失败。**
//
//   ★ 修法那一半(`@import "tailwindcss" source(none)` + 两条 `@source`)写在
//     `app/globals.css` 的抬头里。**这一支不管扫描源限在哪儿**,它只管
//     **生成出来的东西合不合法** —— 换一个别的写法把 CSS 弄坏,它同样会红。
//
// 【它是一道闸】进 `npm run build`,在 `next build` 之前。实测约 1 秒。
//   退出码沿用本仓库三档:0 干净 / 1 找到了违规 / 2 **量具自己坏了**。
//
// ════════════════════════════════════════════════════════════════════════════
// 【瞄准 · AIM】
//   我读的是      :`app/globals.css`,用 `postcss` + `@tailwindcss/postcss`
//                   编译一遍 —— 与 `postcss.config.mjs` 里那唯一一个插件、以及
//                   `next build` 走的是**同一条路**(同一个 cwd、同一个 from)。
//                   然后把编译出来的那段文本交给 **`lightningcss`**(就是
//                   `next build` 用来优化生成 CSS 的那一支)开 `errorRecovery`
//                   解析一遍,收它的 warnings 与 errors。
//   我声称管的是   :「这棵树今天生成出来的应用 CSS,**解析得过**;里面没有
//                   任何一条浏览器读不懂的声明。」
//   两者不同之处   :★★ 这几行要读完再看退出码 ★★
//
//     ① **我只编译 `app/globals.css` 这一个入口。** 别的 CSS(`*.module.css`)
//        由 Next 自己处理,**不经过这里**。它们坏掉我看不见。
//
//     ② **我判的是【解析得过】,不是【长得对】。** 一条语法完全合法、
//        而颜色写错了的规则,我照样放行。这一支不是视觉闸。
//
//     ③ ★ **我看不见"扫描源限窄之后有没有类丢掉"。** 那是一次**比对**
//        (改前 / 改后两套选择器集合),不是一条能在一次运行里回答的判据。
//        ☞ 我只用下面那张【必须生成得出来】的名单兜住最粗的那一档:
//          名单上任何一条不再生成,就说明扫描源塌了 —— 而那正是这一族
//          最可能的下一次事故。
//
//     ④ **`lightningcss` 的 `errorRecovery` 把致命错误降成 warning。**
//        所以我把 warnings 与 errors **一起**当失败,不分轻重 ——
//        AGENTS.md 那条「健康检查的阈值默认应当是零」。
// ════════════════════════════════════════════════════════════════════════════
import { readFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import { assertPopulation, assertPinned, assertAllowlistLive } from './lib/selfproof.mjs'

const SELF = 'check-generated-css'
const ROOT = process.cwd()
const ENTRY = 'app/globals.css'
const require = createRequire(ROOT + '/package.json')
const postcss = require('postcss')
const tailwind = require('@tailwindcss/postcss')
const { transform } = require('lightningcss')

const t0 = Date.now()

// ── ① 编译,与 next build 同一条路 ────────────────────────────────────────────
const source = readFileSync(ENTRY, 'utf8')
let result
try {
    result = await postcss([tailwind()]).process(source, { from: ENTRY, to: null })
} catch (e) {
    console.error(`✗ ${SELF}:${ENTRY} 编译不过 —— ${e.message}`)
    process.exit(1)
}
const css = result.css

// ── ② 覆盖断言:一次什么都没编译出来的运行,不算一次干净 ─────────────────────
const root = postcss.parse(css)
let rules = 0, decls = 0
root.walkRules(() => rules++)
root.walkDecls(() => decls++)
// 第二条【独立】的路:按文本数一遍规则开头。它不走 postcss 的 AST,
// 所以 postcss 那一侧瞎掉时两个数会当场分家。
const lineRules = css.split('\n').filter((l) => /^\s*[^@\s/][^{}]*\{\s*$/.test(l)).length
assertPopulation(SELF, `${ENTRY} 生成出来的声明`, decls)
assertPinned(SELF, '按 AST 数出的规则 ↔ 按文本数出的规则', rules, lineRules,
    '对不上就是两条路里有一条看错了这段 CSS,于是下面每一条判据都不作数。')

// ★ 【必须生成得出来】的名单 —— 它顺带守住「扫描源还看得见 app/」这件事。
//   这些类在 app/ 下各有成百上千个站点;它们一起消失只有一个解释:
//   `@source` 塌了(或者 Tailwind 换了行为)。**两种都要红。**
const MUST_GENERATE = ['.flex', '.text-sm', '.rounded-lg', '.font-medium', '.border']
assertAllowlistLive(SELF, '必须生成得出来的工具类', MUST_GENERATE,
    (sel) => new RegExp(`(^|[,\\s{])${sel.replace('.', '\\.')}(?![\\w-])`, 'm').test(css),
    (sel) => `${sel} —— app/ 下有大量站点,它不再生成 = 扫描源塌了`)

// ── ③ 判据:生成出来的 CSS 解析得过吗 ────────────────────────────────────────
const problems = []
for (const w of result.warnings()) problems.push(`postcss warning:${w.toString()}`)

let ln
try {
    ln = transform({ filename: ENTRY, code: Buffer.from(css), minify: false, errorRecovery: true })
} catch (e) {
    // errorRecovery 之下还抛,就是整段解析不下去
    console.error(`✗ ${SELF}:lightningcss 解析生成出来的 CSS 时直接抛了 —— ${e.message}`)
    process.exit(1)
}
for (const w of ln.warnings || []) {
    const at = w.loc ? `${ENTRY}(生成后)第 ${w.loc.line} 行第 ${w.loc.column} 列` : '位置不明'
    problems.push(`lightningcss ${w.type || 'warning'}:${w.message} —— ${at}`)
}

const ms = Date.now() - t0
if (problems.length) {
    console.error(`✗ ${SELF}:生成出来的 CSS 有 ${problems.length} 处解析不过(${decls} 条声明 / ${rules} 条规则,${ms}ms)`)
    for (const p of problems) console.error(`   · ${p}`)
    console.error('')
    console.error('【怎么查】非法声明多半【不是写在任何一个页面里的】——')
    console.error('  Tailwind v4 会把 `@source` 指到的每一个文件里长得像类名的字符串')
    console.error('  当成一个工具类生成出来。先看上面那个行号附近生成出来的是哪个类,')
    console.error('  再 `git grep` 那个类名:它多半住在一段散文、一句注释或一份说明里。')
    console.error('  ☞ 修法是把那段文字改掉,或者把那个目录从 `app/globals.css` 的')
    console.error('    `@source` 里拿掉 —— 【不要】为了让这道闸变绿去删生成出来的 CSS。')
    process.exit(1)
}
console.log(`✓ ${SELF}:${ENTRY} 生成出 ${rules} 条规则 / ${decls} 条声明,` +
    `postcss 与 lightningcss 两支解析器都没有一条告警(${ms}ms)。`)
