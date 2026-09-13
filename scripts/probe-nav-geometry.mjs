#!/usr/bin/env node
// scripts/probe-nav-geometry.mjs
// ════════════════════════════════════════════════════════════════════════════
// SEARCH-1 · 顶栏的【盒子】,以及根布局的判断【跟不跟着人走】
// ════════════════════════════════════════════════════════════════════════════
//
// 【为什么这支探针存在 —— 两件在册的事,它们恰好是同一棵树上的】
//
//   ① **停止条件 (f)(SEARCH-1 委托书新加的一条)**:顶栏与根布局在【每一页】上,
//      所以它们的渲染几何一动,全树跟着动。委托书因此要求「改前改后各量一次
//      顶栏自己的盒子,两个视口」。★ 实测:在这支之前,**本仓库没有任何一道
//      在册的量具读得到 `<header>` 的盒子** —— `survey-controls.mjs` 读的是
//      控件与表格,`probe-search-shell.mjs` 读的是搜索那一格。
//      BTN-SIZE-1 的交回报告 §8.4 已经为同一类缺口点过名(「今天没有任何一道
//      在册的闸看得见按钮的渲染高度」),这一支把顶栏那一格补上,**并且进仓库**
//      —— 前五支一次性探针没有进仓库,于是每一刀重写一遍。
//
//   ② ★★ **`CONFIRM-1-ROOT-LAYOUT-HEADER` 的判据(S4)** ★★
//      根布局从 `x-pathname` 算「这一页要不要应用外壳」,而 App Router
//      **软导航时不重画根布局** —— 那个布尔在会话的第一次硬导航上求值一次,
//      然后跟着这个人走遍整个系统。
//      ☞ **判据必须走人真的走的那条路**(AGENTS.md 那条具名法则):
//        所以 N6 是【点着走】过去的,而且先证这一次真的是软导航。
//
// ════════════════════════════════════════════════════════════════════════════
// 【瞄准 · AIM】
//   我读的是      :chrome-headless-shell 通过 CDP 读**真实渲染后**的 DOM ——
//                   `<header>` 与搜索触发钮的 `getBoundingClientRect()` /
//                   `getComputedStyle()`,以及 `[data-app-chrome]` 的属性值。
//   我声称管的是   :① 顶栏自己那个盒子改前改后是什么;
//                   ② 根布局那个「要不要外壳」的判断,**软导航之后有没有重新求值**。
//   两者不同之处   :★ **我只量顶栏这一条 `<header>`,不量它底下每一个子元素。**
//                   顶栏里某一格长宽了 1px 而整条 header 高度没变,我看不见 ——
//                   那一层归 `survey-controls.mjs --mode=drift`(它逐元素读计算值)。
//                   ★ 我也**不答「一个人点不点得到」** —— 那要人走一遍。
//                   ★ N6 证的是【判断有没有重新求值】,**不是**「外壳在 bare 路径上
//                   该不该消失」:全树今天指向 bare 路径的 `<Link>` 是 **0 处**
//                   (check-nav-routes 判据 ⑤ 把它钉住了),所以那条路
//                   **走不到**,我也就量不了它。这句话是这支探针的边界,别高估它。
// ════════════════════════════════════════════════════════════════════════════
//
// 用法:node scripts/probe-nav-geometry.mjs     (需要 .next 里有一份生产构建)
//      跑在 next start 上,不跑 next dev。
// 退出码:0 干净 / 1 有格子红了 / 2 量具自己坏了
import { readFileSync, existsSync } from 'node:fs'
import { join } from 'node:path'
import { spawn, execSync } from 'node:child_process'
import { createConnection } from 'node:net'
import { acquireOrExit, release } from './liveLock.mjs'
import { openPlan, planDelete, ephemeralGrantBody, runPlan, reapStalePlans, ORDER } from './ephemeral.mjs'
import { assertPopulation } from './lib/selfproof.mjs'

const ROOT = new URL('..', import.meta.url).pathname
const PORT = 3203                 // 3198 survey · 3199 冒烟 · 3201 avatar · 3202 search-shell
const CDP_PORT = 9339
const CHROME = join(process.env.HOME, '.cache/puppeteer/chrome-headless-shell/mac_arm-152.0.7977.54/chrome-headless-shell-mac-arm64/chrome-headless-shell')

const env = readFileSync(join(ROOT, '.env.local'), 'utf8')
const URL_ = env.match(/NEXT_PUBLIC_SUPABASE_URL=(\S+)/)[1]
const ANON = env.match(/NEXT_PUBLIC_SUPABASE_ANON_KEY=(\S+)/)[1]
const SERVICE = env.match(/SUPABASE_SERVICE_ROLE_KEY=(\S+)/)[1]

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const rest = (p, o = {}) => fetch(URL_ + p, { ...o, headers: {
    apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, 'Content-Type': 'application/json', ...(o.headers || {}) } })

const results = []
const fail = []
const readings = []
function probe(id, ok, detail) {
    results.push({ id, ok, detail })
    if (!ok) fail.push(`${id}: ${detail}`)
    console.log(`${ok ? '✓' : '✗'} ${id.padEnd(28)} ${detail}`)
}

let server = null, chrome = null, accountId = null
const cleanupFailures = []

async function waitPort(port, ms) {
    const t0 = Date.now()
    for (;;) {
        const up = await new Promise((res) => {
            const s = createConnection({ port, host: '127.0.0.1' })
            s.on('connect', () => { s.destroy(); res(true) })
            s.on('error', () => res(false))
        })
        if (up) return true
        if (Date.now() - t0 > ms) return false
        await sleep(300)
    }
}

// ★ 顶栏自己的盒子 + 那一格搜索触发钮 + 根布局判断的记号。
//   **三样一起读,一次调用** —— 分三次读会把三个不同时刻的状态拼成一张读数。
const MEASURE = `(() => {
    const round = (n) => Math.round(n * 100) / 100
    const box = (el) => {
        if (!el) return null
        const r = el.getBoundingClientRect()
        const cs = getComputedStyle(el)
        return { w: round(r.width), h: round(r.height), top: round(r.top),
                 pt: cs.paddingTop, pb: cs.paddingBottom, pl: cs.paddingLeft, pr: cs.paddingRight,
                 position: cs.position, zIndex: cs.zIndex, display: cs.display,
                 visible: el.offsetParent !== null || cs.position === 'fixed' || cs.position === 'sticky' }
    }
    const header = document.querySelector('header')
    // 触发钮:改前是 <summary>(在 [data-nav="search-shell"] 里),改后是 <button>。
    // **两种写法都认** —— 一支只认改后写法的探针,量不了"改前"。
    // ★【两个入口各戴各的记号,所以两个都要认】★
    //   顶栏 data-nav="search-shell" · 首页 data-home-search="shell"。
    //   ⚠ 第一版只认前者,于是在【首页】上 shell 与 trigger 都读成 null ——
    //     而那读起来像"首页那个入口没画",**那是一句假话**:它画着,
    //     只是这支探针不认得它的记号。一支看不见的探针必须说"我没看见",
    //     不许说"它不在"。
    const shell = document.querySelector('[data-nav="search-shell"]')
        || document.querySelector('[data-home-search="shell"]')
    const trig = document.querySelector('[data-nav="search-trigger"]')
        || (shell ? shell.querySelector('summary') : null)
    const chromeEl = document.querySelector('[data-app-chrome]')
    return {
        path: location.pathname,
        vw: document.documentElement.clientWidth,
        header: box(header),
        shell: box(shell),
        trigger: box(trig),
        // ★ S4 的那一格:根布局这一次是按【哪一条路径】判的。
        //   改前这个属性不存在(根布局根本不记录它) —— null 就是那个读数。
        chromePath: chromeEl ? chromeEl.getAttribute('data-app-chrome') : null,
        hasTopNav: !!document.querySelector('[data-nav="avatar-menu"]'),
        panelOpen: !!document.querySelector('[data-search-panel]'),
        slots: [...document.querySelectorAll('[data-search-slot]')].map((e) => e.getAttribute('data-search-slot')),
    }
})()`

function fmtBox(b) {
    return b ? `${b.w}x${b.h} @top=${b.top} pad=${b.pt}/${b.pr}/${b.pb}/${b.pl} ${b.position} z=${b.zIndex}` : '(不在 DOM 里)'
}

async function main() {
    acquireOrExit('scripts/probe-nav-geometry.mjs', { ownExit: false })
    openPlan('scripts/probe-nav-geometry.mjs')
    await reapStalePlans()
    if (!existsSync(join(ROOT, '.next/BUILD_ID')))
        throw new Error('.next/BUILD_ID 不在 —— 这一支要跑在【生产构建】上。先 npm run build。')
    if (!existsSync(CHROME)) throw new Error('chrome-headless-shell not at ' + CHROME)
    try { execSync(`lsof -ti tcp:${PORT} | xargs -r kill -9`, { stdio: 'ignore' }) } catch {}

    const email = `navprobe-${Date.now()}@test.local`
    const cu = await (await rest('/auth/v1/admin/users', { method: 'POST',
        body: JSON.stringify({ email, password: 'nav-probe-1', email_confirm: true }) })).json()
    accountId = cu.id
    if (!accountId) throw new Error('账号建不出来: ' + JSON.stringify(cu).slice(0, 300))
    planDelete(`/rest/v1/user_roles?user_id=eq.${accountId}`, `revoke grant ${accountId}`, ORDER.GRANT)
    planDelete(`/auth/v1/admin/users/${accountId}`, `delete account ${accountId}`, ORDER.ACCOUNT)
    const roles = await (await rest('/rest/v1/roles?select=id&code=eq.admin')).json()
    await rest('/rest/v1/user_roles', { method: 'POST',
        body: JSON.stringify(ephemeralGrantBody(accountId, roles[0].id)) })
    const sess = await (await fetch(URL_ + '/auth/v1/token?grant_type=password', { method: 'POST',
        headers: { apikey: ANON, 'Content-Type': 'application/json' },
        body: JSON.stringify({ email, password: 'nav-probe-1' }) })).json()
    if (!sess?.access_token) throw new Error('登录失败: ' + JSON.stringify(sess).slice(0, 200))
    const cookieName = 'sb-' + URL_.split('//')[1].split('.')[0] + '-auth-token'
    const cookieValue = 'base64-' + Buffer.from(JSON.stringify(sess)).toString('base64url')
    console.log(`· 一次性 admin ${accountId}`)

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
    let msgId = 0
    const pending = new Map()
    sock.onmessage = (m) => {
        const d = JSON.parse(m.data)
        if (d.id && pending.has(d.id)) {
            const { res, rej } = pending.get(d.id)
            pending.delete(d.id)
            if (d.error) rej(new Error(JSON.stringify(d.error)))
            else res(d.result)
        }
    }
    const send = (method, params = {}, sessionId) => new Promise((res, rej) => {
        const id = ++msgId; pending.set(id, { res, rej })
        sock.send(JSON.stringify({ id, method, params, sessionId }))
    })
    const { targetId } = await send('Target.createTarget', { url: 'about:blank' })
    const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true })
    const S = (m, p) => send(m, p, sessionId)
    await S('Page.enable'); await S('Runtime.enable'); await S('DOM.enable'); await S('Network.enable')
    await S('Network.setCookies', { cookies: [{ name: cookieName, value: cookieValue,
        domain: 'localhost', path: '/', httpOnly: false, secure: false }] })

    const evalJs = async (expr) => {
        const r = await S('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true })
        if (r.exceptionDetails) throw new Error(expr.slice(0, 60) + ' → ' + JSON.stringify(r.exceptionDetails).slice(0, 300))
        return r.result.value
    }
    const setWidth = (w) => S('Emulation.setDeviceMetricsOverride',
        { width: w, height: 900, deviceScaleFactor: 1, mobile: w < 768 })

    // 等【水合完成】—— 不等它,下面那次点击不会被 <Link> 接管,于是它变成一次
    // 硬导航,而 N6 会【假绿】。判据与 probe-search-shell.mjs 逐字同源。
    const HYDRATED = `(() => {
        const b = document.querySelector('[data-nav="avatar-menu"] button')
        return !!b && Object.keys(b).some(k => k.startsWith('__react'))
    })()`
    async function waitHydrated(label, ms = 20000) {
        const t0 = Date.now()
        for (;;) {
            if (await evalJs(HYDRATED)) return
            if (Date.now() - t0 > ms) throw new Error(`${label}:水合没有收尾(${ms}ms)`)
            await sleep(200)
        }
    }
    const hardGoto = async (path) => {
        await S('Page.navigate', { url: `${origin}${path}` })
        await sleep(400)
        await waitHydrated(`hard ${path}`)
    }
    const read = async (label) => {
        const m = await evalJs(MEASURE)
        readings.push({ label, ...m })
        console.log(`   · ${label.padEnd(24)} header=${fmtBox(m.header)}`)
        console.log(`     ${' '.repeat(24)} trigger=${fmtBox(m.trigger)}  chromePath=${JSON.stringify(m.chromePath)}`)
        return m
    }

    // ── (f) 顶栏自己的盒子,两个视口 × 两条路由 ────────────────────────────
    await setWidth(1280); await hardGoto('/me');  const d_me   = await read('1280 hard /me')
    await hardGoto('/');                           const d_home = await read('1280 hard /')
    await setWidth(390);  await hardGoto('/me');   const p_me   = await read('390 hard /me')
    await hardGoto('/');                           const p_home = await read('390 hard /')

    for (const [id, m] of [['N1.header-1280-me', d_me], ['N2.header-1280-home', d_home],
                           ['N3.header-390-me', p_me], ['N4.header-390-home', p_home]]) {
        probe(id, !!m.header && m.header.h > 0 && m.header.w > 0,
            `顶栏盒子 ${fmtBox(m.header)} —— ★ 这是 (f) 要的那个读数,改前改后各一次`)
    }
    // 顶栏宽度必须【就是视口宽】—— 它不满宽就是版式已经坏了,而这条不用等比对。
    for (const [id, m] of [['N1w.header-fills-1280', d_me], ['N3w.header-fills-390', p_me]]) {
        probe(id, !!m.header && Math.abs(m.header.w - m.vw) <= 1,
            `顶栏宽 ${m.header?.w} vs 视口 ${m.vw}`)
    }

    // ── ★★ S4:根布局那个判断,软导航之后重新求值了吗 ★★ ────────────────────
    await setWidth(1280)
    await hardGoto('/')
    const s_hard = await read('1280 hard / (S4)')
    probe('N5.chrome-path-recorded', s_hard.chromePath === '/',
        s_hard.chromePath === null
            ? '★ 读不到 [data-app-chrome] —— 根布局【不记录】它是按哪条路径判的,因为它只判过一次(这就是改前的读数)'
            : `根布局记录的路径 = ${JSON.stringify(s_hard.chromePath)},应为 "/"`)

    // 盖记号:它活过这次导航,就证明文档没有重新加载。
    await evalJs(`window.__softNavMarker = 'SEARCH1'`)
    await evalJs(`(() => {
        const b = document.querySelector('[data-nav="avatar-menu"] button')
        if (!b) throw new Error('找不到头像菜单的触发钮')
        b.click()
    })()`)
    await sleep(400)
    await evalJs(`(() => {
        const a = document.querySelector('[data-nav="avatar-menu"] a[href="/me"]')
        if (!a) throw new Error('头像菜单里找不到 /me 那一行')
        a.click()
    })()`)
    const t0 = Date.now()
    for (;;) {
        if (await evalJs(`location.pathname === '/me'`)) break
        if (Date.now() - t0 > 20000) throw new Error('点击之后 20s 没到 /me')
        await sleep(200)
    }
    await waitHydrated('soft /me')
    const wasSoft = await evalJs(`window.__softNavMarker === 'SEARCH1'`)
    probe('N6a.really-soft-nav', wasSoft === true,
        wasSoft ? '记号活过了这次换页 —— 文档没有重新加载,这是一次真的软导航'
                : '★ 记号没了:这一次点击变成了硬导航,N6b 量的不是人走的那条路')
    const s_soft = await read('1280 soft /me (S4)')
    probe('N6b.chrome-path-follows-soft-nav', s_soft.chromePath === '/me',
        s_soft.chromePath === null
            ? '★ 读不到 [data-app-chrome] —— 那个判断【没有跟着人走】,它停在会话第一次硬导航那一刻(改前的读数)'
            : `软导航之后根布局判的是 ${JSON.stringify(s_soft.chromePath)},应为 "/me" —— ★ 判断跟着人走了`)

    // ── 面板:两个入口是【同一个组件】,而它按三件活定形(S1/S2)────────────
    await setWidth(1280)
    await hardGoto('/me')
    const opened = await evalJs(`(() => {
        const b = document.querySelector('[data-nav="search-trigger"]')
        if (!b) return { ok: false, why: '找不到搜索触发钮(改前它是一个 <summary>,没有这个记号)' }
        b.click()
        return { ok: true }
    })()`)
    await sleep(500)
    const m_open = await read('1280 面板打开')
    probe('N7.panel-has-three-slots',
        opened.ok && m_open.panelOpen &&
        JSON.stringify(m_open.slots) === JSON.stringify(['records', 'pages', 'manual']),
        opened.ok
            ? `面板打开 ${m_open.panelOpen},三节 = ${JSON.stringify(m_open.slots)} —— ★ job ① 那一节【今天就在】,SEARCH-2 填它`
            : opened.why)

    // ── S3:390px 上顶栏那一格不画,而快捷键跟着它一起不存在 ──────────────────
    await setWidth(390)
    await hardGoto('/me')
    const m390 = await read('390 hard /me (S3)')
    probe('N8.phone-nav-entry-absent',
        !!m390.shell && m390.shell.display === 'none',
        `390px 顶栏搜索格 display=${m390.shell ? m390.shell.display : '(不在 DOM 里)'} —— ` +
        `★ Tim 裁定接受(S3):手机上进搜索只有首页那一条路`)
    // 快捷键:按 Cmd-K,面板【不许】开 —— 判据是触发钮此刻看不看得见,一个源。
    await evalJs(`document.dispatchEvent(new KeyboardEvent('keydown', {key:'k', metaKey:true, bubbles:true}))`)
    await evalJs(`window.dispatchEvent(new KeyboardEvent('keydown', {key:'k', metaKey:true, bubbles:true}))`)
    await sleep(300)
    const m390b = await read('390 ⌘K 之后')
    probe('N9.phone-shortcut-inert', m390b.panelOpen === false,
        `390px 上 ⌘K 之后面板 open=${m390b.panelOpen} —— 应当是 false(触发钮 display:none,判据问的就是它)`)

    // ── 首页那一个入口在 390px 上【照画】—— S3 的另一半 ──────────────────────
    await hardGoto('/')
    const m390home = await read('390 hard / (S3)')
    probe('N10.phone-home-entry-present',
        !!m390home.trigger && m390home.trigger.w > 0 && m390home.trigger.h > 0,
        `390px 首页那个入口 ${fmtBox(m390home.trigger)} —— ★ 它没有宽度隐藏,手机上是那唯一的一条路`)

    // ★【下界 10 是【数出来的】,不是挑的】★ 这支探针有 10 次 read():
    //   4 次几何(两视口 × 两路由)+ 2 次 S4(硬进 / 软到)+ 1 次面板 + 3 次手机那三格。
    //   少一次 = 有一段没跑到(early return / 抛异常之后的 finally),
    //   而那时上面每一格都可能是绿的 —— 一次没跑到的测量与一次通过的测量,
    //   在退出码上是同一个字节。**这条断言就是把那两件事分开的那一条。**
    assertPopulation('probe-nav-geometry', '量到的读数', readings.length, 10)
}

let cleanedUp = false
async function cleanup() {
    if (cleanedUp) return
    cleanedUp = true
    if (accountId) {
        await runPlan()
        const left = await (await rest(`/rest/v1/user_roles?select=user_id&user_id=eq.${accountId}`)).json()
        if (Array.isArray(left) && left.length) cleanupFailures.push(`DANGLING ADMIN GRANT for ${accountId}`)
    }
    try { if (server) process.kill(-server.pid, 'SIGKILL') } catch {}
    try { if (chrome) process.kill(-chrome.pid, 'SIGKILL') } catch {}
    try { release('scripts/probe-nav-geometry.mjs') } catch {}
    if (cleanupFailures.length) {
        console.error('\n✗ 清理没做干净:')
        for (const c of cleanupFailures) console.error('   ' + c)
    }
    const bad = fail.length + cleanupFailures.length
    try {
        console.log('\n── 顶栏盒子,逐条(停止条件 (f) 要的就是这张表)──')
        for (const r of readings) {
            console.log(`  ${r.label.padEnd(24)} vw=${String(r.vw).padEnd(5)} header=${fmtBox(r.header)}`)
        }
        console.log(`\n${bad ? '✗' : '✓'} probe-nav-geometry:${results.length} 格,${fail.length} 红,清理失败 ${cleanupFailures.length}`)
    } catch { /* stdout 断了(| head)—— 清理照样做完了 */ }
    process.exit(bad ? 1 : 0)
}

for (const sig of ['SIGINT', 'SIGTERM', 'SIGHUP', 'SIGPIPE']) process.on(sig, () => { cleanup() })
process.stdout.on('error', (e) => { if (e.code === 'EPIPE') cleanup() })

main().catch((e) => { fail.push('probe crashed: ' + e.message)
        try { console.error('\n✗ ' + e.message) } catch {} })
    .finally(cleanup)
