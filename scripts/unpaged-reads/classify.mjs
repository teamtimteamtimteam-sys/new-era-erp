// ════════════════════════════════════════════════════════════════════════════
// GOLIVE-2 第 10 行(Tim 2026-10-30 Q1)· 一次 supabase-js 读取【会不会悄悄停在第 1,000 行】—— 判法只有这一份
// ════════════════════════════════════════════════════════════════════════════
// scripts/check-unpaged-reads.mjs(构建闸)与 GOLIVE-2 那一次改写(docs/surveys/GOLIVE-2/codemod-unpaged-reads.mjs)都 import 这里,
//   所以"闸认为要改的"与"改写改掉的"是同一个集合。只读仓库文件,不碰库、不碰网络。
//
// 一条读取 = 以 `.from('<关系>')` 或 `.rpc('<函数>')` 起头、沿 `.method(…)` 往上走到头的那一整串(TypeScript AST,不是正则 ——
//   注释与字符串里的同名字不进 AST)。这一串被交给一个函数(applyFilters(…))时,接着从那个调用往上走:外面那一层加的 .range 也算。
// 判词(verdict):
//   write    insert / update / upsert / delete
//   one      single / maybeSingle
//   head     count + head: true(只回一个数)
//   paged    .range(…)
//   capped   .limit(n) 且 n ≤ 1000(一个刻意的上限,页面上说出「前 N 条」)
//   overcap  .limit(n) 且 n > 1000 —— 线上照样只给 1,000 行,而写的人以为是 n(/inventory/reports/ledger 曾经就是 .limit(2000))
//   helper   在 readAll(() => …) / readAllIn(ids, (c) => …) 里面
//   bounded  关系在 scripts/unpaged-reads/bounded-relations.json 里(带理由)
//   scalar   .rpc 的函数不回一组行(lib/database.types.ts 里 Returns 不是 […][])
//   parent   .eq('<父键>', …) 筛到一条记录的孩子,而那一对 (关系.父键) 在年体量种子上量过、一位父亲最多 ≤ LIMIT 行
//   exempt   那一串起头那一行或上一行写着 `unpaged-ok: <理由>`
//   later    交给了一个变量,而后面那个变量被 .range / .limit / .single 过
//   UNPAGED  以上都不是 —— 一张会长的表上一条不翻页的读取(闸红)
// ════════════════════════════════════════════════════════════════════════════
import ts from 'typescript'
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join } from 'node:path'

export const SCAN_ROOTS = ['app', 'lib']

export function listFiles(root = '.') {
    const files = []
    const walk = (d) => {
        for (const f of readdirSync(d)) {
            const p = join(d, f)
            const s = statSync(p)
            if (s.isDirectory()) { if (f !== 'node_modules') walk(p) }
            else if (/\.(ts|tsx)$/.test(f) && !f.endsWith('.d.ts') && f !== 'database.types.ts') files.push(p)
        }
    }
    for (const r of SCAN_ROOTS) walk(join(root, r))
    return files.sort()
}

/** lib/database.types.ts 的 Functions 一节:哪几支回一组行(Returns: …[]) */
export function setReturningFunctions(typesPath = 'lib/database.types.ts') {
    const src = readFileSync(typesPath, 'utf8')
    const a = src.indexOf('\n    Functions: {')
    const b = src.indexOf('\n    Enums: {', a)
    if (a < 0 || b < 0) throw new Error('UNPAGED_TYPES_UNREADABLE|cannot find the Functions section of lib/database.types.ts')
    const body = src.slice(a, b)
    const names = [...body.matchAll(/^ {6}([a-z_][a-z0-9_]*): /gm)]
    const out = new Set()
    for (let i = 0; i < names.length; i++) {
        const seg = body.slice(names[i].index, i + 1 < names.length ? names[i + 1].index : body.length)
        // 每一个 Returns(重载各自一个)从它那一行起、到下一个 Args / Returns / SetofOptions 或这一段末尾为止;以 `[]` 收尾 = 回一组行
        const rets = [...seg.matchAll(/Returns: ([\s\S]*?)(?=\n\s+(?:Args|Returns|SetofOptions):|\n {6}\}|$)/g)]
        if (rets.some((m) => /\[\]\s*$/.test(m[1].trimEnd()))) out.add(names[i][1])
    }
    if (out.size === 0) throw new Error('UNPAGED_TYPES_UNREADABLE|0 set-returning functions parsed — the parser is blind, not the schema empty')
    return out
}

export function loadConfig(root = '.') {
    const bounded = JSON.parse(readFileSync(join(root, 'scripts/unpaged-reads/bounded-relations.json'), 'utf8'))
    const parent = JSON.parse(readFileSync(join(root, 'scripts/unpaged-reads/per-parent-max.json'), 'utf8'))
    for (const [rel, why] of Object.entries(bounded.relations)) {
        if (!bounded.reasons[why]) throw new Error(`UNPAGED_CONFIG|bounded relation ${rel} names an unknown reason "${why}"`)
    }
    return { bounded: bounded.relations, reasons: bounded.reasons, parentMax: parent.measured, parentLimit: parent.limit,
             setof: setReturningFunctions(join(root, 'lib/database.types.ts')) }
}

/** 这一串往上走到头(交给函数的,接着从那个调用往上走) */
function walkChain(n) {
    let top = n
    const methods = []
    const args = []
    for (;;) {
        const p = top.parent
        if (p && ts.isPropertyAccessExpression(p) && p.expression === top && p.parent && ts.isCallExpression(p.parent) && p.parent.expression === p) {
            methods.push(p.name.text)
            args.push(p.parent.arguments)
            top = p.parent
            continue
        }
        // 交给一个函数当第一个参数(applyFilters(q, …) / applyListSort(q, …)):那个函数回的仍是这条读取,接着往上走
        if (p && ts.isCallExpression(p) && p.arguments[0] === top && !isHelperCall(p) && ts.isIdentifier(p.expression)
            && /^(apply|with|add|filter|narrow|sorted|scope)/i.test(p.expression.text)) {
            methods.push('→' + p.expression.text)
            args.push(p.arguments)
            top = p
            continue
        }
        break
    }
    return { top, methods, args }
}

function isHelperCall(c) {
    return ts.isCallExpression(c) && ts.isIdentifier(c.expression) && (c.expression.text === 'readAll' || c.expression.text === 'readAllIn')
}

/** 在 readAll(() => …) / readAllIn(ids, (c) => …) 的回调里面吗 */
function insideHelper(n) {
    for (let p = n.parent; p; p = p.parent) {
        if ((ts.isArrowFunction(p) || ts.isFunctionExpression(p)) && p.parent && isHelperCall(p.parent) && p.parent.arguments.includes(p)) return true
        if (ts.isSourceFile(p)) return false
    }
    return false
}

function exemptReason(sf, src, n) {
    const line = sf.getLineAndCharacterOfPosition(n.getStart(sf)).line
    // 也认那一整句(变量声明 / return / 表达式语句)起头那一行与它上一行:一串跨好几行时理由写在句首
    let st = n
    while (st.parent && !ts.isSourceFile(st.parent) && !(ts.isVariableStatement(st) || ts.isReturnStatement(st) || ts.isExpressionStatement(st))) st = st.parent
    const sline = sf.getLineAndCharacterOfPosition(st.getStart(sf)).line
    const lines = src.split('\n')
    for (const l of [lines[line], lines[line - 1], lines[sline], lines[sline - 1]]) {
        const m = l && l.match(/unpaged-ok:\s*(.+?)\s*(\*\/)?$/)
        if (m) return m[1]
    }
    return null
}

/**
 * 扫一个文件,返回每一条读取 { file, line, kind, rel, verdict, reason, node, top, sf }。
 * literalCount:起头参数是字符串字面量的 .from / .rpc 个数(覆盖断言用,与正则那一条独立的数对照)。
 */
export function scanFile(file, src, cfg) {
    const sf = ts.createSourceFile(file, src, ts.ScriptTarget.Latest, true, file.endsWith('x') ? ts.ScriptKind.TSX : ts.ScriptKind.TS)
    const out = []
    let literalCount = 0
    const visit = (n) => {
        if (ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression) && ['from', 'rpc'].includes(n.expression.name.text)
            && n.arguments.length
            && !(ts.isPropertyAccessExpression(n.expression.expression) && n.expression.expression.name.text === 'storage')
            && !(ts.isIdentifier(n.expression.expression) && ['Array', 'Buffer', 'Object'].includes(n.expression.expression.text))) {
            const kind = n.expression.name.text
            const a0 = n.arguments[0]
            const literal = ts.isStringLiteralLike(a0)
            if (literal) literalCount++
            const rel = literal ? a0.text : null
            const { top, methods, args } = walkChain(n)
            const has = (m) => methods.includes(m)
            const text = top.getText(sf)
            const line = sf.getLineAndCharacterOfPosition(n.getStart(sf)).line + 1
            const rec = { file, line, kind, rel, relText: literal ? rel : a0.getText(sf), node: n, top, sf, methods }
            let verdict = null, reason = null
            const limitArg = methods.indexOf('limit') >= 0 ? args[methods.indexOf('limit')][0] : null
            if (['insert', 'update', 'upsert', 'delete'].some(has)) verdict = 'write'
            else if (has('single') || has('maybeSingle')) verdict = 'one'
            else if (/head:\s*true/.test(text)) verdict = 'head'
            else if (has('range')) verdict = 'paged'
            else if (limitArg) {
                const v = ts.isNumericLiteral(limitArg) ? Number(limitArg.text) : null
                verdict = v !== null && v > 1000 ? 'overcap' : 'capped'
                reason = `limit(${limitArg.getText(sf)})`
            }
            else if (insideHelper(n)) verdict = 'helper'
            else if (kind === 'from' && rel && cfg.bounded[rel]) { verdict = 'bounded'; reason = cfg.reasons[cfg.bounded[rel]] }
            else if (kind === 'rpc' && rel && !cfg.setof.has(rel)) verdict = 'scalar'
            else {
                const ex = exemptReason(sf, src, n)
                if (ex) { verdict = 'exempt'; reason = ex }
            }
            if (!verdict && kind === 'from' && rel) {
                // 筛到一条记录的孩子:.eq('<列>', …),那一对量过、不超过上限
                for (const [i, m] of methods.entries()) {
                    if (m !== 'eq' || !args[i].length || !ts.isStringLiteralLike(args[i][0])) continue
                    const pair = `${rel}.${args[i][0].text}`
                    if (pair in cfg.parentMax && cfg.parentMax[pair] <= cfg.parentLimit) {
                        verdict = 'parent'
                        reason = `${pair} ≤ ${cfg.parentMax[pair]} per parent on the year seed`
                        break
                    }
                }
            }
            if (!verdict) {
                // 交给了一个变量:后面那个变量被 .range / .limit / .single 过
                let q = top.parent
                while (q && (ts.isAwaitExpression(q) || ts.isParenthesizedExpression(q) || ts.isAsExpression(q))) q = q.parent
                let v = null
                if (q && ts.isVariableDeclaration(q) && ts.isIdentifier(q.name) && q.initializer === top) v = q.name.text
                else if (q && ts.isBinaryExpression(q) && q.operatorToken.kind === ts.SyntaxKind.EqualsToken && q.right === top && ts.isIdentifier(q.left)) v = q.left.text
                if (v) {
                    // 那个变量所在的函数体里、它之后:被 .range / .single 过,或者被交进一个调用、那一串后面跟着 .range(applyListSort(q, …).range(…))
                    let fn = top.parent
                    while (fn && !ts.isFunctionLike(fn) && !ts.isSourceFile(fn)) fn = fn.parent
                    const rest = src.slice(top.getEnd(), fn ? fn.getEnd() : src.length)
                    if (new RegExp(`\\b${v}\\s*(?:=\\s*${v}\\s*)?\\.(range|single|maybeSingle)\\(`).test(rest)) verdict = 'later'
                    else if (new RegExp(`\\(\\s*${v}\\b[\\s\\S]*?\\)\\s*\\.range\\(`).test(rest)) verdict = 'later'
                    else if (new RegExp(`readAll(?:In)?\\([^)]*\\b${v}\\b`).test(rest)) verdict = 'later'
                }
            }
            rec.verdict = verdict ?? 'UNPAGED'
            rec.reason = reason
            out.push(rec)
        }
        ts.forEachChild(n, visit)
    }
    visit(sf)
    return { reads: out, literalCount }
}

/** 一条与 AST 无关的数法:TypeScript 的【词法扫描器】(不建树)数 `.` `from|rpc` `(` `<字符串>` 这四个记号挨着出现的次数,
 *  去掉 `storage.from` 与 `Array/Buffer/Object.from`。注释与字符串由扫描器自己认 —— 不用正则去剥(第一版那样剥,剥错了一个文件)。 */
export function textCount(src, file = 'x.tsx') {
    const sc = ts.createScanner(ts.ScriptTarget.Latest, true, file.endsWith('x') ? ts.LanguageVariant.JSX : ts.LanguageVariant.Standard, src)
    const toks = []
    const stack = []   // 'b' = 一层普通花括号,'t' = 模板字符串里的 ${ … }
    for (let k = sc.scan(); k !== ts.SyntaxKind.EndOfFileToken; k = sc.scan()) {
        if (k === ts.SyntaxKind.OpenBraceToken) stack.push('b')
        else if (k === ts.SyntaxKind.TemplateHead) stack.push('t')
        else if (k === ts.SyntaxKind.CloseBraceToken) {
            if (stack[stack.length - 1] === 't') {
                k = sc.reScanTemplateToken(false)              // } 之后是模板的下一段
                if (k === ts.SyntaxKind.TemplateTail) stack.pop()
            } else stack.pop()
        }
        toks.push({ k, v: sc.getTokenText() })
    }
    let n = 0
    for (let i = 1; i + 2 < toks.length; i++) {
        if (toks[i - 1].k === ts.SyntaxKind.DotToken && (toks[i].v === 'from' || toks[i].v === 'rpc') && toks[i + 1].k === ts.SyntaxKind.OpenParenToken
            && (toks[i + 2].k === ts.SyntaxKind.StringLiteral || toks[i + 2].k === ts.SyntaxKind.NoSubstitutionTemplateLiteral)) {
            const owner = toks[i - 2]?.v
            if (toks[i].v === 'from' && ['storage', 'Array', 'Buffer', 'Object'].includes(owner)) continue
            n++
        }
    }
    return n
}
