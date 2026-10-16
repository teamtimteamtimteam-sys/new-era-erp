// MES-8a close-out item 1.2 b — page probe on the DEPLOYED app (read-only). One-off clones of real roles (cloneOf: exactly that role's codes at
// this moment): admin, cco, finance, warehouse and cfo (the brief's five). Each clone GETs the scorecard list (/suppliers/scorecards), one supplier's
// page with its scorecard panel (/suppliers/<id>/edit, SUP-2026-0003 — the one approved goods supplier on live), the new-PO form
// (/purchasing/orders/new), the supplier statement list (/finance/supplier-statements) and /settings/pending-values, and reads from the
// server-rendered response: HTTP status, the heading, whether the page refused (data-access-denied), which permission codes a disabled control
// names (data-permission-required), which data-section / data-form hooks are drawn, the V23 / V24 rows, and whether an application error shows.
// The PO form's grade line renders only after a supplier is chosen (a client component asking the database), so for that one step the probe
// drives headless Chrome over CDP: open the form with the clone's cookie, wait for hydration, choose SUP-2026-0003, read [data-value="supplier-grade"].
// Choosing a supplier calls a read-only server action (supplier_grade_advice); nothing is submitted anywhere.
// Live holds no review, no V23 / V24 value and no statement, so the review history, a graded line, a statement page and the issue action with data
// are measured on a local rebuild with my own data (mes8a-closeout-local.mjs).
// The throwaway accounts are removed by the ephemeral plan (prefix mes8aprobe, already registered in scripts/ephemeral.mjs:250).
// Verdict line: PAGES_PROBE_EXIT=<n> (0 = every fetch returned and no page showed an application error).
import { onlyWhenRunDirectly } from '../../../scripts/lib/entrypoint.mjs'
// ★ It acts on live, so it runs only when executed directly — importing this file starts nothing.
onlyWhenRunDirectly(import.meta.url)
import { spawn } from 'node:child_process'
import { readFileSync, mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const REPO = new URL('../../..', import.meta.url).pathname.replace(/\/$/, '')
let openPlan, mintThrowaway, reapStalePlans, installExitHooks, exitAfterCleanup, acquireOrExit, release, heldBy
const BASE = process.env.PROBE_BASE || 'https://new-era-erp.vercel.app'
const SUPPLIER = process.argv[2]          // SUP-2026-0003's id, read from live by closeout-readings.sql
const ROLES = ['admin', 'cco', 'finance', 'warehouse', 'cfo']
const PAGES = [
  ['scorecards', '/suppliers/scorecards'],
  ['supplier page', `/suppliers/${SUPPLIER}/edit`],
  ['new PO', '/purchasing/orders/new'],
  ['supplier statements', '/finance/supplier-statements'],
  ['pending values', '/settings/pending-values'],
]
const CHROME = join(process.env.HOME, readFileSync(REPO + '/scripts/survey-phone.mjs', 'utf8').match(/const CHROME = join\(process\.env\.HOME, '([^']+)'\)/)[1])
let locked = false

const text = (html) => html.replace(/<script[\s\S]*?<\/script>/g, ' ').replace(/<style[\s\S]*?<\/style>/g, ' ').replace(/<[^>]+>/g, ' ')
  .replace(/&#x27;/g, "'").replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/\s+/g, ' ')
const pv = (body, code) => { const s = body.split(`data-pending-value="${code}"`)[1]; return s ? text('<x ' + s.split('data-pending-value="')[0]).slice(0, 180) : null }
function read(res, body) {
  const ct = res.headers.get('content-type') || ''
  if (!ct.includes('text/html')) return { contentType: ct, bytes: body.length }
  const gates = {}
  for (const m of body.matchAll(/data-permission-required="([^"]+)"/g)) gates[m[1]] = (gates[m[1]] || 0) + 1
  const hooks = (attr) => [...new Set([...body.matchAll(new RegExp(`${attr}="([^"]+)"`, 'g'))].map((m) => m[1]))].join(',')
  const tx = text(body)
  return {
    h1: (body.match(/<h1[^>]*>([\s\S]*?)<\/h1>/) || [])[1]?.replace(/<[^>]+>/g, '').trim() ?? null,
    refused: body.includes('data-access-denied'), gates,
    sections: hooks('data-section'), forms: hooks('data-form'), notices: hooks('data-notice'),
    notGraded: tx.includes('Not graded'), notReviewed: tx.includes('Not reviewed') || tx.includes('No review'),
    supplierSelect: body.includes('name="supplier_id"'),
    pendingV23: pv(body, 'V23'), pendingV24: pv(body, 'V24'),
    errorText: /Application error|Internal Server Error|This page couldn.t load/.test(body),
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
// One headless Chrome per clone, driven over CDP; fn(ev, go) does the reading. The cookie is the clone's own session.
async function withPage(a, fn) {
  const port = 9370 + Math.floor(Math.random() * 50)
  const dir = mkdtempSync(join(tmpdir(), 'mes8aco-'))
  const chrome = spawn(CHROME, [`--remote-debugging-port=${port}`, '--headless', '--disable-gpu', '--no-sandbox', `--user-data-dir=${dir}`, 'about:blank'], { stdio: 'ignore' })
  try {
    let ws = null
    for (let i = 0; i < 60 && !ws; i++) { await sleep(500); try { ws = (await (await fetch(`http://127.0.0.1:${port}/json/version`)).json()).webSocketDebuggerUrl } catch {} }
    const sock = new WebSocket(ws); await new Promise((r, j) => { sock.onopen = r; sock.onerror = j })
    let id = 0, sid = null; const wait = new Map()
    sock.onmessage = (e) => { const m = JSON.parse(e.data); if (m.id && wait.has(m.id)) { const w = wait.get(m.id); wait.delete(m.id); if (m.error) w.j(new Error(JSON.stringify(m.error))); else w.r(m.result) } }
    const S = (method, params = {}) => new Promise((r, j) => { const i = ++id; wait.set(i, { r, j }); sock.send(JSON.stringify({ id: i, method, params, ...(sid ? { sessionId: sid } : {}) })) })
    const t = await S('Target.createTarget', { url: 'about:blank' }); sid = (await S('Target.attachToTarget', { targetId: t.targetId, flatten: true })).sessionId
    await S('Page.enable'); await S('Runtime.enable')
    const host = new URL(BASE).hostname
    await S('Network.setCookies', { cookies: [{ name: a.cookieName, value: a.cookieValue, domain: host, path: '/', secure: BASE.startsWith('https') }] })
    const ev = async (x) => (await S('Runtime.evaluate', { expression: x, returnByValue: true })).result.value
    const go = async (path, hydrationSelector) => {
      await S('Page.navigate', { url: BASE + path })
      for (let i = 0; i < 60; i++) {
        await sleep(500)
        if (await ev(`(() => { const s = document.querySelector(${JSON.stringify(hydrationSelector)}); return !!s && Object.keys(s).some((k) => k.startsWith('__react')) })()`)) return true
        if (await ev(`!!document.querySelector('[data-access-denied]')`)) return 'refused'
      }
      return false
    }
    return await fn(ev, go)
  } finally { chrome.kill('SIGKILL') }
}
const setSelect = (sel, value) => `(() => { const s = document.querySelector(${JSON.stringify(sel)}); if (!s) return { listed: false, options: -1 };
    const has = [...s.options].some((o) => o.value === ${JSON.stringify(value)}); if (!has) return { listed: false, options: s.options.length - 1 };
    Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, 'value').set.call(s, ${JSON.stringify(value)});
    s.dispatchEvent(new Event('change', { bubbles: true })); return { listed: true, options: s.options.length - 1 } })()`
const setText = (sel, i, value) => `(() => { const el = document.querySelectorAll(${JSON.stringify(sel)})[${i}]; if (!el) return false;
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(el, ${JSON.stringify(value)});
    el.dispatchEvent(new Event('input', { bubbles: true })); el.dispatchEvent(new Event('blur', { bubbles: true })); return true })()`

// The PO form's grade line: choose the supplier, read [data-value="supplier-grade"].
const gradeLine = (a) => withPage(a, async (ev, go) => {
  const hydrated = await go('/purchasing/orders/new', 'select[name="supplier_id"]')
  if (hydrated !== true) return { hydrated }
  const chosen = await ev(setSelect('select[name="supplier_id"]', SUPPLIER))
  if (!chosen.listed) return { hydrated, ...chosen }
  let line = null
  for (let i = 0; i < 40 && line === null; i++) { await sleep(500); line = await ev(`document.querySelector('[data-value="supplier-grade"]')?.textContent ?? document.querySelector('[data-error="grade-advice"]')?.textContent ?? null`) }
  return { hydrated, ...chosen, gradeLine: line }
})

// The statement issue action: choose the supplier and a period, press Preview (a read: supplier_statement_data), then read whether the issue
// control is drawn, whether it sits in a PermissionGate naming module.finance.edit, and whether its button is pressable. Nothing is issued.
const issueAction = (a) => withPage(a, async (ev, go) => {
  const hydrated = await go('/finance/supplier-statements', '[data-field="supplier_id"]')
  if (hydrated !== true) return { hydrated }
  const chosen = await ev(setSelect('[data-field="supplier_id"]', SUPPLIER))
  if (!chosen.listed) return { hydrated, ...chosen }
  await sleep(300)
  const dates = [await ev(setText('[data-date-text]', 0, '01/08/2026')), await ev(setText('[data-date-text]', 1, '16/10/2026'))]
  await sleep(500)
  const pressed = await ev(`(() => { const b = [...document.querySelectorAll('[data-section="issue-supplier-statement"] button')].find((x) => x.textContent.trim() === 'Preview');
      if (!b || b.disabled) return b ? 'disabled' : 'absent'; b.click(); return 'pressed' })()`)
  let out = null
  for (let i = 0; i < 40 && !out; i++) {
    await sleep(500)
    out = await ev(`(() => { const err = document.querySelector('[data-error="supplier-statement"]')?.textContent; if (err) return { error: err };
        const p = document.querySelector('[data-section="supplier-statement-preview"]'); if (!p) return null;
        const issue = [...document.querySelectorAll('[data-section="issue-supplier-statement"] button')].find((x) => x.textContent.trim() === 'Issue the statement');
        const gate = document.querySelector('[data-section="issue-supplier-statement"] [data-permission-required]');
        return { closing: p.querySelector('[data-value="closing"]')?.textContent ?? null, doesNotTie: !!p.querySelector('[data-flag="does-not-tie"]'),
                 issueButton: issue ? issue.textContent.trim() : null, issuePressable: issue ? !issue.disabled && !issue.closest('fieldset[disabled]') : null,
                 gate: gate ? gate.getAttribute('data-permission-required') : null } })()`)
  }
  return { hydrated, ...chosen, dates, pressed, ...(out ?? { preview: 'none within 20 s' }) }
})

async function main() {
  if (!SUPPLIER) { console.error('usage: node mes8a-closeout-pages.mjs <supplier id>'); process.exit(2) }
  ;({ openPlan, mintThrowaway, reapStalePlans, installExitHooks, exitAfterCleanup } = await import(REPO + '/scripts/ephemeral.mjs'))
  ;({ acquireOrExit, release, heldBy } = await import(REPO + '/scripts/liveLock.mjs'))
  installExitHooks({ onFinish: (code) => { try { if (locked) release() } catch {}; console.log(`PAGES_PROBE_EXIT=${code}`) } })
  const other = heldBy(); if (other) { console.error(`live-lock held by ${other.holder}`); return exitAfterCleanup(5) }
  acquireOrExit('mes8a-closeout-pages.mjs', { ownExit: false }); locked = true
  openPlan('docs/surveys/MES-8b-1/mes8a-closeout-pages.mjs'); await reapStalePlans()
  const stamp = Date.now()
  let bad = 0
  for (const r of ROLES) {
    const a = await mintThrowaway({ prefix: 'mes8aprobe', label: `co-${r}`, stamp, codes: { cloneOf: r } })
    const has = (c) => a.codes.includes(c)
    const flags = ['module.suppliers.view', 'action.supplier_review', 'module.purchasing.view', 'module.finance.view', 'module.finance.edit']
      .map((c) => `${c}=${has(c)}`).join('|')
    for (const [label, path] of PAGES) {
      const t0 = Date.now()
      const res = await fetch(BASE + path, { headers: { cookie: a.cookie }, redirect: 'manual' })
      const body = await res.text()
      const m = read(res, body)
      if (m.errorText || res.status >= 500) bad++
      console.log(`PAGE|${r}|${a.codes.length} codes|${flags}|${label}|${res.status}|${Date.now() - t0}ms|${JSON.stringify(m)}`)
    }
    const g = await gradeLine(a)
    if (g.hydrated !== true || g.listed === false || !g.gradeLine) bad++
    console.log(`GRADE|${r}|${JSON.stringify(g)}`)
    const s = await issueAction(a)
    if (s.hydrated === true && (s.listed === false || s.error || !s.issueButton)) bad++
    console.log(`ISSUE|${r}|${JSON.stringify(s)}`)
  }
  return exitAfterCleanup(bad ? 6 : 0)
}
main().catch((e) => { console.error('✗', e?.stack || e); if (exitAfterCleanup) exitAfterCleanup(2); else process.exit(2) })
