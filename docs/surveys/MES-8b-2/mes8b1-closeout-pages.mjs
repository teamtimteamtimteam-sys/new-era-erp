// MES-8b-1 close-out item 1.3 b — page probe on the DEPLOYED app (read-only, GET only). One-off clones of real roles (cloneOf: exactly that role's
// codes at this moment): admin, cfo, cto, finance and warehouse (the brief's five). Each clone GETs an inbound batch page with its margin section
// (/inbound/<id>/edit, IN-2026-0001 — consumed by 7 runs), /finance/price-exposure (the inventory section), /compliance/packs (the preview, the freeze
// panel and the list of frozen packs) and /settings/pending-values, and reads from the server-rendered response: HTTP status, the heading, whether the
// page refused (data-access-denied), whether a section says "Restricted" (data-access-restricted), which permission codes a disabled control names
// (data-permission-required), whether the freeze button is drawn disabled (the disabled="" attribute — not Tailwind's disabled: classes), the margin state, the exposure total, and the V26 / V27 rows.
// Live holds no frozen pack and no locked month, so a pack page and a pressable freeze are measured on a local rebuild (mes8b1-closeout-local.mjs).
// The throwaway accounts are removed by the ephemeral plan (prefix mes8b1probe, already registered in scripts/ephemeral.mjs).
// Verdict line: PAGES_PROBE_EXIT=<n> (0 = every fetch returned and no page showed an application error).
import { onlyWhenRunDirectly } from '../../../scripts/lib/entrypoint.mjs'
// ★ It acts on live, so it runs only when executed directly — importing this file starts nothing.
onlyWhenRunDirectly(import.meta.url)

const REPO = new URL('../../..', import.meta.url).pathname.replace(/\/$/, '')
let openPlan, mintThrowaway, reapStalePlans, installExitHooks, exitAfterCleanup, acquireOrExit, release, heldBy
const BASE = process.env.PROBE_BASE || 'https://new-era-erp.vercel.app'
const INBOUND = process.argv[2]          // IN-2026-0001's id, read from live by closeout-readings.sql
const ROLES = ['admin', 'cfo', 'cto', 'finance', 'warehouse']
const PAGES = [
  ['inbound batch', `/inbound/${INBOUND}/edit`],
  ['price exposure', '/finance/price-exposure'],
  ['compliance packs', '/compliance/packs'],
  ['pending values', '/settings/pending-values'],
]
let locked = false

const text = (html) => html.replace(/<script[\s\S]*?<\/script>/g, ' ').replace(/<style[\s\S]*?<\/style>/g, ' ').replace(/<[^>]+>/g, ' ')
  .replace(/&#x27;/g, "'").replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/\s+/g, ' ')
const pv = (body, code) => { const s = body.split(`data-pending-value="${code}"`)[1]; return s ? text('<x ' + s.split('data-pending-value="')[0]).slice(0, 160) : null }
const after = (body, marker, n = 200) => { const s = body.split(marker)[1]; return s ? text('<x ' + s).slice(0, n) : null }
function read(res, body) {
  const ct = res.headers.get('content-type') || ''
  if (!ct.includes('text/html')) return { contentType: ct, bytes: body.length }
  const gates = {}
  for (const m of body.matchAll(/data-permission-required="([^"]+)"/g)) gates[m[1]] = (gates[m[1]] || 0) + 1
  const hooks = (attr) => [...new Set([...body.matchAll(new RegExp(`${attr}="([^"]+)"`, 'g'))].map((m) => m[1]))].join(',')
  const freeze = body.split('data-section="freeze-compliance-pack"')[1]?.split('</section>')[0] ?? null
  return {
    h1: (body.match(/<h1[^>]*>([\s\S]*?)<\/h1>/) || [])[1]?.replace(/<[^>]+>/g, '').trim() ?? null,
    refused: body.includes('data-access-denied'), restricted: hooks('data-access-restricted'), gates,
    sections: hooks('data-section'), notices: hooks('data-notice'),
    marginState: (body.match(/data-value="margin-([a-z_]+)"/) || [])[1] ?? null,
    margin: after(body, 'data-value="inbound-margin"', 40),
    exposureTotal: after(body, 'data-value="exposure-total"', 120),
    freeze: freeze === null ? null : { gate: (freeze.match(/data-permission-required="([^"]+)"/) || [])[1] ?? null,
      fieldsetDisabled: /<fieldset[^>]*\sdisabled=""/.test(freeze), buttonDisabled: /<button[^>]*\sdisabled=""/.test(freeze), button: text(freeze.split('<button')[1] ? '<b ' + freeze.split('<button')[1].split('</button>')[0] : '').trim() },
    packsList: after(body, 'data-section="compliance-packs"', 160),
    pendingV26: pv(body, 'V26'), pendingV27: pv(body, 'V27'),
    errorText: /Application error|Internal Server Error|This page couldn.t load/.test(body),
  }
}

async function main() {
  if (!INBOUND) { console.error('usage: node mes8b1-closeout-pages.mjs <inbound batch id>'); process.exit(2) }
  ;({ openPlan, mintThrowaway, reapStalePlans, installExitHooks, exitAfterCleanup } = await import(REPO + '/scripts/ephemeral.mjs'))
  ;({ acquireOrExit, release, heldBy } = await import(REPO + '/scripts/liveLock.mjs'))
  installExitHooks({ onFinish: (code) => { try { if (locked) release() } catch {}; console.log(`PAGES_PROBE_EXIT=${code}`) } })
  const other = heldBy(); if (other) { console.error(`live-lock held by ${other.holder}`); return exitAfterCleanup(5) }
  acquireOrExit('mes8b1-closeout-pages.mjs', { ownExit: false }); locked = true
  openPlan('docs/surveys/MES-8b-2/mes8b1-closeout-pages.mjs'); await reapStalePlans()
  const stamp = Date.now()
  let bad = 0
  for (const r of ROLES) {
    const a = await mintThrowaway({ prefix: 'mes8b1probe', label: `co-${r}`, stamp, codes: { cloneOf: r } })
    const has = (c) => a.codes.includes(c)
    const flags = ['data.view_prices', 'module.finance.view', 'module.processing.view', 'module.compliance.view', 'action.compliance_pack']
      .map((c) => `${c}=${has(c)}`).join('|')
    for (const [label, path] of PAGES) {
      const t0 = Date.now()
      const res = await fetch(BASE + path, { headers: { cookie: a.cookie }, redirect: 'manual' })
      const body = await res.text()
      const m = read(res, body)
      if (m.errorText || res.status >= 500) bad++
      console.log(`PAGE|${r}|${a.codes.length} codes|${flags}|${label}|${res.status}|${Date.now() - t0}ms|${JSON.stringify(m)}`)
    }
  }
  return exitAfterCleanup(bad ? 6 : 0)
}
main().catch((e) => { console.error('✗', e?.stack || e); if (exitAfterCleanup) exitAfterCleanup(2); else process.exit(2) })
