#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// DRAFT-6 的证明 —— 本刀搬的三张:#3 PayrollGrid · #11 PermissionMatrix · #1 BulkFxGrid
// ════════════════════════════════════════════════════════════════════════════
// ★ 跑在【生产构建】上(`next start`),等的是**水合收尾**(`__reactFiber$…`)。
//
// ★★【它一次提交都不发,也一次保存都不点】★★
//   `#3` 的判据读的是 `new FormData(form)` —— 那**就是**按下提交会送出去的东西,
//   而读它不写库。`#11` 与 `#1` **连 `<form>` 都没有**(两者收的都是带类型的实参),
//   所以它们连一条可写的路都没有 —— 探针点过 `#11` 的一个勾选框,
//   **而那颗保存钮一次都没有被按过**(收尾复核:`cfo` 的授权 5 条,未变)。
//
// ★★★【重点臂是 `#3`,而它要还的是一笔从 DRAFT-1 欠到今天的账(R12)】★★★
//   在册的读数**不是一个数字,是一句话**(`docs/known-issues.md:7497`):
//     「390px 上横拖 414px 才看得到最后一列,**而那时身份列早已离场**。
//       这是一张录入工资的表 —— 打字的人屏幕上没有任何东西说这一行是谁。」
//   ☞ **所以判据也必须是那句话,不是那个 414**:表自己横不横滚 ·
//     身份格零次点按读不读得出是谁 · 而那一列【核对】说不说得出话。
//
// ★★【`#11` 那一臂证的是「两个 `—` 不会撞车」】★★
//   落点 `cfo` 角色,因为**三种状态同时在那一页上**:
//   `finance` 授了 view 没授 edit(未授予)· `logistics` **没有 edit 码**(没有这样东西)·
//   `hr` 两个都没授(未授予)。☞ 判据是**那三种状态在 390px 上分得开**,
//   而那条 `—` 在手机上**一个都没有**、在桌面上**原样活着**(Tim 的 Q6)。
//
// ★★【`#1` 那一臂只证得了 Q19 的一半,而另一半照直标 NOT MEASURED】★★
//   窗口内**一条在册的牌价都没有**(只读清点:全树 12 行全是 USD,最新 2026-08-17,
//   而这一页的窗口是最近 7 天)。☞ 于是「已在册那一格会串币种」**证不了**;
//   证得了的是另一半:**打的字不再跨币种留着**。
//
// ★ 两处在册的探针缺陷都避开(`docs/known-issues.md`):
//   · `PROBE-UNBOUNDED-CDP-WAIT` —— 每一次 CDP 调用有上限,导航单独给 120s;
//   · `PROBE-LSOF-KILLS-ITSELF` —— 收尾那条 `lsof` 把**本进程**滤掉。
// ★ 逐行判据一律按【那一行自己的面板】取(`window.__panel(t, n)`)——
//   `page-owned` 下 `open` 是一个集合,展开第二行【不会】收起第一行。
// ★ 表头计数只认【有名字的列】:手机档最左那格是组件自己的展开钮、
//   桌面档最右那格是动作列,**两者都没有列头**。
//
// ════════════════════════════════════════════════════════════════════════════
// ⚠★★【本探针自己红过四轮,而四轮红的都是探针 —— 六处判据缺陷,逐条留在落点上】★★
//   ① 列头大小写写死(`'Rate date'` vs `'Rate Date'`);
//   ② `\b` 在 `Financefinance` 中间**不成立**(显示名紧接着模块码,两边都是词字符);
//   ③ ★★★ `noEditCapability` **那句话本身带着一个破折号** ——
//      **散文里的标点被数成了那个「当成值用」的字形**;
//   ④ DOM 计数答不了「屏幕上有没有」(`edit()` 与 `render()` 两份都在 DOM 里);
//   ⑤ `textContent` **把 CSS 藏起来的字也读进去**;
//   ⑥ 嵌套 span **两层都命中**(外层包装与里面那条短横)。
//   ☞ ★★★ **六处是同一句话的六种说法:一个读 DOM 的判据,要说清它认的是【哪一层】。**
//   ☞ ★★ 而 ③ 最值得留着:**它与这一刀在【产品】那一侧刚刚修掉的是同一个病** ——
//     同一个字形,两种意思。在代码里把它治好了,转手在自己的判据里又犯了一次。
// ════════════════════════════════════════════════════════════════════════════
import { readFileSync, existsSync } from 'node:fs'
import { join } from 'node:path'
import { spawn, execSync } from 'node:child_process'
import { createConnection } from 'node:net'
import { acquireOrExit, release } from './liveLock.mjs'
import { openPlan, planDelete, ephemeralGrantBody, runPlan, reapStalePlans, ORDER } from './ephemeral.mjs'

const ROOT = new URL('..', import.meta.url).pathname
const PORT = 3209, CDP_PORT = 9345
const CHROME = join(process.env.HOME, '.cache/puppeteer/chrome-headless-shell/mac_arm-152.0.7977.75/chrome-headless-shell-mac-arm64/chrome-headless-shell')
const env = readFileSync(join(ROOT, '.env.local'), 'utf8')
const URL_ = env.match(/NEXT_PUBLIC_SUPABASE_URL=(\S+)/)[1]
const ANON = env.match(/NEXT_PUBLIC_SUPABASE_ANON_KEY=(\S+)/)[1]
const SERVICE = env.match(/SUPABASE_SERVICE_ROLE_KEY=(\S+)/)[1]

// 只读清点(2026-09-21,一次写都没发,以 `postgres` 身份读,`rolbypassrls = true`)
// 挑出来的落点 —— 每一个都写着它为什么是这一个。
// ★★ **「以谁的身份读」必须写出来**(DRAFT-5 §3.1 的判词):一个「0 行」的读数
//   可能是一次测量,也可能是一次**权限拒绝**,而两者在 `[]` 这个字节上一模一样。
const ROLE_ID = '3aea20f5-2ffd-4add-a3f0-47a0ad505ed7'  // cfo:15 个模块里三种状态【同时】在场 ——
//   logistics 没有 edit 码(「没有这样东西」)· finance 授了 view 没授 edit(「未授予」)
//   · hr 两个都没授(「未授予」)。☞ 一页上同时证得了那三种状态分得开。

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
    acquireOrExit('probe-draft6', { ownExit: false })
    openPlan('probe-draft6')
    await reapStalePlans()
    if (!existsSync(join(ROOT, '.next/BUILD_ID'))) throw new Error('.next/BUILD_ID 不在 —— 先 npm run build')
    if (!existsSync(CHROME)) throw new Error('chrome not at ' + CHROME)
    for (const p of [PORT, CDP_PORT]) { try { execSync(`lsof -ti tcp:${p} | xargs -r kill -9`, { stdio: 'ignore' }) } catch {} }

    const email = `draft6probe-${Date.now()}@test.local`
    const cu = await (await rest('/auth/v1/admin/users', { method: 'POST',
        body: JSON.stringify({ email, password: 'draft6-probe-1', email_confirm: true }) })).json()
    const accountId = cu.id
    if (!accountId) throw new Error('账号建不出来: ' + JSON.stringify(cu).slice(0, 300))
    planDelete(`/rest/v1/user_roles?user_id=eq.${accountId}`, `revoke grant ${accountId}`, ORDER.GRANT)
    planDelete(`/auth/v1/admin/users/${accountId}`, `delete account ${accountId}`, ORDER.ACCOUNT)
    const roles = await (await rest('/rest/v1/roles?select=id&code=eq.admin')).json()
    await rest('/rest/v1/user_roles', { method: 'POST', body: JSON.stringify(ephemeralGrantBody(accountId, roles[0].id)) })
    const sess = await (await fetch(URL_ + '/auth/v1/token?grant_type=password', { method: 'POST',
        headers: { apikey: ANON, 'Content-Type': 'application/json' },
        body: JSON.stringify({ email, password: 'draft6-probe-1' }) })).json()
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


    /* ★★ R12 那笔欠账的量法:**表自己那个横滚壳**,不是整页。
       在册的读数(`known-issues.md:7497`)量的就是它:「390px 上横拖 414px 才看得到
       最后一列」。`EditableTable` 的壳是 `<div class="w-full overflow-x-auto">`。 */
    const tableScroll = (t) => `(() => {
        const tbl = document.querySelectorAll('${T}')[${t}]
        if (!tbl) return null
        const box = tbl.closest('.overflow-x-auto')
        return box ? { scrollWidth: box.scrollWidth, clientWidth: box.clientWidth } : null })()`

    // ══════════════════════════════════════════════════════════════════════
    // ARM A · #3 /hr/payroll/new —— 本刀最重的一张,而 R12 在这里还
    // ══════════════════════════════════════════════════════════════════════
    await view(390)
    await goto('/hr/payroll/new', '#3 @390')
    await js(SET); await js(PANEL)

    const n3 = await js(namedHeads(0))
    probe('#3 @390 · 身份列是【唯一】留在那一行上的列',
        JSON.stringify(n3) === JSON.stringify(['Employee']), `有名字的列 = ${JSON.stringify(n3)}`)

    const sc3 = await js(tableScroll(0))
    probe('★★★ R12 · 表自己【不再横滚】(在册读数:390px 横拖 414px,而那时身份列早已离场)',
        !!sc3 && sc3.scrollWidth <= sc3.clientWidth,
        `表壳 scrollWidth ${sc3 && sc3.scrollWidth} / clientWidth ${sc3 && sc3.clientWidth} ← 在册是 414 / 390`)

    const who = await js(`(() => { const rows = Array.from(document.querySelectorAll('${T}')[0]
        .querySelectorAll('tbody tr')).filter(r => r.querySelector('button[aria-expanded]'))
        return rows.slice(0, 2).map(r => r.querySelector('td:nth-child(2)').textContent.trim()) })()`)
    probe('★★★ R12 · 打字的人【零次点按】看得见这一行是谁',
        who.length === 2 && who.every((x) => x.length > 0), `前两行的身份格 = ${JSON.stringify(who)}`)

    // ── 把第 0 行填成【不平】的:核对那一列必须零次点按说出来 ──────────────
    await openRow(0, 0)
    const ins = await js(inPanel(0, 0, 'input') + '.length')
    probe('#3 @390 · 五个钱数在展开区里(手机上唯一能打字的地方)', ins === 5,
        `第 0 行自己那块展开区里的输入框 ${ins} 个`)
    for (const [i, v] of [[0, '3000'], [1, '500'], [2, '600'], [3, '0'], [4, '2000']]) {
        await js(`(() => { const els = ${inPanel(0, 0, 'input')}; return els[${i}] ? window.__set(els[${i}], '${v}') : false })()`)
    }
    await sleep(500)
    const folded = await js(`(() => { const rows = Array.from(document.querySelectorAll('${T}')[0]
        .querySelectorAll('tbody tr')).filter(r => r.querySelector('button[aria-expanded]'))
        return rows[0].querySelector('td:nth-child(2)').textContent.trim() })()`)
    probe('★★★ #3 @390 · 【核对】那一列零次点按说得出话 —— 而它是一列只读非 priority 的列(G1)',
        /2,?500/.test(folded) && /Check/i.test(folded),
        `身份格读出来 = ${JSON.stringify(folded)}`)
    const tinted = await js(`(() => { const rows = Array.from(document.querySelectorAll('${T}')[0]
        .querySelectorAll('tbody tr')).filter(r => r.querySelector('button[aria-expanded]'))
        return rows[0].className })()`)
    probe('#3 @390 · 能力 B:不平的那一行涂红(与搬家前逐字相同的类)',
        /bg-red-50/.test(tinted), `第 0 行的 class = ${JSON.stringify(tinted)}`)

    const foot390 = await js(`(() => { const tf = document.querySelectorAll('${T}')[0].querySelector('tfoot')
        if (!tf) return null
        const vis = Array.from(tf.querySelectorAll('td')).filter(e => e.offsetParent !== null)
        return { cells: vis.length, text: vis.map(e => e.textContent.trim()).join(' | ') } })()`)
    probe('★★★ 能力 C @390 · 五个合计【叠进手机档标签格】,没有跟着列一起消失',
        !!foot390 && /3,?000/.test(foot390.text) && /2,?000/.test(foot390.text),
        `手机档表尾 = ${JSON.stringify(foot390)}`)

    const b3 = await js(bridge('lines_json'))
    const hit3 = Array.isArray(b3.parsed) ? b3.parsed.filter((r) => r.gross_pay === '3000') : []
    probe('★★ #3 @390 · 手机上打的字【到了桥里,而且只有一份】',
        b3.count === 1 && hit3.length === 1,
        `lines_json 出现 ${b3.count} 次 · 命中 ${hit3.length} 条 = ${JSON.stringify(hit3[0] ?? null)}`)
    probe('#3 · 格子里没有带 name 的控件', (await js(namedInTables)).length === 0,
        `表里的 name = ${JSON.stringify(await js(namedInTables))}`)
    await ov('#3')

    // ── 1280:桌面那一档 ───────────────────────────────────────────────────
    await view(1280)
    await goto('/hr/payroll/new', '#3 @1280')
    await js(SET); await js(PANEL)
    const n3d = await js(namedHeads(0))
    probe('★ #3 @1280 · 桌面照旧七列有名字(与搬家前逐字相同)', n3d.length === 7,
        `有名字的列 = ${JSON.stringify(n3d)}`)
    await js(`(() => { const els = ${inRow(0, 0, 'input[type="text"]')}
        return els.length ? window.__set(els[0], '7777') : false })()`)
    await sleep(500)
    const foot1280 = await js(`(() => { const tf = document.querySelectorAll('${T}')[0].querySelector('tfoot')
        if (!tf) return null
        const vis = Array.from(tf.querySelectorAll('td')).filter(e => e.offsetParent !== null)
        return { cells: vis.length, text: vis.map(e => e.textContent.trim()) } })()`)
    probe('★★★ 能力 C @1280 · 表尾跨满整行,而合计落在【它们自己那一列】下面',
        !!foot1280 && foot1280.cells === 7 && foot1280.text.some((x) => /7,?777/.test(x)),
        `桌面档表尾 ${foot1280 && foot1280.cells} 格 = ${JSON.stringify(foot1280 && foot1280.text)}`)
    const b3d = await js(bridge('lines_json'))
    probe('★ #3 @1280 · 桌面上打的字到了同一座桥里,桥仍然只有一份',
        b3d.count === 1 && Array.isArray(b3d.parsed) &&
        b3d.parsed.some((r) => r.gross_pay === '7777'),
        `lines_json 出现 ${b3d.count} 次 · 命中 ${Array.isArray(b3d.parsed) ? b3d.parsed.filter((r) => r.gross_pay === '7777').length : '?'} 条`)
    const o3d = await js(overflow)
    probe('#3 @1280 · 整页不横向溢出', o3d.scrollWidth <= o3d.clientWidth,
        `scrollWidth ${o3d.scrollWidth} / clientWidth ${o3d.clientWidth}`)

    // ══════════════════════════════════════════════════════════════════════
    // ARM B · #11 /settings/roles/<cfo> —— 三种状态【同时】在一页上
    //   只读清点(2026-09-21,以 postgres 身份读,rolbypassrls = true):
    //   15 个模块;logistics 【没有】edit 码;cfo 持 module.finance.view(有 edit 码但没授)
    //   与 module.logistics.view,而 module.hr.view 【没有】。
    //   ☞ 于是同一屏上三种状态都在:已授予 / 未授予 / 没有这样东西。
    // ══════════════════════════════════════════════════════════════════════
    await view(390)
    await goto(`/settings/roles/${ROLE_ID}`, '#11 @390', '[data-slot="editable-table"] button[aria-expanded]')
    await js(SET); await js(PANEL)

    const n11 = await js(namedHeads(0))
    probe('#11 @390 · 模块列是【唯一】留在那一行上的列(Q1)',
        JSON.stringify(n11) === JSON.stringify(['Module']), `有名字的列 = ${JSON.stringify(n11)}`)

    /* ⚠ 探针缺陷 ②(照直记):第一版拿 `/\\b(logistics|finance|hr)\\b/` 去认模块,
       而那一格的 `textContent` 是**显示名紧接着模块码**(「Finance」+「finance」=
       `Financefinance`)—— **两边都是词字符,`\\b` 在中间【不成立】**,于是四条一起
       读到 `undefined`。☞ 本仓库那条「按行切开再匹配会废掉一个含 \\n 的字符类」的邻居:
       **一条认【文字边界】的判据,认的是两段文字碰巧怎么拼起来的。**
       ☞ 改成按【那个码自己的元素】取 —— 模块码有它自己的 `<span>`。 */
    const cellsByModule = `(() => { const out = {}
        const rows = Array.from(document.querySelectorAll('${T}')[0].querySelectorAll('tbody tr'))
            .filter(r => r.querySelector('button[aria-expanded]'))
        for (const r of rows) { const td = r.querySelector('td:nth-child(2)')
            const codeEl = td.querySelector('span.text-gray-400')
            const m = codeEl && codeEl.textContent.trim()
            if (m) out[m] = td.textContent.trim() }
        return out })()`
    const c11 = await js(cellsByModule)
    probe('★★★ #11 @390 · 【已授予】零次点按读得到(finance:View 授了)',
        /finance/.test(c11.finance || '') && /View:\s*granted/.test(c11.finance || ''),
        `finance 那一格 = ${JSON.stringify(c11.finance)}`)
    probe('★★★ #11 @390 · 【未授予】读的是一句话,不是一个字形',
        /Edit:\s*not granted/.test(c11.finance || ''),
        `finance 的 Edit = ${JSON.stringify((c11.finance || '').match(/Edit:.*/)?.[0])}`)
    probe('★★★ #11 @390 · 【没有这样东西】与【未授予】分得开(logistics 没有 edit 码)',
        /no separate edit permission/i.test(c11.logistics || '') &&
        !/Edit:\s*not granted/.test(c11.logistics || ''),
        `logistics 的 Edit = ${JSON.stringify((c11.logistics || '').match(/Edit:.*/)?.[0])}`)
    probe('★★ #11 @390 · 一整列都没授的模块照样说得出话(hr:两句都是 not granted)',
        /View:\s*not granted/.test(c11.hr || '') && /Edit:\s*not granted/.test(c11.hr || ''),
        `hr 那一格 = ${JSON.stringify(c11.hr)}`)
    /* ⚠ 探针缺陷 ③(照直记):第一版数的是「这一格的文字里含不含破折号」,
       而 `permissions.noEditCapability` 那**句话本身**就带着一个破折号
       (「…no separate edit permission — its View permission is…」)。
       ☞ **那是散文里的标点,不是那个【当成值用】的字形** —— 两者形状相同、
         意思毫不相干,而判据把前者数成了后者。
       ☞ 这正是本刀在产品那一侧刚刚修掉的同一个病:**同一个字形,两种意思。**
         判据因此改成:**有没有一个元素,它【整格就是】那条短横。** */
    const dash390 = await js(`(() => { const tbl = document.querySelectorAll('${T}')[0]
        return Array.from(tbl.querySelectorAll('span, td'))
            .filter(e => e.offsetParent !== null && e.textContent.trim() === '—').length })()`)
    probe('★★★ #11 @390 · 那条【当成值用】的短横在手机上一个都没有 —— 两种意思不可能撞车',
        dash390 === 0, `390px 上整格就是那条短横的元素 = ${dash390} 个`)
    /* ⚠ 探针缺陷 ④(照直记):第一版在这里数 **DOM 里**那条短横的 span 个数,
       并把它钉死成 1。读数是 **4**,而**产品是对的** —— 数错的是判据:
       `page-owned` 下一个可编辑格子把 `edit()` 与 `render()` **两份都放进 DOM**
       (`editable-table.tsx`:`<span class="hidden sm:block">{edit}</span>` +
       `<span class="sm:hidden">{render}</span>`),展开区里还会再来一份。
       ☞ **一个 DOM 计数答不了「屏幕上有没有」** —— 这正是本仓库 COPY-1 那条
         (「`hidden md:block` 在任何宽度上都数成 1」)的又一张脸,
         而这一次它落在探针自己身上。
       ☞ 改成问那件真正要紧的事:**在桌面那一档,logistics 那一行的 Edit 格
         【看得见】,而且它整格就是那条短横。** */
    /* ⚠ 探针缺陷 ⑤(照直记):第一版读的是那一格的 textContent,读回来是【两条短横】。
       **产品是对的** —— textContent 把 CSS 藏起来的字也读进去,而 page-owned 下
       一个可编辑格子里 edit() 与 render() 两份都在 DOM 里
       (一份 hidden sm:block、一份 sm:hidden)。
       ☞ 又一次 COPY-1:**一个读 DOM 的判据答不了「屏幕上是什么」。**
       ☞ 改成只取【看得见】的那一个。
       ⚠ 而这条注释本身也踩过一次:它第一版写在那段 js 模板字符串【里面】,
         而它引用代码时用了反引号 —— 整个模板当场断掉。照直记。
       ⚠ 探针缺陷 ⑥(照直记):改成「只取看得见的」之后读回来是 **2**,title 是 null ——
         **产品仍然是对的**:组件给每一份包了一层 span
         (hidden sm:block / sm:hidden),于是【外层包装】与【里面那条短横】
         都满足「整格就是那条短横」,而外层没有 title。
         ☞ 判据补一句:只认【叶子】元素(children.length === 0)。
         ☞ 三次改判据,三次都是同一句话的不同说法:
           **一个读 DOM 的判据,要说清它认的是哪一层。** */
    await view(1280)
    await sleep(400)
    const dashDesktop = await js(`(() => { const rows = Array.from(document.querySelectorAll('${T}')[0]
        .querySelectorAll('tbody tr')).filter(r => r.querySelector('td'))
        for (const r of rows) {
            const code = r.querySelector('span.text-gray-400')
            if (!code || code.textContent.trim() !== 'logistics') continue
            const tds = Array.from(r.querySelectorAll('td')).filter(e => e.offsetParent !== null)
            const last = tds[tds.length - 1]
            const vis = Array.from(last ? last.querySelectorAll('span') : [])
                .filter(e => e.offsetParent !== null && e.children.length === 0 && e.textContent.trim() === '—')
            return { cells: tds.length, visibleDashes: vis.length,
                     title: vis[0] ? vis[0].getAttribute('title') : null }
        }
        return null })()`)
    probe('★★ #11 @1280 · Q6 那条例外原样活着:logistics 那一行的 Edit 格【看得见】,整格就是那条短横',
        !!dashDesktop && dashDesktop.visibleDashes === 1 && /no separate edit permission/i.test(dashDesktop.title || ''),
        `logistics 那一行 = ${JSON.stringify(dashDesktop)}`)
    const n11d = await js(namedHeads(0))
    probe('★ #11 @1280 · 桌面照旧三列有名字(与搬家前逐字相同)',
        n11d.length === 3, `有名字的列 = ${JSON.stringify(n11d)}`)
    await view(390)
    await sleep(300)

    await openRow(0, 0)
    const boxes = await js(inPanel(0, 0, 'input[type="checkbox"]') + '.length')
    probe('★★ #11 @390 · 真勾选框在展开区里,而且【按得动】(Q7)', boxes >= 1,
        `第 0 行自己那块展开区里看得见的勾选框 ${boxes} 个`)
    const before = await js(inPanel(0, 0, 'input[type="checkbox"]') + '[0].checked')
    await js(`(() => { const els = ${inPanel(0, 0, 'input[type="checkbox"]')}; els[0].click(); return true })()`)
    await sleep(350)
    const after = await js(inPanel(0, 0, 'input[type="checkbox"]') + '[0].checked')
    probe('★★★ #11 @390 · 点它【真的改了状态】—— 不是一个画出来按不动的勾',
        before !== after, `点之前 ${before} → 点之后 ${after}`)
    const unsaved = await js(`document.body.textContent.includes('Unsaved') ||
        !!document.querySelector('.bg-amber-100')`)
    note('#11 @390 · 改过之后的「未保存」提醒', String(unsaved))
    probe('#11 · 格子里没有带 name 的控件', (await js(namedInTables)).length === 0,
        `表里的 name = ${JSON.stringify(await js(namedInTables))}`)
    await ov('#11')

    // ══════════════════════════════════════════════════════════════════════
    // ARM C · #1 /finance/fx/bulk
    //   ⚠ **窗口内一条在册的牌价都没有**(只读清点 2026-09-21,以 postgres 身份读,
    //     rolbypassrls = true,fx_rates 是基表 relkind 'r':全树 12 行,最新
    //     2026-08-17,而窗口是最近 7 天)。☞ 所以【锁住的那一格】与那条
    //     「已在册」链接 **NOT MEASURED**,照直标出来。
    //   ★ 而 Q19 的【第二个症状】今天量得到:两种币在下拉里都在。
    // ══════════════════════════════════════════════════════════════════════
    await goto('/finance/fx/bulk', '#1 @390', '[data-slot="editable-table"] button[aria-expanded]')
    await js(SET); await js(PANEL)

    const n1 = await js(namedHeads(0))
    /* ⚠ 探针缺陷 ①(照直记):第一版把列头写死成 `'Rate date'`,而文案是 `'Rate Date'`。
       判据要的是【只剩一列】与【它是哪一列】,不是那一列的大小写 —— 按小写比。 */
    probe('#1 @390 · 日期列是【唯一】留在那一行上的列(不许用 scroll 模式)',
        n1.length === 1 && n1[0].toLowerCase() === 'rate date', `有名字的列 = ${JSON.stringify(n1)}`)
    const expandable = await js(`document.querySelectorAll('${T}')[0]
        .querySelectorAll('button[aria-expanded]').length`)
    probe('★★ #1 @390 · 展开钮画得出来 —— 这正是 scroll 模式【不会】画的那一颗',
        expandable === 7, `展开钮 ${expandable} 颗(窗口是最近 7 天)`)

    await openRow(0, 0)
    const rateIns = await js(inPanel(0, 0, 'input') + '.length')
    probe('#1 @390 · 三个价种在展开区里(手机上唯一能打字的地方)', rateIns === 3,
        `第 0 行自己那块展开区里的输入框 ${rateIns} 个`)

    const ccyList = await js(`Array.from(document.querySelectorAll('#ccy option')).map(o => o.value)`)
    note('#1 · 下拉里的币种', JSON.stringify(ccyList))
    await js(`(() => { const els = ${inPanel(0, 0, 'input')}; return els[0] ? window.__set(els[0], '1.2345') : false })()`)
    await sleep(350)
    const typed = await js(inPanel(0, 0, 'input') + '[0].value')
    probe('#1 @390 · 手机上打得进字', typed === '1.2345', `第一格 = ${JSON.stringify(typed)}`)

    if (ccyList.length >= 2) {
        const cur = await js(`document.querySelector('#ccy').value`)
        const other = ccyList.find((c) => c !== cur)
        await js(`(() => { const s = document.querySelector('#ccy'); return window.__set(s, '${other}', 'change') })()`)
        await sleep(400)
        const afterSwitch = await js(inPanel(0, 0, 'input') + '[0].value')
        probe('★★★ Q19 · 切到另一种币之后,那个数【不在那里了】—— 键含币种(搬家前它会原样挂在另一种币名下)',
            afterSwitch === '', `切到 ${other} 之后第一格 = ${JSON.stringify(afterSwitch)}`)
        const first = ccyList.find((c) => c !== other)
        await js(`(() => { const s = document.querySelector('#ccy'); return window.__set(s, '${first}', 'change') })()`)
        await sleep(400)
        const back = await js(inPanel(0, 0, 'input') + '[0].value')
        probe('★★ Q19 · 切回来,那个数【还在】—— 两种币各记各的',
            back === '1.2345', `切回 ${first} 之后第一格 = ${JSON.stringify(back)}`)
    } else {
        note('⚠ Q19 那一臂 NOT MEASURED', `下拉里只有 ${ccyList.length} 种币,切换证不了`)
    }

    const onFileCells = await js(`document.querySelectorAll('${T}')[0]
        .querySelectorAll('a[href^="/finance/fx/"]').length`)
    note('⚠ #1 · 【已在册】那一格 NOT MEASURED',
        `窗口内在册的格子 ${onFileCells} 个 —— 线上最新一条牌价是 2026-08-17,不在最近 7 天里;委托书禁止建数据`)
    probe('#1 · 格子里没有带 name 的控件', (await js(namedInTables)).length === 0,
        `表里的 name = ${JSON.stringify(await js(namedInTables))}`)
    await ov('#1')
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
