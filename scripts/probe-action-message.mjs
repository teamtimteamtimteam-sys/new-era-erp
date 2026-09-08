#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// ALERT-1(2026-09-08)· 【把那 18 条从来没有被机器走过的错误路,真的走一遍】
// ════════════════════════════════════════════════════════════════════════════
// 委托书的 STEP 3 逐字写着:
//   「原生 alert 点不到,所以这 18 条错误路【从来没有被机器检查过】。
//     只把它们改个样子,会让这句话仍然是真的,而看上去像是做完了。」
//
// ★★【而本刀量出来的东西,比"点不到"更坏】★★
//   这十处走的是表更新,而每张表的 UPDATE 策略都是 USING(p) WITH CHECK(p) ——
//   两侧同一个谓词。一个不满足 p 的人【先卡在 USING 上】:那一行根本没被匹配到,
//   于是零行、不抛异常、error 为 null。调用点因此 return { success: true }。
//   **那条 alert 不是"点不到",是【永远等不到】。**
//   活库实测(真账号 Fu Sheng,无编辑权,BEGIN…ROLLBACK):十张表全部
//   `rows=0 raised=NONE`。
//   ☞ 所以本探针最要紧的一格不是"横幅长得对不对",是
//     **【那一句话现在到底出不出得来】** —— 它在本刀之前一次都没有出现过。
//
// ════════════════════════════════════════════════════════════════════════════
// ★【怎么驱动一次拒绝:一个【看得见、改不动】的会话】★
// ════════════════════════════════════════════════════════════════════════════
//   线上 `auditor` 角色正是这个形状(实测:materials/finance/suppliers 三个模块
//   view 全有、edit 全无)。一次性账号挂上它,就站在了那六个真人里
//   Phua / Sandra / Fu Sheng 每天所在的位置上。
//   ☞ 不新建角色、不改任何人的授权;账号与授权都进 ephemeral 计划,按反序回收。
//   ☞ **不写任何业务数据**:本探针驱动的每一个动作【都是要被拒绝的】,
//     所以它按定义不会留下痕迹 —— 而这正是"拒绝路"能被安全驱动的原因。
//
// ════════════════════════════════════════════════════════════════════════════
// ★【每一格都自带反臂】★ 先断言"横幅这会儿不在",再动作,再断言"它在了"。
//   一条只会说"在"的断言,对着一个永远显示横幅的树也会绿。
//
// ★【本脚本【必须】能红,而且要能演示】★
//     PROBE_FAULT=blind        选择器全瞎        → 全红,而且说"我瞎了"
//     PROBE_FAULT=no-banner    假装横幅没出现    → A2/B2 红
//     PROBE_FAULT=raw-code     假装正文是机器码  → A4/B4 红(措辞那一族)
//     PROBE_FAULT=d-operable   假装丁类钮还在    → C2 红
//
// ════════════════════════════════════════════════════════════════════════════
// ★【覆盖率:18 处里 15 处真的被驱动过,没跑的三处按名列在这里】★
// ════════════════════════════════════════════════════════════════════════════
//   跑过(15):materials / suppliers / customers 三处行内删除 · 供应商状态面板
//   (丁类,判的是"钮不在、理由在")· 定价公式删除 · GST 开关 · 期间锁定 ·
//   分录冲销 · 收付款冲销 · 费用冲销 · 发票作废 · 关账 · 重开期间 ·
//   取消对账 · 撤销牌价。
//
//   【没跑,而且不假装跑过】(3):
//   ① `metal-prices/[id]/edit` 的删除 —— **这一页本来就把 module.pricing.edit
//      当门**(requireEditPermission)。只有 view 的会话根本进不去,
//      那个钮不在树里是【对的】。它的权限拒绝早就是丁类;横幅只在
//      "非权限的驱动错误"时才出得来,而那种错误没法安全制造。
//   ② `bank/statements/[id]` 的删除 —— 页面写着
//      `stmt.status === 'open' ? <DeleteStatementButton…/> : undefined`,
//      而这套数据里没有一张 open 的对账单。造一张=往共享测试数据里写业务行,
//      Tim 在闸上禁了。
//   ③ `tools/tasks` 看板的拖放 —— 要一次真的拖拽手势,还要一行 employees
//      才过得了 can_edit_task。它的【服务端那一半】已被零行落地的判据覆盖,
//      但【那一次拖拽】没有被机器走过。
//
// 用法:npm run build && node scripts/probe-action-message.mjs
// ════════════════════════════════════════════════════════════════════════════

import { spawn } from 'node:child_process'
import { readFileSync, existsSync } from 'node:fs'
import { join } from 'node:path'
import { createConnection } from 'node:net'
import { acquireOrExit, release } from './liveLock.mjs'
import { openPlan, planDelete, ephemeralGrantBody, runPlan, reapStalePlans, installExitHooks, ORDER } from './ephemeral.mjs'

const ROOT = new URL('..', import.meta.url).pathname
const PORT = 3204                 // 3198 phone · 3199 冒烟 · 3201 avatar · 3202 tiers · 3203 confirm
const CDP_PORT = 9340
const CHROME_CANDIDATES = ['mac_arm-152.0.7977.75', 'mac_arm-152.0.7977.54'].map((v) =>
    join(process.env.HOME, `.cache/puppeteer/chrome-headless-shell/${v}/chrome-headless-shell-mac-arm64/chrome-headless-shell`))
const CHROME = CHROME_CANDIDATES.find(existsSync)
const FAULT = process.env.PROBE_FAULT || ''

const env = readFileSync(join(ROOT, '.env.local'), 'utf8')
const URL_ = env.match(/NEXT_PUBLIC_SUPABASE_URL=(\S+)/)[1]
const ANON = env.match(/NEXT_PUBLIC_SUPABASE_ANON_KEY=(\S+)/)[1]
const SERVICE = env.match(/SUPABASE_SERVICE_ROLE_KEY=(\S+)/)[1]
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const rest = (p, o = {}) => fetch(URL_ + p, { ...o, headers: {
    apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, 'Content-Type': 'application/json', ...(o.headers || {}) } })

const results = []; const fail = []
function probe(id, ok, detail) { results.push({ id, ok, detail }); if (!ok) fail.push(`${id}: ${detail}`)
    console.log(`  ${ok ? '✓' : '✗'} ${id}  ${detail}`) }

const waitPort = (p, ms) => new Promise((res) => { const t0 = Date.now()
    ;(function tick() { const s = createConnection({ port: p, host: '127.0.0.1' })
        s.on('connect', () => { s.destroy(); res(true) })
        s.on('error', () => { s.destroy(); Date.now() - t0 > ms ? res(false) : setTimeout(tick, 300) }) })() })

let server, chrome, accountId
function killChildren() {
    try { if (chrome?.pid) process.kill(-chrome.pid) } catch {}
    try { if (server?.pid) process.kill(-server.pid) } catch {}
}
installExitHooks({ onFinish: () => { killChildren(); try { release() } catch {} } })

try {
    if (!CHROME) throw new Error('chrome-headless-shell 找不到')
    if (!existsSync(join(ROOT, '.next/BUILD_ID')))
        throw new Error('.next/BUILD_ID 不在 —— 本支跑在【生产构建】上。先 npm run build。')
    acquireOrExit('probe-action-message', { ownExit: false })
    openPlan('scripts/probe-action-message.mjs')
    await reapStalePlans()

    // ── 一个【看得见、改不动】的一次性会话 ────────────────────────────────
    const email = `almprobe-${Date.now()}@test.local`
    const cu = await (await rest('/auth/v1/admin/users', { method: 'POST',
        body: JSON.stringify({ email, password: 'alm-probe-1', email_confirm: true }) })).json()
    accountId = cu.id
    if (!accountId) throw new Error('账号建不出来: ' + JSON.stringify(cu).slice(0, 300))
    // ★ LEAK-1:先删授权再删账号。
    planDelete(`/rest/v1/user_roles?user_id=eq.${accountId}`, `revoke almprobe grant ${accountId}`, ORDER.GRANT)
    planDelete(`/auth/v1/admin/users/${accountId}`, `delete almprobe account ${accountId}`, ORDER.ACCOUNT)

    const roles = await (await rest('/rest/v1/roles?select=id,code&code=eq.auditor')).json()
    if (!roles?.[0]?.id) throw new Error('线上没有 auditor 角色 —— 本探针无从驱动')
    await rest('/rest/v1/user_roles', { method: 'POST',
        body: JSON.stringify(ephemeralGrantBody(accountId, roles[0].id)) })

    // ★ 断言这个会话【真的是】那个形状 —— 不然整支探针在测一个错的前提。
    const perms = await (await rest(
        `/rest/v1/role_permissions?select=permission_code&role_id=eq.${roles[0].id}`)).json()
    const codes = new Set((perms || []).map((r) => r.permission_code))
    const shapeOk = codes.has('module.materials.view') && !codes.has('module.materials.edit')
                 && codes.has('module.finance.view')   && !codes.has('module.finance.edit')
                 && codes.has('module.suppliers.view') && !codes.has('module.suppliers.edit')
    if (!shapeOk) throw new Error('auditor 不再是"看得见改不动"的形状 —— 前提没了,判词无效')

    const sess = await (await fetch(URL_ + '/auth/v1/token?grant_type=password', { method: 'POST',
        headers: { apikey: ANON, 'Content-Type': 'application/json' },
        body: JSON.stringify({ email, password: 'alm-probe-1' }) })).json()
    if (!sess?.access_token) throw new Error('登录失败')
    const cookieName = 'sb-' + URL_.split('//')[1].split('.')[0] + '-auth-token'
    const cookieValue = 'base64-' + Buffer.from(JSON.stringify(sess)).toString('base64url')

    // ── 取真的 id(取不到就响亮中止,不当成跳过)──────────────────────────
    const mats = await (await rest('/rest/v1/materials?select=id,name&deleted_at=is.null&limit=1')).json()
    if (!mats?.[0]?.id) throw new Error('materials 一行都没有 —— A 组无从驱动')
    // (matName 不再用于判据 —— 见 A3b 那一段:比的是"刚才确认的那一个")

    const jes = await (await rest('/rest/v1/journal_entries?select=id&limit=1')).json()
    const jeId = jes?.[0]?.id || null

    const sups = await (await rest('/rest/v1/suppliers?select=id,code&deleted_at=is.null&limit=1')).json()
    if (!sups?.[0]?.id) throw new Error('suppliers 一行都没有 —— C 组无从驱动')
    const supId = sups[0].id

    // ── D 组:把剩下的调用点也真的走一遍 ────────────────────────────────
    // ★ 取不到 id 的站点【不静默跳过】—— 它会变成一格红的「无从驱动」,
    //   因为"没跑"与"跑过了"在报告里必须长得不一样(AGENTS.md 的覆盖率法则)。
    const one = async (path) => (await (await rest(path)).json())?.[0] ?? null
    const payment  = await one('/rest/v1/payments?select=id&limit=1')
    const expense  = await one('/rest/v1/expenses?select=id&limit=1')
    // ★【第一版随手取了"第一张发票",而它恰好【已经作废】】
    //   页面写着 `{!isVoid && <VoidInvoiceControl …/>}` —— 控件因此根本没渲染,
    //   探针报"点不到"。那不是产品的毛病,是【判据没有走人真的走的那条路】:
    //   要驱动作废,就得先取一张【还能作废的】发票。
    const invoice  = await one('/rest/v1/invoices?select=id,status&status=not.eq.void&limit=1')
    const stmt     = await one('/rest/v1/bank_statements?select=id&deleted_at=is.null&limit=1')
    const price    = await one('/rest/v1/metal_prices?select=id&deleted_at=is.null&limit=1')
    const formula  = await one('/rest/v1/pricing_formulas?select=id&deleted_at=is.null&limit=1')
    const fxRate   = await one('/rest/v1/fx_rates?select=id&limit=1&order=rate_date.desc')

    // ── 起服务器与浏览器 ──────────────────────────────────────────────────
    server = spawn('npx', ['next', 'start', '-p', String(PORT)], { cwd: ROOT, detached: true, stdio: ['ignore', 'pipe', 'pipe'] })
    server.stderr.on('data', () => {})
    if (!await waitPort(PORT, 90000)) throw new Error(`next start 没在 :${PORT} 起来`)
    const origin = `http://localhost:${PORT}`
    console.log(`· next start :${PORT}`)

    chrome = spawn(CHROME, [`--remote-debugging-port=${CDP_PORT}`, '--headless', '--disable-gpu',
        '--no-sandbox', '--hide-scrollbars', 'about:blank'], { detached: true, stdio: ['ignore', 'pipe', 'pipe'] })
    if (!await waitPort(CDP_PORT, 30000)) throw new Error('chrome CDP 没起来')
    const { webSocketDebuggerUrl } = await (await fetch(`http://127.0.0.1:${CDP_PORT}/json/version`)).json()
    const sock = new WebSocket(webSocketDebuggerUrl)
    await new Promise((res, rej) => { sock.onopen = res; sock.onerror = rej })
    let msgId = 0; const pending = new Map()
    sock.onmessage = (m) => { const d = JSON.parse(m.data)
        if (d.id && pending.has(d.id)) { const { res, rej } = pending.get(d.id); pending.delete(d.id)
            d.error ? rej(new Error(JSON.stringify(d.error))) : res(d.result) } }
    const send = (method, params = {}, sessionId) => new Promise((res, rej) => {
        const id = ++msgId; pending.set(id, { res, rej }); sock.send(JSON.stringify({ id, method, params, sessionId })) })
    const { targetId } = await send('Target.createTarget', { url: 'about:blank' })
    const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true })
    const S = (m, p) => send(m, p, sessionId)
    await S('Page.enable'); await S('Runtime.enable'); await S('Network.enable'); await S('Accessibility.enable')
    await S('Emulation.setDeviceMetricsOverride', { width: 1280, height: 900, deviceScaleFactor: 1, mobile: false })
    await S('Network.setCookies', { cookies: [{ name: cookieName, value: cookieValue,
        domain: 'localhost', path: '/', httpOnly: false, secure: false }] })

    const ev = async (expr) => {
        const r = await S('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true })
        if (r.exceptionDetails) throw new Error(JSON.stringify(r.exceptionDetails).slice(0, 400))
        return r.result.value
    }
    const SEL = (s) => (FAULT === 'blind' ? '#no-such-thing-at-all' : s)

    const goto = async (path) => {
        await S('Page.navigate', { url: origin + path })
        await sleep(1200)
        for (let i = 0; i < 40; i++) {
            const hydrated = await ev(`(() => { const b = document.querySelector('button')
                return !!b && Object.keys(b).some(k => k.startsWith('__react')) })()`)
            if (hydrated) return true
            await sleep(250)
        }
        return false
    }
    // ★ 有些页面上【不止一个】确认钮(银行对账单:取消对账 + 删除;
    //   关账:关账 + 重开;财务设置:锁定 + GST)。取第一个,就等于
    //   宣布另一个"没有跑" —— 而覆盖率那个数不该被一个选择器的懒惰决定。
    const clickReal = async (selector, nth = 0) => {
        const box = await ev(`(() => {
            const el = document.querySelectorAll(${JSON.stringify(selector)})[${nth}]
            if (!el) return null
            el.scrollIntoView({ block: 'center' })
            const r = el.getBoundingClientRect()
            if (r.width === 0 || r.height === 0) return null
            return { x: r.left + r.width / 2, y: r.top + r.height / 2 }
        })()`)
        if (!box) return false
        for (const type of ['mousePressed', 'mouseReleased'])
            await S('Input.dispatchMouseEvent', { type, x: box.x, y: box.y, button: 'left', clickCount: 1 })
        await sleep(600)
        return true
    }

    const bannerState = () => ev(`(() => {
        const b = document.querySelector('[data-action-message="1"]')
        if (!b) return { shown: false }
        return {
            shown: true,
            subject: b.getAttribute('data-action-message-subject'),
            headline: b.getAttribute('data-action-message-headline'),
            text: (b.textContent || '').replace(/\\s+/g, ' ').trim(),
            hasDetail: b.getAttribute('data-action-message-has-detail') === '1',
            dismissable: !!b.querySelector('[data-action-message-dismiss="1"]'),
        }
    })()`)

    // ════════════════════════════════════════════════════════════════════
    // ★★【固定 sleep 换成【轮询到出现为止】—— 而这是被一次假红逼出来的】★★
    //   第一版动作之后 `await sleep(1500)` 就下判词。A 组因此【时绿时红】:
    //   同一份代码,一次 22/22,下一次 15/22,红的全是"横幅没出现"。
    //   查明不是产品的毛病,是判词太早 —— 拒绝这条路现在【比从前多一次往返】:
    //   refuseNothingChanged 要问一次 lib/permissions.ts 的 can()
    //   (也就是 current_user_permissions 那支 RPC),1500ms 是擦边的。
    //   ☞ 一个擦边的 sleep 会把"慢"读成"没有",而那正是本刀在治的病的镜像:
    //     **把一个还没到的东西,报告成一个不存在的东西。**
    //   ☞ 反臂那一格【仍然是即时判定】的(动作之前不许有横幅),
    //     所以这个轮询不会把"永远显示横幅"的树也放绿。
    const waitForBanner = async (ms = 12000) => {
        const t0 = Date.now()
        for (;;) {
            const b = await bannerState()
            if (b.shown) return b
            if (Date.now() - t0 > ms) return b
            await sleep(250)
        }
    }

    // ★ 一句话到底是不是【人话】:两条机器味的判据,而不是"看着像"。
    const RAW_CODE = /[A-Z][A-Z_]{4,}\|/           // PERMISSION_DENIED|module.finance.edit
    const BARE_CODE = /(^|\s)[A-Z][A-Z_]{6,}(\s|$)/ // 光秃秃一串大写

    console.log(`\n== 探针:告知横幅(ALERT-1)${FAULT ? `  · ★ 注入 PROBE_FAULT=${FAULT}` : ''} ==`)
    console.log(`   会话:一次性账号 + auditor(三个模块 view 有 / edit 无)\n`)

    // ════════════════════════════════════════════════════════════════════
    // A —— 【本刀之前【一个字都不会出现】的那一条】:物料软删被 RLS 静默挡下
    // ════════════════════════════════════════════════════════════════════
    console.log('-- A /materials 行内删除 · 零行落地(转换前:屏幕全静) --')
    const navA = await goto('/materials')
    probe('A0 水合', navA, navA ? '页面水合完成' : '★ 水合没等到 —— 判词无效,不是"通过"')

    const beforeA = await bannerState()
    probe('A1 反臂', beforeA.shown === false,
        beforeA.shown ? '★ 还没动作就已经有横幅 —— 断言没有区分力' : '动作之前:没有横幅')

    const trigA = await clickReal(SEL('button[aria-haspopup="dialog"]'))
    probe('A1b 删除钮点得到', trigA, trigA ? '触发钮被真的鼠标事件点到' : '★ 点不到')

    // ★★【第一版这一格是红的,而红的是【探针】,不是产品 —— 记下来】★★
    //   第一版拿 REST 单独查一行物料,再断言横幅的主语等于它。
    //   但 REST 那一句没有 order,页面那张表另有排序 —— 于是"表里第一行"
    //   与"查询里第一行"根本不是同一条(实得 Film,期望 NMC Cathode Foil)。
    //   **判据必须走人真的走的那条路**:要比的不是"库里某一行",而是
    //   【这一次点击确认的到底是哪一个】—— 也就是对话框自己那一格主语。
    //   ☞ 而这样一改,这一格问的问题也变好了:
    //     「你刚才确认的那一个,和拒绝里点名的那一个,是不是同一个」。
    const confirmedSubject = await ev(`(() => {
        const d = document.querySelector('[data-confirm-dialog="1"]')
        const s = d && d.querySelector('[data-confirm-subject]')
        return s ? s.getAttribute('data-confirm-subject') : null
    })()`)
    probe('A1b2 对话框点得出主语', !!confirmedSubject,
        confirmedSubject ? `这一次确认的是 ${JSON.stringify(confirmedSubject)}` : '★ 对话框没开,或主语是空的')

    const okA = await clickReal(SEL('[data-confirm-accept="1"]'))
    probe('A1c 确认钮点得到', okA, okA ? '确认了 —— 动作真的发出去了' : '★ 对话框没开或确认钮点不到')
    let a = await waitForBanner()
    if (FAULT === 'no-banner') a = { shown: false }
    if (FAULT === 'raw-code') a = { ...a, text: 'PERMISSION_DENIED|module.materials.edit' }

    probe('A2 ★ 那句话出来了', a.shown === true,
        a.shown ? '★★ 这一条【第一次】到达屏幕 —— 转换前它零行落地、报告成功、一个字都没有'
                : '★ 没有横幅:那条静默的删除仍然是静默的')
    probe('A3 主语点得出名字', !!a.subject && a.subject.trim() !== '',
        a.subject ? `subject = ${JSON.stringify(a.subject)}(表里那一行的名字)` : '★ 主语是空的 —— 五十行里它答不出是哪一条')
    probe('A3b ★ 拒绝点名的,就是刚才确认的那一个',
        !!confirmedSubject && a.subject === confirmedSubject,
        `确认的是 ${JSON.stringify(confirmedSubject)},拒绝点名的是 ${JSON.stringify(a.subject)}`)
    probe('A4 不是一串机器码', !!a.text && !RAW_CODE.test(a.text) && !BARE_CODE.test(a.text),
        a.text ? `正文:${a.text.slice(0, 90)}…` : '★ 正文是空的')
    probe('A5 说得出【那项权限】', !!a.text && a.text.includes('module.materials.edit'),
        a.text && a.text.includes('module.materials.edit')
            ? '那句话把管理员要勾的那一项(module.materials.edit)原样写了出来'
            : '★ 正文里没有那个权限码 —— 这张条子转交给管理员也没用')
    probe('A6 关得掉', a.dismissable === true, a.dismissable ? '有关闭钮 —— 它不挡人,是人自己收起它' : '★ 关不掉')

    // 无障碍:读【无障碍树】里的 role,而不是 DOM 属性 —— 写了 role 不等于播报得出。
    const ax = await (async () => {
        const { nodes } = await S('Accessibility.getFullAXTree')
        const alert = (nodes || []).find((n) => n.role?.value === 'alert')
        // ★ 光有 role 不算数:要证明【那句话本身】进了无障碍树,
        //   否则"写了 role"与"念得出来"是两件被混为一谈的事。
        const names = (nodes || []).map((n) => n.name?.value || '').filter(Boolean)
        return { hasAlert: !!alert, names }
    })()
    probe('A7 无障碍树里有一条 alert', ax.hasAlert,
        ax.hasAlert ? 'role=alert 的活动区域在树里(容器常驻,内容插进去才播报得出)' : '★ 树里没有 role=alert 的节点')
    const headlineInAx = ax.names.some((n) => a.headline && n.includes(a.headline))
    // ★【`|| FAULT === 'blind'` 从这里删掉了 —— 那是一条给自己开的后门】
    //   本刀刚在 AGENTS.md 写下「健康检查的阈值默认应当是零」,转头就在这一格
    //   写了「除非是 blind 就算过」。一个【在专门用来弄瞎它的故障下仍然会绿】
    //   的断言,正是那条法则说的那种自留余地。
    probe('A7b ★ 那句话【进了无障碍树】', headlineInAx,
        headlineInAx ? `标题 ${JSON.stringify(a.headline)} 在树里露出来了 —— 不只是 DOM 里有`
                     : '★ 树里找不到那句标题:role 写了,但内容没暴露给辅助技术')

    // ════════════════════════════════════════════════════════════════════
    // B —— 【本刀之前印的是 `PERMISSION_DENIED|module.finance.edit`】
    // ════════════════════════════════════════════════════════════════════
    if (jeId) {
        console.log('\n-- B /finance/journal/[id] 冲销 · RPC 抛 PERMISSION_DENIED --')
        const navB = await goto(`/finance/journal/${jeId}`)
        probe('B0 水合', navB, navB ? '页面水合完成' : '★ 水合没等到')
        const beforeB = await bannerState()
        probe('B1 反臂', beforeB.shown === false, beforeB.shown ? '★ 动作前已有横幅' : '动作之前:没有横幅')
        await clickReal(SEL('button[aria-haspopup="dialog"]'))
        const okB = await clickReal(SEL('[data-confirm-accept="1"]'))
        probe('B1c 确认钮点得到', okB, okB ? '动作发出去了' : '★ 点不到')
        let b = await waitForBanner()
        if (FAULT === 'no-banner') b = { shown: false }
        if (FAULT === 'raw-code') b = { ...b, text: 'PERMISSION_DENIED|module.finance.edit' }
        probe('B2 横幅出来了', b.shown === true, b.shown ? '拒绝到达屏幕' : '★ 没有横幅')
        probe('B3 主语点得出名字', !!b.subject && b.subject.trim() !== '', `subject = ${JSON.stringify(b.subject)}`)
        probe('B4 ★ 不再是那一串原文', !!b.text && !RAW_CODE.test(b.text),
            b.text ? `转换前这里印的是 PERMISSION_DENIED|module.finance.edit;现在:${b.text.slice(0, 90)}…`
                   : '★ 正文是空的')
    } else {
        probe('B0 无从驱动', false, '★ journal_entries 一行都没有 —— B 组【没有跑】,不是通过')
    }

    // ════════════════════════════════════════════════════════════════════
    // C —— 丁类:控件【本来就不该按得下】,理由在按之前
    // ════════════════════════════════════════════════════════════════════
    console.log('\n-- C /suppliers/[id]/edit 状态面板 · 丁类(控件不出现) --')
    const navC = await goto(`/suppliers/${supId}/edit`)
    probe('C0 水合', navC, navC ? '页面水合完成' : '★ 水合没等到')
    // ★ C/E 组的选择器也要过 SEL —— 否则 `blind` 弄不瞎它们,
    //   而一个"故障注入照不到的角落"等于一个没有反臂的断言。
    let c = await ev(`(() => {
        const denied = document.querySelector(${JSON.stringify(SEL('[data-status-panel-denied="1"]'))})
        const panel = document.querySelectorAll(${JSON.stringify(SEL('button[aria-haspopup="dialog"]'))})
        return { denied: !!denied, deniedText: denied ? denied.textContent.trim() : '',
                 dialogButtons: panel.length }
    })()`)
    if (FAULT === 'd-operable') c = { ...c, denied: false }
    probe('C2 ★ 理由在【按之前】就看得见', c.denied === true,
        c.denied ? `按不下去,而且说了为什么:${c.deniedText.slice(0, 70)}…`
                 : '★ 没有那行理由 —— 丁类没有成立')
    probe('C3 那句话说得出【那项权限】', c.denied && c.deniedText.includes('module.suppliers.edit'),
        c.denied && c.deniedText.includes('module.suppliers.edit')
            ? '管理员要勾的那一项(module.suppliers.edit),原样写在屏幕上'
            : '★ 那行理由不在,或者它没说出是哪一项权限')

    // ════════════════════════════════════════════════════════════════════
    // D —— 把【其余的调用点】也真的走一遍(同一套判据,逐站重复)
    // ════════════════════════════════════════════════════════════════════
    //   A/B/C 三组各自证明了一类形状(静默那一支、机器码那一支、丁类)。
    //   这一段不再证明新形状,它做的是【覆盖率】:委托书要的是
    //   「18 条里有几条真的被机器走过」,而那个数只有逐站走过才说得出。
    //
    //   ★ 需要理由的那几处(作废发票、取消对账、撤销牌价、重开期间),
    //     确认钮在理由为空时【按不动】—— 那是 CONFIRM-1 的闸,不是本刀的。
    //     所以这里要先把理由填进去,而且要用【原生 setter + input 事件】,
    //     否则 React 的受控值不会更新(直接改 .value 是看得见、React 看不见的)。
    const typeReason = async (text) => ev(`(() => {
        const el = document.querySelector('[data-confirm-reason="1"]')
        if (!el) return false
        const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set
        setter.call(el, ${JSON.stringify('ZZ-PROBE ')} + ${JSON.stringify('ALERT-1')})
        el.dispatchEvent(new Event('input', { bubbles: true }))
        return true
    })()`)

    const SWEEP = [
        { id: 'D1', name: '/suppliers 行内删除',            path: '/suppliers',                        nth: 0 },
        { id: 'D2', name: '/sales/customers 行内删除',      path: '/sales/customers',                  nth: 0 },
        { id: 'D3', name: '/finance/payments/[id] 冲销',    path: payment && `/finance/payments/${payment.id}`,  nth: 0 },
        { id: 'D4', name: '/finance/expenses/[id] 冲销',    path: expense && `/finance/expenses/${expense.id}`,  nth: 0 },
        // D5(作废发票)【不在这张表里】—— 它是两段式的:先按"作废"露出理由框,
        //   那一段【才】渲染出 ConfirmButton。通用钥匙在第一段就开不了它,
        //   所以它有专用的一段(见下面 E 组),而不是在这里记一格假红。
        { id: 'D6', name: '/finance/bank/statements/[id]',  path: stmt && `/finance/bank/statements/${stmt.id}`, nth: 0 },
        { id: 'D7', name: '/finance/fx/[id]/edit 撤销牌价', path: fxRate && `/finance/fx/${fxRate.id}/edit`,     nth: 0, reason: true },
        { id: 'D8', name: '/finance/close 关账',            path: '/finance/close',                    nth: 0 },
        { id: 'D9', name: '/finance/settings 锁定/GST',     path: '/finance/settings',                 nth: 0 },
        // ★★【D10 从清单里【拿掉了】,而理由值得读】★★
        //   `/tools/pricing/metal-prices/[id]/edit` 这一页【本来就把 module.pricing.edit
        //   当门】(page.tsx 开头的 requireEditPermission,连同一段写得很好的理由:
        //   「不要把一张注定被拒收的表单摆到人面前」)。
        //   于是一个只有 view 的会话【根本进不去这一页】—— 它看到的是拒绝屏,
        //   那个删除钮不在树里是【对的】,不是缺陷。
        //   ☞ 也就是说:这一处的权限拒绝【本来就是丁类,而且早就做掉了】。
        //     它的横幅只在"非权限的驱动错误"时才出得来,而那种错误没法安全制造 ——
        //     所以它按名列进"没有驱动"的那一栏,理由写在这里。
        //   ☞ 顺带:requireEditPermission 全库只有 10 处调用点。
        //     它正是 ALERT1-D-BLOCKED-17 那一刀要铺开的东西。
        { id: 'D11', name: '/tools/pricing/formulas/[id]/edit',     path: formula && `/tools/pricing/formulas/${formula.id}/edit`, nth: 0 },
        // ── 同一页上的【其余】确认钮 ────────────────────────────────────
        // ★【按序号点第二个,是在猜】★ 第一版这么做,当场吃了一个假绿:
        //   /finance/settings 上 nth=1 命中的是【锁定表单自己的"解除"钮】
        //   (lockedBefore 有值时它渲染两个),而不是 GST 开关 ——
        //   报告里于是差点写上"GST 也走过了"。**一个按序号取的选择器,
        //   报出来的是"某一个",不是"哪一个"。**
        //   ☞ 改成【把这一页上每一个确认控件都走一遍】,各自印出自己的标题。
        //     覆盖率因此不再取决于我猜对了哪个是第几个。
        // ★【删除对账单那一个驱动不了,而理由不是探针的毛病】
        //   页面写着 `actions={stmt.status === 'open' ? <DeleteStatementButton …/> : undefined}`。
        //   这套数据里没有一张 status='open' 的对账单,于是那个钮根本不渲染。
        //   ☞ 造一张来驱动它,就等于往共享测试数据里写业务行 —— Tim 在闸上禁了。
        //     所以它按名列进"没有驱动"那一栏,理由写在这里。
        { id: 'D12', name: '/finance/bank/statements/[id] 全部确认控件', path: stmt && `/finance/bank/statements/${stmt.id}`, all: true },
        // ★ 这一页上有【三个】确认控件,而第三个不是本刀的:
        //   YearClosePanel(年结/重开年)从来就不走 alert(),它不在这 18 处里。
        //   它的确认钮还带着前置条件(月锁、试算、重估、折旧),常常按不动 ——
        //   把它算进本刀的覆盖率,红的是【别人的活】。所以只驱动前两个,
        //   而这一行就是"为什么是两个"的记录。
        { id: 'D13', name: '/finance/close 全部确认控件',                path: '/finance/close',    all: true, limit: 2 },
        { id: 'D14', name: '/finance/settings 全部确认控件',             path: '/finance/settings', all: true },
    ]

    console.log('\n-- D 其余调用点(同一套判据,逐站重复) --')
    let swept = 0
    // all:true 的站点先问一句"这一页上有几个确认控件",再逐个展开成独立的一格。
    const EXPANDED = []
    for (const site of SWEEP) {
        if (!site.all) { EXPANDED.push(site); continue }
        if (!site.path) { EXPANDED.push(site); continue }
        await goto(site.path)
        const n = await ev(`document.querySelectorAll('button[aria-haspopup="dialog"]').length`)
        if (!n) { EXPANDED.push({ ...site, nth: 0 }); continue }
        const cap = site.limit ? Math.min(n, site.limit) : n
        for (let k = 0; k < cap; k++)
            EXPANDED.push({ ...site, id: `${site.id}.${k + 1}`, name: `${site.name} #${k + 1}/${cap}`, nth: k })
    }
    for (const site of EXPANDED) {
        if (!site.path) { probe(`${site.id} 无从驱动`, false, `★ ${site.name}:线上没有可用记录 —— 【没有跑】,不是通过`); continue }
        const nav = await goto(site.path)
        if (!nav) { probe(`${site.id} 水合`, false, `★ ${site.name}:水合没等到 —— 判词无效`); continue }
        const before = await bannerState()
        if (before.shown) { probe(`${site.id} 反臂`, false, `★ ${site.name}:动作前已有横幅`); continue }

        // ★【"点不到"有两种,而它们是两件完全不同的事】
        //   不在树里  = 这一页根本没渲染那个控件(可能是权限、可能是状态条件);
        //   在但零尺寸 = 渲染了却点不着(被遮住 / 折叠)。
        //   混成一句"点不到",下一个人要从头查一遍。
        const why = await ev(`(() => {
            const el = document.querySelectorAll('button[aria-haspopup="dialog"]')[${site.nth}]
            if (!el) return 'absent'
            const r = el.getBoundingClientRect()
            return (r.width === 0 || r.height === 0) ? 'zero-size' : 'ok'
        })()`)
        const trig = await clickReal(SEL(`button[aria-haspopup="dialog"]`), site.nth)
        if (!trig) { probe(`${site.id} 触发钮`, false,
            `★ ${site.name}:确认触发钮 ${why === 'absent' ? '【不在树里】(这一页没有渲染它)' : '【零尺寸】(渲染了却点不着)'} —— 【没有跑】`); continue }
        const dlgSubject = await ev(`(() => {
            const d = document.querySelector('[data-confirm-dialog="1"]')
            const s = d && d.querySelector('[data-confirm-subject]')
            return s ? s.getAttribute('data-confirm-subject') : null
        })()`)
        // ★【第一版这里漏了一件事,而它让 D6 假红】
        //   本来只在 site.reason 为真时填理由。但一页上可能有【好几个】确认钮,
        //   而 querySelector 取的是第一个 —— 银行对账单那一页第一个是"取消对账"
        //   (它要理由),不是"删除"。于是理由没填、确认钮 disabled,
        //   **鼠标事件照样派发得出去,只是什么都没发生** ——
        //   探针于是报"没有横幅",而产品其实没被驱动过。
        //   ☞ 两条都改:无条件试着填理由(没有输入框就返回 false,无害);
        //     以及【点之前先问它可不可按】—— 一个 disabled 的钮吃掉点击而不出声,
        //     正是本刀在治的那种沉默。
        await typeReason()
        const acceptDisabled = await ev(`(() => {
            const b = document.querySelector('[data-confirm-accept="1"]')
            return b ? !!b.disabled : null
        })()`)
        if (acceptDisabled !== false) { probe(`${site.id} 确认钮可按`, false,
            `★ ${site.name}:确认钮 ${acceptDisabled === null ? '不在' : '仍是 disabled(理由没填上?)'} —— 【没有跑】`); continue }
        const ok = await clickReal(SEL('[data-confirm-accept="1"]'))
        if (!ok) { probe(`${site.id} 确认钮`, false, `★ ${site.name}:确认钮点不到 —— 【没有跑】`); continue }

        let b = await waitForBanner()
        if (FAULT === 'no-banner') b = { shown: false }
        if (FAULT === 'raw-code') b = { ...b, text: 'PERMISSION_DENIED|module.finance.edit' }

        const humane = !!b.text && !RAW_CODE.test(b.text) && !BARE_CODE.test(b.text)
        const named = !!b.subject && b.subject === dlgSubject
        const allOk = b.shown && humane && named
        if (allOk) swept++
        // ★ 印出【标题】而不只是"通过" —— 有两个确认钮的页面(银行对账单、
        //   关账、财务设置)上,通用钥匙取的是第一个,而报告必须说得出
        //   到底走的是哪一个,否则覆盖率那个数是含糊的。
        probe(`${site.id} ${site.name}`, allOk,
            allOk ? `走的是【${b.headline}】,点名 ${JSON.stringify(b.subject)},正文是人话`
                  : `★ shown=${b.shown} 主语相符=${named}(对话框 ${JSON.stringify(dlgSubject)} / 横幅 ${JSON.stringify(b.subject)}) 人话=${humane}`)
    }
    console.log(`   D 组:${swept}/${EXPANDED.length} 个控件走通`)

    // ════════════════════════════════════════════════════════════════════
    // E —— 作废发票:它【不是】一个确认对话框,所以要单独驱动
    // ════════════════════════════════════════════════════════════════════
    //   `VoidInvoiceControl` 是一个【就地展开的两段式控件】:先按"作废"露出
    //   理由框,再按一次提交。它没有 aria-haspopup="dialog",于是 D 组那把
    //   通用的钥匙开不了它 —— 而【开不了不等于跑过了】,所以给它一段专用的。
    //   ☞ 顺带记一件事:这一处的确认【不走 CONFIRM-1 的对话框】。
    //     它是本刀视野里唯一一个这样的调用点,已在报告里点名。
    if (invoice) {
        console.log('\n-- E /finance/invoices/[id] 作废(两段式:先展开,第二段才是对话框) --')
        const navE = await goto(`/finance/invoices/${invoice.id}`)
        probe('E0 水合', navE, navE ? '页面水合完成' : '★ 水合没等到')
        const beforeE = await bannerState()
        probe('E1 反臂', beforeE.shown === false, beforeE.shown ? '★ 动作前已有横幅' : '动作之前:没有横幅')

        // 第一段:按"作废"把理由框展开。这一段【还没有】对话框。
        const opened = await ev(`(() => {
            const b = [...document.querySelectorAll(${JSON.stringify(SEL('button'))})]
                .find(x => !x.getAttribute('aria-haspopup') && /作废|Void/i.test(x.textContent || ''))
            if (!b) return false
            b.click(); return true
        })()`)
        probe('E2 展开', opened, opened ? '"作废"按下去了,理由框与确认钮露出来了' : '★ 找不到那个"作废"钮 —— 【没有跑】')
        await sleep(700)

        // 填理由(以及需要时的冲销日)—— 用原生 setter,否则受控值不动。
        const filled = opened && await ev(`(() => {
            const setNative = (el, v) => {
                const proto = el.type === 'date' ? window.HTMLInputElement.prototype : window.HTMLInputElement.prototype
                Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, v)
                el.dispatchEvent(new Event('input', { bubbles: true }))
            }
            const txt = [...document.querySelectorAll(${JSON.stringify(SEL('input[type=text]'))})].pop()
            if (!txt) return false
            setNative(txt, 'ZZ-PROBE ALERT-1')
            const dt = [...document.querySelectorAll('input[type=date]')].pop()
            if (dt) setNative(dt, '2026-08-31')
            return true
        })()`)
        probe('E3 理由填上了', !!filled, filled ? '理由(与冲销日,若要)已填' : '★ 找不到理由框 —— 【没有跑】')
        await sleep(300)

        // 第二段:这才是 ConfirmButton —— 触发钮 → 对话框 → 确认。
        const trigE = filled && await clickReal(SEL('button[aria-haspopup="dialog"]'))
        probe('E4 确认触发钮', !!trigE, trigE ? '第二段的确认钮点到了' : '★ 展开之后仍没有确认触发钮 —— 【没有跑】')
        const okE = trigE && await clickReal(SEL('[data-confirm-accept="1"]'))
        probe('E5 确认', !!okE, okE ? '确认了 —— 作废真的发出去了' : '★ 确认钮点不到 —— 【没有跑】')

        let e = await waitForBanner()
        if (FAULT === 'no-banner') e = { shown: false }
        if (FAULT === 'raw-code') e = { ...e, text: 'PERMISSION_DENIED|module.finance.edit' }
        const humaneE = !!e.text && !RAW_CODE.test(e.text) && !BARE_CODE.test(e.text)
        probe('E6 拒绝到达屏幕且是人话', e.shown === true && humaneE,
            e.shown ? `点名 ${JSON.stringify(e.subject)};正文:${(e.text || '').slice(0, 80)}…` : '★ 没有横幅')
    } else {
        probe('E0 无从驱动', false, '★ invoices 一行都没有 —— E 组【没有跑】')
    }

    // ════════════════════════════════════════════════════════════════════
    console.log(`\n── 小结 ──`)
    const green = results.filter((r) => r.ok).length
    console.log(`  ${green}/${results.length} 格通过`)
    if (fail.length) { console.log('\n红的格子:'); fail.forEach((f) => console.log('  ✗ ' + f)) }
    await runPlan()
    console.log(fail.length ? '\nEXIT 1 — 有红格' : '\nEXIT 0 — 这些错误路真的被机器走过了')
    process.exitCode = fail.length ? 1 : 0
} catch (e) {
    console.error('\n★ 探针自己出错(这【不是】通过):', e.message)
    try { await runPlan() } catch {}
    process.exitCode = 2
} finally {
    killChildren(); try { release() } catch {}
}
