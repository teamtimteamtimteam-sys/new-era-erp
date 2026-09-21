#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// DRAFT-4 的证明 —— 六张搬过来的表 + 委托书点名要补的 `#6` / `#7` 的 390px
// ════════════════════════════════════════════════════════════════════════════
// ★ 跑在【生产构建】上(`next start`),等的是**水合收尾**(`__reactFiber$…`)。
//
// ★★【它一次提交都不发】★★ 判据读的是 `new FormData(form)` —— 那**就是**按下
//   提交会送出去的东西,而读它不写库。**一张单、一份公式、一条行情都不会被建出来。**
//
// ★★★【`#22` 这一臂证的是【结构】,不是那两个触发器 —— 照直说】★★★
//   `SALES-AMEND-DISABLED-ARRAY-SHIFT` 的两个触发器(勾掉一条非末尾的行 /
//   这张单上有已开票的行)**今天在线上都造不出来**:只读普查(2026-09-21)——
//   6 张销售单,draft 两张【都是 0 行】,有行的三张全是 cancelled / shipped,
//   而那两种状态下改单页是 frozen / addonly,勾选框与输入框全禁用。
//   ☞ **委托书禁止建数据,所以那两个触发器标 NOT MEASURED。**
//   ☞ 而 frozen 那张单**恰好是这条结构性质最强的证据**:它的表里
//     **每一个输入框都是 disabled 的**,也就是搬家前 `getAll('line_quantity')`
//     会是**空的**、而 `getAll('line_id')` 有 2 —— **错位的最大值**。
//     今天那座桥照样把两行逐字交出去。**那正是"配对不存在了"的样子。**
//
// ★ 两处在册的探针缺陷都避开(`docs/known-issues.md`):
//   · `PROBE-UNBOUNDED-CDP-WAIT` —— 每一次 CDP 调用带 30s 上限;
//   · `PROBE-LSOF-KILLS-ITSELF` —— 收尾那条 `lsof` 把**本进程**滤掉。
// ★ 逐行判据一律按【那一行自己的面板】取(`window.__panel(n)`)——
//   `page-owned` 下 `open` 是一个集合,展开第二行【不会】收起第一行。
//   DRAFT-3 的第一版探针就是在这里五条一起红,而红的是探针。
// ════════════════════════════════════════════════════════════════════════════
import { readFileSync, existsSync } from 'node:fs'
import { join } from 'node:path'
import { spawn, execSync } from 'node:child_process'
import { createConnection } from 'node:net'
import { acquireOrExit, release } from './liveLock.mjs'
import { openPlan, planDelete, ephemeralGrantBody, runPlan, reapStalePlans, ORDER } from './ephemeral.mjs'

const ROOT = new URL('..', import.meta.url).pathname
const PORT = 3207, CDP_PORT = 9343
const CHROME = join(process.env.HOME, '.cache/puppeteer/chrome-headless-shell/mac_arm-152.0.7977.75/chrome-headless-shell-mac-arm64/chrome-headless-shell')
const env = readFileSync(join(ROOT, '.env.local'), 'utf8')
const URL_ = env.match(/NEXT_PUBLIC_SUPABASE_URL=(\S+)/)[1]
const ANON = env.match(/NEXT_PUBLIC_SUPABASE_ANON_KEY=(\S+)/)[1]
const SERVICE = env.match(/SUPABASE_SERVICE_ROLE_KEY=(\S+)/)[1]

// 只读普查(2026-09-21)挑出来的落点 —— 每一个都写着它为什么是这一个。
const IN_BATCH = 'd719cc6e-3b84-45f3-be3e-a2c0594079e1'   // IN-2026-0152:已录 6 个金属 → 起点含量非空
const OUT_BATCH = '5f1052b0-aade-4553-9b59-343391ab4c7a'  // OUT-2026-0007:已录 2 个金属 → hasCurrent 为真,对照列才画得出来
const SO_FROZEN = '78793903-b8d3-4950-ba2d-4347afdf7fc8'  // SO-2026-0003:cancelled,2 行 → 全禁用,错位的最大值
const SO_DRAFT = '51851df7-c8a9-45db-8c80-ce75a3fcca83'   // ZZ2B-SO1:draft,0 行 → 加行槽可填

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const rest = (p, o = {}) => fetch(URL_ + p, { ...o, headers: {
    apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, 'Content-Type': 'application/json', ...(o.headers || {}) } })
const fail = []
const probe = (id, ok, detail) => {
    if (!ok) fail.push(`${id}: ${detail}`)
    console.log(`${ok ? '✓' : '✗'} ${id.padEnd(52)} ${detail}`)
}
const note = (id, detail) => console.log(`· ${id.padEnd(52)} ${detail}`)
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
    acquireOrExit('probe-draft4', { ownExit: false })
    openPlan('probe-draft4')
    await reapStalePlans()
    if (!existsSync(join(ROOT, '.next/BUILD_ID'))) throw new Error('.next/BUILD_ID 不在 —— 先 npm run build')
    if (!existsSync(CHROME)) throw new Error('chrome not at ' + CHROME)
    for (const p of [PORT, CDP_PORT]) { try { execSync(`lsof -ti tcp:${p} | xargs -r kill -9`, { stdio: 'ignore' }) } catch {} }

    const email = `draft4probe-${Date.now()}@test.local`
    const cu = await (await rest('/auth/v1/admin/users', { method: 'POST',
        body: JSON.stringify({ email, password: 'draft4-probe-1', email_confirm: true }) })).json()
    const accountId = cu.id
    if (!accountId) throw new Error('账号建不出来: ' + JSON.stringify(cu).slice(0, 300))
    planDelete(`/rest/v1/user_roles?user_id=eq.${accountId}`, `revoke grant ${accountId}`, ORDER.GRANT)
    planDelete(`/auth/v1/admin/users/${accountId}`, `delete account ${accountId}`, ORDER.ACCOUNT)
    const roles = await (await rest('/rest/v1/roles?select=id&code=eq.admin')).json()
    await rest('/rest/v1/user_roles', { method: 'POST', body: JSON.stringify(ephemeralGrantBody(accountId, roles[0].id)) })
    const sess = await (await fetch(URL_ + '/auth/v1/token?grant_type=password', { method: 'POST',
        headers: { apikey: ANON, 'Content-Type': 'application/json' },
        body: JSON.stringify({ email, password: 'draft4-probe-1' }) })).json()
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
    /* ★★ 水合判据的【主语】要按页面挑,不能写死 `form`:
       `#6`/`#7` 那个文件**没有 `<form>` 元素**(DRAFT-3 §2.2 —— `createWorkOrder({…})`
       收的是带类型的实参),于是 `querySelector('form')` 永远是 null,
       这条等待会稳稳地超时,**而它报出来的是「水合没完成」** ——
       一次探针缺陷穿着产品缺陷的衣服。照那棵树真正有的东西问。 */
    const goto = async (path, label, anchor = 'form') => {
        await S('Page.navigate', { url: `http://127.0.0.1:${PORT}${path}` })
        await sleep(800)
        if (!await waitFor(`(() => { const f = document.querySelector('${anchor}')
            return !!f && Object.keys(f).some(k => k.startsWith('__react')) })()`, 60000, label))
            throw new Error(`${label} 水合没完成 —— 判词不可信,不往下量`)
    }

    const T = `[data-slot="editable-table"]`
    const SET = `window.__set = (el, v, kind) => {
        const proto = el.tagName === 'SELECT' ? window.HTMLSelectElement.prototype
            : el.tagName === 'TEXTAREA' ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype
        Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, v)
        el.dispatchEvent(new Event(kind || 'input', { bubbles: true }))
        if (el.tagName === 'SELECT') el.dispatchEvent(new Event('change', { bubbles: true }))
        return true }; true`
    /* ★★ 逐行判据按【那一行自己的面板】取 —— 见本文件抬头。 */
    const PANEL = `window.__panel = (t, n) => {
        const tbl = document.querySelectorAll('${T}')[t]
        if (!tbl) return null
        const rows = Array.from(tbl.querySelectorAll('tbody tr'))
        const dataIdx = rows.map((r, i) => [r, i]).filter(([r]) => r.querySelector('button[aria-expanded]')).map(([, i]) => i)
        const p = rows[dataIdx[n] + 1]
        return (p && !p.querySelector('button[aria-expanded]')) ? p : null }; true`
    const openRow = async (t, n) => {
        await js(`document.querySelectorAll('${T}')[${t}].querySelectorAll('button[aria-expanded]')[${n}].click()`)
        await sleep(450)
    }
    const inPanel = (t, n, sel) =>
        `Array.from((window.__panel(${t}, ${n}) || document.createElement('tr')).querySelectorAll('${sel}')).filter(e => e.offsetParent !== null)`
    /** 第 t 张表、第 n 个数据行【自己那一行】格子里看得见的东西。 */
    const inRow = (t, n, sel) => `(() => {
        const rows = Array.from(document.querySelectorAll('${T}')[${t}].querySelectorAll('tbody tr')).filter(r => r.querySelector('button[aria-expanded]'))
        return Array.from(rows[${n}].querySelectorAll('${sel}')).filter(e => e.offsetParent !== null) })()`
    /** 看得见的表头(390px 上还留在那一行里的列)。
     *  ⚠ **这里面有【两列不是数据列】**:手机档最左那一格是组件自己的展开钮
     *  (`!phoneScroll` 时画,`<td className="px-1 … sm:hidden">`),
     *  桌面档最右那一格是动作列(`showActionCol`)——**两者都没有列头**。
     *  ☞ 所以按 `length` 去数列数会把它们数进去。第一版探针四条一起红,
     *    而**红的是探针**:四个读数逐字都是对的,错的是拿来比的那个整数。
     *  ☞ 判据因此只认【有名字的那些列】,组件自己的两格按构造排除在外。 */
    const heads = (t) => `Array.from(document.querySelectorAll('${T}')[${t}].querySelectorAll('thead th'))
        .filter(e => e.offsetParent !== null).map(e => e.textContent.trim())`
    const namedHeads = (t) => `(${heads(t)}).filter(h => h !== '')`
    const bridge = (key) => `(() => { const f = document.querySelector('form'); const fd = new FormData(f)
        let parsed = null
        try { parsed = JSON.parse(String(fd.get('${key}') ?? 'null')) } catch { parsed = 'PARSE_ERROR' }
        return { count: fd.getAll('${key}').length, parsed } })()`
    /** 表【里面】还有没有带 name 的控件 —— (b) 那条裁定的正面证据。 */
    const namedInTables = `Array.from(document.querySelectorAll('${T} [name]')).map(e => e.getAttribute('name'))`
    const overflow = `({ scrollWidth: document.documentElement.scrollWidth,
                         clientWidth: document.documentElement.clientWidth })`

    const ov = async (label) => {
        const o = await js(overflow)
        probe(`${label} · 390px 整页不横向溢出`, o.scrollWidth <= o.clientWidth,
            `scrollWidth ${o.scrollWidth} / clientWidth ${o.clientWidth}`)
        return o
    }

    // ══════════════════════════════════════════════════════════════════════
    // ARM A · #27 /tools/pricing/metal-prices/bulk —— 打一个字,看它到不到桥上
    // ══════════════════════════════════════════════════════════════════════
    await view(390)
    await goto('/tools/pricing/metal-prices/bulk', '#27')
    await js(SET); await js(PANEL)
    note('#27 · 390px 看得见的表头', JSON.stringify(await js(heads(0))))
    const h27 = await js(heads(0))
    note('#27 · 390px 看得见的表头个数', `${h27.length} = ${JSON.stringify(h27)}(两个空的:展开钮那一格 + 参照价列)`)
    // ★ 那两个空表头分别是【展开钮那一格】与【参照价列】—— 空表头认不出谁是谁,
    //   所以这一条改问那一格【自己】:第 0 行最后一格看不看得见、有没有字。
    const ref27 = await js(`(() => {
        const rows = Array.from(document.querySelectorAll('${T}')[0].querySelectorAll('tbody tr'))
            .filter(r => r.querySelector('button[aria-expanded]'))
        const tds = Array.from(rows[0].querySelectorAll('td'))
        const last = tds[tds.length - 1]
        return { visible: last.offsetParent !== null, text: last.textContent.trim(), cells: tds.filter(e => e.offsetParent !== null).length } })()`)
    probe('★★ #27 · 参照价那一格 390px 上看得见、而且有字(Tim 的 Q2)',
        ref27.visible === true && ref27.text.length > 0,
        `看得见 = ${ref27.visible} · 文字 = ${JSON.stringify(ref27.text)} · 那一行看得见 ${ref27.cells} 格`)
    probe('#27 · 格子里没有带 name 的控件', (await js(namedInTables)).length === 0,
        `表里的 name = ${JSON.stringify(await js(namedInTables))}`)
    await openRow(0, 1)
    await js(`(() => { const els = ${inPanel(0, 1, 'input')}; return els.length ? window.__set(els[0], '4321.5') : false })()`)
    await sleep(400)
    const b27 = await js(bridge('metal_prices_json'))
    probe('#27 · 桥只出现一次', b27.count === 1, `metal_prices_json 出现 ${b27.count} 次`)
    const hit27 = Array.isArray(b27.parsed) ? b27.parsed.filter((r) => r.price === '4321.5') : []
    probe('★★ #27 · 手机上打的字【到了桥里,而且只有一份】', hit27.length === 1,
        `price==="4321.5" 的行 ${hit27.length} 条 · 桥上共 ${Array.isArray(b27.parsed) ? b27.parsed.length : '?'} 行` +
        ` · 命中的那一行 = ${JSON.stringify(hit27[0] ?? null)}`)
    probe('#27 · 桥上的键只有 metal / price', Array.isArray(b27.parsed) && b27.parsed.length > 0 &&
        JSON.stringify(Object.keys(b27.parsed[0])) === JSON.stringify(['metal', 'price']),
        `第 0 行的键 = ${JSON.stringify(Object.keys((b27.parsed || [{}])[0]))}`)
    await ov('#27')

    // ══════════════════════════════════════════════════════════════════════
    // ARM B · #26 /tools/pricing/formulas/new —— 空格子写那句话本身(Tim 的 Q3)
    // ══════════════════════════════════════════════════════════════════════
    await goto('/tools/pricing/formulas/new', '#26')
    await js(SET); await js(PANEL)
    const cell26 = await js(`(() => {
        const rows = Array.from(document.querySelectorAll('${T}')[0].querySelectorAll('tbody tr'))
            .filter(r => r.querySelector('button[aria-expanded]'))
        return rows.map(r => Array.from(r.querySelectorAll('td')).map(td => td.textContent.trim())) })()`)
    note('#26 · 前两行的格子文字', JSON.stringify(cell26.slice(0, 2)))
    const flat26 = JSON.stringify(cell26)
    probe('★★ #26 · 空格子写的是【那句话】,不是「—」(Tim 的 Q3)',
        flat26.includes('Not payable') && !flat26.includes('—'),
        `含 "Not payable" = ${flat26.includes('Not payable')} · 含 "—" = ${flat26.includes('—')}`)
    await openRow(0, 0)
    await js(`(() => { const els = ${inPanel(0, 0, 'input')}; return els.length ? window.__set(els[0], '87.5') : false })()`)
    await sleep(400)
    const b26 = await js(bridge('payables_json'))
    probe('#26 · 桥只出现一次', b26.count === 1, `payables_json 出现 ${b26.count} 次`)
    const hit26 = Array.isArray(b26.parsed) ? b26.parsed.filter((r) => r.pct === '87.5') : []
    probe('★ #26 · 打的字到了桥里,而且只有一份', hit26.length === 1,
        `pct==="87.5" 的行 ${hit26.length} 条 · 命中的那一行 = ${JSON.stringify(hit26[0] ?? null)}`)
    probe('#26 · 格子里没有带 name 的控件', (await js(namedInTables)).length === 0,
        `表里的 name = ${JSON.stringify(await js(namedInTables))}`)
    await ov('#26')

    // ══════════════════════════════════════════════════════════════════════
    // ARM C · #18 /inbound/<id>/assays/new —— 身份列 priority(Tim 的 Q1)
    // ══════════════════════════════════════════════════════════════════════
    await goto(`/inbound/${IN_BATCH}/assays/new`, '#18')
    await js(SET); await js(PANEL)
    const h18 = await js(heads(0)), n18 = await js(namedHeads(0))
    probe('#18 · 金属名列【留在 390px 那一行上】(Tim 的 Q1)',
        JSON.stringify(n18) === JSON.stringify(['Metal']),
        `有名字的列 = ${JSON.stringify(n18)} · 连组件自己那格展开钮一共 ${h18.length} 格`)
    const b18 = await js(bridge('assay_metals_json'))
    probe('#18 · 桥只出现一次', b18.count === 1, `assay_metals_json 出现 ${b18.count} 次`)
    probe('★★ #18 · 桥上的行数 = 页面画出来的【active】行数,不是整个 Record',
        Array.isArray(b18.parsed) && b18.parsed.length === (await js(`document.querySelectorAll('${T}')[0].querySelectorAll('tbody tr button[aria-expanded]').length`)),
        `桥 ${Array.isArray(b18.parsed) ? b18.parsed.length : '?'} 行 · 表里 ${await js(`document.querySelectorAll('${T}')[0].querySelectorAll('tbody tr button[aria-expanded]').length`)} 行`)
    note('#18 · 桥上第 0 行', JSON.stringify((b18.parsed || [null])[0]))
    probe('#18 · 格子里没有带 name 的控件', (await js(namedInTables)).length === 0,
        `表里的 name = ${JSON.stringify(await js(namedInTables))}`)
    await ov('#18')

    // ══════════════════════════════════════════════════════════════════════
    // ARM D · #20 /output/<id>/assays/new —— 对照列不许在 390px 上消失(Q2)
    // ══════════════════════════════════════════════════════════════════════
    await goto(`/output/${OUT_BATCH}/assays/new`, '#20')
    await js(SET); await js(PANEL)
    const h20 = await js(heads(0))
    probe('★★★ #20 · 对照列【留在 390px 那一行上】(Tim 的 Q2)',
        h20.length === 3, `看得见的表头 ${h20.length} 列 = ${JSON.stringify(h20)}`)
    const cur20 = await js(`(() => {
        const rows = Array.from(document.querySelectorAll('${T}')[0].querySelectorAll('tbody tr'))
            .filter(r => r.querySelector('button[aria-expanded]'))
        return rows.map(r => { const tds = Array.from(r.querySelectorAll('td')); return tds[tds.length - 1].textContent.trim() }) })()`)
    note('#20 · 每一行的对照值', JSON.stringify(cur20))
    probe('★ #20 · 对照列真的有数,不是空的', cur20.some((v) => /%$/.test(v)),
        `带 % 的行 ${cur20.filter((v) => /%$/.test(v)).length} 条 · 「—」${cur20.filter((v) => v === '—').length} 条(真的没录过,这里的「—」是对的)`)
    const b20 = await js(bridge('assay_metals_json'))
    probe('#20 · 桥只出现一次', b20.count === 1, `assay_metals_json 出现 ${b20.count} 次`)
    probe('#20 · 桥上的键只有 metal / content', Array.isArray(b20.parsed) && b20.parsed.length > 0 &&
        JSON.stringify(Object.keys(b20.parsed[0])) === JSON.stringify(['metal', 'content']),
        `第 0 行的键 = ${JSON.stringify(Object.keys((b20.parsed || [{}])[0]))} ← 对照值【不进桥】`)
    probe('#20 · 格子里没有带 name 的控件', (await js(namedInTables)).length === 0,
        `表里的 name = ${JSON.stringify(await js(namedInTables))}`)
    await ov('#20')

    // ══════════════════════════════════════════════════════════════════════
    // ARM E · #22 /sales/orders/<frozen>/amend —— 结构性证据(见本文件抬头)
    // ══════════════════════════════════════════════════════════════════════
    await goto(`/sales/orders/${SO_FROZEN}/amend`, '#22 frozen')
    await js(SET); await js(PANEL)
    const tables22 = await js(`document.querySelectorAll('${T}').length`)
    note('#22 · 这一页上的 EditableTable 数', `${tables22}(frozen 时加行那一张不渲染)`)
    const h22 = await js(heads(0)), n22 = await js(namedHeads(0))
    probe('#22 · 390px 上留下的列 = 序号 + 物料', JSON.stringify(n22) === JSON.stringify(['#', 'Material']),
        `有名字的列 = ${JSON.stringify(n22)} · 连展开钮那格一共 ${h22.length} 格`)
    const disabled22 = await js(`(() => {
        const t = document.querySelectorAll('${T}')[0]
        const all = Array.from(t.querySelectorAll('input'))
        return { total: all.length, disabled: all.filter(e => e.disabled).length } })()`)
    note('#22 · 表里的输入框', JSON.stringify(disabled22))
    const b22 = await js(bridge('lines_json'))
    probe('#22 · 桥只出现一次', b22.count === 1, `lines_json 出现 ${b22.count} 次`)
    probe('★★★ #22 · 【每一个输入框都禁用着,而两行照样逐字交出去】—— 那个按下标的配对不存在了',
        Array.isArray(b22.parsed) && b22.parsed.length === 2 &&
        b22.parsed[0].quantity === '10' && b22.parsed[0].unit_price === '10' &&
        b22.parsed[1].quantity === '20' && b22.parsed[1].unit_price === '5',
        `桥 = ${JSON.stringify(b22.parsed)} ← 搬家前 getAll('line_quantity') 在这里会是【空的】` +
        `,而 getAll('line_id') 有 2 —— 错位的最大值`)
    probe('★ #22 · 载荷带着 line_no(于是那句拒绝点的是行号,不是 UUID)',
        Array.isArray(b22.parsed) && b22.parsed.every((r) => typeof r.line_no === 'number' && r.line_no > 0),
        `line_no = ${JSON.stringify((b22.parsed || []).map((r) => r.line_no))}`)
    probe('★ #22 · 每一行只出现一次(按 id 去重)',
        Array.isArray(b22.parsed) && new Set(b22.parsed.map((r) => r.id)).size === b22.parsed.length,
        `id 去重后 ${Array.isArray(b22.parsed) ? new Set(b22.parsed.map((r) => r.id)).size : '?'} 个 / 共 ${Array.isArray(b22.parsed) ? b22.parsed.length : '?'} 行`)
    probe('★ #22 · unit_price 这个【键】每一行都在(键在不在是承重的)',
        Array.isArray(b22.parsed) && b22.parsed.every((r) => Object.prototype.hasOwnProperty.call(r, 'unit_price')),
        `每行的键 = ${JSON.stringify((b22.parsed || [{}]).map((r) => Object.keys(r)))}`)
    // ★★ 三列只读的数:390px 上【零次点按】看得见(Tim 的 Q2 —— 叠在物料那一格里)
    const stack22 = await js(`(() => {
        const rows = Array.from(document.querySelectorAll('${T}')[0].querySelectorAll('tbody tr'))
            .filter(r => r.querySelector('button[aria-expanded]'))
        return rows.map(r => { const d = r.querySelector('div.sm\\\\:hidden')
            return d && d.offsetParent !== null ? d.textContent.replace(/\\s+/g, ' ').trim() : null }) })()`)
    note('#22 · 物料格里那块叠加块(390px)', JSON.stringify(stack22))
    probe('★★★ #22 · 已开票/已预留/已发【零次点按】看得见(Tim 的 Q2)',
        stack22.every((s) => typeof s === 'string' && s.length > 0),
        `两行各自的叠加块 = ${JSON.stringify(stack22)}`)
    probe('#22 · 格子里没有带 name 的控件', (await js(namedInTables)).length === 0,
        `表里的 name = ${JSON.stringify(await js(namedInTables))}`)
    // ★★ Q7:移除勾选在【展开区】里,不在那一行上
    const removeInRow = await js(inRow(0, 0, 'input[type="checkbox"]') + '.length')
    await openRow(0, 0)
    const removeInPanel0 = await js(inPanel(0, 0, 'input[type="checkbox"]') + '.length')
    probe('★★★ #22 · 移除勾选在【展开区】里,不在 390px 那一行上(Tim 的 Q7)',
        removeInRow === 0 && removeInPanel0 === 1,
        `行里 ${removeInRow} 个 · 第 0 行自己那块展开区里 ${removeInPanel0} 个 ← 0 → 1 次点按,有意的回退`)
    // ★ 展开第 1 行【不会】收起第 0 行 —— 逐行判据必须各认各的面板
    await openRow(0, 1)
    const p0 = await js(`!!window.__panel(0, 0)`), p1 = await js(`!!window.__panel(0, 1)`)
    probe('★ #22 · 展开第 1 行之后第 0 行【仍然开着】(判据必须各认各的面板)',
        p0 === true && p1 === true, `第 0 行的面板 ${p0} · 第 1 行的面板 ${p1}`)
    await ov('#22 frozen')

    // ══════════════════════════════════════════════════════════════════════
    // ARM F · #23 /sales/orders/<draft>/amend —— 加行槽:填一个,看它能不能
    //          与既有行分得开(服务端靠 material_id / id 哪一个在分辨)
    // ══════════════════════════════════════════════════════════════════════
    await goto(`/sales/orders/${SO_DRAFT}/amend`, '#23 draft')
    await js(SET); await js(PANEL)
    const tables23 = await js(`document.querySelectorAll('${T}').length`)
    note('#23 · 这一页上的 EditableTable 数', `${tables23}(既有行 0 条 + 加行槽 3 条)`)
    const newTable = tables23 - 1
    const h23 = await js(heads(newTable)), n23 = await js(namedHeads(newTable))
    probe('#23 · 加行表 390px 上留下序号列(三个空槽认得出是哪一个)',
        JSON.stringify(n23) === JSON.stringify(['#']),
        `有名字的列 = ${JSON.stringify(n23)} · 连展开钮那格一共 ${h23.length} 格`)
    await openRow(newTable, 1)
    const filled = await js(`(() => {
        const p = window.__panel(${newTable}, 1); if (!p) return 'no panel'
        const sel = p.querySelector('select'); const nums = Array.from(p.querySelectorAll('input[type="number"]'))
        if (!sel || nums.length < 2) return 'controls missing: sel=' + !!sel + ' nums=' + nums.length
        const opt = Array.from(sel.options).find(o => o.value)
        if (!opt) return 'no material option'
        window.__set(sel, opt.value, 'change'); window.__set(nums[0], '7'); window.__set(nums[1], '99.5')
        return opt.value })()`)
    note('#23 · 填进第 1 槽的物料 id', String(filled))
    await sleep(450)
    const b23 = await js(bridge('new_lines_json'))
    const b23e = await js(bridge('lines_json'))
    probe('#23 · 加行那座桥只出现一次', b23.count === 1, `new_lines_json 出现 ${b23.count} 次`)
    probe('#23 · 既有行那座桥也只出现一次,而且是空的(这张单 0 行)',
        b23e.count === 1 && Array.isArray(b23e.parsed) && b23e.parsed.length === 0,
        `lines_json 出现 ${b23e.count} 次 · = ${JSON.stringify(b23e.parsed)}`)
    const slotHit = Array.isArray(b23.parsed) ? b23.parsed.filter((r) => r.quantity === '7' && r.unit_price === '99.5') : []
    probe('★★ #23 · 手机上填的那一槽【到了桥里,而且只有一份】', slotHit.length === 1,
        `命中 ${slotHit.length} 条 · = ${JSON.stringify(slotHit[0] ?? null)} · 桥上共 ${Array.isArray(b23.parsed) ? b23.parsed.length : '?'} 槽`)
    probe('★★★ #23 · 加行与既有行【分得开】:加行带 material_id、不带 id',
        slotHit.length === 1 && !!slotHit[0].material_id && !Object.prototype.hasOwnProperty.call(slotHit[0], 'id'),
        `material_id = ${slotHit[0]?.material_id ?? '<absent>'} · 有 id 这个键吗 = ${slotHit[0] ? Object.prototype.hasOwnProperty.call(slotHit[0], 'id') : '?'}` +
        ` ← amend_sales_order.sql:100/:132 就是按这个分岔的`)
    probe('★ #23 · 另外两个空槽照旧是空的(服务端整槽跳过)',
        Array.isArray(b23.parsed) && b23.parsed.filter((r) => !r.material_id && !r.quantity && !r.unit_price).length === 2,
        `全空的槽 ${Array.isArray(b23.parsed) ? b23.parsed.filter((r) => !r.material_id && !r.quantity && !r.unit_price).length : '?'} 个`)
    probe('#23 · 格子里没有带 name 的控件', (await js(namedInTables)).length === 0,
        `表里的 name = ${JSON.stringify(await js(namedInTables))}`)
    await ov('#23 draft')

    // 1280:桌面那一档,同一个 store
    await view(1280)
    await goto(`/sales/orders/${SO_FROZEN}/amend`, '#22 @1280')
    await js(SET); await js(PANEL)
    const h22d = await js(heads(0)), n22d = await js(namedHeads(0))
    probe('★★ #22 @1280 · 桌面照旧七列有名字 + 一条动作列 —— 三列只读的数仍然是【列】',
        JSON.stringify(n22d) === JSON.stringify(['#', 'Material', 'Ordered', 'Invoiced', 'Reserved', 'Shipped', 'Unit price (SGD)']) &&
        h22d.length === 8,
        `有名字的列 = ${JSON.stringify(n22d)} · 连动作列那格空表头一共 ${h22d.length} 格` +
        ` ← 搬家前也是八格(最后那一格是移除列),列数逐字未变`)
    const b22d = await js(bridge('lines_json'))
    probe('★ #22 @1280 · 桥仍然只有一份,内容与 390px 逐字相同',
        b22d.count === 1 && JSON.stringify(b22d.parsed) === JSON.stringify(b22.parsed),
        `lines_json 出现 ${b22d.count} 次 · 与 390px 的载荷相同 = ${JSON.stringify(b22d.parsed) === JSON.stringify(b22.parsed)}`)
    const o1280 = await js(overflow)
    probe('#22 @1280 · 整页不横向溢出', o1280.scrollWidth <= o1280.clientWidth,
        `scrollWidth ${o1280.scrollWidth} / clientWidth ${o1280.clientWidth}`)

    // ══════════════════════════════════════════════════════════════════════
    // ARM G · #6 / #7 /operation/orders/new —— 委托书点名要补的那一次 390px
    //   ☞ DRAFT-3 §4.3 ①:它们【搬家前后都没有量过】。
    // ══════════════════════════════════════════════════════════════════════
    await view(390)
    // ★ 这一页没有 <form>,锚点改成组件自己的展开钮。
    await goto('/operation/orders/new', '#6/#7', '[data-slot="editable-table"] button[aria-expanded]')
    await js(SET); await js(PANEL)
    const n67 = await js(`document.querySelectorAll('${T}').length`)
    probe('#6/#7 · 这一页上两张 EditableTable 都在', n67 === 2, `EditableTable ${n67} 张`)
    const h6 = await js(heads(0)), h7 = await js(heads(1))
    const n6 = await js(namedHeads(0)), n7 = await js(namedHeads(1))
    note('#6 · 390px 看得见的表头', `${JSON.stringify(h6)} → 有名字的 ${JSON.stringify(n6)}`)
    note('#7 · 390px 看得见的表头', `${JSON.stringify(h7)} → 有名字的 ${JSON.stringify(n7)}`)
    probe('★ #6 · 390px 上留下序号列(五个空槽认得出是哪一个)', n6[0] === '#', `有名字的列 = ${JSON.stringify(n6)}`)
    probe('★ #7 · 390px 上留下序号列(三个空槽认得出是哪一个)', n7[0] === '#', `有名字的列 = ${JSON.stringify(n7)}`)
    const rows67 = await js(`Array.from(document.querySelectorAll('${T}')).map(t =>
        t.querySelectorAll('tbody tr button[aria-expanded]').length)`)
    probe('★ #6 / #7 · 定长空槽 5 / 3(不加行不删行,所以下标就是稳定的键)',
        JSON.stringify(rows67) === JSON.stringify([5, 3]), `行数 = ${JSON.stringify(rows67)}`)
    probe('#6/#7 · 这个文件里没有 <form>,所以一座桥都没有(DRAFT-3 §2.2)',
        (await js(namedInTables)).length === 0, `表里的 name = ${JSON.stringify(await js(namedInTables))}`)
    await openRow(0, 2)
    const p62 = await js(inPanel(0, 2, 'select, input') + '.length')
    probe('★ #6 · 第 2 行自己那块展开区里有它自己的控件', p62 >= 1,
        `第 2 行面板里看得见的控件 ${p62} 个`)
    await openRow(1, 0)
    const stillOpen = await js(`!!window.__panel(0, 2)`)
    probe('★ #6/#7 · 展开第二张表的行,第一张表那一行【仍然开着】(各认各的面板)',
        stillOpen === true, `#6 的第 2 行面板还在 = ${stillOpen}`)
    const o67 = await js(overflow)
    probe('★★★ #6/#7 · 390px 整页不横向溢出 —— 【第一次有人看见它们在手机上的样子】',
        o67.scrollWidth <= o67.clientWidth,
        `scrollWidth ${o67.scrollWidth} / clientWidth ${o67.clientWidth} ← DRAFT-3 §4.3 ① 那处 NOT MEASURED,今天还上了`)
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
