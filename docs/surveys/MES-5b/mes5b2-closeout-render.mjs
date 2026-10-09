// MES-5b-2 close-out item f — render probe on the DEPLOYED app (read-only). Three one-off clones of real roles (cloneOf: exactly that
// role's codes at this moment): admin, finance, warehouse. Each one:
//   · fetches the expense pages, the allocation list and an allocation page (HTTP status, what the HTML carries);
//   · in a real browser (chrome-headless-shell over CDP), opens the expense page, waits for hydration, presses the Reverse trigger with a
//     real mouse event, reads the dialog (subject, body, whether a reason field is there), and DISMISSES it. It never presses the
//     dialog's confirm button — nothing is reversed. The throwaway accounts are removed by the ephemeral plan.
// Live has no electricity allocation (0 rows, measured), so the allocation page can only be asked about with an id that does not
// exist: the gate answers first (requireModule), then notFound.
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
const CDP_PORT = 9341
const CHROME = ['mac_arm-152.0.7977.75', 'mac_arm-152.0.7977.54'].map((v) =>
  join(process.env.HOME, `.cache/puppeteer/chrome-headless-shell/${v}/chrome-headless-shell-mac-arm64/chrome-headless-shell`)).find(existsSync)
const EXP = { ordinary: ['EXP-2026-0003', 'c41c55b7-fcac-445b-ba8d-e74179137fc4'], relief: ['EXP-2026-0005', '86fa2b87-aa48-4df6-bf91-405a91a33c61'] }
const NO_SUCH_ALLOCATION = '00000000-0000-4000-8000-000000000000'
const ROLES = ['admin', 'finance', 'warehouse']
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
    reverseExpense: body.includes('data-control="reverse-expense"'),
    reverseAllocation: body.includes('data-control="reverse-allocation"'),
    gatedEdit: body.includes('data-permission-required="module.finance.edit"'),
    refused: /data-access-denied|restrictedHint|权限不足|PERMISSION_DENIED/.test(body),
    notFound: res.status === 404,
    errorText: /Application error|Internal Server Error/.test(body),
  }
}

async function main() {
  if (!CHROME) throw new Error('chrome-headless-shell not found')
  const other = heldBy(); if (other) { console.error(`live-lock held by ${other.holder}`); return exitAfterCleanup(5) }
  acquireOrExit('mes5b2-closeout-render.mjs', { ownExit: false }); locked = true
  openPlan('docs/surveys/MES-5b/mes5b2-closeout-render.mjs'); await reapStalePlans()

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
    const a = await mintThrowaway({ prefix: 'mes5b2probe', label: `cof-${r}`, stamp, codes: { cloneOf: r } })
    const f = {
      ordinary: await fetchCell(a.cookie, `/finance/expenses/${EXP.ordinary[1]}`),
      relief: await fetchCell(a.cookie, `/finance/expenses/${EXP.relief[1]}`),
      list: await fetchCell(a.cookie, '/finance/electricity'),
      alloc: await fetchCell(a.cookie, `/finance/electricity/${NO_SUCH_ALLOCATION}`),
    }
    console.log(`FETCH|${r}|${a.codes.length} codes|` + Object.entries(f).map(([k, v]) => `${k} ${JSON.stringify(v)}`).join(' || '))

    // ── the browser half: a fresh target per role, the clone's cookie only ──
    const { targetId } = await send('Target.createTarget', { url: 'about:blank' })
    const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true })
    const S = (m, p) => send(m, p, sessionId)
    await S('Page.enable'); await S('Runtime.enable'); await S('Network.enable')
    await S('Network.clearBrowserCookies')
    await S('Emulation.setDeviceMetricsOverride', { width: 1280, height: 900, deviceScaleFactor: 1, mobile: false })
    await S('Network.setCookies', { cookies: [{ name: a.cookieName, value: a.cookieValue, domain: HOST, path: '/', httpOnly: false, secure: true }] })
    const ev = async (expr) => { const x = await S('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true })
      if (x.exceptionDetails) throw new Error(JSON.stringify(x.exceptionDetails).slice(0, 300)); return x.result.value }
    for (const [kind, [code, id]] of Object.entries(EXP)) {
      await S('Page.navigate', { url: `${BASE}/finance/expenses/${id}` })
      let hydrated = false
      for (let i = 0; i < 80 && !hydrated; i++) { await sleep(250)
        hydrated = await ev(`(() => { const b = document.querySelector('button'); return !!b && Object.keys(b).some(k => k.startsWith('__react')) })()`) }
      const before = await ev(`(() => {
        const host = document.querySelector('[data-control="reverse-expense"]'); const btn = host && host.querySelector('button')
        const fs = btn && btn.closest('fieldset')
        return { host: !!host, button: !!btn, disabled: !!btn && (btn.disabled || !!(fs && fs.disabled)),
                 dialogOpen: !!document.querySelector('[data-confirm-dialog="1"]'), title: document.title }
      })()`)
      let dialog = null
      if (before.button && !before.disabled) {
        const box = await ev(`(() => { const el = document.querySelector('[data-control="reverse-expense"] button'); el.scrollIntoView({ block: 'center' })
          const q = el.getBoundingClientRect(); return { x: q.left + q.width / 2, y: q.top + q.height / 2 } })()`)
        for (const type of ['mousePressed', 'mouseReleased']) await S('Input.dispatchMouseEvent', { type, x: box.x, y: box.y, button: 'left', clickCount: 1 })
        for (let i = 0; i < 20 && !dialog?.open; i++) { await sleep(150)
          dialog = await ev(`(() => { const d = document.querySelector('[data-confirm-dialog="1"]'); if (!d) return { open: false }
            return { open: true, subject: d.querySelector('[data-confirm-subject]')?.getAttribute('data-confirm-subject') ?? null,
                     reasonField: !!d.querySelector('[data-confirm-reason="1"]'), text: d.innerText.replace(/\\s+/g, ' ').slice(0, 400) } })()`) }
        // dismiss — never accept
        await ev(`(() => { const x = document.querySelector('[data-confirm-dismiss="1"]'); if (x) x.click(); return !!x })()`)
        await sleep(300)
        dialog.closedAfterDismiss = !(await ev(`!!document.querySelector('[data-confirm-dialog="1"]')`))
      }
      console.log(`BROWSER|${r}|${kind} ${code}|hydrated=${hydrated}|${JSON.stringify(before)}|dialog=${JSON.stringify(dialog)}`)
    }
    await send('Target.closeTarget', { targetId })
  }
  return exitAfterCleanup(0)
}
main().catch((e) => { console.error('✗', e?.stack || e); exitAfterCleanup(2) })
