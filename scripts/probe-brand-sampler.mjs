#!/usr/bin/env node
// scripts/probe-brand-sampler.mjs
// ════════════════════════════════════════════════════════════════════════════
// SEARCH-1 · 停止条件 (e) —— `/brand-sampler` 的【逐元素】普查与比对
// ════════════════════════════════════════════════════════════════════════════
//
// 【为什么它进仓库 —— 这是第六次写它,而前五次都没有留下来】
//   BTN-SIZE-1 §8.4 记着:round 1 · FONT-1 · INPUT-3 · POLISH-1 r3 · BTN-SIZE-1,
//   **五刀各写一遍 `/brand-sampler` 的逐元素普查,五次都是一次性脚本**。
//   而停止条件 (e)(「取样页一个成员都不许变」)是**每一刀都要跑的**。
//   ☞ 一件每刀都要做、而且每刀都重写一遍的事,该被写成机制。
//   ⚠ 另外 `survey-controls.mjs` 的 `walk()` 在目录这一层就跳过 `brand-sampler`,
//     所以那支普查**结构上看不见它**;`--urls=/brand-sampler` 只补回整页那几个标量
//     (`totalElements` / `tableCount` / `docScrollW`)与控件/表那两族成员,
//     **不是 916 个元素逐个比**。这一支补的正是那一格。
//
// ════════════════════════════════════════════════════════════════════════════
// ★★【身份用【签名】,不用【路径】—— 而这是被这一刀自己的改动逼出来的】★★
// ════════════════════════════════════════════════════════════════════════════
//   直觉的做法是给每个元素算一条 DOM 路径(`body > div:nth-child(3) > …`)。
//   ★ 而 SEARCH-1 在根布局里加了一层 `<div class="contents">`(AppChrome)——
//     于是 `<body>` 的直接子元素整批换了序号,**取样页自己的内容一个像素都没动,
//     而它每一个元素的路径都变了**。一份按路径比对的读数会报出 900 多处"变动"。
//   ☞ 所以身份是**签名**:标签 + class 串 + 自己那一层的文字 + 十项计算值。
//     比的是【多重集】:B 里多出来的、A 里少掉的,各自逐条列出来。
//     一个位置挪了而签名一字不变的元素,读作"没变" —— 那正是 (e) 要问的问题。
//   ⚠ 代价照直说:一个元素的字号变了,会读成「少一个 + 多一个」,不是「一个变了」。
//     **它抓得住,只是措辞是两条。** 这个取舍写在这里,免得下一个人以为它漏了。
//
// ── 分账:顶栏里的 vs 顶栏外的 ──────────────────────────────────────────────
//   ★ 顶栏在【每一页】上,取样页也不例外。SEARCH-1 换掉了顶栏那一格搜索框
//     (`<details>/<summary>` → `<div>/<button>`),所以**取样页的元素总数必然会动**。
//   ☞ (e) 照字面读会与委托书自己的授权矛盾(停止条件 (f) 明说顶栏会动,要量它)。
//     BTN-SIZE-1 §9.2 为同一种矛盾写过判词:**「该写断言,不该写措辞」**。
//     所以这一支把成员分成两堆,分开报:
//       · `nav`  —— 住在 `<header>` 里的。**允许动**,由 (f) 的探针负责量它的盒子;
//       · `page` —— 其余的,**取样页自己那些东西**。★ 这一堆的差额必须是 0。
//
// 用法:
//   node scripts/probe-brand-sampler.mjs --out=<文件.json>
//   node scripts/probe-brand-sampler.mjs --compare --a=<改前.json> --b=<改后.json>
// 退出码:0 干净 · 1 取样页自己变了 · 2 量具自己坏了
//
// ════════════════════════════════════════════════════════════════════════════
// 【瞄准 · AIM】
//   我读的是      :chrome-headless-shell 通过 CDP 读 `/brand-sampler` 渲染后的
//                   **每一个元素**(`document.querySelectorAll('*')`),两个视口,
//                   取它的标签 / class / 自己那一层的文字 / 十项 `getComputedStyle`
//                   / 渲染盒子。
//   我声称管的是   :「取样页**自己**那些成员,改前改后逐个相同」。
//   两者不同之处   :★ **我只量首屏,而且只量这一页。** 点开之后才出现的东西
//                   (下拉、对话框、展开行)我看不见 —— 与 `survey-phone.mjs`
//                   写下的那条盲区逐字同一条。
//                   ★ **我不判"好不好看"**:我只比字节。
//                   ★ 我的"没变"是**签名的多重集没变**,不是"每个元素还在原位"
//                   —— 上面那一段说了为什么,以及它的代价。
import { readFileSync, writeFileSync, existsSync } from 'node:fs'
import { join } from 'node:path'
import { spawn, execSync } from 'node:child_process'
import { createConnection } from 'node:net'
import { assertPopulation, assertPinned } from './lib/selfproof.mjs'

const SELF = 'probe-brand-sampler'
const arg = (k) => (process.argv.find((a) => a.startsWith(k + '=')) || '').split('=')[1]

// ════════════════════════════════════════════════════════════════════════════
// §COMPARE —— 先跑,它不需要浏览器、不需要数据库、不需要锁。
// ════════════════════════════════════════════════════════════════════════════
if (process.argv.includes('--compare')) {
    const fa = arg('--a'), fb = arg('--b')
    if (!fa || !fb) { console.error('compare 需要 --a=FILE --b=FILE'); process.exit(2) }
    const A = JSON.parse(readFileSync(fa, 'utf8'))
    const B = JSON.parse(readFileSync(fb, 'utf8'))
    const viewports = [...new Set([...Object.keys(A.viewports), ...Object.keys(B.viewports)])]
    assertPopulation(SELF, '两份读数里的视口', viewports.length, 2)

    let problems = 0
    let compared = 0
    let fieldComparisons = 0
    for (const vp of viewports) {
        const a = A.viewports[vp], b = B.viewports[vp]
        if (!a || !b) { console.error(`✗ 视口 ${vp} 只有一侧有读数 —— 这一次比对不作数。`); process.exit(2) }

        // ★【分母,而且【印出来】】★ AGENTS.md:一个数写进报告时,分母要跟着它。
        console.log(`\n── ${vp} ──`)
        console.log(`   渲染成员总数:改前 ${a.total} · 改后 ${b.total}` +
            `  (连不渲染的一起数:${a.totalIncludingNonRendered ?? '—'} → ${b.totalIncludingNonRendered ?? '—'})`)
        console.log(`   其中顶栏里:改前 ${a.members.filter((m) => m.nav).length} · 改后 ${b.members.filter((m) => m.nav).length}`)

        // ════════════════════════════════════════════════════════════════
        // ★★★【那个 916 是【另一支量具】的数,而它不是这一支的分母】★★★
        // ════════════════════════════════════════════════════════════════
        //   委托书写着「916 members per viewport」,SEARCH-1 开工时也实测到 916
        //   —— **两个 916 都是真的,而它们都来自 `survey-controls.mjs`**,
        //   那一支跑在 **`next dev`** 上。**这一支跑在 `next start` 上**,
        //   同一页同一视口实测 **903**。
        //   ☞ 差的 13 个是 `next dev` 自己注入的开发期元素,**不是取样页的内容**。
        //   ★★ 把 916 写成这一支的下界,就是 AGENTS.md 那条
        //     「一个数被抄走时,它的【分母】掉了」—— 掉的这一次是**它跑在哪个服务器上**。
        //     实测代价:第一版照抄 916,这一支当场 EXIT 2 报「实测 903,而 916 是下界」
        //     —— **一个正确的读数,被一个借来的门槛判成了故障。**
        //
        // ☞ 所以下界是【结构性】的:两侧都得真的量到东西(非零),而且
        //   **两侧必须是同一支量具的两次读数** —— 判据是它们的总数量级对得上。
        //   真正的判据是下面那个**逐成员比对**,不是一个绝对数。
        //   ★ 而两个数【并排报出来,各带它的量具与服务器】,见上面那两行。
        for (const [side, doc] of [['改前', a], ['改后', b]]) {
            if (!doc.total) {
                console.error(`✗ ${vp} ${side}:成员 0 个 —— 这一次没有测量,不是"取样页空了"。`)
                process.exit(2)
            }
        }
        // ★ 两侧的量级必须对得上:差出一成,那不是"变了",那是两次跑的不是同一件事
        //   (换了服务器 / 换了视口 / 页面没渲染完)。**那时逐成员比对没有意义。**
        if (Math.abs(a.total - b.total) > Math.max(a.total, b.total) * 0.1) {
            console.error(`✗ ${vp}:两侧成员总数差了 ${Math.abs(a.total - b.total)} 个(${a.total} vs ${b.total},超过一成)。`)
            console.error('  这多半不是"取样页变了",是两次跑的不是同一件事 —— 先查服务器/视口/渲染时机。')
            process.exit(2)
        }

        for (const group of ['page', 'nav']) {
            const pick = (doc) => doc.members.filter((m) => (group === 'nav' ? m.nav : !m.nav))
            const ma = pick(a), mb = pick(b)
            const count = (arr) => {
                const m = new Map()
                for (const x of arr) m.set(x.sig, (m.get(x.sig) ?? 0) + 1)
                return m
            }
            const ca = count(ma), cb = count(mb)
            const keys = [...new Set([...ca.keys(), ...cb.keys()])]
            const added = [], removed = []
            for (const k of keys) {
                fieldComparisons++
                const na = ca.get(k) ?? 0, nb = cb.get(k) ?? 0
                if (nb > na) added.push({ k, n: nb - na })
                if (na > nb) removed.push({ k, n: na - nb })
            }
            compared += ma.length + mb.length
            const delta = mb.length - ma.length
            const label = group === 'nav' ? '顶栏里(允许动 —— 由 (f) 的探针量它的盒子)' : '★ 取样页自己(必须为 0)'
            console.log(`   ${label}:${ma.length} → ${mb.length}(${delta >= 0 ? '+' : ''}${delta}) · 多出签名 ${added.length} 种 · 少掉签名 ${removed.length} 种`)
            for (const x of added.slice(0, 8)) console.log(`      + ×${x.n}  ${x.k.slice(0, 150)}`)
            for (const x of removed.slice(0, 8)) console.log(`      - ×${x.n}  ${x.k.slice(0, 150)}`)
            if (group === 'page' && (added.length || removed.length)) problems += added.length + removed.length
        }
    }

    // ★★ 覆盖断言:比过的成员数与字段比较次数都不许是 0 ★★
    assertPopulation(SELF, '比过的成员', compared)
    assertPopulation(SELF, '签名比较次数', fieldComparisons)

    console.log('')
    if (problems === 0) {
        console.log(`✓ (e) 取样页自己【一个成员都没变】。比过成员 ${compared} 个 · 签名比较 ${fieldComparisons} 次。`)
        process.exit(0)
    }
    console.error(`✗ (e) 取样页自己变了:${problems} 处签名差异(见上面逐条)。`)
    process.exit(1)
}

// ════════════════════════════════════════════════════════════════════════════
// §MEASURE
// ════════════════════════════════════════════════════════════════════════════
const { acquireOrExit, release } = await import('./liveLock.mjs')
const { openPlan, planDelete, ephemeralGrantBody, runPlan, reapStalePlans, ORDER } = await import('./ephemeral.mjs')

const ROOT = new URL('..', import.meta.url).pathname
const PORT = 3204                 // 3198 survey · 3199 冒烟 · 3201 avatar · 3202/3203 两支 probe
const CDP_PORT = 9340
const CHROME = join(process.env.HOME, '.cache/puppeteer/chrome-headless-shell/mac_arm-152.0.7977.54/chrome-headless-shell-mac-arm64/chrome-headless-shell')
const OUT = arg('--out') || '/tmp/brand-sampler-census.json'

const env = readFileSync(join(ROOT, '.env.local'), 'utf8')
const URL_ = env.match(/NEXT_PUBLIC_SUPABASE_URL=(\S+)/)[1]
const ANON = env.match(/NEXT_PUBLIC_SUPABASE_ANON_KEY=(\S+)/)[1]
const SERVICE = env.match(/SUPABASE_SERVICE_ROLE_KEY=(\S+)/)[1]
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const rest = (p, o = {}) => fetch(URL_ + p, { ...o, headers: {
    apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, 'Content-Type': 'application/json', ...(o.headers || {}) } })

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

// ════════════════════════════════════════════════════════════════════════════
// ★★【两条边界,而它们是被【第一次跑出来的读数】逼出来的,不是事先想到的】★★
// ════════════════════════════════════════════════════════════════════════════
//
// ① **不渲染的标签不算成员。** 第一次跑,取样页那一堆报出三处差异,
//    而三处全是 script 标签 —— 内容是 RSC 载荷(self.__next_f.push(…)),
//    ★ 而差的只是【块号】:2c→2d · 29→2a · 2f→30。
//    ☞ 根布局多了一个客户端组件(AppChrome),载荷就多一项,后面每一块的号
//      整体挪一位。**任何一次动根布局的改动都会这样,包括 Tim 点名要的那一条。**
//    ☞ 把它们数进"取样页变了",是拿一个【框架序列化的实现细节】去回答
//      「这一页渲染出来的东西变了吗」。
//    ⚠ **代价照直说:这支探针从此看不见只活在 script / style / meta 里的变化。**
//      它看的是【渲染出来的东西】,而那正是 (e) 问的那件事。
//
// ② **AppChrome 那个包装层算【顶栏那一堆】,不算取样页。** 它是
//    display:contents 的 0×0 盒子,是应用外壳的实现细节。
//    ⚠ 只认**它自己**(hasAttribute),**不认它的后代** —— 认后代会把面包屑
//      与告知区在改后挪进另一堆,而改前它们在这一堆里,于是凭空造出一批差异。
//
// ★【顺带一条本刀当场付过账的:这段话【不能】写在下面那个模板字符串里面】★
//   它里面有反引号,而模板字符串就是用反引号收尾的 —— 第一版写进去,
//   Node 当场 SyntaxError。AGENTS.md 记着这一族(引号/转义把一段东西变成了别的)。
// 十项计算值 + 渲染盒子 + 自己那一层的文字。**逐元素**,一个不漏。
const CENSUS = `(() => {
    const round = (n) => Math.round(n * 100) / 100
    const KEYS = ['fontSize','fontWeight','lineHeight','color','backgroundColor',
                  'paddingTop','paddingLeft','borderTopWidth','borderTopColor','borderTopLeftRadius']
    /** 自己那一层的文字 —— 不含后代,否则父元素的签名会把整页都装进去。 */
    const ownText = (el) => {
        let s = ''
        for (const n of el.childNodes) if (n.nodeType === 3) s += n.nodeValue
        return s.replace(/\\s+/g, ' ').trim().slice(0, 40)
    }
    const NOT_RENDERED = new Set(['SCRIPT', 'STYLE', 'LINK', 'META', 'TITLE', 'HEAD', 'BASE', 'NOSCRIPT'])
    const allNodes = [...document.querySelectorAll('*')]
    const all = allNodes.filter((el) => !NOT_RENDERED.has(el.tagName))
    const header = document.querySelector('header')
    const members = all.map((el) => {
        const cs = getComputedStyle(el)
        const r = el.getBoundingClientRect()
        const parts = [
            el.tagName.toLowerCase(),
            (el.getAttribute('class') || '').slice(0, 200),
            ownText(el),
            round(r.width) + 'x' + round(r.height),
            ...KEYS.map((k) => cs[k]),
        ]
        return {
            sig: parts.join('|'),
            nav: !!(header && header.contains(el)) || el.hasAttribute('data-app-chrome'),
        }
    })
    return {
        total: all.length,
        /** 连不渲染的标签一起数 —— 与 survey-controls 的 totalElements 同口径,好对账。 */
        totalIncludingNonRendered: allNodes.length,
        docScrollW: document.documentElement.scrollWidth,
        docClientW: document.documentElement.clientWidth,
        tableCount: document.querySelectorAll('table').length,
        members,
    }
})()`

async function main() {
    acquireOrExit('scripts/probe-brand-sampler.mjs', { ownExit: false })
    openPlan('scripts/probe-brand-sampler.mjs')
    await reapStalePlans()
    if (!existsSync(join(ROOT, '.next/BUILD_ID')))
        throw new Error('.next/BUILD_ID 不在 —— 这一支要跑在【生产构建】上。先 npm run build。')
    // ★★ SEARCH-3:把它读到的 `.next/BUILD_ID` 印出来 —— SEARCH-1 §6 末尾那一次
    //   「对着旧构建量出一个干净的零」就是这么发生的(`git stash pop` 之后没重建)。
    //   一份读数必须说得出【它量的是哪一次构建】。
    console.log(`· .next/BUILD_ID = ${readFileSync(join(ROOT, '.next/BUILD_ID'), 'utf8').trim()}`)
    if (!existsSync(CHROME)) throw new Error('chrome-headless-shell not at ' + CHROME)
    try { execSync(`lsof -ti tcp:${PORT} | xargs -r kill -9`, { stdio: 'ignore' }) } catch {}

    const email = `sampler-${Date.now()}@test.local`
    const cu = await (await rest('/auth/v1/admin/users', { method: 'POST',
        body: JSON.stringify({ email, password: 'sampler-probe-1', email_confirm: true }) })).json()
    accountId = cu.id
    if (!accountId) throw new Error('账号建不出来: ' + JSON.stringify(cu).slice(0, 300))
    planDelete(`/rest/v1/user_roles?user_id=eq.${accountId}`, `revoke grant ${accountId}`, ORDER.GRANT)
    planDelete(`/auth/v1/admin/users/${accountId}`, `delete account ${accountId}`, ORDER.ACCOUNT)
    const roles = await (await rest('/rest/v1/roles?select=id&code=eq.admin')).json()
    await rest('/rest/v1/user_roles', { method: 'POST',
        body: JSON.stringify(ephemeralGrantBody(accountId, roles[0].id)) })
    const sess = await (await fetch(URL_ + '/auth/v1/token?grant_type=password', { method: 'POST',
        headers: { apikey: ANON, 'Content-Type': 'application/json' },
        body: JSON.stringify({ email, password: 'sampler-probe-1' }) })).json()
    if (!sess?.access_token) throw new Error('登录失败: ' + JSON.stringify(sess).slice(0, 200))
    const cookieName = 'sb-' + URL_.split('//')[1].split('.')[0] + '-auth-token'
    const cookieValue = 'base64-' + Buffer.from(JSON.stringify(sess)).toString('base64url')

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
    await S('Network.setCookies', { cookies: [{ name: cookieName, value: cookieValue,
        domain: 'localhost', path: '/', httpOnly: false, secure: false }] })

    const evalJs = async (expr) => {
        const r = await S('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true })
        if (r.exceptionDetails) throw new Error(expr.slice(0, 60) + ' → ' + JSON.stringify(r.exceptionDetails).slice(0, 300))
        return r.result.value
    }

    const out = { at: new Date().toISOString(), viewports: {} }
    for (const [name, w] of [['desktop', 1440], ['phone', 390]]) {
        await S('Emulation.setDeviceMetricsOverride', { width: w, height: 900, deviceScaleFactor: 1, mobile: w < 768 })
        await S('Page.navigate', { url: `${origin}/brand-sampler` })
        // 等水合收尾 —— 与另外两支探针同源的判据。
        const t0 = Date.now()
        for (;;) {
            const ok = await evalJs(`(() => { const b = document.querySelector('[data-nav="avatar-menu"] button'); return !!b && Object.keys(b).some(k => k.startsWith('__react')) })()`)
            if (ok) break
            if (Date.now() - t0 > 25000) throw new Error(`${name}:水合没有收尾`)
            await sleep(200)
        }
        await sleep(300)
        const c = await evalJs(CENSUS)
        // ★ 双向钉住:逐元素走出来的成员数,对上一条不经过那次 .map 的独立计数。
        // ★ 双向钉住:逐元素走出来的成员数,对上一条【不经过那次 filter+map】的独立计数。
        //   ⚠ 两条路必须数【同一个总体】—— 第一版拿 querySelectorAll('*') 去对
        //   一个已经滤掉 script/style 的数,于是它报「判据漏抓了 43 个」。
        //   **那条断言没有错,是我喂给它两个不同的总体。** 现在两边都排除同一族标签,
        //   而第二条路走的是 CSS 选择器(`:not(script)…`),不是同一段 JS 的 filter。
        const independent = await evalJs(
            `document.querySelectorAll('*:not(script):not(style):not(link):not(meta):not(title):not(head):not(base):not(noscript)').length`)
        assertPinned(SELF, `${name} 的渲染成员`, c.members.length, independent,
            '逐元素那次 filter+map 与一条走 CSS 选择器的独立计数必须给出同一个数。')
        // ★ 下界【不借别的量具的数】—— 见 §COMPARE 里那一整段。这里只问"量到了吗"。
        assertPopulation(SELF, `${name} 的成员`, c.members.length)
        out.viewports[name] = c
        console.log(`· ${name} @${w}: 渲染成员 ${c.total} 个(顶栏那一堆 ${c.members.filter((m) => m.nav).length})· ` +
            `连不渲染的一起数 ${c.totalIncludingNonRendered} 个 · 表 ${c.tableCount} 张 · docScrollW ${c.docScrollW}`)
    }
    writeFileSync(OUT, JSON.stringify(out))
    console.log(`wrote ${OUT}`)
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
    try { release('scripts/probe-brand-sampler.mjs') } catch {}
    if (cleanupFailures.length) {
        console.error('\n✗ 清理没做干净:')
        for (const c of cleanupFailures) console.error('   ' + c)
    }
    process.exit(failed || cleanupFailures.length ? 1 : 0)
}
let failed = 0
for (const sig of ['SIGINT', 'SIGTERM', 'SIGHUP', 'SIGPIPE']) process.on(sig, () => { cleanup() })
process.stdout.on('error', (e) => { if (e.code === 'EPIPE') cleanup() })
main().catch((e) => { failed = 1; try { console.error('\n✗ ' + e.message) } catch {} }).finally(cleanup)
