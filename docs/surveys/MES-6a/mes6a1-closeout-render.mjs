// MES-6a-1 close-out item 2 d — render probe on the DEPLOYED app (read-only). Four one-off clones of real roles (cloneOf: exactly that
// role's codes at this moment): warehouse, finance, cco, admin. Each one:
//   · fetches /quality/samples, /quality/disputes, /quality/samples/new (step one, and step two for one inbound batch) and one posted
//     expense page (HTTP status, what the HTML carries);
//   · in a real browser (chrome-headless-shell over CDP), waits for hydration and READS: the "new sample" / "open a dispute" control (a
//     link, or a disabled button inside a PermissionGate naming its code), whether the sample form's fieldset is disabled, and on the
//     expense page the Reverse control. Where it is pressable, it opens the dialog and reads the reason box and the confirm button with
//     the box blank, with spaces only, and with text (set through the input's value setter — no key is pressed, so Enter can never
//     confirm), then presses Cancel and checks the dialog closed.
// ★ Nothing can be submitted: every non-GET request the page makes is failed in the browser (CDP Fetch, BlockedByClient) and counted —
//   the count must stay 0, because the probe presses no confirm button. The expense, batch and dialog are only looked at.
// The throwaway accounts are removed by the ephemeral plan (prefix mes6a1probe, already in scripts/ephemeral.mjs).
// Verdict line: RENDER_PROBE_EXIT=<n> (0 = every fetch and every browser step ran; the table says what each role saw).
import { onlyWhenRunDirectly } from '../../../scripts/lib/entrypoint.mjs'
import { spawn } from 'node:child_process'
import { existsSync } from 'node:fs'
import { join } from 'node:path'
import { createConnection } from 'node:net'
// ★ It acts on live, so it runs only when executed directly — importing this file starts nothing (MES-6a-2 fold-in).
onlyWhenRunDirectly(import.meta.url)

const REPO = new URL('../../..', import.meta.url).pathname.replace(/\/$/, '')
let openPlan, mintThrowaway, reapStalePlans, installExitHooks, exitAfterCleanup, acquireOrExit, release, heldBy
const BASE = process.env.PROBE_BASE || 'https://new-era-erp.vercel.app'
const HOST = new URL(BASE).hostname
const CDP_PORT = 9343
const CHROME = ['mac_arm-152.0.7977.75', 'mac_arm-152.0.7977.54'].map((v) =>
  join(process.env.HOME, `.cache/puppeteer/chrome-headless-shell/${v}/chrome-headless-shell-mac-arm64/chrome-headless-shell`)).find(existsSync)
// read in mes6a1-closeout-readings.sql (D| lines): the newest posted expense and the newest inbound batch
const EXPENSE_ID = '57859da4-f8b7-478c-a078-22daeed7f8f1'   // EXP-2026-0010, posted
const BATCH_ID = '2d8670e8-2c4c-48b4-bae3-53ed9030eaad'
const ROLES = ['warehouse', 'finance', 'cco', 'admin']
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
    gatedQualityEdit: body.includes('data-permission-required="module.quality.edit"'),
    gatedFinanceEdit: body.includes('data-permission-required="module.finance.edit"'),
    newSampleLink: body.includes('href="/quality/samples/new"'),
    newDisputeLink: body.includes('href="/quality/disputes/new"'),
    reverseControl: body.includes('data-control="reverse-expense"'),
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
  acquireOrExit('mes6a1-closeout-render.mjs', { ownExit: false }); locked = true
  openPlan('docs/surveys/MES-6a/mes6a1-closeout-render.mjs'); await reapStalePlans()

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
  let blockedTotal = 0
  for (const r of ROLES) {
    const a = await mintThrowaway({ prefix: 'mes6a1probe', label: `cof-${r}`, stamp, codes: { cloneOf: r } })
    const f = {
      samples: await fetchCell(a.cookie, '/quality/samples'),
      disputes: await fetchCell(a.cookie, '/quality/disputes'),
      newSample: await fetchCell(a.cookie, '/quality/samples/new'),
      newSampleBatch: await fetchCell(a.cookie, `/quality/samples/new?batch=inbound:${BATCH_ID}`),
      expense: await fetchCell(a.cookie, `/finance/expenses/${EXPENSE_ID}`),
    }
    console.log(`FETCH|${r}|${a.codes.length} codes|` + Object.entries(f).map(([k, v]) => `${k} ${JSON.stringify(v)}`).join(' || '))

    // ── the browser half: a fresh target per role, the clone's cookie only; reads only; every non-GET request failed ──
    const { targetId } = await send('Target.createTarget', { url: 'about:blank' })
    const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true })
    const S = (m, p) => send(m, p, sessionId)
    let blocked = 0
    const onPaused = (d) => {
      if (d.method !== 'Fetch.requestPaused' || d.sessionId !== sessionId) return
      const m = d.params.request.method
      if (m === 'GET' || m === 'HEAD') S('Fetch.continueRequest', { requestId: d.params.requestId }).catch(() => {})
      else { blocked++; console.log(`BLOCKED|${r}|${m} ${d.params.request.url}`); S('Fetch.failRequest', { requestId: d.params.requestId, errorReason: 'BlockedByClient' }).catch(() => {}) }
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
      await S('Page.navigate', { url: BASE + path })
      let hydrated = false
      for (let i = 0; i < 80 && !hydrated; i++) { await sleep(250)
        hydrated = await ev(`(() => { const b = document.querySelector('button, select, a'); return !!b && Object.keys(b).some(k => k.startsWith('__react')) })()`) }
      return hydrated
    }
    const listRead = (href) => `(() => {
      const link = [...document.querySelectorAll('a[href="${href}"]')].filter(x => x.offsetParent !== null)
      const gate = document.querySelector('[data-permission-required="module.quality.edit"]')
      const gbtn = gate && gate.querySelector('button')
      return { h1: document.querySelector('h1')?.innerText ?? null, addLinkVisible: link.length, gatedButton: !!gbtn,
               gatedButtonDisabled: !!gbtn && (gbtn.disabled || !!gbtn.closest('fieldset')?.disabled),
               gateText: gate ? gate.innerText.replace(/\\s+/g, ' ').slice(0, 160) : null,
               restricted: !!document.querySelector('[data-access-denied]') || /Restricted|受限/.test(document.querySelector('main')?.innerText?.slice(0, 400) ?? '') }
    })()`
    let h = await open('/quality/samples')
    console.log(`BROWSER|${r}|/quality/samples|hydrated=${h}|${JSON.stringify(await ev(listRead('/quality/samples/new')))}`)
    h = await open('/quality/disputes')
    console.log(`BROWSER|${r}|/quality/disputes|hydrated=${h}|${JSON.stringify(await ev(listRead('/quality/disputes/new')))}`)
    h = await open(`/quality/samples/new?batch=inbound:${BATCH_ID}`)
    const form = await ev(`(() => {
      const gate = document.querySelector('[data-permission-required="module.quality.edit"]')
      const fs = gate && gate.querySelector('fieldset')
      const submit = document.querySelector('form button[type="submit"]')
      return { h1: document.querySelector('h1')?.innerText ?? null, gatePresent: !!gate, fieldsetDisabled: !!fs && fs.disabled,
               submitDisabled: !!submit && (submit.disabled || !!submit.closest('fieldset')?.disabled),
               gateText: gate ? (gate.innerText.match(/[^\\n]*(permission|权限|Needs)[^\\n]*/i)?.[0] ?? '').slice(0, 160) : null,
               refused: !!document.querySelector('[data-access-denied]') }
    })()`)
    console.log(`BROWSER|${r}|/quality/samples/new?batch=…|hydrated=${h}|${JSON.stringify(form)}`)

    h = await open(`/finance/expenses/${EXPENSE_ID}`)
    const exp = await ev(`(() => {
      const ctl = document.querySelector('[data-control="reverse-expense"]')
      const gate = ctl && ctl.querySelector('[data-permission-required="module.finance.edit"]')
      const btn = ctl && ctl.querySelector('button')
      return { h1: document.querySelector('h1')?.innerText ?? null, refused: !!document.querySelector('[data-access-denied]'),
               reverseControl: !!ctl, gate: !!gate, pressable: !!btn && !btn.disabled && !btn.closest('fieldset')?.disabled,
               gateText: gate ? gate.innerText.replace(/\\s+/g, ' ').slice(0, 160) : null,
               blocked: ctl?.querySelector('[data-reverse-blocked]')?.innerText ?? null }
    })()`)
    let dialog = null
    if (exp.pressable) {
      await ev(`document.querySelector('[data-control="reverse-expense"] button').click()`)
      for (let i = 0; i < 40; i++) { await sleep(100); if (await ev(`!!document.querySelector('[data-confirm-dialog]')`)) break }
      const readDlg = `(() => {
        const d = document.querySelector('[data-confirm-dialog]'); if (!d) return null
        const inp = d.querySelector('[data-confirm-reason]'); const acc = d.querySelector('[data-confirm-accept]')
        return { open: true, subject: d.querySelector('[data-confirm-subject]')?.innerText ?? null,
                 reasonBox: !!inp, reasonLabel: inp?.closest('label')?.querySelector('span')?.innerText ?? null,
                 body: d.querySelector('p:not([data-confirm-subject])')?.innerText?.slice(0, 200) ?? null,
                 acceptDisabled: !!acc && acc.disabled, acceptLabel: acc?.innerText ?? null }
      })()`
      const setReason = (v) => ev(`(() => { const inp = document.querySelector('[data-confirm-dialog] [data-confirm-reason]'); if (!inp) return false
        Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(inp, ${JSON.stringify(v)})
        inp.dispatchEvent(new Event('input', { bubbles: true })); return true })()`)
      const blank = await ev(readDlg)
      await setReason('   '); await sleep(150); const spaces = await ev(readDlg)
      await setReason('probe text — not submitted'); await sleep(150); const typed = await ev(readDlg)
      await setReason(''); await sleep(100)
      await ev(`document.querySelector('[data-confirm-dialog] [data-confirm-dismiss]').click()`)
      await sleep(300)
      const closed = !(await ev(`!!document.querySelector('[data-confirm-dialog]')`))
      dialog = { blank, spacesAcceptDisabled: spaces?.acceptDisabled, typedAcceptDisabled: typed?.acceptDisabled, closedByCancel: closed }
    }
    console.log(`BROWSER|${r}|/finance/expenses/[id]|hydrated=${h}|${JSON.stringify(exp)}|dialog=${JSON.stringify(dialog)}`)
    console.log(`BLOCKED_COUNT|${r}|${blocked}`)
    blockedTotal += blocked
    handlers.splice(handlers.indexOf(onPaused), 1)
    await send('Target.closeTarget', { targetId })
  }
  console.log(`BLOCKED_TOTAL|${blockedTotal}`)
  return exitAfterCleanup(blockedTotal === 0 ? 0 : 6)
}
main().catch((e) => { console.error('✗', e?.stack || e); if (exitAfterCleanup) exitAfterCleanup(2); else process.exit(2) })
