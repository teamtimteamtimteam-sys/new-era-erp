// MES-7b-2 close-out item 1.3 b, LOCAL half (never live): the states live has none of — checklists, inspections with findings, monitored
// parameters and results — on a fresh rebuild of HEAD's mirrors seeded with docs/surveys/MES-7b-1/local-seed.sql (clones of the real roles'
// codes) and then docs/surveys/MES-7b-2/local-seed.sql (three checklists, INS-2026-0001…0003, three parameters, four results, one exceedance
// incident). It talks to next dev on :3196 against the harness gateway stub (proxy.mjs serve → local PostgREST); it reads only server-rendered
// HTML with GET. It spawns nothing on live, but it carries the run-directly guard like every script under docs/surveys/.
// Run from the harness directory (it calls proxy.mjs there for the session cookie):
//   H_SECRET=… node mes7b2-closeout-local.mjs <checklist id (DISCHARGE)> <run id (INS-2026-0001, open finding)>
// Verdict line: LOCAL_PAGES_EXIT=<n> (0 = every fetch 200 and no application error).
import { onlyWhenRunDirectly } from '../../../scripts/lib/entrypoint.mjs'
onlyWhenRunDirectly(import.meta.url)
import { execFileSync } from 'node:child_process'

const BASE = process.env.LOCAL_BASE || 'http://localhost:3196'
const [TPL, RUN] = process.argv.slice(2)
const U = { admin: '01', cto: '05', warehouse: '04', cfo: '06', finance: '03' }
const PAGES = [
  ['inspection list', '/safety/inspections'],
  ['new checklist', '/safety/inspections/templates/new'],
  ['checklist page', `/safety/inspections/templates/${TPL}`],
  ['record an inspection', `/safety/inspections/new?template=${TPL}`],
  ['inspection run', `/safety/inspections/${RUN}`],
  ['environment', '/safety/environment'],
  ['pending values', '/settings/pending-values'],
]
const text = (html) => html.replace(/<script[\s\S]*?<\/script>/g, ' ').replace(/<style[\s\S]*?<\/style>/g, ' ').replace(/<[^>]+>/g, ' ')
  .replace(/&#x27;/g, "'").replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/\s+/g, ' ')
const pv = (body, code) => { const s = body.split(`data-pending-value="${code}"`)[1]; return s ? text('<x ' + s.split('data-pending-value="')[0]) : null }
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
    const v18 = pv(body, 'V18'), v20 = pv(body, 'V20')
    const m = {
      h1: (body.match(/<h1[^>]*>([\s\S]*?)<\/h1>/) || [])[1]?.replace(/<[^>]+>/g, '').trim() ?? null,
      refused: body.includes('data-access-denied'), gates,
      newChecklistLink: /<a[^>]+href="\/safety\/inspections\/templates\/new"[^>]*>[^<]*New checklist/.test(body),
      recordRunLink: /<a[^>]+href="\/safety\/inspections\/new\?template=[^"]+"[^>]*>[^<]*Record an inspection/.test(body),
      recordRunText: tx.includes('Record an inspection'),
      checklists: (tx.match(/\b(DISCHARGE|FIRE-MONTHLY|OLD-STORE)\b/g) || []).filter((v, i, a) => a.indexOf(v) === i).length,
      runs: (tx.match(/INS-2026-\d{4}/g) || []).filter((v, i, a) => a.indexOf(v) === i).length,
      checklistForm: body.includes('data-form="inspection-template"'),
      runForm: body.includes('data-form="inspection-run"'),
      findingsSection: body.includes('data-section="findings"'),
      closeFindingForm: body.includes('data-form="close-finding"'),
      recordFindingForm: body.includes('data-form="record-finding"'),
      envForm: body.includes('data-form="environmental-result"'),
      envJudgements: ['Exceeds', 'Within', 'Not judged'].filter((w) => tx.includes(w)),
      envIncident: /INC-2026-\d{4}/.test(tx),
      pendingV18: v18 ? v18.slice(0, 160) : null,
      pendingV20: v20 ? v20.slice(0, 160) : null,
      errorText: /Application error|Internal Server Error|Unhandled Runtime Error|This page couldn.t load/.test(body),
    }
    if (res.status !== 200 || m.errorText) bad++
    console.log(`LOCAL|${role}|${label}|${res.status}|${JSON.stringify(m)}`)
  }
}
console.log(`LOCAL_PAGES_EXIT=${bad ? 1 : 0}`)
process.exit(bad ? 1 : 0)
