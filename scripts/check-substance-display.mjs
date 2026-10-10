#!/usr/bin/env node
// scripts/check-substance-display.mjs —— 物质下拉的名字来自字典;含量以 % 原样印,惩罚元素旁边带 ppm,不舍入;定价页只给可计价金属
// ==========================================================================
// 【瞄准 · AIM】
//   我读的是      :① lib/substances.ts 的几支纯函数在【我自己造的输入】上吐出来的字(真的 import、真的调用);
//                   ② app/ 下每一处 toOptions( 调用、合同页那两本字典、termSpecs 的三条映射、以及每一处 content_pct 的源码文本。
//   我声称管的是   :MES-6a-2(Q27 · Q29 · Q30)—— 下拉里一种物质叫字典给它起的名字(按读者语言);
//                   化验含量按存的样子印,惩罚元素在 % 旁边带等值的 ppm(0.0050 % 印成 0.005% (50 ppm),不会被印成 0.01%);
//                   定价那几页只递可计价金属,合同的惩罚条款只递惩罚元素。
//   两者不同之处   :★ ① 证的是那几支函数,不是屏幕 —— 一个页面绕开它们自己拼字(比如又写一句 toFixed(2))我只在
//                   【它恰好写着 content_pct】时看得见;屏幕上的读数由版式普查与线上验证去读。
//                   ★ ② 是源码文本:一个不经 toOptions 的新选单我看不见(选单住在调用点,不住在闭合集合里)。
// ==========================================================================
// 在 npm run build 里跑,不碰库(只读仓库文件 + import 一支纯 .ts,~0.1s)。
// 【每一次运行都先证明自己没瞎】:② 那几条规则先对着合成的坏源码跑,每一条都必须点名;任何一格没咬人 → 退 3。
// 【故障注入】CHECK_SUBSTANCE_DISPLAY_FAULT=
//   round      —— 含量换成 toFixed(2) 的印法(Q29 那个老毛病)→ ① 红;
//   labelkey   —— 选项的名字换回 'metals.<code>' 键(Q30 之前的样子)→ ① 红;
//   ppm-float  —— ppm 走浮点乘法(实测 0.0029 × 10000 = 28.999999999999996)→ ① 红;
//   pricing    —— 把一个定价页的 payableOnly 从源码里拿掉再判 → ② 红。
// 退出码:0 干净 · 1 有违反 · 3 本检查瞎了。
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join, relative } from 'node:path'
import { assertPopulation, assertPinned, assertAssertionsRan } from './lib/selfproof.mjs'

const SELF = 'check-substance-display'
const ROOT = process.cwd()
const FAULT = process.env.CHECK_SUBSTANCE_DISPLAY_FAULT ?? ''
const L = await import(join(ROOT, 'lib/substances.ts'))
const problems = []

// ── ① 那几支函数,在造出来的输入上 ─────────────────────────────────────────
const contentText = FAULT === 'round'
    ? (p, r) => { const v = Number(p).toFixed(2); return r === 'penalty_element' ? `${v}% (${L.ppmOf(p)} ppm)` : `${v}%` }
    : L.contentText
const toSubstanceOptions = FAULT === 'labelkey'
    ? (rows, locale) => L.toSubstanceOptions(rows, locale).map((o) => ({ ...o, label: 'metals.' + o.value }))
    : L.toSubstanceOptions
const ppmOf = FAULT === 'ppm-float' ? (p) => String(Number(p) * L.PPM_PER_PCT) : L.ppmOf

const ROWS = [
    { code: 'ni', name_en: 'Nickel', name_zh: '镍', symbol: 'Ni', is_active: true, role: 'payable_metal' },
    { code: 'f', name_en: 'Fluorine', name_zh: '氟', symbol: 'F', is_active: true, role: 'penalty_element' },
    { code: 'cl', name_en: 'Chlorine', name_zh: '氯', symbol: 'Cl', is_active: true, role: 'penalty_element' },
    { code: 'zz', name_en: 'Retired thing', name_zh: '停用物', symbol: null, is_active: false, role: 'other' },
]
let ran = 0
const eq = (what, got, want) => { ran++; if (got !== want) problems.push(`① ${what}:得到 ${JSON.stringify(got)},应当是 ${JSON.stringify(want)}`) }
// Q29:% 原样、不舍入;惩罚元素带 ppm
eq('惩罚元素 0.0050 %', contentText('0.0050', 'penalty_element'), '0.005% (50 ppm)')
eq('惩罚元素 0.0123 %', contentText('0.0123', 'penalty_element'), '0.0123% (123 ppm)')
eq('惩罚元素 0.0029 %(浮点乘法给 28.999999999999996)', contentText('0.0029', 'penalty_element'), '0.0029% (29 ppm)')
eq('惩罚元素 2.5 %(数字入参)', contentText(2.5, 'penalty_element'), '2.5% (25000 ppm)')
eq('可计价金属 20.5 % 不带 ppm', contentText('20.5', 'payable_metal'), '20.5%')
eq('可计价金属 0.123456 % 不舍入', contentText('0.123456', 'payable_metal'), '0.123456%')
eq('列头已写 % 的一格', L.contentCell('0.0050', 'penalty_element'), '0.005 (50 ppm)')
eq('ppm 0.0123', ppmOf('0.0123'), '123')
eq('ppm 1.005(浮点乘法给 10049.999999999998)', ppmOf('1.005'), '10050')
eq('ppm 0.00001(很小的数,不进科学计数法)', ppmOf('0.00001'), '0.1')
eq('ppm 1e-7(数字入参是科学计数法)', ppmOf(1e-7), '0.001')
eq('每百分点 50 → 每 ppm', L.perPpmOf('50'), '0.005')
eq('角色不明的码不带 ppm', contentText('0.5', null), '0.5%')
// Q30:名字来自字典,按读者语言;停用的照样在(D5)
const en = toSubstanceOptions(ROWS, 'en'), zh = toSubstanceOptions(ROWS, 'zh')
eq('英文名字', en.map((o) => o.label).join('|'), 'Nickel|Fluorine|Chlorine|Retired thing')
eq('中文名字', zh.map((o) => o.label).join('|'), '镍|氟|氯|停用物')
eq('停用的行带 isActive=false 留在选项里', en.find((o) => o.value === 'zz')?.isActive, false)
// Q27:分角色
eq('payableOnly', L.payableOnly(ROWS).map((r) => r.code).join(','), 'ni')
eq('penaltyOnly', L.penaltyOnly(ROWS).map((r) => r.code).join(','), 'f,cl')
assertAssertionsRan(SELF, ran, 18)

// ── ② 源码:每一处 toOptions 带着语言;定价页只递可计价金属;合同的两本字典;没有被舍入的含量 ─────────────
function* walk(dir) {
    for (const n of readdirSync(dir)) {
        const p = join(dir, n)
        if (statSync(p).isDirectory()) yield* walk(p)
        else if (/\.(ts|tsx)$/.test(n)) yield p
    }
}
/** 去掉 // 与块注释(注释里提到的 toFixed / toOptions 不是调用) */
const stripComments = (s) => s.replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, ' ')).replace(/(^|[^:'"`])\/\/.*$/gm, '$1')
/** 从 open('(' 的位置)起读到配对的 ')',返回参数串;认字符串,不认注释(已剥) */
function argsAt(s, open) {
    let depth = 0, q = null
    for (let i = open; i < s.length; i++) {
        const c = s[i]
        if (q) { if (c === '\\') i++; else if (c === q) q = null; continue }
        if (c === '"' || c === "'" || c === '`') { q = c; continue }
        if (c === '(') depth++
        else if (c === ')' && --depth === 0) return s.slice(open + 1, i)
    }
    return null
}
const topLevelArgs = (a) => { let d = 0, n = a.trim() ? 1 : 0; for (const c of a) { if ('([{'.includes(c)) d++; else if (')]}'.includes(c)) d--; else if (c === ',' && d === 0) n++ } return n }

/** 一份源码里的违反。rel 决定它是不是定价页。 */
export function rulesFor(rel, raw) {
    const out = []
    const src = stripComments(raw)
    let calls = 0
    for (const m of src.matchAll(/\btoOptions\(/g)) {
        if (/function\s+$/.test(src.slice(Math.max(0, m.index - 10), m.index))) continue      // 定义本身
        calls++
        const a = argsAt(src, m.index + 'toOptions'.length)
        if (a === null) { out.push(`${rel}: a toOptions( call does not close — cannot be judged`); continue }
        if (topLevelArgs(a) < 2) out.push(`${rel}: toOptions(${a.trim()}) has no locale — the picker would not get the dictionary's own name for the reader's language (Q30)`)
        if (rel.startsWith('app/tools/pricing/') && !/^\s*payableOnly\(/.test(a)) out.push(`${rel}: a pricing page hands toOptions something other than payableOnly(...) — a penalty element would be offered on a price path (Q27)`)
    }
    const rounded = src.match(/content_pct[^\n;]*\.toFixed\(|\.toFixed\([^\n;]*content_pct/g) ?? []
    for (let i = 0; i < rounded.length; i++)
        out.push(`${rel}: content_pct is printed through toFixed — 0.0050 % would read 0.01 % (Q29: as stored, ppm beside a penalty element)`)
    if (/\blabelKey\b/.test(src) && /SubstanceOption|MetalOption/.test(src)) out.push(`${rel}: a substance option still carries a labelKey — the name comes from the dictionary row now (Q30)`)
    return { out, calls }
}

// 自证:每一条规则在一份合成的坏源码上必须点名
const blind = []
const cell = (what, rel, src, needle) => { const r = rulesFor(rel, src).out; if (!r.some((p) => p.includes(needle))) blind.push(`self-proof: ${what} was NOT flagged — the rule is blind`) }
cell('a toOptions call without a locale', 'app/x/page.tsx', `const o = toOptions(await loadSubstances(s))`, 'has no locale')
cell('a pricing page without payableOnly', 'app/tools/pricing/x/page.tsx', `const o = toOptions(await loadSubstances(s), locale)`, 'pricing page')
cell('content_pct through toFixed', 'app/x/Panel.tsx', `<td>{Number(r.content_pct).toFixed(2)}</td>`, 'toFixed')
cell('a substance option with a labelKey', 'app/x/opts.ts', `type SubstanceOption = { value: string; labelKey: string }`, 'labelKey')
if (rulesFor('app/tools/pricing/x/page.tsx', `// toOptions(x)\nconst o = toOptions(payableOnly(rows), locale)`).out.length) blind.push('self-proof: a correct pricing call (with a commented-out bad one above it) was flagged — the rule over-reaches')
if (blind.length) {
    console.error(`✗ ${SELF}:本检查瞎了 —— 它此刻报的"干净"不作数`)
    for (const b of blind) console.error('   · ' + b)
    process.exit(3)
}

let calls = 0, roughCalls = 0, files = 0
for (const f of walk(join(ROOT, 'app'))) {
    const rel = relative(ROOT, f)
    let raw = readFileSync(f, 'utf8')
    if (FAULT === 'pricing' && rel === 'app/tools/pricing/calculator/page.tsx') raw = raw.replace('toOptions(payableOnly(', 'toOptions((')
    files++
    const r = rulesFor(rel, raw)
    calls += r.calls
    // 独立的粗计数:非注释行里 "toOptions(" 出现几次,减去定义那一行
    roughCalls += raw.split('\n').filter((l) => !/^\s*(\/\/|\*)/.test(l) && /\btoOptions\(/.test(l) && !/function\s+toOptions\(/.test(l)).length
    problems.push(...r.out.map((p) => '② ' + p))
}
assertPopulation(SELF, 'app/ 下读过的 .ts/.tsx', files)
assertPopulation(SELF, 'toOptions( 调用', calls)
assertPinned(SELF, 'toOptions( 调用:判据 ↔ 粗计数', calls, roughCalls, '差额 = 一处跨行或写在注释后面的调用,判据与粗计数看见的不是同一批。')

// 合同页:两本字典各递它该递的角色;termSpecs 的三条映射指着对的字典
const page = stripComments(readFileSync(join(ROOT, 'app/contracts/[id]/page.tsx'), 'utf8'))
if (!/payables:\s*pickable\(payableOnly\(/.test(page)) problems.push('② app/contracts/[id]/page.tsx: the payables dictionary is not payableOnly(...) (Q27)')
if (!/penaltyElements:\s*pickable\(penaltyOnly\(/.test(page)) problems.push('② app/contracts/[id]/page.tsx: the penaltyElements dictionary is not penaltyOnly(...) (Q27)')
const specs = stripComments(readFileSync(join(ROOT, 'app/contracts/[id]/termSpecs.ts'), 'utf8'))
const dictOf = (table, col) => {
    const at = specs.indexOf(`dbTable: '${table}'`)
    if (at < 0) return undefined
    const next = specs.indexOf('dbTable:', at + 1)
    const block = specs.slice(at, next < 0 ? undefined : next)
    return new RegExp(`name:\\s*'${col}'[^}]*dict:\\s*'(\\w+)'`).exec(block)?.[1]
}
for (const [table, col, want] of [['contract_pricing_terms', 'metal', 'payables'], ['contract_refining_charges', 'metal', 'payables'], ['contract_penalty_elements', 'substance', 'penaltyElements']]) {
    const got = dictOf(table, col)
    if (got !== want) problems.push(`② app/contracts/[id]/termSpecs.ts: ${table}.${col} picks from '${got}', not '${want}' (Q27)`)
}

if (problems.length) {
    console.error(`✗ ${SELF}:${problems.length} 处`)
    for (const p of problems) console.error('   · ' + p)
    process.exit(1)
}
console.log(`✓ ${SELF}:① ${ran} 条断言(% 原样不舍入、惩罚元素旁带 ppm、名字来自字典、分角色)全部成立;`
    + `② ${files} 个文件里 ${calls} 处 toOptions 都带着语言、定价页只递可计价金属,合同的两本字典与三条映射对得上,没有一处 content_pct 被 toFixed。自证 5 格全部咬人。`)
