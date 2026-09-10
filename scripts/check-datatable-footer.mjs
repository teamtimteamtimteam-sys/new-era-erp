#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// TABLE-FOOTER-1(2026-09-10)· 表尾【在两个断点上各自跨对格数】—— 一支会变红的量具
// ════════════════════════════════════════════════════════════════════════════
// 【为什么它是渲染,不是读源码】
// 本仓库对「读源码的量具」已经付过账(CHECKER-BLIND-SPOTS ④:字体守卫读的是
// 另一个对象,而它每一次致盲注入都照常变红)。表尾这件事尤其读不出来:
// `colSpan` 是一个【算出来的数】,源码里写的是一个表达式,不是那个数。
// **所以这支量具把组件真的转译、真的渲染,读渲染出来的 HTML。**
//
// 【为什么 colSpan 是难的那一半】
// colSpan 不能随断点变 —— 全仓 6 张手搓表为这件事把标签格【写两份】
// (trial-balance:234/242 · payables:309/321 · receivables:300/315 · quotes:190/194)。
// 空态那一格躲得过去,是因为它【只有一格】:HTML 会把跨多了的 colSpan 截断,
// 一格跨过头看不出来。**表尾躲不过去:它有两格以上,标签跨几格【决定了合计落在哪一列】。**
// 跨多一格,合计就整体右移一列 —— 而它在屏幕上仍然是一张排得整整齐齐的表。
//
// ════════════════════════════════════════════════════════════════════════════
// 【瞄准 · AIM】
//   我读的是      :`app/components/ui/data-table.tsx` 的源码 —— 用 typescript
//                   转译成 CJS、用 react-dom/server 【真的渲染一遍】,
//                   读的是渲染出来的 HTML 字符串里的 <thead>/<tfoot> 格子。
//   我声称管的是   :DataTable 的表尾能力 —— ① 给了 footer 就长出 <tfoot>;
//                   ② 手机档与桌面档【各自】跨满整行,一格不多一格不少;
//                   ③ 手机上被折走的那些列的合计【不会凭空消失】;
//                   ④ **不给 footer 的调用点一个 <tfoot> 都不长**。
//   两者不同之处   :★★ 我渲染的是【我自己造的样例表】,不是那 160 个真实调用点。★★
//                   一张真实的表可能有我没造出来的形状(运行期算出来的列、
//                   c.className 里自带的 hidden、嵌套表格),而那些我看不见。
//                   ☞ ④ 那一条尤其要读清楚:它证的是"这几张样例表不长 tfoot",
//                     **不是**"那 160 个调用点渲染得和从前一模一样" ——
//                     后者是本刀在交回报告里用逐页实测回答的,不是这支量具答的。
// ════════════════════════════════════════════════════════════════════════════
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createRequire } from 'node:module'
import { assertPopulation, assertPinned, assertAssertionsRan } from './lib/selfproof.mjs'

const SELF = 'check-datatable-footer'
const require = createRequire(import.meta.url)
const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const SRC = join(ROOT, 'app/components/ui/data-table.tsx')

const ts = require('typescript')
const React = require('react')
const { renderToStaticMarkup } = require('react-dom/server')

// ── 把组件转译出来跑 ────────────────────────────────────────────────────────
// 三个 `@/` 依赖在这里换成【行为等价的桩】:cn 就是拼字符串,t 回显 key,
// 字序比较回退到 localeCompare。它们都不参与表尾的 colSpan 计算,
// 所以桩掉它们不会让本支量具看走眼。
const STUBS = {
    '@/lib/i18n/client': { useTranslations: () => (k) => k },
    '@/lib/utils': { cn: (...a) => a.flat(Infinity).filter((x) => typeof x === 'string' && x).join(' ') },
    '@/lib/sortCollation': { compareForSort: (a, b) => String(a).localeCompare(String(b)) },
}

// ★ `table-style.ts` 【不桩】,真的载进来 —— 表尾用的是 tableC 的类串,
//   而本支量具靠读类串判断一格在哪个断点上看得见。桩掉它就等于自己给自己
//   编一份类名,然后拿它去证明类名是对的。
// ★ `control-style.ts` 同理【不桩】(INPUT-2,2026-09-10):`data-table.tsx:479` 那个
//   筛选框现在从它拿类串,而本支靠读类串判断一格在哪个断点上看得见 ——
//   桩掉它就是自己编一份类名再拿它证明类名是对的,与上面那一条逐字同一个理由。
//   它是一个只有字符串常量、零 import 的模块,真载进来没有代价。
const REAL = {
    '@/app/components/ui/table-style': 'app/components/ui/table-style.ts',
    '@/app/components/ui/control-style': 'app/components/ui/control-style.ts',
}

function transpile(file) {
    return ts.transpileModule(readFileSync(file, 'utf8'), {
        compilerOptions: { jsx: ts.JsxEmit.React, target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS },
        fileName: file,
    }).outputText
}

function loadComponent(file) {
    const out = transpile(file)
    const mod = { exports: {} }
    const req = (id) => {
        if (STUBS[id]) return STUBS[id]
        if (REAL[id]) return loadComponent(join(ROOT, REAL[id]))
        if (id.startsWith('@/') || id.startsWith('./')) {
            throw new Error(`${SELF}:没有为 ${id} 准备桩 —— 量具自己不完整。`)
        }
        return require(id)
    }
    new Function('require', 'module', 'exports', out)(req, mod, mod.exports)
    return mod.exports
}

// ── 一个够用的格子扫描器 ────────────────────────────────────────────────────
// 【为什么不上 DOM 库】没有这个依赖,而输入是【本支自己渲染出来的】标记,
// 不是野生 HTML:没有嵌套表格、没有未闭合标签。所以扫描器只要认得
// <td>/<th> 的属性与内文就够了 —— 而它认不认得,由下面的覆盖断言现场证明。
function section(html, tag) {
    const m = html.match(new RegExp(`<${tag}\\b[^>]*>([\\s\\S]*?)</${tag}>`))
    return m ? m[1] : null
}
function cells(fragment) {
    const out = []
    const re = /<(td|th)\b([^>]*)>([\s\S]*?)<\/\1>/g
    let m
    while ((m = re.exec(fragment)) !== null) {
        const attrs = m[2]
        const cls = (attrs.match(/class="([^"]*)"/) || [, ''])[1]
        const span = Number((attrs.match(/colspan="(\d+)"/i) || [, '1'])[1])
        out.push({ tag: m[1], cls, span, inner: m[3] })
    }
    return out
}
// 手机档看得见 = 身上没有「桌面才出现」的类;桌面档看得见 = 身上没有 sm:hidden。
const onPhone = (c) => !/\bhidden sm:table-cell\b/.test(c.cls) && !/\bhidden sm:table-row\b/.test(c.cls)
const onDesktop = (c) => !/\bsm:hidden\b/.test(c.cls)
const width = (list, at) => list.filter(at === 'phone' ? onPhone : onDesktop).reduce((n, c) => n + c.span, 0)

const { DataTable } = loadComponent(SRC)
const h = React.createElement

// ── 两张样例表 ─────────────────────────────────────────────────────────────
// ★★【为什么是两张,而不是一张 —— 这一条是致盲注入逼出来的】★★
//   第一版只有 trial-balance 那一张,而它的前导两列【都是 priority】。
//   于是「手机档前导 = 前导里的 priority 列数」与「= 前导列数」在那张表上
//   **算出来一模一样**:把 `.filter(isPhoneCol)` 整个删掉,量具照样报绿。
//   ☞ 第二张(PayrollGrid 的形状)专治这一条:它的前导里【夹着一列非 priority】,
//     两种算法在它身上必然分叉。**一张不带差异的样例,证不出一条带差异的规矩。**
const SCENARIOS = [
    {
        name: 'trial-balance 形状(5 列 · 前导两列都留在手机上)',
        rows: [
            { id: 'a', code: '1000', name: 'Cash', debit: 120, credit: 0, net: 120 },
            { id: 'b', code: '2000', name: 'Payables', debit: 0, credit: 80, net: -80 },
        ],
        columns: [
            { key: 'code', header: 'Code', priority: true, render: (r) => r.code },
            { key: 'name', header: 'Account', priority: true, render: (r) => r.name },
            { key: 'debit', header: 'Debit', align: 'right', render: (r) => r.debit },
            { key: 'credit', header: 'Credit', align: 'right', render: (r) => r.credit },
            { key: 'net', header: 'Net', align: 'right', priority: true, render: (r) => r.net },
        ],
        footer: [{ key: 'totals', label: 'TOTALS_LABEL', cells: { debit: 'D_120', credit: 'C_80' } }],
        folded: ['D_120', 'C_80'],
        headDesktop: 5, headPhone: 4,
    },
    {
        name: '★ PayrollGrid 形状(4 列 · 前导里【夹着一列非 priority】)',
        rows: [
            { id: 'a', name: 'Ang', dept: 'Ops', gross: 3000, net: 2400 },
            { id: 'b', name: 'Bala', dept: 'Fin', gross: 4000, net: 3200 },
        ],
        columns: [
            { key: 'name', header: 'Employee', priority: true, render: (r) => r.name },
            // ★ 这一列不 priority —— 它就是让两种 colSpan 算法分叉的那一列。
            { key: 'dept', header: 'Dept', render: (r) => r.dept },
            { key: 'gross', header: 'Gross', align: 'right', render: (r) => r.gross },
            { key: 'net', header: 'Net', align: 'right', priority: true, render: (r) => r.net },
        ],
        footer: [{ key: 'totals', label: 'PAY_TOTALS', cells: { gross: 'G_7000', net: 'N_5600' } }],
        folded: ['G_7000'],
        headDesktop: 4, headPhone: 3,
    },
]

const problems = []
let ran = 0
let want = 0
const check = (ok, msg) => { ran++; if (!ok) problems.push(msg) }

for (const sc of SCENARIOS) {
    const base = { rows: sc.rows, columns: sc.columns, rowKey: (r) => r.id, phone: { mode: 'columns' } }
    const html = renderToStaticMarkup(h(DataTable, { ...base, footer: () => sc.footer }))

    // ── 覆盖断言:扫描器真的解析出了表头,而且格数与这张样例的声明对得上 ────
    //    对不上就是扫描器把类名读错了 —— 那时下面每一条判据都不作数。
    const head = cells(section(html, 'thead') ?? '')
    assertPopulation(SELF, `${sc.name}:<thead> 里解析出来的格子`, head.length, sc.columns.length)
    assertPinned(SELF, `${sc.name}:桌面档表头格数`, width(head, 'desktop'), sc.headDesktop,
        '对不上就是扫描器读错了类名,这一次读数不作数。')
    assertPinned(SELF, `${sc.name}:手机档表头格数(priority 列 + 展开格)`,
        width(head, 'phone'), sc.headPhone, '同上。')

    // ── ① 给了 footer 就要长出 <tfoot> ────────────────────────────────────
    const foot = section(html, 'tfoot')
    check(foot !== null, `${sc.name}:给了 footer,渲染出来【没有 <tfoot>】—— 组件没有表尾能力。`)
    want += 1
    if (!foot) continue

    const fc = cells(foot)
    check(fc.length > 0, `${sc.name}:<tfoot> 里一个格子都没有。`)

    // ── ② 两个断点各自跨满整行 ────────────────────────────────────────────
    //    本支量具的心脏:基准是【表头实际渲染出来的格数】,不是写死的数字。
    check(width(fc, 'desktop') === width(head, 'desktop'),
        `${sc.name}:桌面档表尾跨了 ${width(fc, 'desktop')} 格,表头是 ${width(head, 'desktop')} 格 —— 合计会落错列。`)
    check(width(fc, 'phone') === width(head, 'phone'),
        `${sc.name}:手机档表尾跨了 ${width(fc, 'phone')} 格,表头是 ${width(head, 'phone')} 格 —— 合计会落错列。`)

    // ── ③ 手机上折走的列,它的合计不许凭空消失 ──────────────────────────
    const phoneText = fc.filter(onPhone).map((c) => c.inner).join('')
    for (const token of sc.folded) {
        check(phoneText.includes(token),
            `${sc.name}:手机档找不到被折走那一列的合计(${token})—— 合计在 390px 上凭空消失了。`)
        want += 1
    }

    // ── ④ 标签本身两个断点都要在场 ────────────────────────────────────────
    const label = sc.footer[0].label
    check(fc.filter(onPhone).some((c) => c.inner.includes(label)), `${sc.name}:手机档表尾标签不见了。`)
    check(fc.filter(onDesktop).some((c) => c.inner.includes(label)), `${sc.name}:桌面档表尾标签不见了。`)
    want += 5
}

// ── ⑤ 不给 footer 的调用点,一个 <tfoot> 都不许长 ───────────────────────────
const plain = renderToStaticMarkup(h(DataTable, {
    rows: SCENARIOS[0].rows, columns: SCENARIOS[0].columns,
    rowKey: (r) => r.id, phone: { mode: 'columns' },
}))
check(section(plain, 'tfoot') === null,
    '没给 footer 的表也长出了 <tfoot> —— 160 个调用点的渲染被改动了。')
want += 1

// ── 覆盖断言:上面每一条判据都真的求值过 ────────────────────────────────────
assertPopulation(SELF, '跑过的样例表', SCENARIOS.length, 2)
assertAssertionsRan(SELF, ran, want)

if (problems.length) {
    console.error(`✗ ${SELF}:${problems.length} 处`)
    for (const p of problems) console.error(`   · ${p}`)
    process.exit(1)
}
console.log(`✓ ${SELF}:表尾在两个断点上各自跨满整行;折走的合计没有丢;无 footer 的表不长 <tfoot>。`)
