#!/usr/bin/env node
// scripts/check-pdf-font-stack.mjs —— PDF 文档里的【字体】体检。
//
// ════════════════════════════════════════════════════════════════════════════
// 【它防的是一个已经发生过的缺陷,不是一种假想】(PDF-1,2026-09-02)
// ════════════════════════════════════════════════════════════════════════════
// StatementDocument.tsx 把 page 写成 `fontFamily: 'Helvetica'`,另有六处
// `'Helvetica-Bold'`。Helvetica 是 PDF 内置字体,**一个汉字都没有**。
// 于是对账单上的 `上海金属回收有限公司` 印出来是 **`wÑ^Þ6 Plø`** ——
// 不是空白、不是豆腐块,是一串看起来像模像样的重音拉丁字母,所以没人发现。
// 而对账单的全部用途,就是寄给欠款人要钱。
//
// ★【这条规矩当时【已经写下来了】,写在发票文档里,而它没有拦住任何人】★
//     「凡是要加粗的地方一律用 fontWeight: 'bold'(而不是 fontFamily:
//       'Helvetica-Bold'),否则等于把那个节点换回了拉丁字体。」
// 一条要靠人读到、记住、并照做的规矩,与一条没写的规矩,区别只在于写下来的
// 那个人以为它生效了。**本仓库对"第二次就换成机制"有明文门槛,这是兑现。**
//
// ★【为什么运行时的守卫拦不住它】★
// 路由确实调了 findUnrenderableText(),但那道守卫查的是【覆盖清单】的码位,
// 而清单描述的是 Google Sans + Noto Sans SC。文档嵌的却是 Helvetica ——
// **标签与判据问的不是同一件事**,所以它每一次都通过。
// 运行时守卫回答"这些字这个栈画得出来吗";本支回答"这份文档嵌的【真的是】那个栈吗"。
// 两个问题,两支检查,谁也替不了谁。
//
// ════════════════════════════════════════════════════════════════════════════
// 【判据】PDF 文档文件里,`fontFamily:` 的值必须是 DOC_FONT_STACK 这个标识符。
// ════════════════════════════════════════════════════════════════════════════
//   fontFamily: DOC_FONT_STACK          ← 唯一允许的写法
//   fontFamily: 'Helvetica'             ← 红
//   fontFamily: 'Helvetica-Bold'        ← 红
//   fontFamily: INVOICE_FONT_FAMILY     ← 红(单个家族:中文能印,但拉丁也被它画走)
//   fontFamily: ['Google Sans', ...]    ← 红(就地重写一遍栈 = 第二份真源)
//
// 【什么算"PDF 文档文件"】import 了 '@react-pdf/renderer' 的 .ts/.tsx。
// 这是【结构判据,不是路径判据】:按目录名(*/pdf/*)判会漏掉
// app/inventory/reports/ReportDocument.tsx 与 app/components/pdf/ 下的零件,
// 而按 import 判,一个文件只要用得上 StyleSheet 就必然落在射程里。
//
// 【它不查什么】—— 说清楚,免得绿灯被读成"字体一定对"。
// 它查的是【源码里写没写别的字体】。它【不】验证 coverage.json 与 .subset.ttf
// 是否对得上(那由 subset.py 同一次产出保证),也【不】验证渲染结果的字形
// (那要真的渲染,是 STEP 4 的事)。一支说得比自己做得多的检查,比没有更坏。
import { readdirSync, readFileSync, statSync } from 'node:fs'
import { join, relative } from 'node:path'

const ROOT = process.cwd()
const EXTS = new Set(['.tsx', '.ts'])
const SKIP_DIRS = new Set(['node_modules', '.next', '.git', 'public', 'assets', 'db', 'docs'])

// 例外必须带【写下来的理由】,与 check-currency-literals 的 ALLOWLIST 同一形状。
// 空着不是疏忽 —— 今天一处例外都不需要,而那正是它该有的样子。
const ALLOWLIST = [
    // { path: '...', match: '...', reason: '...' },
]

const ALLOWED_IDENTIFIER = 'DOC_FONT_STACK'

function* walk(dir) {
    for (const e of readdirSync(dir)) {
        if (SKIP_DIRS.has(e)) continue
        const p = join(dir, e)
        if (statSync(p).isDirectory()) yield* walk(p)
        else if (EXTS.has(p.slice(p.lastIndexOf('.')))) yield p
    }
}

/** 整行注释与块注释里的 fontFamily 是【在讲这条规矩】,不是在设字体。 */
function stripComments(src) {
    return src.replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, ' '))
              .replace(/(^|[^:])\/\/[^\n]*/g, (m, p1) => p1 + ' '.repeat(m.length - p1.length))
}

const problems = []
let scanned = 0

for (const abs of walk(ROOT)) {
    const raw = readFileSync(abs, 'utf8')
    if (!raw.includes('@react-pdf/renderer')) continue
    scanned += 1
    const rel = relative(ROOT, abs)
    const src = stripComments(raw)

    for (const m of src.matchAll(/fontFamily\s*:\s*([^,\n}]+)/g)) {
        const value = m[1].trim().replace(/\s+as\s+never$/, '').trim()
        if (value === ALLOWED_IDENTIFIER) continue
        const line = src.slice(0, m.index).split('\n').length
        if (ALLOWLIST.some((a) => a.path === rel && value.includes(a.match))) continue
        problems.push({ rel, line, value })
    }
}

// ★ 零不是一个可以推出来的数 —— 它必须是一次测量 ★
// 扫到 0 个 PDF 文件时报绿,与"每一份都合规"在屏幕上长得一模一样。本仓库为
// 这一族(check_xmodule_views 的 return-count、check-i18n 的零后缀)已经付过账。
if (scanned === 0) {
    console.error('✗ check-pdf-font-stack:一个 PDF 文档文件都没扫到。')
    console.error('  判据(import 了 @react-pdf/renderer)多半失效了 —— 这不是"没有问题",是没有测量。')
    process.exit(2)
}

if (problems.length) {
    console.error(`✗ check-pdf-font-stack:${problems.length} 处 PDF 文档写了字体栈以外的 fontFamily\n`)
    for (const p of problems) {
        console.error(`  ${p.rel}:${p.line}`)
        console.error(`      fontFamily: ${p.value}`)
    }
    console.error(
        `\n  对外单据的字体只有一个来源:app/components/pdf/fonts.ts 的 ${ALLOWED_IDENTIFIER}。\n` +
        `  写死一个家族名(尤其是内置的 Helvetica)会让那个节点【没有中文字形】——\n` +
        `  汉字不会报错,会印成一串重音拉丁字母(实测:上海金属回收有限公司 → wÑ^Þ6 Plø),\n` +
        `  而运行时的覆盖守卫查的是另一组字体,所以它【不会】拦住你。\n\n` +
        `  要加粗:fontWeight: 'bold'(栈里两个家族都注册了 400 与 700)。\n` +
        `  真有例外:写进本文件的 ALLOWLIST,【带理由】。`
    )
    process.exit(1)
}

console.log(`✓ check-pdf-font-stack:${scanned} 个 PDF 文档文件,字体栈一致(${ALLOWED_IDENTIFIER})`)
