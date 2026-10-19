// LOCAL harness (never live): MES-8b-2 layout (/display at wall / desktop / phone widths, price exposure with kind-not-stated stock, month-end). Copied from local-layout8b1.mjs.
// values, a byte-less issued CoA (Save PDF). Same MEASURE string as scripts/survey-phone.mjs (read from that file, not copied), same chrome, own port.
// Usage: node local-layout.mjs <width> <role> <path>...   (next dev on :3196 against the harness proxy must already be up)
import { execFileSync, spawn } from 'node:child_process'
import fs from 'node:fs'
const REPO = process.env.HOME + '/Documents/projects/new-era-erp'
const H = new URL('.', import.meta.url).pathname
const src = fs.readFileSync(REPO + '/scripts/survey-phone.mjs', 'utf8')
const MEASURE = src.slice(src.indexOf('const MEASURE = `') + 'const MEASURE = `'.length, src.indexOf('})()`', src.indexOf('const MEASURE = `')) + 4)
const CHROME = src.match(/const CHROME = join\(process\.env\.HOME, '([^']+)'\)/)[1]
const [W, ROLE, ...PATHS] = process.argv.slice(2)
const WIDTH = Number(W), HEIGHT = 900, CDP = Number(process.env.LL_CDP || 9344), BASE = process.env.LOCAL_BASE || 'http://localhost:3196'
const U = { admin: '01', cco: '02', finance: '03', warehouse: '04', cto: '05', cfo: '06', gm: '07', floor: '08' }
const cookieVal = execFileSync('node', ['proxy.mjs', 'cookie', `a0000000-0000-4000-8000-0000000000${U[ROLE]}`, (ROLE === 'floor' ? 'floor@test.local' : `clone-${ROLE}@test.local`)], { cwd: H, env: { ...process.env, H_SECRET: 'harness-local-secret-0123456789-abcdefghij' } }).toString().trim()
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const chrome = spawn(process.env.HOME + '/' + CHROME, [`--remote-debugging-port=${CDP}`, '--headless', '--disable-gpu', '--no-sandbox', '--hide-scrollbars',
    `--window-size=${WIDTH},${HEIGHT}`, `--user-data-dir=${H}chrome-8b2-${WIDTH}-${ROLE}`, 'about:blank'], { stdio: 'ignore' })
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
        if (process.env.LL_OPEN_DETAILS) { await ev(`(() => { document.querySelectorAll('details').forEach((d) => { d.open = true }); return 1 })()`); await sleep(400) }
        const m = await ev(MEASURE)
        const extra = await ev(`(() => ({ h1: document.querySelector('h1')?.textContent?.trim() ?? null,
            err: /Application error|Internal Server Error|Unhandled Runtime Error/.test(document.body.innerText),
            denied: !!document.querySelector('[data-access-denied]'),
            sections: [...document.querySelectorAll('[data-section]')].map((e) => e.getAttribute('data-section')).join(','),
            restricted: (document.body.innerText.match(/Restricted/g) || []).length,
            sstCodes: (document.body.innerText.match(/SST-2026-\\d{4}/g) || []).filter((v, i, a) => a.indexOf(v) === i).join(','),
            notCompared: (document.body.innerText.match(/Not compared/g) || []).length, notGraded: /Not graded/.test(document.body.innerText),
            warn: /above|cap/i.test(document.body.innerText) && /prepayment|deposit/i.test(document.body.innerText),
            sampling: /Every 10th bag|Every 5th bag/.test(document.body.innerText), superseded: /[Ss]uperseded/.test(document.body.innerText),
            gates: [...document.querySelectorAll('[data-permission-required]')].map((e) => e.getAttribute('data-permission-required')).filter((v, i, a) => a.indexOf(v) === i).join(','),
            x: 0 }))()`)
        if (lastDoc >= 400 || extra.err || m.overflowPx > 1 || m.clippedTables > 0) bad++
        console.log(`PAGE|${WIDTH}|${ROLE}|${lastDoc}|ovf=${m.overflowPx}|clip=${m.clippedTables}|tables=${m.tableCount}|${p}|${JSON.stringify({ ...extra, culprits: m.culprits })}`)
    }
} finally { chrome.kill('SIGKILL') }
console.log(`LOCAL_LAYOUT_EXIT=${bad ? 1 : (process.exitCode ?? 0)}`)
process.exit(bad ? 1 : (process.exitCode ?? 0))
