// MES-7a-1 close-out item 1.2 b — page probe on the DEPLOYED app (read-only). Five one-off clones of real roles (cloneOf: exactly that role's
// codes at this moment): admin, cco, cto, warehouse, finance. Each one GETs /operation/equipment, an equipment detail page (FA-2026-0001, the
// machine live has downtime, maintenance and an interval on), the reliability view, the dictionaries page, /finance/assets and the same machine's
// asset card, and reads from the server-rendered response: HTTP status, the heading, whether the page refused (data-access-denied), which
// permission codes a disabled control names (data-permission-required) and how many such gates there are, whether the downtime / maintenance /
// interval entry points are drawn (their labels), whether the "needs processing edit" sentence or the "recorded on the machine page" pointer is
// shown, whether the reliability table renders (data-rel cells), whether the dictionaries page shows "Downtime causes", whether the asset card
// still lists the downtime / maintenance records and offers "Capitalise", and whether an application error is shown. Only GET requests; nothing
// is submitted.
// The throwaway accounts are removed by the ephemeral plan (prefix mes7a1probe, already registered in scripts/ephemeral.mjs).
// Verdict line: PAGES_PROBE_EXIT=<n> (0 = every fetch returned and no page showed an application error).
import { onlyWhenRunDirectly } from '../../../scripts/lib/entrypoint.mjs'
// ★ It acts on live, so it runs only when executed directly — importing this file starts nothing.
onlyWhenRunDirectly(import.meta.url)

const REPO = new URL('../../..', import.meta.url).pathname.replace(/\/$/, '')
let openPlan, mintThrowaway, reapStalePlans, installExitHooks, exitAfterCleanup, acquireOrExit, release, heldBy
const BASE = process.env.PROBE_BASE || 'https://new-era-erp.vercel.app'
// read on live (postgres, 2026-10-16 11:2x CST): FA-2026-0001 Bosch Deep Discharging Machine
const ASSET = 'a1560d88-de19-40fe-b78b-3bfa4079762b'
const ROLES = ['admin', 'cco', 'cto', 'warehouse', 'finance']
const PAGES = [
  ['equipment list', '/operation/equipment'],
  ['equipment detail', `/operation/equipment/${ASSET}`],
  ['reliability', '/operation/equipment/reliability'],
  ['dictionaries', '/settings/dictionaries'],
  ['finance assets', '/finance/assets'],
  ['finance asset card', `/finance/assets/${ASSET}`],
]
let locked = false

const text = (html) => html.replace(/<script[\s\S]*?<\/script>/g, ' ').replace(/<style[\s\S]*?<\/style>/g, ' ').replace(/<[^>]+>/g, ' ')
  .replace(/&#x27;/g, "'").replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/\s+/g, ' ')
function read(res, body) {
  const ct = res.headers.get('content-type') || ''
  if (!ct.includes('text/html')) return { contentType: ct, bytes: body.length }
  const tx = text(body)
  const h1 = (body.match(/<h1[^>]*>([\s\S]*?)<\/h1>/) || [])[1]?.replace(/<[^>]+>/g, '').trim() ?? null
  const gates = [...body.matchAll(/data-permission-required="([^"]+)"/g)].map((m) => m[1])
  const gateCount = {}
  for (const g of gates) gateCount[g] = (gateCount[g] || 0) + 1
  return {
    h1, refused: body.includes('data-access-denied'),
    gates: gateCount,
    downtimeAdd: tx.includes('Start a downtime period'),
    downtimeClose: tx.includes('Close this period'),
    downtimeOpenNow: tx.includes('This machine is DOWN NOW'),
    maintAdd: tx.includes('Record work'),
    intervalAdd: tx.includes('Add an interval'),
    needsProcessingEdit: tx.includes('Recording maintenance, downtime and service intervals needs edit rights'),
    recordedOnMachinePage: tx.includes('are recorded on the machine’s equipment page') || tx.includes("are recorded on the machine's equipment page"),
    reliabilitySection: body.includes('data-section="reliability"'),
    relCells: (body.match(/data-rel="(hours|failures|mtbf|mttr)"/g) || []).length,
    relNoHours: tx.includes('No operating hours recorded') || tx.includes('none recorded'),
    downtimeCauses: tx.includes('Downtime causes'),
    causeNames: ['Breakdown', 'Planned maintenance', 'External'].filter((n) => tx.includes(n)),
    downtimeTitle: tx.includes('Downtime'),
    maintTitle: tx.includes('Maintenance and repairs'),
    notClassified: tx.includes('Not classified'),
    capitalise: tx.includes('Capitalise'),
    tbodyRows: [...body.matchAll(/<tbody[^>]*>([\s\S]*?)<\/tbody>/g)].map((m) => (m[1].match(/<tr[\s>]/g) || []).length),
    errorText: /Application error|Internal Server Error|This page couldn.t load/.test(body),
  }
}

async function main() {
  ;({ openPlan, mintThrowaway, reapStalePlans, installExitHooks, exitAfterCleanup } = await import(REPO + '/scripts/ephemeral.mjs'))
  ;({ acquireOrExit, release, heldBy } = await import(REPO + '/scripts/liveLock.mjs'))
  installExitHooks({ onFinish: (code) => { try { if (locked) release() } catch {}; console.log(`PAGES_PROBE_EXIT=${code}`) } })
  const other = heldBy(); if (other) { console.error(`live-lock held by ${other.holder}`); return exitAfterCleanup(5) }
  acquireOrExit('mes7a1-closeout-pages.mjs', { ownExit: false }); locked = true
  openPlan('docs/surveys/MES-7a-2/mes7a1-closeout-pages.mjs'); await reapStalePlans()
  const stamp = Date.now()
  let bad = 0
  for (const r of ROLES) {
    const a = await mintThrowaway({ prefix: 'mes7a1probe', label: `cof-${r}`, stamp, codes: { cloneOf: r } })
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
