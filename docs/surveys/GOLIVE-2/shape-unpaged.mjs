import ts from 'typescript'
import { readFileSync } from 'node:fs'
import { listFiles, loadConfig, scanFile } from '../../../scripts/unpaged-reads/classify.mjs'

const cfg = loadConfig(); const t = {}; const ex = {}
for (const f of listFiles()) { const s = readFileSync(f, 'utf8'); for (const r of scanFile(f, s, cfg).reads) { if (r.verdict !== 'UNPAGED') continue
  let q = r.top.parent; while (q && (ts.isParenthesizedExpression(q) || ts.isAsExpression(q))) q = q.parent
  const ctx = ts.isAwaitExpression(q) ? 'await' : ts.isArrayLiteralExpression(q) ? 'array(Promise.all)' : ts.isVariableDeclaration(q) ? 'var' : ts.isReturnStatement(q) || ts.isArrowFunction(q) ? 'returned' : ts.isCallExpression(q) ? 'arg:' + q.expression.getText(r.sf).slice(0, 30) : ts.SyntaxKind[q.kind]
  const k = `${r.kind}${r.rel ? '' : '(dynamic)'} ${ctx.startsWith('arg:') ? 'arg' : ctx}`; t[k] = (t[k] ?? 0) + 1
  if (!['await', 'array(Promise.all)'].includes(ctx)) (ex[k] ??= []).push(`${r.file}:${r.line} ${r.relText} ${ctx}`) } }
console.log(t); for (const [k, v] of Object.entries(ex)) { console.log('==', k); for (const x of v.slice(0, 40)) console.log('  ', x) }
