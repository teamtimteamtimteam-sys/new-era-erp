#!/usr/bin/env node
// scripts/probe-search-shell.mjs
// ════════════════════════════════════════════════════════════════════════════
// CONFIRM-1 Step 4 · 顶栏搜索外壳:两个宽度 × 两条到达方式
// ════════════════════════════════════════════════════════════════════════════
//
// 【它证的是什么】UI-1c 的规矩是「首页不画,别的页都画」。Tim 在生产上看到的是
// 「哪一页都不画」,桌面、满屏、每一个角色都一样。
//
// ════════════════════════════════════════════════════════════════════════════
// ★★【判据一:量【看得见】,不量【在不在 DOM 里】】★★
// ════════════════════════════════════════════════════════════════════════════
//   COPY-1 报过「/ → 0 · /me、/settings/accounts、/purchasing/orders → 1 each」。
//   那是一个 **DOM 计数**,而这一格带着 `hidden md:block` ——
//   **一个 display:none 的元素,在任何宽度上都数成 1。**
//   所以那条判据在 390px 上【不可能变红】,而它当时是绿的。
//   这里的判据是 offsetParent + 盒子尺寸 + computed display/visibility,
//   并且**把「在不在」与「看不看得见」分开打印** —— 那个区别正是本条的全部内容。
//
// ════════════════════════════════════════════════════════════════════════════
// ★★【判据二:走【人真的走的那条路】—— 而这一条比判据一更要紧】★★
// ════════════════════════════════════════════════════════════════════════════
//   Tim 的裁定(CONFIRM-1 第二轮):**一条判据必须走人真的走的那条路。**
//   前四次那一族是「判据看不见它要证的那个性质」;**这一次不一样 ——
//   判据看得见,只是被指向了一个【人永远到不了的状态】。**
//
//   `<SearchShell>` 住在 **根布局** 里(app/layout.tsx),而 App Router
//   **在客户端换页时不重画根布局**。人登录之后落在 `/`(lib/loginRoute.ts:148,
//   UI-1b 把落点从 /me 改成了 /),那一次根布局求值得到 `null`,
//   然后他点着 <Link> 走遍整个系统 —— **那个 null 跟着他一整个会话。**
//
//   而一次脚本 fetch / page.goto 是**硬导航**:根布局当场重画,外壳正常出现。
//   **两边都没有撒谎** —— COPY-1 量到的是真的,只是它量的那个状态,
//   人从来不会到达。所以 S3 必须**点击**,不许 goto。
//
//   ★ 而「我真的走了软导航吗」这件事本身也要证:导航前在 window 上盖一个记号,
//     导航后它还在 = 文档没有重新加载 = 这一次是软导航。
//     **没有这个记号,一次悄悄变成硬导航的点击会让 S3 假绿** ——
//     那就是本探针要抓的缺陷,穿着探针自己的衣服回来。
//
// ── 六格 ────────────────────────────────────────────────────────────────────
//   S1  1280 · 硬进 `/`            → 看不见   (规矩本身:首页让位给它自己那个大框)
//   S2  1280 · 硬进 `/me`          → 看得见   (COPY-1 走的就是这条路,它【应该】绿)
//   S3  1280 · `/` --点击--> `/me` → 看得见   (★ 人走的那条路。HEAD 上【预期红】)
//   S4  390  · 硬进 `/me`          → 看不见   (`hidden md:block` 的现状。
//                                             Tim 已裁定:今天不是缺陷 —— 首页自己
//                                             那个外壳没有宽度隐藏,手机上仍然读得到
//                                             「搜索还没建」。**记在这里是为了钉住它**:
//                                             谁改了那个断点,这一格会说话。
//                                             搜索真建起来那天的手机入口,记在 A 刀。)
//   S5  首屏 HTML · /me          → 有这一格 (★ 'use client' 的代价:它还在 SSR 里吗)
//   S6  首屏 HTML · /            → 没有     (规矩在服务端就已经生效)
//
// 用法:node scripts/probe-search-shell.mjs      (需要 .next 里有一份生产构建)
//      跑在 next start 上,不跑 next dev —— UI-1c 实测这棵树在 dev 下水合不收尾。
import { readFileSync, existsSync } from 'node:fs'
import { join } from 'node:path'
import { spawn, execSync } from 'node:child_process'
import { createConnection } from 'node:net'
import { acquireOrExit, release } from './liveLock.mjs'

const ROOT = new URL('..', import.meta.url).pathname
const PORT = 3202                 // 3198 survey-phone · 3199 冒烟 · 3201 probe-avatar
const CDP_PORT = 9338
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
function probe(id, ok, detail) {
    results.push({ id, ok, detail })
    if (!ok) fail.push(`${id}: ${detail}`)
    console.log(`${ok ? '✓' : '✗'} ${id.padEnd(26)} ${detail}`)
}

let server = null, chrome = null, accountId = null
const cleanupFailures = []
async function restCleanup(p, o, what) {
    try {
        const r = await rest(p, o)
        if (!r.ok) cleanupFailures.push(`${what} → HTTP ${r.status} ${(await r.text()).slice(0, 160)}`)
    } catch (e) { cleanupFailures.push(`${what} → ${e.message}`) }
}

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

// ★ 判据一的实现。**presence 与 visible 分开返回** —— COPY-1 量的是前者。
const MEASURE = `(() => {
    const el = document.querySelector('[data-nav="search-shell"]')
    if (!el) return { present: false, visible: false, why: 'not in DOM at all' }
    const r = el.getBoundingClientRect()
    const cs = getComputedStyle(el)
    const visible = el.offsetParent !== null && r.width > 0 && r.height > 0
        && cs.display !== 'none' && cs.visibility !== 'hidden'
    return { present: true, visible,
             why: 'display=' + cs.display + ' visibility=' + cs.visibility
                  + ' box=' + Math.round(r.width) + 'x' + Math.round(r.height)
                  + ' offsetParent=' + (el.offsetParent !== null) }
})()`

async function main() {
    acquireOrExit('scripts/probe-search-shell.mjs')
    if (!existsSync(join(ROOT, '.next/BUILD_ID')))
        throw new Error('.next/BUILD_ID 不在 —— 这一支要跑在【生产构建】上。先 npm run build。')
    if (!existsSync(CHROME)) throw new Error('chrome-headless-shell not at ' + CHROME)
    try { execSync(`lsof -ti tcp:${PORT} | xargs -r kill -9`, { stdio: 'ignore' }) } catch {}

    // ── 一次性 admin(用完即删,承诺由退出码兑现)────────────────────────────
    const email = `searchprobe-${Date.now()}@test.local`
    const cu = await (await rest('/auth/v1/admin/users', { method: 'POST',
        body: JSON.stringify({ email, password: 'search-probe-1', email_confirm: true }) })).json()
    accountId = cu.id
    if (!accountId) throw new Error('账号建不出来: ' + JSON.stringify(cu).slice(0, 300))
    const roles = await (await rest('/rest/v1/roles?select=id&code=eq.admin')).json()
    await rest('/rest/v1/user_roles', { method: 'POST', body: JSON.stringify({ user_id: accountId, role_id: roles[0].id }) })
    const sess = await (await fetch(URL_ + '/auth/v1/token?grant_type=password', { method: 'POST',
        headers: { apikey: ANON, 'Content-Type': 'application/json' },
        body: JSON.stringify({ email, password: 'search-probe-1' }) })).json()
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
        if (d.id && pending.has(d.id)) { const { res, rej } = pending.get(d.id); pending.delete(d.id)
            d.error ? rej(new Error(JSON.stringify(d.error))) : res(d.result) }
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

    // ★ 等【水合完成】,不等"HTML 里有那个东西"。水合过的节点上挂着 __reactFiber$…,
    //   服务端送来的 HTML 上没有。不等它,下面那次点击不会被 <Link> 接管 ——
    //   于是它变成一次硬导航,而 S3 会【假绿】。
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

    // ── S1 · 1280,硬进首页 → 看不见(规矩本身)────────────────────────────
    await setWidth(1280)
    await hardGoto('/')
    const s1 = await evalJs(MEASURE)
    console.log(`   · / @1280  present=${s1.present} visible=${s1.visible}  ${s1.why}`)
    probe('S1.home-hidden', s1.visible === false,
        `首页不画顶栏搜索框(present=${s1.present}) —— 它自己有一个大的`)

    // ── S2 · 1280,硬进 /me → 看得见(COPY-1 走的就是这条路)──────────────
    await hardGoto('/me')
    const s2 = await evalJs(MEASURE)
    console.log(`   · /me @1280 (硬导航) present=${s2.present} visible=${s2.visible}  ${s2.why}`)
    probe('S2.hard-nav-visible', s2.visible === true,
        `硬进非首页看得见 —— ★ 这一格【绿】正是 COPY-1 当时量到的东西`)

    // ── S3 · ★ 人走的那条路:落在 /,点着走到 /me ★ ────────────────────────
    await hardGoto('/')
    // 盖记号:它活过这次导航,就证明文档没有重新加载。
    await evalJs(`window.__softNavMarker = 'CONFIRM1'`)
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
    // 等换页落定:pathname 变了,而且水合过的
    const t0 = Date.now()
    for (;;) {
        if (await evalJs(`location.pathname === '/me'`)) break
        if (Date.now() - t0 > 20000) throw new Error('点击之后 20s 没到 /me')
        await sleep(200)
    }
    await waitHydrated('soft /me')
    // ★ 先证这一次【真的是软导航】—— 不然下面那一格量的是另一条路
    const wasSoft = await evalJs(`window.__softNavMarker === 'CONFIRM1'`)
    probe('S3a.really-soft-nav', wasSoft === true,
        wasSoft ? '记号活过了这次换页 —— 文档没有重新加载,这是一次真的软导航'
                : '★ 记号没了:这一次点击变成了硬导航,S3b 量的不是人走的那条路')
    const s3 = await evalJs(MEASURE)
    console.log(`   · /me @1280 (软导航) present=${s3.present} visible=${s3.visible}  ${s3.why}`)
    probe('S3b.soft-nav-visible', s3.visible === true,
        `点着走到非首页之后仍然看得见 —— ★ 这是人真的走的那条路`)

    // ── S4 · 390,硬进 /me → 看不见(`hidden md:block` 的现状,已裁定)────
    await setWidth(390)
    await hardGoto('/me')
    const s4 = await evalJs(MEASURE)
    console.log(`   · /me @390  present=${s4.present} visible=${s4.visible}  ${s4.why}`)
    probe('S4.phone-hidden', s4.visible === false,
        `390px 上看不见(present=${s4.present})—— ★ present 与 visible 在这一格【分开了】,` +
        `而 COPY-1 的判据只看得见前者`)

    // ── S5/S6 · 'use client' 的代价:它还在【首屏 HTML】里吗 ─────────────────
    // ★ Tim 在 CONFIRM-1 第三轮点名要的那一条:把一个服务端组件改成客户端组件,
    //   如果这一格变成"水合之后才出现",那就是拿一个看不见的缺陷换了一个
    //   【看得见】的缺陷(首屏闪一下 / 顶栏跳一下版)。
    //   判据不是看渲染完的 DOM —— 那时已经水合过了,什么都看得见。
    //   **判据是【原始 HTML 字节】**:JS 一行都还没跑的那一份。
    const ssr = async (path) => {
        const r = await fetch(`${origin}${path}`, {
            headers: { cookie: `${cookieName}=${cookieValue}` }, redirect: 'manual' })
        const html = await r.text()
        return { status: r.status,
                 isApp: html.includes('data-nav="avatar-menu"'),
                 hasShell: html.includes('data-nav="search-shell"') }
    }
    const h5 = await ssr('/me')
    console.log(`   · SSR /me  HTTP ${h5.status} isApp=${h5.isApp} hasShell=${h5.hasShell}`)
    probe('S5.ssr-has-shell', h5.status === 200 && h5.isApp && h5.hasShell === true,
        `非首页的【首屏 HTML】里就有这一格 —— 'use client' 没有把它推到水合之后,不闪不跳版`)
    const h6 = await ssr('/')
    console.log(`   · SSR /    HTTP ${h6.status} isApp=${h6.isApp} hasShell=${h6.hasShell}`)
    probe('S6.ssr-home-clean', h6.status === 200 && h6.isApp && h6.hasShell === false,
        `首页的首屏 HTML 里【没有】这一格 —— 规矩在服务端就已经生效`)
}

let cleanedUp = false
async function cleanup() {
    if (cleanedUp) return
    cleanedUp = true
    if (accountId) {
        await restCleanup(`/rest/v1/user_roles?user_id=eq.${accountId}`, { method: 'DELETE' }, `revoke grant ${accountId}`)
        await restCleanup(`/auth/v1/admin/users/${accountId}`, { method: 'DELETE' }, `delete account ${accountId}`)
        const left = await (await rest(`/rest/v1/user_roles?select=user_id&user_id=eq.${accountId}`)).json()
        if (Array.isArray(left) && left.length) cleanupFailures.push(`DANGLING ADMIN GRANT for ${accountId}`)
    }
    try { if (server) process.kill(-server.pid, 'SIGKILL') } catch {}
    try { if (chrome) process.kill(-chrome.pid, 'SIGKILL') } catch {}
    try { release('scripts/probe-search-shell.mjs') } catch {}
    if (cleanupFailures.length) {
        console.error('\n✗ 清理没做干净:')
        for (const c of cleanupFailures) console.error('   ' + c)
    }
    const bad = fail.length + cleanupFailures.length
    try {
        console.log(`\n${bad ? '✗' : '✓'} probe-search-shell:${results.length} 格,${fail.length} 红,清理失败 ${cleanupFailures.length}`)
    } catch { /* stdout 断了(| head)—— 清理照样做完了 */ }
    process.exit(bad ? 1 : 0)
}

for (const sig of ['SIGINT', 'SIGTERM', 'SIGHUP', 'SIGPIPE']) process.on(sig, () => { cleanup() })
process.stdout.on('error', (e) => { if (e.code === 'EPIPE') cleanup() })

main().catch((e) => { fail.push('probe crashed: ' + e.message)
        try { console.error('\n✗ ' + e.message) } catch {} })
    .finally(cleanup)
