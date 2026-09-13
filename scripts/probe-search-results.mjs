#!/usr/bin/env node
// scripts/probe-search-results.mjs
// ════════════════════════════════════════════════════════════════════════════
// SEARCH-1 · 搜索面板【真的找得到东西吗】—— 而 S9 的那条泄漏线,要一个【进不去】的人才量得到
// ════════════════════════════════════════════════════════════════════════════
//
// 【为什么它必须存在】`probe-nav-geometry.mjs` 证的是**面板打得开、三节都在**;
//   它一个字都没打进去。**一个打得开却搜不出东西的面板,与一个搜得出东西的面板,
//   在那支探针上是同一个读数。**
//
// ★★【而 S9 的判据【按构造】量不到,如果探针只用 admin】★★
//   Tim 的裁定:「内容不给,存在说出来」——「Finance 里还有 3 条,你没有权限看」。
//   **一个 admin 什么都看得见,所以他那一侧的被扣下计数【恒为 0】。**
//   一支只跑 admin 的探针会对着一条从来没有被求值过的代码路径报绿。
//   ☞ 所以这一支起**两个**一次性账号:一个 admin,一个 **operations**,
//     而那条泄漏线只在后者身上量得到。
//   (这与 AGENTS.md 记的 fixture 26 那一课同形:fixture 跑在 postgres 上、
//    绕过 RLS,于是两条臂是空的 —— **判据必须走那个真的被挡住的人走的路。**)
//
// ════════════════════════════════════════════════════════════════════════════
// 【瞄准 · AIM】
//   我读的是      :chrome-headless-shell 通过 CDP 打开搜索面板、**真的把字打进去**,
//                   然后读 `[data-search-slot]` 三节里的 DOM:命中条数、
//                   `[data-search-withheld]` 那几行的文字、手册那一节的版本行。
//   我声称管的是   :① 面板找得到页面与手册段落;② 被扣下的结果**说出了存在**,
//                   而且那句话里的模块名是九个一级模块之一;③ 中文搜手册匹配不到时,
//                   屏幕上那句「这一节是英文的」在;
//                   ★ ④(SEARCH-3)**打字发生在【你点的那一格】里** —— 全页只有
//                   一个 `[data-search-input]`,而它住在触发格里面(R6)。
//   两者不同之处   :★ **我量的是一个 operations 角色看到的东西,不是每一个角色。**
//                   别的角色被扣下多少条,我没量。
//                   ★ 我也**不判排序好不好** —— 排序的规则只有一条(标题命中的在前),
//                   写在 `app/components/search/actions.ts` 里,而"好不好"要人看。
// ════════════════════════════════════════════════════════════════════════════
//
// 用法:node scripts/probe-search-results.mjs   (需要 .next 里有一份生产构建)
// 退出码:0 干净 / 1 有格子红了 / 2 量具自己坏了
import { readFileSync, existsSync } from 'node:fs'
import { join } from 'node:path'
import { spawn, execSync } from 'node:child_process'
import { createConnection } from 'node:net'
import { acquireOrExit, release } from './liveLock.mjs'
import { openPlan, planDelete, ephemeralGrantBody, runPlan, reapStalePlans, ORDER } from './ephemeral.mjs'
import { assertPopulation } from './lib/selfproof.mjs'

const ROOT = new URL('..', import.meta.url).pathname
const PORT = 3205
const CDP_PORT = 9341
const CHROME = join(process.env.HOME, '.cache/puppeteer/chrome-headless-shell/mac_arm-152.0.7977.54/chrome-headless-shell-mac-arm64/chrome-headless-shell')

const env = readFileSync(join(ROOT, '.env.local'), 'utf8')
const URL_ = env.match(/NEXT_PUBLIC_SUPABASE_URL=(\S+)/)[1]
const ANON = env.match(/NEXT_PUBLIC_SUPABASE_ANON_KEY=(\S+)/)[1]
const SERVICE = env.match(/SUPABASE_SERVICE_ROLE_KEY=(\S+)/)[1]

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const rest = (p, o = {}) => fetch(URL_ + p, { ...o, headers: {
    apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, 'Content-Type': 'application/json', ...(o.headers || {}) } })

// ════════════════════════════════════════════════════════════════════════════
// ★★★【那个受限角色【必须是线上活着的】—— 而第一版挑的那个已经退休了】★★★
// ════════════════════════════════════════════════════════════════════════════
//   第一版挑的是 `operations`(AGENTS.md 的 `--reach` 那一节把它列为三个角色之一)。
//   ★ **实测:它在线上是 `is_active=false` · `deleted_at=2026-09-10`。**
//   而 `current_user_permissions()` 的 WHERE 里写着 `AND r.is_active AND r.deleted_at IS NULL`
//   —— ☞ **于是那个账号解析出来是【零权限】。**
//
//   ★★ 后果值得读两遍:**R5 / R5b / R5c 三格照样全绿** ——
//     一个零权限的人当然看得到「N more matches in X」那句话,而且模块名当然是
//     九个之一。**那三格因此证明不了它们声称的那件事:一个【部分可见】的人
//     看到的是不是对的。** 把它们读成"S9 通过了",就是拿一个极端情形冒充一般情形。
//   ☞ **抓住它的是 R5d** —— 那条配对的断言(「他自己进得去的东西照样找得到」)。
//     它红了,而它红的理由不是产品坏了,是**探针挑错了角色**。
//     **一条配对的断言,买到的正是这个。**
//
//   ⚠ 顺带一条【不属于这一刀、但这一刀看见了】的事,照直记:
//     `AGENTS.md` 的 `--reach` 那一节仍然把 operations 写成三个角色之一,
//     而它已经退休了。**报告,不清扫** —— 处置由人决定。
//
// 【为什么挑 warehouse】实测线上 12 条权限:有 inbound / inventory / output /
//   stocktakes / logistics / tasks,**没有 finance、没有 processing**。
//   于是「payments」那一类必然被扣下,而他自己那几族必然找得到 ——
//   **两侧都不是空的,这才量得出 S9 那条线。**
const RESTRICTED_ROLE = 'warehouse'

const results = []
const fail = []
function probe(id, ok, detail) {
    results.push({ id, ok, detail })
    if (!ok) fail.push(`${id}: ${detail}`)
    console.log(`${ok ? '✓' : '✗'} ${id.padEnd(30)} ${detail}`)
}

let server = null, chrome = null
const accounts = []
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

/** 面板里现在画着什么 —— 三节各自的条数、被扣下的那几行、手册那一节的几句话。 */
const READ = `(() => {
    const txt = (el) => (el && el.textContent || '').replace(/\\s+/g, ' ').trim()
    const sec = (name) => document.querySelector('[data-search-slot="' + name + '"]')
    const hits = (name) => [...(sec(name)?.querySelectorAll('[data-search-hit]') ?? [])].map(txt)
    return {
        panelOpen: !!document.querySelector('[data-search-panel]'),
        answered: document.querySelector('[data-search-answered]')?.getAttribute('data-search-answered') ?? null,
        slots: [...document.querySelectorAll('[data-search-slot]')].map((e) => e.getAttribute('data-search-slot')),
        pageHits: [...(sec('pages')?.querySelectorAll('[data-search-hit="page"]') ?? [])].map(txt),
        manualHits: [...(sec('manual')?.querySelectorAll('[data-search-hit="manual"]') ?? [])].map(txt),
        manualLangLine: txt(document.querySelector('[data-search-manual-language]')),
        manualSectionText: txt(sec('manual')),
        recordsState: document.querySelector('[data-search-records-state]')?.getAttribute('data-search-records-state') ?? null,
        recordsText: txt(document.querySelector('[data-search-records-state]')),
        // SEARCH-2b:单据那一节现在【真的有命中】,所以要读得到它们。
        recordHits: [...(sec('records')?.querySelectorAll('[data-search-hit="record"]') ?? [])].map(txt),
        recentHits: [...(sec('recents')?.querySelectorAll('[data-search-hit="recent"]') ?? [])].map(txt),
        withheld: [...document.querySelectorAll('[data-search-withheld]')]
            .map((e) => ({ module: e.getAttribute('data-search-withheld'), text: txt(e) })),
        emptyRecents: txt(document.querySelector('[data-search-empty-recents]')),
        // ★ SEARCH-4:一条命中带出来的关联分组,按单据号收起来。
        //   groups 是那一条命中【声明】自己有几组,items 是真的画出来的几行 ——
        //   两个数合起来才拦得住"属性写对了、行没画出来"那一种。
        related: [...document.querySelectorAll('[data-search-related]')].map((e) => ({
            code: e.getAttribute('data-search-related'),
            groups: Number(e.getAttribute('data-search-related-groups')),
            items: [...e.querySelectorAll('[data-search-related-group]')].map((g) => ({
                key: g.getAttribute('data-search-related-group'),
                n: Number(g.getAttribute('data-search-related-count')),
                text: txt(g),
            })),
            text: txt(e),
        })),
        relatedPartialLine: txt(document.querySelector('[data-search-related-partial]')),
        // ★★ 停止条件 (g):下拉【自己的高度】。V1 让结果按设计变高,而一个
        //   跑出 390px 屏幕底下的下拉,就是这一刀版本的溢出。
        panel: (() => {
            const p = document.querySelector('[data-search-panel]')
                   ?? document.querySelector('[role="dialog"]')
            if (!p) return null
            const r = p.getBoundingClientRect()
            return { w: Math.round(r.width * 100) / 100, h: Math.round(r.height * 100) / 100,
                     top: Math.round(r.top * 100) / 100, bottom: Math.round(r.bottom * 100) / 100,
                     viewportH: window.innerHeight,
                     overflowsBottom: r.bottom > window.innerHeight + 0.5,
                     scrolls: p.scrollHeight > p.clientHeight + 0.5 }
        })(),
        failed: !!document.querySelector('[data-search-failed]'),
        // ★★ SEARCH-3 · U1:**你在【你点的那一格】里打字。**
        //   两个读数合起来才是那句话:① 全页只有【一个】输入框;
        //   ② 而它就住在【你点的那一格】里面。
        //   ⚠ 缺了 ① 那一半,「输入框在触发格里」在一个同时还开着第二个输入框的
        //     面板上照样成立 —— 而那正是改前那个模态的形状。
        inputCount: document.querySelectorAll('[data-search-input]').length,
        inputInsideField: (() => {
            const f = document.querySelector('[data-nav="search-trigger"]')
            const i = document.querySelector('[data-search-input]')
            return !!(f && i && f.contains(i))
        })(),
    }
})()`

async function main() {
    acquireOrExit('scripts/probe-search-results.mjs', { ownExit: false })
    openPlan('scripts/probe-search-results.mjs')
    await reapStalePlans()
    if (!existsSync(join(ROOT, '.next/BUILD_ID')))
        throw new Error('.next/BUILD_ID 不在 —— 这一支要跑在【生产构建】上。先 npm run build。')
    // ★★ SEARCH-3:把它读到的 `.next/BUILD_ID` 印出来 —— SEARCH-1 §6 末尾那一次
    //   「对着旧构建量出一个干净的零」就是这么发生的(`git stash pop` 之后没重建)。
    //   一份读数必须说得出【它量的是哪一次构建】。
    console.log(`· .next/BUILD_ID = ${readFileSync(join(ROOT, '.next/BUILD_ID'), 'utf8').trim()}`)
    if (!existsSync(CHROME)) throw new Error('chrome-headless-shell not at ' + CHROME)
    try { execSync(`lsof -ti tcp:${PORT} | xargs -r kill -9`, { stdio: 'ignore' }) } catch {}

    // ── 两个一次性账号:admin 与一个【真的被挡住】的角色 ────────────────────
    async function makeAccount(roleCode) {
        const email = `searchres-${roleCode}-${Date.now()}@test.local`
        const pw = 'search-results-1'
        const cu = await (await rest('/auth/v1/admin/users', { method: 'POST',
            body: JSON.stringify({ email, password: pw, email_confirm: true }) })).json()
        if (!cu.id) throw new Error(`账号建不出来(${roleCode}): ` + JSON.stringify(cu).slice(0, 300))
        planDelete(`/rest/v1/user_roles?user_id=eq.${cu.id}`, `revoke grant ${cu.id}`, ORDER.GRANT)
        planDelete(`/auth/v1/admin/users/${cu.id}`, `delete account ${cu.id}`, ORDER.ACCOUNT)
        const roles = await (await rest(`/rest/v1/roles?select=id&code=eq.${roleCode}`)).json()
        if (!roles?.[0]?.id) throw new Error(`角色 ${roleCode} 在库里找不到 —— 这一次读数不作数`)
        await rest('/rest/v1/user_roles', { method: 'POST',
            body: JSON.stringify(ephemeralGrantBody(cu.id, roles[0].id)) })
        const sess = await (await fetch(URL_ + '/auth/v1/token?grant_type=password', { method: 'POST',
            headers: { apikey: ANON, 'Content-Type': 'application/json' },
            body: JSON.stringify({ email, password: pw }) })).json()
        if (!sess?.access_token) throw new Error(`登录失败(${roleCode}): ` + JSON.stringify(sess).slice(0, 200))
        accounts.push({ roleCode, id: cu.id })
        return 'base64-' + Buffer.from(JSON.stringify(sess)).toString('base64url')
    }
    const cookieName = 'sb-' + URL_.split('//')[1].split('.')[0] + '-auth-token'
    const adminCookie = await makeAccount('admin')
    const opsCookie = await makeAccount(RESTRICTED_ROLE)
    console.log(`· 一次性账号 ${accounts.map((a) => `${a.roleCode}=${a.id}`).join(' · ')}`)

    server = spawn('npx', ['next', 'start', '-p', String(PORT)], { cwd: ROOT, detached: true, stdio: ['ignore', 'pipe', 'pipe'] })
    server.stderr.on('data', () => {})
    if (!await waitPort(PORT, 90000)) throw new Error(`next start 没在 :${PORT} 起来`)
    const origin = `http://localhost:${PORT}`

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
    await S('Page.enable'); await S('Runtime.enable'); await S('Network.enable')
    await S('Emulation.setDeviceMetricsOverride', { width: 1280, height: 900, deviceScaleFactor: 1, mobile: false })

    const evalJs = async (expr) => {
        const r = await S('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true })
        if (r.exceptionDetails) throw new Error(expr.slice(0, 60) + ' → ' + JSON.stringify(r.exceptionDetails).slice(0, 300))
        return r.result.value
    }
    const setCookie = (value) => S('Network.setCookies', { cookies: [{ name: cookieName, value,
        domain: 'localhost', path: '/', httpOnly: false, secure: false }] })

    async function openPanelOn(path) {
        await S('Page.navigate', { url: `${origin}${path}` })
        const t0 = Date.now()
        for (;;) {
            const ok = await evalJs(`(() => { const b = document.querySelector('[data-nav="search-trigger"]'); return !!b && Object.keys(b).some(k => k.startsWith('__react')) })()`)
            if (ok) break
            if (Date.now() - t0 > 25000) throw new Error(`${path}:触发钮没有水合`)
            await sleep(200)
        }
        // ★ 两种写法都认:改前触发格是一颗 <button>,改后它是一个包着输入框的
        //   <label>(点它 = 聚焦那个输入框)。一支只认一种写法的探针量不了另一边。
        await evalJs(`(() => {
            document.querySelector('[data-nav="search-trigger"]').click()
            const i = document.querySelector('[data-search-input]')
            if (i) i.focus()
        })()`)
        await sleep(300)
    }

    /** 把字打进去,等到面板画出【回答这一个问题】的结果为止。 */
    async function type(q) {
        await evalJs(`(() => {
            const el = document.querySelector('[data-search-input]')
            if (!el) throw new Error('面板里找不到输入框')
            const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set
            setter.call(el, ${JSON.stringify(q)})
            el.dispatchEvent(new Event('input', { bubbles: true }))
        })()`)
        // ════════════════════════════════════════════════════════════════
        // ★★【等的是【这一次的】答案,判据是它自己说出来的那个问题】★★
        // ════════════════════════════════════════════════════════════════
        //   第一版等的是「有命中,或者过了 2500ms」。★ 那一版红了一格(R5d),
        //   而红的原因**不是产品** —— 是一次往返比 2500ms 慢时,
        //   探针把"还没回来"读成了"没找到"。
        //   ☞ 面板因此在结果区上挂了 `data-search-answered`,值就是
        //     **这份答案回答的那个问题**。等它等于我刚打的那一串,一个字不差。
        //   与 AGENTS.md 那条「判据必须检查【标签承诺的那件事】」同源:
        //   标签写的是"等这次搜索的结果",判据问的也就该是这一句。
        const t0 = Date.now()
        for (;;) {
            const r = await evalJs(READ)
            if (r.failed) return r
            if (r.answered === q) return r
            if (Date.now() - t0 > 20000) throw new Error(`打「${q}」之后 20s 还没有【这一次的】答案(answered=${JSON.stringify(r.answered)})`)
            await sleep(150)
        }
    }

    // ══ admin ════════════════════════════════════════════════════════════
    await setCookie(adminCookie)
    await openPanelOn('/me')

    // ══ ★★ R6 · SEARCH-3 · U1:你在【你点的那一格】里打字 ★★ ══════════════
    //
    // 【这一格换掉了什么】SEARCH-1/2b 的这支探针从来没有问过"输入框在哪"——
    //   它只问"打进去之后找不找得到东西"。而改前的答案是:**你点的那一格在一层
    //   遮罩底下待着,真正接字的是模态里【另一个】输入框。**
    //   ☞ Tim 的 U1 把这件事变成一条可以量的判据,所以它在这里,不在注释里。
    //   ★ 改前这一格【必红】:那时 `[data-search-input]` 住在 `[data-search-panel]`
    //     里面,而 `[data-nav="search-trigger"]` 是它外面那颗按钮。
    const u1 = await evalJs(READ)
    probe('R6.you-type-in-the-field-you-clicked',
        u1.inputCount === 1 && u1.inputInsideField === true,
        `全页 [data-search-input] ${u1.inputCount} 个 · 它在触发格里面:${u1.inputInsideField}` +
        ` —— ★ 一个输入框,而它就是你点的那一格`)

    // R0 · 空状态:三节都在,而且「最近看过」那一句说出来了(S10)
    const empty = await evalJs(READ)
    probe('R0.empty-state',
        empty.panelOpen &&
        JSON.stringify(empty.slots) === JSON.stringify(['records', 'pages', 'manual']) &&
        empty.emptyRecents.length > 0,
        `三节 = ${JSON.stringify(empty.slots)} · 「还没有最近看过」那一句:${empty.emptyRecents ? '在' : '★ 不在'}`)

    // R1 · job ② —— Tim 自己举的那个例子
    const r1 = await type('field receiving')
    probe('R1.pages-find-buried-screen',
        r1.pageHits.some((h) => h.includes('/inbound/receive')),
        `「field receiving」→ 页面 ${r1.pageHits.length} 条:${r1.pageHits.slice(0, 3).join(' | ').slice(0, 160)}`)

    // R1b · ★ 那 18 条【本来搜不到】—— 随手再验一条,不要只验 Tim 举的那一个
    const r1b = await type('leave balances')
    probe('R1b.pages-find-another-buried',
        r1b.pageHits.some((h) => h.includes('/hr/leave/balances')),
        `「leave balances」→ 页面 ${r1b.pageHits.length} 条:${r1b.pageHits.slice(0, 2).join(' | ').slice(0, 160)}`)

    // R2 · job ③ 上半 + 手册版本(Tim 的裁定 ③)
    const r2 = await type('partially shipped')
    const versionShown = /v1\.0\.1/.test(r2.manualSectionText)
    probe('R2.manual-finds-passage-with-version',
        r2.manualHits.length > 0 && versionShown,
        `「partially shipped」→ 手册 ${r2.manualHits.length} 段 · 版本行里有 v1.0.1:${versionShown} · 首条:${(r2.manualHits[0] ?? '').slice(0, 120)}`)

    // R3 · ★★ job ① 的槽 —— **SEARCH-2b(2026-09-13)把它从"还没建"换成了真结果**
    //
    // 【这一格原来断言的是什么,以及为什么换掉】SEARCH-1 写的是
    //   `recordsState === 'not-built'` —— 它钉住的是「这一半还没建」与「没找到」
    //   **必须分得开**。那条区别今天一个字都没变,**变的是答案**:三支迁移
    //   (document_types · pg_trgm+GIN · 22 条 recents 索引)下去之后,
    //   `built` 恒为 true,于是 `data-search-records-state` 这个属性**根本不再渲染**。
    //   ☞ 所以原样留着它,就是留下一条【永远红】的判据;而把它删掉,
    //     就是把"找得到单据"这件事变成没有人看着。**两个都不对,所以是换。**
    //
    // 【换成什么 —— 而这一格必须用一个【真的存在的】单据号】
    //   探针自己不建单据(建一张真单据要走整条业务路径,还会烧号 —— 那 9 支
    //   触发器用 nextval,不回滚)。所以它拿 admin 身份搜一个**线上真有的前缀**,
    //   断言:① 不再画「还没建」;② 至少一条命中;③ 命中里带着那个号。
    // ★ 号从【线上现读】,不写死一个。写死的那一刻起,它就是一条会在
    //   某张单据被删掉的那天为了错的理由变红的判据 —— 而那天没有人会知道
    //   红的是"搜索坏了"还是"那一行没了"。
    const probeCode = await (async () => {
        const r = await rest('/rest/v1/quotes?select=code&order=code.desc&limit=1')
        const rows = await r.json()
        if (!r.ok || !Array.isArray(rows) || rows.length === 0 || !rows[0].code) {
            throw new Error(`R3 取不到一个真的单据号(HTTP ${r.status}) —— `
                + `这不是"搜索坏了",是探针自己拿不到判据的输入,不许当成通过`)
        }
        return rows[0].code
    })()
    const RECORD_PROBE_CODE = probeCode
    const r3 = await type(RECORD_PROBE_CODE)
    probe('R3.records-slot-is-built-and-finds-one',
        r3.recordsState === null && r3.recordHits.length > 0
            && r3.recordHits.some((h) => h.includes(RECORD_PROBE_CODE)),
        `单据那一节 state=${r3.recordsState}(built ⇒ 不该再有 not-built)· `
        + `命中 ${r3.recordHits.length} 条:${r3.recordHits.slice(0, 3).map((h) => `「${h.slice(0, 48)}」`).join(' · ')}`)

    // ══ ★★ R7 族 · SEARCH-4:一条命中【带着它的关联记录】★★ ═══════════════
    //
    // 【这一格必须真的找到东西】一个"搜了、没红"的格子与一个"搜了、什么都没有"
    //   的格子在退出码上一模一样。所以它挑的是一个**今天真的有一叠关联**的对象,
    //   而"有多少"由探针**在跑的时候现读**。
    //
    // ★★【为什么不把 11 / 8 / 4 / 3 写死 —— SEARCH-3 的 R3 教训,逐字同一条】★★
    //   一个写死的计数会在某天多一行的时候为了【错的理由】变红,
    //   而那天没有人分得出红的是"搜索坏了"还是"数据动了"。
    //   ☞ 所以期望值走一条**独立的路**取:REST 直查那张表的行数
    //     (探针身份是 service role,而 UI 那一侧是 admin —— 两条路不共用代码)。
    const ACME = await (async () => {
        const r = await rest('/rest/v1/suppliers?select=id,code,legal_name&legal_name=ilike.*Acme*&limit=1')
        const rows = await r.json()
        if (!r.ok || !Array.isArray(rows) || rows.length === 0) {
            // ★ 这是【量具拿不到输入】,不是"关联搜索坏了"。两种必须分开报。
            throw new Error(`R7 取不到那个供应商(HTTP ${r.status})—— `
                + `探针自己拿不到判据的输入,不许当成通过`)
        }
        return rows[0]
    })()
    // 期望值:逐表现读,**不写死**。四张表都以 supplier_id 指向 suppliers。
    const acmeExpect = {}
    for (const t of ['inbound_batches', 'payments', 'purchase_orders', 'expenses']) {
        const r = await rest(`/rest/v1/${t}?select=id&supplier_id=eq.${ACME.id}`,
            { headers: { Prefer: 'count=exact' } })
        const rows = await r.json()
        if (!r.ok || !Array.isArray(rows)) throw new Error(`R7 数不出 ${t} 的行数(HTTP ${r.status})`)
        acmeExpect[t] = rows.length
    }
    const EXPECT_KEY = { inbound_batches: 'inbound_batch', payments: 'payment_out',
                         purchase_orders: 'purchase_order', expenses: 'expense' }
    const r7 = await type('Acme')
    const acmeRow = r7.related.find((x) => x.code === ACME.code)
    const shown = Object.fromEntries((acmeRow?.items ?? []).map((i) => [i.key, i.n]))
    // ★ 只比对【探针独立数得出来】的那四类;UI 可能还带着别的组(经桥的那些),
    //   而那几组这里没有独立的期望值 —— 不比对它们,并且把它们报出来。
    const mismatches = Object.entries(acmeExpect)
        .filter(([t]) => acmeExpect[t] > 0)
        .filter(([t]) => shown[EXPECT_KEY[t]] !== acmeExpect[t])
        .map(([t]) => `${t}: 屏幕 ${shown[EXPECT_KEY[t]] ?? '(没有这一组)'} ≠ 现读 ${acmeExpect[t]}`)
    probe('R7.a-hit-carries-its-grouped-relations',
        r7.recordHits.some((h) => h.includes(ACME.code)) && !!acmeRow
            && acmeRow.groups > 0 && mismatches.length === 0,
        `搜「Acme」→ 命中 ${r7.recordHits.length} 条 · ${ACME.code} 带 ${acmeRow?.groups ?? 0} 组:`
        + `${(acmeRow?.items ?? []).map((i) => `${i.key} ${i.n}`).join(' · ') || '(零)'}`
        + ` · 现读期望 ${JSON.stringify(acmeExpect)}`
        + (mismatches.length ? ` · ★ 对不上:${mismatches.join(' ; ')}` : ''))

    // R7b · ★ 两种状态【穷尽】:要么有分组,要么那句「没有关联记录」——
    //   而【都不许】是一块白,更不许是"还没建"。SEARCH-3 刚为同一条理由
    //   删掉 records.built 与 search.recordsNotBuiltYet。
    probe('R7b.every-hit-says-one-of-the-two-things',
        r7.recordHits.length > 0
            && r7.related.length === r7.recordHits.length
            && r7.related.every((x) => (x.groups > 0 && x.items.length === x.groups)
                                       || (x.groups === 0 && x.text.trim().length > 0)),
        `命中 ${r7.recordHits.length} 条 · 关联块 ${r7.related.length} 个 · `
        + r7.related.map((x) => `${x.code}:${x.groups} 组/${x.items.length} 行`).join(' · '))

    // R7c · ★ Q8:一个不提"还有你看不到的"的计数会被当成全部。
    probe('R7c.counts-say-they-are-only-what-you-can-see',
        (r7.related.some((x) => x.groups > 0)) === (r7.relatedPartialLine.trim().length > 0),
        `有分组:${r7.related.some((x) => x.groups > 0)} · 那一句:`
        + `${r7.relatedPartialLine ? `「${r7.relatedPartialLine.slice(0, 80)}」` : '★ 不在'}`)

    // R7d · ★★ 停止条件 (g):下拉【自己的高度】。V1 让结果按设计变高。
    //   ⚠ 这一格量的是**探针这一侧的视口(1280×900)**;390 那一侧由
    //     scripts/probe-nav-geometry.mjs 量,两支各管一个,谁都不冒充对方。
    probe('R7d.panel-does-not-run-off-the-bottom',
        !!r7.panel && !r7.panel.overflowsBottom,
        r7.panel
            ? `面板 ${r7.panel.w}×${r7.panel.h} · top=${r7.panel.top} bottom=${r7.panel.bottom} `
              + `· 视口高 ${r7.panel.viewportH} · 跑出底下:${r7.panel.overflowsBottom} · 自己滚:${r7.panel.scrolls}`
            : '★ 读不到面板的盒子 —— [data-search-panel] 不在')

    // R4 · ★ S7 那条【Tim 没说、而面板必须处理】的后果:中文搜手册,匹配不到
    const r4 = await type('入库批次')
    probe('R4.chinese-query-says-manual-is-english',
        r4.manualHits.length === 0 && r4.manualLangLine.length > 0,
        `中文查询 → 手册 ${r4.manualHits.length} 段,而「这一节是英文的」那一句:${r4.manualLangLine ? '在' : '★ 不在'} —— 「${r4.manualLangLine.slice(0, 70)}」`)

    // ══ ★★ 受限角色 —— S9 的那条线只在他身上量得到 ★★ ══════════════════
    await setCookie(opsCookie)
    await openPanelOn('/me')
    const r5 = await type('payments')
    const mods = r5.withheld.map((w) => w.module)
    const NINE = ['purchasing', 'logistics', 'operation', 'sales', 'finance', 'inventory', 'hr', 'tools', 'settings']
    probe('R5.withheld-disclosed',
        r5.withheld.length > 0,
        `${RESTRICTED_ROLE} 搜「payments」→ 被扣下 ${r5.withheld.length} 行:${r5.withheld.map((w) => `${w.module}「${w.text.slice(0, 60)}」`).join(' · ')}`)
    probe('R5b.withheld-module-is-one-of-nine',
        r5.withheld.length > 0 && mods.every((m) => NINE.includes(m)),
        `报出来的模块 = ${JSON.stringify(mods)} —— ★ 必须是九个一级模块之一(Tim 的 Q6:薪资不是模块,它住在 hr 底下)`)
    probe('R5c.withheld-line-has-a-count',
        r5.withheld.every((w) => /\d/.test(w.text)),
        `每一行都带着数目 —— ★ Tim 已裁定计数照给(SEARCH-0 §7 存了那次交换)`)
    // ★ 而"他自己进得去的东西照样找得到" —— 否则上面那条可能是"他什么都搜不到"。
    //   ⚠ 这一格【必须把它看到的东西报出来】:第一版的 detail 是一句静态文案,
    //     于是它红的时候说不出自己看见了什么,而我只好再跑一遍去问它
    //     (AGENTS.md:「一条说不出自己抓到了什么的检查,会让你再跑一遍去问它」)。
    const r5d = await type('stocktakes')
    probe('R5d.ops-still-finds-his-own',
        r5d.pageHits.length > 0,
        `${RESTRICTED_ROLE} 搜「stocktakes」→ 页面 ${r5d.pageHits.length} 条:` +
        `${r5d.pageHits.slice(0, 3).join(' | ').slice(0, 160) || '(零)'} · ` +
        `被扣下 ${r5d.withheld.length} 行 ${JSON.stringify(r5d.withheld)} · answered=${JSON.stringify(r5d.answered)} · 手册 ${r5d.manualHits.length} 段`)

    // ★ 下界从 10 加到 14 —— SEARCH-4 多了 R7 · R7b · R7c · R7d。
    //   **这个数是数出来的,不是估的:**
    //   R6 · R0 · R1 · R1b · R2 · R3 · R7 · R7b · R7c · R7d · R4 · R5 · R5b ·
    //   R5c · R5d = 15 格,而下界取 14 是因为 R5c 在被扣下 0 行时是一条
    //   空真断言(它仍然会跑)—— 同 SEARCH-3 留那一格余量的理由,一字不改。
    assertPopulation('probe-search-results', '跑过的格子', results.length, 14)
}

let cleanedUp = false
async function cleanup() {
    if (cleanedUp) return
    cleanedUp = true
    if (accounts.length) {
        await runPlan()
        for (const a of accounts) {
            const left = await (await rest(`/rest/v1/user_roles?select=user_id&user_id=eq.${a.id}`)).json()
            if (Array.isArray(left) && left.length) cleanupFailures.push(`DANGLING GRANT for ${a.roleCode} ${a.id}`)
        }
    }
    try { if (server) process.kill(-server.pid, 'SIGKILL') } catch {}
    try { if (chrome) process.kill(-chrome.pid, 'SIGKILL') } catch {}
    try { release('scripts/probe-search-results.mjs') } catch {}
    if (cleanupFailures.length) {
        console.error('\n✗ 清理没做干净:')
        for (const c of cleanupFailures) console.error('   ' + c)
    }
    const bad = fail.length + cleanupFailures.length
    try {
        console.log(`\n${bad ? '✗' : '✓'} probe-search-results:${results.length} 格,${fail.length} 红,清理失败 ${cleanupFailures.length}`)
    } catch { /* stdout 断了 */ }
    process.exit(bad ? 1 : 0)
}

for (const sig of ['SIGINT', 'SIGTERM', 'SIGHUP', 'SIGPIPE']) process.on(sig, () => { cleanup() })
process.stdout.on('error', (e) => { if (e.code === 'EPIPE') cleanup() })
main().catch((e) => { fail.push('probe crashed: ' + e.message)
        try { console.error('\n✗ ' + e.message) } catch {} })
    .finally(cleanup)
