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

const hits = []
for (const abs of walk(join(ROOT, 'app'))) {
    const file = relative(ROOT, abs)
    if (file.startsWith(LIBRARY_DIR)) continue
    const lines = stripComments(readFileSync(abs, 'utf8')).split('\n')
    lines.forEach((ln, idx) => {
        if (/<table[\s>]/.test(ln)) hits.push({ file, line: idx + 1 })
    })
}

const counts = new Map()
for (const h of hits) counts.set(h.file, (counts.get(h.file) ?? 0) + 1)

const NOTE = '★ 这份基线【只会缩短】,不会变长。多一处 <table> → 闸变红;'
    + '少一处 → 顺手收紧。它不是白名单:白名单随新债增长,基线随还债缩短。'
    + '任何一刀想把它改大,必须在文档里解释为什么 —— 而 --update-baseline 让这件事留在 diff 里。'

if (process.argv.includes('--update-baseline')) {
    const obj = { __NOTE__: NOTE,
        ...Object.fromEntries([...counts].sort((a, b) => a[0].localeCompare(b[0]))) }
    writeFileSync(BASELINE, JSON.stringify(obj, null, 2) + '\n')
    console.log(`✓ 基线已刷新:${counts.size} 个文件,共 ${hits.length} 处手搓 <table>。`)
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

const added = [], gone = []
for (const [f, n] of counts) {
    const was = base[f] ?? 0
    if (n > was) added.push({ f, was, now: n })
}
for (const f of Object.keys(base)) {
    if (f.startsWith('__')) continue            // __NOTE__ 不是一个文件
    if ((counts.get(f) ?? 0) < base[f]) gone.push({ f, was: base[f], now: counts.get(f) ?? 0 })
}

console.log('== 手搓 <table> 的地方(app/,不含组件库自己)==')
console.log('   判词:**这张表请改用 <DataTable> / <EditableTable>。**')
console.log('   规矩的另一半(库里缺能力时先加进库)【本闸不检查】,见 docs/base-components.md。')
console.log(`   基线:${Object.keys(base).filter((k) => !k.startsWith('__')).length} 个文件在册。本次扫到 ${hits.length} 处。`)
console.log('')

if (gone.length) {
    console.log('· 少了几处 —— 有人改好了,或者文件动了。基线可以收紧:')
    for (const g of gone) console.log(`    ${g.f}  ${g.was} → ${g.now}`)
    console.log('  收紧:node scripts/check-component-library.mjs --update-baseline')
    console.log('')
}

if (!added.length) {
    console.log('✓ 没有新增的手搓表格。')
    process.exit(0)
}

console.log(`✗ 新增 ${added.length} 处手搓 <table> —— 新页面必须用组件库:`)
for (const a of added) {
    const where = hits.filter((h) => h.file === a.f).map((h) => `${h.file}:${h.line}`)
    console.log(`   ${a.f}  基线 ${a.was} → 现在 ${a.now}`)
    for (const w of where) console.log(`      ${w}`)
}
console.log('')
console.log('改法:<DataTable>(只读)/ <EditableTable>(整行可编辑),见')
console.log('  docs/list-page-template.md · docs/editable-grid-template.md · docs/detail-page-template.md')
console.log('库里缺你要的能力时:**先把能力加进库,再用它** —— 不要内联"就这一次"。')
console.log('**不要**为了让门变绿而直接刷新基线:基线只会缩短。')
process.exit(1)
