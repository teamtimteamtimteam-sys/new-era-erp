// LOCAL harness (never live): MES-6b-2 close-out item 1.2 b, local half — states live has no data for, as clones of the real roles' codes
// (cco, warehouse, cfo, admin; codes read from live 2026-10-15 22:3x CST). Pages read before and after; actions go through the app's own route
// (POST /output/[id]/coa/pdf) and, for the void request, the RPC the CoA detail page's action calls, each as the clone whose codes allow it.
// Copied into the repo as the record of the run (MES-7a/MES-6b-2-CLOSEOUT.md §2 b). It talks to a LOCAL harness only, but it does act on import,
// so it carries the same run-directly guard as the live scripts (scripts/check-import-inert.mjs scans docs/surveys/). HARNESS_DIR = the scratch
// directory holding proxy.mjs and env.txt (the harness's own gateway stub and its keys), never the repo.
import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import { onlyWhenRunDirectly } from '../../../scripts/lib/entrypoint.mjs'
onlyWhenRunDirectly(import.meta.url)
const BASE = 'http://localhost:3196', REST = 'http://127.0.0.1:55486'
const H = (process.env.HARNESS_DIR || '/Users/timchen/.claude/jobs/44fff67a/tmp/h').replace(/\/?$/, '/')
const OB = process.argv[2], OBV = process.argv[3]
const U = { cco: 'a0000000-0000-4000-8000-000000000002', warehouse: 'a0000000-0000-4000-8000-000000000004', cfo: 'a0000000-0000-4000-8000-000000000006',
  admin: 'a0000000-0000-4000-8000-000000000001' }
const raw = (r) => execFileSync('node', ['proxy.mjs', 'cookie', U[r], `clone-${r}@test.local`], { cwd: H, env: process.env }).toString().trim()
const cookie = (r) => 'sb-localhost-auth-token=' + raw(r)
const token = (r) => JSON.parse(Buffer.from(raw(r).replace(/^base64-/, ''), 'base64url').toString()).access_token
const ANON = fs.readFileSync(H + 'env.txt', 'utf8').match(/ANON_KEY=(.*)/)[1]
const text = (html) => html.replace(/<script[\s\S]*?<\/script>/g, ' ').replace(/<style[\s\S]*?<\/style>/g, ' ').replace(/<[^>]+>/g, ' ')
  .replace(/&#x27;/g, "'").replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/\s+/g, ' ')
const pdfText = (buf) => { fs.writeFileSync(H + 'coa.pdf', buf); return execFileSync('python3', ['-c', `import pypdf;r=pypdf.PdfReader("${H}coa.pdf");print(len(r.pages));print(" ".join(p.extract_text() for p in r.pages))`]).toString().replace(/\s+/g, ' ') }
let bad = 0
const after = (tx, needle, n = 150) => { const i = tx.indexOf(needle); return i < 0 ? null : tx.slice(i, i + n) }
async function page(role, label, path, extra = []) {
  const res = await fetch(BASE + path, { headers: { cookie: cookie(role) }, redirect: 'manual' })
  const body = await res.text(); const tx = text(body)
  const m = { h1: (body.match(/<h1[^>]*>([\s\S]*?)<\/h1>/) || [])[1]?.replace(/<[^>]+>/g, '').trim() ?? null,
    refused: body.includes('data-access-denied'), needs: [...new Set([...body.matchAll(/data-permission-required="([^"]+)"/g)].map((x) => x[1]))],
    coaSection: body.includes('data-section="coa"'), feed: after(tx, 'Feed chemistry', 110), blocked: after(tx, 'It cannot be issued yet', 160),
    issueButton: tx.includes('Issue certificate'), err: /Application error|Internal Server Error|Unhandled Runtime Error/.test(body) }
  for (const n of extra) m['has:' + n] = tx.includes(n)
  if (res.status >= 500 || m.err) bad++
  console.log(`LOCAL|${role}|${label}|${res.status}|${JSON.stringify(m)}`)
  return { res, body, tx }
}
const count = () => execFileSync('psql', ['host=localhost port=55484 user=postgres dbname=m7a', '-X', '-At', '-c', 'select count(*) from certificates_of_analysis']).toString().trim()

// ── before: the section and the issue action as each role's codes allow ──
for (const r of Object.keys(U)) await page(r, 'output batch (final assay, nothing issued)', `/output/${OB}/edit`)
// ── issue through the route: warehouse (no action.issue_coa) is refused, cco issues ──
let res = await fetch(`${BASE}/output/${OB}/coa/pdf`, { method: 'POST', headers: { cookie: cookie('warehouse'), 'content-type': 'application/json' }, body: '{}' })
console.log(`ACTION|warehouse|POST issue|${res.status}|${(await res.text()).slice(0, 160)}|certificates=${count()}`)
if (res.status < 400) bad++
res = await fetch(`${BASE}/output/${OB}/coa/pdf`, { method: 'POST', headers: { cookie: cookie('cco'), 'content-type': 'application/json' }, body: '{}' })
const c1 = await res.json().catch(() => null)
console.log(`ACTION|cco|POST issue|${res.status}|${JSON.stringify(c1)}|certificates=${count()}`)
if (res.status !== 200 || !c1?.code) bad++
res = await fetch(`${BASE}/output/${OBV}/coa/pdf`, { method: 'POST', headers: { cookie: cookie('admin'), 'content-type': 'application/json' }, body: '{}' })
const c2 = await res.json().catch(() => null)
console.log(`ACTION|admin|POST issue|${res.status}|${JSON.stringify(c2)}|certificates=${count()}`)
if (res.status !== 200 || !c2?.code) bad++
// ── stored bytes as each role (download) ──
for (const r of Object.keys(U)) {
  const g = await fetch(`${BASE}/output/${OB}/coa/pdf?coa=${encodeURIComponent(c1.code)}`, { headers: { cookie: cookie(r) } })
  const buf = Buffer.from(await g.arrayBuffer())
  const t = g.status === 200 && (g.headers.get('content-type') || '').includes('pdf') ? pdfText(buf) : buf.toString().slice(0, 120)
  console.log(`DOWNLOAD|${r}|${g.status}|${(t.match(/Issued by [^.]{0,60}/) || [''])[0]}|feed:${(t.match(/Feed chemistry[^.]{0,40}/) || [''])[0]}|${t.slice(0, 60)}`)
  if (g.status !== 200) bad++
}
// ── a coa_void request on COA for OBV, raised as cco through the RPC the detail page calls ──
res = await fetch(`${REST}/rest/v1/rpc/submit_coa_void_request`, { method: 'POST', headers: { apikey: ANON, authorization: `Bearer ${token('cco')}`, 'content-type': 'application/json' },
  body: JSON.stringify({ p_coa_id: c2.coa_id, p_reason: 'Harness: wrong batch named on the paper' }) })
console.log(`ACTION|cco|submit_coa_void_request|${res.status}|${(await res.text()).slice(0, 200)}`)
// ── after: list, detail, batch section, CFO request list ──
for (const r of Object.keys(U)) {
  await page(r, 'output batch (issued)', `/output/${OB}/edit`, [c1.code, 'already'])
  await page(r, 'coa list', '/quality/coa', [c1.code, c2.code])
  await page(r, 'coa detail (issued)', `/quality/coa/${c1.coa_id}`, ['Request void', 'Issued by', 'Download'])
  await page(r, 'coa detail (void requested)', `/quality/coa/${c2.coa_id}`, ['Request void', 'waiting'])
  await page(r, 'inventory (CFO request list)', '/inventory', ['A certificate of analysis void is waiting for the CFO', c2.code, 'Approve', 'Withdraw'])
}
console.log(`LOCALCLOSEOUT_EXIT=${bad ? 1 : 0}`)
