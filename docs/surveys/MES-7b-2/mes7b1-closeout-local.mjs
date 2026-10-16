// MES-7b-1 close-out item 1.2 b, LOCAL half (never live): the states live has none of — an injury incident with its details, a fire incident,
// a handover citing two incidents — on a rebuild of HEAD's mirrors seeded with docs/surveys/MES-7b-1/local-seed.sql (clones of the real roles'
// codes). It talks to next dev on :3196 against the harness gateway stub (proxy.mjs serve → local PostgREST); it reads only server-rendered
// HTML with GET. It spawns nothing on live, but it carries the run-directly guard like every script under docs/surveys/
// (scripts/check-import-inert.mjs scans them).
// Run from the harness directory (it calls proxy.mjs there for the session cookie):
//   H_SECRET=… node mes7b1-closeout-local.mjs <injury incident id> <fire incident id> <handover id>
// Verdict line: LOCAL_PAGES_EXIT=<n> (0 = every fetch 200 and no application error).
import { onlyWhenRunDirectly } from '../../../scripts/lib/entrypoint.mjs'
onlyWhenRunDirectly(import.meta.url)
import { execFileSync } from 'node:child_process'

const BASE = process.env.LOCAL_BASE || 'http://localhost:3196'
const [INJ, FIRE, HO] = process.argv.slice(2)
const U = { admin: '01', cto: '05', warehouse: '04', cfo: '06', finance: '03' }
const PAGES = [
  ['incident list', '/safety/incidents'],
  ['new incident', '/safety/incidents/new'],
  ['injury incident', `/safety/incidents/${INJ}`],
  ['fire incident', `/safety/incidents/${FIRE}`],
  ['new handover', '/operation/handovers/new'],
  ['handover page', `/operation/handovers/${HO}`],
  ['pending values', '/settings/pending-values'],
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
    const gates = {}
    for (const m of body.matchAll(/data-permission-required="([^"]+)"/g)) gates[m[1]] = (gates[m[1]] || 0) + 1
    const ho = (body.split('data-section="handover-incidents"')[1] || '').split(/<textarea/)[0]
    const m = {
      h1: (body.match(/<h1[^>]*>([\s\S]*?)<\/h1>/) || [])[1]?.replace(/<[^>]+>/g, '').trim() ?? null,
      refused: body.includes('data-access-denied'), gates,
      recordLink: /<a[^>]+href="\/safety\/incidents\/new"[^>]*>[^<]*Record an incident/.test(body),
      listRows: (tx.match(/INC-2026-\d{4}/g) || []).filter((v, i, a) => a.indexOf(v) === i).length,
      restrictedCount: (tx.match(/Restricted/g) || []).length,
      injuryText: tx.includes('Chemical burn'),
      injuryRestrictedLine: tx.includes('injury details are kept for people allowed to see health information'),
      handoverCheckboxes: (ho.match(/type="checkbox"/g) || []).length,
      handoverCitesIncident: path.startsWith('/operation/handovers/') && !path.endsWith('/new') ? /INC-2026-\d{4}/.test(tx) : null,
      pendingV19: body.includes('data-pending-value="V19"'),
      v19Unconfirmed: /unconfirmed/i.test(text('<x ' + ((body.split('data-pending-value="V19"')[1] || '').split('data-pending-value="')[0]))),
      errorText: /Application error|Internal Server Error|Unhandled Runtime Error|This page couldn.t load/.test(body),
    }
    if (res.status !== 200 || m.errorText) bad++
    console.log(`LOCAL|${role}|${label}|${res.status}|${JSON.stringify(m)}`)
  }
}
console.log(`LOCAL_PAGES_EXIT=${bad ? 1 : 0}`)
process.exit(bad ? 1 : 0)
