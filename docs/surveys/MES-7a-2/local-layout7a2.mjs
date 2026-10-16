// Copied into the repo as the record of the MES-7a-2 local layout run (hand-back §3 row 11). It talks to a LOCAL harness only (next dev on :3196
// against a stub gateway and PostgREST over a rebuild of this cut's mirrors seeded with docs/surveys/MES-7a-2/local-seed.sql), but it spawns a
// browser on import, so it carries the same run-directly guard as the live scripts (scripts/check-import-inert.mjs scans docs/surveys/).
// Run it from the harness directory (it reads proxy.mjs from its own folder): node local-layout7a2.mjs <width> <role> <path>...
import { onlyWhenRunDirectly } from '../../../scripts/lib/entrypoint.mjs'
onlyWhenRunDirectly(import.meta.url)
// LOCAL harness (never live): MES-7a-2 layout on states live has none of — spare-part batches (priced, unpriced, on hold), issues and a return on a
// maintenance record, a reprice that sent the issued share to 6800, V21 listed. Same MEASURE string as scripts/survey-phone.mjs (read from that file, not copied), same chrome, own port.
// Usage: node local-layout.mjs <width> <role> <path>...   (next dev on :3196 against the harness proxy must already be up)
import { execFileSync, spawn } from 'node:child_process'
import fs from 'node:fs'
const REPO = process.env.HOME + '/Documents/projects/new-era-erp'
const H = new URL('.', import.meta.url).pathname
const src = fs.readFileSync(REPO + '/scripts/survey-phone.mjs', 'utf8')
const MEASURE = src.slice(src.indexOf('const MEASURE = `') + 'const MEASURE = `'.length, src.indexOf('})()`', src.indexOf('const MEASURE = `')) + 4)
const CHROME = src.match(/const CHROME = join\(process\.env\.HOME, '([^']+)'\)/)[1]
const [W, ROLE, ...PATHS] = process.argv.slice(2)
const WIDTH = Number(W), HEIGHT = 900, CDP = 9354, BASE = 'http://localhost:3196'
const U = { admin: '01', cco: '02', warehouse: '04', cfo: '06' }
const cookieVal = execFileSync('node', ['proxy.mjs', 'cookie', `a0000000-0000-4000-8000-0000000000${U[ROLE]}`, `clone-${ROLE}@test.local`], { cwd: H, env: { ...process.env, H_SECRET: 'harness-local-secret-0123456789-abcdefghij' } }).toString().trim()
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const chrome = spawn(process.env.HOME + '/' + CHROME, [`--remote-debugging-port=${CDP}`, '--headless', '--disable-gpu', '--no-sandbox', '--hide-scrollbars',
    `--window-size=${WIDTH},${HEIGHT}`, `--user-data-dir=${H}chrome-7a2-${WIDTH}`, 'about:blank'], { stdio: 'ignore' })
let bad = 0
try {
    let ws = null
    for (let i = 0; i < 60 && !ws; i++) { await sleep(500); try { ws = (await (await fetch(`http://127.0.0.1:${CDP}/json/version`)).json()).webSocketDebuggerUrl } catch {} }
    const sock = new WebSocket(ws); await new Promise((r, j) => { sock.onopen = r; sock.onerror = j })
    let id = 0; const wait = new Map(); let lastDoc = null
    sock.onmessage = (e) => { const m = JSON.parse(e.data); if (m.id && wait.has(m.id)) { const w = wait.get(m.id); wait.delete(m.id); if (m.error) w.j(new Error(JSON.stringify(m.error))); else w.r(m.result) }
        else if (m.method === 'Network.responseReceived' && m.params?.type === 'Document') lastDoc = m.params.response.status }
    let sid = null
    const S = (method, params = {}) => new Promise((r, j) => { const i = ++id; wait.set(i, { r, j }); sock.send(JSON.stringify({ id: i, method, params, ...(sid ? { sessionId: sid } : {}) })) })
    const t = await S('Target.createTarget', { url: 'about:blank' }); sid = (await S('Target.attachToTarget', { targetId: t.targetId, flatten: true })).sessionId
    await S('Page.enable'); await S('Runtime.enable'); await S('Network.enable')
    await S('Emulation.setDeviceMetricsOverride', { width: WIDTH, height: HEIGHT, deviceScaleFactor: WIDTH < 768 ? 3 : 1, mobile: WIDTH < 768, screenWidth: WIDTH, screenHeight: HEIGHT })
    await S('Network.setCookies', { cookies: [{ name: 'sb-localhost-auth-token', value: cookieVal, domain: 'localhost', path: '/' }] })
    const ev = async (x) => (await S('Runtime.evaluate', { expression: x, returnByValue: true })).result.value
    const go = async (p) => { lastDoc = null; await S('Page.navigate', { url: BASE + p }); for (let i = 0; i < 120; i++) { await sleep(500); if (await ev('document.readyState') === 'complete' && lastDoc) break } await sleep(1500) }
    // self-test: the same measurement must SEE an injected overflow on a real page
    await go(PATHS[0])
    const b0 = await ev(MEASURE)
    await ev(`(() => { const d = document.createElement('div'); d.style.cssText = 'width:${WIDTH + 400}px;height:4px'; document.body.appendChild(d) })()`)
    const b1 = await ev(MEASURE)
    if (!(b1.overflowPx > 300) || b0.vw !== WIDTH) { console.log(`SELFTEST|FAILED|base ${b0.overflowPx} vw ${b0.vw} injected ${b1.overflowPx}`); process.exitCode = 2 }
    else console.log(`SELFTEST|bit|injected overflow read +${b1.overflowPx}px`)
    for (const p of PATHS) {
        await go(p)
        const m = await ev(MEASURE)
        const extra = await ev(`(() => ({ h1: document.querySelector('h1')?.textContent?.trim() ?? null,
            err: /Application error|Internal Server Error|Unhandled Runtime Error/.test(document.body.innerText),
            parts: !!document.querySelector('[data-section="spare-parts"]'),
            partRows: document.querySelectorAll('[data-section="spare-parts"] tbody tr').length,
            issueGate: [...document.querySelectorAll('[data-section="spare-parts"] [data-permission-required]')].map((e) => e.getAttribute('data-permission-required')).join(','),
            valueCol: /Still out, at landed cost/.test(document.body.innerText),
            maintCol: /Issued to maintenance \(net of returns\)/.test(document.body.innerText),
            v21: /Minimum stock of a spare part/.test(document.body.innerText),
            mix: /Issued to maintenance/.test(document.body.innerText) }))()`)
        if (lastDoc >= 400 || extra.err || m.overflowPx > 1 || m.clippedTables > 0) bad++
        console.log(`PAGE|${WIDTH}|${ROLE}|${lastDoc}|ovf=${m.overflowPx}|clip=${m.clippedTables}|tables=${m.tableCount}|${p}|${JSON.stringify({ ...extra, culprits: m.culprits })}`)
    }
} finally { chrome.kill('SIGKILL') }
console.log(`LOCAL_LAYOUT_EXIT=${bad ? 1 : (process.exitCode ?? 0)}`)
process.exit(bad ? 1 : (process.exitCode ?? 0))
