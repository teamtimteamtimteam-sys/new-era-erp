#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// DRAFT-3 · 【搬家之前】的 390px 读数 —— #8 与 #9(Tim 的 Q9)
// ════════════════════════════════════════════════════════════════════════════
// ★ 它存在的全部理由:DRAFT-2 §4.1 为 #24 留下过一处 `NOT MEASURED` ——
//   「搬家之后」量到了,「搬家之前」没有,因为量它要多付一次生产构建。
//   ☞ 本刀 Tim 裁的是【付那一次】:#8 / #9 的 390px 今天没有任何人量过,
//     而这是旧 markup 还在树上的**最后一刀**。错过这一次就永远补不回来了。
//
// ★★【这支探针【只读】】★★ 它不提交、不写库,只点开一行、数一数、量一量。
//
// ★ 两处在册的探针缺陷都避开(`docs/known-issues.md`):
//   · `PROBE-UNBOUNDED-CDP-WAIT` —— 每一次 CDP 调用带 30s 上限;
//   · `PROBE-LSOF-KILLS-ITSELF` —— 收尾那条 `lsof` 把**本进程**滤掉。
// ════════════════════════════════════════════════════════════════════════════
import { readFileSync, existsSync } from 'node:fs'
import { join } from 'node:path'
import { spawn, execSync } from 'node:child_process'
import { createConnection } from 'node:net'
import { acquireOrExit, release } from './liveLock.mjs'
import { openPlan, planDelete, ephemeralGrantBody, runPlan, reapStalePlans, ORDER } from './ephemeral.mjs'

const ROOT = new URL('..', import.meta.url).pathname
const PORT = 3205, CDP_PORT = 9341
const CHROME = join(process.env.HOME, '.cache/puppeteer/chrome-headless-shell/mac_arm-152.0.7977.75/chrome-headless-shell-mac-arm64/chrome-headless-shell')
const env = readFileSync(join(ROOT, '.env.local'), 'utf8')
const URL_ = env.match(/NEXT_PUBLIC_SUPABASE_URL=(\S+)/)[1]
const ANON = env.match(/NEXT_PUBLIC_SUPABASE_ANON_KEY=(\S+)/)[1]
const SERVICE = env.match(/SUPABASE_SERVICE_ROLE_KEY=(\S+)/)[1]
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const rest = (p, o = {}) => fetch(URL_ + p, { ...o, headers: {
    apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, 'Content-Type': 'application/json', ...(o.headers || {}) } })
const out = []
const note = (id, detail) => { out.push(`${id}: ${detail}`); console.log(`· ${id.padEnd(46)} ${detail}`) }
let server = null, chrome = null

async function waitPort(port, ms) {
    const t0 = Date.now()
    for (;;) {
        const up = await new Promise((res) => {
            const s = createConnection({ port, host: '127.0.0.1' })
            s.on('connect', () => { s.destroy(); res(true) }); s.on('error', () => res(false))
        })
        if (up) return true
        if (Date.now() - t0 > ms) return false
        await sleep(300)
    }
}

async function main() {
    acquireOrExit('probe-draft3-before', { ownExit: false })
    openPlan('probe-draft3-before')
    await reapStalePlans()
    if (!existsSync(join(ROOT, '.next/BUILD_ID'))) throw new Error('.next/BUILD_ID 不在 —— 先 npm run build')
    if (!existsSync(CHROME)) throw new Error('chrome not at ' + CHROME)
    for (const p of [PORT, CDP_PORT]) { try { execSync(`lsof -ti tcp:${p} | xargs -r kill -9`, { stdio: 'ignore' }) } catch {} }

    const email = `draft3before-${Date.now()}@test.local`
    const cu = await (await rest('/auth/v1/admin/users', { method: 'POST',
        body: JSON.stringify({ email, password: 'draft3-probe-1', email_confirm: true }) })).json()
    const accountId = cu.id
    if (!accountId) throw new Error('账号建不出来: ' + JSON.stringify(cu).slice(0, 300))
    planDelete(`/rest/v1/user_roles?user_id=eq.${accountId}`, `revoke grant ${accountId}`, ORDER.GRANT)
    planDelete(`/auth/v1/admin/users/${accountId}`, `delete account ${accountId}`, ORDER.ACCOUNT)
    const roles = await (await rest('/rest/v1/roles?select=id&code=eq.admin')).json()
    await rest('/rest/v1/user_roles', { method: 'POST', body: JSON.stringify(ephemeralGrantBody(accountId, roles[0].id)) })
    const sess = await (await fetch(URL_ + '/auth/v1/token?grant_type=password', { method: 'POST',
        headers: { apikey: ANON, 'Content-Type': 'application/json' },
        body: JSON.stringify({ email, password: 'draft3-probe-1' }) })).json()
    if (!sess?.access_token) throw new Error('登录失败')
    const cookieName = 'sb-' + URL_.split('//')[1].split('.')[0] + '-auth-token'
    const cookieValue = 'base64-' + Buffer.from(JSON.stringify(sess)).toString('base64url')

    server = spawn(join(ROOT, 'node_modules/.bin/next'), ['start', '-p', String(PORT)], { cwd: ROOT, stdio: 'ignore' })
    if (!await waitPort(PORT, 120000)) throw new Error('next start 没起来')

    chrome = spawn(CHROME, [`--remote-debugging-port=${CDP_PORT}`, '--headless', '--disable-gpu',
        '--no-sandbox', '--hide-scrollbars', 'about:blank'], { detached: true, stdio: 'ignore' })
    if (!await waitPort(CDP_PORT, 30000)) throw new Error('chrome CDP 没起来')
    const { webSocketDebuggerUrl } = await (await fetch(`http://127.0.0.1:${CDP_PORT}/json/version`)).json()
    const sock = new WebSocket(webSocketDebuggerUrl)
    await new Promise((res, rej) => { sock.onopen = res; sock.onerror = rej })
    let msgId = 0; const pending = new Map()
    sock.onmessage = (m) => {
        const d = JSON.parse(m.data)
        if (d.id && pending.has(d.id)) {
            const { res, rej } = pending.get(d.id); pending.delete(d.id)
            if (d.error) rej(new Error(JSON.stringify(d.error))); else res(d.result)
        }
    }
    // ★ PROBE-UNBOUNDED-CDP-WAIT:每一次调用都有上限。
    const send = (method, params = {}, sessionId) => new Promise((res, rej) => {
        const id = ++msgId
        const timer = setTimeout(() => { if (pending.delete(id)) rej(new Error(`CDP 超时(30s):${method}`)) }, 30000)
        pending.set(id, { res: (v) => { clearTimeout(timer); res(v) }, rej: (e) => { clearTimeout(timer); rej(e) } })
        sock.send(JSON.stringify({ id, method, params, sessionId }))
    })
    const { targetId } = await send('Target.createTarget', { url: 'about:blank' })
    const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true })
    const S = (m, p) => send(m, p, sessionId)
    await S('Page.enable'); await S('Runtime.enable'); await S('Network.enable')
    await S('Network.setCookies', { cookies: [{ name: cookieName, value: cookieValue,
        domain: '127.0.0.1', path: '/', httpOnly: false, secure: false }] })

    const js = async (expr) => {
        const r = await S('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true })
        if (r.exceptionDetails) throw new Error(expr.slice(0, 90) + ' → ' + JSON.stringify(r.exceptionDetails).slice(0, 300))
        return r.result.value
    }
    const waitFor = async (expr, ms, label) => {
        const t0 = Date.now()
        for (;;) {
            if (await js(expr)) return true
            if (Date.now() - t0 > ms) { console.log(`  · 等待超时(${label})`); return false }
            await sleep(250)
        }
    }
    await S('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 1, mobile: true })

    // 量一张【手搓】表:表里看得见的控件、整页溢出、以及那一格叠起来的东西。
    const MEASURE = `(() => {
        const t = document.querySelectorAll('table')
        const tbl = t[t.length - 1]
        if (!tbl) return { err: 'no table' }
        const ctrls = Array.from(tbl.querySelectorAll('input, select, textarea'))
        const shown = ctrls.filter(e => e.offsetParent !== null)
        const se = document.scrollingElement
        return {
            rows: tbl.querySelectorAll('tbody tr').length,
            cols: tbl.querySelectorAll('thead th').length,
            colsShown: Array.from(tbl.querySelectorAll('thead th')).filter(e => e.offsetParent !== null).length,
            ctrls: ctrls.length, shown: shown.length,
            tableW: Math.round(tbl.getBoundingClientRect().width),
            tableScrollW: tbl.scrollWidth,
            pageScrollW: se.scrollWidth, pageClientW: se.clientWidth,
        } })()`

    // ── #9 /purchasing/payment-terms/new ────────────────────────────────────
    await S('Page.navigate', { url: `http://127.0.0.1:${PORT}/purchasing/payment-terms/new` })
    await sleep(700)
    if (!await waitFor(`(() => { const f = document.querySelector('form')
        return !!f && Object.keys(f).some(k => k.startsWith('__react')) })()`, 60000, '#9 水合'))
        throw new Error('#9 水合没完成 —— 读数不可信')
    const m9 = await js(MEASURE)
    note('#9 搬家前/390 · 表里的控件', `共 ${m9.ctrls} 个,看得见 ${m9.shown} 个(就地可填)`)
    note('#9 搬家前/390 · 列', `表头 ${m9.cols} 列,看得见 ${m9.colsShown} 列`)
    note('#9 搬家前/390 · 表宽', `宽 ${m9.tableW}px · scrollWidth ${m9.tableScrollW}px`)
    note('#9 搬家前/390 · 整页横向溢出',
        `scrollWidth ${m9.pageScrollW} / clientWidth ${m9.pageClientW} —— ${m9.pageScrollW > m9.pageClientW + 1 ? '★ 溢出' : '不溢出'}`)

    // ── #8 /purchasing/orders/new(terms 开局是空的,先加一行)─────────────
    await S('Page.navigate', { url: `http://127.0.0.1:${PORT}/purchasing/orders/new` })
    await sleep(900)
    if (!await waitFor(`(() => { const f = document.querySelector('form')
        return !!f && Object.keys(f).some(k => k.startsWith('__react')) })()`, 60000, '#8 水合'))
        throw new Error('#8 水合没完成 —— 读数不可信')
    const t0 = await js(`(() => { const t = document.querySelectorAll('table'); return t.length })()`)
    // 「加一期」—— 它是 terms 那一节下面唯一一颗 variant=link 的钮
    const added = await js(`(() => {
        const b = Array.from(document.querySelectorAll('button')).filter(e => e.offsetParent !== null)
        for (const e of b) { if (/instalment|加一期|增加一期/i.test(e.textContent || '')) { e.click(); return e.textContent.trim() } }
        return null })()`)
    await sleep(600)
    const m8 = await js(MEASURE)
    note('#8 搬家前/390 · 加一期', `点了「${added ?? '没找到'}」· 表数 ${t0} → ${await js(`document.querySelectorAll('table').length`)}`)
    note('#8 搬家前/390 · 表里的控件', `共 ${m8.ctrls} 个,看得见 ${m8.shown} 个(就地可填)`)
    note('#8 搬家前/390 · 列', `表头 ${m8.cols} 列,看得见 ${m8.colsShown} 列`)
    note('#8 搬家前/390 · 表宽', `宽 ${m8.tableW}px · scrollWidth ${m8.tableScrollW}px`)
    note('#8 搬家前/390 · 整页横向溢出',
        `scrollWidth ${m8.pageScrollW} / clientWidth ${m8.pageClientW} —— ${m8.pageScrollW > m8.pageClientW + 1 ? '★ 溢出' : '不溢出'}`)
}

let code = 0
try { await main() } catch (e) { console.error('✗ 探针自己挂了:', e.message); code = 2 }
finally {
    try { if (chrome) process.kill(-chrome.pid, 'SIGKILL') } catch {}
    try { if (server) process.kill(server.pid, 'SIGTERM') } catch {}
    // ★★ PROBE-LSOF-KILLS-ITSELF:把本进程滤掉。
    for (const p of [PORT, CDP_PORT]) {
        try { execSync(`lsof -ti tcp:${p} | grep -v '^${process.pid}$' | xargs -r kill -9`, { stdio: 'ignore' }) } catch {}
    }
    const r = await runPlan(); console.log(`· 清理:${JSON.stringify(r)}`)
    release()
}
console.log(`\n【搬家之前的读数,共 ${out.length} 条】`)
console.log(`BEFORE_OWN_EXIT=${code}`)
process.exit(code)
