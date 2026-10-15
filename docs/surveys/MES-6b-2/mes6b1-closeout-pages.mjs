// MES-6b-1 close-out item 1.3 b (live half) — page probe on the DEPLOYED app (read-only). Five one-off clones of real roles (cloneOf: exactly
// that role's codes at this moment): cco, cto, warehouse, finance, admin. Each one GETs the NCR list, the NCR "new" page (bare, and with an output
// batch chosen), the output list (the page that failed in MES-6b-1's smoke), an output batch page, an inbound batch page and a sales-order page,
// and reads from the server-rendered HTML: HTTP status, the page heading, whether the page refused (data-access-denied), which permission codes
// a disabled control names (data-permission-required), whether the quality panel is drawn (data-panel="quality"), table body row count, and
// whether an application error is shown. Only GET requests are made; nothing is submitted.
// ★ Live has 0 NCRs and 0 contracts (read 2026-10-15 18:5x CST as postgres), so the NCR detail page, the hold banners and the contract
//   quality-limits section cannot be shown on live — they are measured on a local rebuild with data of my own (mes6b1-closeout-local.mjs).
// The throwaway accounts are removed by the ephemeral plan (prefix mes6b1probe, already registered in scripts/ephemeral.mjs).
// Verdict line: PAGES_PROBE_EXIT=<n> (0 = every fetch returned and no page showed an application error).
import { onlyWhenRunDirectly } from '../../../scripts/lib/entrypoint.mjs'
// ★ It acts on live, so it runs only when executed directly — importing this file starts nothing.
onlyWhenRunDirectly(import.meta.url)

const REPO = new URL('../../..', import.meta.url).pathname.replace(/\/$/, '')
let openPlan, mintThrowaway, reapStalePlans, installExitHooks, exitAfterCleanup, acquireOrExit, release, heldBy
const BASE = process.env.PROBE_BASE || 'https://new-era-erp.vercel.app'
// read on live (postgres, BEGIN READ ONLY): the newest live output batch, inbound batch and sales order
const OUT_ID = '7329b061-9b21-4ad3-bc23-2ead6c8fb30a'   // OUT-2026-0380
const IN_ID = '2d8670e8-2c4c-48b4-bae3-53ed9030eaad'    // ZZ-PROCCOST1-DEMO
const SO_ID = 'b5a89d4b-80d7-4797-b130-d1250504014d'    // ZZ2B-SO2
const ROLES = ['cco', 'cto', 'warehouse', 'finance', 'admin']
const PAGES = [
  ['ncr list', '/quality/ncr'],
  ['ncr new', '/quality/ncr/new'],
  ['ncr new (batch chosen)', `/quality/ncr/new?batch=output:${OUT_ID}`],
  ['output list', '/output'],
  ['output batch', `/output/${OUT_ID}/edit`],
  ['inbound batch', `/inbound/${IN_ID}/edit`],
  ['sales order', `/sales/orders/${SO_ID}`],
]
let locked = false

function read(body) {
  const h1 = (body.match(/<h1[^>]*>([\s\S]*?)<\/h1>/) || [])[1]?.replace(/<[^>]+>/g, '').trim() ?? null
  const tbodies = [...body.matchAll(/<tbody[^>]*>([\s\S]*?)<\/tbody>/g)].map((m) => (m[1].match(/<tr[\s>]/g) || []).length)
  return {
    h1, refused: body.includes('data-access-denied'),
    needs: [...new Set([...body.matchAll(/data-permission-required="([^"]+)"/g)].map((m) => m[1]))],
    qualityPanel: body.includes('data-panel="quality"'),
    holdBanner: /on quality hold/.test(body),
    tbodyRows: tbodies,
    emptyNcr: /No non-conformance reports/i.test(body),
    errorText: /Application error|Internal Server Error|This page couldn.t load/.test(body),
  }
}

async function main() {
  ;({ openPlan, mintThrowaway, reapStalePlans, installExitHooks, exitAfterCleanup } = await import(REPO + '/scripts/ephemeral.mjs'))
  ;({ acquireOrExit, release, heldBy } = await import(REPO + '/scripts/liveLock.mjs'))
  installExitHooks({ onFinish: (code) => { try { if (locked) release() } catch {}; console.log(`PAGES_PROBE_EXIT=${code}`) } })
  const other = heldBy(); if (other) { console.error(`live-lock held by ${other.holder}`); return exitAfterCleanup(5) }
  acquireOrExit('mes6b1-closeout-pages.mjs', { ownExit: false }); locked = true
  openPlan('docs/surveys/MES-6b-2/mes6b1-closeout-pages.mjs'); await reapStalePlans()
  const stamp = Date.now()
  let bad = 0
  for (const r of ROLES) {
    const a = await mintThrowaway({ prefix: 'mes6b1probe', label: `cof-${r}`, stamp, codes: { cloneOf: r } })
    for (const [label, path] of PAGES) {
      const t0 = Date.now()
      const res = await fetch(BASE + path, { headers: { cookie: a.cookie }, redirect: 'manual' })
      const body = await res.text()
      const m = read(body)
      if (m.errorText || res.status >= 500) bad++
      console.log(`PAGE|${r}|${a.codes.length} codes|${label}|${res.status}|${Date.now() - t0}ms|${JSON.stringify(m)}`)
    }
  }
  return exitAfterCleanup(bad ? 6 : 0)
}
main().catch((e) => { console.error('✗', e?.stack || e); if (exitAfterCleanup) exitAfterCleanup(2); else process.exit(2) })
