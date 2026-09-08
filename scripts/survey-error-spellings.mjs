#!/usr/bin/env node
// ALERT-1 · 数【那 163 处行内错误各自的画法】—— 给下一刀一个数,而不是一个猜想
// 判据:一个 JSX 元素,其子节点里出现 error/err 这类状态变量,取它的 className 字面量。
import ts from 'typescript'
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join, relative } from 'node:path'
const ROOT = new URL('..', import.meta.url).pathname
const walk = (d, o = []) => { for (const e of readdirSync(d)) { if (e === 'node_modules' || e.startsWith('.')) continue
    const p = join(d, e); statSync(p).isDirectory() ? walk(p, o) : /\.tsx$/.test(e) && o.push(p) } return o }
const files = walk(join(ROOT, 'app'))
if (!files.length) { console.error('BLIND: 0 files'); process.exit(3) }
const spellings = new Map(); const filesHit = new Set(); let nodes = 0
for (const f of files) {
    const sf = ts.createSourceFile(f, readFileSync(f, 'utf8'), ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX)
    const visit = (n) => { nodes++
        if (ts.isJsxElement(n) || ts.isJsxSelfClosingElement(n)) {
            const open = ts.isJsxElement(n) ? n.openingElement : n
            const body = ts.isJsxElement(n) ? n.children.map(c => c.getText(sf)).join('') : ''
            if (/\b(error|err|errorMsg|message)\b/.test(body) && body.length < 400) {
                const cls = open.attributes.properties.find(
                    (a) => ts.isJsxAttribute(a) && a.name.getText(sf) === 'className')
                if (cls && cls.initializer) {
                    let v = cls.initializer.getText(sf).replace(/^["'{}`]+|["'{}`]+$/g, '').trim()
                    if (v && v.length < 200 && /red|destructive|danger/.test(v)) {
                        spellings.set(v, (spellings.get(v) || 0) + 1); filesHit.add(relative(ROOT, f))
                    }
                }
            }
        }
        ts.forEachChild(n, visit) }
    visit(sf)
}
if (nodes < 10000) { console.error(`BLIND: only ${nodes} nodes walked`); process.exit(3) }
const sorted = [...spellings.entries()].sort((a, b) => b[1] - a[1])
console.log(`扫描 .tsx:${files.length}  走过节点:${nodes}`)
console.log(`\n行内错误显示:${filesHit.size} 个文件,${[...spellings.values()].reduce((a,b)=>a+b,0)} 处,【${spellings.size} 种不同的 className 写法】(判据:className 里含 red/destructive/danger)\n`)
for (const [s, n] of sorted.slice(0, 20)) console.log(`  ×${String(n).padStart(3)}  ${s}`)
if (sorted.length > 20) console.log(`  … 另有 ${sorted.length - 20} 种只出现一到两次`)
