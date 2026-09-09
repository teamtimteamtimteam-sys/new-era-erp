#!/usr/bin/env node
// scripts/check-lint.mjs — eslint 的问题数【只许降,不许升】。
//
// ════════════════════════════════════════════════════════════════════════════
// 【为什么需要这一支:那 130 个问题从来没有让任何一次构建变红过】
// ════════════════════════════════════════════════════════════════════════════
// `npm run lint`(= `eslint`)一直都在,`eslint.config.mjs` 也一直都在。
// 但 **`next@16` 的 `next build` 不再自动跑 eslint**(Next 15 起的变更),
// 而 `next.config.ts` 里一个 eslint 设定都没有。于是:
//   **仓库里 42 个 error 与 88 个 warning,没有一个拦过任何人。**
// 一道没有人跑的检查,与一道不存在的检查,代价完全一样 —— 这一支把它接进构建。
//
// ════════════════════════════════════════════════════════════════════════════
// ★★【冻结,不是修复 —— 这两件事【故意】没有混在一起】★★
// ════════════════════════════════════════════════════════════════════════════
// 本刀【一个都不修】。混在一起做,绿灯两件事都证明不了:
// 看见绿的人分不清是"没有新增违规"还是"旧的被顺手改掉了"。
// 先把数钉死,再另开一刀去减 —— 那一刀的绿灯才有意义。
//
// ════════════════════════════════════════════════════════════════════════════
// ★★【为什么 error 与 warning 分开记两个数】★★
// ════════════════════════════════════════════════════════════════════════════
// 只冻 error(42)会让**最容易长的那一类完全不设防**:
// 这棵树上 `@typescript-eslint/no-unused-vars` 一条就有 63 个 warning。
// 一道只盯 error 的闸对它是瞎的 —— **那是一道开着后门的冻结。**
// 所以两个数各记各的,**各自只许降**。
//
// ════════════════════════════════════════════════════════════════════════════
// ★【键是【文件 + 规则】,【不是】行号 —— 这一条是刻意的】★
// ════════════════════════════════════════════════════════════════════════════
// 行号随每一次编辑漂:在文件顶上加一行注释,底下几十条基线全部对不上,
// 闸第二天就开始假红,而一道天天假红的闸三刀之内会被人关掉。
// `文件 + 规则 -> 计数` 对【同一文件同一规则多出一处】敏感(该红),
// 对【整块代码上下平移】不敏感(不该红)。
//   ✗ 它看不见:同一文件同一规则里,一处违规被修好、另一处被新加(净额为零)。
//     那是这个口径【已知的洞】,写在这里而不是等下一个人踩到。
//
// ════════════════════════════════════════════════════════════════════════════
// 【瞄准 · AIM】
//   我读的是      :`new ESLint({ cwd: ROOT }).lintFiles(['.'])` 回来的结果数组
//                   —— 也就是**eslint 自己决定要看哪些文件**之后的产物。
//   我声称管的是  :这棵树上的 eslint 问题数只降不升。
//   两者不同之处  :★ **我读的那份清单,由 `eslint.config.mjs` 与它的 ignores 决定,
//                   而我对那份清单一个字都没有验过。** 一次让 eslint 少看几个目录
//                   的配置改动,在我这里长得【和有人把问题修好了一模一样】——
//                   两者都表现为"某个文件+规则的计数掉到 0"。
//                   ☞ 下面的覆盖断言就是为这一句写的。
//
// ════════════════════════════════════════════════════════════════════════════
// ★★【NARROW-COVERAGE-1(2026-09-09)补的覆盖断言 —— 它此前是全库最大的一个洞】★★
// ════════════════════════════════════════════════════════════════════════════
// 原来的判据只看三件事:有没有【新的】文件+规则、有没有【变多】、总数有没有升。
// **三件在 eslint 一个文件都没看的时候【全部为假】** ——
//   added = []、risen = []、totalsRose = (0 > 42) = false,
// 于是它印「✓ 没有新增的 eslint 问题。」并 **exit 0**。
// **一次完全瞎掉的 eslint,能通过这道冻结 42/88 的闸。**
// 而这道闸是整条构建链上最不能瞎的一道:本仓库每一刀都拿它的绿灯当"没加新债"的证明。
//
// 【两条断言,各治一半】
//   ① 它到底看了几个文件?0 个 = 瞎了,不是树干净了。
//   ② **基线本身就是一组"已知必然被看到"的探针。** 基线里点名的每一个文件,
//      这一次都必须真的被 lint 到。看不到,只有两种可能而它们在输出上分不开:
//      那个文件没了(基线过期,`--update-baseline`),或者 eslint 不再看它了。
//      这一条与 check-base-isolation:160 的 `known !== KNOWN_CONVERSIONS.size`
//      是同一个做法 —— 那一处已经上线,这里只是把它推广过来。
//
// 用法:
//   node scripts/check-lint.mjs                    # 闸(进 npm run build)
//   node scripts/check-lint.mjs --update-baseline  # 收紧基线(只在干净树上做)
// ════════════════════════════════════════════════════════════════════════════
import { ESLint } from 'eslint'
import { readFileSync, writeFileSync, existsSync } from 'node:fs'
import { join, relative } from 'node:path'
import { assertAllowlistLive, assertPopulation } from './lib/selfproof.mjs'

const ROOT = process.cwd()
const BASELINE = join(ROOT, 'scripts', 'lint-baseline.json')
const UPDATE = process.argv.includes('--update-baseline')
const SEP = ' :: '

const NOTE = '★ 这份基线【只会缩短】,不会变长。键是【文件路径 + 规则名】,不是行号(行号随每次编辑漂,会让闸天天假红)。error 与 warning 【各记一个数,各自只许降】—— 只冻 error 会让 no-unused-vars 那 63 个 warning 完全不设防,那是一道开着后门的冻结。多一处 → 闸变红并点名文件与规则;少一处 → 用 --update-baseline 顺手收紧。它不是白名单:白名单随新债增长,基线随还债缩短。本刀(PERM-CODE-1 + LINT-FREEZE-1,2026-09-09)只冻结,【一个都没有修】。'

// ── 量 ──────────────────────────────────────────────────────────────────────
const eslint = new ESLint({ cwd: ROOT })
const results = await eslint.lintFiles(['.'])

// ── 覆盖断言 ① ──────────────────────────────────────────────────────────────
// eslint 到底看了几个文件?一个都没看时,下面每一条判据都为假,而闸会变绿。
const lintedFiles = new Set(results.map((r) => relative(ROOT, r.filePath)))
assertPopulation('check-lint', 'eslint 实际 lint 到的文件', lintedFiles.size)

/** `${file}${SEP}${rule}` -> { errors, warnings } */
const now = new Map()
let totErr = 0
let totWarn = 0
for (const r of results) {
    const file = relative(ROOT, r.filePath)
    for (const m of r.messages) {
        // ruleId 为空的两种:未被使用的 eslint-disable 指令,以及解析失败。
        const rule = m.ruleId ?? (m.fatal ? '<parse-error>' : '<unused-eslint-disable>')
        const k = file + SEP + rule
        const c = now.get(k) ?? { errors: 0, warnings: 0 }
        if (m.severity === 2) { c.errors++; totErr++ } else { c.warnings++; totWarn++ }
        now.set(k, c)
    }
}

const splitKey = (k) => {
    const i = k.lastIndexOf(SEP)
    return [k.slice(0, i), k.slice(i + SEP.length)]
}

const asObject = () => {
    const entries = {}
    for (const k of [...now.keys()].sort()) {
        const [file, rule] = splitKey(k)
        ;(entries[file] ??= {})[rule] = now.get(k)
    }
    return { __NOTE__: NOTE, totals: { errors: totErr, warnings: totWarn }, entries }
}

// ── 写基线 ──────────────────────────────────────────────────────────────────
if (UPDATE || !existsSync(BASELINE)) {
    writeFileSync(BASELINE, JSON.stringify(asObject(), null, 2) + '\n')
    console.log(`✓ 基线已写入 scripts/lint-baseline.json —— error ${totErr} · warning ${totWarn}`)
    console.log(`  ${now.size} 条【文件 + 规则】。`)
    process.exit(0)
}

// ── 比 ──────────────────────────────────────────────────────────────────────
const base = JSON.parse(readFileSync(BASELINE, 'utf8'))
const baseAt = (file, rule) => base.entries?.[file]?.[rule] ?? { errors: 0, warnings: 0 }

// ── 覆盖断言 ② ──────────────────────────────────────────────────────────────
// 基线里点名的每一个文件,这一次都必须真的被 lint 到。
// 【为什么这一条比"总数没升"硬】总数没升在 eslint 少看了几个目录的时候【也成立】,
// 而且那时它还顺手把那些文件报成"债还掉了"(fallen),读起来像好消息。
const baseFiles = Object.keys(base.entries ?? {})
assertPopulation('check-lint', '基线里点名的文件', baseFiles.length)
assertAllowlistLive(
    'check-lint',
    '基线文件的可见性(每一个都该被 lint 到)',
    baseFiles,
    (f) => lintedFiles.has(f),
    (f) => `${f} —— 基线记着它有 eslint 问题,而这一次 eslint 【没有看它】`,
)

const risen = []
const added = []
const fallen = []
for (const [k, c] of now) {
    const [file, rule] = splitKey(k)
    const b = baseAt(file, rule)
    if (b.errors === 0 && b.warnings === 0) added.push({ file, rule, ...c })
    else if (c.errors > b.errors || c.warnings > b.warnings) risen.push({ file, rule, was: b, now: c })
    else if (c.errors < b.errors || c.warnings < b.warnings) fallen.push({ file, rule, was: b, now: c })
}
for (const [file, rules] of Object.entries(base.entries ?? {})) {
    for (const [rule, b] of Object.entries(rules)) {
        if (!now.has(file + SEP + rule)) fallen.push({ file, rule, was: b, now: { errors: 0, warnings: 0 } })
    }
}

const bt = base.totals ?? { errors: 0, warnings: 0 }
const totalsRose = totErr > bt.errors || totWarn > bt.warnings

console.log('── eslint 冻结闸 ─────────────────────────────────────────────')
console.log(`基线  error ${bt.errors} · warning ${bt.warnings}`)
console.log(`现在  error ${totErr} · warning ${totWarn}`)

let red = 0

if (added.length) {
    red++
    console.log(`\n✗ ${added.length} 条【新的】文件+规则组合 —— 基线里没有它:`)
    for (const a of added) console.log(`   ${a.file}  ${a.rule}  error ${a.errors} · warning ${a.warnings}`)
}
if (risen.length) {
    red++
    console.log(`\n✗ ${risen.length} 条数变多了:`)
    for (const r of risen) console.log(`   ${r.file}  ${r.rule}  error ${r.was.errors}→${r.now.errors} · warning ${r.was.warnings}→${r.now.warnings}`)
}
if (totalsRose) {
    red++
    console.log(`\n✗ 总数上升:error ${bt.errors}→${totErr} · warning ${bt.warnings}→${totWarn}`)
}

if (fallen.length) {
    console.log(`\n· ${fallen.length} 条变少了 —— 有人还了债。基线可以收紧:`)
    for (const f of fallen.slice(0, 20)) console.log(`    ${f.file}  ${f.rule}  error ${f.was.errors}→${f.now.errors} · warning ${f.was.warnings}→${f.now.warnings}`)
    if (fallen.length > 20) console.log(`    …… 另有 ${fallen.length - 20} 条`)
    console.log('  收紧:node scripts/check-lint.mjs --update-baseline')
}

if (red) {
    console.log('\n☞ 这一支【不修】任何东西,它只拦【新增】。修旧的那 130 个是另一刀的事。')
    console.log('  要看具体是哪一行:npm run lint')
} else {
    console.log('\n✓ 没有新增的 eslint 问题。')
}
process.exit(red ? 1 : 0)
