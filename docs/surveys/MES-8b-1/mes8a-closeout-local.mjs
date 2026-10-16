// MES-8a close-out item 1.2 b, LOCAL half (never live): the states live has none of — a graded review corrected by another, a not-graded review,
// V23 / V24 set, AP activity and two statements over one period — on a fresh rebuild of HEAD's mirrors seeded with
// docs/surveys/MES-8a/local-seed-clones.sql (the real roles' codes as clones) and docs/surveys/MES-8a/local-seed-data.sql. It talks to next dev
// on :3196 against the harness gateway stub (proxy.mjs serve → local PostgREST); GETs read server-rendered HTML, and two steps drive headless
// Chrome over CDP: the PO form's grade line after choosing the graded supplier, and the statement issue control after a Preview (a read).
// Nothing is submitted. It spawns nothing on live, but it carries the run-directly guard like every script under docs/surveys/.
// Run from the harness directory (it calls proxy.mjs there for the session cookie):
//   H_SECRET=… node mes8a-closeout-local.mjs <graded supplier id> <not-graded supplier id> <current statement id> <period from DD/MM/YYYY> <to>
// Verdict line: LOCAL_PAGES_EXIT=<n> (0 = every fetch 200, no application error, and each CDP step read its control).
import { onlyWhenRunDirectly } from '../../../scripts/lib/entrypoint.mjs'
onlyWhenRunDirectly(import.meta.url)
import { execFileSync, spawn } from 'node:child_process'
import { readFileSync, mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const REPO = process.env.HOME + '/Documents/projects/new-era-erp'
const BASE = process.env.LOCAL_BASE || 'http://localhost:3196'
const [S1, S2, ST, FROM, TO] = process.argv.slice(2)
const U = { admin: '01', cco: '02', finance: '03', warehouse: '04', cfo: '06' }
const PAGES = [
  ['scorecards', '/suppliers/scorecards'],
  ['graded supplier', `/suppliers/${S1}/edit`],
  ['not-graded supplier', `/suppliers/${S2}/edit`],
  ['new PO', '/purchasing/orders/new'],
  ['supplier statements', '/finance/supplier-statements'],
  ['statement', `/finance/supplier-statements/${ST}`],
  ['pending values', '/settings/pending-values'],
]
const CHROME = join(process.env.HOME, readFileSync(REPO + '/scripts/survey-phone.mjs', 'utf8').match(/const CHROME = join\(process\.env\.HOME, '([^']+)'\)/)[1])
const text = (html) => html.replace(/<script[\s\S]*?<\/script>/g, ' ').replace(/<style[\s\S]*?<\/style>/g, ' ').replace(/<[^>]+>/g, ' ')
  .replace(/&#x27;/g, "'").replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/\s+/g, ' ')
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

async function withPage(cookieValue, fn) {
  const port = 9420 + Math.floor(Math.random() * 50)
  const dir = mkdtempSync(join(tmpdir(), 'mes8acol-'))
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
    await S('Network.setCookies', { cookies: [{ name: 'sb-localhost-auth-token', value: cookieValue, domain: 'localhost', path: '/' }] })
    const ev = async (x) => (await S('Runtime.evaluate', { expression: x, returnByValue: true })).result.value
    const go = async (path, sel) => {
      await S('Page.navigate', { url: BASE + path })
      for (let i = 0; i < 120; i++) {
        await sleep(500)
        if (await ev(`(() => { const s = document.querySelector(${JSON.stringify(sel)}); return !!s && Object.keys(s).some((k) => k.startsWith('__react')) })()`)) return true
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

let bad = 0
for (const [role, n] of Object.entries(U)) {
  const cookie = execFileSync('node', ['proxy.mjs', 'cookie', `a0000000-0000-4000-8000-0000000000${n}`, `clone-${role}@test.local`], { env: process.env }).toString().trim()
  for (const [label, path] of PAGES) {
    const res = await fetch(BASE + path, { headers: { cookie: `sb-localhost-auth-token=${cookie}` }, redirect: 'manual' })
    const body = await res.text()
    const tx = text(body)
    const gates = {}
    for (const m of body.matchAll(/data-permission-required="([^"]+)"/g)) gates[m[1]] = (gates[m[1]] || 0) + 1
    const hooks = (attr) => [...new Set([...body.matchAll(new RegExp(`${attr}="([^"]+)"`, 'g'))].map((m) => m[1]))].join(',')
    const m = {
      h1: (body.match(/<h1[^>]*>([\s\S]*?)<\/h1>/) || [])[1]?.replace(/<[^>]+>/g, '').trim() ?? null,
      refused: body.includes('data-access-denied'), gates,
      sections: hooks('data-section'), forms: hooks('data-form'), values: hooks('data-value'), flags: hooks('data-flag'),
      grades: [...new Set((tx.match(/\bGrade [A-C]\b/g) || []))].join(','), notGraded: tx.includes('Not graded'), notCompared: (tx.match(/Not compared/g) || []).length,
      sst: [...new Set(tx.match(/SST-\d{4}-\d{4,}/g) || [])].join(','),
      pendingV23: body.includes('data-pending-value="V23"'), pendingV24: body.includes('data-pending-value="V24"'),
      errorText: /Application error|Internal Server Error|Unhandled Runtime Error|This page couldn.t load/.test(body),
    }
    if (res.status !== 200 || m.errorText) bad++
    console.log(`LOCAL|${role}|${label}|${res.status}|${JSON.stringify(m)}`)
  }
  const g = await withPage(cookie, async (ev, go) => {
    const h = await go('/purchasing/orders/new', 'select[name="supplier_id"]'); if (h !== true) return { hydrated: h }
    const c = await ev(setSelect('select[name="supplier_id"]', S1)); if (!c.listed) return { hydrated: h, ...c }
    let line = null
    for (let i = 0; i < 40 && line === null; i++) { await sleep(500); line = await ev(`document.querySelector('[data-value="supplier-grade"]')?.textContent ?? document.querySelector('[data-error="grade-advice"]')?.textContent ?? null`) }
    return { hydrated: h, ...c, gradeLine: line }
  })
  if (g.hydrated !== true || g.listed === false || !g.gradeLine) bad++
  console.log(`GRADE|${role}|${JSON.stringify(g)}`)
  const s = await withPage(cookie, async (ev, go) => {
    const h = await go('/finance/supplier-statements', '[data-field="supplier_id"]'); if (h !== true) return { hydrated: h }
    const c = await ev(setSelect('[data-field="supplier_id"]', S1)); if (!c.listed) return { hydrated: h, ...c }
    await sleep(300)
    const dates = [await ev(setText('[data-date-text]', 0, FROM)), await ev(setText('[data-date-text]', 1, TO))]
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
    return { hydrated: h, ...c, dates, pressed, ...(out ?? { preview: 'none within 20 s' }) }
  })
  if (s.hydrated === true && (s.listed === false || s.error || !s.issueButton)) bad++
  console.log(`ISSUE|${role}|${JSON.stringify(s)}`)
}
console.log(`LOCAL_PAGES_EXIT=${bad ? 1 : 0}`)
process.exit(bad ? 1 : 0)
