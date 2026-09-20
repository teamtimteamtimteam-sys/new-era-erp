// ==========================================================================
// 【瞄准 · AIM】
//   我读的是      :app/ 下 .ts/.tsx 的 TypeScript AST,把每一处含中日韩字符的字符串按用途分七类。
//   我声称管的是   :给 check-cjk-rendered 提供【哪些中文会走到人眼前】这个判断。
//   两者不同之处   :★★ **我是一支分类器,而一道闸把我的分类当成了真相。**
//                   check-cjk-rendered 的覆盖率**就是我的覆盖率** —— 我漏判一类,
//                   那道闸表现为「基线变短了」,而基线变短在那边是**好消息**。
//                   ☞ NARROW-COVERAGE-1 因此在那一侧补了一条断言:
//                     基线非空时,D-rendered 这一格不许是 0。
//   ☞ 【本文件是普查,不是闸】它的红是【给读数的人的一句话】(这一次读数不可信),
//     不是一道拦住构建的门 —— 它不在 npm run build 里,也不该进去:
//     普查报的是【数】不是【违规】,接进构建会把基线漂移变成构建红,
//     而那种红会被 --update-baseline 顺手按掉。(R-Q4)

// ==========================================================================
import ts from 'typescript'
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join } from 'node:path'
const DEFAULT_ROOT = process.cwd()
const CJK = /[一-鿿　-〿＀-￯㐀-䶿]/
const SKIP = new Set(['node_modules', '.next', '.git', 'docs', 'db', 'public', 'assets'])
function* walk(d) {
    for (const n of readdirSync(d)) {
        if (SKIP.has(n)) continue
        const p = join(d, n)
        if (statSync(p).isDirectory()) yield* walk(p)
        else if (/\.tsx?$/.test(n) && !n.endsWith('.d.ts')) yield p
    }
}
// 沿祖先链判断这个字面量【落在什么位置】
function classify(node, rel, text = '') {
    if (rel.startsWith('app/brand-sampler/')) return 'A-sampler'
    // E:formatMoneyBare 的第 2 个参数 —— 它在 lib/format.ts 里被 `void` 掉,
    //    只是留在调用点的一句交代,【永远不渲染】。
    const par = node.parent
    if (par && ts.isCallExpression(par) && /formatMoneyBare$/.test(par.expression.getText())
        && par.arguments[1] === node) return 'E-doc-arg'
    // F:写进数据库的规范值(与 labelKey 成对出现),不是显示文案
    if (par && ts.isPropertyAssignment(par) && par.name.getText() === 'value') {
        const obj = par.parent
        if (obj && ts.isObjectLiteralExpression(obj)
            && obj.properties.some((q) => q.name && q.name.getText() === 'labelKey')) return 'F-stored-value'
    }
    // G:语言切换器【本来就该】用目标语言写自己
    if (rel.endsWith('LanguageSwitcher.tsx')) return 'G-by-design'
    // ════════════════════════════════════════════════════════════════════════
    // H:★ 日期格式化里那三个字(DATE-1,2026-09-20)
    // ════════════════════════════════════════════════════════════════════════
    // `lib/dates.ts` 是这套系统里【唯一】一份日期显示格式化,而 Tim 的 D4 裁的是:
    //     英文 `01 Sep 2026`   ·   ★ 中文 `2026年9月1日`
    // 那三个字**只在 isZh(locale) 为真的那一支里渲染** —— 它与 G 是同一件事:
    // **界面是哪一种语言,就说哪一种语言的话。**
    // ☞ 它【不该】进 messages:一个日期的写法是这支函数的实现,不是一条文案;
    //   把 `年` 做成一个 i18n 键,等于让人有机会把它翻译成别的东西。
    // ⚠ 判据写得【很窄】,而窄正是它不放过别的东西的全部依据:
    //   **只有这一个文件,而且只有这三个字**。这个文件里写别的中文照样会红。
    // ⚠ 判据读的是【解码后的文本】,不是 node.getText():
    //   一个 TemplateMiddle 的源码文本是 `}年${`,永远不会是一个光秃秃的 `年`。
    //   ☞ 与 AGENTS.md 那条「一支扫描器的【切词】那一层可以和它的【读取】那一层
    //     不一样瞎」同族 —— 这一次瞎的是【读取那一层拿错了东西】。
    if (rel === 'lib/dates.ts' && /^[年月日]+$/.test(text.trim())) return 'H-date-particle'
    let n = node.parent
    let depth = 0
    while (n && depth++ < 14) {
        // throw new Error(...) / console.error(...) —— 面向开发者
        if (ts.isThrowStatement(n)) return 'C-dev-throw'
        if (ts.isCallExpression(n)) {
            const t = n.expression.getText()
            if (/^console\.(error|warn|log)$/.test(t)) return 'C-dev-throw'
            if (/^(Error|TypeError)$/.test(t)) return 'C-dev-throw'
        }
        if (ts.isNewExpression(n) && /Error$/.test(n.expression.getText())) return 'C-dev-throw'
        n = n.parent
    }
    return null
}
export function scanCjk(ROOT = DEFAULT_ROOT) {
const out = []
for (const file of walk(ROOT)) {
    const rel = file.slice(ROOT.length + 1)
    if (rel.startsWith('messages/')) continue
    const src = readFileSync(file, 'utf8')
    const sf = ts.createSourceFile(rel, src, ts.ScriptTarget.Latest, true,
        /\.tsx$/.test(file) ? ts.ScriptKind.TSX : ts.ScriptKind.TS)
    const add = (node, kind, text) => {
        if (!CJK.test(text)) return
        const { line } = sf.getLineAndCharacterOfPosition(node.getStart(sf))
        let cat = classify(node, rel, text)
        // B:刻意双语 —— 同一个字面量里既有 CJK 又有拉丁字母,且带分隔符
        // B:刻意双语 —— 同一字面量里 CJK 与拉丁并存(分隔符可以是 / | ( 或空格)
        if (!cat && /[A-Za-z]/.test(text) && /[\/|( ]/.test(text)) cat = 'B-bilingual'
        // F2:纯 CJK 标点(顿号/括号/句号)—— 渲染出来的是分隔符,不是句子
        if (!cat && /^[、。（）：；「」【】·]+$/.test(text.trim())) cat = 'F2-punctuation'
        if (!cat) cat = 'D-rendered'
        out.push({ file: rel, line: line + 1, kind, cat, text: text.trim().replace(/\s+/g, ' ').slice(0, 100) })
    }
    const visit = (node) => {
        if (ts.isJsxText(node)) add(node, 'jsx-text', node.text)
        else if (ts.isStringLiteral(node)) add(node, 'string', node.text)
        else if (ts.isNoSubstitutionTemplateLiteral(node)) add(node, 'template', node.text)
        else if (ts.isTemplateHead(node) || ts.isTemplateMiddle(node) || ts.isTemplateTail(node)) add(node, 'template', node.text)
        ts.forEachChild(node, visit)
    }
    visit(sf)
}
return out
}

// CLI:直接跑就打印全量分类结果(它是【勘察】)。
// 闸在 scripts/check-cjk-rendered.mjs —— 两者共用【同一个】分类器,
// 免得勘察与闸各自长出一套判据然后悄悄分家。
if (import.meta.url === `file://${process.argv[1]}`) {
    console.log(JSON.stringify(scanCjk(), null, 1))
}
