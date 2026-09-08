#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// SILENT-1(2026-09-08)· 委托书【点名】的两条路,真的走一遍
// ════════════════════════════════════════════════════════════════════════════
// probe-action-message 走的是"拒绝到不到得了屏幕"那 18 处。它没有覆盖
// 委托书另外点名的两条,而这两条各自证明【不同】的一件事:
//
//   S · 供应商状态的拒绝,在英文界面上是不是英文
//       —— 库里那句中文散文换成了 INVALID_STATUS_TRANSITION|<from>|<to>。
//       ★【怎么走到一次非法跳转】状态面板【只列合法的那几个】,所以点是点不出
//         非法跳转的。真实世界里它是这样发生的:**页面打开之后,状态在底下变了。**
//         本探针就照这条路驱动 —— 开页(draft,面板给出"提交审核"),
//         在底下把状态改成 approved,再按那个钮。approved→pending_review 非法。
//         这不是编出来的场景,这是唯一到得了它的场景。
//
//   T · 看板上一次被拒绝的拖拽,卡片回不回得去、说不说得出话
//       ★【而这一条要证明的恰恰是"数据库【没有】接管它"】★
//         tasks 的策略判的是【行】(can_edit_task):一个持 module.tasks.edit
//         却不在这张任务上的人,**今天仍然拿到零行静默** —— SILENT-1 的
//         语句级写闸看不见行,所以拦不住这一半。那一半仍由 ALERT-1 的
//         应用层兜着。这一格红了,意味着看板又开始把卡片留在数据库拒绝的那一列里。
//
// 【一次性账号,不碰任何人的授权】procurement 角色两样都有
// (module.suppliers.edit / module.tasks.edit),而它【不参与】任何既有任务 ——
// 于是 T 那一条的"看得见、改不动"是天然的,不需要制造。
//
// ★【必须能红,而且要能演示】★
//     PROBE_FAULT=blind      选择器全瞎     → 全红
//     PROBE_FAULT=no-banner  假装横幅没出现 → S3 / T3 红
//     PROBE_FAULT=no-revert  假装卡片没回去 → T4 红
// ════════════════════════════════════════════════════════════════════════════
import { spawn } from 'node:child_process'
import { readFileSync, existsSync } from 'node:fs'
import { join } from 'node:path'
import { createConnection } from 'node:net'
import { acquireOrExit, release } from './liveLock.mjs'
import { openPlan, planDelete, ephemeralGrantBody, runPlan, reapStalePlans, installExitHooks, ORDER } from './ephemeral.mjs'

const ROOT = new URL('..', import.meta.url).pathname
const PORT = 3205
const CDP_PORT = 9341
const CHROME = ['mac_arm-152.0.7977.75', 'mac_arm-152.0.7977.54']
    .map((v) => join(process.env.HOME, `.cache/puppeteer/chrome-headless-shell/${v}/chrome-headless-shell-mac-arm64/chrome-headless-shell`))
    .find(existsSync)
const FAULT = process.env.PROBE_FAULT || ''

const env = readFileSync(join(ROOT, '.env.local'), 'utf8')
const URL_ = env.match(/NEXT_PUBLIC_SUPABASE_URL=(\S+)/)[1]
const ANON = env.match(/NEXT_PUBLIC_SUPABASE_ANON_KEY=(\S+)/)[1]
const SERVICE = env.match(/SUPABASE_SERVICE_ROLE_KEY=(\S+)/)[1]
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const rest = (p, o = {}) => fetch(URL_ + p, { ...o, headers: {
    apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, 'Content-Type': 'application/json', ...(o.headers || {}) } })

const results = []; const fail = []
const probe = (id, ok, detail) => { results.push({ id, ok }); if (!ok) fail.push(`${id}: ${detail}`)
    console.log(`  ${ok ? '✓' : '✗'} ${id}  ${detail}`) }
const waitPort = (p, ms) => new Promise((res) => { const t0 = Date.now()
    ;(function tick() { const s = createConnection({ port: p, host: '127.0.0.1' })
        s.on('connect', () => { s.destroy(); res(true) })
        s.on('error', () => { s.destroy(); Date.now() - t0 > ms ? res(false) : setTimeout(tick, 300) }) })() })

let server, chrome, accountId
const killChildren = () => { try { if (chrome?.pid) process.kill(-chrome.pid) } catch {}
                             try { if (server?.pid) process.kill(-server.pid) } catch {} }
installExitHooks({ onFinish: () => { killChildren(); try { release() } catch {} } })

try {
    if (!CHROME) throw new Error('chrome-headless-shell 找不到')
    if (!existsSync(join(ROOT, '.next/BUILD_ID'))) throw new Error('.next/BUILD_ID 不在 —— 先 npm run build')
    acquireOrExit('probe-silent1-journeys', { ownExit: false })
    openPlan('scripts/probe-silent1-journeys.mjs')
    await reapStalePlans()

    // ── 一次性账号:procurement(suppliers.edit + tasks.edit,且不参与任何任务)──
    const email = `s1probe-${Date.now()}@test.local`
    const cu = await (await rest('/auth/v1/admin/users', { method: 'POST',
        body: JSON.stringify({ email, password: 's1-probe-1', email_confirm: true }) })).json()
    accountId = cu.id
    if (!accountId) throw new Error('账号建不出来: ' + JSON.stringify(cu).slice(0, 300))
    planDelete(`/rest/v1/user_roles?user_id=eq.${accountId}`, `revoke s1probe grant`, ORDER.GRANT)
    planDelete(`/auth/v1/admin/users/${accountId}`, `delete s1probe account`, ORDER.ACCOUNT)

    const roles = await (await rest('/rest/v1/roles?select=id,code&code=eq.procurement')).json()
    if (!roles?.[0]?.id) throw new Error('线上没有 procurement 角色')
    await rest('/rest/v1/user_roles', { method: 'POST', body: JSON.stringify(ephemeralGrantBody(accountId, roles[0].id)) })

    // ★ 断言前提:这个会话【真的】两样都持有 —— 否则整支探针在测一个错的前提。
    const perms = await (await rest(`/rest/v1/role_permissions?select=permission_code&role_id=eq.${roles[0].id}`)).json()
    const codes = new Set((perms || []).map((r) => r.permission_code))
    if (!(codes.has('module.suppliers.edit') && codes.has('module.tasks.edit')))
        throw new Error('procurement 不再同时持有 suppliers.edit 与 tasks.edit —— 前提没了')

    const sess = await (await fetch(URL_ + '/auth/v1/token?grant_type=password', { method: 'POST',
        headers: { apikey: ANON, 'Content-Type': 'application/json' },
        body: JSON.stringify({ email, password: 's1-probe-1' }) })).json()
    if (!sess?.access_token) throw new Error('登录失败')
    const cookieName = 'sb-' + URL_.split('//')[1].split('.')[0] + '-auth-token'
    const cookieValue = 'base64-' + Buffer.from(JSON.stringify(sess)).toString('base64url')

    // ── 一张一次性的供应商:不碰任何既有记录 ──────────────────────────────
    const supRes = await rest('/rest/v1/suppliers', { method: 'POST',
        headers: { Prefer: 'return=representation' },
        body: JSON.stringify({ legal_name: `ZZS1PROBE ${Date.now()}`, country: 'SG', status: 'draft',
                               counterparty_type: 'service_vendor' }) })
    const supRow = (await supRes.json())?.[0]
    if (!supRow?.id) throw new Error('一次性供应商建不出来: ' + JSON.stringify(supRow ?? null))
    const supId = supRow.id
    planDelete(`/rest/v1/suppliers?id=eq.${supId}`, `delete probe supplier ${supRow.code}`, ORDER.OTHER)

    // ── 一张【看得见、改不动】的团队任务 ──────────────────────────────────
    const tasksRows = await (await rest(
        '/rest/v1/tasks?select=id,code,title,status&task_type=eq.team&deleted_at=is.null&limit=5')).json()
    const target = (tasksRows || []).find((t) => t.status !== 'done') || (tasksRows || [])[0]
    if (!target?.id) throw new Error('没有团队任务 —— T 组无从驱动')

    server = spawn('npx', ['next', 'start', '-p', String(PORT)], { cwd: ROOT, detached: true, stdio: ['ignore', 'pipe', 'pipe'] })
    server.stderr.on('data', () => {})
    if (!await waitPort(PORT, 90000)) throw new Error(`next start 没在 :${PORT} 起来`)
    const origin = `http://localhost:${PORT}`

    chrome = spawn(CHROME, [`--remote-debugging-port=${CDP_PORT}`, '--headless', '--disable-gpu',
        '--no-sandbox', '--window-size=1440,1000'], { detached: true, stdio: ['ignore', 'pipe', 'pipe'] })
    if (!await waitPort(CDP_PORT, 30000)) throw new Error('chrome 没起来')
    await sleep(400)
    const { webSocketDebuggerUrl } = await (await fetch(`http://127.0.0.1:${CDP_PORT}/json/version`)).json()
    // 最小 CDP 客户端 —— 与 probe-action-message 逐字同法(Node 内建 WebSocket,不多一个依赖)
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
    const s = (m, p) => send(m, p, sessionId)
    await s('Page.enable'); await s('Runtime.enable'); await s('Network.enable')
    await s('Emulation.setDeviceMetricsOverride', { width: 1440, height: 1000, deviceScaleFactor: 1, mobile: false })
    await s('Network.setCookies', { cookies: [{ name: cookieName, value: cookieValue,
        domain: 'localhost', path: '/', httpOnly: false, secure: false }] })
    const evalJs = async (expr) => (await s('Runtime.evaluate',
        { expression: expr, awaitPromise: true, returnByValue: true }))?.result?.value
    const goto = async (path) => { await s('Page.navigate', { url: origin + path }); await sleep(3000)
        for (let i = 0; i < 40; i++) { if (await evalJs('document.readyState === "complete"')) break; await sleep(250) }
        await sleep(1200) }
    const BANNER = FAULT === 'blind' ? '#nope-nope' : '[data-action-message]'
    const bannerText = () => evalJs(
        `(() => { const e = document.querySelector('${BANNER}'); return e ? e.innerText.replace(/\\s+/g,' ').trim() : '' })()`)

    // ═══════════════════ S · 供应商状态的拒绝,是不是英文 ═══════════════════
    console.log(`\n-- S /suppliers/[id]/edit 状态面板 · 非法跳转(页面打开后状态在底下变了) --`)
    await goto(`/suppliers/${supId}/edit`)
    const hydrated = await evalJs('!!document.querySelector("form")')
    probe('S0 水合', !!hydrated, hydrated ? '页面水合完成' : '没水合')
    probe('S1 反臂', (await bannerText()) === '', '动作之前:没有横幅')

    // 找那个"提交审核"钮(draft 唯一的合法去处之一)
    const btnSel = `Array.from(document.querySelectorAll('button')).find(b => /Submit for Review/i.test(b.innerText))`
    const haveBtn = await evalJs(`!!(${btnSel})`)
    probe('S2 面板给出了合法去处', !!haveBtn, haveBtn ? '"Submit for Review" 在' : '找不到那个钮')

    // ★ 在底下把状态改掉 —— 这是唯一到得了非法跳转的那条路。
    //   ☞【底下那一步自己也得是【合法】的跳转】第一版在这里写了 draft → approved,
    //     而那本身就是一次非法跳转 —— **同一支触发器把它也拒了**(service_role
    //     绕得开 RLS,绕不开触发器)。于是供应商还停在 draft,接下来那一按就成了
    //     一次【合法】跳转,横幅当然不出现。判据当时报的是"横幅没出现",
    //     而真相是"这一格根本没有被驱动到"。
    //   draft → archived 合法;而 archived 之后【只能】回 draft,
    //   所以再按"提交审核"(pending_review)就是一次真的非法跳转。
    const under = await rest(`/rest/v1/suppliers?id=eq.${supId}`, { method: 'PATCH',
        headers: { Prefer: 'return=representation' }, body: JSON.stringify({ status: 'archived' }) })
    const underRow = (await under.json())?.[0]
    probe('S2c 底下那一步真的落地了', underRow?.status === 'archived',
        `状态现在是 ${underRow?.status ?? '(没回行)'} —— 期望 archived`)
    // 确认钮走的是 confirm 对话框
    await evalJs(`(${btnSel})?.click(); true`)
    // 【等对话框真的出现,而不是猜一个睡眠】触发钮与确认钮的【文案是同一句】
    // (confirmLabel 就是 "Submit for Review"),所以只能按 data-confirm-accept 认,
    // 而且必须等它挂上去 —— 一次猜出来的 sleep 会把"还没开"读成"找不到"。
    // ★★【这条路上【没有】确认对话框,而这是量出来的,不是猜的】★★
    //   StatusPanel 只给【破坏性】的跳转套 ConfirmButton;draft → pending_review
    //   不是破坏性的,所以它是一个普通钮:按下去动作【当场就发出去了】。
    //   第一版在这里等一个对话框,等不到就报红 —— 那是判据在等一个这条路上
    //   根本不存在的东西。实测确认:按下之后钮的面变成「Processing… → Pending Review」。
    let fired = false
    for (let i = 0; i < 40; i++) {
        fired = await evalJs(`/Processing/i.test(document.body.innerText)`)
                || (await bannerText()).length > 0
        if (fired) break
        await sleep(200)
    }
    probe('S2b 动作真的发出去了', !!fired, fired ? '钮进入 Processing…(这条路没有确认对话框)'
                                                : '★ 按下之后什么都没发生')
    // 【等横幅,不猜一个睡眠】今天这台机器到库的往返实测 3–4 秒,
    // 一个拍脑袋的 sleep 会把"还在路上"读成"没出现"。
    let txt = ''
    for (let i = 0; i < 60; i++) {
        txt = await bannerText()
        if (txt) break
        await sleep(500)
    }
    if (FAULT === 'no-banner') txt = ''
    probe('S3 拒绝到达屏幕', txt.length > 0, txt ? `正文:${txt.slice(0, 120)}` : '横幅没出现')
    const hasCjk = /[一-鿿]/.test(txt)
    // 【没有横幅时不许说"没有 CJK"】那句话读起来像通过,而实际上这一格
    // 【什么都没看见】。一条说不出自己看见了什么的判据,会让人以为它看过了。
    probe('S4 ★ 英文界面上是英文', txt.length > 0 && !hasCjk,
        txt.length === 0 ? '★ 横幅根本没出现 —— 这一格【什么都没验到】,不是"没有中文"'
        : hasCjk ? `★ 屏幕上出现了中文:${txt.slice(0, 90)}`
        : '正文里没有一个 CJK 字符')
    const namesStates = /Archived/i.test(txt) && /Pending Review/i.test(txt)
    probe('S5 说得出是哪两个状态', namesStates,
        namesStates ? '点名 "Archived" → "Pending Review"(用的是状态面板那套标签,不是存储值)'
                    : `没有同时点名两个状态标签:${txt.slice(0, 110)}`)
    const rawCode = /INVALID_STATUS_TRANSITION/.test(txt)
    probe('S6 不是一串机器码', !rawCode, rawCode ? '★ 机器码原样印在屏幕上' : '标题与正文都是人话')

    // ═══════════════════ T · 看板:被拒绝的拖拽 ═══════════════════
    console.log(`\n-- T /tools/tasks 看板 · 一次改不动的拖拽(行级拒绝,库【不】抛,应用层兜着) --`)
    await goto('/tools/tasks')
    const cardSel = `document.querySelector('[data-task-id="${target.id}"]')`
    let card = await evalJs(`!!${cardSel}`)
    if (!card) {
        // 卡片上没有 data-task-id 就按标题找,并把这件事说出来
        const byTitle = await evalJs(`!!Array.from(document.querySelectorAll('*'))
            .find(e => e.children.length === 0 && e.innerText === ${JSON.stringify(target.title)})`)
        probe('T1 找得到那张卡', !!byTitle, byTitle ? `按标题找到 "${target.title}"(卡片没有 data-task-id)`
            : `★ 看板上找不到 "${target.title}" —— T 组【无从驱动】,这不是跳过`)
    } else {
        probe('T1 找得到那张卡', true, `data-task-id 命中 "${target.title}"`)
    }
    probe('T2 反臂', (await bannerText()) === '', '拖拽之前:没有横幅')

    // 用真的指针事件驱动 dnd-kit(PointerSensor,activationConstraint distance 5)
    // ★【看板的列【没有】data 标记 —— 它们只由 dnd-kit 的 droppable ref 认得】★
    //   所以这里按【直属 <h2> 子元素】认列(每一列的结构就是 div > h2 + 卡片区),
    //   而不是按 data-column-id 找一个不存在的东西。
    //   ☞ 第一版正是按 data-column-id 找的,于是报 NO_COLUMN ——
    //     那不是产品的毛病,是判据在找一个树上没有的记号。
    const dragged = await evalJs(`(async () => {
        const cols = Array.from(document.querySelectorAll('div'))
            .filter(d => d.querySelector(':scope > h2'))
        if (cols.length < 2) return 'NO_COLUMN:' + cols.length
        const el = Array.from(document.querySelectorAll('*')).find(e =>
            e.children.length === 0 && e.innerText && e.innerText.trim() === ${JSON.stringify(target.title)})
        if (!el) return 'NO_CARD'
        const card = el.closest('div[class*="rounded"]') || el
        const mine = cols.find(c => c.contains(el))
        const dest = cols.find(c => c !== mine)
        if (!dest) return 'NO_DEST'
        const from = card.getBoundingClientRect(), to = dest.getBoundingClientRect()
        const pe = (type, x, y, node) => node.dispatchEvent(new PointerEvent(type, {
            bubbles: true, cancelable: true, clientX: x, clientY: y,
            pointerId: 1, pointerType: 'mouse', isPrimary: true, button: 0, buttons: 1 }))
        pe('pointerdown', from.x + 20, from.y + 12, card)
        await new Promise(r => setTimeout(r, 80))
        pe('pointermove', from.x + 60, from.y + 14, document)
        await new Promise(r => setTimeout(r, 80))
        pe('pointermove', to.x + to.width / 2, to.y + 80, document)
        await new Promise(r => setTimeout(r, 150))
        pe('pointerup', to.x + to.width / 2, to.y + 80, document)
        return 'DRAGGED:' + (dest.querySelector(':scope > h2')?.innerText || '?').trim()
    })()`)
    await sleep(2000)
    probe('T3a 拖拽真的发出去了', String(dragged).startsWith('DRAGGED'), String(dragged))
    let ttxt = ''
    for (let i = 0; i < 60; i++) { ttxt = await bannerText(); if (ttxt) break; await sleep(500) }
    if (FAULT === 'no-banner') ttxt = ''
    probe('T3 拒绝到达屏幕', ttxt.length > 0, ttxt ? `正文:${ttxt.slice(0, 130)}` : '★ 横幅没出现 —— 屏幕对一次被拒绝的移动一言不发')

    // ★ 卡片必须回到原来那一列 —— 库里状态没变,屏幕就不许显示它变了
    const after = await (await rest(`/rest/v1/tasks?select=status&id=eq.${target.id}`)).json()
    const dbUnchanged = after?.[0]?.status === target.status
    probe('T4a 库里状态没变', dbUnchanged, `库=${after?.[0]?.status} 期望=${target.status}`)
    // 回滚也要【等】—— 它发生在服务端动作回来之后。
    let onScreen = null
    for (let i = 0; i < 40; i++) {
        onScreen = await evalJs(`(() => {
        // 按【哪一列的整段文字里有这个标题】认 —— 找叶子节点会被卡片内部结构的
        // 任何一次变化弄丢(重渲染之后标题未必还是某个叶子的全部文字)。
        const col = Array.from(document.querySelectorAll('div'))
            .filter(d => d.querySelector(':scope > h2'))
            .find(c => c.innerText.includes(${JSON.stringify(target.title)}))
        return col ? (col.querySelector(':scope > h2').innerText.split('(')[0].trim()) : null })()`)
        if (onScreen) break
        await sleep(500)
    }
    if (FAULT === 'no-revert') onScreen = '__moved__'
    // 列头写的是【标签】(To Do / In Progress / Done),不是存储值,所以比标签。
    const LABEL = { todo: 'To Do', in_progress: 'In Progress', blocked: 'Blocked', done: 'Done' }
    const want = LABEL[target.status] ?? target.status
    const reverted = onScreen === null ? null : onScreen === want
    probe('T4 ★ 卡片回到了原来那一列', reverted === true,
        reverted === null ? '★ 拖拽之后在看板上找不到那张卡了' : `屏幕列="${onScreen}" 期望="${want}"`)

    console.log(`\n── 小结 ──\n  ${results.filter(r => r.ok).length}/${results.length} 格通过`)
    if (fail.length) { console.log('\n红的格子:'); fail.forEach(f => console.log('  ✗ ' + f)) }
    killChildren(); runPlan(); release()
    if (fail.length) { console.log('\nEXIT 1'); process.exitCode = 1 }
    else console.log('\nEXIT 0 — 两条点名的路都被机器走过了')
} catch (e) {
    console.error('✗ 探针自身出错:', e?.message || e)
    killChildren(); try { runPlan() } catch {} try { release() } catch {}
    process.exitCode = 2
}
