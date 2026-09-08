#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// ALERT-2a(2026-09-08)· 【把那 41 处降级后的机器字,真的从无障碍树上读一遍】
// ════════════════════════════════════════════════════════════════════════════
//
// ★★【判据为什么【不是】"它被播报了"】★★
//   委托书原本要求「断言那条消息被播报」。而实测:**那 41 处全部是服务端组件**
//   (41/41 没有 `'use client'`)—— 它们是随页面一起到达的静态内容,不是插进来的。
//   live region(`role="alert"` / `aria-live`)播报的是【变化】;
//   一个随页面一起到达、一开始就带着内容的活动区,多数读屏软件根本不念。
//   ☞ 给这 41 个盒子套一个 `role="alert"`,再写一支对着它变绿的探针,
//     正是本仓库反复付账的那个形状:**一条判据看得见那个性质,却指着一个
//     没有人住的状态**。Tim 在闸上裁定改成下面这条,并说「你该带上来而不是
//     悄悄替换掉」。
//
//   **所以这支探针断言的是【真的成立、而且承重】的那三件:**
//     ① 那句人话在无障碍树里,**在阅读顺序上排在机器字前面**;
//     ② 那个展开钮是一个**真的、有名字的**控件,`expanded` 一开始是 false;
//     ③ 展开之后,机器字**够得着、而且一个字节都没少**。
//   ①+③ 合起来就是「人先读到人话,而报修时抄得走原文」——
//   降级掉了原文的收敛,比它治的那个漂移更坏。
//
// ════════════════════════════════════════════════════════════════════════════
// ★【怎么驱动一次【真的】读取失败 —— 不注入故障、不改一行代码】★
// ════════════════════════════════════════════════════════════════════════════
//   `db/functions/account_ledger.sql:37` 对认不出来的科目码
//   `RAISE EXCEPTION 'ACCOUNT_NOT_FOUND|%'`。于是
//   **`/finance/ledger/<不存在的科目码>` 是一条【线上真实存在】的失败路**,
//   它走的正是那 41 处共用的那个 `if (error) return (…)` 分支。
//   ☞ 不桩、不注入、不写任何业务数据 —— 一次读,失败,回来。
//
// ════════════════════════════════════════════════════════════════════════════
// ★【本脚本【必须】能红,而且要能演示】★
//     PROBE_FAULT=blind        选择器全瞎        → 全红,而且说"我瞎了"
//     PROBE_FAULT=no-details   假装没有展开钮    → A2/A3 红
//     PROBE_FAULT=raw-first    假装机器字排在前  → A1b 红
//     PROBE_FAULT=truncated    假装原文被截断    → A4 红
//     PROBE_FAULT=no-note      假装确认框没有那句话 → B/C 红
//
// 用法:npm run build && node scripts/probe-alert2a.mjs
// ════════════════════════════════════════════════════════════════════════════

import { spawn } from 'node:child_process'
import { readFileSync, existsSync } from 'node:fs'
import { join } from 'node:path'
import { createConnection } from 'node:net'
import { acquireOrExit, release } from './liveLock.mjs'
import { openPlan, planDelete, ephemeralGrantBody, runPlan, reapStalePlans, installExitHooks, ORDER } from './ephemeral.mjs'

const ROOT = new URL('..', import.meta.url).pathname
const PORT = 3205                 // 3198 phone · 3199 冒烟 · 3201 avatar · 3202 tiers · 3203 confirm · 3204 action-message
const CDP_PORT = 9341
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

// 两种语言各自那三句话 —— 判据比的是【文案文件里的那一份】,不是我记得的那一句。
const M = { en: JSON.parse('{}'), zh: JSON.parse('{}') }
function msg(lang, path) {
    const src = readFileSync(join(ROOT, `messages/${lang}.ts`), 'utf8')
    // 只取最后一段键名,并且要求它在文件里唯一 —— 取不到就抛,不猜。
    const leaf = path.split('.').pop()
    const re = new RegExp(`(?:^|\\n)\\s*${leaf}:\\s*(['\`])((?:\\\\.|(?!\\1).)*)\\1`, 'g')
    const hits = [...src.matchAll(re)].map((m) => m[2])
    if (!hits.length) throw new Error(`messages/${lang}.ts 里找不到 ${path}`)
    return hits
}

try {
    if (!CHROME) throw new Error('chrome-headless-shell 找不到')
    if (!existsSync(join(ROOT, '.next/BUILD_ID')))
        throw new Error('.next/BUILD_ID 不在 —— 本支跑在【生产构建】上。先 npm run build。')
    acquireOrExit('probe-alert2a', { ownExit: false })
    openPlan('scripts/probe-alert2a.mjs')
    await reapStalePlans()

    const DETAIL_EN = msg('en', 'common.actionMessage.technicalDetail')[0]
    const DETAIL_ZH = msg('zh', 'common.actionMessage.technicalDetail')[0]
    const SOFT_EN = msg('en', 'common.softDeleteNote')[0]
    const SOFT_ZH = msg('zh', 'common.softDeleteNote')[0]
    const HARD_EN = msg('en', 'common.hardDeleteNote')[0]
    const HARD_ZH = msg('zh', 'common.hardDeleteNote')[0]
    console.log(`· 文案取自 messages/*.ts:detail=${JSON.stringify(DETAIL_EN)}`)

    // ★ 本刀改过的那句话【不许再说"可以恢复"】—— 全仓库没有恢复路径。
    //   这一格不用浏览器,但它属于同一份判词:一句在库里为假的话,画得再好也是假的。
    const softLies = /recoverab|可以恢复|可恢复/i.test(SOFT_EN + SOFT_ZH)
    probe('A0 软删说明不再承诺"可以恢复"', !softLies,
        softLies ? `★ 仍然承诺恢复:${SOFT_EN}` : '两种语言都只说"记录留着",不说"恢复得了"')

    // ── 一个一次性会话(admin —— 本探针只【打开】对话框,一律取消,不写任何东西)──
    const email = `a2aprobe-${Date.now()}@test.local`
    const cu = await (await rest('/auth/v1/admin/users', { method: 'POST',
        body: JSON.stringify({ email, password: 'a2a-probe-1', email_confirm: true }) })).json()
    accountId = cu.id
    if (!accountId) throw new Error('账号建不出来: ' + JSON.stringify(cu).slice(0, 300))
    planDelete(`/rest/v1/user_roles?user_id=eq.${accountId}`, `revoke a2aprobe grant ${accountId}`, ORDER.GRANT)
    planDelete(`/auth/v1/admin/users/${accountId}`, `delete a2aprobe account ${accountId}`, ORDER.ACCOUNT)

    const roles = await (await rest('/rest/v1/roles?select=id,code&code=eq.admin')).json()
    if (!roles?.[0]?.id) throw new Error('线上没有 admin 角色 —— 本探针无从驱动')
    await rest('/rest/v1/user_roles', { method: 'POST',
        body: JSON.stringify(ephemeralGrantBody(accountId, roles[0].id)) })

    const sess = await (await fetch(URL_ + '/auth/v1/token?grant_type=password', { method: 'POST',
        headers: { apikey: ANON, 'Content-Type': 'application/json' },
        body: JSON.stringify({ email, password: 'a2a-probe-1' }) })).json()
    if (!sess?.access_token) throw new Error('登录失败')
    const cookieName = 'sb-' + URL_.split('//')[1].split('.')[0] + '-auth-token'
    const cookieValue = 'base64-' + Buffer.from(JSON.stringify(sess)).toString('base64url')

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

    const setLang = async (lang) => S('Network.setCookies', { cookies: [
        { name: cookieName, value: cookieValue, domain: 'localhost', path: '/', httpOnly: false, secure: false },
        { name: 'NEXT_LOCALE', value: lang, domain: 'localhost', path: '/', httpOnly: false, secure: false } ] })

    const ev = async (expr) => {
        const r = await S('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true })
        if (r.exceptionDetails) throw new Error(JSON.stringify(r.exceptionDetails).slice(0, 400))
        return r.result.value
    }
    const goto = async (path) => {
        await S('Page.navigate', { url: origin + path })
        for (let i = 0; i < 120; i++) {
            await sleep(250)
            if (await ev('document.readyState === "complete"')) break
        }
        await sleep(400)
    }
    // 无障碍树:拉全树,按【阅读顺序】拿到节点数组
    const axTree = async () => {
        const { nodes } = await S('Accessibility.getFullAXTree')
        return nodes.map((n) => ({
            role: n.role?.value ?? '',
            name: n.name?.value ?? '',
            expanded: (n.properties || []).find((p) => p.name === 'expanded')?.value?.value,
            ignored: !!n.ignored,
        }))
    }

    // ════════════════════════════════════════════════════════════════════
    // A 组 —— 那 41 处的形状,走一条【线上真实存在】的读取失败
    // ════════════════════════════════════════════════════════════════════
    console.log('\n── A 组:/finance/ledger/<不存在的科目> —— account_ledger 会 RAISE ──')
    await setLang('en')
    await goto('/finance/ledger/ZZ-NO-SUCH-ACCOUNT?mode=bs')

    let ax = await axTree()
    if (FAULT === 'blind') ax = []
    const LOAD_EN = msg('en', 'finance.loadError')[0]

    const iHead = ax.findIndex((n) => !n.ignored && n.name.includes(LOAD_EN))
    let iDisc = ax.findIndex((n) => !n.ignored && n.name.includes(DETAIL_EN))
    if (FAULT === 'no-details') iDisc = -1

    probe('A0b 探针没有瞎', ax.length > 20, `无障碍树 ${ax.length} 个节点`)
    probe('A1 那句人话在无障碍树里', iHead >= 0,
        iHead >= 0 ? `「${LOAD_EN}」在第 ${iHead} 个节点` : `★ 树里没有「${LOAD_EN}」`)

    // 机器字:原文里那串 ACCOUNT_NOT_FOUND —— 它是这次失败的真凭据
    const RAW = 'ACCOUNT_NOT_FOUND'
    let iRaw = ax.findIndex((n) => !n.ignored && n.name.includes(RAW))
    if (FAULT === 'raw-first') iRaw = 0
    probe('A1b 人话排在机器字【前面】(阅读顺序)',
        iHead >= 0 && (iRaw < 0 || iHead < iRaw),
        iRaw < 0 ? '机器字收起时不在树里 —— 人话是第一句' : `人话 @${iHead} · 机器字 @${iRaw}`)

    probe('A2 展开钮是一个【有名字的真控件】', iDisc >= 0 && !!ax[iDisc]?.role,
        iDisc >= 0 ? `role=${ax[iDisc].role} name=「${ax[iDisc].name}」` : '★ 树里没有展开钮')
    probe('A2b 一开始是【收起】的', iDisc >= 0 && ax[iDisc]?.expanded === false,
        iDisc >= 0 ? `expanded=${ax[iDisc]?.expanded}` : '★ 无从判断')

    // ★★【这一格第一版是错的,而错法正是本仓库记了六次的那一个】★★
    //   第一版写的是 `document.querySelector('details')` —— 而这一页上有【两个】
    //   `<details>`(另一个在导航里),机器字那个是**第二个**。
    //   于是探针点开了导航那一个,再去问机器字那一个的 `expanded`,当然是 false,
    //   报回来像是"产品没做到"。**判据没有走人真的走的那条路。**
    //   ☞ 是一格【对照】把它钉死的:同一个浏览器里跑一段裸 `<details>`,
    //     开合完全正常(expanded false→true、原文 false→true 地进出无障碍树)。
    //     **对照绿了,被测的红了 —— 那么该被怀疑的是判据,不是被测的东西。**
    //   ☞ 所以下面先【断言我找的是哪一个】,再谈开合。
    const which = await ev(`(() => {
        const all = [...document.querySelectorAll('details')];
        return JSON.stringify({ total: all.length, mine: all.findIndex((d) => d.querySelector('pre')) });
    })()`)
    const w = JSON.parse(which || '{"total":0,"mine":-1}')
    probe('A2c 找对了【机器字那一个】details', w.mine >= 0,
        `页面上 ${w.total} 个 details,带 <pre> 的是第 ${w.mine} 个`)

    const opened = await ev(`(() => {
        const d = [...document.querySelectorAll('details')].find((x) => x.querySelector('pre'));
        if (!d) return false;
        const s = d.querySelector('summary'); if (!s) return false;
        s.click(); return d.open === true;
    })()`)
    probe('A3 展开钮点得动', opened === true, opened ? 'details.open = true' : '★ 点不开')

    await sleep(300)
    let ax2 = await axTree()
    const iDisc2 = ax2.findIndex((n) => !n.ignored && n.name.includes(DETAIL_EN))
    probe('A3b 展开后 expanded=true', iDisc2 >= 0 && ax2[iDisc2]?.expanded === true,
        iDisc2 >= 0 ? `expanded=${ax2[iDisc2]?.expanded}` : '★ 展开钮不见了')

    // ★ 收起时机器字【不在】无障碍树里,展开后【在】—— 这一对才是"降级"的证据。
    //   只断言"展开后在",对着一个根本没有收起过的页面也会绿。
    const rawInAxNow = ax2.some((n) => !n.ignored && n.name.includes(RAW))
    probe('A3c 机器字:收起时不在树里 → 展开后在树里', iRaw < 0 && rawInAxNow === true,
        `收起 ${iRaw < 0 ? '不在' : '在(★)'} · 展开 ${rawInAxNow ? '在' : '不在(★)'}`)

    // 原文完整性:页面上那段 <pre> 的文字,与 JSON.stringify 的形状对得上
    let payload = await ev(`(() => { const p = document.querySelector('details pre'); return p ? p.textContent : null })()`)
    if (FAULT === 'truncated') payload = (payload || '').slice(0, 12)
    // ★ 判词要把【实际算出来的三个分项】说出来 —— 第一版把它们写成了断言,
    //   于是 PROBE_FAULT=truncated 那一格红着、理由里却写着"完整的 JSON 对象",
    //   一句自相矛盾的失败说明。标签念出来要和判据念出来是同一件事。
    const hasRaw = !!payload && payload.includes(RAW)
    const wellFormed = !!payload && payload.trim().startsWith('{') && payload.trim().endsWith('}')
    const complete = hasRaw && wellFormed
    probe('A4 机器字够得着,而且一个字节都没少', complete,
        payload ? `${payload.length} 字符 · 含 ${RAW}=${hasRaw} · 首尾是完整 JSON=${wellFormed}` : '★ 取不到原文')

    // ★ 盒子没有被换掉 —— 那 74 个同族盒子留在旧画法上,本刀不许动它
    const boxKept = await ev(`!!document.querySelector('.bg-red-100.border-red-400')`)
    probe('A5 红盒子【原样没动】', boxKept === true,
        boxKept ? '仍是 bg-red-100 border-red-400 —— 没有采用 Alert,没有造出第二种盒子' : '★ 盒子被换掉了')

    // ── 中文那一遍(文案不是英文的直译,所以要各自走)──
    console.log('\n── A 组(中文)──')
    await setLang('zh')
    await goto('/finance/ledger/ZZ-NO-SUCH-ACCOUNT?mode=bs')
    const axZh = await axTree()
    const LOAD_ZH = msg('zh', 'finance.loadError')[0]
    const iHeadZh = axZh.findIndex((n) => !n.ignored && n.name.includes(LOAD_ZH))
    const iDiscZh = axZh.findIndex((n) => !n.ignored && n.name.includes(DETAIL_ZH))
    probe('A6 中文:人话在树里', iHeadZh >= 0, iHeadZh >= 0 ? `「${LOAD_ZH}」@${iHeadZh}` : `★ 没有「${LOAD_ZH}」`)
    probe('A7 中文:展开钮在树里且收起', iDiscZh >= 0 && axZh[iDiscZh]?.expanded === false,
        iDiscZh >= 0 ? `「${axZh[iDiscZh].name}」expanded=${axZh[iDiscZh].expanded}` : '★ 没有展开钮')

    // ════════════════════════════════════════════════════════════════════
    // B/C 组 —— 确认框里那两句话。【只打开,一律取消,不写任何东西】
    // ════════════════════════════════════════════════════════════════════
    const openDialogAndRead = async (path, clickSel) => {
        await goto(path)
        const clicked = await ev(`(() => {
            const els = [...document.querySelectorAll(${JSON.stringify(clickSel)})];
            const el = els[0]; if (!el) return false; el.click(); return true;
        })()`)
        if (!clicked) return { clicked: false, text: '' }
        await sleep(600)
        const text = await ev(`(() => {
            const d = document.querySelector('[role="dialog"]');
            return d ? d.innerText : '';
        })()`)
        return { clicked: true, text: text || '' }
    }
    const cancelDialog = async () => {
        await ev(`(() => { const b = document.querySelector('[data-confirm-cancel="1"]');
            if (b) { b.click(); return true }
            document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true })); return true })()`)
        await sleep(300)
    }

    console.log('\n── B 组:说 Delete、其实软删 —— 那句说明到没到屏幕上 ──')
    await setLang('en')
    const formula = await (await rest('/rest/v1/pricing_formulas?select=id&deleted_at=is.null&limit=1')).json()
    if (formula?.[0]?.id) {
        let r = await openDialogAndRead(`/tools/pricing/formulas/${formula[0].id}/edit`,
            'button[aria-haspopup="dialog"]')
        if (FAULT === 'no-note') r = { ...r, text: '(no note)' }
        probe('B1 定价公式:确认框打得开', r.clicked, r.clicked ? '对话框开了' : '★ 触发钮点不到 —— 【没有跑】')
        probe('B2 定价公式:软删说明在对话框里', r.clicked && r.text.includes(SOFT_EN.slice(0, 28)),
            r.clicked ? `正文:${r.text.replace(/\s+/g, ' ').slice(0, 120)}…` : '★ 无从判断')
        await cancelDialog()
        const gone = await ev(`!document.querySelector('[role="dialog"]')`)
        probe('B3 取消之后什么都没发生', gone === true, gone ? '对话框关了,没有确认过任何删除' : '★ 对话框还在')
    } else {
        probe('B0 无从驱动', false, '★ pricing_formulas 一行都没有 —— B 组【没有跑】')
    }

    console.log('\n── C 组:硬删 —— 那句"永久、无法撤销"到没到屏幕上 ──')
    const hol = await (await rest('/rest/v1/public_holidays?select=id,holiday_date&limit=1&order=holiday_date.desc')).json()
    if (hol?.[0]?.id) {
        const yr = String(hol[0].holiday_date).slice(0, 4)
        let r = await openDialogAndRead(`/hr/leave/holidays?year=${yr}`, 'button[aria-haspopup="dialog"]')
        if (FAULT === 'no-note') r = { ...r, text: '(no note)' }
        probe('C1 公众假期:确认框打得开(此前【一个都没有】)', r.clicked,
            r.clicked ? '对话框开了' : '★ 触发钮点不到 —— 【没有跑】')
        probe('C2 公众假期:硬删说明在对话框里', r.clicked && r.text.includes(HARD_EN.slice(0, 28)),
            r.clicked ? `正文:${r.text.replace(/\s+/g, ' ').slice(0, 120)}…` : '★ 无从判断')
        probe('C3 硬删说明【不是】那句软删的话', r.clicked && !r.text.includes(SOFT_EN.slice(0, 28)),
            r.clicked ? '没有把"记录留着"抄到一个永久销毁的钮上' : '★ 无从判断')
        await cancelDialog()
        const gone = await ev(`!document.querySelector('[role="dialog"]')`)
        probe('C4 取消之后什么都没发生', gone === true, gone ? '对话框关了,那一天还在' : '★ 对话框还在')
    } else {
        probe('C0 无从驱动', false, '★ public_holidays 一行都没有 —— C 组【没有跑】')
    }

    // ════════════════════════════════════════════════════════════════════
    console.log(`\n── 小结 ──`)
    const green = results.filter((r) => r.ok).length
    console.log(`  ${green}/${results.length} 格通过`)
    if (fail.length) { console.log('\n红的格子:'); fail.forEach((f) => console.log('  ✗ ' + f)) }
    await runPlan()
    console.log(fail.length ? '\nEXIT 1 — 有红格' : '\nEXIT 0 — 降级后的机器字,真的从无障碍树上被读过了')
    process.exitCode = fail.length ? 1 : 0
} catch (e) {
    console.error('\n★ 探针自己出错(这【不是】通过):', e.message)
    try { await runPlan() } catch {}
    process.exitCode = 2
} finally {
    killChildren(); try { release() } catch {}
}
