#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// BASE-1(2026-09-02)· 「一个页面都没转换」是一条【机器守着的事实】,不是一句话
// ════════════════════════════════════════════════════════════════════════════
// R5:本刀只建组件,不转换任何页面 —— 187 个已上线页面必须一个像素都不变。
// BRAND-1 用声明级 + 逐字节 className 证过"样式没变"。那条证明【今天仍然要跑】,
// 但它证不了这一条:一个新组件如果被某一页 import 了,那一页就【真的变了】,
// 而声明级证明看到的只是"多了一些新声明",完全合法。
//
// 所以补这一道:**除了组件自己和取样页,任何文件都不许 import 这批组件。**
// 它把"我没有转换页面"从一句自述变成一条可以跑的断言。
//
// 【它也守着 `base-*` 类名】那些类名进了全局样式表。只要它们只出现在
// 允许的文件里,它们就【不可能】改变任何既有页面的样子 —— 这比"我检查过了"硬。
//
// 【故障注入验过】见 docs/frontend-scoping.md:把一次 import 写进
// app/inbound/page.tsx,本检查退出码 1 并点名那一行;撤掉之后回到 0。
// 一条没被证明会红的断言,和没有这条断言是一样的。
//
// 用法:node scripts/check-base-isolation.mjs        (退出码 0 = 干净)
// ════════════════════════════════════════════════════════════════════════════

import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join, relative } from 'node:path'

const ROOT = process.cwd()

// 【允许持有这批组件的地方】—— 组件自己,和那个用完即删的取样页。
const ALLOWED_PREFIXES = [
    'app/components/ui/',
    'app/brand-sampler/',
]

// ★ 一处【已经发生过的、正当的】转换 ★
// /login 由 LOGIN-1(2026-09-02)转换过,它真的在用 button / card / input / label。
// 它不是本刀转的,但它是本刀【必须证明没有被弄坏】的那一页 ——
// 因为 BASE-1 动了 button.tsx 与 input.tsx。
// 【写成一张按行登记的基线,而不是把这四个组件从 GUARDED 里删掉】:
// 删掉的话,以后任何一页偷偷用上 button 都不会再被抓到;
// 登记的话,**多出来的每一处仍然会红**。
const KNOWN_CONVERSIONS = new Set([
    'app/login/SubmitButton.tsx → button',
    'app/login/page.tsx → card',
    'app/login/page.tsx → input',
    'app/login/page.tsx → label',
])

// 本刀新建/改动的基础组件。转换刀每转换一个模块,就把它从这里【拿掉一条】——
// 也就是说这个清单会随着转换推进自然缩短,而不是变成一张过期的白名单。
// ★★【CONV-0(2026-09-03):'refusal' 从这张清单上【拿掉了】—— 它毕业了】★★
// 本脚本自己写着这条办法:「如果是转换刀,请把那个组件从 GUARDED 里拿掉。」
// CONV-0 正是那一刀 —— 它把 <Refusal> 接进 MaskedValue 与 ActorName,
// 并把整页拒绝的三份逐字副本合并成 <RefusalPage>,于是 14 个已上线文件的
// 拒绝态一次收敛。**那是一次刻意的、看得见的视觉变更**,不是违规。
//
// ★【拿掉之后这道闸对 refusal 就不再守着什么了 —— 说清楚,别高估它】★
//   它守的是"这个组件还没有人用"。一个已经被采用的组件不可能再满足那条断言,
//   所以对它来说这道闸【已经用完了】。接替它的是别的东西:
//   拒绝态的【画法】从此只有一份实现(app/components/ui/refusal.tsx),
//   要漂就得改那一个文件 —— 这比一道闸更硬。
//   清单上剩下的 11 个组件仍然一个都没被采用,这道闸继续守着它们。
// ★★【CONV-1(2026-09-03):'data-table' 也毕业了 —— 与 CONV-0 的 refusal 同一条路】★★
// CONV-1 是【模板定形】那一刀:它把 <DataTable> 接进了四页(/inbound ·
// /finance/claims 的已决登记簿 · /commissions · /sales/quotes),并新建了
// 列表页外壳 <ListPage>。**那是一次刻意的、看得见的转换**,不是违规。
//
// ★【拿掉之后这道闸对 data-table 就不再守着什么 —— 接替它的是三样别的东西】★
//   ① 类型:DataTable 的 phone 是必填 prop —— 一张不声明手机处置的表编译不过;
//   ② 闸:scripts/check-datatable-phone.mjs —— columns 模式至少一列 priority,
//      点名 file:line,已进 npm run build;
//   ③ 渲染期 throw:DATATABLE_NO_PHONE_COLUMNS,兜住运行期才拼出来的列。
//   **这三样加起来比"没有人用它"硬得多**,因为它们守的是【用得对不对】,
//   而这道闸守的只是【有没有人用】。
//
// 清单上剩下的 10 个组件仍然一个都没被采用,这道闸继续守着它们。
// 【list-page 从来没有进过这张清单】—— 它是 CONV-1 新建的,建出来就是给页面用的。
const GUARDED = [
    'feedback',
    'button', 'input', 'alert', 'badge', 'card', 'label', 'select', 'table', 'textarea',
]

const walk = (dir, out = []) => {
    for (const name of readdirSync(dir)) {
        if (name === 'node_modules' || name === '.next' || name.startsWith('.')) continue
        const p = join(dir, name)
        if (statSync(p).isDirectory()) walk(p, out)
        else if (/\.(tsx?|mjs)$/.test(p)) out.push(p)
    }
    return out
}

const files = [...walk(join(ROOT, 'app')), ...walk(join(ROOT, 'lib'))]
const importRe = new RegExp(
    String.raw`from\s+['"]@/app/components/ui/(` + GUARDED.join('|') + String.raw`)['"]`, 'g')
const classRe = /\bbase-(flash-ok|nudge-err|skeleton|spin|pressable|reveal)\b/g

let known = 0
const badImports = []
const badClasses = []

for (const abs of files) {
    const rel = relative(ROOT, abs)
    if (ALLOWED_PREFIXES.some((p) => rel.startsWith(p))) continue
    const src = readFileSync(abs, 'utf8')
    for (const m of src.matchAll(importRe)) {
        if (KNOWN_CONVERSIONS.has(`${rel} → ${m[1]}`)) { known++; continue }
        const line = src.slice(0, m.index).split('\n').length
        badImports.push(`${rel}:${line}  → @/app/components/ui/${m[1]}`)
    }
    for (const m of src.matchAll(classRe)) {
        const line = src.slice(0, m.index).split('\n').length
        badClasses.push(`${rel}:${line}  → ${m[0]}`)
    }
}

if (badImports.length === 0 && badClasses.length === 0) {
    console.log(`✓ base 组件仍然是【隔离】的:${files.length} 个文件里,` +
        `取样页与组件目录之外 0 处 import、0 处 base-* 类名。`)
    console.log(`  已登记的既有转换 ${known} 处(全部在 /login,LOGIN-1 做的)——`)
    console.log('  除它之外,187 个已上线页面【没有一个】用到本刀建的东西。')
    if (known !== KNOWN_CONVERSIONS.size) {
        console.error(`\n✗ 基线对不上:登记了 ${KNOWN_CONVERSIONS.size} 处,只找到 ${known} 处。`)
        console.error('  一条【比实际宽】的基线会悄悄放过真的违规 —— 请把消失的那一处删掉。')
        process.exit(1)
    }
    process.exit(0)
}

console.error('\n✗ R5 破了 —— 有页面已经在用这批组件/类名,而本刀声称【没有转换任何页面】:')
for (const b of badImports) console.error('   import  ' + b)
for (const b of badClasses) console.error('   class   ' + b)
console.error('\n这不一定是错的 —— 转换刀本来就要做这件事。')
console.error('但如果是转换刀,请把那个组件从 scripts/check-base-isolation.mjs 的 GUARDED 里拿掉,')
console.error('并且【对着那一页重新跑一次视觉证明】:它现在真的变了,不能再引用 BASE-1 那次的结论。')
process.exit(1)
