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
// 用法:
//   node scripts/check-lint.mjs                    # 闸(进 npm run build)
//   node scripts/check-lint.mjs --update-baseline  # 收紧基线(只在干净树上做)
// ════════════════════════════════════════════════════════════════════════════
import { ESLint } from 'eslint'
import { readFileSync, writeFileSync, existsSync } from 'node:fs'
import { join, relative } from 'node:path'

const ROOT = process.cwd()
const BASELINE = join(ROOT, 'scripts', 'lint-baseline.json')
const UPDATE = process.argv.includes('--update-baseline')
const SEP = ' :: '

const NOTE = '★ 这份基线【只会缩短】,不会变长。键是【文件路径 + 规则名】,不是行号(行号随每次编辑漂,会让闸天天假红)。error 与 warning 【各记一个数,各自只许降】—— 只冻 error 会让 no-unused-vars 那 63 个 warning 完全不设防,那是一道开着后门的冻结。多一处 → 闸变红并点名文件与规则;少一处 → 用 --update-baseline 顺手收紧。它不是白名单:白名单随新债增长,基线随还债缩短。本刀(PERM-CODE-1 + LINT-FREEZE-1,2026-09-09)只冻结,【一个都没有修】。'

// ── 量 ──────────────────────────────────────────────────────────────────────
const eslint = new ESLint({ cwd: ROOT })
const results = await eslint.lintFiles(['.'])

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
