// GOLIVE-2 Step 0 · row 10 survey: every Supabase read chain in app/ and lib/, found by the TypeScript AST (not by grep).
//   A chain = the call expression rooted at `.from('<rel>')` or `.rpc('<fn>')`, walked up through every `.method(...)`.
//   Bucket per chain: write (insert/update/upsert/delete) · one (single/maybeSingle) · head (count head:true) · paged (.range)
//   · capped (.limit) · unbounded (none of those). Prints JSON lines; only reads repo files.
import ts from 'typescript'
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join } from 'node:path'
const files = []
const walk = (d) => { for (const f of readdirSync(d)) { const p = join(d, f); const s = statSync(p)
    if (s.isDirectory()) { if (f !== 'node_modules') walk(p) } else if (/\.(ts|tsx)$/.test(f) && !f.endsWith('.d.ts') && f !== 'database.types.ts') files.push(p) } }
walk('app'); walk('lib')
const out = []
let fromCalls = 0, rpcCalls = 0
for (const file of files) {
    const src = readFileSync(file, 'utf8')
    const sf = ts.createSourceFile(file, src, ts.ScriptTarget.Latest, true, file.endsWith('x') ? ts.ScriptKind.TSX : ts.ScriptKind.TS)
    const visit = (n) => {
        if (ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression) && ['from', 'rpc'].includes(n.expression.name.text)
            && n.arguments.length && !(ts.isPropertyAccessExpression(n.expression.expression) && n.expression.expression.name.text === 'storage')) {
            const kind = n.expression.name.text
            const arg = n.arguments[0]
            const rel = ts.isStringLiteralLike(arg) ? arg.text : '<' + arg.getText(sf).slice(0, 40) + '>'
            if (kind === 'from') fromCalls++; else rpcCalls++
            // walk up the chain
            let top = n; const methods = []; const args = []
            for (;;) {
                const p = top.parent
                if (p && ts.isPropertyAccessExpression(p) && p.expression === top && p.parent && ts.isCallExpression(p.parent) && p.parent.expression === p) {
                    methods.push(p.name.text); args.push(p.parent.arguments.map((a) => a.getText(sf)).join(', ').slice(0, 80)); top = p.parent
                } else break
            }
            const text = top.getText(sf)
            const has = (m) => methods.includes(m)
            let bucket
            if (['insert', 'update', 'upsert', 'delete'].some(has)) bucket = 'write'
            else if (has('single') || has('maybeSingle')) bucket = 'one'
            else if (/head:\s*true/.test(text)) bucket = 'head'
            else if (has('range')) bucket = 'paged'
            else if (has('limit')) bucket = 'capped'
            else bucket = 'unbounded'
            // a builder that leaves this expression (assigned / returned / passed on) may be paged later — follow it
            let escapes = null
            if (bucket === 'unbounded') {
                let q = top.parent
                while (q && (ts.isAwaitExpression(q) || ts.isParenthesizedExpression(q) || ts.isAsExpression(q))) q = q.parent
                if (q && ts.isVariableDeclaration(q) && ts.isIdentifier(q.name) && top.parent === q) escapes = 'var:' + q.name.text
                else if (q && ts.isBinaryExpression(q) && q.operatorToken.kind === ts.SyntaxKind.EqualsToken && q.right === top && ts.isIdentifier(q.left)) escapes = 'var:' + q.left.text
                else if (q && ts.isReturnStatement(q) && top.parent === q) escapes = 'returned'
                else if (q && ts.isArrowFunction(q) && q.body === top) escapes = 'returned'
                else if (q && ts.isCallExpression(q) && q.arguments.includes(top)) escapes = 'passed:' + q.expression.getText(sf).slice(0, 40)
                if (escapes?.startsWith('var:')) {
                    const v = escapes.slice(4)
                    const re = new RegExp(`\\b${v}\\s*(?:=\\s*${v}\\s*)?\\.(range|limit|single|maybeSingle)\\(|\\b(?:pageRange|applyRange|readAll|fetchAll|paged|withRange)\\w*\\(\\s*${v}\\b`)
                    const m = src.slice(top.getEnd()).match(re)
                    if (m) bucket = 'paged-later'
                    else if (new RegExp(`\\(\\s*${v}\\b|\\b${v}\\s*\\)`).test(src.slice(top.getEnd()))) escapes += ' (handed on)'
                }
            }
            const filters = methods.map((m, i) => ({ m, a: args[i] })).filter((x) => ['eq', 'in', 'match', 'filter', 'or', 'gte', 'lte', 'lt', 'gt', 'is', 'not', 'neq', 'ilike', 'like', 'contains'].includes(x.m))
            const line = sf.getLineAndCharacterOfPosition(n.getStart(sf)).line + 1
            out.push({ file, line, kind, rel, bucket, escapes, methods: methods.join('.'), filters: filters.map((f) => `${f.m}(${f.a})`).join(' ') })
        }
        ts.forEachChild(n, visit)
    }
    visit(sf)
}
for (const o of out) console.log(JSON.stringify(o))
console.error(`SCAN|${files.length} files · ${fromCalls} .from() · ${rpcCalls} .rpc() · ${out.length} chains · ` +
    Object.entries(out.reduce((m, o) => (m[o.bucket] = (m[o.bucket] ?? 0) + 1, m), {})).map(([k, v]) => `${k} ${v}`).join(' · '))
// coverage: an independent count of `.from(` / `.rpc(` text occurrences (minus storage.from) must not be far below the AST count
const textCount = files.reduce((n, f) => { const s = readFileSync(f, 'utf8'); return n + (s.match(/\.(from|rpc)\(\s*['"`]/g) ?? []).length - (s.match(/storage\s*\.from\(/g) ?? []).length }, 0)
console.error(`SCAN|independent text count of .from('…') / .rpc('…') (string-literal first arg, storage excluded): ${textCount}`)
