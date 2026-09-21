#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// DRAFT-3 的证明 —— #8 `/purchasing/orders/new`(这一刀最重、失去最多的那一张)
//                    + #9 的 `hasFixed`(第一次有人证它)
//                    + IDLE-DRAFT-GRID-HALF-RESTORE 的【第一次实测】
// ════════════════════════════════════════════════════════════════════════════
// ★ 跑在【生产构建】上,等的是**水合收尾**(`__reactFiber$…`)——
//   `next dev` 下这棵树水合不收尾,交互探针量不到点击的结果。
//
// ★★【它一次提交都不发】★★ 判据读的是 `new FormData(form)` —— 那**就是**按下
//   提交会送出去的东西,而读它不写库。于是这支探针**一张采购单都不会建**。
//
// ★★【它证的不是一次红→绿,照直说】★★ 这四张表【从来不在】那条
//   `EDITABLETABLE-NAME-DOUBLE-SUBMIT` 的射程里(DRAFT-2 §1.3),所以今天没有
//   一页是红的。这里证的是**结果**:桥只有一份、带着那个断点上打的字、
//   表外面那些派生读数跟着草稿动、而该按不动的钮真的按不动。
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
const PORT = 3206, CDP_PORT = 9342
const CHROME = join(process.env.HOME, '.cache/puppeteer/chrome-headless-shell/mac_arm-152.0.7977.75/chrome-headless-shell-mac-arm64/chrome-headless-shell')
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
    console.log(`${ok ? '✓' : '✗'} ${id.padEnd(44)} ${detail}`)
}
const note = (id, detail) => console.log(`· ${id.padEnd(44)} ${detail}`)
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
    acquireOrExit('probe-draft3', { ownExit: false })
    openPlan('probe-draft3')
    await reapStalePlans()
    if (!existsSync(join(ROOT, '.next/BUILD_ID'))) throw new Error('.next/BUILD_ID 不在 —— 先 npm run build')
    if (!existsSync(CHROME)) throw new Error('chrome not at ' + CHROME)
    for (const p of [PORT, CDP_PORT]) { try { execSync(`lsof -ti tcp:${p} | xargs -r kill -9`, { stdio: 'ignore' }) } catch {} }

    const email = `draft3probe-${Date.now()}@test.local`
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
    const view = (w) => S('Emulation.setDeviceMetricsOverride',
        { width: w, height: 844, deviceScaleFactor: 1, mobile: w < 700 })
    const goto = async (path, label) => {
        await S('Page.navigate', { url: `http://127.0.0.1:${PORT}${path}` })
        await sleep(800)
        // ★ 等【水合收尾】,不是等服务端那份 HTML 里的元素 —— 判词下在水合之前
        //   就等于在量一棵还没有事件处理器的树(UI-1d fu2 付过这笔账)。
        if (!await waitFor(`(() => { const f = document.querySelector('form')
            return !!f && Object.keys(f).some(k => k.startsWith('__react')) })()`, 60000, label))
            throw new Error(`${label} 水合没完成 —— 判词不可信,不往下量`)
    }

    const T = `[data-slot="editable-table"]`
    // 受控输入:走原生 setter 再派事件,否则 React 收不到。
    const SET = `window.__set = (el, v, kind) => {
        const proto = el.tagName === 'SELECT' ? window.HTMLSelectElement.prototype
            : el.tagName === 'TEXTAREA' ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype
        Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, v)
        el.dispatchEvent(new Event(kind || 'input', { bubbles: true }))
        if (el.tagName === 'SELECT') el.dispatchEvent(new Event('change', { bubbles: true }))
        return true }; true`
    /* ★★ 展开区要按【那一行自己的面板】取控件,不能按「看得见的第 0 个」取 ——
       `page-owned` 下 `open` 是一个【集合】,组件不会在展开第二行时收起第一行
       (那一支没有 `onSave`,所以走不到 `begin()` 那条「至多一个键」的约束)。
       ☞ 第一版探针就是这么把第二行的字打进了第一行:五条判据一起红,
         而红的是探针,不是这棵树。 */
    const PANEL = `window.__panel = (n) => {
        const rows = Array.from(document.querySelectorAll('${T} tbody tr'))
        const dataIdx = rows.map((r, i) => [r, i]).filter(([r]) => r.querySelector('button[aria-expanded]')).map(([, i]) => i)
        const p = rows[dataIdx[n] + 1]
        return (p && !p.querySelector('button[aria-expanded]')) ? p : null }; true`
    const openRow = async (n) => {
        await js(`document.querySelectorAll('${T} button[aria-expanded]')[${n}].click()`)
        await sleep(450)
    }
    /** 第 n 行【自己那块】展开区里看得见的控件。 */
    const inPanel = (n, sel) =>
        `Array.from((window.__panel(${n}) || document.createElement('tr')).querySelectorAll('${sel}')).filter(e => e.offsetParent !== null)`
    /** 第 n 个【数据行】格子里看得见的控件(桌面档就地编辑)。 */
    const inRow = (n, sel) => `(() => {
        const rows = Array.from(document.querySelectorAll('${T} tbody tr')).filter(r => r.querySelector('button[aria-expanded]'))
        return Array.from(rows[${n}].querySelectorAll('${sel}')).filter(e => e.offsetParent !== null) })()`
    const FORM = (key) => `(() => { const f = document.querySelector('form'); const fd = new FormData(f)
        const keys = Array.from(fd.keys())
        let parsed = null
        try { parsed = JSON.parse(String(fd.get('${key}') ?? 'null')) } catch { parsed = 'PARSE_ERROR' }
        return { count: fd.getAll('${key}').length, parsed,
                 currencyKeys: keys.filter(k => k === 'currency'),
                 currencyVal: String(fd.get('currency') ?? '<absent>') } })()`

    // ══════════════════════════════════════════════════════════════════════
    // ARM A · #9 /purchasing/payment-terms/new —— `hasFixed` 决定【另一个字段存不存在】
    //   ☞ 这是第一张【派生值管着一个字段的存在与否】的搬家表。DRAFT-3 的闸轮
    //     把它标成「一次外推,不是一次测量」—— 这一臂就是那次测量。
    // ══════════════════════════════════════════════════════════════════════
    await view(390)
    await goto('/purchasing/payment-terms/new', '#9')
    await js(SET)

    const before9 = await js(`({
        select: !!document.querySelector('select[name="currency"]'),
        hidden: !!document.querySelector('input[type="hidden"][name="currency"]'),
        rows: document.querySelectorAll('${T} tbody tr').length })`)
    probe('#9/390 · 比例模式:币种字段【不存在】,补位的隐藏输入在',
        before9.select === false && before9.hidden === true,
        `<select name=currency> ${before9.select} · <input hidden name=currency> ${before9.hidden}`)

    await js(PANEL)
    await openRow(0)
    const radios = await js(`${inPanel(0, 'input[type=radio]')}.length`)
    probe('#9/390 · 展开区里两颗模式单选都在', radios === 2, `看得见的 radio ${radios} 个`)
    // 第二颗 = 定额
    await js(`(() => { const r = ${inPanel(0, 'input[type=radio]')}[1]; r.click(); return true })()`)
    await sleep(500)
    const after9 = await js(`({
        select: !!document.querySelector('select[name="currency"]'),
        hidden: !!document.querySelector('input[type="hidden"][name="currency"]') })`)
    probe('★★★ #9/390 · 选了定额 → 币种字段【长出来了】,隐藏那个退场',
        after9.select === true && after9.hidden === false,
        `<select name=currency> ${after9.select} · <input hidden name=currency> ${after9.hidden}` +
        ' ← 派生值管着【另一个字段存不存在】,这条今天【量过了】,不再是外推')

    const f9 = await js(FORM('lines_json'))
    probe('#9/390 · 桥只出现一次,而且是一个数组',
        f9.count === 1 && Array.isArray(f9.parsed), `lines_json ${f9.count} 次 · ${JSON.stringify(f9.parsed)}`)
    probe('★ #9/390 · 载荷里【没有 uid】—— 与搬家前逐字节同形',
        Array.isArray(f9.parsed) && f9.parsed.every((l) => !('uid' in l)),
        `键 = ${JSON.stringify(Object.keys(f9.parsed?.[0] ?? {}))}`)
    const named9 = await js(`document.querySelectorAll('${T} [name]').length`)
    probe('#9/390 · 格子里的具名控件 = 0', named9 === 0, `<EditableTable> 里带 name 的控件 ${named9} 个`)
    const ov9 = await js(`({ sw: document.scrollingElement.scrollWidth, cw: document.scrollingElement.clientWidth })`)
    probe('★ #9/390 · 整页横向溢出(搬家前实测 533/390 ——【溢出】)',
        ov9.sw <= ov9.cw + 1, `scrollWidth ${ov9.sw} / clientWidth ${ov9.cw}`)

    // ══════════════════════════════════════════════════════════════════════
    // ARM B · #8 /purchasing/orders/new @390 —— 两期,含一个【条件字段】
    // ══════════════════════════════════════════════════════════════════════
    await goto('/purchasing/orders/new', '#8')
    await js(SET); await js(PANEL)
    const addTerm = `(() => { const b = Array.from(document.querySelectorAll('button')).filter(e => e.offsetParent !== null)
        for (const e of b) { if (/instalment|加一期|增加一期/i.test(e.textContent || '')) { e.click(); return true } }
        return false })()`
    await js(addTerm); await sleep(400); await js(addTerm); await sleep(600)
    const rows8 = await js(`document.querySelectorAll('${T} button[aria-expanded]').length`)
    probe('#8/390 · 加了两期', rows8 === 2, `数据行 ${rows8} 行`)

    // ★ Tim 的 Q1:金额列在手机那一行上【看得见】,零次点按
    const heads8 = await js(`Array.from(document.querySelectorAll('${T} thead th'))
        .filter(e => e.offsetParent !== null).map(e => e.textContent.trim())`)
    probe('★★★ #8/390 · 金额列留在手机那一行上(Tim 的 Q1)',
        heads8.some((h) => /amount|金额/i.test(h)),
        `390px 上看得见的表头 = ${JSON.stringify(heads8)}`)

    // 逐行填:每一行【只在它自己那块展开区里】写
    const fillTerm = async (n, label, pct) => {
        await openRow(n)
        await js(`window.__set(${inPanel(n, 'input[type=text]')}[0], '${label}')`)
        await sleep(300)
        await js(`window.__set(${inPanel(n, 'input[inputmode=decimal]')}[0], '${pct}')`)
        await sleep(400)
    }
    await fillTerm(0, 'Deposit', '60')
    await fillTerm(1, 'Balance', '30')

    // 第二期的触发改成 fixed_date —— 一个【条件字段】
    const hasFixedDate = await js(`(() => { const s = ${inPanel(1, 'select')}[0]
        const o = Array.from(s.options).find(x => x.value === 'fixed_date')
        if (!o) return false
        window.__set(s, 'fixed_date'); return true })()`)
    await sleep(500)
    const dateShown = await js(`${inPanel(1, 'input[type=date]')}.length`)
    probe('★★ #8/390 · 触发改成 fixed_date → 条件日期字段【长出来了】',
        hasFixedDate && dateShown === 1, `fixed_date 选项在=${hasFixedDate} · 第二行展开区里的 date 输入 ${dateShown} 个`)
    await js(`window.__set(${inPanel(1, 'input[type=date]')}[0], '2026-12-31', 'change')`)
    await sleep(500)

    // 表【外面】那个比例合计,跟着草稿动吗
    const pctText = () => js(`Array.from(document.querySelectorAll('p'))
        .filter(e => /text-amber-700|text-red-600/.test(e.className))
        .map(e => e.textContent.trim())`)
    const pct90 = await pctText()
    probe('★★★ #8/390 · 表【外面】的比例合计跟着草稿动(60+30=90)',
        pct90.some((x) => /\b90\b/.test(x)), `合计那一行 = ${JSON.stringify(pct90)}`)

    const f8 = await js(FORM('terms_json'))
    const t0 = f8.parsed?.[0] ?? {}, t1 = f8.parsed?.[1] ?? {}
    probe('★★★ #8/390 · 手机上打的字【到了】桥里,而桥只有一份',
        f8.count === 1 && t0.label === 'Deposit' && t0.percentage === '60'
        && t1.label === 'Balance' && t1.percentage === '30'
        && t1.trigger_event === 'fixed_date' && t1.due_date === '2026-12-31',
        `terms_json ${f8.count} 次 · [0]=${JSON.stringify(t0)} · [1]=${JSON.stringify(t1)}`)
    probe('★ #8/390 · 载荷里【没有 uid】—— 与搬家前逐字节同形',
        Array.isArray(f8.parsed) && f8.parsed.every((l) => !('uid' in l)),
        `键 = ${JSON.stringify(Object.keys(t0))}`)
    const named8 = await js(`document.querySelectorAll('${T} [name]').length`)
    probe('#8/390 · 格子里的具名控件 = 0', named8 === 0, `<EditableTable> 里带 name 的控件 ${named8} 个`)
    const ov8 = await js(`({ sw: document.scrollingElement.scrollWidth, cw: document.scrollingElement.clientWidth })`)
    probe('★ #8/390 · 整页横向溢出(搬家前实测 552/390 ——【溢出】)',
        ov8.sw <= ov8.cw + 1, `scrollWidth ${ov8.sw} / clientWidth ${ov8.cw}`)

    // ★ 提交闸:把第一期推到 90 → 合计 120,那颗钮必须按不动
    const submitState = () => js(`(() => { const b = document.querySelector('form button[type="submit"]')
        return { disabled: !!b?.disabled, text: (b?.textContent || '').trim() } })()`)
    const sBefore = await submitState()
    probe('#8/390 · 合计 90% 时提交钮按得动', sBefore.disabled === false, `disabled=${sBefore.disabled}`)
    await js(`window.__set(${inPanel(0, 'input[inputmode=decimal]')}[0], '90')`)
    await sleep(700)
    const sOver = await submitState()
    const pctOverText = await pctText()
    probe('★★★ #8/390 · 合计推到 120% → 提交钮按不动,而且说出了为什么',
        sOver.disabled === true && pctOverText.some((x) => /120/.test(x)),
        `disabled=${sOver.disabled} · 那一行 = ${JSON.stringify(pctOverText)}`)
    await js(`window.__set(${inPanel(0, 'input[inputmode=decimal]')}[0], '60')`)
    await sleep(700)
    const sBack = await submitState()
    probe('#8/390 · 改回 60% → 钮又按得动了', sBack.disabled === false, `disabled=${sBack.disabled}`)

    // ══════════════════════════════════════════════════════════════════════
    // ARM C · 1280px —— ★【不重新导航】,只改视口:草稿留在原地
    // ══════════════════════════════════════════════════════════════════════
    await view(1280); await sleep(700)
    // ★ `inRow('n', …)` 把下标原样插成标识符 `n`,于是它在这个 map 的闭包里求值。
    const deskLabels = await js(`[0, 1].map((n) => ${inRow('n', 'input[type=text]')}[0]?.value ?? '<none>')`)
    probe('★ 1280 · 390 上打的字出现在【格子里】',
        deskLabels[0] === 'Deposit' && deskLabels[1] === 'Balance',
        `两行格子里的名目 = ${JSON.stringify(deskLabels)}`)
    await js(`window.__set(${inRow(0, 'input[type=text]')}[0], 'Deposit-desktop')`)
    await sleep(700)
    const f8d = await js(FORM('terms_json'))
    probe('★★★ 1280 · 桌面上打的字【到了】桥里,而桥仍然只有一份',
        f8d.count === 1 && f8d.parsed?.[0]?.label === 'Deposit-desktop'
        && f8d.parsed?.[0]?.percentage === '60'
        && f8d.parsed?.[1]?.label === 'Balance' && f8d.parsed?.[1]?.due_date === '2026-12-31',
        `terms_json ${f8d.count} 次 · [0]=${JSON.stringify(f8d.parsed?.[0])} · [1].due_date=${JSON.stringify(f8d.parsed?.[1]?.due_date)}`)
    const ovD = await js(`({ sw: document.scrollingElement.scrollWidth, cw: document.scrollingElement.clientWidth })`)
    probe('1280 · 整页不横向溢出', ovD.sw <= ovD.cw + 1, `scrollWidth ${ovD.sw} / clientWidth ${ovD.cw}`)

    // ══════════════════════════════════════════════════════════════════════
    // ARM D · IDLE-DRAFT-GRID-HALF-RESTORE —— ★ 它至今标着 `NOT MEASURED`
    //   ☞ Tim 的 Q8:探针既然已经在这一页上,就把它量掉。
    //     **量出来是什么就报什么** —— 不复现的话,那比那条修订更值钱。
    // ══════════════════════════════════════════════════════════════════════
    await view(390); await sleep(400)
    // 抬头那个字段也填一个,好分辨「抬头回来了 / 网格没回来」
    await js(`(() => { const el = document.querySelector('input[name="terms_text"]')
        if (!el) return false; window.__set(el, 'DRAFT3-PROBE-HEADER'); return true })()`)
    await sleep(1500)   // useFormDraft 的 800ms 防抖 + 余量
    const saved = await js(`(() => {
        const out = []
        for (const store of [window.localStorage, window.sessionStorage]) {
            for (let i = 0; i < store.length; i++) {
                const k = store.key(i)
                if (!/evoltrya:draft/.test(k)) continue
                let v = null; try { v = JSON.parse(store.getItem(k)) } catch {}
                out.push({ k, where: store === window.localStorage ? 'local' : 'session',
                           terms_json: v?.values?.terms_json ?? '<absent>',
                           terms_text: v?.values?.terms_text ?? '<absent>' })
            }
        }
        return out })()`)
    note('IDLE-DRAFT · 草稿里存下来的', JSON.stringify(saved))
    const entry = saved.find((x) => /orders\/new/.test(x.k)) ?? saved[0]
    const capturedTerms = entry ? JSON.parse(entry.terms_json === '<absent>' ? 'null' : entry.terms_json) : null
    probe('IDLE-DRAFT · 草稿【存】下了 terms_json(它是表单里一个具名隐藏输入)',
        Array.isArray(capturedTerms) && capturedTerms.length === 2,
        `存下来的 terms_json = ${entry?.terms_json?.slice?.(0, 120)}`)

    await goto('/purchasing/orders/new', '#8 重载')
    const banner = await js(`!!document.querySelector('[data-draft="found"]')`)
    probe('IDLE-DRAFT · 重载后出现「发现一份草稿」', banner === true, `[data-draft=found] = ${banner}`)
    await js(`document.querySelector('[data-draft="found"] button').click()`)
    await sleep(900)
    const restored = await js(`(() => {
        const f = document.querySelector('form'); const fd = new FormData(f)
        let terms = null; try { terms = JSON.parse(String(fd.get('terms_json') ?? 'null')) } catch {}
        return { header: String(fd.get('terms_text') ?? '<absent>'),
                 terms, tableRows: document.querySelectorAll('${T} tbody tr').length,
                 restoredBanner: !!document.querySelector('[data-draft="restored"]') } })()`)
    note('IDLE-DRAFT · 恢复之后', JSON.stringify(restored))
    const headerBack = restored.header === 'DRAFT3-PROBE-HEADER'
    const gridBack = Array.isArray(restored.terms) && restored.terms.length === 2
    probe('★★★ IDLE-DRAFT-GRID-HALF-RESTORE —— 【复现】:抬头回来了,那张网格没回来',
        headerBack === true && gridBack === false,
        `抬头字段=${JSON.stringify(restored.header)} · 恢复后的 terms_json=${JSON.stringify(restored.terms)}` +
        ` · 表里的行 ${restored.tableRows} · 「已恢复」横幅=${restored.restoredBanner}` +
        (headerBack && !gridBack ? ' ← 这一条此前标着 NOT MEASURED,现在量过了'
            : ' ← ⚠ 与那条在册的推断【不一致】,照直报,不要悄悄改文档'))
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
    const r = await runPlan(); console.log(`· 清理:${JSON.stringify(r ?? 'ok')}`)
    release()
}
if (fail.length) { console.log(`\n✗ ${fail.length} 条没过:\n  ` + fail.join('\n  ')); code = code || 1 }
else if (code === 0) console.log('\n✓ 全部通过')
console.log(`PROBE_OWN_EXIT=${code}`)
process.exit(code)
