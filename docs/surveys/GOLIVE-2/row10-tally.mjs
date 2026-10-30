// GOLIVE-2 第 10 行 · 收尾计数:经 lib/readAll.ts 的读取(按 .from / .rpc、按 readAll / readAllIn)· 豁免与理由 · 判词总表。只读仓库文件。
import { readFileSync } from 'node:fs'
import { listFiles, loadConfig, scanFile } from '../../../scripts/unpaged-reads/classify.mjs'
const cfg = loadConfig(); const t = {}; const ex = []; const helper = { from: 0, rpc: 0, readAll: 0, readAllIn: 0 }
for (const f of listFiles()) {
    const src = readFileSync(f, 'utf8')
    for (const r of scanFile(f, src, cfg).reads) {
        t[r.verdict] = (t[r.verdict] ?? 0) + 1
        if (r.verdict === 'helper') {
            helper[r.kind]++
            let p = r.node.parent; while (p && !(p.expression && /^readAll(In)?$/.test(p.expression.escapedText ?? ''))) p = p.parent
            helper[p?.expression?.escapedText ?? 'readAll']++
        }
        if (r.verdict === 'exempt') ex.push(`${r.file}:${r.line} ${r.relText} — ${r.reason}`)
    }
}
console.log('VERDICTS', JSON.stringify(t)); console.log('HELPER', JSON.stringify(helper)); for (const e of ex) console.log('EXEMPT', e)
