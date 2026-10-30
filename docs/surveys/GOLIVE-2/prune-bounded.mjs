// GOLIVE-2 · 一次性:把 bounded-relations.json 里今天没有任何一条读取用到的关系删掉(check-unpaged-reads 的 ③ 死条目)。
import { readFileSync, writeFileSync } from 'node:fs'
import { listFiles, loadConfig, scanFile } from '../../../scripts/unpaged-reads/classify.mjs'
const cfg = loadConfig(); const hit = new Set()
for (const f of listFiles()) for (const r of scanFile(f, readFileSync(f, 'utf8'), cfg).reads) if (r.verdict === 'bounded') hit.add(r.rel)
const p = 'scripts/unpaged-reads/bounded-relations.json'; const d = JSON.parse(readFileSync(p, 'utf8'))
const dead = Object.keys(d.relations).filter((k) => !hit.has(k)); for (const k of dead) delete d.relations[k]
writeFileSync(p, JSON.stringify(d, null, 2) + '\n'); console.log(`pruned ${dead.length}: ${dead.join(', ')} · kept ${Object.keys(d.relations).length}`)
