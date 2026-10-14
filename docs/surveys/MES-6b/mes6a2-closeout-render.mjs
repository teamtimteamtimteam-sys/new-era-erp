// MES-6a-2 close-out item 2 c — render probe on the DEPLOYED app (read-only). Three one-off clones of real roles (cloneOf: exactly that
// role's codes at this moment): finance, cco, admin. Each one:
//   · fetches the inbound and the output assay form, the metal-price list and its "new" form, and the contracts list (HTTP status);
//   · in a real browser (chrome-headless-shell over CDP), waits for hydration and READS: on both assay forms, the metal table's header and
//     every row's text (name + code), whether F and Cl are rows, whether "ppm" appears anywhere in the table — first as the page opens, then
//     after a value is put into the F row's box through the input's value setter (no key is pressed, no button is pressed) — and the
//     indicator fieldset's labels; on both metal-price pages, every <select>'s options (is F or Cl offered?).
// ★ Nothing can be submitted: every non-GET request the page makes is failed in the browser (CDP Fetch, BlockedByClient) and counted. Putting
//   a value into the F box starts the form's debounced price PREVIEW (a server action, i.e. a POST) — that request is failed like any other
//   and counted separately as "preview" (it is a read on the server side, but it is not let through either).
// ★ Live has 0 contracts (mes6a2-closeout-readings.sql, W| line), so /contracts/[id] — where the penalty-element picker lives — cannot be
//   rendered on live without creating a contract, which this block forbids. The probe fetches /contracts only to show the list is empty.
// The throwaway accounts are removed by the ephemeral plan (prefix mes6a2probe, already in scripts/ephemeral.mjs).
// Verdict line: RENDER_PROBE_EXIT=<n> (0 = every fetch and browser step ran and nothing but preview calls was attempted).
import { onlyWhenRunDirectly } from '../../../scripts/lib/entrypoint.mjs'
import { spawn } from 'node:child_process'
import { existsSync } from 'node:fs'
import { join } from 'node:path'
import { createConnection } from 'node:net'
// ★ It acts on live, so it runs only when executed directly — importing this file starts nothing.
onlyWhenRunDirectly(import.meta.url)

const REPO = new URL('../../..', import.meta.url).pathname.replace(/\/$/, '')
let openPlan, mintThrowaway, reapStalePlans, installExitHooks, exitAfterCleanup, acquireOrExit, release, heldBy
const BASE = process.env.PROBE_BASE || 'https://new-era-erp.vercel.app'
const HOST = new URL(BASE).hostname
const CDP_PORT = 9344
const CHROME = ['mac_arm-152.0.7977.75', 'mac_arm-152.0.7977.54'].map((v) =>
  join(process.env.HOME, `.cache/puppeteer/chrome-headless-shell/${v}/chrome-headless-shell-mac-arm64/chrome-headless-shell`)).find(existsSync)
// read in mes6a2-closeout-readings.sql (D| lines): the newest live inbound and output batch
const IN_ID = '2d8670e8-2c4c-48b4-bae3-53ed9030eaad'    // ZZ-PROCCOST1-DEMO
const OUT_ID = 'b9edf2ac-c1af-4837-afaa-afbbfbed0344'   // OUT-2026-0381
const ROLES = ['finance', 'cco', 'admin']
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
let locked = false, chrome = null
const waitPort = (p, ms) => new Promise((res) => {
  const t0 = Date.now()
  function tick() {
    const s = createConnection({ port: p, host: '127.0.0.1' })
    s.on('connect', () => { s.destroy(); res(true) })
    s.on('error', () => { s.destroy(); if (Date.now() - t0 > ms) res(false); else setTimeout(tick, 300) })
  }
  tick()
})

async function fetchCell(cookie, path) {
  const res = await fetch(BASE + path, { headers: { cookie }, redirect: 'manual' })
  const body = await res.text()
  return {
    status: res.status,
    hasFluorine: /Fluorine/.test(body), hasChlorine: /Chlorine/.test(body),
    hasPpm: /ppm/.test(body),
    indicatorPanel: body.includes('data-panel="indicator-fields"'),
    refused: /data-access-denied|restrictedHint|PERMISSION_DENIED/.test(body),
    errorText: /Application error|Internal Server Error/.test(body),
  }
}

async function main() {
  ;({ openPlan, mintThrowaway, reapStalePlans, installExitHooks, exitAfterCleanup } = await import(REPO + '/scripts/ephemeral.mjs'))
  ;({ acquireOrExit, release, heldBy } = await import(REPO + '/scripts/liveLock.mjs'))
  installExitHooks({ onFinish: (code) => { try { if (chrome?.pid) process.kill(-chrome.pid) } catch {}; try { if (locked) release() } catch {}; console.log(`RENDER_PROBE_EXIT=${code}`) } })
  if (!CHROME) throw new Error('chrome-headless-shell not found')
  const other = heldBy(); if (other) { console.error(`live-lock held by ${other.holder}`); return exitAfterCleanup(5) }
  acquireOrExit('mes6a2-closeout-render.mjs', { ownExit: false }); locked = true
  openPlan('docs/surveys/MES-6b/mes6a2-closeout-render.mjs'); await reapStalePlans()

  chrome = spawn(CHROME, [`--remote-debugging-port=${CDP_PORT}`, '--headless', '--disable-gpu', '--no-sandbox', '--hide-scrollbars', 'about:blank'],
    { detached: true, stdio: ['ignore', 'pipe', 'pipe'] })
  if (!await waitPort(CDP_PORT, 30000)) throw new Error('chrome CDP did not come up')
  const { webSocketDebuggerUrl } = await (await fetch(`http://127.0.0.1:${CDP_PORT}/json/version`)).json()
  const sock = new WebSocket(webSocketDebuggerUrl)
  await new Promise((res, rej) => { sock.onopen = res; sock.onerror = rej })
  let msgId = 0; const pending = new Map(); const handlers = []
  sock.onmessage = (m) => { const d = JSON.parse(m.data)
    if (d.id && pending.has(d.id)) { const { res, rej } = pending.get(d.id); pending.delete(d.id); if (d.error) rej(new Error(JSON.stringify(d.error))); else res(d.result) }
    else if (d.method) for (const h of handlers) h(d) }
  const send = (method, params = {}, sessionId) => new Promise((res, rej) => { const id = ++msgId; pending.set(id, { res, rej }); sock.send(JSON.stringify({ id, method, params, sessionId })) })

  const stamp = Date.now()
  let unexpectedTotal = 0
  for (const r of ROLES) {
    const a = await mintThrowaway({ prefix: 'mes6a2probe', label: `cof-${r}`, stamp, codes: { cloneOf: r } })
    const f = {
      inboundAssayForm: await fetchCell(a.cookie, `/inbound/${IN_ID}/assays/new`),
      outputAssayForm: await fetchCell(a.cookie, `/output/${OUT_ID}/assays/new`),
      metalPrices: await fetchCell(a.cookie, '/tools/pricing/metal-prices'),
      metalPriceNew: await fetchCell(a.cookie, '/tools/pricing/metal-prices/new'),
      contracts: await fetchCell(a.cookie, '/contracts'),
    }
    console.log(`FETCH|${r}|${a.codes.length} codes|` + Object.entries(f).map(([k, v]) => `${k} ${JSON.stringify(v)}`).join(' || '))

    // ── the browser half: a fresh target per role, the clone's cookie only; reads only; every non-GET request failed ──
    const { targetId } = await send('Target.createTarget', { url: 'about:blank' })
    const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true })
    const S = (m, p) => send(m, p, sessionId)
    let blocked = [], phase = 'open'
    const onPaused = (d) => {
      if (d.method !== 'Fetch.requestPaused' || d.sessionId !== sessionId) return
      const m = d.params.request.method
      if (m === 'GET' || m === 'HEAD') S('Fetch.continueRequest', { requestId: d.params.requestId }).catch(() => {})
      else { blocked.push(phase); console.log(`BLOCKED|${r}|${phase}|${m} ${d.params.request.url}`); S('Fetch.failRequest', { requestId: d.params.requestId, errorReason: 'BlockedByClient' }).catch(() => {}) }
    }
    handlers.push(onPaused)
    await S('Fetch.enable', { patterns: [{ urlPattern: '*', requestStage: 'Request' }] })
    await S('Page.enable'); await S('Runtime.enable'); await S('Network.enable')
    await S('Network.clearBrowserCookies')
    await S('Emulation.setDeviceMetricsOverride', { width: 1280, height: 900, deviceScaleFactor: 1, mobile: false })
    await S('Network.setCookies', { cookies: [{ name: a.cookieName, value: a.cookieValue, domain: HOST, path: '/', httpOnly: false, secure: true }] })
    const ev = async (expr) => { const x = await S('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true })
      if (x.exceptionDetails) throw new Error(JSON.stringify(x.exceptionDetails).slice(0, 300)); return x.result.value }
    const open = async (path) => {
      phase = 'open'
      await S('Page.navigate', { url: BASE + path })
      let hydrated = false
      for (let i = 0; i < 80 && !hydrated; i++) { await sleep(250)
        hydrated = await ev(`(() => { const b = document.querySelector('button, select, a'); return !!b && Object.keys(b).some(k => k.startsWith('__react')) })()`) }
      await sleep(500)
      return hydrated
    }
    // the metal table of an assay form: header, rows, F / Cl rows, any "ppm"; the indicator fieldset
    const readForm = `(() => {
      const tables = [...document.querySelectorAll('table')]
      const t = tables.find(x => /Nickel|镍/.test(x.textContent)) || null; const tableCount = tables.length
      const header = t ? [...t.querySelectorAll('thead th')].map(h => h.innerText.trim()).filter(Boolean) : []
      const rows = t ? [...t.querySelectorAll('tbody tr')].map(tr => tr.textContent.replace(/\\s+/g, ' ').trim()) : []
      const fRow = rows.find(x => /Fluorine|氟/.test(x)) ?? null
      const clRow = rows.find(x => /Chlorine|氯/.test(x)) ?? null
      const fs = document.querySelector('[data-panel="indicator-fields"]')
      return { h1: document.querySelector('h1')?.innerText ?? null, refused: !!document.querySelector('[data-access-denied]'), tableCount,
               metalHeader: header, metalRows: rows, fRow, clRow,
               ppmInTable: t ? /ppm/.test(t.textContent) : null, ppmOnPage: /ppm/.test(document.querySelector('main')?.innerText ?? ''),
               indicatorLegend: fs?.querySelector('legend')?.innerText ?? null,
               indicatorLabels: fs ? [...fs.querySelectorAll('label span')].map(s => s.innerText) : [],
               indicatorInputs: fs ? [...fs.querySelectorAll('input')].map(i => i.name + ' min=' + i.min + ' max=' + (i.max || '—')) : [] }
    })()`
    // put a value into the F row's box (value setter + input event; no key, no button) and read the row and the table again
    const typeF = `(() => {
      const t = [...document.querySelectorAll('table')].find(x => /Nickel|镍/.test(x.textContent)); if (!t) return { typed: false, why: 'no metal table', tables: document.querySelectorAll('table').length }
      const tr = [...t.querySelectorAll('tbody tr')].find(x => /Fluorine|氟/.test(x.textContent)); if (!tr) return { typed: false, why: 'no F row' }
      const inp = tr.querySelector('input'); if (!inp) return { typed: false, why: 'no input in the F row' }
      Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(inp, '0.0123')
      inp.dispatchEvent(new Event('input', { bubbles: true })); inp.dispatchEvent(new Event('change', { bubbles: true }))
      return { typed: true }
    })()`
    const readAfter = `(() => {
      const t = [...document.querySelectorAll('table')].find(x => /Nickel|镍/.test(x.textContent))
      const tr = t && [...t.querySelectorAll('tbody tr')].find(x => /Fluorine|氟/.test(x.textContent))
      return { fRowText: tr ? tr.textContent.replace(/\\s+/g, ' ').trim() : null, fInputValue: tr?.querySelector('input')?.value ?? null,
               ppmInTable: t ? /ppm/.test(t.textContent) : null, ppmOnPage: /ppm/.test(document.querySelector('main')?.innerText ?? '') }
    })()`
    for (const [label, path] of [['inbound', `/inbound/${IN_ID}/assays/new`], ['output', `/output/${OUT_ID}/assays/new`]]) {
      const h = await open(path)
      const before = await ev(readForm)
      phase = 'preview'
      const typed = await ev(typeF)
      await sleep(2500)
      const after = typed.typed ? await ev(readAfter) : null
      console.log(`BROWSER|${r}|${label} assay form|hydrated=${h}|${JSON.stringify(before)}|typedF=${JSON.stringify(typed)}|after=${JSON.stringify(after)}`)
    }
    const readSelects = `(() => ({ h1: document.querySelector('h1')?.innerText ?? null, refused: !!document.querySelector('[data-access-denied]'),
      selects: [...document.querySelectorAll('select')].map(s => ({ name: s.name || null,
        options: [...s.options].map(o => o.value + '=' + o.text.trim()) })),
      fluorineOrChlorineAnywhere: /Fluorine|Chlorine|氟|氯/.test(document.querySelector('main')?.innerText ?? '') }))()`
    for (const path of ['/tools/pricing/metal-prices', '/tools/pricing/metal-prices/new']) {
      const h = await open(path)
      console.log(`BROWSER|${r}|${path}|hydrated=${h}|${JSON.stringify(await ev(readSelects))}`)
    }
    const unexpected = blocked.filter((p) => p !== 'preview').length
    console.log(`BLOCKED_COUNT|${r}|preview=${blocked.length - unexpected}|other=${unexpected}`)
    unexpectedTotal += unexpected
    handlers.splice(handlers.indexOf(onPaused), 1)
    await send('Target.closeTarget', { targetId })
  }
  console.log(`BLOCKED_UNEXPECTED_TOTAL|${unexpectedTotal}`)
  return exitAfterCleanup(unexpectedTotal === 0 ? 0 : 6)
}
main().catch((e) => { console.error('✗', e?.stack || e); if (exitAfterCleanup) exitAfterCleanup(2); else process.exit(2) })
