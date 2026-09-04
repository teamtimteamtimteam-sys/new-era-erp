#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// 出口检查 —— 「这一页唯一能动手的地方,会不会住在一个被空态吃掉的分支里」
//
// ★ 为什么它是一个【普查】而不是一道【闸】★
//   它找得到的是「一个动作住在一个空集形状的条件里」,而那件事**本身不是缺陷**:
//   守卫住【指向 X 的链接】而 X 不存在,是不画死链,对的;
//   守卫住【创建 X 的按钮】,才是藏出口。**这两者的差别机器分不出来,人分得出。**
//   所以它印出来给人判,不 exit 1 —— 一道会对着正确代码变红的闸,
//   两刀之内就会被人加白名单绕过去,那比没有更坏。
//
// ★ 判据为什么按【括号栈】而不是 grep ★
//   grep '\.length.*&&' 只认 `&&` 守卫那一种形状,漏掉三元的 else 分支。
//   CONV-10 实测:grep 得 5 处,括号栈得 3 处【真的包住动作的】,
//   而其中一处(credit-notes 的三元 else)grep 【看不见】。
//
//   用法:node scripts/survey-hidden-exits.mjs <file|dir> ...
//         不给参数就扫 app/ 下所有详情页(路由末段是 [param])
// ════════════════════════════════════════════════════════════════════════════
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)))
const ACTION = /<Link\b|<button\b|<form\b|<a\s|<input\b|<select\b|<textarea\b|<\w*(Control|Controls|Panel|Editor|Actions|Button|Form)\b/
// 「空集形状」:说的是一个集合空不空,而不是一条记录处于什么状态。
// (`status === 'posted'` 这种【不算】—— 那是记录的属性,本来就该分支。)
const EMPTY = /\.length\b|\.size\b|^\s*!\w*(Rows|List|Items|s)\b/

function* walk(d) {
    for (const n of readdirSync(d)) {
        const p = join(d, n)
        if (statSync(p).isDirectory()) { if (n !== 'node_modules' && n !== '.next') yield* walk(p) }
        else if (p.endsWith('.tsx')) yield p
    }
}

let targets = process.argv.slice(2).filter((a) => !a.startsWith('--'))
if (!targets.length) {
    // 所有详情页目录里的 .tsx(页面自己 + 它旁边的子表组件)
    targets = [...walk(join(ROOT, 'app'))].filter((p) => /\[[^\]/]+\]\/[^/]+\.tsx$/.test(p))
} else {
    targets = targets.flatMap((t) => {
        const p = t.startsWith('/') ? t : join(ROOT, t)
        return statSync(p).isDirectory() ? [...walk(p)] : [p]
    })
}

let flagged = 0, withActions = 0
for (const f of targets.sort()) {
    const lines = readFileSync(f, 'utf8').split('\n')
    const stack = []
    let depth = 0
    const risky = []
    let any = false
    lines.forEach((ln, i) => {
        const code = ln.replace(/\/\/.*$/, '').replace(/\{\/\*[\s\S]*?\*\/\}/g, '')
        const m = code.match(/\{\s*([^{}]*?)\s*(&&|\?)\s*\(?\s*$/)
        if (m) stack.push({ cond: m[1], line: i + 1, depth })
        for (const ch of code) {
            if (ch === '{') depth++
            else if (ch === '}') { depth--; while (stack.length && stack[stack.length - 1].depth >= depth) stack.pop() }
        }
        if (ACTION.test(code)) {
            any = true
            const g = stack.filter((s) => EMPTY.test(s.cond))
            if (g.length) risky.push({ line: i + 1, text: code.trim().slice(0, 64), g })
        }
    })
    if (any) withActions++
    if (!risky.length) continue
    console.log(`\n⚠ ${f.slice(ROOT.length + 1)}`)
    for (const r of risky) {
        flagged++
        console.log(`   :${r.line}  ${r.text}`)
        console.log(`      guarded by: ${r.g.map((x) => `${x.cond}  @${x.line}`).join('  >  ')}`)
    }
}
console.log(`\n${targets.length} file(s) · ${withActions} carry an action · ${flagged} action(s) inside an emptiness-shaped branch`)
console.log(flagged
    ? '→ JUDGE EACH: guarding a LINK TO a thing that does not exist is correct.\n'
      + '  Guarding the BUTTON THAT CREATES it is the defect this looks for.'
    : '→ nothing to judge.')
