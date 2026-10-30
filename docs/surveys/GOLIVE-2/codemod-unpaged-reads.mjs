#!/usr/bin/env node
// GOLIVE-2 第 10 行(Tim 2026-10-30 Q1)· 一次性的改写:把每一条 scripts/unpaged-reads/classify.mjs 判成 UNPAGED / overcap 的读取包进 lib/readAll.ts。
//   readAll(() => <原样那一串>, { label, key })                       —— 一般的读取
//   readAllIn(<那一组>, (ids) => <那一串,.in(列, ids)>, { label, key }) —— 带一个不是字面量数组的 .in(…):长名单分批
//   overcap(.limit(n),n > 1000):把 .limit(n) 拿掉再包 —— 线上本来就只给了 1,000 行,写的人要的是 n 行以上。
// 判法与构建闸(scripts/check-unpaged-reads.mjs)是同一份(classify.mjs),所以"闸要改的"与"这里改掉的"是同一个集合。
// key:关系上有 id → 默认;没有 id 而有 seq → 'seq';都没有 → 它输出的全部列(在每一列都相同的两行本来就是同一行,次序不影响答案)。
//   列清单取自 db/gate 同一份重建的目录(GOLIVE-2 本地库导出,docs/surveys/GOLIVE-2/relation-columns.json)。
// 用法:node docs/surveys/GOLIVE-2/codemod-unpaged-reads.mjs [--dry]   —— 只改 app/ lib/ 下的文件;改完跑 tsc。
import ts from 'typescript'
import { readFileSync, writeFileSync } from 'node:fs'
import { listFiles, loadConfig, scanFile } from '../../../scripts/unpaged-reads/classify.mjs'

const DRY = process.argv.includes('--dry')
const cfg = loadConfig()
const cols = JSON.parse(readFileSync('docs/surveys/GOLIVE-2/relation-columns.json', 'utf8'))
const STOP = new Set(['then', 'catch', 'finally', 'csv', 'geojson', 'explain'])

function keyFor(kind, rel) {
    const c = cols[kind === 'rpc' ? `rpc:${rel}` : rel]
    if (!c) return null                       // 不知道 → readAll 的默认 'id'(没有那一列时读满一页会当场报错,不是一个错数)
    if (c.includes('id')) return null
    if (c.includes('seq')) return `'seq'`
    return `[${c.map((x) => `'${x}'`).join(', ')}]`
}

let files = 0, wrapped = 0, wrappedIn = 0, uncapped = 0
const report = []
for (const file of listFiles()) {
    const src = readFileSync(file, 'utf8')
    const { reads } = scanFile(file, src, cfg)
    const todo = reads.filter((r) => r.verdict === 'UNPAGED' || r.verdict === 'overcap')
    if (!todo.length) continue
    const edits = []
    for (const r of todo) {
        const sf = r.sf
        // 包的那一段:从 .from/.rpc 那个调用往上,直到碰到 .then / .catch …(那些不是查询的一部分)或走出这一串
        let top = r.node
        for (;;) {
            const p = top.parent
            if (p && ts.isPropertyAccessExpression(p) && p.expression === top && p.parent && ts.isCallExpression(p.parent) && p.parent.expression === p
                && !STOP.has(p.name.text)) { top = p.parent; continue }
            break
        }
        let text = src.slice(top.getStart(sf), top.getEnd())
        if (r.verdict === 'overcap') {
            const t2 = text.replace(/\s*\.limit\(\s*\d+\s*\)/, '')
            if (t2 === text) throw new Error(`cannot drop the over-cap limit at ${file}:${r.line}`)
            text = t2
            uncapped++
        }
        const label = r.rel ?? r.relText.replace(/[^\w.]/g, '').slice(0, 40)
        const key = r.rel ? keyFor(r.kind, r.rel) : null
        const opts = `{ label: '${label}'${key ? `, key: ${key}` : ''} }`
        // 一个不是字面量数组的 .in(列, X):长名单分批
        let inCall = null
        const visit = (n) => {
            if (inCall) return
            if (ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression) && n.expression.name.text === 'in' && n.arguments.length === 2
                && !ts.isArrayLiteralExpression(n.arguments[1])) inCall = n
            else ts.forEachChild(n, visit)
        }
        visit(top)
        let repl
        if (inCall && r.verdict !== 'overcap') {
            const a = inCall.arguments[1]
            const s0 = a.getStart(sf) - top.getStart(sf), s1 = a.getEnd() - top.getStart(sf)
            const listExpr = text.slice(s0, s1)
            const body = text.slice(0, s0) + '__ids' + text.slice(s1)
            repl = `readAllIn(${listExpr}, (__ids) => ${body}, ${opts})`
            wrappedIn++
        } else {
            repl = `readAll(() => ${text}, ${opts})`
            wrapped++
        }
        edits.push({ start: top.getStart(sf), end: top.getEnd(), repl })
        report.push(`${r.verdict === 'overcap' ? 'UNCAP+' : ''}${inCall ? 'readAllIn' : 'readAll'} ${file}:${r.line} ${r.kind} ${r.relText}`)
    }
    // 从后往前改(位置不乱);同一处嵌套的只改外面那一层
    edits.sort((a, b) => b.start - a.start)
    let out = src
    let lastStart = Infinity
    for (const e of edits) {
        if (e.end > lastStart) continue
        out = out.slice(0, e.start) + e.repl + out.slice(e.end)
        lastStart = e.start
    }
    const need = ['readAll', 'readAllIn'].filter((n) => new RegExp(`\\b${n}\\(`).test(out))
    if (!/from '@\/lib\/readAll'/.test(out)) {
        const imp = `import { ${need.join(', ')} } from '@/lib/readAll'\n`
        const lines = out.split('\n')
        let last = -1
        for (let i = 0; i < lines.length; i++) {
            if (/^import\b/.test(lines[i])) { last = i; while (!/from\s+['"].*['"]\s*;?\s*$|^import\s+['"].*['"]\s*;?\s*$/.test(lines[last]) && last < lines.length - 1) last++; i = last }
        }
        if (last < 0) {
            // 没有 import:放在 'use server' / 'use client' 指令之后
            const d = lines.findIndex((l) => /^['"]use (server|client)['"]/.test(l))
            lines.splice(d + 1, 0, imp.trimEnd())
        } else lines.splice(last + 1, 0, imp.trimEnd())
        out = lines.join('\n')
    }
    if (!DRY) writeFileSync(file, out)
    files++
}
for (const l of report) console.log(l)
console.log(`CODEMOD|${files} files · ${wrapped} readAll · ${wrappedIn} readAllIn · ${uncapped} over-cap limits dropped${DRY ? ' (dry run, nothing written)' : ''}`)
