#!/usr/bin/env node
// scripts/check-component-library.mjs
//
// ════════════════════════════════════════════════════════════════════════════
// PRE-ACCOUNT-1(2026-09-04)· 组件库棘轮:**新页面不许手搓表格**
//
// 【它回答一个问题,而且只回答那一个】
//     **app 里还有哪些地方自己写 `<table>`,而不是用 <DataTable> / <EditableTable>?**
//
// 【为什么是棘轮,不是闸,也不是普查 —— 这一段是本文件存在的理由】
//   实测(2026-09-04,本刀开工前):app 下 70 个文件、81 处手搓 `<table>`。
//   **一道"不许手搓表格"的闸今天会对着 70 个文件变红。**
//   委托自己写下过这条判据:「一份一开始就很长的例外清单,是这条规矩不对的证据」。
//   而 CONV-10 的克制同样适用:**一道会对着正确代码变红的闸,两刀之内就会被
//   加白名单绕过去,那比没有这道闸更坏。**
//
//   但"只印不拦"在这里【不够】:本刀存在的理由是**下一刀要新建一批页面**
//   (建账号 / 建角色 / 录 KPI)。一份没人看的普查拦不住新债。
//
//   所以走本仓库已经付过四次账、已经证明有效的第三条路:**冻结今天,只拦增量。**
//   前例:masked-reads-baseline.json · auth-error-baseline.json ·
//         currency-messages-baseline.json · check-base-isolation 的 KNOWN_CONVERSIONS
//   ——最后那一处把这条办法写成了一句话:**「多出来的每一处仍然会红」。**
//
// 【★ 这份基线【只会缩短】★】
//   它不是白名单,两者的差别是方向:白名单随着新债增长,基线随着还债缩短。
//   多一处 → 红。少一处 → 只提示,请顺手收紧基线。
//   **任何一刀想把基线改大,都必须先解释为什么** —— 而 --update-baseline
//   会把这件事留在 diff 里,藏不住。这条性质也写在基线文件自己的 __NOTE__ 里。
//
// 【它看得见什么】
//   ✓ app/ 下所有 .tsx 里的 `<table` 开标签,逐行点名 file:line
//   ✗ 【不看】app/components/ui/ —— 组件库自己就该有那一个 <table>(data-table.tsx
//     与 editable-table.tsx 正是把它收敛成一处的东西)。扫它等于罚它做对的事。
//   ✗ 【不看】注释掉的代码 —— CONV-8 的手机闸【被它自己的注释骗过去过】
//     (docs/detail-page-template.md)。所以这里先剥注释再匹配:
//     `//` 行注释 · `/* */` 块注释 · JSX 的 `{/* */}`。
//
// 【它【不】回答的那一半 —— 点名,不含糊】
//   ✗ **「库里缺能力时,先把能力加进库,再用」** —— 那是 Tim 规矩的 (b) 半条,
//     而它【没有机械特征】:一段本该抽成组件的内联代码,和一段本就该内联的代码,
//     长得一模一样。**本文件不假装检查它。** 它写在 docs/base-components.md 里,
//     明确标着 UNENFORCED —— 一个夸大自己的检查会被人忽略,而被忽略的检查
//     比没有更坏(check-masked-reads 抬头那一课)。
//
// ════════════════════════════════════════════════════════════════════════════
// ★★ BTN-1(2026-09-06):这道棘轮现在有【两个维度】,而第二个是本刀的理由 ★★
// ════════════════════════════════════════════════════════════════════════════
// 【为什么加这一维 —— 委托书自己的验收条款是量不出来的】
//   BTN-1 的验收写着「组件库棘轮的基线必须缩短」。而本文件在那一刻只匹配
//   `<table`,**一个按钮都看不见** —— 转换 123 个按钮,基线纹丝不动。
//   Tim 的裁定:那不是把条款划掉,是【把这一维补上】。
//
// 【新债到达的速度是量出来的,不是估的】
//   C-1b(8afa0b7,2026-09-04)量到 383 个手写 <button> / 200 个文件。
//   BTN-1 开工前(6302ae2,2026-09-06)重新量:**391 / 205**。
//   **两天 +8 处 / +5 个文件。** 没有闸的那两天,债按每天约 4 个按钮的速度回填。
//   一次性转换 123 个而不留闸,三个月后就回到原处 —— 这一维就是为了那件事。
//
// 【两维共用一份基线文件,形状变了,而变化本身留在 diff 里】
//   旧形状:{ __NOTE__, "<file>": n, … }        ← 全部是 <table>
//   新形状:{ __NOTE__, table: {…}, button: {…} }
//   ★ 迁移【没有放宽 table 那一维】:迁移前后都是 66 个文件 / 76 处,原样搬过去。
//
// 【它【不】看什么 —— 与 table 那一维同一条界线】
//   ✗ app/components/ui/ —— 组件库自己就该有 <button>(button.tsx 正是落点)。
//   ✗ 注释掉的代码 —— 先剥注释再匹配(CONV-8 的手机闸被自己的注释骗过一次)。
//   ✗ `<Button`(大写)—— 那是库组件,正是我们要的东西。正则区分大小写。
//
// 【★ 它看得见"新增",看不见"改错了档"★ 说清楚,别高估它】
//   一个本该是 destructive 的按钮写成了 default,这道闸【一声不吭】——
//   它数的是"有没有用库",不是"档位对不对"。档位由人评审,
//   判据写在 docs/base-components.md 与 app/components/ui/button.tsx 抬头。
// ════════════════════════════════════════════════════════════════════════════
// 用法:node scripts/check-component-library.mjs
//       node scripts/check-component-library.mjs --update-baseline
// 退出码:0 = 没有新增;1 = 有新增(点名 file:line)
// ════════════════════════════════════════════════════════════════════════════
import { readFileSync, writeFileSync, readdirSync, statSync } from 'node:fs'
import { join, relative } from 'node:path'

const ROOT = process.cwd()
const BASELINE = join(ROOT, 'scripts/component-library-baseline.json')

// 组件库自己住的地方 —— 它【应当】有 <table>,那正是收敛的落点。
const LIBRARY_DIR = 'app/components/ui/'

function walk(dir, out = []) {
    for (const e of readdirSync(dir)) {
        const p = join(dir, e)
        if (statSync(p).isDirectory()) walk(p, out)
        else if (p.endsWith('.tsx')) out.push(p)
    }
    return out
}

// 【先剥注释,再匹配】保留换行,行号才不会漂 —— 点名点错行的检查没人信。
function stripComments(src) {
    let out = ''
    let i = 0
    const keepNl = (s) => s.replace(/[^\n]/g, ' ')
    while (i < src.length) {
        const two = src.slice(i, i + 2)
        if (two === '/*') {                      // /* … */  和 {/* … */} 的内层
            const end = src.indexOf('*/', i + 2)
            const stop = end === -1 ? src.length : end + 2
            out += keepNl(src.slice(i, stop)); i = stop; continue
        }
        if (two === '//') {                       // 行注释
            const end = src.indexOf('\n', i)
            const stop = end === -1 ? src.length : end
            out += keepNl(src.slice(i, stop)); i = stop; continue
        }
        out += src[i]; i++
    }
    return out
}

// ── 两个维度。加一维只要往这里加一行。────────────────────────────────────────
// ★★【一个量出来的陷阱 —— 这道闸差一点只看得见 40% 的按钮】★★
//   原来的写法是 `/<button[\s>]/`,要求标签名后面【同一行】还有一个空白字符。
//   而本仓库的多行标签是这么写的:
//         <button                    ← 这一行到此为止,后面什么都没有
//             type="submit"
//             onClick={…}
//         >
//   `.split('\n')` 已经把换行吃掉了,于是这一行【匹配不上】。
//   实测:266 处里有 **158 处是多行标签** —— 旧写法只数到 108 处。
//   ☞ 后果不是"数字偏小",是**这道闸对多行写法完全失效**:
//     一个新写的多行 <button> 不会让闸变红,而那正是它存在的唯一理由。
//   改法:`(?=[\s>]|$)` —— 行尾也算一个合法的边界。
//   ★ 对 table 那一维【无影响】(实测新旧同为 66 个文件 / 76 处):
//     本仓库的 <table> 全部写成 `<table className=…` 同一行。所以旧基线没有虚报,
//     这次也【没有】因为换正则而把 table 的基线改大。
const DIMS = [
    { key: 'table',  re: /<table(?=[\s>]|$)/,  what: '手搓 <table>',  fix: '<DataTable> / <EditableTable>' },
    { key: 'button', re: /<button(?=[\s>]|$)/, what: '手写 <button>', fix: '<Button>(档位见 button.tsx 抬头)' },
]

const hits = Object.fromEntries(DIMS.map((d) => [d.key, []]))
for (const abs of walk(join(ROOT, 'app'))) {
    const file = relative(ROOT, abs)
    if (file.startsWith(LIBRARY_DIR)) continue
    const lines = stripComments(readFileSync(abs, 'utf8')).split('\n')
    lines.forEach((ln, idx) => {
        for (const d of DIMS) if (d.re.test(ln)) hits[d.key].push({ file, line: idx + 1 })
    })
}

const counts = Object.fromEntries(DIMS.map((d) => {
    const m = new Map()
    for (const h of hits[d.key]) m.set(h.file, (m.get(h.file) ?? 0) + 1)
    return [d.key, m]
}))

const NOTE = '★ 这份基线【只会缩短】,不会变长。多一处 <table> 或 <button> → 闸变红;'
    + '少一处 → 顺手收紧。它不是白名单:白名单随新债增长,基线随还债缩短。'
    + '任何一刀想把它改大,必须在文档里解释为什么 —— 而 --update-baseline 让这件事留在 diff 里。'
    + ' BTN-1(2026-09-06)加入 button 维度:table 维度原样搬迁,没有放宽。'

if (process.argv.includes('--update-baseline')) {
    const obj = { __NOTE__: NOTE }
    for (const d of DIMS) {
        obj[d.key] = Object.fromEntries([...counts[d.key]].sort((a, b) => a[0].localeCompare(b[0])))
    }
    writeFileSync(BASELINE, JSON.stringify(obj, null, 2) + '\n')
    for (const d of DIMS) {
        console.log(`✓ 基线已刷新[${d.key}]:${counts[d.key].size} 个文件,共 ${hits[d.key].length} 处${d.what}。`)
    }
    process.exit(0)
}

let base
try {
    base = JSON.parse(readFileSync(BASELINE, 'utf8'))
} catch {
    console.error('✗ check-component-library:读不到基线 scripts/component-library-baseline.json。')
    console.error('  读不到【不是】空基线 —— 那会把历史债当成同样多的新债。')
    console.error('  头一次生成:node scripts/check-component-library.mjs --update-baseline')
    process.exit(2)
}

// ── 逐维比对。任一维有新增 → 整道闸红。──────────────────────────────────────
let red = 0
for (const d of DIMS) {
    const base_d = base[d.key]
    if (!base_d || typeof base_d !== 'object') {
        console.error(`✗ check-component-library:基线里没有 ${d.key} 这一维。`)
        console.error('  缺一维【不是】空基线 —— 那会把历史债当成同样多的新债。')
        console.error('  生成:node scripts/check-component-library.mjs --update-baseline')
        process.exit(2)
    }
    const added = [], gone = []
    for (const [f, n] of counts[d.key]) {
        const was = base_d[f] ?? 0
        if (n > was) added.push({ f, was, now: n })
    }
    for (const f of Object.keys(base_d)) {
        if ((counts[d.key].get(f) ?? 0) < base_d[f]) gone.push({ f, was: base_d[f], now: counts[d.key].get(f) ?? 0 })
    }

    console.log(`== ${d.what}(app/,不含组件库自己)==`)
    console.log(`   判词:**请改用 ${d.fix}。**`)
    console.log(`   基线:${Object.keys(base_d).length} 个文件在册。本次扫到 ${hits[d.key].length} 处。`)

    if (gone.length) {
        console.log('· 少了几处 —— 有人改好了,或者文件动了。基线可以收紧:')
        for (const g of gone) console.log(`    ${g.f}  ${g.was} → ${g.now}`)
        console.log('  收紧:node scripts/check-component-library.mjs --update-baseline')
    }

    if (!added.length) {
        console.log(`✓ 没有新增的${d.what}。`)
        console.log('')
        continue
    }
    red++
    console.log(`✗ 新增 ${added.length} 处${d.what} —— 新页面必须用组件库:`)
    for (const a of added) {
        const where = hits[d.key].filter((h) => h.file === a.f).map((h) => `${h.file}:${h.line}`)
        console.log(`   ${a.f}  基线 ${a.was} → 现在 ${a.now}`)
        for (const w of where) console.log(`      ${w}`)
    }
    console.log('')
}

console.log('规矩的另一半(库里缺能力时先加进库)【本闸不检查】,见 docs/base-components.md §八。')
process.exit(red ? 1 : 0)
