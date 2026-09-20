#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// DRAFT-2 的 (b) 证明 —— #24 `/sales/quotes/new`(这一刀唯一一张换了收参形状的表)
// ════════════════════════════════════════════════════════════════════════════
// ★ 跑在【生产构建】上:`probe-avatar` 抬头那条 —— 这棵树在 `next dev` 下水合
//   不收尾,交互探针量不到点击的结果。等的是**水合收尾**(`__reactFiber$…`)。
//
// ★★【它一次提交都不发】★★ 判据读的是 `new FormData(form)` —— 那**就是**按下
//   提交时会送出去的东西,而读它不写库。于是这支探针**一张报价都不会建**。
//
// ★★【它证的是什么,说清楚 —— 它【不是】一次红→绿】★★
//   (b) 不改那个双渲染,所以一个数 DOM 副本的判据在 (b) 之下会一直红。
//   这里证的是**结果**:格子里一个 `name` 都没有;那座桥在 FormData 里
//   **只出现一次**;而它带着**那个断点上打的字**。
//   ☞ 真正红得起来的那个测试是 `scripts/check-editable-name.mjs`(故障注入实测)。
//
// ★ 两处在册的探针缺陷,这里都避开了(`docs/known-issues.md`):
//   · `PROBE-UNBOUNDED-CDP-WAIT` —— 每一次 CDP 调用都带 30s 上限;
//   · `PROBE-LSOF-KILLS-ITSELF` —— 收尾那条 `lsof` 把**本进程**滤掉。
// ════════════════════════════════════════════════════════════════════════════
import { readFileSync, existsSync } from 'node:fs'
import { join } from 'node:path'
import { spawn, execSync } from 'node:child_process'
import { createConnection } from 'node:net'
import { acquireOrExit, release } from './liveLock.mjs'
import { openPlan, planDelete, ephemeralGrantBody, runPlan, reapStalePlans, ORDER } from './ephemeral.mjs'

const ROOT = new URL('..', import.meta.url).pathname
const PORT = 3203, CDP_PORT = 9339
const CHROME = join(process.env.HOME, '.cache/puppeteer/chrome-headless-shell/mac_arm-152.0.7977.75/chrome-headless-shell-mac-arm64/chrome-headless-shell')
const env = readFileSync(join(ROOT, '.env.local'), 'utf8')
const URL_ = env.match(/NEXT_PUBLIC_SUPABASE_URL=(\S+)/)[1]
const ANON = env.match(/NEXT_PUBLIC_SUPABASE_ANON_KEY=(\S+)/)[1]
const SERVICE = env.match(/SUPABASE_SERVICE_ROLE_KEY=(\S+)/)[1]
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const rest = (p, o = {}) => fetch(URL_ + p, { ...o, headers: {
    apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, 'Content-Type': 'application/json', ...(o.headers || {}) } })
const fail = []
const probe = (id, ok, detail) => {
    if (!ok) fail.push(`${id}: ${detail}`)
    console.log(`${ok ? '✓' : '✗'} ${id.padEnd(40)} ${detail}`)
}
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
    acquireOrExit('probe-draft2', { ownExit: false })
    openPlan('probe-draft2')
    await reapStalePlans()
    if (!existsSync(join(ROOT, '.next/BUILD_ID'))) throw new Error('.next/BUILD_ID 不在 —— 先 npm run build')
    if (!existsSync(CHROME)) throw new Error('chrome not at ' + CHROME)
    for (const p of [PORT, CDP_PORT]) { try { execSync(`lsof -ti tcp:${p} | xargs -r kill -9`, { stdio: 'ignore' }) } catch {} }

    const email = `draft2probe-${Date.now()}@test.local`
    const cu = await (await rest('/auth/v1/admin/users', { method: 'POST',
        body: JSON.stringify({ email, password: 'draft2-probe-1', email_confirm: true }) })).json()
    const accountId = cu.id
    if (!accountId) throw new Error('账号建不出来: ' + JSON.stringify(cu).slice(0, 300))
    planDelete(`/rest/v1/user_roles?user_id=eq.${accountId}`, `revoke grant ${accountId}`, ORDER.GRANT)
    planDelete(`/auth/v1/admin/users/${accountId}`, `delete account ${accountId}`, ORDER.ACCOUNT)
    const roles = await (await rest('/rest/v1/roles?select=id&code=eq.admin')).json()
    await rest('/rest/v1/user_roles', { method: 'POST', body: JSON.stringify(ephemeralGrantBody(accountId, roles[0].id)) })
    const sess = await (await fetch(URL_ + '/auth/v1/token?grant_type=password', { method: 'POST',
        headers: { apikey: ANON, 'Content-Type': 'application/json' },
        body: JSON.stringify({ email, password: 'draft2-probe-1' }) })).json()
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
            if (d.error) rej(new Error(JSON.stringify(d.error)))
            else res(d.result)
        }
    }
    // ★ PROBE-UNBOUNDED-CDP-WAIT:每一次调用都有上限 —— 一个没有失败分支的等待,
    //   挂死时是沉默的,连外层 waitFor 的上限都到不了。
    const send = (method, params = {}, sessionId) => new Promise((res, rej) => {
        const id = ++msgId
        const timer = setTimeout(() => {
            if (pending.delete(id)) rej(new Error(`CDP 超时(30s):${method}`))
        }, 30000)
        pending.set(id, { res: (v) => { clearTimeout(timer); res(v) },
                          rej: (e) => { clearTimeout(timer); rej(e) } })
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
    const view = async (w) => S('Emulation.setDeviceMetricsOverride',
        { width: w, height: 844, deviceScaleFactor: 1, mobile: w < 700 })

    const T = `[data-slot="editable-table"]`
    // 提交时会送出去的东西 —— 读它,不发它。
    const FORM = `(() => { const f = document.querySelector('form'); const fd = new FormData(f)
        const keys = Array.from(fd.keys())
        return { keys, lineKeys: keys.filter(k => /^line_/.test(k)),
                 jsonCount: fd.getAll('lines_json').length,
                 lines: JSON.parse(String(fd.get('lines_json') ?? '[]')) } })()`
    const NUM = `Array.from(document.querySelectorAll('${T} input[type=number]'))`
    const census = () => js(`${NUM}.map(e => ({ label: e.getAttribute('aria-label'), value: e.value, shown: e.offsetParent !== null }))`)
    const typeInto = async (idxExpr, text) => {
        await js(`(() => { const e = ${NUM}[${idxExpr}]; e.focus(); e.select(); return true })()`)
        await S('Input.insertText', { text })
        await sleep(350)
    }

    // ══ 390px ═══════════════════════════════════════════════════════════════
    await view(390)
    await S('Page.navigate', { url: `http://127.0.0.1:${PORT}/sales/quotes/new` })
    await sleep(600)
    if (!await waitFor(`(() => { const t = document.querySelector('${T}')
        return !!t && Object.keys(t).some(k => k.startsWith('__react')) })()`, 60000, '水合'))
        throw new Error('水合没完成 —— 判词不可信,不往下量')

    // ★★★ (b) 的直证:格子里一个具名控件都没有。
    const named = await js(`document.querySelectorAll('${T} [name]').length`)
    probe('★★★ 格子里的具名控件 = 0', named === 0, `<EditableTable> 里带 name 的控件 ${named} 个`)

    const f0 = await js(FORM)
    probe('★★★ 桥只出现一次 · 并列数组已退场',
        f0.jsonCount === 1 && f0.lineKeys.length === 0,
        `lines_json ${f0.jsonCount} 次 · line_* 具名字段 ${f0.lineKeys.length} 个(搬家前是 15 个)`)
    probe('390/桥里有 5 个空槽', Array.isArray(f0.lines) && f0.lines.length === 5,
        `lines.length = ${f0.lines.length}`)

    const before = await census()
    probe('390/收起时格子只读', before.length === 10 && before.every((i) => !i.shown),
        `DOM ${before.length} 个数字输入、看得见 ${before.filter((i) => i.shown).length} 个`)

    // 展开第一行 —— 手机上编辑【只】发生在展开区(组件抬头 ④)
    await js(`document.querySelectorAll('${T} button[aria-expanded]')[0].click()`); await sleep(500)
    const opened = await census()
    probe('390/展开后两份都在 DOM 里', opened.length === 12 && opened.filter((i) => i.shown).length === 2,
        `DOM ${opened.length} / 看得见 ${opened.filter((i) => i.shown).length}(期望 12 / 2 —— 双渲染照旧在,(b) 不修它)`)

    // 在展开区里真的打字
    const qtyIdx = await js(`${NUM}.findIndex(e => e.offsetParent !== null)`)
    await typeInto(qtyIdx, '77')
    const priceIdx = await js(`${NUM}.map((e,i)=>({e,i})).filter(x=>x.e.offsetParent!==null).map(x=>x.i)[1]`)
    await typeInto(priceIdx, '10.5')
    // 物料:受控 select,要走原生 setter 再派发 change,否则 React 收不到
    await js(`(() => { const s = Array.from(document.querySelectorAll('${T} select')).filter(e => e.offsetParent !== null)[0]
        const opt = Array.from(s.options).find(o => o.value)
        const set = Object.getOwnPropertyDescriptor(window.HTMLSelectElement.prototype, 'value').set
        set.call(s, opt.value); s.dispatchEvent(new Event('change', { bubbles: true })); return opt.value })()`)
    await sleep(400)

    const f1 = await js(FORM)
    const l0 = f1.lines[0] ?? {}
    probe('★★★ 390/手机上打的字【到了】桥里',
        f1.jsonCount === 1 && l0.qty === '77' && l0.price === '10.5' && !!l0.material_id,
        `lines_json ${f1.jsonCount} 次 · lines[0] = ${JSON.stringify(l0)}`)
    probe('390/其余四槽还是空的',
        f1.lines.slice(1).every((l) => l.material_id === '' && l.qty === '' && l.price === ''),
        `lines[1..4] = ${JSON.stringify(f1.lines.slice(1))}`)

    const ov = await js(`({ sw: document.scrollingElement.scrollWidth, cw: document.scrollingElement.clientWidth })`)
    probe('390/整页不横向溢出(搬家【之后】的读数)', ov.sw <= ov.cw + 1,
        `scrollWidth ${ov.sw} / clientWidth ${ov.cw}`)

    // ══ 1280px ══════════════════════════════════════════════════════════════
    // ★ 【不重新导航】,只改视口 —— 草稿留在原地,于是这一臂证得了一件
    //   `goto` 证不了的事:390 上打的字在 1280 的格子里。
    await view(1280); await sleep(600)
    const desk = await census()
    const deskShown = desk.filter((i) => i.shown)
    probe('1280/格子里就地编辑', deskShown.length === 10,
        `DOM ${desk.length} / 看得见 ${deskShown.length}(五行 × 两格;展开区那一行被 sm:hidden 整行藏起来)`)
    probe('★ 1280/390 上打的字出现在格子里',
        deskShown[0]?.value === '77' && deskShown[1]?.value === '10.5',
        `第一行两格 = ${JSON.stringify([deskShown[0]?.value, deskShown[1]?.value])}`)

    await typeInto(await js(`${NUM}.map((e,i)=>({e,i})).filter(x=>x.e.offsetParent!==null).map(x=>x.i)[2]`), '9')
    const f2 = await js(FORM)
    probe('★★★ 1280/桌面上打的字【到了】桥里,而且桥仍然只有一份',
        f2.jsonCount === 1 && f2.lines[1]?.qty === '9' && f2.lines[0]?.qty === '77',
        `lines_json ${f2.jsonCount} 次 · lines[0].qty=${JSON.stringify(f2.lines[0]?.qty)} · lines[1].qty=${JSON.stringify(f2.lines[1]?.qty)}`)
    probe('1280/没有一个 line_* 具名字段', f2.lineKeys.length === 0,
        `line_* = ${JSON.stringify(f2.lineKeys)}`)
}

let code = 0
try { await main() } catch (e) { console.error('✗ 探针自己挂了:', e.message); code = 2 }
finally {
    try { if (chrome) process.kill(-chrome.pid, 'SIGKILL') } catch {}
    try { if (server) process.kill(server.pid, 'SIGTERM') } catch {}
    // ★★ PROBE-LSOF-KILLS-ITSELF:把**本进程**滤掉 —— `lsof -ti tcp:<cdp>` 会把
    //   本进程那条 CDP 客户端 socket 也列出来,于是探针会在收尾时把自己 SIGKILL 掉
    //   (DRAFT-1 实测 `PROBE_EXIT=137`:断言全绿、而清理一步都没跑)。
    for (const p of [PORT, CDP_PORT]) {
        try { execSync(`lsof -ti tcp:${p} | grep -v '^${process.pid}$' | xargs -r kill -9`, { stdio: 'ignore' }) } catch {}
    }
    const r = await runPlan(); console.log(`· 清理:${JSON.stringify(r)}`)
    release()
}
if (fail.length) { console.log(`\n✗ ${fail.length} 条没过:\n  ` + fail.join('\n  ')); code = code || 1 }
else if (code === 0) console.log('\n✓ 全部通过')
console.log(`PROBE_OWN_EXIT=${code}`)
process.exit(code)
