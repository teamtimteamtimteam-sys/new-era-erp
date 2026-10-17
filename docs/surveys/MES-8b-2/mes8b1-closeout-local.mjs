// MES-8b-1 close-out item 1.3 b, LOCAL half (never live): the states live has none of — a margin that computes, a frozen pack and the pack it
// superseded, a locked month with no pack (so the freeze is pressable), its V26 / V27 panel — on a fresh rebuild of HEAD's mirrors seeded with
// docs/surveys/MES-8b-2/local-seed-clones.sql (the seven real roles' codes as clones, read from live) and docs/surveys/MES-8b-1/local-layout-seed.sql
// (MES-8b-1's own scenery: margin, exposure, CPK-2026-09 superseded by CPK-2026-09-2, locked_before 2026-10-01). It talks to next dev on :3196 against
// the harness gateway stub (proxy.mjs serve → local PostgREST) and reads server-rendered HTML only (GET). Nothing is submitted.
// It spawns nothing on live, but it carries the run-directly guard like every script under docs/surveys/.
// Run from the harness directory (it calls proxy.mjs there for the session cookie):
//   node mes8b1-closeout-local.mjs <inbound A id> <inbound C id> <live pack id> <superseded pack id>
// Verdict line: LOCAL_PAGES_EXIT=<n> (0 = every fetch 200 and no application error).
import { onlyWhenRunDirectly } from '../../../scripts/lib/entrypoint.mjs'
onlyWhenRunDirectly(import.meta.url)
import { execFileSync } from 'node:child_process'

const BASE = process.env.LOCAL_BASE || 'http://localhost:3196'
const [A, C, P2, P1] = process.argv.slice(2)
const U = { admin: '01', cfo: '06', cto: '05', finance: '03', warehouse: '04' }
const PAGES = [
  ['inbound A (computed)', `/inbound/${A}/edit`],
  ['inbound C (not computable)', `/inbound/${C}/edit`],
  ['price exposure', '/finance/price-exposure'],
  ['packs, 2026-09 (has a live pack)', '/compliance/packs?month=2026-09'],
  ['packs, 2026-08 (locked, no pack)', '/compliance/packs?month=2026-08'],
  ['pack CPK-2026-09-2', `/compliance/packs/${P2}`],
  ['pack CPK-2026-09 (superseded)', `/compliance/packs/${P1}`],
  ['pending values', '/settings/pending-values'],
]
const text = (html) => html.replace(/<script[\s\S]*?<\/script>/g, ' ').replace(/<style[\s\S]*?<\/style>/g, ' ').replace(/<[^>]+>/g, ' ')
  .replace(/&#x27;/g, "'").replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/\s+/g, ' ')
const after = (body, marker, n = 200) => { const s = body.split(marker)[1]; return s ? text('<x ' + s).slice(0, n) : null }
const pv = (body, code) => { const s = body.split(`data-pending-value="${code}"`)[1]; return s ? text('<x ' + s.split('data-pending-value="')[0]).slice(0, 80) : null }
const block = (body, marker) => body.split(marker)[1]?.split('</section>')[0] ?? null
const ctl = (b) => b === null ? null : { gate: (b.match(/data-permission-required="([^"]+)"/) || [])[1] ?? null, fieldsetDisabled: /<fieldset[^>]*\sdisabled=""/.test(b),
  buttons: [...b.matchAll(/<button([^>]*)>([\s\S]*?)<\/button>/g)].map((m) => `${text(m[2]).trim()}${/\sdisabled=""/.test(m[1]) ? '[disabled]' : ''}`).join(' / ') }
function read(body) {
  const gates = {}
  for (const m of body.matchAll(/data-permission-required="([^"]+)"/g)) gates[m[1]] = (gates[m[1]] || 0) + 1
  const hooks = (attr) => [...new Set([...body.matchAll(new RegExp(`${attr}="([^"]+)"`, 'g'))].map((m) => m[1]))].join(',')
  return {
    h1: (body.match(/<h1[^>]*>([\s\S]*?)<\/h1>/) || [])[1]?.replace(/<[^>]+>/g, '').trim() ?? null,
    refused: body.includes('data-access-denied'), restricted: hooks('data-access-restricted'), gates, notices: hooks('data-notice'),
    marginState: (body.match(/data-value="margin-([a-z_]+)"/) || [])[1] ?? null, margin: after(body, 'data-value="inbound-margin"', 30),
    exposureTotal: after(body, 'data-value="exposure-total"', 60),
    freeze: ctl(block(body, 'data-section="freeze-compliance-pack"')),
    archive: ctl(body.split('data-form="archive-compliance-pack"')[1]?.split('</div>')[0] ?? null),
    packSections: (body.match(/data-section="pack-[a-z-]+"/g) || []).length,
    pdfLinks: [...body.matchAll(/href="([^"]*\/pdf[^"]*)"/g)].map((m) => m[1].replace(/^.*\/pdf/, 'pdf')).join(','),
    versions: after(body, 'data-section="versions"', 80), superseded: after(body, 'data-notice="superseded"', 120),
    packsList: after(body, 'data-section="compliance-packs"', 140),
    pendingV26: pv(body, 'V26'), pendingV27: pv(body, 'V27'),
    errorText: /Application error|Internal Server Error|This page couldn.t load/.test(body),
  }
}
let bad = 0
for (const [r, n] of Object.entries(U)) {
  const cookie = execFileSync('node', ['proxy.mjs', 'cookie', `a0000000-0000-4000-8000-0000000000${n}`, `clone-${r}@test.local`],
    { env: { ...process.env, H_SECRET: 'harness-local-secret-0123456789-abcdefghij' } }).toString().trim()
  for (const [label, path] of PAGES) {
    const res = await fetch(BASE + path, { headers: { cookie: `sb-localhost-auth-token=${cookie}` }, redirect: 'manual' })
    const body = await res.text()
    const m = read(body)
    if (res.status !== 200 || m.errorText) bad++
    console.log(`LOCAL|${r}|${label}|${res.status}|${JSON.stringify(m)}`)
  }
}
console.log(`LOCAL_PAGES_EXIT=${bad ? 6 : 0}`)
process.exit(bad ? 6 : 0)
