// MES-7b-1 close-out item 1.2 b — page probe on the DEPLOYED app (read-only). One-off clones of real roles (cloneOf: exactly that role's codes
// at this moment): admin, cto, warehouse, cfo and finance (the brief's five). Each clone GETs the incident list (/safety/incidents), the
// new-incident page (/safety/incidents/new), the new-handover form (/operation/handovers/new — where a handover cites incidents) and
// /settings/pending-values, and reads from the server-rendered response: HTTP status, the heading, whether the page refused
// (data-access-denied), which permission codes a disabled control names (data-permission-required), whether "Record an incident" is a
// pressable link to /safety/incidents/new, whether the V19 settings panel is drawn, the handover form's incident section (drawn / Restricted /
// "none cited" / a list), whether the pending-values page lists V19 and says it is unconfirmed, and whether an application error is shown.
// Live holds no incident, so the incident page itself and the "Restricted" injury reading are measured on a local rebuild (mes7b1-closeout-local.mjs).
// Only GET requests; nothing is submitted. The throwaway accounts are removed by the ephemeral plan (prefix mes7b1probe, already registered in
// scripts/ephemeral.mjs). Verdict line: PAGES_PROBE_EXIT=<n> (0 = every fetch returned and no page showed an application error).
import { onlyWhenRunDirectly } from '../../../scripts/lib/entrypoint.mjs'
// ★ It acts on live, so it runs only when executed directly — importing this file starts nothing.
onlyWhenRunDirectly(import.meta.url)

const REPO = new URL('../../..', import.meta.url).pathname.replace(/\/$/, '')
let openPlan, mintThrowaway, reapStalePlans, installExitHooks, exitAfterCleanup, acquireOrExit, release, heldBy
const BASE = process.env.PROBE_BASE || 'https://new-era-erp.vercel.app'
const ROLES = ['admin', 'cto', 'warehouse', 'cfo', 'finance']
const PAGES = [
  ['incident list', '/safety/incidents'],
  ['new incident', '/safety/incidents/new'],
  ['new handover', '/operation/handovers/new'],
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
  const gates = {}
  for (const m of body.matchAll(/data-permission-required="([^"]+)"/g)) gates[m[1]] = (gates[m[1]] || 0) + 1
  const ho = (body.split('data-section="handover-incidents"')[1] || '').split(/data-section="|<textarea/)[0]
  const hoText = text('<x ' + ho)
  const v19 = (body.split('data-pending-value="V19"')[1] || '').split('data-pending-value="')[0]
  return {
    h1, refused: body.includes('data-access-denied'), gates,
    recordLink: /<a[^>]+href="\/safety\/incidents\/new"[^>]*>[^<]*Record an incident/.test(body),
    recordText: tx.includes('Record an incident'),
    emptyList: tx.includes('No incident has been recorded.'),
    v19Panel: tx.includes('NEA written-report deadline (V19)'),
    formInjurySection: body.includes('data-section="injury"'),
    handoverIncidents: body.includes('data-section="handover-incidents"')
      ? (hoText.includes('Restricted') ? 'restricted' : hoText.includes('Incidents') ? (/type="checkbox"/.test(ho) ? 'list' : 'none-cited-or-empty') : 'drawn')
      : null,
    handoverIncidentsText: body.includes('data-section="handover-incidents"') ? hoText.slice(0, 160) : null,
    pendingV19: body.includes('data-pending-value="V19"'),
    pendingV19Unconfirmed: /unconfirmed/i.test(text('<x ' + v19)),
    pendingV19Text: v19 ? text('<x ' + v19).slice(0, 220) : null,
    errorText: /Application error|Internal Server Error|This page couldn.t load/.test(body),
  }
}

async function main() {
  ;({ openPlan, mintThrowaway, reapStalePlans, installExitHooks, exitAfterCleanup } = await import(REPO + '/scripts/ephemeral.mjs'))
  ;({ acquireOrExit, release, heldBy } = await import(REPO + '/scripts/liveLock.mjs'))
  installExitHooks({ onFinish: (code) => { try { if (locked) release() } catch {}; console.log(`PAGES_PROBE_EXIT=${code}`) } })
  const other = heldBy(); if (other) { console.error(`live-lock held by ${other.holder}`); return exitAfterCleanup(5) }
  acquireOrExit('mes7b1-closeout-pages.mjs', { ownExit: false }); locked = true
  openPlan('docs/surveys/MES-7b-2/mes7b1-closeout-pages.mjs'); await reapStalePlans()
  const stamp = Date.now()
  let bad = 0
  for (const r of ROLES) {
    const a = await mintThrowaway({ prefix: 'mes7b1probe', label: `cof-${r}`, stamp, codes: { cloneOf: r } })
    const has = (c) => a.codes.includes(c)
    const flags = `safety.view=${has('module.safety.view')}|safety.edit=${has('module.safety.edit')}|view_health=${has('data.view_health')}`
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
