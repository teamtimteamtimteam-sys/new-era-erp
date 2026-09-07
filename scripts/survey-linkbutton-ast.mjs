#!/usr/bin/env node
// scripts/survey-linkbutton-ast.mjs
// ════════════════════════════════════════════════════════════════════════════
// ★ SURVEY TOOL — NOT A GATE. BTN-6(2026-09-07)。
//   它只回答一个问题:**app 里还有多少个「长得像按钮」的 <Link>/<a>?**
//   断言什么都不断言、拦什么都不拦、不被任何 build / gate / smoke 调用。
//   退出码:0 —— 除非本脚本自己崩了。
//
// ════════════════════════════════════════════════════════════════════════════
// ★★【它为什么必须存在,而不是"BTN-5b 当时量过了"】★★
// ════════════════════════════════════════════════════════════════════════════
//   docs/base-components.md §18.2 记着一张两条路的对照表(棘轮 114/115,
//   AST 115),§18.3 还记着一张三行的故障注入表。**而那条 AST 路从来没有进过仓库。**
//   BTN-6 复查时,scripts/ 里唯一用 TypeScript 编译器的脚本是 survey-cjk-strings.mjs,
//   干的是另一件事。也就是说:
//
//     ☞ **BTN-5b 最核心的那句证据(「两条路逐条集合相等,差集两边都是空」)
//        今天没有任何人能重跑。**
//
//   而这正是 BTN-5b 自己在修的那一类缺陷 —— 一个没有调用点的能力和一个坏掉的
//   能力,在任何检查的退出码上都是同一个字节。一次跑完就扔掉的校对,与一次
//   没做过的校对,在仓库里留下的痕迹**完全相同**。
//
// ════════════════════════════════════════════════════════════════════════════
// ★★【它凭什么算"独立的第二路"—— 判据是【不共用失效模式】★★
// ════════════════════════════════════════════════════════════════════════════
//   §十七 写死过这一条:**一条独立的第二路,只有在不共用第一路的失效模式时
//   才是独立的。** 棘轮(路 A)的失效模式是它自己踩过的那些:
//       · 按行切分 → 多行标签看不见(本族踩过 6 次)
//       · 正则找标签 → 换行处的前瞻匹配不上
//       · 注释污染 → 要先手写一个 stripComments(本族踩过 5 次)
//       · 花括号配平 → 要手写 readTag / grabClass
//   本路一件都不做:
//       ✗ 不按行切     ✗ 不用正则找标签   ✗ 不做花括号配平
//       ✗ 不剥注释 —— 注释在解析器里【根本不是节点】,天然排除
//   它读的是 TypeScript 编译器建出来的语法树,失效模式与路 A 没有交集。
//
// ════════════════════════════════════════════════════════════════════════════
// ★★【className 的解析:这里【比路 A 更强】,而强的地方要说出口】★★
// ════════════════════════════════════════════════════════════════════════════
//   路 A 靠正则把同文件常量代回去,而它为此付过一次账:BTN-5b 发现
//   `className={base + ' ' + (active ? … : …)}` 这种写法【整个看不见】。
//   本路不打补丁 —— 它顺着表达式的语法树往下走,把每一片字符串收齐:
//       字符串字面量 · 模板串(头 + 每一段 + 每个插值) · `+` 二元表达式
//       · 三元的两侧 · 括号 · 标识符(查同文件的 const 字符串)
//   ☞ 于是 `+` 拼接不是一个需要被特判的形状,**它就是二元表达式的普通一支**。
//
//   ★ 判据本身与路 A【逐字相同】,这是有意的:两条路要量同一件东西,
//     否则它们的一致或分歧都不说明任何事情。
//       两个方向的内边距 + 圆角 +(实底 或 描边)
//
// ════════════════════════════════════════════════════════════════════════════
// ★★【它看不见什么 —— 不许把边界说宽】★★
// ════════════════════════════════════════════════════════════════════════════
//   ✗ 跨文件的常量:`import { CLS } from './styles'` 里的 CLS 解析不出来。
//     两条路在这一点上【同样瞎】,所以它不是分歧的来源,但它是共同的盲区。
//   ✗ 运行期才拼出来的 className(探针 probe-button-tiers 的 RAWLINK 维读 DOM,
//     看得见这一类 —— 两件仪器的盲区在这里互补)。
//   ✗ 档位【选得对不对】。一个坐在面板抬头里、却写成 variant="link" 的库按钮,
//     本脚本一声不吭 —— 它连库按钮都不数。见 §十九 那条「没有任何仪器看得见
//     错档」的记录(BTN-6/F5 是第一处量出来的实例)。
//
// 用法:node scripts/survey-linkbutton-ast.mjs [--json]
// ════════════════════════════════════════════════════════════════════════════
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join, relative } from 'node:path'
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const ts = require('typescript')

const ROOT = process.cwd()
const APP = join(ROOT, 'app')
// 组件库自己住的地方 —— 与路 A 同一条界线(扫它等于罚它做对的事)。
const LIBRARY_DIR = join(ROOT, 'app/components/ui')

function walk(dir, out = []) {
    for (const e of readdirSync(dir)) {
        const p = join(dir, e)
        if (statSync(p).isDirectory()) {
            if (p === LIBRARY_DIR) continue
            walk(p, out)
        } else if (p.endsWith('.tsx')) out.push(p)
    }
    return out
}

// ── 判据:与路 A 逐字相同 ────────────────────────────────────────────────────
const padBoth = (c) => /(^|[\s"'`{])p-\S/.test(c)
    || (/(^|[\s"'`{])px-\S/.test(c) && /(^|[\s"'`{])py-\S/.test(c))
    || (/(^|[\s"'`{])pl-\S/.test(c) && /(^|[\s"'`{])pr-\S/.test(c) && /(^|[\s"'`{])py-\S/.test(c))
const hasRadius = (c) => /(^|[\s"'`{])rounded(-|\b)/.test(c)
const hasFill = (c) => /(^|[\s"'`{])bg-[a-z\[]/.test(c)
const hasBorder = (c) => /(^|[\s"'`{])border(\b|-)/.test(c)
const isButtonShaped = (c) => padBoth(c) && hasRadius(c) && (hasFill(c) || hasBorder(c))

// ── 把一个表达式里所有的字符串片收齐 ────────────────────────────────────────
// 【为什么是递归,不是特判】`+` 拼接、模板串、三元,在语法树里是三种节点,
// 但要做的事是同一件:往下走,把字符串收上来。特判会漏掉第四种写法 ——
// 而路 A 正是这么漏掉 SettingsSubnav 的。
function collectStrings(node, consts, seen = new Set()) {
    if (!node) return ''
    if (ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node)) return node.text
    if (ts.isTemplateExpression(node)) {
        let s = node.head.text
        for (const span of node.templateSpans) {
            s += ' ' + collectStrings(span.expression, consts, seen) + ' ' + span.literal.text
        }
        return s
    }
    if (ts.isBinaryExpression(node)) {
        return collectStrings(node.left, consts, seen) + ' ' + collectStrings(node.right, consts, seen)
    }
    if (ts.isConditionalExpression(node)) {
        return collectStrings(node.whenTrue, consts, seen) + ' ' + collectStrings(node.whenFalse, consts, seen)
    }
    if (ts.isParenthesizedExpression(node)) return collectStrings(node.expression, consts, seen)
    if (ts.isJsxExpression(node)) return collectStrings(node.expression, consts, seen)
    if (ts.isIdentifier(node)) {
        const name = node.text
        if (seen.has(name)) return ''            // 自引用护栏
        if (!(name in consts)) return ''
        seen.add(name)
        return collectStrings(consts[name], consts, seen)
    }
    // 函数调用(cn(...)、clsx(...))里的实参照收 —— 它们也是 className 的一部分。
    if (ts.isCallExpression(node)) {
        return node.arguments.map((a) => collectStrings(a, consts, seen)).join(' ')
    }
    if (ts.isArrayLiteralExpression(node)) {
        return node.elements.map((a) => collectStrings(a, consts, seen)).join(' ')
    }
    return ''
}

const files = walk(APP)
const hits = []
let openTags = 0
const openTagFiles = new Set()

for (const file of files) {
    const rel = relative(ROOT, file)
    const src = readFileSync(file, 'utf8')
    const sf = ts.createSourceFile(rel, src, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX)

    // 同文件里的 const:名字 → 初始化表达式节点(值本身也走同一个解析器)
    const consts = Object.create(null)
    ;(function collectConsts(n) {
        if (ts.isVariableDeclaration(n) && ts.isIdentifier(n.name) && n.initializer) {
            consts[n.name.text] = n.initializer
        }
        ts.forEachChild(n, collectConsts)
    })(sf)

    ;(function visit(n) {
        const isOpen = ts.isJsxOpeningElement(n) || ts.isJsxSelfClosingElement(n)
        if (isOpen) {
            const tag = n.tagName.getText(sf)
            if (tag === 'Link' || tag === 'a') {
                openTags++
                openTagFiles.add(rel)
                const attr = n.attributes.properties.find(
                    (p) => ts.isJsxAttribute(p) && p.name.getText(sf) === 'className'
                )
                const cls = attr ? collectStrings(attr.initializer, consts) : ''
                if (isButtonShaped(cls)) {
                    const { line } = sf.getLineAndCharacterOfPosition(n.getStart(sf))
                    hits.push({ file: rel, line: line + 1, cls: cls.trim().replace(/\s+/g, ' ') })
                }
            }
        }
        ts.forEachChild(n, visit)
    })(sf)
}

const byFile = new Map()
for (const h of hits) byFile.set(h.file, (byFile.get(h.file) ?? 0) + 1)

if (process.argv.includes('--json')) {
    console.log(JSON.stringify({ openTags, openTagFiles: openTagFiles.size, hits }, null, 2))
} else {
    console.log('── 路 B(TypeScript 编译器 AST)· 按钮态链接普查 ' + '─'.repeat(28))
    console.log(`扫描 ${files.length} 个 .tsx(app/,不含 app/components/ui/)`)
    console.log(`<Link>/<a> 开标签总数:${openTags} / ${openTagFiles.size} 个文件`)
    console.log(`★ 按钮态链接:${hits.length} 处 / ${byFile.size} 个文件`)
    console.log('')
    for (const [f, n] of [...byFile].sort()) console.log(`  ${f}${n > 1 ? '  ×' + n : ''}`)
    console.log('')
    for (const h of hits) console.log(`  ${h.file}:${h.line}  ${h.cls.slice(0, 90)}`)
}
