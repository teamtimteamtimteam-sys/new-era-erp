#!/usr/bin/env node
// DRAFT-1 的双渲染证明 —— #10 QuoteLinesEditor(唯一一张线上有行的表,见 R11 计数)。
// ★ 跑在【生产构建】上:probe-avatar 抬头那条 —— 这棵树在 next dev 下水合不收尾。
// ★ 它【不点保存】,所以一行业务数据都不会被写。
import { readFileSync, existsSync } from 'node:fs'
import { join } from 'node:path'
import { spawn, execSync } from 'node:child_process'
import { createConnection } from 'node:net'
import { acquireOrExit, release } from './liveLock.mjs'
import { openPlan, planDelete, ephemeralGrantBody, runPlan, reapStalePlans, ORDER } from './ephemeral.mjs'

const ROOT = new URL('..', import.meta.url).pathname
const PORT = 3202, CDP_PORT = 9338
const CHROME = join(process.env.HOME, '.cache/puppeteer/chrome-headless-shell/mac_arm-152.0.7977.75/chrome-headless-shell-mac-arm64/chrome-headless-shell')
const QUOTE = process.env.QUOTE_ID
const env = readFileSync(join(ROOT, '.env.local'), 'utf8')
const URL_ = env.match(/NEXT_PUBLIC_SUPABASE_URL=(\S+)/)[1]
const ANON = env.match(/NEXT_PUBLIC_SUPABASE_ANON_KEY=(\S+)/)[1]
const SERVICE = env.match(/SUPABASE_SERVICE_ROLE_KEY=(\S+)/)[1]
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const rest = (p, o = {}) => fetch(URL_ + p, { ...o, headers: {
    apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, 'Content-Type': 'application/json', ...(o.headers || {}) } })
const fail = []
const probe = (id, ok, detail) => {
    if (!ok) fail.push(`${id}: ${detail}`)
    console.log(`${ok ? '✓' : '✗'} ${id.padEnd(36)} ${detail}`)
}
let server = null, chrome = null, accountId = null

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
    acquireOrExit('probe-draft1', { ownExit: false })
    openPlan('probe-draft1')
    await reapStalePlans()
    if (!existsSync(join(ROOT, '.next/BUILD_ID'))) throw new Error('.next/BUILD_ID 不在 —— 先 npm run build')
    if (!existsSync(CHROME)) throw new Error('chrome not at ' + CHROME)
    for (const p of [PORT, CDP_PORT]) { try { execSync(`lsof -ti tcp:${p} | xargs -r kill -9`, { stdio: 'ignore' }) } catch {} }

    const email = `draft1probe-${Date.now()}@test.local`
    const cu = await (await rest('/auth/v1/admin/users', { method: 'POST',
        body: JSON.stringify({ email, password: 'draft1-probe-1', email_confirm: true }) })).json()
    accountId = cu.id
    if (!accountId) throw new Error('账号建不出来: ' + JSON.stringify(cu).slice(0, 300))
    planDelete(`/rest/v1/user_roles?user_id=eq.${accountId}`, `revoke grant ${accountId}`, ORDER.GRANT)
    planDelete(`/auth/v1/admin/users/${accountId}`, `delete account ${accountId}`, ORDER.ACCOUNT)
    const roles = await (await rest('/rest/v1/roles?select=id&code=eq.admin')).json()
    await rest('/rest/v1/user_roles', { method: 'POST', body: JSON.stringify(ephemeralGrantBody(accountId, roles[0].id)) })
    const sess = await (await fetch(URL_ + '/auth/v1/token?grant_type=password', { method: 'POST',
        headers: { apikey: ANON, 'Content-Type': 'application/json' },
        body: JSON.stringify({ email, password: 'draft1-probe-1' }) })).json()
    if (!sess?.access_token) throw new Error('登录失败')
    const cookieName = 'sb-' + URL_.split('//')[1].split('.')[0] + '-auth-token'
    const cookieValue = 'base64-' + Buffer.from(JSON.stringify(sess)).toString('base64url')

    server = spawn(join(ROOT,'node_modules/.bin/next'), ['start', '-p', String(PORT)], { cwd: ROOT, stdio: 'ignore' })
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
            if (d.error) rej(new Error(JSON.stringify(d.error)))
            else res(d.result)
        }
    }
    // ★ 每一次 CDP 调用都有上限 —— AGENTS.md:「一个没有上限的等待,是一个没有
    //   失败分支的等待」。第一版没有它,于是 1280 那一臂【挂住不动】:
    //   Runtime.evaluate 的 promise 永不落地,连 waitFor 的 60s 上限都到不了,
    //   最后要靠 run_detached 在 900s 处收尾 —— 一次沉默的挂死,不是一次失败。
    const send = (method, params = {}, sessionId) => new Promise((res, rej) => {
        const id = ++msgId
        const timer = setTimeout(() => {
            if (pending.delete(id)) rej(new Error(`CDP 超时(30s):${method}`))
        }, 30000)
        pending.set(id, { res: (v) => { clearTimeout(timer); res(v) },
                          rej: (e) => { clearTimeout(timer); rej(e) } })
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
    const view = async (w) => S('Emulation.setDeviceMetricsOverride',
        { width: w, height: 900, deviceScaleFactor: 1, mobile: w < 700 })
    const goto = async (path) => {
        await S('Page.navigate', { url: `http://127.0.0.1:${PORT}${path}` })
        await sleep(600)
        // ★ 等【水合收尾】,不是等元素出现(CONFIRM-1 那条)
        const ok = await waitFor(`(() => { const t = document.querySelector('[data-slot="editable-table"]')
            return !!t && Object.keys(t).some(k => k.startsWith('__react')) })()`, 60000, '水合')
        if (!ok) throw new Error('水合没完成 —— 判词不可信,不往下量')
    }
    const INPUTS = `Array.from(document.querySelectorAll('[data-slot="editable-table"] input[type=number]'))`
    const census = () => js(`${INPUTS}.map(e => ({ label: e.getAttribute('aria-label'), value: e.value, shown: e.offsetParent !== null }))`)
    // 真的打字:聚焦看得见的那一份,全选,再由 CDP 送字符进去
    const typeInto = async (idxExpr, text) => {
        await js(`(() => { const e = ${INPUTS}[${idxExpr}]; e.focus(); e.select(); return true })()`)
        await S('Input.insertText', { text })
        await sleep(350)
    }
    const path = `/sales/quotes/${QUOTE}`

    // ══ 390px ═══════════════════════════════════════════════════════════════
    await view(390); await goto(path)
    const before = await census()
    probe('390/收起时', before.length === 2 && before.every((i) => !i.shown),
        `DOM ${before.length} 个、看得见 ${before.filter(i=>i.shown).length} 个(手机上格子只读)`)

    await js(`document.querySelector('[data-slot="editable-table"] button[aria-expanded]').click()`); await sleep(500)
    const opened = await census()
    probe('390/展开后 DOM 里有两份', opened.length === 4 && opened.filter(i=>i.shown).length === 2,
        `DOM ${opened.length} / 看得见 ${opened.filter(i=>i.shown).length}(期望 4 / 2)`)

    const shownIdx = await js(`${INPUTS}.findIndex(e => e.offsetParent !== null)`)
    const shownLabel = opened[shownIdx]?.label
    await typeInto(shownIdx, '77')
    const typed = await census()
    const pair = typed.filter((i) => i.label === shownLabel).map((i) => i.value)
    probe('★ 390/两份读同一个 store', pair.length === 2 && pair.every((v) => v === '77'),
        `「${shownLabel}」两份的值 = ${JSON.stringify(pair)}`)

    await js(`document.querySelector('[data-slot="editable-table"] button[aria-expanded]').click()`); await sleep(500)
    const collapsed = await census()
    probe('390/收起 —— 展开区那一份卸载', collapsed.length === 2, `DOM ${collapsed.length} 个`)

    await js(`document.querySelector('[data-slot="editable-table"] button[aria-expanded]').click()`); await sleep(500)
    const re = await census()
    const reShown = re.filter((i) => i.shown && i.label === shownLabel)[0]
    probe('★★ 390/收起再展开,打的字还在', reShown?.value === '77',
        `展开区那一份 = ${JSON.stringify(reShown?.value)}(期望 "77")`)

    const totals = await js(`Array.from(document.querySelectorAll('[data-slot="editable-table"] tbody td, [data-slot="editable-table"] tbody dd'))
        .map(e => e.textContent.trim()).filter(t => /^[\\d,]+\\.\\d\\d$/.test(t))`)
    probe('390/金额列是草稿的投影', totals.length > 0, `算出来的金额 = ${JSON.stringify(totals)}`)

    // ══ 1280px ══════════════════════════════════════════════════════════════
    // ★ 【不重新导航】,只改视口 —— 两个理由:
    //   ① 断点切换本来就是纯 CSS 的事,重新导航反而把它变成了另一次首屏;
    //   ② ★ 更要紧的:草稿【留在原地】,于是这一臂能证一件 goto 证不了的事 ——
    //     390 上在展开区打的那个 77,在 1280 上出现在【格子里】,而展开区那一份
    //     被 CSS 整行藏起来。**同一个 store,两个断点。**
    await view(1280); await sleep(600)
    const desk = await census()
    const deskShown = desk.filter((i) => i.shown)
    probe('1280/格子里就地编辑', desk.length === 4 && deskShown.length === 2,
        `DOM ${desk.length} / 看得见 ${deskShown.length}(展开区那一行被 sm:hidden 整行藏起来)`)
    probe('★ 1280/390 上打的字出现在格子里', deskShown.some((i) => i.value === '77'),
        `看得见的两格 = ${JSON.stringify(deskShown.map((i) => i.value))}`)
    await typeInto(await js(`${INPUTS}.findIndex(e => e.offsetParent !== null)`), '88')
    const deskTyped = await census()
    const pair88 = deskTyped.filter((i) => i.label === shownLabel).map((i) => i.value)
    probe('1280/打字落在同一个 store', pair88.length === 2 && pair88.every((v) => v === '88'),
        `「${shownLabel}」两份的值 = ${JSON.stringify(pair88)}`)
}

let code = 0
try { await main() } catch (e) { console.error('✗ 探针自己挂了:', e.message); code = 2 }
finally {
    try { if (chrome) process.kill(-chrome.pid, 'SIGKILL') } catch {}
    try { if (server) process.kill(server.pid, 'SIGTERM') } catch {}
    // ★★ 【不许把自己也杀掉】★★ 第一版写的是 `lsof -ti tcp:<port> | xargs kill -9`,
    //   而 `lsof -ti tcp:9338` 会连**本进程那条 CDP 客户端 socket** 一起列出来 ——
    //   于是这支探针在收尾时把自己 SIGKILL 掉了(实测 `PROBE_EXIT=137`),
    //   九条断言全绿、而 runPlan() 一步都没跑:线上留下一个一次性 admin 和它的授权。
    //   ☞ 这正是 LEAK-1 那条「清理要接到每一条出口上」的又一张脸,
    //     而救回它的是那份【先于它要清的东西落盘】的计划 —— 下一次运行把它收走了。
    for (const p of [PORT, CDP_PORT]) {
        try { execSync(`lsof -ti tcp:${p} | grep -v '^${process.pid}$' | xargs -r kill -9`, { stdio: 'ignore' }) } catch {}
    }
    const r = await runPlan(); console.log(`· 清理:${JSON.stringify(r)}`)
    release()
}
if (fail.length) { console.log(`\n✗ ${fail.length} 条没过:\n  ` + fail.join('\n  ')); code = code || 1 }
else if (code === 0) console.log('\n✓ 全部通过')
console.log(`PROBE_OWN_EXIT=${code}`)
process.exit(code)
