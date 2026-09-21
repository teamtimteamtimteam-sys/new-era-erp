#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// DRAFT-7 的证明 —— 本刀搬的**最后一张**:#21 采购 AmendOrderForm
// ════════════════════════════════════════════════════════════════════════════
// ★ 跑在【生产构建】上(`next start`),等的是**水合收尾**(`__reactFiber$…`)。
//
// ★★【它一次提交都不发】★★
//   判据读的是 `new FormData(form)` —— 那**就是**按下提交会送出去的东西,而读它不写库。
//   ☞ 探针点过勾选框、改过数量、删过期次,**而那颗提交钮一次都没有被按过**。
//     收尾复核照读一遍两张单的行与期次,证明它们逐字未变。
//
// ★★★【两个落点,而它们是【互补】的,不是重复的】★★★
//   · **PO-2026-0003**(receiving · USD · has_formula=true · 已收 700 → `cannotRemove`)
//     —— 证得了:定价状态那个「挂了公式就标不成定价」的禁用、
//        以及「低于已收」那句告警(把数量压到 700 以下)。
//   · **PO-2026-0011**(confirmed · SGD · has_formula=false · 已收 0 → **删得掉**)
//     —— 证得了:被删的那一行真的进了桥。
//   ☞ 两张各 3 期条款,于是 `terms_json` 的三条判据两边都跑得了。
//
// ⚠★★【两处 NOT MEASURED,连理由一起写在落点上】★★
//   · **`null` 与 `[]` 在【数据库那一侧】的分别** —— 量它要发一次写,而委托书禁止。
//     这一侧证得的是**桥上那三种形态分得开**(键不在 / 3 行 / `"[]"`)。
//   · **多行对位** —— 只读清点(身份:`postgres`,`rolbypassrls = true`,三张全是基表
//     `relkind 'r'`):**五张可改的单【每一张都只有 1 行】**,所以「多行会不会错位」
//     这条性质在线上**造不出来**。而它在结构上无所谓:**一行没有配对可错位。**
//
// ⚠★【`{ id, remove: true }` 那一条是【代码收据】,不是一次测量,照直说】★
//   桥上那一行带着**全部原始字符串**(裁定:桥载原样,转换全在 `actions.ts`);
//   而「恰好 `{ id, remove: true }`」是 `actions.ts` **喂给 RPC** 的那个对象,
//   要量它得发一次提交。☞ 这一侧量的是**桥上那一行的 `remove` 为真且带着 id**;
//     那个 payload 形状由 `git diff` 证明它与搬家前**逐字节相同**。
//
// ★ 两处在册的探针缺陷都避开(`docs/known-issues.md`):
//   · `PROBE-UNBOUNDED-CDP-WAIT` —— 每一次 CDP 调用有上限,导航单独给 120s;
//   · `PROBE-LSOF-KILLS-ITSELF` —— 收尾那条 `lsof` 把**本进程**滤掉。
// ★ 逐行判据一律按【那一行自己的面板】取(`window.__panel(t, n)`)。
// ★ 表头计数只认【有名字的列】:手机档最左那格是组件自己的展开钮、
//   桌面档最右那格是动作列,**两者都没有列头**。
// ════════════════════════════════════════════════════════════════════════════
import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs'
import { join } from 'node:path'
import { spawn, execSync } from 'node:child_process'
import { createConnection } from 'node:net'
import { acquireOrExit, release } from './liveLock.mjs'
import { openPlan, planDelete, ephemeralGrantBody, runPlan, reapStalePlans, ORDER } from './ephemeral.mjs'

const ROOT = new URL('..', import.meta.url).pathname
const PORT = 3210, CDP_PORT = 9346
const CHROME = join(process.env.HOME, '.cache/puppeteer/chrome-headless-shell/mac_arm-152.0.7977.75/chrome-headless-shell-mac-arm64/chrome-headless-shell')
const env = readFileSync(join(ROOT, '.env.local'), 'utf8')
const URL_ = env.match(/NEXT_PUBLIC_SUPABASE_URL=(\S+)/)[1]
const ANON = env.match(/NEXT_PUBLIC_SUPABASE_ANON_KEY=(\S+)/)[1]
const SERVICE = env.match(/SUPABASE_SERVICE_ROLE_KEY=(\S+)/)[1]

// 只读清点(2026-09-21,一次写都没发)。★★ **「以谁的身份读」写出来**:
//   `psql` 直连,`current_user = postgres`,`rolbypassrls = t`,
//   `purchase_orders` / `purchase_order_lines` / `purchase_order_payment_terms`
//   **三张全是基表(`relkind 'r'`)** —— 所以下面这些数是**真行数**,不是一次权限拒绝。
const PO_FORMULA = { id: '6d2ce1ff-728e-4594-bd7b-155002f54de7', code: 'PO-2026-0003', ccy: 'USD',
    lineId: '75e100ac-04ac-49a1-bb8f-3dad390d8c22', received: 700, qty: 700, removable: false }
const PO_PLAIN = { id: 'e6c26a97-579e-4475-9057-7db0af5471d0', code: 'PO-2026-0011', ccy: 'SGD',
    lineId: '69bcdcf8-886a-4ac7-bb24-9b50c7b60914', received: 0, qty: 1, removable: true }

/** ★ 桥上那一期【应当】长什么样 —— `AmendTerm` 的七个键,**而 `uid` 不在其中**。 */
const TERM_KEYS = ['seq', 'label', 'mode', 'percentage', 'fixed_amount', 'trigger_event', 'due_date']

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const rest = (p, o = {}) => fetch(URL_ + p, { ...o, headers: {
    apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, 'Content-Type': 'application/json', ...(o.headers || {}) } })
const fail = []
const probe = (id, ok, detail) => {
    if (!ok) fail.push(`${id}: ${detail}`)
    console.log(`${ok ? '✓' : '✗'} ${id.padEnd(62)} ${detail}`)
}
const note = (id, detail) => console.log(`· ${id.padEnd(62)} ${detail}`)
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
    acquireOrExit('probe-draft7', { ownExit: false })
    openPlan('probe-draft7')
    await reapStalePlans()
    if (!existsSync(join(ROOT, '.next/BUILD_ID'))) throw new Error('.next/BUILD_ID 不在 —— 先 npm run build')
    if (!existsSync(CHROME)) throw new Error('chrome not at ' + CHROME)
    mkdirSync(join(ROOT, 'docs/captures'), { recursive: true })
    for (const p of [PORT, CDP_PORT]) { try { execSync(`lsof -ti tcp:${p} | xargs -r kill -9`, { stdio: 'ignore' }) } catch {} }

    const email = `draft7probe-${Date.now()}@test.local`
    const cu = await (await rest('/auth/v1/admin/users', { method: 'POST',
        body: JSON.stringify({ email, password: 'draft7-probe-1', email_confirm: true }) })).json()
    const accountId = cu.id
    if (!accountId) throw new Error('账号建不出来: ' + JSON.stringify(cu).slice(0, 300))
    planDelete(`/rest/v1/user_roles?user_id=eq.${accountId}`, `revoke grant ${accountId}`, ORDER.GRANT)
    planDelete(`/auth/v1/admin/users/${accountId}`, `delete account ${accountId}`, ORDER.ACCOUNT)
    const roles = await (await rest('/rest/v1/roles?select=id&code=eq.admin')).json()
    await rest('/rest/v1/user_roles', { method: 'POST', body: JSON.stringify(ephemeralGrantBody(accountId, roles[0].id)) })
    const sess = await (await fetch(URL_ + '/auth/v1/token?grant_type=password', { method: 'POST',
        headers: { apikey: ANON, 'Content-Type': 'application/json' },
        body: JSON.stringify({ email, password: 'draft7-probe-1' }) })).json()
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
    // ★ PROBE-UNBOUNDED-CDP-WAIT:导航 120s(打库的详情页实测过 30s 上下),其余 30s。
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
    const rowCellEl = (t, n, nth) => `(() => {
        const rows = Array.from(document.querySelectorAll('${T}')[${t}].querySelectorAll('tbody tr')).filter(r => r.querySelector('button[aria-expanded]'))
        return rows[${n}].querySelectorAll('td')[${nth}] || null })()`
    const heads = (t) => `Array.from(document.querySelectorAll('${T}')[${t}].querySelectorAll('thead th'))
        .filter(e => e.offsetParent !== null).map(e => e.textContent.trim())`
    const namedHeads = (t) => `(${heads(t)}).filter(h => h !== '')`
    const bridge = (key) => `(() => { const f = document.querySelector('form'); const fd = new FormData(f)
        let parsed = null
        try { parsed = JSON.parse(String(fd.get('${key}') ?? 'null')) } catch { parsed = 'PARSE_ERROR' }
        return { count: fd.getAll('${key}').length, raw: String(fd.get('${key}') ?? ''), parsed } })()`
    /** 整张表单上的具名控件。
     *  ⚠★★【探针缺陷 ①,照直留在落点上】★★ 第一版按 `[name]` 直接数,读回 **13** 个 ——
     *    多出来的四个是 **`$ACTION_1:0` · `$ACTION_1:1` · `$ACTION_KEY` · `$ACTION_REF_1`**,
     *    ☞ 那是 **React 给 `<form action={serverAction}>` 自己插的 Server Action 传输字段**,
     *      不是这一页的控件,而且**搬家前就在那里**(这个表单一直是 `action={formAction}`)。
     *  ☞ 所以判据分成两半,而**两个数都报出来** —— 把框架那四个悄悄滤掉、
     *    只报一个「9」,会让下一个人以为这一页上只有九个 `name`。 */
    const namedOnPage = `(() => {
        const all = Array.from(document.querySelector('form').querySelectorAll('[name]')).map(e => e.getAttribute('name')).sort()
        return { own: all.filter(n => !n.startsWith('$')), framework: all.filter(n => n.startsWith('$')) } })()`
    /** ★ 屏幕上真的读得到的字 —— `innerText` 认 CSS,`textContent` 不认。
     *  ⚠★★【探针缺陷 ③】★★ 第一版用 `textContent`,于是它把**桌面那一份
     *    `hidden sm:block` 的 `edit()`** 也读了进来:390px 上「低于已收」那句话
     *    读回来是**两遍**。那条判据当时是绿的,**而它绿得没有道理** ——
     *    它证明的是「那句话在 DOM 里」,不是「那句话在屏幕上」。
     *  ☞ 与 DRAFT-6 探针第 ⑤ 轮那一条逐字同源:**一个读 DOM 的判据,要说清它认的是哪一层。** */
    const vtext = (expr) => `(() => { const el = ${expr}; return el ? el.innerText.trim() : null })()`
    /** 表【里面】还有没有带 name 的控件 —— (b) 那条裁定的正面证据。 */
    const namedInTables = `Array.from(document.querySelectorAll('${T} [name]')).map(e => e.getAttribute('name'))`
    const hasEditTerms = `(() => { const fd = new FormData(document.querySelector('form')); return fd.has('edit_terms') })()`
    /** 付款计划那一块(用 `edit_terms` 这个勾选框定位它的容器,不靠 class 串)。 */
    const termsBox = `document.querySelector('input[name="edit_terms"]').closest('div.border')`
    const overflow = `({ scrollWidth: document.documentElement.scrollWidth,
                         clientWidth: document.documentElement.clientWidth })`
    const tableScroll = (t) => `(() => {
        const tbl = document.querySelectorAll('${T}')[${t}]
        if (!tbl) return null
        const box = tbl.closest('.overflow-x-auto')
        return box ? { scrollWidth: box.scrollWidth, clientWidth: box.clientWidth } : null })()`

    const ov = async (label) => {
        const o = await js(overflow)
        probe(`${label} · 整页不横向溢出`, o.scrollWidth <= o.clientWidth,
            `scrollWidth ${o.scrollWidth} / clientWidth ${o.clientWidth}`)
        return o
    }

    /** 桥上那三期的形状:3 行 · 七个键一个不多一个不少 · **没有 uid**。 */
    const checkTerms = (b, label) => {
        const rows = Array.isArray(b.parsed) ? b.parsed : []
        probe(`${label} · terms_json 只画一遍`, b.count === 1, `出现 ${b.count} 次`)
        probe(`${label} · terms_json 有 3 期`, rows.length === 3, `${rows.length} 行`)
        const keysOk = rows.length === 3 && rows.every((r) =>
            JSON.stringify(Object.keys(r).sort()) === JSON.stringify([...TERM_KEYS].sort()))
        probe(`★★ ${label} · 键逐字是 AmendTerm 那七个`, keysOk,
            `第 0 行的键 = ${JSON.stringify(rows[0] ? Object.keys(rows[0]) : null)}`)
        const noUid = rows.every((r) => !('uid' in r))
        probe(`★★★ ${label} · 【没有 uid】—— 它在那一期【旁边】,不在里面(裁定:无剥离动作)`,
            noUid, `含 uid 的行 ${rows.filter((r) => 'uid' in r).length} 个`)
    }

    // ══════════════════════════════════════════════════════════════════════
    // ARM A · PO-2026-0003 @390 —— has_formula=true · 已收 700 → 删不掉
    // ══════════════════════════════════════════════════════════════════════
    await view(390)
    await goto(`/purchasing/orders/${PO_FORMULA.id}/amend`, `${PO_FORMULA.code} @390`)
    await js(SET); await js(PANEL)

    const nA = await js(namedHeads(0))
    probe(`${PO_FORMULA.code} @390 · 行号是【唯一】留在那一行上的列`,
        JSON.stringify(nA) === JSON.stringify(['#']), `有名字的列 = ${JSON.stringify(nA)}`)

    const scA = await js(tableScroll(0))
    probe(`★★ ${PO_FORMULA.code} @390 · 表自己不横滚`,
        !!scA && scA.scrollWidth <= scA.clientWidth,
        `表壳 scrollWidth ${scA && scA.scrollWidth} / clientWidth ${scA && scA.clientWidth}`)

    // ★★ 已收:一列【只读且非 priority】的列 —— page-owned 下展开区不画它,
    //    所以它必须叠在行号那一格里,而且是【零次点按】。
    const seqCell = await js(vtext(rowCellEl(0, 0, 1)))
    probe(`★★★ ${PO_FORMULA.code} @390 · 【已收】零次点按读得到(叠在行号格里)`,
        /700/.test(seqCell) && /Received/i.test(seqCell), `行号格读出来 = ${JSON.stringify(seqCell)}`)

    const namedA = await js(namedOnPage)
    probe('★★★ 这一页自己的具名控件恰好九个(六个抬头字段 + edit_terms + 两座桥)',
        namedA.own.length === 9 && namedA.own.includes('lines_json') && namedA.own.includes('terms_json')
        && namedA.own.includes('edit_terms'), `name = ${JSON.stringify(namedA.own)}`)
    note('· 另有 React 自己插的 Server Action 传输字段(搬家前就在)', JSON.stringify(namedA.framework))
    probe('★★★ 表【里面】一个带 name 的控件都没有', (await js(namedInTables)).length === 0,
        `表里的 name = ${JSON.stringify(await js(namedInTables))}`)

    // ── 不勾 edit_terms:那个键【根本不在】FormData 里 ──────────────────────
    const has0 = await js(hasEditTerms)
    probe('★★★ 不勾 · formData.has("edit_terms") === false —— 而 terms_json 仍然画着',
        has0 === false, `has(edit_terms) = ${has0}`)
    const tb0 = await js(bridge('terms_json'))
    probe('★★★ 不勾 · terms_json 【无条件渲染】(住在 {editTerms && …} 外面)',
        tb0.count === 1 && Array.isArray(tb0.parsed) && tb0.parsed.length === 3,
        `count ${tb0.count} · ${Array.isArray(tb0.parsed) ? tb0.parsed.length : tb0.parsed} 行`)
    note('☞ 于是「不动付款计划」与「清空它」分得开', '分开它们的是 edit_terms,不是那座桥在不在')

    // ── 勾上 edit_terms,3 期 ────────────────────────────────────────────────
    await js(`document.querySelector('input[name="edit_terms"]').click()`)
    await sleep(400)
    const has1 = await js(hasEditTerms)
    probe('勾上 · formData.has("edit_terms") === true', has1 === true, `has(edit_terms) = ${has1}`)
    checkTerms(await js(bridge('terms_json')), `★ ${PO_FORMULA.code} @390 勾上`)

    // ── 把三期全删掉 → terms_json === "[]" ────────────────────────────────
    for (let i = 0; i < 3; i++) {
        await js(`(() => { const btns = Array.from(${termsBox}.querySelectorAll('button[type="button"]'))
            .filter(b => b.textContent.trim() === 'Remove')
            return btns.length ? (btns[btns.length - 1].click(), true) : false })()`)
        await sleep(250)
    }
    const tbEmpty = await js(bridge('terms_json'))
    probe('★★★ 三期全删掉 · terms_json === "[]" —— 而那【不是】不动它,是明说清空',
        tbEmpty.raw === '[]', `terms_json = ${JSON.stringify(tbEmpty.raw)}`)
    const warnShown = await js(`(() => { const b = ${termsBox}
        return /empty/i.test(b.textContent) })()`)
    probe('★ 清空之后那句告警在屏幕上', warnShown === true, `termsEmptyWarning 可见 = ${warnShown}`)

    // ── 数量压到已收以下:那句告警必须【零次点按】读得到(Tim 的 Q5) ────────
    await openRow(0, 0)
    /* ⚠★★【探针缺陷 ②,照直留在落点上】★★ 第一版按 `input` 数,钉死 2,读回 **3**。
       ☞ 多的那一个是**移除勾选框** —— 它走 `rowActions`,而 `rowActions` 在手机上
         正是画在**展开区末尾**(Tim 的 Q7)。**产品是对的,判据把两族控件混成一族了。**
       ☞ 所以现在两族分开数,而那第三个当场变成 Q7 落地的一条【正面证据】。 */
    const insA = await js(inPanel(0, 0, 'input[type="text"]') + '.length')
    probe(`${PO_FORMULA.code} @390 · 数量与单价在展开区里(手机上唯一能打字的地方)`,
        insA === 2, `第 0 行自己那块展开区里的文本框 ${insA} 个`)
    const cbA = await js(inPanel(0, 0, 'input[type="checkbox"]') + '.length')
    probe(`★★ ${PO_FORMULA.code} @390 · Q7 · 移除勾选也在这块展开区里(它走 rowActions)`,
        cbA === 1, `展开区里的勾选框 ${cbA} 个`)
    const selA = await js(inPanel(0, 0, 'select') + '.length')
    probe(`${PO_FORMULA.code} @390 · 定价状态那个下拉也在展开区里`, selA === 1,
        `展开区里的 select ${selA} 个`)
    // ★ 挂了公式的行:「定价」那一项必须禁用(CMP-2,搬家前逐字相同)
    const fixedDisabled = await js(`(() => { const s = ${inPanel(0, 0, 'select')}[0]
        const o = Array.from(s.options).find(o => o.value === 'fixed')
        return o ? o.disabled : null })()`)
    probe(`★★ ${PO_FORMULA.code} · has_formula 的行【标不成定价】(那一项禁用)`,
        fixedDisabled === true, `option[value=fixed].disabled = ${fixedDisabled}`)

    await js(`(() => { const els = ${inPanel(0, 0, 'input')}; return window.__set(els[0], '500') })()`)
    await sleep(400)
    const seqAfter = await js(vtext(rowCellEl(0, 0, 1)))   // ★ 行号那一格(0=展开钮 1=行号 2=数量)
    probe('★★★ Tim 的 Q5 · 「低于已收」那句告警【零次点按】读得到(它叠在行号那一格里)',
        /700/.test(String(seqAfter)) && /below/i.test(String(seqAfter)),
        `行号格【屏幕上】读出来 = ${JSON.stringify(seqAfter)}`)
    /* ★★ 而「屏幕上有几份」要单独问一次 —— `page-owned` 下同一格里
       `edit()` 与 `render()` 【两份都在 DOM 里】(桌面那份靠 `hidden sm:block` 藏着)。
       390px 上看得见的必须**恰好一份**。 */
    /* ⚠★★★【探针缺陷 ④ —— 而它是 DRAFT-6 第 ⑤ 轮那一条的【第二种穿法】】★★★
       第一版问的是 `p.offsetParent !== null`,读回 **0**,而 `innerText` 明明读得到那句话。
       ☞ 逐项量下来(`getComputedStyle`):
         · `hidden sm:block` 那一份 **`display: none`** —— 产品是对的,桌面那份确实藏着;
         · ⚠ **两份 `<p>` 的 `offsetParent` 【都是 null】**,包括看得见的那一份。
       ☞ 所以 `offsetParent` 在这里**答不了「屏幕上有没有」** —— 它答的是
         「有没有一个定位祖先」,而那是另一个问题。
         (同理 `getComputedStyle(p).display` 也答不了:`display:none` 不会传到子元素的
          计算值上,两份读回来都是 `block`。)
       ☞ 判据换成**直接问几何**:`getBoundingClientRect().height > 0` ——
         一个不占位置的元素,在屏幕上就是没有。 */
    const warnVisible = await js(`(() => {
        const tr = ${rowCellEl(0, 0, 1)}.closest('tr')
        return Array.from(tr.querySelectorAll('p'))
            .filter(p => /below/i.test(p.textContent) && p.getBoundingClientRect().height > 0).length })()`)
    const warnInDom = await js(`(() => {
        const tr = ${rowCellEl(0, 0, 1)}.closest('tr')
        return Array.from(tr.querySelectorAll('p')).filter(p => /below/i.test(p.textContent)).length })()`)
    probe('★★★ @390 · 那一行上那句告警在【屏幕上】恰好一份 —— 而这正是第一版落错地方的那一条',
        warnVisible === 1, `那一行:屏幕上 ${warnVisible} 份 / DOM 里 ${warnInDom} 份`)

    // ★ 收过货的行删不掉 —— 勾选框禁用并说明
    const remA = await js(`(() => { const p = window.__panel(0, 0); if (!p) return null
        const cb = p.querySelector('input[type="checkbox"]')
        return cb ? { disabled: cb.disabled, label: cb.closest('label').textContent.trim() } : null })()`)
    probe(`★★ ${PO_FORMULA.code} @390 · 移除勾选在【展开区末尾】,而已收 700 → 按不动并说明`,
        !!remA && remA.disabled === true && /cannot remove/i.test(remA.label),
        `${JSON.stringify(remA)}`)

    const lbA = await js(bridge('lines_json'))
    probe('★★ lines_json 只画一遍,而它住在表【外面】', lbA.count === 1, `出现 ${lbA.count} 次`)
    probe('★ 桥上带着打进去的那个数量(原始字符串,一个转换都不在这一侧做)',
        Array.isArray(lbA.parsed) && lbA.parsed[0] && lbA.parsed[0].quantity === '500',
        `第 0 行 = ${JSON.stringify(lbA.parsed && lbA.parsed[0])}`)
    probe('★★★ Tim 的 Q1 · 桥上带着 line_no —— 五条具名拒绝从此点的是行号,不是「?」',
        Array.isArray(lbA.parsed) && lbA.parsed[0] && lbA.parsed[0].line_no === 1,
        `line_no = ${JSON.stringify(lbA.parsed && lbA.parsed[0] && lbA.parsed[0].line_no)}`)

    const shot = await S('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true })
    writeFileSync(join(ROOT, 'docs/captures/draft7-amend-390.png'), Buffer.from(shot.data, 'base64'))
    note('★ 390px 截图', 'docs/captures/draft7-amend-390.png')

    const oA = await ov(`${PO_FORMULA.code} @390`)
    note('☞ 这一读数还掉了一笔在册的 NOT MEASURED',
        `known-issues.md:6695 写着「它在 390px 上大概仍然放不下,没有量过」→ 实测 ${oA.scrollWidth}/${oA.clientWidth}`)

    // ══════════════════════════════════════════════════════════════════════
    // ARM B · PO-2026-0011 @390 —— 已收 0 → **删得掉**,于是被删的那一行进得了桥
    // ══════════════════════════════════════════════════════════════════════
    await goto(`/purchasing/orders/${PO_PLAIN.id}/amend`, `${PO_PLAIN.code} @390`)
    await js(SET); await js(PANEL)

    await openRow(0, 0)
    const remB = await js(`(() => { const p = window.__panel(0, 0); if (!p) return null
        const cb = p.querySelector('input[type="checkbox"]')
        return cb ? { disabled: cb.disabled, label: cb.closest('label').textContent.trim() } : null })()`)
    probe(`★★ ${PO_PLAIN.code} @390 · 已收 0 → 移除勾选【按得动】`,
        !!remB && remB.disabled === false && /remove this line/i.test(remB.label),
        `${JSON.stringify(remB)}`)

    await js(`window.__panel(0, 0).querySelector('input[type="checkbox"]').click()`)
    await sleep(400)
    const lbB = await js(bridge('lines_json'))
    const row0 = Array.isArray(lbB.parsed) ? lbB.parsed[0] : null
    probe('★★★ 被删的那一行进了桥:remove === true,带着它自己的 id',
        !!row0 && row0.remove === true && row0.id === PO_PLAIN.lineId,
        `第 0 行 = ${JSON.stringify(row0)}`)
    note('⚠ 而「恰好 { id, remove: true }」是【代码收据】,不是这一侧的测量',
        'actions.ts:118 `if (l.remove) return { id: l.id, remove: true }` —— 与搬家前 :37 逐字节相同;量它要发一次提交')
    const tinted = await js(`(() => { const rows = Array.from(document.querySelectorAll('${T}')[0]
        .querySelectorAll('tbody tr')).filter(r => r.querySelector('button[aria-expanded]'))
        return rows[0].className })()`)
    probe('★ 能力 B · 勾掉的行变灰(与搬家前逐字相同的两个类)',
        /bg-gray-100/.test(tinted) && /text-gray-400/.test(tinted), `class = ${JSON.stringify(tinted)}`)

    // ── 这一张的 terms 三条判据也跑一遍(两张各 3 期) ────────────────────
    const hasB0 = await js(hasEditTerms)
    probe(`★ ${PO_PLAIN.code} @390 · 不勾 · has("edit_terms") === false`, hasB0 === false, `${hasB0}`)
    await js(`document.querySelector('input[name="edit_terms"]').click()`)
    await sleep(400)
    checkTerms(await js(bridge('terms_json')), `★ ${PO_PLAIN.code} @390 勾上`)
    for (let i = 0; i < 3; i++) {
        await js(`(() => { const btns = Array.from(${termsBox}.querySelectorAll('button[type="button"]'))
            .filter(b => b.textContent.trim() === 'Remove')
            return btns.length ? (btns[btns.length - 1].click(), true) : false })()`)
        await sleep(250)
    }
    const tbB = await js(bridge('terms_json'))
    probe(`★★★ ${PO_PLAIN.code} @390 · 三期全删掉 · terms_json === "[]"`,
        tbB.raw === '[]', `terms_json = ${JSON.stringify(tbB.raw)}`)

    probe(`${PO_PLAIN.code} @390 · 表里一个带 name 的控件都没有`,
        (await js(namedInTables)).length === 0, `表里的 name = ${JSON.stringify(await js(namedInTables))}`)
    await ov(`${PO_PLAIN.code} @390`)

    // ══════════════════════════════════════════════════════════════════════
    // ARM C · 1280 桌面 —— 五列有名字,动作列在最右,桥仍然只画一遍
    // ══════════════════════════════════════════════════════════════════════
    await view(1280)
    await goto(`/purchasing/orders/${PO_FORMULA.id}/amend`, `${PO_FORMULA.code} @1280`)
    await js(SET); await js(PANEL)

    const nC = await js(namedHeads(0))
    probe(`★ ${PO_FORMULA.code} @1280 · 桌面照旧五列有名字`,
        nC.length === 5 && nC[0] === '#' && /Received/i.test(nC[2]),
        `有名字的列 = ${JSON.stringify(nC)}`)
    const headCells = await js(`document.querySelectorAll('${T}')[0].querySelectorAll('thead th').length`)
    probe(`★ ${PO_FORMULA.code} @1280 · 动作列是组件自己加的第 N+1 格(5 + 展开钮格 + 动作格)`,
        headCells === 7, `thead 的格子 ${headCells} 个(手机展开钮那格 sm:hidden,这里不可见但在 DOM 里)`)

    const namedC = await js(namedOnPage)
    probe('★★ @1280 · 这一页自己的具名控件仍然恰好九个', namedC.own.length === 9, `name = ${JSON.stringify(namedC.own)}`)
    note('· @1280 · React 的 Server Action 传输字段', JSON.stringify(namedC.framework))
    probe('★★ @1280 · 表里一个带 name 的控件都没有', (await js(namedInTables)).length === 0,
        `表里的 name = ${JSON.stringify(await js(namedInTables))}`)

    // 桌面就地打字 → 同一座桥,仍然一份
    await js(`(() => { const tds = document.querySelectorAll('${T}')[0]
        .querySelectorAll('tbody tr')[0].querySelectorAll('input[type="text"]')
        return window.__set(tds[0], '650') })()`)
    await sleep(400)
    const lbC = await js(bridge('lines_json'))
    probe('★★ @1280 · 桌面打的字进同一座桥,而桥仍然【一份】',
        lbC.count === 1 && lbC.parsed[0].quantity === '650',
        `count ${lbC.count} · quantity = ${JSON.stringify(lbC.parsed[0].quantity)}`)

    const hasC = await js(hasEditTerms)
    probe('★★ @1280 · 不勾 · has("edit_terms") === false', hasC === false, `${hasC}`)
    await js(`document.querySelector('input[name="edit_terms"]').click()`)
    await sleep(400)
    checkTerms(await js(bridge('terms_json')), `★ ${PO_FORMULA.code} @1280 勾上`)
    await ov(`${PO_FORMULA.code} @1280`)

    // ══════════════════════════════════════════════════════════════════════
    // 收尾复核 —— ★ 一次写都没发,证明给它看(只读,身份写在抬头)
    // ══════════════════════════════════════════════════════════════════════
    for (const po of [PO_FORMULA, PO_PLAIN]) {
        const l = await (await rest(`/rest/v1/purchase_order_lines?select=id,line_no,quantity,estimated_unit_price,price_status&purchase_order_id=eq.${po.id}&order=line_no`)).json()
        const t = await (await rest(`/rest/v1/purchase_order_payment_terms?select=seq&purchase_order_id=eq.${po.id}`)).json()
        probe(`★★★ 复核 · ${po.code} 的行与期次【逐字未变】`,
            l.length === 1 && Number(l[0].quantity) === po.qty && t.length === 3,
            `行 ${l.length} 条(数量 ${l[0] && l[0].quantity},预期 ${po.qty})· 期次 ${t.length} 期`)
    }
    note('⚠ NOT MEASURED · null 与 [] 在【数据库那一侧】的分别', '量它要发一次写,而委托书禁止 —— 这一侧证的是桥上三种形态分得开')
    note('⚠ NOT MEASURED · 多行对位', '五张可改的单每一张都只有 1 行(postgres / rolbypassrls=t / 三张全是基表 relkind r);一行没有配对可错位')
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
