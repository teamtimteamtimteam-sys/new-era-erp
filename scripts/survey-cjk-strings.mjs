import ts from 'typescript'
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join } from 'node:path'
const ROOT = process.cwd()
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
function classify(node, rel) {
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
        let cat = classify(node, rel)
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
console.log(JSON.stringify(out, null, 1))
