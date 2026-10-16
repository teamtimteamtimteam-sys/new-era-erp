// MES-7a-2 close-out item 1.3 b, LOCAL half (never live): the states live has none of — spare-part batches (priced, unpriced, on hold), two issues
// and a return on a repair record, a reprice after the issue, V21 listed — on a rebuild of HEAD's mirrors seeded with
// docs/surveys/MES-7a-2/local-seed.sql (+ docs/surveys/MES-7b/local-seed-finance.sql). It talks to next dev on :3197 against the harness gateway
// stub (proxy.mjs serve → local PostgREST); it reads only server-rendered HTML with GET. It spawns nothing on live, but it carries the run-directly
// guard like every script under docs/surveys/ (scripts/check-import-inert.mjs scans them).
// Run from the harness directory (it calls proxy.mjs there for the session cookie):
//   H_SECRET=… node mes7a2-closeout-local.mjs <fa id> <priced batch id>
// Verdict line: LOCAL_PAGES_EXIT=<n> (0 = every fetch 200 and no application error).
import { onlyWhenRunDirectly } from '../../../scripts/lib/entrypoint.mjs'
onlyWhenRunDirectly(import.meta.url)
import { execFileSync } from 'node:child_process'

const BASE = 'http://localhost:3197'
const [FA, IBP] = process.argv.slice(2)
const U = { admin: '01', cco: '02', finance: '03', warehouse: '04', cfo: '06' }
const PAGES = [
  ['machine page', `/operation/equipment/${FA}`],
  ['roll-forward', '/operation/balance'],
  ['trial balance (all)', '/finance/trial-balance?all=1'],
  ['pending values', '/settings/pending-values'],
  ['batch page (balance tree)', `/inbound/${IBP}/edit`],
]
const text = (html) => html.replace(/<script[\s\S]*?<\/script>/g, ' ').replace(/<style[\s\S]*?<\/style>/g, ' ').replace(/<[^>]+>/g, ' ')
  .replace(/&#x27;/g, "'").replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/\s+/g, ' ')
let bad = 0
for (const [role, n] of Object.entries(U)) {
  const cookie = execFileSync('node', ['proxy.mjs', 'cookie', `a0000000-0000-4000-8000-0000000000${n}`, `clone-${role}@test.local`],
    { env: process.env }).toString().trim()
  for (const [label, path] of PAGES) {
    const res = await fetch(BASE + path, { headers: { cookie: `sb-localhost-auth-token=${cookie}` }, redirect: 'manual' })
    const body = await res.text()
    const tx = text(body)
    const sec = body.split('data-section="spare-parts"')[1]?.split(/data-section="(?!spare-parts)/)[0] ?? ''
    const gates = {}
    for (const m of sec.matchAll(/data-permission-required="([^"]+)"/g)) gates[m[1]] = (gates[m[1]] || 0) + 1
    const m = {
      h1: (body.match(/<h1[^>]*>([\s\S]*?)<\/h1>/) || [])[1]?.replace(/<[^>]+>/g, '').trim() ?? null,
      refused: body.includes('data-access-denied'),
      partsSection: body.includes('data-section="spare-parts"'),
      partsIssueEntry: tx.includes('Issue spare parts'),
      partsRows: (sec.match(/<tbody[^>]*>([\s\S]*?)<\/tbody>/)?.[1].match(/<tr[\s>]/g) || []).length,
      returnButtons: (sec.match(/>Return</g) || []).length,
      allReturned: tx.includes('All returned'),
      partsGatesInSection: gates,
      valueCol: tx.includes('Still out, at landed cost'),
      valueRestricted: tx.includes('Amounts are shown only to people who can see prices.'),
      rollMaintenanceCol: tx.includes('Issued to maintenance (net of returns)'),
      tb6800: (tx.match(/6800 [^|]{0,70}/) || [null])[0],
      tbSystemWord: /6800[^0-9]{0,80}\bsystem\b/i.test(tx),
      v21: tx.includes('Minimum stock of a spare part'),
      v21Item: tx.includes('ZZ-LL-BLADE') || tx.includes('Shredder blade, hardened'),
      v21Bearing: tx.includes('ZZ-LL-BEARING'),
      errorText: /Application error|Internal Server Error|Unhandled Runtime Error|This page couldn.t load/.test(body),
    }
    if (res.status !== 200 || m.errorText) bad++
    console.log(`LOCAL|${role}|${label}|${res.status}|${JSON.stringify(m)}`)
  }
}
console.log(`LOCAL_PAGES_EXIT=${bad ? 1 : 0}`)
process.exit(bad ? 1 : 0)
