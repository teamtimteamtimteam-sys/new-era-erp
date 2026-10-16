// MES-7a-2 close-out item 1.3 b — page probe on the DEPLOYED app (read-only). One-off clones of real roles (cloneOf: exactly that role's codes
// at this moment): admin, cco, finance, warehouse (the brief's four) and cfo (the one live role among the seven real accounts' roles that does
// NOT hold module.inventory.edit, so the "disabled with the code named" half has a subject). Each clone GETs the machine page of FA-2026-0001,
// the stock roll-forward (/operation/balance), the trial balance with every account (/finance/trial-balance?all=1 — there is no chart-of-accounts
// page) and /settings/pending-values, and reads from the server-rendered response: HTTP status, the heading, whether the page refused
// (data-access-denied), which permission codes a disabled control names (data-permission-required) and how many, whether the spare-parts panel
// is drawn (data-section="spare-parts") with its "Issue spare parts" entry, the "no parts issued" line and the "amounts only to price viewers"
// line, whether the roll-forward shows the "Issued to maintenance (net of returns)" column, whether the trial balance lists 6800 Repairs &
// Maintenance and whether any word marks it as a system account, whether the pending-values page lists V21, and whether an application error
// is shown. Only GET requests; nothing is submitted.
// The throwaway accounts are removed by the ephemeral plan (prefix mes7a2probe, already registered in scripts/ephemeral.mjs).
// Verdict line: PAGES_PROBE_EXIT=<n> (0 = every fetch returned and no page showed an application error).
import { onlyWhenRunDirectly } from '../../../scripts/lib/entrypoint.mjs'
// ★ It acts on live, so it runs only when executed directly — importing this file starts nothing.
onlyWhenRunDirectly(import.meta.url)

const REPO = new URL('../../..', import.meta.url).pathname.replace(/\/$/, '')
let openPlan, mintThrowaway, reapStalePlans, installExitHooks, exitAfterCleanup, acquireOrExit, release, heldBy
const BASE = process.env.PROBE_BASE || 'https://new-era-erp.vercel.app'
// FA-2026-0001 Bosch Deep Discharging Machine (id recorded by the MES-7a-1 close-out probe, docs/surveys/MES-7a-2/mes7a1-closeout-pages.mjs)
const ASSET = 'a1560d88-de19-40fe-b78b-3bfa4079762b'
const ROLES = ['admin', 'cco', 'finance', 'warehouse', 'cfo']
const PAGES = [
  ['machine page', `/operation/equipment/${ASSET}`],
  ['roll-forward', '/operation/balance'],
  ['trial balance (all)', '/finance/trial-balance?all=1'],
  ['pending values', '/settings/pending-values'],
]
let locked = false

const text = (html) => html.replace(/<script[\s\S]*?<\/script>/g, ' ').replace(/<style[\s\S]*?<\/style>/g, ' ').replace(/<[^>]+>/g, ' ')
  .replace(/&#x27;/g, "'").replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/\s+/g, ' ')
function read(res, body) {
  const ct = res.headers.get('content-type') || ''
  if (!ct.includes('text/html')) return { contentType: ct, bytes: body.length }
  const tx = text(body)
  const h1 = (body.match(/<h1[^>]*>([\s\S]*?)<\/h1>/) || [])[1]?.replace(/<[^>]+>/g, '').trim() ?? null
  const gateCount = {}
  for (const m of body.matchAll(/data-permission-required="([^"]+)"/g)) gateCount[m[1]] = (gateCount[m[1]] || 0) + 1
  const parts = (body.match(/data-section="spare-parts"[\s\S]*?(?=data-section="|$)/) || [''])[0]
  const partsGates = {}
  for (const m of parts.matchAll(/data-permission-required="([^"]+)"/g)) partsGates[m[1]] = (partsGates[m[1]] || 0) + 1
  const row6800 = (tx.match(/6800 [^0-9]{0,60}/) || [null])[0]
  return {
    h1, refused: body.includes('data-access-denied'),
    gates: gateCount,
    partsSection: body.includes('data-section="spare-parts"'),
    partsTitle: tx.includes('Spare parts issued to maintenance'),
    partsIssueEntry: tx.includes('Issue spare parts'),
    partsGates,
    partsNone: tx.includes('No spare parts have been issued to this machine'),
    partsValueRestricted: tx.includes('Amounts are shown only to people who can see prices.'),
    rollMaintenanceCol: tx.includes('Issued to maintenance (net of returns)'),
    tb6800: row6800,
    tbSystemWord: /6800[^0-9]{0,80}\b(system|System)\b/.test(tx),
    v21: tx.includes('Minimum stock of a spare part'),
    pvHeading: tx.includes('Pending values') || tx.includes('Not yet set'),
    errorText: /Application error|Internal Server Error|This page couldn.t load/.test(body),
  }
}

async function main() {
  ;({ openPlan, mintThrowaway, reapStalePlans, installExitHooks, exitAfterCleanup } = await import(REPO + '/scripts/ephemeral.mjs'))
  ;({ acquireOrExit, release, heldBy } = await import(REPO + '/scripts/liveLock.mjs'))
  installExitHooks({ onFinish: (code) => { try { if (locked) release() } catch {}; console.log(`PAGES_PROBE_EXIT=${code}`) } })
  const other = heldBy(); if (other) { console.error(`live-lock held by ${other.holder}`); return exitAfterCleanup(5) }
  acquireOrExit('mes7a2-closeout-pages.mjs', { ownExit: false }); locked = true
  openPlan('docs/surveys/MES-7b/mes7a2-closeout-pages.mjs'); await reapStalePlans()
  const stamp = Date.now()
  let bad = 0
  for (const r of ROLES) {
    const a = await mintThrowaway({ prefix: 'mes7a2probe', label: `cof-${r}`, stamp, codes: { cloneOf: r } })
    const inv = a.codes.includes('module.inventory.edit')
    for (const [label, path] of PAGES) {
      const t0 = Date.now()
      const res = await fetch(BASE + path, { headers: { cookie: a.cookie }, redirect: 'manual' })
      const body = await res.text()
      const m = read(res, body)
      if (m.errorText || res.status >= 500) bad++
      console.log(`PAGE|${r}|${a.codes.length} codes|inventory.edit=${inv}|${label}|${res.status}|${Date.now() - t0}ms|${JSON.stringify(m)}`)
    }
  }
  return exitAfterCleanup(bad ? 6 : 0)
}
main().catch((e) => { console.error('✗', e?.stack || e); if (exitAfterCleanup) exitAfterCleanup(2); else process.exit(2) })
