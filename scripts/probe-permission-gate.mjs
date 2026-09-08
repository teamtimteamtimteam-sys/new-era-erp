#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// DBLOCK-1(2026-09-08)· 【一个按不下去的控件,真的在屏幕上说出为什么了吗】
// ════════════════════════════════════════════════════════════════════════════
// SILENT-1 的教训写在它自己的提交信息里:**库上 133/133 全绿,而五张屏仍然坏着**,
// 只有把界面走一遍才找得到。所以本刀的判词【不许】只由 fixture 出。
//
// ★★【两条臂,而第二条才是难的那条】★★
//   A 臂(auditor:view 全有、edit 全无)—— 控件【看得见、按不动、旁边有话】。
//   B 臂(finance:持 module.finance.edit / module.purchasing.edit)——
//     **同一批控件照常能按**。
//   一支只跑 A 臂的探针,对着一个【把所有按钮都禁掉】的实现也会全绿 ——
//   那正是"用弄坏来修好"。B 臂就是抓这个的。
//
// ★★【C 臂:没有任何一个控件对任何人消失】★★
//   两条臂各自把整页的按钮标签收成一个多重集合,然后比。
//   本刀之前有 20 处写的是 `{canEdit && <button>}` —— 那种实现会让
//   A 臂的集合【小一截】。C 臂就是钉住"不许藏"这条裁定的那一格。
//
// ★【本脚本必须能红,而且要能演示】★
//     PROBE_FAULT=blind        选择器全瞎    → 全红,并且说"我瞎了"
//     PROBE_FAULT=no-reason    假装理由不在  → A3 红
//     PROBE_FAULT=a-operable   假装 A 臂能按 → A2 红
//     PROBE_FAULT=hide         假装 A 臂少一个钮 → C1 红
//
// 用法:npm run build && node scripts/probe-permission-gate.mjs
// ════════════════════════════════════════════════════════════════════════════
import { spawn } from 'node:child_process'
import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { createConnection } from 'node:net'
import { acquireOrExit, release } from './liveLock.mjs'
import { openPlan, planDelete, ephemeralGrantBody, reapStalePlans, installExitHooks, ORDER } from './ephemeral.mjs'

const ROOT = new URL('..', import.meta.url).pathname
const PORT = 3205, CDP_PORT = 9341
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

const results = [], fail = []
const probe = (id, ok, detail) => { results.push({ id, ok }); if (!ok) fail.push(`${id}: ${detail}`)
    console.log(`  ${ok ? '✓' : '✗'} ${id}  ${detail}`) }
const waitPort = (p, ms) => new Promise((res) => { const t0 = Date.now()
    ;(function tick() { const s = createConnection({ port: p, host: '127.0.0.1' })
        s.on('connect', () => { s.destroy(); res(true) })
        s.on('error', () => { s.destroy(); Date.now() - t0 > ms ? res(false) : setTimeout(tick, 300) }) })() })

// 两条臂都进得去的页面(auditor 与 finance 都持这三个模块的 view)
const PAGES = ['/finance/close', '/finance/settings', '/finance/fx/new',
               '/finance/bank', '/finance/gst', '/finance/assets/new',
               '/purchasing/payment-terms', '/logistics/lanes']

let server, chrome
const accounts = []
function killChildren() {
    try { if (chrome?.pid) process.kill(-chrome.pid) } catch {}
    try { if (server?.pid) process.kill(-server.pid) } catch {}
}
installExitHooks({ onFinish: () => { killChildren(); try { release() } catch {} } })

async function mint(roleCode, tag) {
    const email = `pgprobe-${tag}-${Date.now()}@test.local`
    const cu = await (await rest('/auth/v1/admin/users', { method: 'POST',
        body: JSON.stringify({ email, password: 'pg-probe-1', email_confirm: true }) })).json()
    if (!cu.id) throw new Error(`账号建不出来(${tag}): ` + JSON.stringify(cu).slice(0, 200))
    // ★ LEAK-1:先删授权再删账号。
    planDelete(`/rest/v1/user_roles?user_id=eq.${cu.id}`, `revoke pgprobe grant ${cu.id}`, ORDER.GRANT)
    planDelete(`/auth/v1/admin/users/${cu.id}`, `delete pgprobe account ${cu.id}`, ORDER.ACCOUNT)
    const roles = await (await rest(`/rest/v1/roles?select=id,code&code=eq.${roleCode}`)).json()
    if (!roles?.[0]?.id) throw new Error(`线上没有 ${roleCode} 角色`)
    await rest('/rest/v1/user_roles', { method: 'POST', body: JSON.stringify(ephemeralGrantBody(cu.id, roles[0].id)) })
    const perms = new Set((await (await rest(
        `/rest/v1/role_permissions?select=permission_code&role_id=eq.${roles[0].id}`)).json() || [])
        .map((r) => r.permission_code))
    const sess = await (await fetch(URL_ + '/auth/v1/token?grant_type=password', { method: 'POST',
        headers: { apikey: ANON, 'Content-Type': 'application/json' },
        body: JSON.stringify({ email, password: 'pg-probe-1' }) })).json()
    if (!sess?.access_token) throw new Error(`登录失败(${tag})`)
    accounts.push(cu.id)
    return { perms, sess }
}

try {
    if (!CHROME) throw new Error('chrome-headless-shell 找不到')
    if (!existsSync(join(ROOT, '.next/BUILD_ID')))
        throw new Error('.next/BUILD_ID 不在 —— 本支跑在【生产构建】上。先 npm run build。')
    acquireOrExit('probe-permission-gate', { ownExit: false })
    openPlan('scripts/probe-permission-gate.mjs')
    await reapStalePlans()

    const A = await mint('auditor', 'a')
    const B = await mint('finance', 'b')
    // ★ 先钉住两条臂【真的是】它们该有的形状,否则整支探针在测一个错的前提。
    const shapeA = A.perms.has('module.finance.view') && !A.perms.has('module.finance.edit')
                && A.perms.has('module.purchasing.view') && !A.perms.has('module.purchasing.edit')
    const shapeB = B.perms.has('module.finance.view') && B.perms.has('module.finance.edit')
                && B.perms.has('module.purchasing.edit')
    probe('P0a', shapeA, `auditor = 看得见改不动 (finance.view=${A.perms.has('module.finance.view')}, finance.edit=${A.perms.has('module.finance.edit')})`)
    probe('P0b', shapeB, `finance = 改得动 (finance.edit=${B.perms.has('module.finance.edit')}, purchasing.edit=${B.perms.has('module.purchasing.edit')})`)
    if (!shapeA || !shapeB) throw new Error('两条臂的前提不成立 —— 判词无效')

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
    let msgId = 0; const pending = new Map()
    sock.onmessage = (m) => { const d = JSON.parse(m.data)
        if (d.id && pending.has(d.id)) { const { res, rej } = pending.get(d.id); pending.delete(d.id)
            d.error ? rej(new Error(JSON.stringify(d.error))) : res(d.result) } }
    const send = (method, params = {}, sessionId) => new Promise((res, rej) => {
        const id = ++msgId; pending.set(id, { res, rej }); sock.send(JSON.stringify({ id, method, params, sessionId })) })
    const { targetId } = await send('Target.createTarget', { url: 'about:blank' })
    const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true })
    const S = (m, p) => send(m, p, sessionId)
    await S('Page.enable'); await S('Runtime.enable'); await S('Network.enable')
    await S('Emulation.setDeviceMetricsOverride', { width: 1280, height: 900, deviceScaleFactor: 1, mobile: false })
    const cookieName = 'sb-' + URL_.split('//')[1].split('.')[0] + '-auth-token'
    const setArm = async (arm) => {
        await S('Network.clearBrowserCookies')
        await S('Network.setCookies', { cookies: [{ name: cookieName,
            value: 'base64-' + Buffer.from(JSON.stringify(arm.sess)).toString('base64url'),
            domain: 'localhost', path: '/', httpOnly: false, secure: false }] })
    }
    const ev = async (expr) => {
        const r = await S('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true })
        if (r.exceptionDetails) throw new Error(JSON.stringify(r.exceptionDetails).slice(0, 400))
        return r.result.value
    }
    const goto = async (path) => {
        await S('Page.navigate', { url: origin + path }); await sleep(1400)
        for (let i = 0; i < 40; i++) {
            if (await ev(`(() => { const b = document.querySelector('button')
                return !!b && Object.keys(b).some(k => k.startsWith('__react')) })()`)) return true
            await sleep(250)
        }
        return false
    }
    const GATE_SEL = FAULT === 'blind' ? '#nothing-at-all' : '[data-permission-required]'
    // 一页的读数:闸门清单 + 整页按钮标签的多重集合 + 是否被整页拒绝
    const readPage = () => ev(`(() => {
        const norm = (s) => (s || '').replace(/\\s+/g, ' ').trim()
        const gates = [...document.querySelectorAll(${JSON.stringify(GATE_SEL)})].map((g) => {
            const ctl = g.querySelector('button, input[type=submit]')
            const fs = g.querySelector('fieldset')
            const reason = g.querySelector('[data-slot="refusal"]')
            const r = g.getBoundingClientRect()
            return {
                code: g.getAttribute('data-permission-required'),
                hasControl: !!ctl,
                controlDisabled: !!(ctl && ctl.disabled),
                fieldsetDisabled: !!(fs && fs.disabled),
                reasonText: norm(reason && reason.textContent),
                reasonVisible: !!(reason && reason.getBoundingClientRect().width > 0),
                visible: r.width > 0 && r.height > 0,
            }
        })
        const labels = [...document.querySelectorAll('button')].map((b) => norm(b.textContent)).filter(Boolean).sort()
        return { gates, labels, denied: !!document.querySelector('[data-access-denied]') }
    })()`)

    const snap = {}
    for (const [tag, arm] of [['A', A], ['B', B]]) {
        await setArm(arm); snap[tag] = {}
        for (const p of PAGES) {
            if (!await goto(p)) { snap[tag][p] = { gates: [], labels: [], denied: false, dead: true }; continue }
            snap[tag][p] = await readPage()
        }
    }

    console.log('\n── A 臂:没有权限的人看到什么 ──')
    let gatesSeen = 0, allVisible = true, allDisabled = true, allExplained = true
    for (const p of PAGES) {
        const s = snap.A[p]
        if (s.dead) { probe(`A0 ${p}`, false, '页面没起来 —— 无从驱动'); continue }
        for (const g of s.gates) {
            gatesSeen++
            if (!g.visible) allVisible = false
            const disabled = FAULT === 'a-operable' ? false : (g.controlDisabled || g.fieldsetDisabled)
            if (!disabled) allDisabled = false
            const explained = FAULT === 'no-reason' ? false
                : (g.reasonVisible && g.reasonText.includes(g.code))
            if (!explained) allExplained = false
        }
        console.log(`   ${p}: ${s.gates.length} 个闸门${s.denied ? ' (整页拒绝)' : ''}`)
    }
    probe('A1', gatesSeen > 0, `A 臂上共 ${gatesSeen} 个上了闸的控件`)
    probe('A2', gatesSeen > 0 && allVisible, '每一个都【看得见】(不是 display:none,不是零尺寸)')
    probe('A3', gatesSeen > 0 && allDisabled, '每一个都【按不动】(fieldset disabled 或 button disabled)')
    probe('A4', gatesSeen > 0 && allExplained, '每一个旁边都有【看得见的理由,并且点名那个权限码】')

    console.log('\n── B 臂:有权限的人还能不能用(抓"用弄坏来修好")──')
    let bGates = 0, bOperable = true
    for (const p of PAGES) {
        const s = snap.B[p]
        if (s.dead) { probe(`B0 ${p}`, false, '页面没起来'); continue }
        bGates += s.gates.length
        // 有权限时 PermissionGate 直接渲染 children —— 不该留下任何标记
        for (const g of s.gates) {
            console.log(`   ${p}: 残留闸门 code=${g.code} disabled=${g.controlDisabled || g.fieldsetDisabled}`)
            if (g.controlDisabled || g.fieldsetDisabled) bOperable = false
        }
    }
    probe('B1', bGates === 0, `有权限时【一个闸门标记都不该留下】,实测 ${bGates} 个`)
    probe('B2', bOperable, '有权限的人手里,这些控件没有被本刀禁掉')

    console.log('\n── C 臂:没有任何一个控件对任何人消失 ──')
    let hiddenFrom = []
    for (const p of PAGES) {
        const a = snap.A[p], b = snap.B[p]
        if (a.dead || b.dead) continue
        const la = [...a.labels], lb = [...b.labels]
        if (FAULT === 'hide') la.pop()
        // B 有而 A 没有的标签 = 对无权限者藏起来的控件
        const bag = new Map(); la.forEach((x) => bag.set(x, (bag.get(x) || 0) + 1))
        const missing = []
        for (const x of lb) { const n = bag.get(x) || 0; if (n === 0) missing.push(x); else bag.set(x, n - 1) }
        if (missing.length) hiddenFrom.push(`${p}: ${[...new Set(missing)].join(' / ')}`)
        console.log(`   ${p}: A ${la.length} 个钮 · B ${lb.length} 个钮`)
    }
    probe('C1', hiddenFrom.length === 0,
        hiddenFrom.length ? `对无权限者藏起来的控件 → ${hiddenFrom.join(' | ')}` : '两条臂的按钮集合一致 —— 没有任何控件因缺权限而消失')

    console.log('\n════ 结果 ════')
    console.log(`${results.filter((r) => r.ok).length}/${results.length} 通过`)
    if (fail.length) { console.log('\n红:'); fail.forEach((f) => console.log('  ✗ ' + f)) }
    killChildren(); try { release() } catch {}
    process.exit(fail.length ? 1 : 0)
} catch (e) {
    console.error('\n探针自己炸了(这【不是】一次通过):', e.message)
    killChildren(); try { release() } catch {}
    process.exit(2)
}
