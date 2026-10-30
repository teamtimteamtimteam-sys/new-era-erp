// GOLIVE-2 · 改写之后的一次核对:哪几处 readAll(…) / readAllIn(…) 的【返回值】被直接 cast 掉(as …)—— 在那里 tsc 看不见"拿 Promise 当 builder 用"。
//   (/hr/training 就是这样漏过 tsc、在冒烟里 500 的:let query = readAll(…) as unknown as Chain; query.eq(…))只读仓库文件。
import ts from 'typescript'
import { readFileSync } from 'node:fs'
import { listFiles } from '../../../scripts/unpaged-reads/classify.mjs'
for (const f of listFiles()) {
    const src = readFileSync(f, 'utf8')
    if (!src.includes('readAll')) continue
    const sf = ts.createSourceFile(f, src, ts.ScriptTarget.Latest, true, f.endsWith('x') ? ts.ScriptKind.TSX : ts.ScriptKind.TS)
    const visit = (n) => {
        if (ts.isCallExpression(n) && ts.isIdentifier(n.expression) && /^readAll(In)?$/.test(n.expression.text)) {
            let p = n.parent
            while (p && ts.isParenthesizedExpression(p)) p = p.parent
            if (p && (ts.isAsExpression(p) || ts.isTypeAssertionExpression(p))) {
                const line = sf.getLineAndCharacterOfPosition(n.getStart(sf)).line + 1
                console.log(`CAST ${f}:${line} → ${p.type.getText(sf).slice(0, 60)}`)
            }
        }
        ts.forEachChild(n, visit)
    }
    visit(sf)
}
// 第二问:readAll(…) 落在一个【不是】await / 数组(Promise.all)/ 条件分支 / return / 变量初值 / 箭头函数体 的位置上 —— 列出来逐个看
for (const f of listFiles()) {
    const src = readFileSync(f, 'utf8')
    if (!src.includes('readAll')) continue
    const sf = ts.createSourceFile(f, src, ts.ScriptTarget.Latest, true, f.endsWith('x') ? ts.ScriptKind.TSX : ts.ScriptKind.TS)
    const visit = (n) => {
        if (ts.isCallExpression(n) && ts.isIdentifier(n.expression) && /^readAll(In)?$/.test(n.expression.text)) {
            let p = n.parent
            while (p && ts.isParenthesizedExpression(p)) p = p.parent
            const fine = ts.isAwaitExpression(p) || ts.isArrayLiteralExpression(p) || ts.isConditionalExpression(p) || ts.isReturnStatement(p)
                || ts.isVariableDeclaration(p) || ts.isArrowFunction(p) || ts.isAsExpression(p)
            if (!fine) console.log(`ODD ${f}:${sf.getLineAndCharacterOfPosition(n.getStart(sf)).line + 1} parent ${ts.SyntaxKind[p.kind]} ${p.getText(sf).slice(0, 80).replace(/\s+/g, ' ')}`)
        }
        ts.forEachChild(n, visit)
    }
    visit(sf)
}
