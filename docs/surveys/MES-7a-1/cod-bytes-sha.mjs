// MES-7a-1 — the sha256 of every object in the `cod-documents` bucket, read through the Storage API (GET only; nothing is written).
// The database holds the RECORDED hash (cod_issues.sha256); this reads the STORED bytes, so before / after this cut the two issued CODs can be
// shown byte-identical. Run: node docs/surveys/MES-7a-1/cod-bytes-sha.mjs   (needs .env.local: NEXT_PUBLIC_SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)
import { readFileSync } from 'node:fs'
import { createHash } from 'node:crypto'
import { onlyWhenRunDirectly } from '../../../scripts/lib/entrypoint.mjs'

onlyWhenRunDirectly(import.meta.url)

const env = readFileSync(new URL('../../../.env.local', import.meta.url), 'utf8')
const URL_ = env.match(/NEXT_PUBLIC_SUPABASE_URL=(\S+)/)[1]
const KEY = env.match(/SUPABASE_SERVICE_ROLE_KEY=(\S+)/)[1]
const H = { apikey: KEY, Authorization: `Bearer ${KEY}` }

async function list(bucket, prefix = '') {
    const r = await fetch(`${URL_}/storage/v1/object/list/${bucket}`, {
        method: 'POST', headers: { ...H, 'Content-Type': 'application/json' },
        body: JSON.stringify({ prefix, limit: 1000, offset: 0 }),
    })
    if (!r.ok) throw new Error(`list ${bucket}/${prefix}: HTTP ${r.status}`)
    const out = []
    for (const e of await r.json()) {
        const path = prefix ? `${prefix}/${e.name}` : e.name
        if (e.id === null) out.push(...await list(bucket, path))   // a folder
        else out.push(path)
    }
    return out
}

let fail = 0
for (const bucket of process.argv.slice(2).length ? process.argv.slice(2) : ['cod-documents']) {
    const paths = await list(bucket)
    console.log(`BUCKET|${bucket}|objects=${paths.length}`)
    for (const p of paths.sort()) {
        // one-time query string so no cache answers instead of the store (MES-6b-2 proof, attempt 4)
        const r = await fetch(`${URL_}/storage/v1/object/${bucket}/${p}?t=${Date.now()}`, { headers: H })
        if (!r.ok) { console.log(`OBJECT|${p}|HTTP ${r.status}`); fail++; continue }
        const buf = Buffer.from(await r.arrayBuffer())
        console.log(`OBJECT|${p}|bytes=${buf.length}|sha256=${createHash('sha256').update(buf).digest('hex')}`)
    }
}
console.log(`CODSHA_OWN_EXIT=${fail ? 1 : 0}`)
process.exit(fail ? 1 : 0)
