// MES-8a — the two issued CODs' STORED BYTES, hashed (GET only; nothing is written anywhere).
// Reads .env.local for the project URL and the service key (the bucket is private), lists cod-documents, downloads each object and prints its
// sha256 and byte length beside the hash cod_issues recorded for it. Run: node docs/surveys/MES-8a/cod-bytes.mjs
// Also prints the object list of every bucket MES-8a's proof touches, so the before/after reading can compare them.
import { readFileSync } from 'node:fs'
import { createHash } from 'node:crypto'
import { onlyWhenRunDirectly } from '../../../scripts/lib/entrypoint.mjs'

onlyWhenRunDirectly(import.meta.url)

const env = readFileSync(new URL('../../../.env.local', import.meta.url), 'utf8')
const URL_ = env.match(/NEXT_PUBLIC_SUPABASE_URL=(\S+)/)[1]
const KEY = env.match(/SUPABASE_SERVICE_ROLE_KEY=(\S+)/)[1]
const H = { apikey: KEY, Authorization: `Bearer ${KEY}` }

async function list(bucket) {
    const r = await fetch(`${URL_}/storage/v1/object/list/${bucket}`, {
        method: 'POST', headers: { ...H, 'Content-Type': 'application/json' },
        body: JSON.stringify({ prefix: '', limit: 1000, offset: 0 }),
    })
    if (r.status === 400 || r.status === 404) return null          // bucket absent
    if (!r.ok) throw new Error(`list ${bucket}: HTTP ${r.status} ${await r.text()}`)
    const top = await r.json()
    const out = []
    for (const e of top) {
        if (e.id) { out.push(e.name); continue }
        const r2 = await fetch(`${URL_}/storage/v1/object/list/${bucket}`, {
            method: 'POST', headers: { ...H, 'Content-Type': 'application/json' },
            body: JSON.stringify({ prefix: e.name, limit: 1000, offset: 0 }),
        })
        if (!r2.ok) throw new Error(`list ${bucket}/${e.name}: HTTP ${r2.status}`)
        for (const f of await r2.json()) out.push(`${e.name}/${f.name}`)
    }
    return out.sort()
}

const rest = await fetch(`${URL_}/rest/v1/cod_issues?select=file_path,sha256`, { headers: H })
if (!rest.ok) throw new Error(`cod_issues: HTTP ${rest.status}`)
const recorded = new Map((await rest.json()).map(r => [r.file_path, r.sha256]))

const cod = await list('cod-documents')
if (!cod || cod.length === 0) throw new Error('cod-documents lists 0 objects — a blind reading, not a clean one')
for (const name of cod) {
    const r = await fetch(`${URL_}/storage/v1/object/cod-documents/${name}`, { headers: H })
    if (!r.ok) throw new Error(`download ${name}: HTTP ${r.status}`)
    const buf = Buffer.from(await r.arrayBuffer())
    const sha = createHash('sha256').update(buf).digest('hex')
    const rec = recorded.get(name) ?? '-'
    console.log(`COD_BYTES|${name}|bytes=${buf.length}|sha256=${sha}|recorded=${rec}|match=${sha === rec}`)
}
for (const b of ['cod-documents', 'statement-documents', 'supplier-statement-documents']) {
    const names = await list(b)
    console.log(`BUCKET|${b}|${names === null ? 'absent' : names.length + '|' + names.join(',')}`)
}
