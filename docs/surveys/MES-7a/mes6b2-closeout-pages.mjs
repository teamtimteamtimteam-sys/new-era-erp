// MES-6b-2 close-out item 1.2 b (live half) — page probe on the DEPLOYED app (read-only). Four one-off clones of real roles (cloneOf: exactly
// that role's codes at this moment): cco, warehouse, cfo, admin. Each one GETs an output batch page (the CoA section and its issue action), the
// CoA list, the inventory page (the CFO request list, where coa_void requests are listed) and the CoA preview route, and reads from the
// server-rendered response: HTTP status, the page heading, whether the page refused (data-access-denied), which permission codes a disabled
// control names (data-permission-required), whether the CoA section is drawn (data-section="coa"), what it says about feed chemistry and the
// blockers, whether the issue button is there, and whether an application error is shown. Only GET requests are made; nothing is submitted.
// ★ Live has 0 output assays, 0 certificates and 0 coa_void requests (read 2026-10-15 22:28:32 CST as postgres, closeout-readings.sql), so an
//   issued certificate, its detail page and a waiting coa_void request cannot be shown on live — they are measured on a local rebuild with data of
//   my own (the local half of item b).
// The throwaway accounts are removed by the ephemeral plan (prefix mes6b2probe, already registered in scripts/ephemeral.mjs).
// Verdict line: PAGES_PROBE_EXIT=<n> (0 = every fetch returned and no page showed an application error).
import { onlyWhenRunDirectly } from '../../../scripts/lib/entrypoint.mjs'
// ★ It acts on live, so it runs only when executed directly — importing this file starts nothing.
onlyWhenRunDirectly(import.meta.url)

const REPO = new URL('../../..', import.meta.url).pathname.replace(/\/$/, '')
let openPlan, mintThrowaway, reapStalePlans, installExitHooks, exitAfterCleanup, acquireOrExit, release, heldBy
const BASE = process.env.PROBE_BASE || 'https://new-era-erp.vercel.app'
// read on live (postgres, BEGIN READ ONLY): the newest live output batch
const OUT_ID = '7329b061-9b21-4ad3-bc23-2ead6c8fb30a'   // OUT-2026-0380
const ROLES = ['cco', 'warehouse', 'cfo', 'admin']
const PAGES = [
  ['output batch', `/output/${OUT_ID}/edit`],
  ['coa list', '/quality/coa'],
  ['inventory (CFO request list)', '/inventory'],
  ['coa preview route', `/output/${OUT_ID}/coa/pdf`],
]
let locked = false

const text = (html) => html.replace(/<script[\s\S]*?<\/script>/g, ' ').replace(/<style[\s\S]*?<\/style>/g, ' ').replace(/<[^>]+>/g, ' ')
  .replace(/&#x27;/g, "'").replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/\s+/g, ' ')
function read(res, body) {
  const ct = res.headers.get('content-type') || ''
  if (!ct.includes('text/html')) return { contentType: ct, bytes: body.length, head: body.slice(0, 160) }
  const tx = text(body)
  const h1 = (body.match(/<h1[^>]*>([\s\S]*?)<\/h1>/) || [])[1]?.replace(/<[^>]+>/g, '').trim() ?? null
  const coa = body.includes('data-section="coa"')
  const after = (needle, n = 140) => { const i = tx.indexOf(needle); return i < 0 ? null : tx.slice(i, i + n) }
  return {
    h1, refused: body.includes('data-access-denied'),
    needs: [...new Set([...body.matchAll(/data-permission-required="([^"]+)"/g)].map((m) => m[1]))],
    coaSection: coa,
    feedChemistry: coa ? after('Feed chemistry', 90) : null,
    issueForm: body.includes('data-form="coa-issue"'),
    issueButton: tx.includes('Issue certificate'),
    blocked: coa ? after('It cannot be issued yet', 200) : null,
    coaEmpty: tx.includes('No certificate has been issued for this batch'),
    coaVoidText: tx.includes('certificate of analysis void') || tx.includes('Certificate of analysis'),
    tbodyRows: [...body.matchAll(/<tbody[^>]*>([\s\S]*?)<\/tbody>/g)].map((m) => (m[1].match(/<tr[\s>]/g) || []).length),
    errorText: /Application error|Internal Server Error|This page couldn.t load/.test(body),
  }
}

async function main() {
  ;({ openPlan, mintThrowaway, reapStalePlans, installExitHooks, exitAfterCleanup } = await import(REPO + '/scripts/ephemeral.mjs'))
  ;({ acquireOrExit, release, heldBy } = await import(REPO + '/scripts/liveLock.mjs'))
  installExitHooks({ onFinish: (code) => { try { if (locked) release() } catch {}; console.log(`PAGES_PROBE_EXIT=${code}`) } })
  const other = heldBy(); if (other) { console.error(`live-lock held by ${other.holder}`); return exitAfterCleanup(5) }
  acquireOrExit('mes6b2-closeout-pages.mjs', { ownExit: false }); locked = true
  openPlan('docs/surveys/MES-7a/mes6b2-closeout-pages.mjs'); await reapStalePlans()
  const stamp = Date.now()
  let bad = 0
  for (const r of ROLES) {
    const a = await mintThrowaway({ prefix: 'mes6b2probe', label: `cof-${r}`, stamp, codes: { cloneOf: r } })
    for (const [label, path] of PAGES) {
      const t0 = Date.now()
      const res = await fetch(BASE + path, { headers: { cookie: a.cookie }, redirect: 'manual' })
      const body = await res.text()
      const m = read(res, body)
      if (m.errorText || res.status >= 500) bad++
      console.log(`PAGE|${r}|${a.codes.length} codes|${label}|${res.status}|${Date.now() - t0}ms|${JSON.stringify(m)}`)
    }
  }
  return exitAfterCleanup(bad ? 6 : 0)
}
main().catch((e) => { console.error('✗', e?.stack || e); if (exitAfterCleanup) exitAfterCleanup(2); else process.exit(2) })
