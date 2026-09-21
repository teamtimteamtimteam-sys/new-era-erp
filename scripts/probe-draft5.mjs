#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// DRAFT-5 的证明 —— 本刀搬的六张:#25 · #13 · #12 · #14 · #15 / #16
// ════════════════════════════════════════════════════════════════════════════
// ★ 跑在【生产构建】上(`next start`),等的是**水合收尾**(`__reactFiber$…`)。
//
// ★★【它一次提交都不发】★★ 判据读的是 `new FormData(form)` —— 那**就是**按下
//   提交会送出去的东西,而读它不写库。**一张发票、一笔付款、一张运费单
//   都不会被建出来**;计价器那一页连写的路都没有。
//
// ★★★【重点臂是 `#15`/`#16`】★★★ 它是本刀最重的一张,而它要证的那件事很具体:
//   两张表**同时渲染**、搬家前**共用三条并列数组**,而服务端逐行读的是
//   `allocKinds[i]` —— **按 kind 分辨,不按位置**。
//   ☞ 所以判据是:**两张表各填一格 → 两座桥各带一行 → 每一行的 `kind` 正确**,
//     而不是「顺序对不对」。顺序在这条路上从来不是判据,那正是它能分成两座的理由。
//
// ★ 两处在册的探针缺陷都避开(`docs/known-issues.md`):
//   · `PROBE-UNBOUNDED-CDP-WAIT` —— 每一次 CDP 调用带 30s 上限;
//   · `PROBE-LSOF-KILLS-ITSELF` —— 收尾那条 `lsof` 把**本进程**滤掉。
// ★ 逐行判据一律按【那一行自己的面板】取(`window.__panel(t, n)`)——
//   `page-owned` 下 `open` 是一个集合,展开第二行【不会】收起第一行。
// ★ 表头计数只认【有名字的列】:手机档最左那格是组件自己的展开钮、
//   桌面档最右那格是动作列,**两者都没有列头**。DRAFT-4 在这里四条一起红过,
//   而红的是探针 —— 四个读数逐字都是对的,错的是拿来比的那个整数。
// ════════════════════════════════════════════════════════════════════════════
import { readFileSync, existsSync } from 'node:fs'
import { join } from 'node:path'
import { spawn, execSync } from 'node:child_process'
import { createConnection } from 'node:net'
import { acquireOrExit, release } from './liveLock.mjs'
import { openPlan, planDelete, ephemeralGrantBody, runPlan, reapStalePlans, ORDER } from './ephemeral.mjs'

const ROOT = new URL('..', import.meta.url).pathname
const PORT = 3208, CDP_PORT = 9344
const CHROME = join(process.env.HOME, '.cache/puppeteer/chrome-headless-shell/mac_arm-152.0.7977.75/chrome-headless-shell-mac-arm64/chrome-headless-shell')
const env = readFileSync(join(ROOT, '.env.local'), 'utf8')
const URL_ = env.match(/NEXT_PUBLIC_SUPABASE_URL=(\S+)/)[1]
const ANON = env.match(/NEXT_PUBLIC_SUPABASE_ANON_KEY=(\S+)/)[1]
const SERVICE = env.match(/SUPABASE_SERVICE_ROLE_KEY=(\S+)/)[1]

// 只读普查(2026-09-21,一次写都没发)挑出来的落点 —— 每一个都写着它为什么是这一个。
// ⚠ **这个落点换过一次,而换的理由要记下来:** 第一版挑的是 `INV-2026-0004`
// (issued,1 行),而它的 `kind` 是 `sale` —— 屏幕上回的是
// 「Credit notes apply to order-flow invoices only」。
// ☞ **那是第【五】道闸,而我只枚举了 `CreditNoteSection.tsx:144-155` 的四道** ——
//   一次「我把分支数全了」的假设,漏掉了它上面那一层。照直记。
const INVOICE_ID = 'b82d06cf-fc0b-4233-9aba-44ba5e895190'   // INV-2026-0007:kind='order' 且 issued → 全树唯一一张
const CUSTOMER_ID = 'fdfefcd3-d313-4314-b8fc-b6e0fc96afab'  // ST Engineering:1 张待开票销售 → #14 的表画得出来
const SUPPLIER_ID = '6fd51aec-177d-4912-9973-7c195a3fc87a'  // Acme:2 张在途采购单 → #15 与 #16 【同时】渲染

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
    acquireOrExit('probe-draft5', { ownExit: false })
    openPlan('probe-draft5')
    await reapStalePlans()
    if (!existsSync(join(ROOT, '.next/BUILD_ID'))) throw new Error('.next/BUILD_ID 不在 —— 先 npm run build')
    if (!existsSync(CHROME)) throw new Error('chrome not at ' + CHROME)
    for (const p of [PORT, CDP_PORT]) { try { execSync(`lsof -ti tcp:${p} | xargs -r kill -9`, { stdio: 'ignore' }) } catch {} }

    const email = `draft5probe-${Date.now()}@test.local`
    const cu = await (await rest('/auth/v1/admin/users', { method: 'POST',
        body: JSON.stringify({ email, password: 'draft5-probe-1', email_confirm: true }) })).json()
    const accountId = cu.id
    if (!accountId) throw new Error('账号建不出来: ' + JSON.stringify(cu).slice(0, 300))
    planDelete(`/rest/v1/user_roles?user_id=eq.${accountId}`, `revoke grant ${accountId}`, ORDER.GRANT)
    planDelete(`/auth/v1/admin/users/${accountId}`, `delete account ${accountId}`, ORDER.ACCOUNT)
    const roles = await (await rest('/rest/v1/roles?select=id&code=eq.admin')).json()
    await rest('/rest/v1/user_roles', { method: 'POST', body: JSON.stringify(ephemeralGrantBody(accountId, roles[0].id)) })
    const sess = await (await fetch(URL_ + '/auth/v1/token?grant_type=password', { method: 'POST',
        headers: { apikey: ANON, 'Content-Type': 'application/json' },
        body: JSON.stringify({ email, password: 'draft5-probe-1' }) })).json()
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
    /* ★ PROBE-UNBOUNDED-CDP-WAIT:每一次调用都有上限。
       ⚠ **而上限要从实测成本推出来,不是挑一个整数**(AGENTS.md 那条):
       `Page.navigate` 到一页要打好几次库的详情页,实测**同一天里一次 <30s、
       一次 >30s** —— 30 秒的通用上限因此会把一次【本来会成功的】导航变成误杀,
       而误杀留下的日志与真失败长得一模一样。
       ☞ 导航单独给 120s(实测最慢的一次约 30s,取 4 倍余量);
         其余调用照旧 30s —— 它们是本地求值,不打库。 */
    const NAV_TIMEOUT = 120000, CDP_TIMEOUT = 30000
    const send = (method, params = {}, sessionId) => new Promise((res, rej) => {
        const id = ++msgId
        const ms = method === 'Page.navigate' ? NAV_TIMEOUT : CDP_TIMEOUT
        const timer = setTimeout(() => { if (pending.delete(id)) rej(new Error(`CDP 超时(${ms / 1000}s):${method}`)) }, ms)
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
    // ARM A · #25 /tools/pricing/calculator —— #18 的孪生,而它【不写库】
    // ══════════════════════════════════════════════════════════════════════
    await view(390)
    await goto('/tools/pricing/calculator', '#25')
    await js(SET); await js(PANEL)
    const n25 = await js(namedHeads(0))
    probe('#25 · 金属名列【留在 390px 那一行上】(Q1)',
        JSON.stringify(n25) === JSON.stringify(['Metal']), `有名字的列 = ${JSON.stringify(n25)}`)
    probe('#25 · 格子里没有带 name 的控件', (await js(namedInTables)).length === 0,
        `表里的 name = ${JSON.stringify(await js(namedInTables))}`)
    await openRow(0, 1)
    await js(`(() => { const els = ${inPanel(0, 1, 'input')}; return els.length ? window.__set(els[0], '33.25') : false })()`)
    await sleep(400)
    const b25 = await js(bridge('assay_metals_json'))
    probe('#25 · 桥只出现一次', b25.count === 1, `assay_metals_json 出现 ${b25.count} 次`)
    const hit25 = Array.isArray(b25.parsed) ? b25.parsed.filter((r) => r.content === '33.25') : []
    probe('★★ #25 · 手机上打的字【到了桥里,而且只有一份】', hit25.length === 1,
        `命中 ${hit25.length} 条 · = ${JSON.stringify(hit25[0] ?? null)} · 桥上共 ${Array.isArray(b25.parsed) ? b25.parsed.length : '?'} 行`)
    probe('#25 · 桥上的键只有 metal / content', Array.isArray(b25.parsed) && b25.parsed.length > 0 &&
        JSON.stringify(Object.keys(b25.parsed[0])) === JSON.stringify(['metal', 'content']),
        `第 0 行的键 = ${JSON.stringify(Object.keys((b25.parsed || [{}])[0]))}`)
    await ov('#25')

    // ══════════════════════════════════════════════════════════════════════
    // ARM B · #13 /finance/invoices/<id> —— 贷项凭证那张表
    //   ⚠ 落点是**全树唯一一张** `kind='order'` 且 `issued` 的发票(见上面的常量)。
    // ══════════════════════════════════════════════════════════════════════
    await goto(`/finance/invoices/${INVOICE_ID}`, '#13 发票页', 'main, body')
    await js(SET)
    /* ⚠ 判据要认【具体是哪一条】,不许用一个松正则去碰运气:
       「开不了」有**五**条路,各指一个不同的下一步 ——
       `CreditNoteSection.tsx:144-155` 的四条(作废 / 没权限 / 已结清 / 看不到发货),
       **外加它上面那一层:非订单流发票根本没有这块**。
       ★ 第一版判据只枚举了四条,于是命中 0 条、报了一句说不清楚的 NOT MEASURED ——
         **一个说不出自己抓到了什么的判据,会让人再跑一遍去问它。** */
    const st13 = await js(`(() => {
        const txt = document.body.innerText
        const reasons = {
            void: txt.includes('there is nothing left to credit'),
            fullySettled: txt.includes('This invoice has nothing open'),
            needsFinanceEdit: txt.includes('it posts to the ledger'),
            needsSalesView: txt.includes('the form is withheld'),
        }
        return { tables: document.querySelectorAll('${T}').length,
                 reasons,
                 which: Object.keys(reasons).filter(k => reasons[k]),
                 hasCreateBtn: Array.from(document.querySelectorAll('button')).some(b => /credit note|贷项/i.test(b.textContent || '')),
                 crashed: /Application error|Unhandled/i.test(txt) } })()`)
    note('#13 · 发票页读数', JSON.stringify(st13))
    probe('#13 · 这条路由画得出来,没有崩',
        st13.crashed === false, `页面上没有 Application error = ${!st13.crashed}`)
    // 控件开局是收起来的(`open=false`),先点开那颗「Raise a credit note」。
    const opened13 = await js(`(() => {
        const b = Array.from(document.querySelectorAll('button'))
            .find((x) => /raise a credit note|贷项/i.test(x.textContent || ''))
        if (!b) return false
        b.click(); return true })()`)
    note('#13 · 点开那颗「新建贷项凭证」', String(opened13))
    await sleep(900)
    const st13b = await js(`document.querySelectorAll('${T}').length`)
    probe('★★ #13 · 那张表在浏览器里画出来了(全树唯一一张订单流 + 已签发的发票)',
        st13b === 1,
        `点开之后 EditableTable ${st13b} 张 · 「新建」钮 = ${st13.hasCreateBtn}` +
        ` · 五条「开不了」命中 ${JSON.stringify(st13.which)}(空 = 一条都没挡住)`)
    await js(PANEL)
    const n13 = await js(namedHeads(0))
    note('#13 · 390px 有名字的列', JSON.stringify(n13))
    const stack13 = await js(`(() => {
        const rows = Array.from(document.querySelectorAll('${T}')[0].querySelectorAll('tbody tr'))
            .filter(r => r.querySelector('button[aria-expanded]'))
        return rows.map(r => { const d = r.querySelector('div[class*="sm:hidden"]')
            return d && d.offsetParent !== null ? d.textContent.replace(/\s+/g, ' ').trim() : null }) })()`)
    probe('★★ #13 · 两列只读的数【零次点按】看得见(Q2)',
        stack13.every((s) => typeof s === 'string' && s.length > 0),
        `叠加块 = ${JSON.stringify(stack13)}`)
    await openRow(0, 0)
    const kindInPanel = await js(inPanel(0, 0, 'select') + '.length')
    probe('★ #13 · 类型下拉在【展开区】里(0 → 1 次点按,旧注释说「换得起」)',
        kindInPanel === 1, `第 0 行自己那块展开区里的 select ${kindInPanel} 个`)
    await js(`(() => { const els = ${inPanel(0, 0, 'input[type="number"]')}
        if (els.length < 2) return 'need 2, got ' + els.length
        window.__set(els[0], '3'); window.__set(els[1], '12.5'); return true })()`)
    await sleep(500)
    const b13 = await js(bridge('cn_lines_json'))
    probe('#13 · 桥只出现一次', b13.count === 1, `cn_lines_json 出现 ${b13.count} 次`)
    const hit13 = Array.isArray(b13.parsed) ? b13.parsed.filter((r) => r.amount === '12.5') : []
    probe('★★ #13 · 手机上打的字到了桥里,只有一份', hit13.length === 1,
        `命中 ${hit13.length} 条 · = ${JSON.stringify(hit13[0] ?? null)}`)
    probe('★★★ #13 · `qty` 与 `kind` 都在那一行里(服务端判的是【键在不在】)',
        hit13.length === 1 && hit13[0].qty === '3' && !!hit13[0].kind,
        `qty = ${JSON.stringify(hit13[0]?.qty)} · kind = ${JSON.stringify(hit13[0]?.kind)}`)
    probe('#13 · 格子里没有带 name 的控件', (await js(namedInTables)).length === 0,
        `表里的 name = ${JSON.stringify(await js(namedInTables))}`)
    await ov('#13')

    // ══════════════════════════════════════════════════════════════════════
    // ARM C · #12 /finance/freight/new —— 勾选框就是可编辑列 + 条件列
    // ══════════════════════════════════════════════════════════════════════
    await goto('/finance/freight/new', '#12')
    await js(SET); await js(PANEL)
    const n12a = await js(namedHeads(0))
    note('#12 · 4 列那一支(weight)有名字的列', JSON.stringify(n12a))
    probe('★★ #12 · 四列那一支【也有一列可编辑】—— 勾选框(Q2)',
        (await js(`document.querySelectorAll('${T}').length`)) === 1,
        `表画出来了 = true ← EditableTable 对「一列都不可编辑」是按名拒绝的,画得出来就说明那一列成立`)
    // 切到 stated:条件列长出来
    await js(`(() => { const s = document.querySelector('select[name="allocation_basis"]')
        return s ? window.__set(s, 'stated', 'change') : false })()`)
    await sleep(600)
    const n12b = await js(namedHeads(0))
    /* ⚠ **条件列的判据要下在【桌面那一档】** —— 390px 上非 priority 的列本来就不画,
       所以「分得」在手机上看不见是**对的**,不是缺陷。第一版判据下在 390px 上,
       四个读数逐字都对,而拿来比的那个整数问错了断点。 */
    note('#12 · 390px:stated 档有名字的列', `${JSON.stringify(n12a)} → ${JSON.stringify(n12b)}` +
        `(「剩余」按 priority: !stacked 收进批次格,「分得」非 priority —— 两者都在展开区/叠加块里)`)
    await view(1280); await sleep(500)
    const n12desk = await js(namedHeads(0))
    probe('★★ #12 · 切到 stated → 「分得」那一列在【桌面档】长出来了(条件列)',
        n12desk.includes('Share') && n12desk.length === 4,
        `1280 stated 档有名字的列 = ${JSON.stringify(n12desk)}`)
    await view(390); await sleep(400)
    await openRow(0, 0)
    const pickBox = await js(inPanel(0, 0, 'input[type="checkbox"]') + '.length')
    probe('★ #12 · 勾选框在【展开区】里(Q7)', pickBox === 1,
        `第 0 行自己那块展开区里的勾选框 ${pickBox} 个`)
    await js(`(() => { const e = ${inPanel(0, 0, 'input[type="checkbox"]')}[0]; if (!e) return false; e.click(); return true })()`)
    await sleep(450)
    await js(`(() => { const els = ${inPanel(0, 0, 'input[type="text"]')}
        return els.length ? window.__set(els[els.length - 1], '250.75') : 'no text input' })()`)
    await sleep(400)
    const b12 = await js(bridge('alloc_json'))
    probe('#12 · 桥只出现一次', b12.count === 1, `alloc_json 出现 ${b12.count} 次`)
    probe('★★★ #12 · 桥上【只有挑中的那一行】,而且带着 stated_amount',
        Array.isArray(b12.parsed) && b12.parsed.length === 1 && b12.parsed[0].stated_amount === '250.75',
        `桥 = ${JSON.stringify(b12.parsed)} ← 搬家前那两个具名输入也是条件渲染的,逐字同构`)
    probe('#12 · 格子里没有带 name 的控件', (await js(namedInTables)).length === 0,
        `表里的 name = ${JSON.stringify(await js(namedInTables))}`)
    /* ⚠★★ 这一页 390px 上【真的横向溢出】,而元凶不是这张表 ——
       逐元素量过:**只有一个** 元素越界,是一颗页面级的原生 `<select>`
       (`h-8 rounded-lg border border-input …`,宽 384,右缘 416 / 视口 390),
       **它不在表里**,而本刀一颗 select 都没有碰。
       ☞ 这是 INPUT-2b 那一族:一个内在尺寸由最长那条 option 决定的原生下拉,
         坐在一个不换行的容器里。**照直量出来、照直报出来,不在这一刀里修**
         —— 修它要么改那一行容器,要么裁一条关于 option 文案的规矩,
         两件都不是这一刀的范围。 */
    const o12 = await js(overflow)
    const who12 = await js(`(() => {
        const W = document.documentElement.clientWidth
        const out = []
        document.querySelectorAll('*').forEach((el) => {
            const r = el.getBoundingClientRect()
            if (r.right > W + 0.5) out.push({ tag: el.tagName,
                inTable: !!el.closest('${T}'),
                cls: String(el.className || '').slice(0, 48), right: Math.round(r.right) })
        })
        return { count: out.length, inTable: out.filter(x => x.inTable).length, sample: out.slice(0, 3) } })()`)
    note('#12 · 390px 整页横向溢出', `scrollWidth ${o12.scrollWidth} / clientWidth ${o12.clientWidth}`)
    probe('⚠ #12 · 那处 390px 溢出【不是这张表造成的】—— 越界元素全在表外面',
        who12.inTable === 0 && who12.count >= 1,
        `越界元素 ${who12.count} 个,其中在表里的 ${who12.inTable} 个 · ${JSON.stringify(who12.sample)}` +
        ` ← 一颗页面级原生 select(INPUT-2b 那一族),本刀一颗 select 都没碰`)

    // ══════════════════════════════════════════════════════════════════════
    // ARM D · #14 /finance/invoices/new —— 一份单纯的 id 名单
    // ══════════════════════════════════════════════════════════════════════
    await goto('/finance/invoices/new', '#14')
    await js(SET)
    await js(`(() => { const s = document.querySelector('select[name="customer_id"]')
        return s ? window.__set(s, '${CUSTOMER_ID}', 'change') : false })()`)
    await sleep(700)
    await js(PANEL)
    const tables14 = await js(`document.querySelectorAll('${T}').length`)
    probe('#14 · 选了客户之后那张表画出来了', tables14 === 1, `EditableTable ${tables14} 张`)
    const n14 = await js(namedHeads(0))
    note('#14 · 390px 有名字的列', JSON.stringify(n14))
    const stack14 = await js(`(() => {
        const rows = Array.from(document.querySelectorAll('${T}')[0].querySelectorAll('tbody tr'))
            .filter(r => r.querySelector('button[aria-expanded]'))
        return rows.map(r => { const d = r.querySelector('div[class*="sm:hidden"]')
            return d && d.offsetParent !== null ? d.textContent.replace(/\\s+/g, ' ').trim() : null }) })()`)
    probe('★★ #14 · 数量 / 单价【零次点按】看得见(Q2)',
        stack14.every((s) => typeof s === 'string' && s.length > 0),
        `叠加块 = ${JSON.stringify(stack14)}`)
    await openRow(0, 0)
    const box14 = await js(inPanel(0, 0, 'input[type="checkbox"]') + '.length')
    probe('★★ #14 · 那个勾在【展开区】里 —— 0 → 1 次点按,照直记(Q7)',
        box14 === 1, `第 0 行自己那块展开区里的勾选框 ${box14} 个` +
        ` ← 旧注释说「它必须留在看得见的地方」,而手机档的格子恒为只读,留下来的会是一个按不动的勾`)
    await js(`(() => { const e = ${inPanel(0, 0, 'input[type="checkbox"]')}[0]; if (!e) return false; e.click(); return true })()`)
    await sleep(450)
    const b14 = await js(bridge('sale_ids_json'))
    probe('#14 · 桥只出现一次', b14.count === 1, `sale_ids_json 出现 ${b14.count} 次`)
    probe('★★ #14 · 桥交的是一份【单纯的 id 名单】,勾一票就有一条',
        Array.isArray(b14.parsed) && b14.parsed.length === 1 && typeof b14.parsed[0] === 'string',
        `桥 = ${JSON.stringify(b14.parsed)} ← 它从来没有第二条数组要对齐,所以从来没有错位的风险`)
    probe('#14 · 格子里没有带 name 的控件', (await js(namedInTables)).length === 0,
        `表里的 name = ${JSON.stringify(await js(namedInTables))}`)
    await ov('#14')

    // ══════════════════════════════════════════════════════════════════════
    // ARM E · ★★★ #15 / #16 /finance/payments/new —— 本刀最重的一张
    //
    //   两张表**同时渲染**,搬家前共用三条并列数组(`alloc_id` / `alloc_kind` /
    //   `alloc_amount`),按下标配对。而服务端逐行读的是 `allocKinds[i]` ——
    //   **按 kind 分辨,不按位置**。☞ 判据因此是:
    //   **两张表各填一格 → 两座桥各带一行 → 每一行的 `kind` 正确、谁也没带上对方那一行。**
    //   **顺序在这条路上从来不是判据**,那正是它能分成两座的理由。
    //
    //   ⚠★★ 照直记一处【我自己的误判,而它差点写进报告】:开工前我用
    //   Management API 查 `po_prepayment_applicable` / `ap_open_items` /
    //   `ar_open_items`,三张**全是 0 行**,于是我把这一臂写成了「源是空的,
    //   NOT MEASURED」。**那个零是假的:** 那三张视图都带 `has_permission()` 谓词,
    //   而 Management API 跑在 `postgres` 上、**没有 JWT**(`auth.uid()` 为 NULL)——
    //   于是谓词恒假,视图对它恒空,**与线上有没有数据无关**。
    //   ☞ 浏览器里带着真会话一看:`#15` **2 行**、`#16` **8 行**。
    //   ☞ **空的是我的判据,不是那张表。**(本仓库那条「先问这个判据读的是哪一份
    //     真源」的又一张脸 —— 这一次它差一步就把一个能证的东西报成了证不了。)
    // ══════════════════════════════════════════════════════════════════════
    const setupPayment = async () => {
        await js(`(() => { const s = document.querySelector('select[name="direction"]')
            return s ? window.__set(s, 'out', 'change') : false })()`)
        await sleep(500)
        await js(`(() => { const s = document.querySelector('select[name="counterparty"]')
            return s ? window.__set(s, 'supplier:${SUPPLIER_ID}', 'change') : false })()`)
        await sleep(1200)
    }
    await view(390)
    await goto('/finance/payments/new', '#15/#16 @390')
    await js(SET)
    await setupPayment()
    await js(PANEL)
    const nTables = await js(`document.querySelectorAll('${T}').length`)
    const rowCounts = await js(`Array.from(document.querySelectorAll('${T}')).map(t =>
        t.querySelectorAll('tbody tr button[aria-expanded]').length)`)
    probe('★★★ #15 / #16 · 两张表【同时】渲染,而且都有行',
        nTables === 2 && rowCounts[0] > 0 && rowCounts[1] > 0,
        `EditableTable ${nTables} 张 · 行数 ${JSON.stringify(rowCounts)}` +
        ` ← 两张表同时在,正是搬家前那三条数组接在一起的原因`)
    const nPo = await js(namedHeads(0)), nItem = await js(namedHeads(1))
    note('#15 · 390px 有名字的列', JSON.stringify(nPo))
    note('#16 · 390px 有名字的列', JSON.stringify(nItem))
    probe('★★★ #15 · 预估总额与已预付【两列都留在 390px 那一行上】',
        nPo.length >= 3, `有名字的列 = ${JSON.stringify(nPo)}` +
        ` ← 它们不是同一种币,而旧注释写着「两个数缺一个这一格就填不成」`)
    const stackPo = await js(`(() => {
        const rows = Array.from(document.querySelectorAll('${T}')[0].querySelectorAll('tbody tr'))
            .filter(r => r.querySelector('button[aria-expanded]'))
        return rows.map(r => { const d = r.querySelector('div[class*="sm:hidden"]')
            return d && d.offsetParent !== null ? d.textContent.replace(/\s+/g, ' ').trim() : null }) })()`)
    probe('★★ #15 · 下单日期【零次点按】看得见(Q2 的叠加块)',
        stackPo.every((x) => typeof x === 'string' && x.length > 0),
        `叠加块 = ${JSON.stringify(stackPo)}`)

    // ★ 两张表各填一格,各按各自的面板取控件
    await openRow(0, 0)
    const poFilled = await js(`(() => { const els = ${inPanel(0, 0, 'input[type="text"]')}
        return els.length ? window.__set(els[0], '111.11') : 'no input' })()`)
    await sleep(400)
    await openRow(1, 0)
    const itemFilled = await js(`(() => { const els = ${inPanel(1, 0, 'input[type="text"]')}
        return els.length ? window.__set(els[0], '222.22') : 'no input' })()`)
    await sleep(600)
    note('#15 / #16 · 两格各自填进去了', `${poFilled} / ${itemFilled}`)
    const stillOpen = await js(`!!window.__panel(0, 0)`)
    probe('★ #15 · 展开第二张表的行之后,第一张表那一行【仍然开着】(各认各的面板)',
        stillOpen === true, `#15 的第 0 行面板还在 = ${stillOpen}`)

    const bPo = await js(bridge('po_alloc_json'))
    const bItem = await js(bridge('item_alloc_json'))
    probe('#15 · 采购单那座桥只出现一次', bPo.count === 1, `po_alloc_json 出现 ${bPo.count} 次`)
    probe('#16 · 未结单据那座桥只出现一次', bItem.count === 1, `item_alloc_json 出现 ${bItem.count} 次`)
    probe('★★★ #15 · 那一格【只出现一次】,而且 kind = purchase_order',
        Array.isArray(bPo.parsed) && bPo.parsed.length === 1 &&
        bPo.parsed[0].amount === '111.11' && bPo.parsed[0].kind === 'purchase_order',
        `po 桥 = ${JSON.stringify(bPo.parsed)}`)
    probe('★★★ #16 · 那一格【只出现一次】,而且 kind 是它自己的单据类别,不是 purchase_order',
        Array.isArray(bItem.parsed) && bItem.parsed.length === 1 &&
        bItem.parsed[0].amount === '222.22' && !!bItem.parsed[0].kind &&
        bItem.parsed[0].kind !== 'purchase_order',
        `item 桥 = ${JSON.stringify(bItem.parsed)} ← 服务端按 kind 分辨,不按位置`)
    probe('★★★ #15 / #16 · 两座桥【谁都没有带上对方那一行】',
        Array.isArray(bPo.parsed) && Array.isArray(bItem.parsed) &&
        !bPo.parsed.some((r) => r.amount === '222.22') &&
        !bItem.parsed.some((r) => r.amount === '111.11'),
        `po 里有 222.22 吗 = ${(bPo.parsed || []).some((r) => r.amount === '222.22')}` +
        ` · item 里有 111.11 吗 = ${(bItem.parsed || []).some((r) => r.amount === '111.11')}`)
    probe('★ #15 / #16 · 另外那些行照旧不在桥上(只填的那两格进了桥)',
        Array.isArray(bPo.parsed) && bPo.parsed.length === 1 &&
        Array.isArray(bItem.parsed) && bItem.parsed.length === 1,
        `表里 ${JSON.stringify(rowCounts)} 行 · 桥上 ${bPo.parsed.length} + ${bItem.parsed.length} 行`)
    const fillInPanel = await js(inPanel(0, 0, 'button') + '.length')
    probe('★ #15 · 「填满」那颗钮在展开区末尾(能力 A + Q7)', fillInPanel >= 1,
        `第 0 行自己那块展开区里的钮 ${fillInPanel} 颗`)
    probe('#15 / #16 · 两张表的格子里都没有带 name 的控件',
        (await js(namedInTables)).length === 0, `表里的 name = ${JSON.stringify(await js(namedInTables))}`)
    await ov('#15/#16')

    // ── 1280:桌面那一档,同一个 store ─────────────────────────────────────
    await view(1280)
    await goto('/finance/payments/new', '#15/#16 @1280')
    await js(SET)
    await setupPayment()
    await js(PANEL)
    const nPoD = await js(namedHeads(0)), nItemD = await js(namedHeads(1))
    probe('★★ #15 @1280 · 桌面照旧五列有名字(下单日期回到自己那一列)',
        nPoD.length === 5, `有名字的列 = ${JSON.stringify(nPoD)}`)
    probe('★ #16 @1280 · 桌面照旧四列有名字', nItemD.length === 4,
        `有名字的列 = ${JSON.stringify(nItemD)}`)
    await js(`(() => { const els = ${inRow(0, 0, 'input[type="text"]')}
        return els.length ? window.__set(els[0], '333.33') : false })()`)
    await js(`(() => { const els = ${inRow(1, 0, 'input[type="text"]')}
        return els.length ? window.__set(els[0], '444.44') : false })()`)
    await sleep(600)
    const bPoD = await js(bridge('po_alloc_json'))
    const bItemD = await js(bridge('item_alloc_json'))
    probe('★★★ #15 / #16 @1280 · 桌面上打的字分别到了【各自】那座桥里,各一份,kind 各自正确',
        bPoD.count === 1 && bItemD.count === 1 &&
        Array.isArray(bPoD.parsed) && bPoD.parsed.length === 1 && bPoD.parsed[0].amount === '333.33' &&
        bPoD.parsed[0].kind === 'purchase_order' &&
        Array.isArray(bItemD.parsed) && bItemD.parsed.length === 1 && bItemD.parsed[0].amount === '444.44' &&
        bItemD.parsed[0].kind !== 'purchase_order',
        `po = ${JSON.stringify(bPoD.parsed)} · item = ${JSON.stringify(bItemD.parsed)}`)
    const o1280 = await js(overflow)
    probe('#15/#16 @1280 · 整页不横向溢出', o1280.scrollWidth <= o1280.clientWidth,
        `scrollWidth ${o1280.scrollWidth} / clientWidth ${o1280.clientWidth}`)
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
