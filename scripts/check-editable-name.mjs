#!/usr/bin/env node
// scripts/check-editable-name.mjs
// ════════════════════════════════════════════════════════════════════════════
// DRAFT-2(2026-09-21)· 【`<EditableTable>` 的格子里不许有带 `name` 的输入】—— 在构建期
// ════════════════════════════════════════════════════════════════════════════
//
// ★★★【它守的是 Tim 的 Q1 裁定 (b),而那条裁定【没有】改组件的机制】★★★
//
//   `EDITABLETABLE-NAME-DOUBLE-SUBMIT` 的机制是:组件把列回调画【两遍】——
//   `editable-table.tsx` 的桌面格(`hidden sm:block`,**CSS 藏起来,不是移出 DOM**)
//   与手机展开区(`isOpen` 时挂载)。一个带 `name=` 的输入因此在 `FormData` 里
//   出现两次:`getAll()` 的并列数组【错位】,或者 `get()` 拿到桌面那一份空的。
//
//   ☞ **裁定 (b) 不修这个机制,它拿走这个机制的燃料**:页面持有那个数组,
//     草稿经【一个】隐藏的 `*_json` 交出去(那一个画在表【外面】,只画一遍),
//     于是格子里根本不再有具名输入。
//   ⚠ **也就是说 (b) 落地之后,「格子里不许有 name」这条规矩【没有任何东西守着】。**
//     一句注释拦不住下一个人往格子里放一个 `name=` —— 本仓库为
//     「一条被破了很多次的规矩不再是一条规矩,是一个机制」付过账
//     (`check-auth-error-swallowing` 抬头)。**这个文件就是那个机制。**
//
// 【判据】对每一个 `<EditableTable` 调用点:
//   * 从属性区读出 `columns={…}`,在同一个文件里定位那个数组(或那个造它的函数),
//     按括号配对切出它的【整个】区段;
//   * 区段里出现 `name=` → 报错,点名 file:line。
//   ★ **`render` 与 `edit` 一视同仁** —— 组件对两者都画两遍
//     (`render` 在桌面格与手机展开区各一份),所以坏法逐字相同。
//   ★ **`footer` 【不】在判据内,而那是刻意的** —— 表尾画在表外面,**只画一遍**,
//     那正是 (b) 那座 JSON 桥该待的地方。把 footer 也拦下来等于拦掉解法本身。
//
// 【读不出来的照直说,不当作通过】`columns` 定位不到、或括号配到文件尾都没配平时,
//   记成 `unresolved` 并**点名列出** —— 本闸不假装查过。
//
// ★【空集不算通过】★ 解析出 0 个 `<EditableTable` 调用点 = 解析器坏了,
//   不是"全都合格"。本仓库为这条规矩付过多次账。
//
// ⚠【为什么它不与 check-datatable-phone.mjs 共用那三个解析工具,照直记】
//   那一支的 `blankComments()` **只抹注释,不抹字符串正文**,而本闸要按括号配对,
//   所以它必须把字符串正文也抹掉(否则一个字符串里的 `[` 会把配对带偏)。
//   改那一支去共用,就会改掉它 `assertPinned` 钉住的那两个计数(它抬头 :152-162
//   逐字讨论的正是一个住在字符串里的 `<DataTable>`)—— **为了不重复而让一道在跑的
//   闸换一个判据,买到的比付出的少。** 两份 `blankComments` 会漂开是一个真的风险,
//   记在这里,不假装它不存在。
//
// 退出码 0 = 干净;1 = 格子里有具名输入;2 = 解析器坏了。
// ==========================================================================
// 【瞄准 · AIM】
//   我读的是      :`app/` 下的 `.tsx` 源码文本 —— `<EditableTable` 的属性区,
//                   以及它 `columns` 指向的那个数组/函数的括号区段。
//   我声称管的是   :没有任何一个带 `name` 的表单控件住在可编辑表的格子里。
//   两者不同之处   :★★ **我读的是【词法上的那一段】,不是渲染出来的 DOM。**
//                   一个从别的文件 import 进来的列数组、或者一个把
//                   `name={NAME_CONST}` 藏在另一个组件里的格子 —— 我看不见。
//                   ☞ 前者我记成 `unresolved` 并点名;**后者我连它存在都不知道。**
//                   ★ 另:**我只管 `EditableTable`。** `DataTable` 的同一个机制
//                     (`DATATABLE-UNCONTROLLED-NAME-DOUBLE-SUBMIT`)**不在本闸内**,
//                     那一条今天仍然只有一句注释守着,它开着。
// ==========================================================================
import { assertPinned, assertPopulation } from './lib/selfproof.mjs'
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

/**
 * 把注释【与字符串正文】逐字符抹成空格,长度与偏移量逐字节不变。
 *
 * 【为什么连字符串正文一起抹 —— 本闸与 check-datatable-phone 的分别就在这里】
 * 本闸按括号配对切区段。一个字符串里的 `[` / `{`(例如一句
 * `throw new Error('… columns=[…] …')`)会把配对带偏整整一个层级,
 * 而带偏之后本闸【不会变红,它会安静地少查一张表】—— 那正是本仓库
 * 反复付账的那种失败(见 check-datatable-phone 的 blankComments 抬头,同一个病的第四次)。
 *
 * ★ 引号本身留着,只抹正文 —— 于是 `name="foo"` 变成 `name="   "`,
 *   判据 `\bname\s*=` 照样命中。**抹掉的是内容,不是那个属性。**
 */
function blankCode(src) {
    const out = src.split('')
    let i = 0
    while (i < src.length) {
        const two = src[i] + src[i + 1]
        if (two === '//') {
            while (i < src.length && src[i] !== '\n') { out[i] = ' '; i++ }
        } else if (two === '/*') {
            while (i < src.length && !(src[i] === '*' && src[i + 1] === '/')) {
                if (src[i] !== '\n') out[i] = ' '
                i++
            }
            out[i] = ' '; out[i + 1] = ' '; i += 2
        } else if (src[i] === "'" || src[i] === '"' || src[i] === '`') {
            const q = src[i]
            i++                                   // ← 开引号留着
            while (i < src.length && src[i] !== q) {
                if (src[i] === '\\') { out[i] = ' '; i++ }
                if (i < src.length && src[i] !== '\n') out[i] = ' '
                i++
            }
            i++                                   // ← 闭引号留着
        } else i++
    }
    return out.join('')
}

/** 一个调用点的属性区(先跳过泛型实参表,再按花括号计数走到未配对的 `>`)。 */
function propsBlockAt(src, start) {
    let i = start + 1
    while (i < src.length && !/[\s\n<>{]/.test(src[i])) i++
    if (src[i] === '<') {
        let g = 0
        for (; i < src.length; i++) {
            if (src[i] === '<') g++
            else if (src[i] === '>') { g--; if (g === 0) { i++; break } }
        }
    }
    const from = i
    let depth = 0
    for (; i < src.length; i++) {
        const ch = src[i]
        if (ch === '{') depth++
        else if (ch === '}') depth--
        else if (ch === '>' && depth === 0) return src.slice(from, i)
    }
    return null
}

/** 从 `from` 起找第一个 `[` 或 `{`,按括号配对返回 `[开, 闭]` 偏移;配不平返回 null。 */
function spanFrom(code, from) {
    let i = from
    while (i < code.length && code[i] !== '[' && code[i] !== '{') {
        // 一行里配不到就放弃 —— 不跨半个文件乱找
        if (code[i] === ';') return null
        i++
    }
    if (i >= code.length) return null
    const open = code[i]
    const close = open === '[' ? ']' : '}'
    let depth = 0
    for (let j = i; j < code.length; j++) {
        if (code[j] === open) depth++
        else if (code[j] === close) { depth--; if (depth === 0) return [i, j] }
    }
    return null
}

const files = walk(join(ROOT, 'app'))
assertPopulation('check-editable-name', 'app/ 下走到的 .tsx 文件', files.length)

const problems = []
const unresolved = []
let callSites = 0
let callSitesBlanked = 0
let checkedSpans = 0

for (const abs of files) {
    const raw = readFileSync(abs, 'utf8')
    callSitesBlanked += (blankCode(raw).match(/<EditableTable(?=[\s\n<])/g) ?? []).length
}

for (const abs of files) {
    const rel = relative(ROOT, abs)
    const raw = readFileSync(abs, 'utf8')
    if (!raw.includes('<EditableTable')) continue
    const code = blankCode(raw)              // ← 偏移量与 raw 逐字节对齐
    for (const m of code.matchAll(/<EditableTable(?=[\s\n<])/g)) {
        callSites++
        const line = lineOf(raw, m.index)
        const block = propsBlockAt(code, m.index)
        if (block === null) {
            problems.push({ rel, line, why: '读不出这个 <EditableTable 的属性区 —— 解析器可能坏了' })
            continue
        }
        // `columns={IDENT}` 或 `columns={IDENT(...)}`(/me 的 `columnsFor(locked)` 是后者)
        const ident = block.match(/columns=\{(\w+)\s*[(}]/)
        if (!ident) {
            unresolved.push({ rel, line, why: 'columns 不是一个可静态定位的标识符' })
            continue
        }
        const name = ident[1]
        const decl = code.search(new RegExp(String.raw`(const|let|function)\s+${name}\b`))
        if (decl === -1) {
            unresolved.push({ rel, line, why: `columns={${name}} 的定义不在同一个文件里` })
            continue
        }
        // 从声明名之后起跳:`const columns: Column<T>[] = [` 里那个 `[]` 属于类型,
        // 不是数组 —— 所以先走到 `=` 或参数表的 `)`,再找第一个 `[` / `{`。
        const after = code.indexOf(name, decl) + name.length
        const eq = code.indexOf('=', after)
        const paren = code.indexOf(')', after)
        const startAt = code.slice(decl, decl + 12).startsWith('function')
            ? (paren === -1 ? after : paren)
            : (eq === -1 ? after : eq)
        const span = spanFrom(code, startAt)
        if (span === null) {
            unresolved.push({ rel, line, why: `columns={${name}} 的区段括号配不平 —— 本闸不假装查过` })
            continue
        }
        checkedSpans++
        const [open, close] = span
        const region = code.slice(open, close + 1)
        for (const hit of region.matchAll(/\bname\s*=/g)) {
            problems.push({
                rel,
                line: lineOf(raw, open + hit.index),
                why: `<EditableTable 的列里有一个带 name 的控件。组件把列回调画【两遍】` +
                     `(桌面格 hidden sm:block + 手机展开区),于是它在 FormData 里出现两次:` +
                     `getAll() 的并列数组会错位,get() 会拿到桌面那一份空的。` +
                     `☞ 按 Tim 的 Q1 裁定 (b):让页面持有那个数组,草稿经表【外面】一个隐藏的 ` +
                     `*_json 交出去(先例:TemplateForm / NewOrderForm / PayrollGrid),` +
                     `格子里不要放具名输入。见 docs/known-issues.md 的 EDITABLETABLE-NAME-DOUBLE-SUBMIT。`,
            })
        }
    }
}

if (callSites === 0) {
    console.error('✗ check-editable-name:解析出 0 个 <EditableTable 调用点 —— 解析器坏了,不是"全都合格"。')
    process.exit(2)
}
assertPinned(
    'check-editable-name',
    '剥注释后数出的调用点 ↔ 逐文件复查数出的调用点',
    callSites, callSitesBlanked,
    '不等 = 两条路数的不是同一批调用点,判据的分母因此不可信。',
)

if (problems.length === 0) {
    console.log(
        `✓ 可编辑表的格子:${callSites} 个 <EditableTable 调用点 —— 查了 ${checkedSpans} 个 columns 区段,` +
        `带 name 的控件 0 个` +
        (unresolved.length ? ` · 静态读不出 ${unresolved.length}(照直列出,不当作通过)` : '')
    )
    for (const u of unresolved) console.log(`   · ${u.rel}:${u.line}  ${u.why}`)
    process.exit(0)
}

console.error(`\n✗ 可编辑表的格子:${problems.length} 处带 name 的控件 —— 它们会被提交两次:\n`)
for (const p of problems) console.error(`   ${p.rel}:${p.line}\n     ${p.why}\n`)
process.exit(1)
