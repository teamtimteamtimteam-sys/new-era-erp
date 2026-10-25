#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// TABLE-FEATURES-1(Tim 2026-10-25 Q10)· 每一处 `<fieldset disabled>` 都经 `<DisabledBlock>`
// ════════════════════════════════════════════════════════════════════════════
// 一处手写的 `<fieldset disabled>` 会把它里面表格的导出 / 排序 / 翻页一起灰掉 ——
// 那正是 EXPORT-DISABLED-ON-ENDED-RECORDS(12 个结束块、5 处缺权限、1 份活着的记录)。
// `app/components/ui/disabled-block.tsx` 让禁用块告诉表格层「你在一块禁用区里」,表格层的只读控件改画成
// fieldset 管不到的 `<span role="button">`。**那个 context 只有经 DisabledBlock 才会被设上** ——
// 所以手写的那一处就是一处悄悄回归。
//
// 【瞄准 · AIM】
//   我读的是      :`app/` 下每一个 .tsx 的源码文本(注释剥掉),里面每一个 `<fieldset …>` 开标签(跨行也认)。
//   我声称管的是   :除 disabled-block.tsx 那唯一一处,没有任何一个 fieldset 开标签带 `disabled`。
//   两者不同之处   :★ 我认的是【字面上的 fieldset 开标签】。一个经 React.createElement('fieldset', { disabled })
//                   造出来的、或者经 {...props} 把 disabled 摊进来的 fieldset,我看不见 ——
//                   今天这两种写法都是 0 处(本支的第二条路数的就是「一切 fieldset 开标签」,含摊开属性的)。
// ════════════════════════════════════════════════════════════════════════════
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join, relative } from 'node:path'
import { assertPopulation, assertPinned } from './lib/selfproof.mjs'

const SELF = 'check-disabled-block'
const ROOT = process.cwd()
const ALLOWED = 'app/components/ui/disabled-block.tsx'

function walk(dir, out = []) {
    for (const n of readdirSync(dir)) {
        if (n === 'node_modules' || n.startsWith('.')) continue
        const p = join(dir, n)
        if (statSync(p).isDirectory()) walk(p, out)
        else if (p.endsWith('.tsx')) out.push(p)
    }
    return out
}

/** 剥注释:块注释与行注释(字符串里的 // 不在这里出现 —— 本支只看 JSX 开标签,它们不在字符串里)。 */
function stripComments(src) {
    return src.replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, ' '))
        .replace(/(^|[^:'"`])\/\/.*$/gm, (m, a) => a)
}

const files = walk(join(ROOT, 'app'))
assertPopulation(SELF, 'app/ 下的 .tsx 文件', files.length)

let tags = 0, roughTags = 0
const bad = []
let allowedHit = 0
for (const f of files) {
    const rel = relative(ROOT, f)
    const src = stripComments(readFileSync(f, 'utf8'))
    // 第二条路:不经判据的粗计数 —— 「<fieldset」后面跟空白或 >
    roughTags += (src.match(/<fieldset(?=[\s>])/g) ?? []).length
    // 判据:整份源码上跑(不按行切 —— AGENTS.md「按行切开再匹配会废掉含 \n 的字符类」)
    for (const m of src.matchAll(/<fieldset\b([^>]*)>/g)) {
        tags++
        if (!/\bdisabled\b/.test(m[1])) continue
        if (rel === ALLOWED) { allowedHit++; continue }
        const line = src.slice(0, m.index).split('\n').length
        bad.push(`${rel}:${line}`)
    }
}

assertPinned(SELF, 'fieldset 开标签', tags, roughTags, '判据与粗计数不一样多 —— 有一种开标签写法判据没认出来')
assertPopulation(SELF, 'disabled-block.tsx 里那唯一一处 fieldset disabled', allowedHit)

if (process.env.CHECK_DISABLED_BLOCK_FAULT === 'inject') bad.push('INJECTED:1')

if (bad.length) {
    console.error(`✗ ${SELF}:${bad.length} 处手写的 <fieldset disabled> 没有经 <DisabledBlock>:`)
    for (const b of bad) console.error(`    ${b}`)
    console.error('  ☞ 换成 app/components/ui/disabled-block.tsx 的 <DisabledBlock disabled={…}> —— 否则里面表格的导出 / 排序 / 翻页会一起灰掉(Tim 2026-10-25 Q10)。')
    process.exit(1)
}
console.log(`✓ ${SELF}:${files.length} 个 .tsx · ${tags} 个 fieldset 开标签 · 带 disabled 的只有 ${ALLOWED} 那一处`)
