// MES-7b-2 close-out item 1.3 b — page probe on the DEPLOYED app (read-only). One-off clones of real roles (cloneOf: exactly that role's codes
// at this moment): admin, cto, warehouse, cfo and finance (the brief's five). Each clone GETs the inspection list (/safety/inspections), the
// new-checklist page (/safety/inspections/templates/new), the environment page (/safety/environment) and /settings/pending-values, and reads from
// the server-rendered response: HTTP status, the heading, whether the page refused (data-access-denied), which permission codes a disabled control
// names (data-permission-required), whether "New checklist" is a pressable link, whether the checklist form is drawn, the environment page's
// "no parameter" notice and whether its record form is drawn, the V18 / V20 rows on the pending-values page, and whether an application error is
// shown. Live holds no checklist, run, parameter or result, so "Record an inspection", a run page and the environment record form are measured on a
// local rebuild with my own data (mes7b2-closeout-local.mjs).
// Only GET requests; nothing is submitted. The throwaway accounts are removed by the ephemeral plan (prefix mes7b2probe, already registered in
// scripts/ephemeral.mjs:250). Verdict line: PAGES_PROBE_EXIT=<n> (0 = every fetch returned and no page showed an application error).
import { onlyWhenRunDirectly } from '../../../scripts/lib/entrypoint.mjs'
// ★ It acts on live, so it runs only when executed directly — importing this file starts nothing.
onlyWhenRunDirectly(import.meta.url)

const REPO = new URL('../../..', import.meta.url).pathname.replace(/\/$/, '')
let openPlan, mintThrowaway, reapStalePlans, installExitHooks, exitAfterCleanup, acquireOrExit, release, heldBy
const BASE = process.env.PROBE_BASE || 'https://new-era-erp.vercel.app'
const ROLES = ['admin', 'cto', 'warehouse', 'cfo', 'finance']
const PAGES = [
  ['inspection list', '/safety/inspections'],
  ['new checklist', '/safety/inspections/templates/new'],
  ['environment', '/safety/environment'],
  ['pending values', '/settings/pending-values'],
]
let locked = false

const text = (html) => html.replace(/<script[\s\S]*?<\/script>/g, ' ').replace(/<style[\s\S]*?<\/style>/g, ' ').replace(/<[^>]+>/g, ' ')
  .replace(/&#x27;/g, "'").replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/\s+/g, ' ')
function section(body, attr) {
  const s = body.split(attr)[1]
  return s ? s.split('data-pending-value="')[0] : ''
}
function read(res, body) {
  const ct = res.headers.get('content-type') || ''
  if (!ct.includes('text/html')) return { contentType: ct, bytes: body.length }
  const tx = text(body)
  const h1 = (body.match(/<h1[^>]*>([\s\S]*?)<\/h1>/) || [])[1]?.replace(/<[^>]+>/g, '').trim() ?? null
  const gates = {}
  for (const m of body.matchAll(/data-permission-required="([^"]+)"/g)) gates[m[1]] = (gates[m[1]] || 0) + 1
  const v18 = section(body, 'data-pending-value="V18"'), v20 = section(body, 'data-pending-value="V20"')
  return {
    h1, refused: body.includes('data-access-denied'), gates,
    newChecklistLink: /<a[^>]+href="\/safety\/inspections\/templates\/new"[^>]*>[^<]*New checklist/.test(body),
    newChecklistText: tx.includes('New checklist'),
    noTemplates: tx.includes('No checklist yet.'),
    noRuns: tx.includes('No inspection has been recorded.'),
    checklistForm: body.includes('data-form="inspection-template"'),
    envNoParameters: body.includes('data-notice="no-parameters"'),
    envForm: body.includes('data-form="environmental-result"'),
    envNoResults: tx.includes('No result has been recorded') || tx.includes('No result'),
    pendingV18: body.includes('data-pending-value="V18"'),
    pendingV18Text: v18 ? text('<x ' + v18).slice(0, 200) : null,
    pendingV20: body.includes('data-pending-value="V20"'),
    pendingV20Text: v20 ? text('<x ' + v20).slice(0, 200) : null,
    errorText: /Application error|Internal Server Error|This page couldn.t load/.test(body),
  }
}

async function main() {
  ;({ openPlan, mintThrowaway, reapStalePlans, installExitHooks, exitAfterCleanup } = await import(REPO + '/scripts/ephemeral.mjs'))
  ;({ acquireOrExit, release, heldBy } = await import(REPO + '/scripts/liveLock.mjs'))
  installExitHooks({ onFinish: (code) => { try { if (locked) release() } catch {}; console.log(`PAGES_PROBE_EXIT=${code}`) } })
  const other = heldBy(); if (other) { console.error(`live-lock held by ${other.holder}`); return exitAfterCleanup(5) }
  acquireOrExit('mes7b2-closeout-pages.mjs', { ownExit: false }); locked = true
  openPlan('docs/surveys/MES-8/mes7b2-closeout-pages.mjs'); await reapStalePlans()
  const stamp = Date.now()
  let bad = 0
  for (const r of ROLES) {
    const a = await mintThrowaway({ prefix: 'mes7b2probe', label: `cof-${r}`, stamp, codes: { cloneOf: r } })
    const has = (c) => a.codes.includes(c)
    const flags = `safety.view=${has('module.safety.view')}|safety.edit=${has('module.safety.edit')}`
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
