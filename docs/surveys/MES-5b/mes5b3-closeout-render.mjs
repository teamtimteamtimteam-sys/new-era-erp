// MES-5b-3 close-out item 3 d — render probe on the DEPLOYED app (read-only). Three one-off clones of real roles (cloneOf: exactly that
// role's codes at this moment): warehouse, finance, admin. Each one:
//   · fetches /operation/blending, /operation/blending/new, a plan page with an id that does not exist, and /operation/processing/new
//     (HTTP status, what the HTML carries);
//   · in a real browser (chrome-headless-shell over CDP), waits for hydration and READS: the "New blending plan" control (link or a
//     disabled button inside a PermissionGate), whether the plan form's fieldset is disabled, and every <option> of the run form's
//     operation picker. It presses nothing and submits nothing.
// Live has no blending plan (0 rows, measured in mes5b3-closeout-readings.sql), so a plan page — and with it the release control — can only
// be asked about with an id that does not exist: the gate answers first (requireFunction), then notFound.
// The throwaway accounts are removed by the ephemeral plan (prefix mes5b3probe, already in scripts/ephemeral.mjs).
// Verdict line: RENDER_PROBE_EXIT=<n> (0 = every fetch and every browser step ran; the table says what each role saw).
import { spawn } from 'node:child_process'
import { existsSync } from 'node:fs'
import { join } from 'node:path'
import { createConnection } from 'node:net'
const REPO = new URL('../../..', import.meta.url).pathname.replace(/\/$/, '')
const { openPlan, mintThrowaway, reapStalePlans, installExitHooks, exitAfterCleanup } = await import(REPO + '/scripts/ephemeral.mjs')
const { acquireOrExit, release, heldBy } = await import(REPO + '/scripts/liveLock.mjs')
const BASE = process.env.PROBE_BASE || 'https://new-era-erp.vercel.app'
const HOST = new URL(BASE).hostname
const CDP_PORT = 9342
const CHROME = ['mac_arm-152.0.7977.75', 'mac_arm-152.0.7977.54'].map((v) =>
  join(process.env.HOME, `.cache/puppeteer/chrome-headless-shell/${v}/chrome-headless-shell-mac-arm64/chrome-headless-shell`)).find(existsSync)
const NO_SUCH_PLAN = '00000000-0000-4000-8000-000000000000'
const ROLES = ['warehouse', 'finance', 'admin']
// the seven operations the live reading says the ordinary form offers (positive control) — and the one it must not
const OFFERED = ['battery_powder_line', 'casing_removal', 'deep_discharge', 'electrode_line', 'electrode_powder_line', 'electrode_separation', 'manual_disassembly']
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
let locked = false, chrome = null
installExitHooks({ onFinish: (code) => { try { if (chrome?.pid) process.kill(-chrome.pid) } catch {}; try { if (locked) release() } catch {}; console.log(`RENDER_PROBE_EXIT=${code}`) } })
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
    newPlanLink: body.includes('href="/operation/blending/new"'),
    gatedWoCreate: body.includes('data-permission-required="action.wo_create"'),
    gatedWoRelease: body.includes('data-permission-required="action.wo_release"'),
    releaseControl: body.includes('data-control="blending-plan-actions"'),
    refused: /data-access-denied|restrictedHint|PERMISSION_DENIED/.test(body),
    notFound: res.status === 404,
    errorText: /Application error|Internal Server Error/.test(body),
    optBlending: body.includes('value="blending"'),
    optOffered: OFFERED.filter((c) => body.includes(`value="${c}"`)).length,
  }
}

async function main() {
  if (!CHROME) throw new Error('chrome-headless-shell not found')
  const other = heldBy(); if (other) { console.error(`live-lock held by ${other.holder}`); return exitAfterCleanup(5) }
  acquireOrExit('mes5b3-closeout-render.mjs', { ownExit: false }); locked = true
  openPlan('docs/surveys/MES-5b/mes5b3-closeout-render.mjs'); await reapStalePlans()

  chrome = spawn(CHROME, [`--remote-debugging-port=${CDP_PORT}`, '--headless', '--disable-gpu', '--no-sandbox', '--hide-scrollbars', 'about:blank'],
    { detached: true, stdio: ['ignore', 'pipe', 'pipe'] })
  if (!await waitPort(CDP_PORT, 30000)) throw new Error('chrome CDP did not come up')
  const { webSocketDebuggerUrl } = await (await fetch(`http://127.0.0.1:${CDP_PORT}/json/version`)).json()
  const sock = new WebSocket(webSocketDebuggerUrl)
  await new Promise((res, rej) => { sock.onopen = res; sock.onerror = rej })
  let msgId = 0; const pending = new Map()
  sock.onmessage = (m) => { const d = JSON.parse(m.data)
    if (d.id && pending.has(d.id)) { const { res, rej } = pending.get(d.id); pending.delete(d.id); if (d.error) rej(new Error(JSON.stringify(d.error))); else res(d.result) } }
  const send = (method, params = {}, sessionId) => new Promise((res, rej) => { const id = ++msgId; pending.set(id, { res, rej }); sock.send(JSON.stringify({ id, method, params, sessionId })) })

  const stamp = Date.now()
  for (const r of ROLES) {
    const a = await mintThrowaway({ prefix: 'mes5b3probe', label: `cof-${r}`, stamp, codes: { cloneOf: r } })
    const f = {
      list: await fetchCell(a.cookie, '/operation/blending'),
      newPlan: await fetchCell(a.cookie, '/operation/blending/new'),
      plan: await fetchCell(a.cookie, `/operation/blending/${NO_SUCH_PLAN}`),
      runForm: await fetchCell(a.cookie, '/operation/processing/new'),
    }
    console.log(`FETCH|${r}|${a.codes.length} codes|` + Object.entries(f).map(([k, v]) => `${k} ${JSON.stringify(v)}`).join(' || '))

    // ── the browser half: a fresh target per role, the clone's cookie only; reads only ──
    const { targetId } = await send('Target.createTarget', { url: 'about:blank' })
    const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true })
    const S = (m, p) => send(m, p, sessionId)
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
    let h = await open('/operation/blending')
    const list = await ev(`(() => {
      const link = [...document.querySelectorAll('a[href="/operation/blending/new"]')].filter(x => x.offsetParent !== null)
      const gate = document.querySelector('[data-permission-required="action.wo_create"]')
      const gbtn = gate && gate.querySelector('button')
      return { newPlanLinkVisible: link.length, gatedButton: !!gbtn, gatedButtonDisabled: !!gbtn && (gbtn.disabled || !!gbtn.closest('fieldset')?.disabled),
               gateText: gate ? gate.innerText.replace(/\\s+/g, ' ').slice(0, 200) : null, h1: document.querySelector('h1')?.innerText ?? null }
    })()`)
    console.log(`BROWSER|${r}|/operation/blending|hydrated=${h}|${JSON.stringify(list)}`)
    h = await open('/operation/blending/new')
    const form = await ev(`(() => {
      const gate = document.querySelector('[data-permission-required="action.wo_create"]')
      const fs = gate && gate.querySelector('fieldset')
      const submit = document.querySelector('form button[type="submit"], form button:not([type])')
      return { h1: document.querySelector('h1')?.innerText ?? null, gatePresent: !!gate, fieldsetDisabled: !!fs && fs.disabled,
               submitDisabled: !!submit && (submit.disabled || !!submit.closest('fieldset')?.disabled),
               gateText: gate ? (gate.innerText.match(/[^\\n]*(permission|权限)[^\\n]*/i)?.[0] ?? '').slice(0, 200) : null }
    })()`)
    console.log(`BROWSER|${r}|/operation/blending/new|hydrated=${h}|${JSON.stringify(form)}`)
    h = await open('/operation/processing/new')
    const ops = await ev(`(() => {
      const sel = [...document.querySelectorAll('select')].find(s => [...s.options].some(o => o.value === 'manual_disassembly'))
      return sel ? { found: true, options: [...sel.options].map(o => o.value).filter(Boolean) } : { found: false, h1: document.querySelector('h1')?.innerText ?? null }
    })()`)
    console.log(`BROWSER|${r}|/operation/processing/new|hydrated=${h}|${JSON.stringify(ops)}|blending offered=${!!ops.options?.includes('blending')}`)
    await send('Target.closeTarget', { targetId })
  }
  return exitAfterCleanup(0)
}
main().catch((e) => { console.error('✗', e?.stack || e); exitAfterCleanup(2) })
