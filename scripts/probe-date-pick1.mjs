#!/usr/bin/env node
// scripts/probe-date-pick1.mjs
// ════════════════════════════════════════════════════════════════════════════
// DATE-PICK-1(2026-10-05)· 日期框的交互探针 —— 对着线上库、在真浏览器里敲、点、提交
// ════════════════════════════════════════════════════════════════════════════
// 【它证什么】(委托书第 3 节第 9 步)每个模块至少一张表单(采购 · 销售 · 库存 · 加工 · 财务 · 人事 · 设置),
//   外加【每一个】月份框与日期时间框:
//   ① 四种认的写法(5/10/2026 · 05/10/26 · 05102026 · 粘贴 2026-10-05)各敲一次,读回交出去的 ISO;
//   ② 一个不存在的日子(31/02)与一个范围外的日子各敲一次:框下面说出原因,提交被拦;
//   ③ 月历周一开头、中文界面里月名与星期名是中文;键盘(方向键 · PageUp/PageDown · Enter · Esc);
//   ④ 日期时间框交出去的是新加坡时间。
//
// 【它为什么写不了库】(本探针最要紧的一条)
//   每一次 server action 的 POST(带 `Next-Action` 头)都在【浏览器这一侧】被 CDP 的 Fetch 拦下、读出请求体、
//   然后 failRequest —— 请求一个字节都没有到服务端。于是"提交出去的是什么"是一次【测量】(读的是浏览器真正要发的那一份),
//   而线上一行都不会因为它改变。GET 表单与 router.push 的筛选是只读的导航,照常放行。
//   ★ 唯一写线上的是那个一次性的 admin 账号与它的授权(ephemeral 计划,出口一律 exitAfterCleanup)。
//   ★ 前后读数另跑 db/scripts/2026-10-05-datepick1-live-readings.sql 比对。
//
// 用法:node scripts/probe-date-pick1.mjs            (先 npm run build;跑在 next start 上)
//       PROBE_FAULT=no-block node scripts/probe-date-pick1.mjs     ← 注入:判据当作"没拦住",拦截那 8 格必须红
//       PROBE_FAULT=no-validity node scripts/probe-date-pick1.mjs  ← 注入:浏览器里的 setCustomValidity 换成空操作(机制真的坏掉),
//                                                                    原生表单那几格必须红(提交真的发出去了,仍被掐在浏览器里)
// 退出码:0 全过 · 1 有判据没过 · 2 探针自己挂了 · 6 收尾没清干净
// ════════════════════════════════════════════════════════════════════════════
import { onlyWhenRunDirectly } from './lib/entrypoint.mjs'
import { readFileSync, existsSync } from 'node:fs'
import { join } from 'node:path'
import { spawn, execSync } from 'node:child_process'
import { createConnection } from 'node:net'
import { acquireOrExit, release } from './liveLock.mjs'
import { openPlan, mintThrowaway, reapStalePlans, exitAfterCleanup, installExitHooks } from './ephemeral.mjs'

onlyWhenRunDirectly(import.meta.url)

const ROOT = new URL('..', import.meta.url).pathname
const PORT = 3209, CDP_PORT = 9349
const CHROME = join(process.env.HOME, '.cache/puppeteer/chrome-headless-shell/mac_arm-152.0.7977.75/chrome-headless-shell-mac-arm64/chrome-headless-shell')
const env = readFileSync(join(ROOT, '.env.local'), 'utf8')
const URL_ = env.match(/NEXT_PUBLIC_SUPABASE_URL=(\S+)/)[1]
const SERVICE = env.match(/SUPABASE_SERVICE_ROLE_KEY=(\S+)/)[1]
const FAULT = process.env.PROBE_FAULT || ''

// 线上的几条记录(只读打开;它们的页面上才画得出那几个日期时间框)
const ASSET_OPEN_DOWNTIME = 'a1560d88-de19-40fe-b78b-3bfa4079762b'   // FA-2026-0001:有一段没结束的停机 → "结束时刻"框
const ASSET_NO_DOWNTIME = 'c20e3ba1-67a2-48dd-a884-b2f826dcb1ad'     // FA-2026-0002:没有开着的停机 → "开始时刻"框
const TASK = '233b92e2-1427-4a71-8ad8-6cd2c96feee5'                  // TASK-2026-0181

const en = (await import('../messages/en.ts')).default
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const rest = (p, o = {}) => fetch(URL_ + p, { ...o, headers: {
    apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, 'Content-Type': 'application/json', ...(o.headers || {}) } })
const fail = [], passed = []
const probe = (id, ok, detail) => {
    (ok ? passed : fail).push(`${id}: ${detail}`)
    console.log(`${ok ? '✓' : '✗'} ${id.padEnd(70)} ${detail}`)
}
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

// 新加坡今天 / 明天(判据自己的,不借被测的代码)
const sgToday = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Singapore' }).format(new Date())
const sgTomorrow = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Singapore' }).format(new Date(Date.now() + 86400000))
const dmy = (iso) => `${iso.slice(8, 10)}/${iso.slice(5, 7)}/${iso.slice(0, 4)}`

// 四种认的写法 → 同一天(2026-09-03,过去的日子,任何"不晚于今天"的框都收)
const FORMATS = [['D/M/YYYY', '3/9/2026'], ['DD/MM/YY', '03/09/26'], ['DDMMYYYY', '03092026'], ['ISO 粘贴', '2026-09-03']]
const WANT = '2026-09-03'

async function main() {
    acquireOrExit('probe-date-pick1', { ownExit: false })
    installExitHooks({ onFinish: () => {
        try { if (chrome) process.kill(-chrome.pid, 'SIGKILL') } catch {}
        try { if (server) process.kill(server.pid, 'SIGTERM') } catch {}
        for (const p of [PORT, CDP_PORT]) {
            try { execSync(`lsof -ti tcp:${p} | grep -v '^${process.pid}$' | xargs -r kill -9`, { stdio: 'ignore' }) } catch {}
        }
        release()
    } })
    openPlan('probe-date-pick1')
    await reapStalePlans()
    if (!existsSync(join(ROOT, '.next/BUILD_ID'))) throw new Error('.next/BUILD_ID 不在 —— 先 npm run build')
    if (!existsSync(CHROME)) throw new Error('chrome not at ' + CHROME)
    for (const p of [PORT, CDP_PORT]) { try { execSync(`lsof -ti tcp:${p} | xargs -r kill -9`, { stdio: 'ignore' }) } catch {} }

    // ── 一次性全码会话 ──
    // ★ U1-B(2026-10-05,GHOST-GRANTS):此前授的是【真 admin】(而且不看授权那一句的返回码);现在经 mintThrowaway
    //   造一个一次性全码角色(probe-datepick1probe-all-<stamp>)授给它 —— 删除步先落盘,每一句往返看返回码。
    const tw = await mintThrowaway({ prefix: 'datepick1probe', label: 'all', codes: 'all', password: 'datepick1-probe-1' })
    const cookieName = tw.cookieName
    const cookieValue = tw.cookieValue

    server = spawn(join(ROOT, 'node_modules/.bin/next'), ['start', '-p', String(PORT)], { cwd: ROOT, stdio: 'ignore' })
    if (!await waitPort(PORT, 120000)) throw new Error('next start 没起来')
    chrome = spawn(CHROME, [`--remote-debugging-port=${CDP_PORT}`, '--headless', '--disable-gpu',
        '--no-sandbox', '--hide-scrollbars', 'about:blank'], { detached: true, stdio: 'ignore' })
    if (!await waitPort(CDP_PORT, 30000)) throw new Error('chrome CDP 没起来')
    const { webSocketDebuggerUrl } = await (await fetch(`http://127.0.0.1:${CDP_PORT}/json/version`)).json()
    const sock = new WebSocket(webSocketDebuggerUrl)
    await new Promise((res, rej) => { sock.onopen = res; sock.onerror = rej })
    let msgId = 0; const pending = new Map()
    const actions = []          // 被拦下的 server action:{ url, body }
    let sessionIdG = null
    const send = (method, params = {}, sessionId) => new Promise((res, rej) => {
        const id = ++msgId
        const timer = setTimeout(() => { if (pending.delete(id)) rej(new Error(`CDP 超时(30s):${method}`)) }, 30000)
        pending.set(id, { res: (v) => { clearTimeout(timer); res(v) }, rej: (e) => { clearTimeout(timer); rej(e) } })
        sock.send(JSON.stringify({ id, method, params, sessionId }))
    })
    sock.onmessage = (m) => {
        const d = JSON.parse(m.data)
        if (d.id && pending.has(d.id)) {
            const { res, rej } = pending.get(d.id); pending.delete(d.id)
            if (d.error) rej(new Error(JSON.stringify(d.error))); else res(d.result)
            return
        }
        // ★ 拦截:每一个 server action 的 POST 都读出请求体、然后【在浏览器这一侧】掐掉 —— 一个字节都到不了服务端
        if (d.method === 'Fetch.requestPaused') {
            const { requestId, request } = d.params
            const isAction = request.method === 'POST' && Object.keys(request.headers || {}).some((h) => h.toLowerCase() === 'next-action')
            if (isAction) {
                actions.push({ url: request.url, body: request.postData ?? '' })
                send('Fetch.failRequest', { requestId, errorReason: 'Aborted' }, d.sessionId).catch(() => {})
            } else {
                send('Fetch.continueRequest', { requestId }, d.sessionId).catch(() => {})
            }
        }
    }
    const { targetId } = await send('Target.createTarget', { url: 'about:blank' })
    const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true })
    sessionIdG = sessionId
    const S = (m, p) => send(m, p, sessionIdG)
    await S('Page.enable'); await S('Runtime.enable'); await S('Network.enable')
    await S('Fetch.enable', { patterns: [{ urlPattern: '*', requestStage: 'Request' }] })
    // ★ 注入 no-validity:把浏览器的 setCustomValidity 换成空操作 —— 拦原生提交的那一半【真的】坏掉,
    //   于是敲错的日子会被提交出去(仍然在浏览器里被掐掉)。原生表单那几格必须红,按钮那几格(onInvalidChange)仍绿。
    if (FAULT === 'no-validity') await S('Page.addScriptToEvaluateOnNewDocument', { source: 'HTMLInputElement.prototype.setCustomValidity = function () {}' })
    const setLocale = (loc) => S('Network.setCookies', { cookies: [
        { name: cookieName, value: cookieValue, domain: '127.0.0.1', path: '/', httpOnly: false, secure: false },
        { name: 'NEXT_LOCALE', value: loc, domain: '127.0.0.1', path: '/', httpOnly: false, secure: false }] })
    await setLocale('en')

    const js = async (expr) => {
        const r = await S('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true })
        if (r.exceptionDetails) throw new Error(expr.slice(0, 90) + ' → ' + JSON.stringify(r.exceptionDetails).slice(0, 300))
        return r.result.value
    }
    const waitFor = async (expr, ms) => {
        const t0 = Date.now()
        for (;;) { if (await js(expr)) return true; if (Date.now() - t0 > ms) return false; await sleep(200) }
    }
    const view = (w) => S('Emulation.setDeviceMetricsOverride', { width: w, height: 900, deviceScaleFactor: 1, mobile: w < 700 })
    await view(1280)
    const goto = async (path, label) => {
        await S('Page.navigate', { url: `http://127.0.0.1:${PORT}${path}` })
        await sleep(600)
        // 水合判据:日期框外层挂上了 React 的 fiber(没有日期框的页面不会被拿来量)
        if (!await waitFor(`(() => { const w = document.querySelector('[data-date-picker]')
            return !!w && Object.keys(w).some(k => k.startsWith('__react')) })()`, 60000))
            throw new Error(`${label}(${path}):日期框没出现或没水合 —— 判词不可信,不往下量`)
        await js(HELPERS)
    }
    // 页内助手:按序号或隐藏输入的 name 找日期框
    const HELPERS = `window.__dp = (k) => typeof k === 'number'
            ? document.querySelectorAll('[data-date-picker]')[k]
            : document.querySelector('input[type=hidden][name="' + k + '"]')?.closest('[data-date-picker]');
        window.__st = (k) => { const w = window.__dp(k); if (!w) return null
            const tx = w.querySelector('[data-date-text]')
            return { value: w.getAttribute('data-date-value'), text: tx.value, time: w.querySelector('[data-date-time]')?.value ?? null,
                     hidden: w.querySelector('input[type=hidden]')?.value ?? null,
                     error: w.querySelector('[data-date-error]')?.textContent ?? null, validity: tx.validationMessage,
                     formValid: tx.form ? tx.form.checkValidity() : null } }; true`

    /** 往第 k 个日期框(或叫 name 的那个)里敲 text(和 time),再离开 —— 用 CDP 的 insertText,与人敲字走同一条路 */
    const type = async (k, text, time) => {
        await js(`(() => { const t = window.__dp(${JSON.stringify(k)}).querySelector('[data-date-text]'); t.focus(); t.select(); return true })()`)
        if (text === '') await S('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Backspace', code: 'Backspace', windowsVirtualKeyCode: 8 })
        else await S('Input.insertText', { text })
        if (time !== undefined) {
            await js(`(() => { const t = window.__dp(${JSON.stringify(k)}).querySelector('[data-date-time]'); t.focus(); t.select(); return true })()`)
            await S('Input.insertText', { text: time })
        }
        await js(`document.activeElement && document.activeElement.blur(), true`)
        await sleep(150)
        return js(`window.__st(${JSON.stringify(k)})`)
    }
    const st = (k) => js(`window.__st(${JSON.stringify(k)})`)
    const click = (sel) => js(`(() => { const b = ${sel}; if (!b) return 'missing'; b.click(); return 'clicked' })()`)
    const btnByText = (txt, scope = 'document') => `Array.from(${scope}.querySelectorAll('button')).find(b => b.textContent.trim() === ${JSON.stringify(txt)})`
    const submitOf = (k) => `window.__dp(${JSON.stringify(k)}).querySelector('[data-date-text]').form?.querySelector('button[type=submit], button:not([type])')`

    /** ① 四种写法 —— 每一种都读回同一个 ISO(交出去的值;有 name 的另读隐藏输入) */
    const formats = async (label, k, { named = true } = {}) => {
        for (const [fmt, txt] of FORMATS) {
            const s = await type(k, txt)
            const ok = s && s.value === WANT && (!named || s.hidden === WANT) && s.text === dmy(WANT) && !s.error
            probe(`${label} · 敲 ${fmt} "${txt}"`, ok, `交出 ${s?.value}${named ? ` · 隐藏输入 ${s?.hidden}` : ''} · 框里 "${s?.text}"`)
        }
    }
    /** ② 不存在 / 范围外 —— 说出原因、值不变、提交被拦 */
    const blocked = async (label, k, txt, needle, how) => {
        const before = await st(k)
        const s = await type(k, txt)
        const said = !!s.error && s.error.includes(needle)
        const kept = s.value === before.value
        let stopped
        if (how.kind === 'native') {
            const n0 = actions.length, url0 = await js('location.href')
            await click(submitOf(k)); await sleep(1500)
            const posted = actions.length > n0 || (await js('location.href')) !== url0
            stopped = s.formValid === false && s.validity === s.error && !posted && FAULT !== 'no-block'
            probe(`${label} · ${how.what} "${txt}" 拦住原生提交`, said && kept && stopped,
                `框下:"${s.error}" · 浏览器的校验句${s.validity === s.error ? '与它相同' : `不同:"${s.validity}"`} · 值仍是 ${s.value} · 点了提交:${posted ? '发出去了' : '没有发出任何请求'}`)
        } else {
            const dis = await js(`(() => { const b = ${how.button}; return b ? b.disabled : 'missing' })()`)
            stopped = dis === true && FAULT !== 'no-block'
            probe(`${label} · ${how.what} "${txt}" 关掉按钮提交`, said && kept && stopped,
                `框下:"${s.error}" · 值仍是 ${s.value} · 提交钮 disabled=${dis}`)
        }
        await type(k, dmy(WANT))   // 改回一个合法值,给后面的步骤
    }

    // ════════ 采购:/purchasing/orders/new(原生表单,order_date 必填)════════
    await goto('/purchasing/orders/new', '采购单新建')
    await formats('采购 order_date', 'order_date')
    probe('采购 order_date · 表单数据里是 ISO', await js(`new FormData(window.__dp('order_date').querySelector('[data-date-text]').form).get('order_date')`) === WANT, '读 new FormData(form)')
    await blocked('采购 order_date', 'order_date', '31/02/2026', '31/02/2026', { kind: 'native', what: '不存在的日子' })

    // ════════ 销售:/sales/quotes/new(原生表单,quote_date / valid_until)════════
    await goto('/sales/quotes/new', '报价新建')
    await formats('销售 quote_date', 'quote_date')
    await blocked('销售 quote_date', 'quote_date', '30/02/2026', '30/02/2026', { kind: 'native', what: '不存在的日子' })
    await formats('销售 valid_until', 'valid_until')

    // ════════ 库存:/inbound/new(原生表单)+ /inventory/reports/ledger(GET 筛选,真提交 —— 只读导航)════════
    await goto('/inbound/new', '进料新建')
    await formats('库存 arrival_date', 'arrival_date')
    await blocked('库存 arrival_date', 'arrival_date', '31/04/2026', '31/04/2026', { kind: 'native', what: '不存在的日子' })
    await goto('/inventory/reports/ledger', '库存流水')
    await formats('库存流水 from', 'from')
    await type('to', '30/9/2026')
    await click(submitOf('from'))
    await waitFor(`location.search.includes('from=')`, 15000)
    const lq = await js('location.search')
    probe('库存流水 · GET 提交的 URL 是 ISO', lq.includes(`from=${WANT}`) && lq.includes('to=2026-09-30'), lq)

    // ════════ 加工:/operation/orders/new(按钮 onClick 提交 → onInvalidChange 关钮)════════
    await goto('/operation/orders/new', '工单新建')
    await formats('加工 scheduled', 0, { named: false })
    await blocked('加工 scheduled', 0, '29/02/2026', '29/02/2026', { kind: 'button', what: '不存在的日子',
        button: `Array.from(document.querySelectorAll('button[type=button]')).filter(b => !b.closest('[data-date-picker]')).pop()` })

    // ════════ 财务:/finance/expenses/new(原生表单,不晚于今天)════════
    await goto('/finance/expenses/new', '费用新建')
    await formats('财务 expense_date', 'expense_date')
    await blocked('财务 expense_date', 'expense_date', '31/06/2026', '31/06/2026', { kind: 'native', what: '不存在的日子' })
    await blocked('财务 expense_date', 'expense_date', dmy(sgTomorrow), 'future', { kind: 'native', what: '范围外(明天)' })
    // 月历里明天是灰的,原因写在月历底下
    await click(`window.__dp('expense_date').querySelector('[data-date-open]')`)
    await waitFor(`!!document.querySelector('[data-date-popover]')`, 5000)
    const dis = await js(`(() => { const b = document.querySelector('[data-date-popover] [data-day="${sgTomorrow}"]')
        const r = document.querySelector('[data-date-popover] [data-date-reason]')
        return { tomorrowDisabled: b ? b.getAttribute('aria-disabled') : 'not in this month', title: b?.title ?? null, reason: r?.textContent ?? null } })()`)
    probe('财务 expense_date · 月历里明天点不了、原因写着', (dis.tomorrowDisabled === 'true' || dis.tomorrowDisabled === 'not in this month') && !!dis.reason && dis.reason.includes(dmy(sgToday)),
        JSON.stringify(dis))
    if (dis.tomorrowDisabled === 'true') {
        await click(`document.querySelector('[data-date-popover] [data-day="${sgTomorrow}"]')`)
        await sleep(200)
        const s = await st('expense_date')
        probe('财务 expense_date · 点灰掉的明天什么都不交', s.value === WANT, `交出的值仍是 ${s.value}`)
    }
    await S('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 })
    await sleep(200)

    // ════════ 键盘:方向键 · PageDown · Home/End · Enter · Esc(在费用日期框上)════════
    {
        await click(`window.__dp('expense_date').querySelector('[data-date-open]')`)
        await waitFor(`document.activeElement?.hasAttribute('data-day')`, 5000)
        const f0 = await js(`document.activeElement.getAttribute('data-day')`)
        const key = async (key, code, vk, mods = 0) => {
            await S('Input.dispatchKeyEvent', { type: 'keyDown', key, code, windowsVirtualKeyCode: vk, modifiers: mods })
            await S('Input.dispatchKeyEvent', { type: 'keyUp', key, code, windowsVirtualKeyCode: vk, modifiers: mods })
            await sleep(120)
            return js(`document.activeElement?.getAttribute('data-day') ?? null`)
        }
        const r1 = await key('ArrowRight', 'ArrowRight', 39), r2 = await key('ArrowDown', 'ArrowDown', 40)
        const r3 = await key('ArrowLeft', 'ArrowLeft', 37), r4 = await key('ArrowUp', 'ArrowUp', 38)
        const r5 = await key('PageUp', 'PageUp', 33), r6 = await key('PageDown', 'PageDown', 34)
        const r7 = await key('Home', 'Home', 36), r8 = await key('End', 'End', 35)
        const iso = (d) => new Date(d + 'T00:00:00Z')
        const plus = (d, n) => new Date(iso(d).getTime() + n * 86400000).toISOString().slice(0, 10)
        const dowMon = (d) => (iso(d).getUTCDay() + 6) % 7
        probe('键盘 · 打开时焦点落在选中的那一天', f0 === WANT, `焦点 ${f0}`)
        probe('键盘 · → +1 天 · ↓ +7 天 · ← −1 · ↑ −7', r1 === plus(f0, 1) && r2 === plus(f0, 8) && r3 === plus(f0, 7) && r4 === f0, `${r1} · ${r2} · ${r3} · ${r4}`)
        probe('键盘 · PageUp 上一个月 · PageDown 回来', r5 === '2026-08-03' && r6 === f0, `${r5} · ${r6}`)
        probe('键盘 · Home 到周一 · End 到周日', dowMon(r7) === 0 && dowMon(r8) === 6 && r8 === plus(r7, 6), `${r7} · ${r8}`)
        await key('ArrowLeft', 'ArrowLeft', 37)
        const target = await js(`document.activeElement.getAttribute('data-day')`)
        await key('Enter', 'Enter', 13)
        await sleep(200)
        const after = await st('expense_date')
        const closed = await js(`!document.querySelector('[data-date-popover]')`)
        const focusBack = await js(`document.activeElement?.hasAttribute('data-date-text')`)
        probe('键盘 · Enter 选中那一天、月历关上、焦点回到框里', after.value === target && after.hidden === target && closed && focusBack,
            `选中 ${target} → 交出 ${after.value} · 月历关了 ${closed} · 焦点回框 ${focusBack}`)
        await click(`window.__dp('expense_date').querySelector('[data-date-open]')`)
        await waitFor(`document.activeElement?.hasAttribute('data-day')`, 5000)
        await key('Escape', 'Escape', 27)
        await sleep(200)
        probe('键盘 · Esc 关上月历、值不变、焦点回框', await js(`!document.querySelector('[data-date-popover]')`) && (await st('expense_date')).value === target
            && await js(`document.activeElement?.hasAttribute('data-date-text')`), 'Esc')
    }

    // ════════ 月历:周一开头;中文界面的月名与星期名是中文(Q35 · Q39)════════
    const calendarLook = async () => {
        await click(`window.__dp(0).querySelector('[data-date-open]')`)
        await waitFor(`!!document.querySelector('[data-date-popover] [data-date-dow]')`, 5000)
        const r = await js(`(() => { const p = document.querySelector('[data-date-popover]')
            const dows = Array.from(p.querySelectorAll('[data-date-dow]')).map(e => e.textContent)
            const rows = Array.from(p.querySelectorAll('[role=grid] [role=row]')).slice(1)
            const first = rows[0] ? Array.from(rows[0].children).findIndex(c => c.querySelector('[data-day]')) : -1
            const day1 = p.querySelector('[data-day]')?.getAttribute('data-day')
            return { title: p.querySelector('[data-date-title]').textContent, dows, firstCol: first, day1 } })()`)
        await S('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 })
        return r
    }
    const col = (d) => (new Date(d + 'T00:00:00Z').getUTCDay() + 6) % 7
    {
        await goto('/finance/expenses/new', '费用新建(英文月历)')
        const e = await calendarLook()
        probe('月历 · 英文:周一开头,1 号落在它那一列', e.dows[0] === 'Mon' && e.dows[6] === 'Sun' && e.firstCol === col(e.day1), `${e.title} · ${e.dows.join(' ')} · 1 号在第 ${e.firstCol + 1} 列`)
        probe('月历 · 英文月名', /^[A-Z][a-z]+ \d{4}$/.test(e.title), e.title)
        await setLocale('zh')
        await goto('/finance/expenses/new', '费用新建(中文月历)')
        const z = await calendarLook()
        probe('月历 · 中文:周一开头,星期名是中文', z.dows[0] === '一' && z.dows[6] === '日' && z.firstCol === col(z.day1), `${z.title} · ${z.dows.join(' ')}`)
        probe('月历 · 中文月名(2026年10月 这样)', /^\d{4}年\d{1,2}月$/.test(z.title), z.title)
        const zt = await type('expense_date', '03092026')
        probe('中文界面 · 敲的格式仍是 DD/MM/YYYY', zt.text === '03/09/2026' && zt.hidden === WANT, `框里 "${zt.text}" · 交出 ${zt.hidden}`)
        const zb = await type('expense_date', '31/02/2026')
        probe('中文界面 · 不存在的日子用中文说', !!zb.error && /不是一个存在的日子/.test(zb.error), zb.error)
        await setLocale('en')
    }

    // ════════ 人事:/hr/reviews/cycles(三个框,按钮提交)════════
    await goto('/hr/reviews/cycles', '评审轮次')
    for (const i of [0, 1, 2]) await formats(`人事 轮次框 #${i + 1}`, i, { named: false })
    await blocked('人事 轮次 start', 0, '31/09/2026', '31/09/2026', { kind: 'button', what: '不存在的日子',
        button: btnByText(en.common.save) })

    // ════════ 设置:/settings/change-history(GET 筛选,真提交 —— 只读导航)════════
    await goto('/settings/change-history', '变更记录')
    await formats('设置 from', 'from')
    await blocked('设置 to', 'to', '32/01/2026', '32/01/2026', { kind: 'native', what: '不存在的日子' })
    await type('to', '30/09/2026')
    await click(submitOf('from'))
    await waitFor(`location.search.includes('from=')`, 15000)
    const cq = await js('location.search')
    probe('设置 · GET 提交的 URL 是 ISO', cq.includes(`from=${WANT}`) && cq.includes('to=2026-09-30'), cq)

    // ════════ 每一个月份框(5 个)════════
    const MONTH_WANT = '2026-09'
    const monthFormats = async (label, k) => {
        for (const [fmt, txt] of [['M/YYYY', '9/2026'], ['MM/YY', '09/26'], ['MMYYYY', '092026'], ['ISO 粘贴', '2026-09']]) {
            const s = await type(k, txt)
            probe(`${label} · 敲 ${fmt} "${txt}"`, s.value === MONTH_WANT && s.text === '09/2026' && !s.error, `交出 ${s.value} · 隐藏 ${s.hidden} · 框里 "${s.text}"`)
        }
        const b = await type(k, '13/2026')
        probe(`${label} · 不存在的月份 "13/2026" 说出来、值不变`, !!b.error && b.error.includes('13/2026') && b.value === MONTH_WANT, `"${b.error}" · 值 ${b.value}`)
        return b
    }
    // ① /finance/month-end(GET month)
    await goto('/finance/month-end', '月结')
    {
        const b = await monthFormats('月份 /finance/month-end', 'month')
        probe('月份 /finance/month-end · 不存在的月份拦住 GET 提交', b.formValid === false, `表单校验 ${b.formValid}`)
        await type('month', '9/2026')
        await click(submitOf('month'))
        await waitFor(`location.search.includes('month=')`, 15000)
        probe('月份 /finance/month-end · GET 提交 month=2026-09', (await js('location.search')).includes('month=2026-09'), await js('location.search'))
    }
    // ② /finance/packs(选了就跳)
    await goto('/finance/packs', '管理包')
    {
        await monthFormats('月份 /finance/packs', 0)
        // 这一页默认就是 09/2026(上一个月)—— 敲同一个月不会跳,这是对的;换一个月才看得见"选了就跳"
        await type(0, '8/2026')
        await waitFor(`location.search.includes('month=2026-08')`, 15000)
        probe('月份 /finance/packs · 选中另一个月就跳到 ?month=2026-08', (await js('location.search')).includes('month=2026-08'), await js('location.search'))
    }
    // ③ /hr/attendance(按钮提交 → 被拦的 POST)
    await goto('/hr/attendance', '考勤')
    {
        await monthFormats('月份 /hr/attendance', 0)
        const btn = btnByText(en.attendance.openBtn)
        await type(0, '13/2026')
        probe('月份 /hr/attendance · 不存在的月份关掉"开月"钮', await js(`${btn}?.disabled`) === true, `disabled=${await js(`${btn}?.disabled`)}`)
        await type(0, '9/2026')
        const n0 = actions.length
        await click(btn); await sleep(1500)
        const a = actions.slice(n0)
        probe('月份 /hr/attendance · 提交出去的是 2026-09(被拦在浏览器里)', a.length === 1 && a[0].body.includes('2026-09'), a.map((x) => x.body.slice(0, 160)).join(' | ') || '没有请求')
    }
    // ④ /hr/leave/calendar(GET month)
    await goto('/hr/leave/calendar', '请假日历')
    {
        await monthFormats('月份 /hr/leave/calendar', 'month')
        await type('month', '9/2026')
        await click(submitOf('month'))
        await waitFor(`location.search.includes('month=')`, 15000)
        probe('月份 /hr/leave/calendar · GET 提交 month=2026-09', (await js('location.search')).includes('month=2026-09'), await js('location.search'))
    }
    // ⑤ /hr/payroll/new(原生表单 period_month)
    await goto('/hr/payroll/new', '工资新建')
    {
        const b = await monthFormats('月份 /hr/payroll/new', 'period_month')
        probe('月份 /hr/payroll/new · 不存在的月份拦住原生提交', b.formValid === false, `表单校验 ${b.formValid}`)
        await type('period_month', '9/2026')
        probe('月份 /hr/payroll/new · 表单数据里是 2026-09', await js(`new FormData(window.__dp('period_month').querySelector('[data-date-text]').form).get('period_month')`) === '2026-09', 'new FormData(form)')
        await formats('工资 payment_date', 'payment_date')
    }

    // ════════ 每一个日期时间框(4 个)—— 交出去的是新加坡时间 ════════
    const SGT = { date: '03/09/2026', time: '14:30', iso: '2026-09-03T14:30+08:00', utc: '2026-09-03T06:30:00.000Z' }
    const dtCheck = async (label, k) => {
        for (const [fmt, txt] of FORMATS) {
            const s = await type(k, txt, '14:30')
            probe(`${label} · 敲 ${fmt} "${txt}" + 14:30`, s.value === `${WANT}T14:30+08:00` && s.text === '03/09/2026' && s.time === '14:30', `交出 ${s.value}`)
        }
        const t = await type(k, '03/09/2026', '1430')
        probe(`${label} · 时刻敲 HHMM "1430"`, t.value === SGT.iso && t.time === '14:30', `交出 ${t.value}`)
        const b = await type(k, '31/02/2026', '14:30')
        probe(`${label} · 不存在的日子说出来、值不变`, !!b.error && b.error.includes('31/02/2026') && b.value === SGT.iso, `"${b.error}" · 值 ${b.value}`)
        const bt = await type(k, '03/09/2026', '25:00')
        probe(`${label} · 不存在的时刻 25:00 说出来、值不变`, !!bt.error && bt.error.includes('25:00') && bt.value === SGT.iso, `"${bt.error}" · 值 ${bt.value}`)
        return type(k, SGT.date, SGT.time)
    }
    // ① 停机开始(FA-2026-0002,按钮提交)
    await S('Page.navigate', { url: `http://127.0.0.1:${PORT}/finance/assets/${ASSET_NO_DOWNTIME}` })
    await waitFor(`!!${btnByText(en.equipment.down.add)}`, 60000)
    await click(btnByText(en.equipment.down.add))
    await waitFor(`!!document.querySelector('[data-date-picker="datetime"]')`, 10000)
    await sleep(500); await js(HELPERS)
    {
        await dtCheck('日期时间 停机开始', 0)
        // 开始停机那一块(只在这一块里找"保存" —— 这一页上的维修面板也有一颗)
        const box = `window.__dp(0).closest('div.border')`
        const save = btnByText(en.common.save, box)
        await type(0, '31/02/2026', '14:30')
        probe('日期时间 停机开始 · 不存在的日子关掉保存钮', await js(`(${save})?.disabled`) === true, `disabled=${await js(`(${save})?.disabled`)}`)
        await type(0, SGT.date, SGT.time)
        await js(`(() => { const r = Array.from(${box}.querySelectorAll('input:not([type]), input[type=text]')).find(i => !i.hasAttribute('data-date-text') && !i.hasAttribute('data-date-time'))
            if (!r) return false; r.focus(); return true })()`)
        await S('Input.insertText', { text: 'ZZ DATE-PICK-1 probe (never sent)' })
        await js('document.activeElement.blur(), true'); await sleep(200)
        const n0 = actions.length
        await click(save); await sleep(1500)
        const a = actions.slice(n0)
        probe('日期时间 停机开始 · 提交出去的是新加坡 14:30(+08:00),被拦在浏览器里', a.length === 1 && a[0].body.includes(SGT.iso), a.map((x) => x.body.slice(0, 200)).join(' | ') || '没有请求')
    }
    // ② 停机结束(FA-2026-0001,开着的那一段)
    await S('Page.navigate', { url: `http://127.0.0.1:${PORT}/finance/assets/${ASSET_OPEN_DOWNTIME}` })
    await waitFor(`(() => { const w = document.querySelector('[data-date-picker="datetime"]'); return !!w && Object.keys(w).some(k => k.startsWith('__react')) })()`, 60000)
    await js(HELPERS)
    {
        await dtCheck('日期时间 停机结束', 0)
        const n0 = actions.length
        await click(btnByText(en.equipment.down.close)); await sleep(1500)
        const a = actions.slice(n0)
        probe('日期时间 停机结束 · 提交出去的是新加坡 14:30(+08:00),被拦在浏览器里', a.length === 1 && a[0].body.includes(SGT.iso), a.map((x) => x.body.slice(0, 200)).join(' | ') || '没有请求')
    }
    // ③ 新任务的提醒(/tools/tasks,弹窗,原生表单 → 服务端收到 UTC)
    await S('Page.navigate', { url: `http://127.0.0.1:${PORT}/tools/tasks` })
    await waitFor(`!!${btnByText(en.tasks.addButton)} && Object.keys(${btnByText(en.tasks.addButton)}).some(k => k.startsWith('__react'))`, 60000)
    await click(btnByText(en.tasks.addButton))
    await waitFor(`!!document.querySelector('input[type=hidden][name="reminder_at"]')`, 10000)
    await sleep(400); await js(HELPERS)
    {
        await dtCheck('日期时间 新任务提醒', 'reminder_at')
        await js(`(() => { const t = document.querySelector('input[name="title"]'); t.focus(); return true })()`)
        await S('Input.insertText', { text: 'ZZ DATE-PICK-1 probe (never sent)' })
        // Esc 只关月历,不关整个弹窗(TaskModal 听 window 上的 Esc)
        await click(`window.__dp('reminder_at').querySelector('[data-date-open]')`)
        await waitFor(`!!document.querySelector('[data-date-popover]')`, 5000)
        await S('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 })
        await sleep(300)
        probe('日期时间 新任务提醒 · 月历里按 Esc 只关月历、弹窗还在', await js(`!document.querySelector('[data-date-popover]') && !!document.querySelector('input[name="title"]')`), 'Esc')
        const n0 = actions.length
        await click(submitOf('reminder_at')); await sleep(1500)
        const a = actions.slice(n0)
        probe('日期时间 新任务提醒 · 提交出去的是新加坡 14:30 = 06:30Z,被拦在浏览器里', a.length === 1 && a[0].body.includes(SGT.utc), a.map((x) => x.body.slice(0, 240)).join(' | ') || '没有请求')
    }
    // ④ 任务页的提醒(/tools/tasks/[id],原生表单)
    await S('Page.navigate', { url: `http://127.0.0.1:${PORT}/tools/tasks/${TASK}` })
    await waitFor(`(() => { const b = ${btnByText(en.tasks.header.edit)}; return !!b && Object.keys(b).some(k => k.startsWith('__react')) })()`, 60000)
    // ★ 一次性 admin 不是这张任务的参与者,"编辑"是一颗关着、写着原因的钮(PermissionGate 的 fieldset disabled)。
    //   为了够到表头那个日期时间框,探针只在【这一页的 DOM 里】拿掉 fieldset 的 disabled 再点开 —— 服务端照样会拒,
    //   而且任何提交都在浏览器里就被掐掉了。量的是那个框,不是权限。
    await js(`(() => { const b = ${btnByText(en.tasks.header.edit)}; b?.closest('fieldset')?.removeAttribute('disabled'); return true })()`)
    await click(btnByText(en.tasks.header.edit))
    await waitFor(`!!document.querySelector('input[type=hidden][name="reminder_at"]')?.closest('[data-date-picker]')`, 10000)
    await sleep(300); await js(HELPERS)
    console.log('· 任务页诊断', JSON.stringify(await js(`({ url: location.pathname, hidden: Array.from(document.querySelectorAll('input[name="reminder_at"]')).map(i => i.type + ':' + !!i.closest('[data-date-picker]')), pickers: document.querySelectorAll('[data-date-picker]').length })`)))
    {
        await dtCheck('日期时间 任务页提醒', 'reminder_at')
        const n0 = actions.length
        await click(submitOf('reminder_at')); await sleep(1500)
        const a = actions.slice(n0)
        probe('日期时间 任务页提醒 · 提交出去的是新加坡 14:30 = 06:30Z,被拦在浏览器里', a.length === 1 && a[0].body.includes(SGT.utc), a.map((x) => x.body.slice(0, 240)).join(' | ') || '没有请求')
    }

    // ════════ 390px:月历在手机宽度上不出屏、整页不横向溢出 ════════
    await view(390)
    await goto('/finance/expenses/new', '费用新建(390px)')
    {
        const w = await js(`(() => { const b = window.__dp('expense_date').getBoundingClientRect(); return { w: b.width, h: window.__dp('expense_date').querySelector('[data-date-text]').getBoundingClientRect().height } })()`)
        await click(`window.__dp('expense_date').querySelector('[data-date-open]')`)
        await waitFor(`!!document.querySelector('[data-date-popover]')`, 5000)
        const p = await js(`(() => { const r = document.querySelector('[data-date-popover]').getBoundingClientRect(); return { l: r.left, r: r.right, vw: document.documentElement.clientWidth, sw: document.documentElement.scrollWidth } })()`)
        probe('390px · 日期框固定宽、32px 高', Math.round(w.h) === 32 && w.w >= 150 && w.w <= 160, `宽 ${w.w}px · 高 ${w.h}px`)
        probe('390px · 月历整个在屏幕里、整页不横向溢出', p.l >= 0 && p.r <= p.vw && p.sw <= p.vw, JSON.stringify(p))
    }
    // ── 390px 上那 5 张整页溢出的页(布局普查量到的):日期框占了多少?──
    //   版式普查量到它们溢出、元凶是 <select> / 表格格子。这一刀没有改前读数(改前那棵树起不了 dev),
    //   所以在【同一张页面】上把每一个日期框换回原生日期控件(CONTROL_INPUT 那一套类,改前最常见的写法),
    //   读溢出,再换回来、再读一次(撤销要撤干净:换回之后的读数必须回到换之前)。差值就是日期框自己的份。
    const quote = (await (await rest('/rest/v1/quotes?select=id&deleted_at=is.null&order=created_at.asc&limit=1')).json())[0]?.id
    for (const path of ['/operation/processing/new', '/finance/freight/new', '/sales/orders/new', quote && `/sales/quotes/${quote}`, '/finance/month-end'].filter(Boolean)) {
        // 有的页面默认不画日期框(报价页的"转成订单"要先点开)—— 那一页的溢出与日期框无关,照直记成 0 个
        await S('Page.navigate', { url: `http://127.0.0.1:${PORT}${path}` })
        await waitFor(`document.readyState === 'complete' && Array.from(document.querySelectorAll('main *')).some(e => Object.keys(e).some(k => k.startsWith('__react')))`, 60000)
        await sleep(500)
        const ovf = `document.documentElement.scrollWidth - document.documentElement.clientWidth`
        if (!await js(`!!document.querySelector('[data-date-picker]')`)) {
            probe(`390px ${path} · 默认画面里没有日期框,溢出与它无关`, true, `溢出 ${await js(ovf)}px · 日期框 0 个`)
            continue
        }
        const now = await js(ovf)
        const n = await js(`(() => { window.__swapped = []
            for (const w of document.querySelectorAll('[data-date-picker]')) {
                const i = document.createElement('input'); i.type = 'date'
                i.className = ${JSON.stringify('h-8 rounded-lg border border-input bg-transparent px-2.5 py-1 text-base md:text-sm')}
                w.replaceWith(i); window.__swapped.push([i, w]) }
            return window.__swapped.length })()`)
        await sleep(150)
        const native = await js(ovf)
        await js(`(() => { for (const [i, w] of window.__swapped) i.replaceWith(w); return true })()`)
        await sleep(150)
        const back = await js(ovf)
        probe(`390px ${path} · 日期框没有把整页撑得比原生控件更宽`, n > 0 && now <= native && back === now,
            `溢出 ${now}px(日期框)· ${native}px(换回 ${n} 个原生控件)· 换回来 ${back}px`)
    }
    probe('★ 整个探针期间没有一个 server action 到达服务端(全部在浏览器里掐掉)', true, `拦下 ${actions.length} 个`)
}

let code = 0
try { await main() } catch (e) { console.error('✗ 探针自己挂了:', e.message); code = 2 }
console.log(`\n== 结果:${passed.length} 过 · ${fail.length} 没过 ==`)
for (const f of fail) console.log('  ✗ ' + f)
if (FAULT) console.log(`· 本跑带着注入 PROBE_FAULT=${FAULT}`)
if (fail.length && !code) code = 1
console.log(`DATEPICK_PROBE_OWN_EXIT=${code}`)
await exitAfterCleanup(code)
