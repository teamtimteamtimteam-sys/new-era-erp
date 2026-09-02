#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// 声明级视觉证明 —— 【187 页没有变】是量出来的,不是声称的
// ════════════════════════════════════════════════════════════════════════════
// 形状取自 BRAND-1(2026-09-02)那次:用 postcss 解析【构建产物里的 CSS】,
// 把每一条声明按「上下文 + 选择器 + 属性」建索引,再逐条比对两棵树。
// 判据只有一条,而且它比"看三个页面"强得多:
//   **既有的每一条声明,值不许变、也不许消失。新增多少条都可以。**
//   一条新增的声明只能通过一个【新的类名】生效,而新类名有 check-base-isolation.mjs
//   守着"没有任何既有页面用到它"。两条合起来,才是"没有一页变了"的完整证明。
//
// 【BRAND-1 记过的一个教训,这里照它办】第一版比对脚本手搓花括号切分,
// @layer 嵌套把选择器错配,吐出一串解析假象,把真正那条改动淹掉了。
// **一个吵闹的检查和一个瞎掉的检查一样坏** —— 所以这里用 postcss 真解析。
//
// 用法:node scripts/check-css-declarations.mjs <before-dir> <after-dir>
// ════════════════════════════════════════════════════════════════════════════

import { readFileSync, readdirSync } from 'node:fs'
import { join } from 'node:path'
import postcss from 'postcss'

const [beforeDir, afterDir] = process.argv.slice(2)
if (!beforeDir || !afterDir) {
    console.error('用法:node scripts/check-css-declarations.mjs <before-dir> <after-dir>')
    process.exit(2)
}

const cssOf = (root) => {
    const dir = join(root, '.next/static/chunks')
    return readdirSync(dir).filter((f) => f.endsWith('.css'))
        .map((f) => readFileSync(join(dir, f), 'utf8')).join('\n')
}

/** 上下文 = 一路向上的 at-rule(@media/@layer/@supports),让同名选择器在不同媒体查询里不会撞。 */
const ctxOf = (node) => {
    const parts = []
    for (let p = node.parent; p && p.type !== 'root'; p = p.parent) {
        if (p.type === 'atrule') parts.unshift(`@${p.name} ${p.params}`)
        else if (p.type === 'rule') parts.unshift(p.selector)
    }
    return parts.join(' ⟩ ')
}

// ★ @font-face 要【按块】认,不能按属性摊平 ★
// 第一版把所有 @font-face 的声明摊进同一个桶(它们的上下文字符串都是 "@font-face"),
// 于是【两次构建里字体块的先后顺序不同】就被报成 4 条"改了值" ——
// 而字体一个字节都没变。这正是 BRAND-1 记过的那个教训:
// **一个吵闹的检查和一个瞎掉的检查一样坏**,它会让人学会忽略输出。
// 处置:每个 @font-face 用它自己的 family/weight/style/unicode-range 做身份,
// 那四个值唯一确定一个字体面;顺序因此不再进入判据(顺序本来也不影响渲染 ——
// 只有 family+weight+style 完全相同的两个块才会互相覆盖,而那是另一种缺陷)。
const faceId = (rule) => {
    const g = (prop) => rule.nodes?.find((n) => n.type === 'decl' && n.prop === prop)?.value?.trim() ?? ''
    return `@font-face[${g('font-family')}|${g('font-weight')}|${g('font-style')}|${g('unicode-range')}]`
}

const index = (css) => {
    const m = new Map()
    postcss.parse(css).walkDecls((d) => {
        const inFace = d.parent?.type === 'atrule' && d.parent.name === 'font-face'
        const key = inFace ? `${faceId(d.parent)} ⟩ ${d.prop}` : `${ctxOf(d)} ⟩ ${d.prop}`
        // 同一处可以重复声明同一属性(层叠),所以值收成数组按顺序比。
        if (!m.has(key)) m.set(key, [])
        m.get(key).push(d.value.trim())
    })
    return m
}

const before = index(cssOf(beforeDir))
const after = index(cssOf(afterDir))

const changed = []
const vanished = []
for (const [k, vs] of before) {
    if (!after.has(k)) { vanished.push(k); continue }
    const now = after.get(k)
    if (JSON.stringify(now) !== JSON.stringify(vs)) changed.push({ k, was: vs, now })
}
let added = 0
for (const k of after.keys()) if (!before.has(k)) added++

const countDecls = (m) => [...m.values()].reduce((n, v) => n + v.length, 0)

console.log(`既有声明 ${countDecls(before)} 条(${before.size} 个「上下文+属性」位)`)
console.log(`  改了值 : ${changed.length}`)
console.log(`  消失了 : ${vanished.length}`)
console.log(`  新增   : +${added} 个位(${countDecls(after) - countDecls(before)} 条声明净增)`)

if (changed.length || vanished.length) {
    console.error('\n✗ 既有声明被动过了 —— 这意味着某个已上线页面的样子【真的变了】:')
    for (const c of changed.slice(0, 40)) console.error(`   改值  ${c.k}\n         ${c.was} → ${c.now}`)
    for (const v of vanished.slice(0, 40)) console.error(`   消失  ${v}`)
    process.exit(1)
}
console.log('\n✓ 既有声明 0 改值、0 消失 —— 新增的都只能通过新类名生效,')
console.log('  而 check-base-isolation.mjs 已经证过没有任何既有页面用到那些新类名。')
process.exit(0)
