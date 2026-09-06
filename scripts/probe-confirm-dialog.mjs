#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// BTN-4(2026-09-06)· 【把确认这一步真的走一遍】
// ════════════════════════════════════════════════════════════════════════════
// CONFIRM-1 的抬头第 ③ 条写着,它存在的一半理由是:
//   「★【原生对话框对冒烟是隐形的】★ 自动化点不到 window.confirm,
//     于是这 40 步确认**一次都没有被机器走过**。」
// 而它换掉了那 40 个盒子之后,**没有写那支探针** —— 于是那句话在 CONFIRM-1
// 落地之后【仍然是真的】:确认这一步依旧一次都没有被机器走过,只是原因从
// 「点不到」变成了「没有人去点」。本脚本是那半句话的兑现。
//
// ★ 它驱动的是 BTN-4 的两件事,而这两件正是【非它不可】的两件:
//   ① app/finance/fx/[id]/edit —— 全树最后一个原生【输入型】对话框(window.prompt)
//      在这一刀退休。**一个 window.prompt 是点不到的**,所以在本刀之前,
//      "撤销一条牌价"这一步没有任何机器走过。
//   ② app/tools/tasks/[id] —— 那个【没有确认步骤的硬删除】。BTN-3b 给了它破坏档
//      却刻意没加确认框(那一刀不许改行为)。本刀加了,而
//      **known-issues 的 BTN3B-TASKNODE-HARD-DELETE 只有在这支探针真的驱动过
//      它之后才允许关闭** —— 不是凭代码写出来了。
//
// ════════════════════════════════════════════════════════════════════════════
// ★★【判据必须走人真的走的那条路,而且必须【分得开两臂】】★★
// ════════════════════════════════════════════════════════════════════════════
//   AGENTS.md 记了这一族六次。本脚本因此:
//   · 用【真的鼠标事件】点(Input.dispatchMouseEvent),不是 el.click() ——
//     后者绕开命中检测,一个被遮住/零尺寸的按钮照样"点得到",于是判据假绿;
//   · 等【水合收尾】(__reactFiber$…)才动手 —— 服务端 HTML 里那个按钮
//     在 JS 一行都没跑的时候就存在了,在那之前下判词等于什么都没测;
//   · ★ 每一条断言都自带【反臂】:先断言"对话框这会儿不在",再点开,
//     再断言"它在了"。一条只会说"在"的断言,对着一个永远显示对话框的树
//     也会绿。
//
// ★★【本脚本【必须】能红 —— 而这件事本身要能被演示】★★
//   `PROBE_FAULT=<格子名>` 注入一个故障,那一格【必须】变红。
//   没有这个开关,一支从来没有红过的探针与一支不存在的探针,退出码相同。
//     PROBE_FAULT=no-dialog     假装点开之后对话框没出现   → D1/T1 红
//     PROBE_FAULT=no-subject    假装主语那一格是空的        → D2/T2 红
//     PROBE_FAULT=blind         把选择器弄瞎(全都找不到)  → 全红,而且是"我瞎了"
//
// 用法:npm run build && node scripts/probe-confirm-dialog.mjs
//       退出码 0 = 两件事都被真的走过了
// ════════════════════════════════════════════════════════════════════════════

import { spawn } from 'node:child_process'
import { readFileSync, existsSync } from 'node:fs'
import { join } from 'node:path'
import { createConnection } from 'node:net'
import { acquireOrExit, release } from './liveLock.mjs'
import { openPlan, planDelete, ephemeralGrantBody, runPlan, reapStalePlans, installExitHooks, ORDER } from './ephemeral.mjs'

const ROOT = new URL('..', import.meta.url).pathname
const PORT = 3203                 // 3198 survey-phone · 3199 冒烟 · 3201 avatar · 3202 button-tiers
const CDP_PORT = 9339
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

let server, chrome, accountId, fxRateId, taskId, nodeId
function killChildren() {
    try { if (chrome?.pid) process.kill(-chrome.pid) } catch {}
    try { if (server?.pid) process.kill(-server.pid) } catch {}
}
installExitHooks({ onFinish: () => { killChildren(); try { release() } catch {} } })

try {
    if (!CHROME) throw new Error('chrome-headless-shell 找不到')
    if (!existsSync(join(ROOT, '.next/BUILD_ID')))
        throw new Error('.next/BUILD_ID 不在 —— 这一支跑在【生产构建】上。先 npm run build。')
    acquireOrExit('probe-confirm-dialog', { ownExit: false })
    openPlan('scripts/probe-confirm-dialog.mjs')
    await reapStalePlans()

    // ── 一次性 admin ──────────────────────────────────────────────────────
    const email = `cfmprobe-${Date.now()}@test.local`
    const cu = await (await rest('/auth/v1/admin/users', { method: 'POST',
        body: JSON.stringify({ email, password: 'cfm-probe-1', email_confirm: true }) })).json()
    accountId = cu.id
    if (!accountId) throw new Error('账号建不出来: ' + JSON.stringify(cu).slice(0, 300))
    // ★ LEAK-1:先删授权再删账号 —— 顺序反了留下的正是一条认不到人的授权。
    planDelete(`/rest/v1/user_roles?user_id=eq.${accountId}`, `revoke cfmprobe grant ${accountId}`, ORDER.GRANT)
    planDelete(`/auth/v1/admin/users/${accountId}`, `delete cfmprobe account ${accountId}`, ORDER.ACCOUNT)
    const roles = await (await rest('/rest/v1/roles?select=id&code=eq.admin')).json()
    await rest('/rest/v1/user_roles', { method: 'POST',
        body: JSON.stringify(ephemeralGrantBody(accountId, roles[0].id)) })

    const sess = await (await fetch(URL_ + '/auth/v1/token?grant_type=password', { method: 'POST',
        headers: { apikey: ANON, 'Content-Type': 'application/json' },
        body: JSON.stringify({ email, password: 'cfm-probe-1' }) })).json()
    if (!sess?.access_token) throw new Error('登录失败')
    const cookieName = 'sb-' + URL_.split('//')[1].split('.')[0] + '-auth-token'
    const cookieValue = 'base64-' + Buffer.from(JSON.stringify(sess)).toString('base64url')

    // ── 取两个真的 id ────────────────────────────────────────────────────
    // ★ 取不到就【响亮中止】,不当成跳过 —— 一次失败不是一个空集(AGENTS.md)。
    const fx = await (await rest('/rest/v1/fx_rates?select=id&limit=1&order=rate_date.desc')).json()
    fxRateId = fx?.[0]?.id
    if (!fxRateId) throw new Error('fx_rates 里一行都没有 —— 本探针的 ① 无从驱动')

    // ★★【为什么不自己造一张 task】★★ `tasks` 上挂着 `trg_tasks_no_hard_delete`
    //   (它是软删的)与 `trg_tasks_owner_required`(owner 默认取
    //   `current_user_employee()`,而服务角色解析不出员工)。造一张进去,
    //   要么被拒,要么留下一张【删不掉】的任务 —— 一支制造残骸的探针,
    //   比没有探针坏。所以:挂一个 ZZ-SMOKE-* 的【步骤】到一张线上真实、
    //   未被软删的任务上。**要删的正是这个步骤,而那就是被测的那个动作。**
    //   ☞ 业务残骸【按名标成 scratch】—— AGENTS.md 的既有约定。
    // ════════════════════════════════════════════════════════════════════
    // ★★【这一段被改过两次,两次都是被【实测】逼的 —— 两次都记下来】★★
    // ════════════════════════════════════════════════════════════════════
    //
    // 【第一版】把步骤挂到线上**别人的**任务上 → 对话框全绿,而 T6「行真的没了」红。
    //   查明:`task_nodes delete` 策略是 `can_edit_task()`,它要求任务归你(私人)
    //   或你是参与者(团队)。一次性 admin 没有 employees 行,
    //   `current_user_employee()` 是 NULL,DELETE **命中 0 行**。
    //   ★ RLS 不报错,它只是让那条 DELETE 什么都删不到。★
    //   **权限是对的,是探针没站在一个删得动的人身上。**
    //   ☞ 顺带照出一件真的:`removeNode` 在 0 行被删时仍返回成功 ——
    //     已立案 `docs/known-issues.md · BTN4-REMOVENODE-SILENT-NOOP`。
    //
    // 【第二版】改成"自己造员工 + 自己的私人任务"。T6 变绿了,**而它砸了冒烟。**
    //   `smoke-routes.mjs` 的 `sweepScratch()` 无条件硬删所有 `ZZ-SMOKE-*` 员工;
    //   而 `tasks` 无条件拒绝硬删(`trg_tasks_no_hard_delete`),
    //   `tasks.owner_id → employees(id)` 于是**永远**攥着那名员工。
    //   实测:冒烟在【清扫阶段】就中止,一条路由都没走过 ——
    //   **一支探针给自己挣了一格绿,代价是让另一支检查从此起不来。**
    //   ★ 判据:临时数据不但要"能清掉",还要"清得掉它的每一个引用者"。
    //
    // 【第三版,也就是现在这一版】**不造任务。**
    //   造一名 `ZZ-SMOKE-*` 员工,把它加进一张**线上已有的团队任务**当参与者
    //   (`can_edit_task` 的团队分支),步骤造在那张任务上。
    //   清理全是硬删、且顺序是依赖的反序:
    //     参与者产生的 task_history → 参与者行 → 员工 → 授权 → 账号。
    //   **没有任何一行是删不掉的,所以冒烟的清扫永远不会被它绊住。**
    const emp = await (await rest('/rest/v1/employees', { method: 'POST',
        headers: { Prefer: 'return=representation' },
        body: JSON.stringify({ code: `ZZ-SMOKE-CFM-${Date.now()}`, legal_name: 'ZZ-SMOKE Confirm Probe',
            employment_type: 'full_time', work_category: 'office', hire_date: '2026-01-01',
            user_id: accountId }) })).json()
    const empId = emp?.[0]?.id
    if (!empId) throw new Error('建不出探针员工: ' + JSON.stringify(emp).slice(0, 300))

    // ★ 取一张线上已有的【团队】任务 —— 不造新的,见上。
    const teamTask = await (await rest(
        '/rest/v1/tasks?select=id,code&task_type=eq.team&deleted_at=is.null&limit=1')).json()
    taskId = teamTask?.[0]?.id
    if (!taskId) throw new Error('线上没有一张未软删的团队任务 —— 本探针的 ② 无从驱动')

    // 参与者:`trg_task_participants_guard` 要求这名员工有登录账号(上面绑好了)。
    const part = await (await rest('/rest/v1/task_participants', { method: 'POST',
        headers: { Prefer: 'return=representation' },
        body: JSON.stringify({ task_id: taskId, employee_id: empId, added_by: empId }) })).json()
    const partId = part?.[0]?.id
    if (!partId) throw new Error('加不进参与者: ' + JSON.stringify(part).slice(0, 300))

    // ★ 清理按【依赖反序】声明,而且现在【每一步都删得掉】。
    //   ORDER 里没有业务档位,所以用比 REVIEW(10) 更早的数字表达"最先删"。
    planDelete(`/rest/v1/task_history?task_id=eq.${taskId}&changed_by=eq.${empId}`,
        `delete probe participant history on ${taskId}`, 4)
    planDelete(`/rest/v1/task_participants?id=eq.${partId}`, `delete probe participant ${partId}`, 6)
    planDelete(`/rest/v1/employees?id=eq.${empId}`, `delete probe employee ${empId}`, ORDER.EMPLOYEE)
    console.log(`· 参与线上团队任务 ${teamTask[0].code}(不新建任务 —— 见本段注释)`)

    const NODE_TITLE = `ZZ-SMOKE-NODE-${Date.now()}`
    const node = await (await rest('/rest/v1/task_nodes', { method: 'POST',
        headers: { Prefer: 'return=representation' },
        body: JSON.stringify({ task_id: taskId, title: NODE_TITLE, depth: 0, sort_order: 999000 }) })).json()
    nodeId = node?.[0]?.id
    if (!nodeId) throw new Error('建不出探针步骤: ' + JSON.stringify(node).slice(0, 300))
    // 这一行【本来就是要被探针删掉的】,但计划里仍然要有它 ——
    // 探针中途被 SIGKILL 时,它是唯一还认得这行的东西(LEAK-1)。
    planDelete(`/rest/v1/task_nodes?id=eq.${nodeId}`, `delete probe node ${nodeId}`, 2)

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
    await S('Page.enable'); await S('Runtime.enable'); await S('Network.enable')
    await S('Emulation.setDeviceMetricsOverride', { width: 1280, height: 900, deviceScaleFactor: 1, mobile: false })
    await S('Network.setCookies', { cookies: [{ name: cookieName, value: cookieValue,
        domain: 'localhost', path: '/', httpOnly: false, secure: false }] })

    const ev = async (expr) => {
        const r = await S('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true })
        if (r.exceptionDetails) throw new Error(JSON.stringify(r.exceptionDetails).slice(0, 400))
        return r.result.value
    }

    // ★ 注入点:把选择器弄瞎。'blind' 那一格【必须】让每一格都红。
    const SEL = (s) => (FAULT === 'blind' ? '#no-such-thing-at-all' : s)

    const goto = async (path) => {
        await S('Page.navigate', { url: origin + path })
        await sleep(1200)
        // 【等水合收尾】—— 服务端 HTML 上没有 __reactFiber$,水合过的才有。
        for (let i = 0; i < 40; i++) {
            const hydrated = await ev(`(() => {
                const b = document.querySelector('button')
                return !!b && Object.keys(b).some(k => k.startsWith('__react'))
            })()`)
            if (hydrated) return true
            await sleep(250)
        }
        return false
    }

    // 【真的鼠标点】—— el.click() 绕开命中检测,一个被遮住的按钮照样"点得到"。
    const clickReal = async (selector) => {
        const box = await ev(`(() => {
            const el = document.querySelector(${JSON.stringify(selector)})
            if (!el) return null
            el.scrollIntoView({ block: 'center' })
            const r = el.getBoundingClientRect()
            if (r.width === 0 || r.height === 0) return null
            return { x: r.left + r.width / 2, y: r.top + r.height / 2 }
        })()`)
        if (!box) return false
        for (const type of ['mousePressed', 'mouseReleased'])
            await S('Input.dispatchMouseEvent', { type, x: box.x, y: box.y, button: 'left', clickCount: 1 })
        await sleep(500)
        return true
    }

    const dialogState = () => ev(`(() => {
        const d = document.querySelector('[data-confirm-dialog="1"]')
        if (!d) return { open: false }
        const subj = d.querySelector('[data-confirm-subject]')
        return {
            open: true,
            subject: subj ? subj.getAttribute('data-confirm-subject') : null,
            hasReason: !!d.querySelector('[data-confirm-reason="1"]'),
            acceptDisabled: !!d.querySelector('[data-confirm-accept="1"]')?.disabled,
            title: d.querySelector('h2')?.textContent || '',
            body: d.textContent || '',
        }
    })()`)

    console.log(`\n== 探针:确认对话框(BTN-4)${FAULT ? `  · ★ 注入 PROBE_FAULT=${FAULT}` : ''} ==\n`)

    // ════════════════════════════════════════════════════════════════════
    // ① Item 2 —— 全树最后一个原生输入型对话框(fx 撤销牌价)
    // ════════════════════════════════════════════════════════════════════
    console.log('-- ① /finance/fx/[id]/edit —— 那个 window.prompt 的继任者 --')
    const okNav1 = await goto(`/finance/fx/${fxRateId}/edit`)
    probe('D0 水合', okNav1, okNav1 ? '页面水合完成,可以下判词了' : '★ 水合没等到 —— 判词无效,不是"通过"')

    const before1 = await dialogState()
    probe('D1a 反臂', before1.open === false, before1.open ? '★ 还没点就已经有对话框了 —— 断言没有区分力' : '点之前:没有对话框(反臂成立)')

    // 锁到撤销档那一个 —— 这一页今天只有一个,而【今天】不是判据。
    const clicked1 = await clickReal(SEL('button[data-variant="reversal"][aria-haspopup="dialog"]'))
    probe('D1b 点得到', clicked1, clicked1 ? '触发钮被【真的鼠标事件】点到了' : '★ 点不到:选择器没命中,或者按钮零尺寸/被遮住')

    let d1 = await dialogState()
    if (FAULT === 'no-dialog') d1 = { open: false }
    if (FAULT === 'no-subject') d1 = { ...d1, subject: '' }

    probe('D1 对话框打开了', d1.open === true,
        d1.open ? '这一步【第一次】被机器走过 —— 转换前它是 window.prompt,点不到' : '★ 点完之后没有对话框')
    probe('D2 主语点得出名字', !!d1.subject && d1.subject.trim() !== '',
        d1.subject ? `subject = ${JSON.stringify(d1.subject)}` : '★ 主语是空的 —— 它答不出"哪一个"')
    probe('D3 理由框在', d1.hasReason === true,
        d1.hasReason ? '带理由的对话框,替掉了 window.prompt 那一格' : '★ 没有理由输入框')
    probe('D4 空理由时确认钮【不可按】', d1.acceptDisabled === true,
        d1.acceptDisabled ? '一个服务端必然拒绝的动作,没有可提交的控件' : '★ 理由为空却按得下去')

    // 填理由 → 确认钮活过来(这一对是【分得开】的两臂)
    // ★ 找不到输入框时【返回 false,不要抛】—— 一支自己炸掉的探针报的是
    //   "我坏了"(退 2),而这一格要问的是"产品坏没坏"(退 1)。两者必须分得开。
    const filled = await ev(`(() => {
        const i = document.querySelector('[data-confirm-reason="1"]')
        if (!i) return false
        const set = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set
        set.call(i, 'ZZ-SMOKE probe reason')
        i.dispatchEvent(new Event('input', { bubbles: true }))
        return true
    })()`)
    probe('D5a 理由填得进去', filled, filled ? '理由框接受输入' : '★ 没有理由框可填')
    await sleep(300)
    const d1b = await dialogState()
    probe('D5 填了理由之后确认钮【活过来】', d1b.acceptDisabled === false,
        d1b.acceptDisabled === false ? '两臂分得开:空→禁用,非空→可按' : '★ 填了理由仍然按不下去')

    // ★ 不真的确认 —— 撤销一条真牌价是【线上数据】。关掉它,并断言它真的关了。
    await clickReal('[data-confirm-dismiss="1"]')
    const d1c = await dialogState()
    probe('D6 驳回那一侧关得掉', d1c.open === false,
        d1c.open === false ? '取消关闭对话框(没有动线上那条牌价)' : '★ 点了取消,对话框还开着')

    // ════════════════════════════════════════════════════════════════════
    // ② Item 3 —— 那个【此前没有确认步骤】的硬删除
    // ════════════════════════════════════════════════════════════════════
    console.log('\n-- ② /tools/tasks/[id] —— 那个硬删除,现在会问了 --')
    const okNav2 = await goto(`/tools/tasks/${taskId}`)
    probe('T0 水合', okNav2, okNav2 ? '页面水合完成' : '★ 水合没等到 —— 判词无效')

    const before2 = await dialogState()
    probe('T1a 反臂', before2.open === false, before2.open ? '★ 还没点就有对话框' : '点之前:没有对话框(反臂成立)')

    // ★★【选择器必须锁到那一行】★★ 同一页上 TaskHeader 也有一个
    //   aria-haspopup="dialog"(它软删【整张任务】)。取第一个匹配,
    //   这支探针就会去删那张任务 —— 一个把别人的数据删掉的探针,
    //   比一个不存在的探针坏得多。所以按【标题所在的那一行】定位。
    const nodeBtnSel = SEL(`[data-node-row="${nodeId}"] [aria-haspopup="dialog"]`)
    const scoped = await ev(`!!document.querySelector(${JSON.stringify(nodeBtnSel)})`)
    probe('T1s 选择器锁到了那一行', scoped,
        scoped ? '按 data-node-row 定位,不会碰到 TaskHeader 那个删整张任务的钮'
               : '★ 定位不到那一行的删除钮 —— 【不】退回去点第一个匹配')
    const clicked2 = scoped && await clickReal(nodeBtnSel)
    probe('T1b 点得到', clicked2, clicked2 ? '步骤行上的删除钮被真的点到了' : '★ 点不到那个删除钮')

    let d2 = await dialogState()
    if (FAULT === 'no-dialog') d2 = { open: false }
    if (FAULT === 'no-subject') d2 = { ...d2, subject: '' }

    probe('T1 硬删除现在【会问】', d2.open === true,
        d2.open ? '★ 这是本刀最要紧的一格:转换前它【立刻删,不问】' : '★ 删除钮点下去没有确认框 —— 缺陷仍在')
    probe('T2 主语是这个步骤的标题', d2.subject === NODE_TITLE,
        `subject = ${JSON.stringify(d2.subject)}(期望 ${JSON.stringify(NODE_TITLE)})`)
    probe('T3 话说到了【永久】那个份上', /permanent|永久/i.test(d2.body || ''),
        /permanent|永久/i.test(d2.body || '')
            ? '措辞说了它不可撤销 —— 这是一个人【唯一】会被告知这件事的地方'
            : '★ 措辞没说永久:全树只有这一处是硬删除,而确认框没说')
    probe('T4 这一处【不】要理由', d2.hasReason === false,
        d2.hasReason === false ? '硬删除没有理由可记(行都没了)—— 与软删那一族不同' : '★ 意外地有理由框')

    // ★ 真的确认 —— 删的是本探针自己造的那一行。
    const acceptedOk = await clickReal('[data-confirm-accept="1"]')
    probe('T5 确认钮点得到', acceptedOk, acceptedOk ? '确认这一下也是真的鼠标事件' : '★ 确认钮点不到')
    await sleep(2500)

    const left = await (await rest(`/rest/v1/task_nodes?select=id&id=eq.${nodeId}`)).json()
    const gone = Array.isArray(left) && left.length === 0
    probe('T6 确认之后那一行【真的没了】', gone,
        gone ? '端到端:点开 → 读到主语 → 确认 → 行从库里消失' : `★ 行还在(${JSON.stringify(left).slice(0, 120)})`)

    // ════════════════════════════════════════════════════════════════════
    console.log('')
    const passed = results.filter((r) => r.ok).length
    console.log(`== ${results.length} 格:${passed} 通过,${fail.length} 失败 ==`)
    if (fail.length) { console.log('\n红的格子:'); for (const f of fail) console.log('  · ' + f) }
    console.log(`\nCONFIRM_PROBE_EXIT=${fail.length ? 1 : 0}`)
    process.exitCode = fail.length ? 1 : 0
} catch (e) {
    console.error('\n★ 探针自己炸了(这【不是】"产品没问题"):', e.message)
    console.log('\nCONFIRM_PROBE_EXIT=2')
    process.exitCode = 2
} finally {
    try { await runPlan() } catch (e) { console.error('清理没跑干净:', e.message) }
    killChildren()
    try { release() } catch {}
}
