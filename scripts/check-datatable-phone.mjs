#!/usr/bin/env node
// scripts/check-datatable-phone.mjs
// ════════════════════════════════════════════════════════════════════════════
// CONV-1(2026-09-03)· 【columns 模式的表,至少要有一列 priority】—— 在构建期
// ════════════════════════════════════════════════════════════════════════════
//
// 【为什么需要它 —— 一个【量出来的】缺陷,不是整洁】
// BASE-1 把「没声明手机列就按名拒绝」写成了 DataTable 渲染函数里的一个 throw。
// 那条拒绝是对的,而它响的【时机】是错的:
//   * `next build` 【不渲染】这些页面,所以构建期它一声不响;
//   * 于是它只在**有人真的打开那一页**时才响 —— 对一张少有人访问的列表页,
//     那可能是几个月之后,而且是在一个真实用户面前响。
// Tim 的裁定(CONV-1 Q2):「一条只在人打开一张少访问页面时才响的拒绝可以睡上几个月。
// 修它在范围内。」
//
// ★【三道网,各管各的 —— 写清楚,免得下一个人以为它们重复】★
//   ① 【类型】`phone` 是 DataTable 的必填 prop(PhoneTreatment 联合类型)。
//      漏掉它 = 编译不过。**管的是"有没有声明"。**
//      而 `mode: 'scroll'` 强制带 `why: string` —— 选横向滚动就必须当场写下理由。
//   ② 【本闸】columns 模式下,至少一列 priority: true。点名 file:line。
//      **管的是"声明得对不对"** —— 这是类型系统表达不了的那一半:
//      TypeScript 没有办法在一个普通数组上要求"至少一个元素的某个字段为 true"。
//   ③ 【渲染期 throw】DataTable 自己那条 DATATABLE_NO_PHONE_COLUMNS。
//      **管的是【运行期才拼出来的列】** —— 本闸是静态解析,读不出
//      `columns={cond ? A : B}` 或 `columns={buildCols(x)}` 这类动态列。
//   三条谁都替不了谁。
//
// 【判据】对每一个 `<DataTable` 调用点:
//   * 找到它的 `phone={{ mode: '…' }}`(类型已经保证它在,这里只读它是哪一支);
//   * mode === 'scroll' → 放行(它已经回答过手机这个问题了);
//   * mode === 'columns' → 找到它的 `columns={IDENT}`,在同一个文件里定位那个数组,
//     要求其中至少有一处 `priority: true`;
//   * 【读不出来的照直说,不当作通过】columns 不是一个能静态定位的标识符时,
//     记成 `unresolved` 并【点名列出】—— 它由第③道网兜着,而这里不假装查过。
//
// ★【空集不算通过】★ 解析出 0 个调用点 = 解析器坏了,不是"全都合格"。
//   本仓库为这条规矩付过多次账(check-nav-routes / check-dock 抬头同一条)。
//
// 退出码 0 = 干净;1 = 有表没声明可用的手机列;2 = 解析器坏了。
// ════════════════════════════════════════════════════════════════════════════
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join, relative } from 'node:path'

const ROOT = process.cwd()

function walk(dir, out = []) {
    for (const name of readdirSync(dir)) {
        if (name === 'node_modules' || name === '.next' || name.startsWith('.')) continue
        const p = join(dir, name)
        if (statSync(p).isDirectory()) walk(p, out)
        else if (p.endsWith('.tsx')) out.push(p)
    }
    return out
}

const lineOf = (src, idx) => src.slice(0, idx).split('\n').length

/** `<DataTable … />` 的属性区(到第一个未配对的 `>` 为止,方括号/花括号计数)。 */
function propsBlockAt(src, start) {
    let depth = 0
    for (let i = start; i < src.length; i++) {
        const ch = src[i]
        if (ch === '{') depth++
        else if (ch === '}') depth--
        else if (ch === '>' && depth === 0) return src.slice(start, i)
    }
    return null
}

const files = walk(join(ROOT, 'app'))
const problems = []
const unresolved = []
let callSites = 0
let scrollMode = 0
let columnsMode = 0

for (const abs of files) {
    const rel = relative(ROOT, abs)
    const src = readFileSync(abs, 'utf8')
    for (const m of src.matchAll(/<DataTable[\s\n]/g)) {
        callSites++
        const line = lineOf(src, m.index)
        const block = propsBlockAt(src, m.index)
        if (block === null) {
            problems.push({ rel, line, why: '读不出这个 <DataTable 的属性区 —— 解析器可能坏了' })
            continue
        }
        const mode = block.match(/phone=\{\{\s*mode:\s*'(\w+)'/)
        if (!mode) {
            // 类型已经保证 phone 在场;走到这里说明它是变量形式,读不出是哪一支。
            unresolved.push({ rel, line, why: 'phone 不是字面量,静态读不出是哪一支' })
            continue
        }
        if (mode[1] === 'scroll') {
            scrollMode++
            // scroll 必须带 why —— 类型已经强制,这里再确认它不是空串。
            const why = block.match(/why:\s*'([^']*)'/)
            if (why && why[1].trim() === '') {
                problems.push({ rel, line, why: "phone 声明了 scroll,但 why 是空串 —— 一个空的理由不是理由" })
            }
            continue
        }
        columnsMode++
        const colsIdent = block.match(/columns=\{(\w+)\}/)
        if (!colsIdent) {
            unresolved.push({ rel, line, why: 'columns 不是一个可静态定位的标识符' })
            continue
        }
        const ident = colsIdent[1]
        const declIdx = src.search(new RegExp(String.raw`(const|let)\s+${ident}\b`))
        if (declIdx === -1) {
            unresolved.push({ rel, line, why: `columns={${ident}} 的定义不在同一个文件里` })
            continue
        }
        const decl = src.slice(declIdx, declIdx + 20000)
        if (!/priority:\s*true/.test(decl)) {
            problems.push({
                rel, line,
                why: `phone 是 columns 模式,但 columns={${ident}} 里没有任何一列 priority: true —— ` +
                     '手机上就没有一列留得下来。给身份列与那个要紧的数字列加 priority: true,' +
                     "或者显式改成 phone={{ mode: 'scroll', why: '…' }} 并写下理由。",
            })
        }
    }
}

if (callSites === 0) {
    console.error('✗ check-datatable-phone:解析出 0 个 <DataTable 调用点 —— 解析器坏了,不是"全都合格"。')
    process.exit(2)
}

if (problems.length === 0) {
    console.log(
        `✓ 手机声明:${callSites} 个 <DataTable> 调用点 —— ` +
        `columns 模式 ${columnsMode}(各自至少一列 priority)· scroll 模式 ${scrollMode}(各自带 why)` +
        (unresolved.length ? ` · 静态读不出 ${unresolved.length}(由渲染期那道网兜着)` : '')
    )
    for (const u of unresolved) console.log(`   · ${u.rel}:${u.line}  ${u.why}`)
    process.exit(0)
}

console.error(`\n✗ 手机声明:${problems.length} 处 —— 这张表在 390px 上没有任何一列留得下来:\n`)
for (const p of problems) console.error(`   ${p.rel}:${p.line}\n     ${p.why}\n`)
process.exit(1)
