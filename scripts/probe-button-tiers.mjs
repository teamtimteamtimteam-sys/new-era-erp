#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// BTN-1 · 档位探针 —— 「一个人在两页之间来回看,按钮是不是同一个东西」
//
// ★ 它证的三件事,一件都不在服务端看得见 ★
//   L1 · 【几何收敛】同一 (variant,size) 的按钮,在【不同页面之间】
//        高度 / 圆角 / 内边距 / 字重完全一致。这是本刀存在的理由:
//        转换之前同一个"新增"在不同页上是不同的高度和圆角。
//   L2 · 【不靠颜色也分得开】destructive 与 reversal 各有一条左竖条
//        (一实一虚),secondary 是唯一字重 400 的档 —— 三条判据全部
//        【不读颜色】。一个分不出破坏与撤销的界面,把最危险的一格
//        押在一部分人根本用不了的信道上。
//   L3 · 【禁用态读得清】禁用按钮的字/底对比度 ≥ 4.5。
//        原库用 disabled:opacity-50,实测 1.45:1 —— 比它要取代的
//        disabled:bg-gray-400(2.54:1)还差。本仓库还有 9 处只灰不说的
//        提交钮(docs/silent-disable-inventory.md),看不清会让它们更坏。
//
// ★★ 判据【不是】HTTP 200 ★★
//   FIX-2b 的头一版角色探针断言 HTTP===200,而它对着一个正在抛错的页面
//   报了绿 —— App Router 在 RSC 抛之前就把状态码定下来了。UI-1d fu2 是
//   同一个坑的第一次。所以这里【先证这一页真的画出来了】:
//   要求页面上至少有一个 [data-slot="button"],且没有 Next 的错误覆盖层。
//   一页都没画出来 → 直接红,不进几何比对。
//
// 用法:node scripts/probe-button-tiers.mjs
// 退出码:0 = 全绿;1 = 有断言红
// 需要:.next/BUILD_ID(跑在生产构建上,不是 dev)
// ════════════════════════════════════════════════════════════════════════════
import { spawn } from 'node:child_process'
import { readFileSync, existsSync } from 'node:fs'
import { join } from 'node:path'
import { createConnection } from 'node:net'
import { acquireOrExit, release } from './liveLock.mjs'
import { openPlan, planDelete, ephemeralGrantBody, runPlan, reapStalePlans, installExitHooks, ORDER } from './ephemeral.mjs'

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

const results = []; const fail = []
function probe(id, ok, detail) { results.push({ id, ok, detail }); if (!ok) fail.push(`${id}: ${detail}`)
    console.log(`  ${ok ? '✓' : '✗'} ${id}  ${detail}`) }

const waitPort = (p, ms) => new Promise((res) => { const t0 = Date.now()
    ;(function tick() { const s = createConnection({ port: p, host: '127.0.0.1' })
        s.on('connect', () => { s.destroy(); res(true) })
        s.on('error', () => { s.destroy(); Date.now() - t0 > ms ? res(false) : setTimeout(tick, 300) }) })() })

// ── 页面清单:本刀真的改过的页,跨模块取样(finance / hr / sales / purchasing / me)
// ★ 页面清单只放【本刀真的改过的路由】。第一版放了 /sales/customers 与
//   /settings/roles —— 那两页一个库按钮都没有(改的是它们的 [id]/edit 子页),
//   于是 RENDER 断言当场变红。**那是清单错了,不是产品坏了** —— 而这正是
//   RENDER 那条断言要拦的东西:一页没画出按钮,就不该拿它去比几何。
const PAGES = [
    '/me',                    // primary + destructive(头像)
    '/hr/claims',             // secondary(筛选)
    '/hr/leave', '/hr/leave/calendar', '/hr/leave/grants',
    '/hr/reviews', '/hr/reviews/cycles',
    '/finance/revaluation',   // secondary + 禁用态 primary
    '/finance/company',       // primary + destructive
    '/finance/settings',      // primary + reversal(解锁)
    '/finance/assets', '/finance/close', '/finance/journal/new',
    '/materials/new', '/suppliers/new', '/sales/customers/new',
    '/purchasing/payment-terms/new', '/settings/roles/new',
    // ★ BTN-2(2026-09-06):加这两页【只是为了让 link/inline 这一对被看见】。
    //   BTN-2 给库加了 `size="inline"`(行内链接态),而本探针当时取样的 18 页
    //   一个都没有渲染到它 —— **一个新档位落地,而唯一能量它几何的探针看不见它**,
    //   正是 §10.5 自己写下的那句警告。这两页的「加一行 / 加一个投入」是
    //   无条件渲染的 link/inline,所以 L1 拿得到 ≥2 处去比。
    '/purchasing/orders/new', '/operation/processing/new',
    // ★ BTN-3(2026-09-06):这四页是为了让本刀落地的三对 (variant,size) 被【求值】。
    //   BTN-2 已经付过一次这笔账(它改的 20 个文件一页都不在取样里),而本刀新加的
    //   是三个【组合】—— destructive/inline · reversal/inline · secondary/inline ——
    //   探针按 (variant,size) 分组,所以组合是新的,分组逻辑不必改,但【取样必须够到】。
    '/hr/leave/holidays',      // destructive/inline(逐行的"删除")
    '/purchasing/licences',    // destructive/inline(逐行的"删除")+ link/inline
    '/settings/dictionaries',  // secondary/xs(逐行的"编辑" / "重新启用")
    '/logistics/lanes',        // default/sm + secondary/sm + destructive/inline
    // ★ BTN-3b(2026-09-06):这是【第三次】为同一个洞补取样,而这一次的规模说明了问题。
    //   BTN-2 改的 20 个文件一页都不在取样里;BTN-3 又补了五页;本刀开工前实测:
    //   **那 91 个按钮住在 44 个目录里,而其中 32 个目录一条路由都不在这张清单上。**
    //   一支只走 24 页的探针,对着一把改了 54 个文件的刀,绿得毫无意义。
    //   下面每一页都【渲染本刀转过的按钮】,按 (variant,size) 分组去够 REQUIRED_GROUPS。
    '/notifications',              // secondary/xs(标记已读)
    '/settings/deleted',           // secondary/sm(筛选)
    '/finance/month-end',          // secondary/sm(筛选;它的文案键是 reviews.filter,已立案)
    '/hr/kpi/score',               // secondary/sm(选月)+ secondary/xs(逐行补算)
    '/finance/payroll-payments',   // default/sm(支付所选)
    '/finance/processing-costs',   // default/sm(汇出 / 冲销计提)
    '/hr/attendance',              // default/sm(开考勤期)
    '/finance/cash-forecast',      // secondary/sm(加一行)+ default/default(保存)
    '/settings/import',            // default/default(预览)
    '/stocktakes',                 // default/default(新建盘点)
    '/tools/tasks',                // default/default(新建任务)
    '/tools/converter',            // default/default(换算)—— 也是唯一一处连 style 一起去掉的
    // ★★【这四条【试过、量过、拿掉了】,连同理由 —— BTN-3 的先例:
    //     「那是清单错了,不是产品坏了」,而 RENDER 那条断言正是为此存在】★★
    //   第一版把它们放了进去,五条 RENDER 当场变红。逐条查明:
    //   · /settings/roles/{id}/edit —— ★【那条路由不存在】,真实路由是
    //     /settings/roles/{id}(app/settings/roles/[id]/page.tsx)。已在 IDSRC 改正。
    //   · /sales/commissions —— 表单在 /new 与 /[id]/edit,列表页一个库按钮都没有。已改正。
    //   · /tools/pricing/calculator —— 那个「复制明细」住在 `{res && (…)}` 里:
    //     **要先算一次才存在**,一次页面加载永远看不到(与 §10.5 的 /settings/accounts 同类)。
    //   · /operation/handovers —— 实测 shift_handovers 表【0 行】,逐行的确认钮无从渲染。
    //   · /finance/claims —— 实测 medical_claims 表【0 行】,同上。
    //   · /sales/commissions/new —— ★ 这一条最值得读:路由是对的、表单也在,而
    //     `CommissionForm:67` 写着 `if (agents.length === 0) return (…)` ——
    //     一个【不含任何按钮】的提前返回。而实测 counterparty_type=service_vendor
    //     的供应商【0 行】,于是那个提交钮在今天的线上【必然】画不出来。
    //     「路由对、组件在、按钮仍然不存在」是这一族里最容易被误读成产品缺陷的一种。
    //   ☞ 后三条【不是取样偷懒,是线上没有能渲染它的数据/状态】,
    //     归 docs/manual-walk-list.md 由人走。
]

// ★★ BTN-3:本刀落地的组合,必须【真的被求值】—— 不是"没红"就算数 ★★
//   L1 对着 list.length < 2 的组是 `continue`,**一声不吭**。于是一个新档位可以
//   完整地落地、被这支探针整支跑过、而它的那条断言【从来没有被求值】——
//   而一条没被求值的断言与一条绿掉的断言,在退出码上仍然是同一个字节
//   (AGENTS.md「★★★ 覆盖率本身必须是一条断言」)。
//   所以这里把"被求值"本身写成断言:下面每一个组合都必须在取样里出现 ≥2 处,
//   否则整支红,并且点名是哪一个组合没被看见。
// ★ `need` 是【L1 能不能比】的门槛(跨页全等要两处),`1` 是【有没有被渲染到】。
//   reversal/inline 只能到 1,而那不是取样偷懒 —— 见下面 IDSRC 里写明的原因。
//   它由 `L2 行内两档同几何` 兜住,那条用一处实例就成立。
const REQUIRED_GROUPS = [
    { k: 'destructive/inline', need: 2 },  // 红色链接态 → 破坏档(实线左竖条),BTN-3 Item 2
    { k: 'reversal/inline',    need: 1,    // 撤销档的行内形态,BTN-3 Item 1
      note: '线上没有能渲染出两处的数据(见 IDSRC 注释)—— L1 因此比不了,由 L2 行内两档同几何 兜住' },
    // ── ★ BTN-3b(2026-09-06):本刀落地的【盒子形态】组合 ────────────────────
    //   BTN-3 证的三对全是行内档。本刀转的 74 处里有 71 处是盒子,而盒子形态的
    //   (variant,size) 此前**一个都没有被 REQUIRED_GROUPS 守着** —— 它们只是碰巧
    //   出现在取样里,于是"没被求值"与"绿"在退出码上又是同一个字节。
    { k: 'default/default',    need: 2 },  // 新建 / 提交(导入 · 盘点 · 任务 · 佣金 · 换算)
    { k: 'secondary/default',  need: 2 },  // 与之并排的取消 / 再来一份
    { k: 'default/sm',         need: 2 },  // 批准 · 支付 · 开期 · 开评估周期
    { k: 'secondary/sm',       need: 2 },  // 筛选 · 驳回 · 预览 · 对话框取消
    { k: 'secondary/xs',       need: 2 },  // 逐行的编辑 / 标记已读
    // ── ★ 撤销档的盒子形态:两处调用点,而线上只渲染得出一处 ──────────────
    //   `/settings/roles/{id}/edit` 的 Delete(其实是 softDeleteRole)渲染得出;
    //   `/hr/leave/{id}` 的 Cancel(其实是补一条等额 release)渲染不出 ——
    //   ★ 实测:leave_requests 表里 pending 与 approved 【各 0 行】,
    //     也就是"线上没有能渲染它的数据",与 BTN-3 的 reversal/inline 同一个理由。
    { k: 'reversal/sm',        need: 1,
      note: '两个调用点,而 leave_requests 的 pending/approved 各 0 行 —— 见 IDSRC roles;由 L2b 盒子两档同几何 兜住' },
    { k: 'reversal/xs',        need: 1,
      note: '只有一个调用点(客户联系人的软删除),天然到不了 2;由 L2b 兜住' },
    // ★★【destructive/sm 【故意】不在这张表上,而它不在的理由必须被读到】★★
    //   它只有一个调用点(hr/reviews 的 Void,void_review),而**线上
    //   performance_reviews 一行都没有** —— 实测 `status=neq.void` 返回 []。
    //   于是它【任何取样都渲染不出来】,写进 REQUIRED_GROUPS 只会让这支探针
    //   永久变红,而那是把"我看不见"伪装成"产品坏了"。
    //   ☞ 处置与 BTN-3 对 reversal/inline 的处置同一条:**不降门槛,换一条
    //     更强、而且不需要线上数据的断言** —— 见下面 L4(库源码层的左竖条判据)。
    //   ★ 它在收尾里【连同理由一起印出来】,不是悄悄省掉的。
    { k: 'secondary/inline',   need: 2 },  // 草稿行的"移除" —— 什么都还没存过,红色在这里是假话
    { k: 'link/inline',        need: 2 },  // BTN-2 的,顺带守住不回退
]
// 本刀声明为"渲染不出、由 L4 承担"的组合,收尾时逐条印出来
const UNRENDERABLE = [
    { k: 'destructive/sm', site: 'app/hr/reviews/ReviewActions.tsx:122',
      why: '★ 说准一点:【这个调用点】走不到 —— 线上 performance_reviews 0 行'
         + '(status=neq.void 返回空),那一页画不出这个钮。'
         + '而【这个组合】是证过的:L2b 拿它与 reversal/sm 比过同几何(树里别处的调用点渲染了它)。'
         + '☞ 缺的是"本刀这一处被求值过",不是"destructive/sm 这一档没被证过" —— 两句话不一样,别混着说' },
    { k: 'default/xs', site: '5 处:MaintenancePanel:466 · AssetActions:143 · NodeTree:81 · NodeTree:144 · RetentionPanel:176',
      why: '五处【无一】在页面加载时存在:前四处要先点开一个面板/进入编辑态,'
         + 'RetentionPanel 那处要一张带质保金的采购单(实测该表在 PostgREST 里取不到)。'
         + '★ xs 这一号的盒子几何由 secondary/xs 跨页证着(/settings/dictionaries 34 处),'
         + 'default 与 secondary 的差别在底与字重、不在盒子 —— 所以缺的是"这一格被渲染过",不是几何' },
]
// ★【为什么 /settings/accounts 不在这张清单上 —— 它不是坏的,是【看不见的】】
//   那一页的 <Button variant="default"> 住在 `open` 这个 state 的分支里:
//   要先点一下"建账号"把面板展开,按钮才存在。**一次页面加载看不到它。**
//   同理 /purchasing/payment-terms:表单挂在 /new 与 /[id]/edit,不在列表页上。
//   这一条与委托书里"覆盖物"那一节是同一件事:**按页枚举会漏掉只在
//   某个状态下才存在的东西**。这类按钮由人走(docs/manual-walk-list.md)。

let server, chrome, accountId
function killChildren() {
    try { if (chrome?.pid) process.kill(-chrome.pid) } catch {}
    try { if (server?.pid) process.kill(-server.pid) } catch {}
}
// ★ 这一支【从前一个信号处理器都没有】—— 被 Ctrl-C 或管道断掉时,
//   连那个只删账号的 finally 都跑不到。退出从此归 ephemeral 管。
installExitHooks({ onFinish: () => { killChildren(); try { release() } catch {} } })
try {
    if (!existsSync(join(ROOT, '.next/BUILD_ID')))
        throw new Error('.next/BUILD_ID 不在 —— 这一支跑在【生产构建】上。先 npm run build。')
    acquireOrExit('probe-button-tiers', { ownExit: false })
    openPlan('scripts/probe-button-tiers.mjs')
    await reapStalePlans()

    const email = `btnprobe-${Date.now()}@test.local`
    const cu = await (await rest('/auth/v1/admin/users', { method: 'POST',
        body: JSON.stringify({ email, password: 'btn-probe-1', email_confirm: true }) })).json()
    accountId = cu.id
    if (!accountId) throw new Error('账号建不出来: ' + JSON.stringify(cu).slice(0, 300))
    // ★★ LEAK-1(2026-09-06):这一支是那 28 条幽灵授权的【头号产地】,而它
    //    【不是】被杀掉才漏的 —— 原来的 finally 只删账号、**一个字都没提 user_roles**
    //    (整份文件里 user_roles 只出现过一次,就是下面这条 INSERT)。
    //    于是它【每一次跑完都漏一条】:退出码 0、没有人被杀、没有任何东西报红。
    //    先删授权再删账号,顺序反了留下的正是一条认不到人的授权。
    planDelete(`/rest/v1/user_roles?user_id=eq.${accountId}`, `revoke btnprobe grant ${accountId}`, ORDER.GRANT)
    planDelete(`/auth/v1/admin/users/${accountId}`, `delete btnprobe account ${accountId}`, ORDER.ACCOUNT)
    const roles = await (await rest('/rest/v1/roles?select=id&code=eq.admin')).json()
    await rest('/rest/v1/user_roles', { method: 'POST',
        body: JSON.stringify(ephemeralGrantBody(accountId, roles[0].id)) })
    const sess = await (await fetch(URL_ + '/auth/v1/token?grant_type=password', { method: 'POST',
        headers: { apikey: ANON, 'Content-Type': 'application/json' },
        body: JSON.stringify({ email, password: 'btn-probe-1' }) })).json()
    if (!sess?.access_token) throw new Error('登录失败')
    const cookieName = 'sb-' + URL_.split('//')[1].split('.')[0] + '-auth-token'
    const cookieValue = 'base64-' + Buffer.from(JSON.stringify(sess)).toString('base64url')

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
    const evalJs = async (expr) => {
        const r = await S('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true })
        if (r.exceptionDetails) throw new Error(JSON.stringify(r.exceptionDetails).slice(0, 300))
        return r.result.value
    }

    // 采集脚本:把每个库按钮的几何与用色读回来
    const COLLECT = `(() => {
      const L = h => { const c = h.map(v => v/255).map(v => v <= .03928 ? v/12.92 : Math.pow((v+.055)/1.055, 2.4));
        return .2126*c[0] + .7152*c[1] + .0722*c[2] };
      const parse = s => (s.match(/\\d+(\\.\\d+)?/g) || []).slice(0,3).map(Number);
      const over = (fg, a, bg) => fg.map((v,i) => v*a + bg[i]*(1-a));
      const bgOf = el => { let n = el; while (n && n !== document.documentElement) {
          const c = getComputedStyle(n).backgroundColor; const p = parse(c);
          const al = /rgba/.test(c) ? Number(c.split(',')[3]) : 1;
          if (al > .95 && p.length === 3) return p; n = n.parentElement } return [255,255,255] };
      const err = !!document.querySelector('nextjs-portal, [data-nextjs-dialog]');
      const out = [];
      for (const el of document.querySelectorAll('[data-slot="button"]')) {
        const cs = getComputedStyle(el); const r = el.getBoundingClientRect();
        if (r.width === 0 && r.height === 0) continue;
        const before = getComputedStyle(el, '::before');
        const fg = parse(cs.color); const fa = /rgba/.test(cs.color) ? Number(cs.color.split(',')[3]) : 1;
        const ownBg = parse(cs.backgroundColor);
        const ownA = /rgba/.test(cs.backgroundColor) ? Number(cs.backgroundColor.split(',')[3]) : 1;
        const under = bgOf(el.parentElement || document.body);
        let effBg = ownA > .01 ? over(ownBg, ownA, under) : under;
        let effFg = over(fg, fa, effBg);
        // ★★【element opacity 必须算进去 —— 这道判据【第一版是假的】★★
        //   getComputedStyle().color / .backgroundColor 报的是【没有褪色的】值:
        //   把 disabled:opacity-50 注回去之后,这条断言照样报 4.53:1 绿灯。
        //   实测发现的(故障注入),不是推的 —— 委托书两次点名的正是这个坑:
        //   「一道判据可以对着一个坏掉的页面报绿」。opacity 是把整个元素
        //   (底 + 字)作为一组合成到父层上,所以底和字【各自】按同一个 o 合成:
        //       final = o × group + (1 − o) × under
        let o = 1, n = el;
        while (n && n !== document.documentElement) { o *= Number(getComputedStyle(n).opacity || 1); n = n.parentElement }
        if (o < .999) { effBg = over(effBg, o, under); effFg = over(effFg, o, under) }
        const l1 = L(effFg), l2 = L(effBg);
        const cr = (Math.max(l1,l2)+.05)/(Math.min(l1,l2)+.05);
        out.push({ variant: el.dataset.variant, size: el.dataset.size,
          h: Math.round(r.height), radius: cs.borderTopLeftRadius, padL: cs.paddingLeft, padR: cs.paddingRight,
          weight: cs.fontWeight, disabled: el.disabled === true,
          rule: before.content !== 'none' && before.width !== 'auto' ? before.width : null,
          ruleImg: before.backgroundImage !== 'none',
          cr: Math.round(cr*100)/100, label: (el.textContent||'').trim().slice(0,24) });
      }
      return JSON.stringify({ err, n: out.length, out });
    })()`

    // ★★ BTN-3:两条【动态】路由,因为 reversal/inline 在这棵树上【没有静态落点】★★
    //   六个撤销档调用点全部住在 [id] 路由里。取样清单原本只收静态路径,于是
    //   COVER reversal/inline 当场报红 —— **而那正是它被加进来要说的话**:
    //   「这一档没有被求值」,不是「这一档是绿的」。
    //   处置不是把断言删掉,是把取样够到它:id 从线上现取(与冒烟同一个办法),
    //   ★ 取不到就【报红】,不是静默跳过 —— 一个取样不到的页面与一个没有缺陷的
    //     页面,在退出码上又会是同一个字节。
    // ★ 每一条各带自己的查询,而不是共用一句 `select=id&limit=1` —— 第一版就是那样写的,
    //   于是它取到一行 **软删除掉的** task,页面 404、`RENDER` 当场变红。
    //   **"取一行"与"取一行【这个页面画得出来的】"不是同一个问题**,而冒烟的
    //   id 解析器早就为同一件事付过账(它维护着一张 27 张表的软删除清单)。
    const IDSRC = [
        { name: 'fx_rates',
          q: '/rest/v1/fx_rates?select=id&limit=1',
          pick: (r) => r?.id,
          mk: (id) => `/finance/fx/${id}/edit`,
          why: 'reversal/inline —— 那处写着 Delete 而做的是带理由的软删除' },
        // ★★【为什么这里【没有】第二条 —— 这棵树上取不到】★★
        //   reversal/inline 的另外两处(Unmatch · Restore)住在对账台上,而那一页
        //   **只对【尚未对完】的对账单渲染**(status==='reconciled' 时它 redirect 走)。
        //   实测(BTN-3):全库两张对账单 —— 一张 open 但【已软删除】且两行都是
        //   unmatched(画不出这两个钮),另一张有 matched+ignored 行但**已经对完**
        //   (于是重定向,一个库按钮都渲染不出来)。
        //   ☞ **所以这不是取样清单懒,是【线上没有能渲染它的数据】。**
        //   处置见下面的 `L2 行内两档同几何` —— 那条断言用一处实例就成立,
        //   而且它断的正是 §10.1 ③ 那条设计律,比跨页全等更强。
        // ── ★ BTN-3b(2026-09-06)加的四条,每一条都各带自己的查询 ────────────
        //   照 BTN-3 那条教训:**「取一行」与「取一行【这一页画得出来的】」
        //   不是同一个问题**,所以没有一条是 `select=id&limit=1`。
        { name: 'roles',
          q: '/rest/v1/roles?select=id&deleted_at=is.null&is_system=eq.false&limit=1',
          pick: (r) => r?.id,
          mk: (id) => `/settings/roles/${id}`,   // ★ 不是 /edit —— 那条路由不存在,第一版据此报了一次假红
          why: 'reversal/sm —— 那处写着 Delete 而做的是 softDeleteRole(deleted_at + is_active=false)。'
             + '★ is_system=false:系统角色由 guard_system_role 挡着,那一页画不出这个钮' },
        { name: 'customer_with_contact',
          q: '/rest/v1/counterparty_contacts?select=customer_id&deleted_at=is.null&customer_id=not.is.null&limit=1',
          pick: (r) => r?.customer_id,
          mk: (id) => `/sales/customers/${id}`,
          why: 'reversal/xs —— 逐行的"移除联系人",实为 soft_delete_counterparty_contact。'
             + '★ 必须取【有活联系人的】那个客户,否则那张表一行都不画' },
        { name: 'task_with_nodes',
          q: '/rest/v1/task_nodes?select=task_id&limit=1',
          pick: (r) => r?.task_id,
          mk: (id) => `/tools/tasks/${id}`,
          why: 'destructive/inline + link/inline —— ★ 本刀的头号发现就住在这一页:'
             + 'NodeTree 的"移除"是 task_nodes.delete(),一次【硬删除】。'
             + '★ 必须取【有步骤的】那个任务,空任务画不出 NodeTree 的行' },
        { name: 'output_batch',
          q: '/rest/v1/output_batches?select=id&deleted_at=is.null&limit=1',
          pick: (r) => r?.id,
          mk: (id) => `/output/${id}/assays/new`,
          why: 'secondary/default —— 那张表单的「只记录」提交钮是无条件渲染的。'
             + '★ secondary/default 的另外几个调用点(许可证取消 · 导入再来一份 · 任务弹窗取消)'
             + '全都藏在某个 state 分支里,一次页面加载都到不了' },
        { name: 'output_batch_2',
          q: '/rest/v1/output_batches?select=id&deleted_at=is.null&limit=1&offset=1',
          pick: (r) => r?.id,
          mk: (id) => `/output/${id}/assays/new`,
          why: '★ secondary/default 的【第二处】—— L1 要跨页比几何就得有两处,而这一档'
             + '其余六个调用点全在 state 分支里。取【第二个】产出批次,于是两处住在'
             + '两条不同的 URL 上,是真的跨页,不是把门槛降到 1' },
        { name: 'sales_order_open',
          q: '/rest/v1/sales_orders?select=id&deleted_at=is.null&status=eq.draft&limit=1',
          pick: (r) => r?.id,
          mk: (id) => `/sales/orders/${id}`,
          why: 'TransitionPanel 的运行期档位(cancelled → destructive,其余 secondary)。'
             + '★ 必须取 draft:cancelled/shipped 的单子 nextStates 为空,一个钮都不画' },
    ]
    const dynamic = []
    for (const s of IDSRC) {
        let id = null
        try {
            const rows = await (await rest(s.q)).json()
            id = Array.isArray(rows) && rows[0] ? s.pick(rows[0]) : null
        } catch { id = null }
        probe(`IDSRC ${s.name}`, !!id, id ? `取到 id ${String(id).slice(0, 8)}… · ${s.why}` :
            `线上取不到符合条件的行 —— 这一页因此【没有被取样】,而不是它没有缺陷`)
        if (id) dynamic.push(s.mk(id))
    }

    const all = []
    console.log('')
    for (const path of [...PAGES, ...dynamic]) {
        await S('Page.navigate', { url: origin + path })
        await sleep(1400)
        await evalJs(`new Promise(r => { const t0 = Date.now(); (function w(){
            if (document.querySelector('[data-slot="button"]') || Date.now()-t0 > 6000) return r(1); setTimeout(w, 100) })() })`)
        const raw = await evalJs(COLLECT)
        const d = JSON.parse(raw)
        // ★ 先证这一页真的画出来了 —— 不是 HTTP 200,是【屏幕上有库按钮且没有错误覆盖层】
        probe(`RENDER ${path}`, !d.err && d.n > 0, d.err ? '错误覆盖层在' : `${d.n} 个库按钮`)
        if (!d.err && d.n > 0) all.push(...d.out.map(o => ({ ...o, path })))
    }

    console.log('')
    // ── L1 · 同一 (variant,size) 跨页几何一致 ───────────────────────────────
    const groups = new Map()
    for (const b of all) { const k = `${b.variant}/${b.size}`; if (!groups.has(k)) groups.set(k, []); groups.get(k).push(b) }
    // ★ BTN-3:先证【它被看见了】,再谈几何。一个数不出来的组是一条没被求值的断言。
    for (const { k, need, note } of REQUIRED_GROUPS) {
        const list = groups.get(k) ?? []
        const pages = [...new Set(list.map(b => b.path))]
        probe(`COVER ${k}`, list.length >= need,
            list.length >= need
                ? `取样命中 ${list.length} 处 / ${pages.length} 页`
                  + (need < 2 ? `(门槛 ${need}:${note})` : '')
                : `取样只命中 ${list.length} 处(要 ${need})—— L1 会【静默跳过】这一组,`
                  + `所以这一档【没有被求值】。给 PAGES 补一页渲染它的路由。`)
    }

    for (const [k, list] of groups) {
        if (list.length < 2) continue
        // ★★【BTN-3b:行内档不比高度 —— 这条法则 BTN-3 已经写下,只是没有写进 L1】★★
        //   BTN-3 在 L2 那条里量出来并写清楚了:`size="inline"` 就是 `h-auto`,
        //   **行内档的高度按定义等于它周围那行字的高度** —— 18 来自 text-xs 的
        //   表格单元格,22 来自 text-sm 的正文。它当时只把这条应用到 L2 上,
        //   而 L1 照旧把 h 比进去 —— 那没有立刻变红,**只是因为当时的取样里
        //   destructive/inline 两处都住在 text-xs 的表格里**。
        //   本刀把取样铺到 /tools/tasks/{id}(正文,text-sm)之后,L1 当场两种几何。
        //   ☞ **这不是回归,是 L1 一直在问一个 BTN-3 已经判定不该问的问题,
        //     而旧取样恰好让它答对了。** 把它比错的东西拿掉,不是把断言放松。
        const inline = k.endsWith('/inline')
        const sig = b => inline
            ? `r=${b.radius} pl=${b.padL} pr=${b.padR} w=${b.weight}`
            : `h=${b.h} r=${b.radius} pl=${b.padL} pr=${b.padR} w=${b.weight}`
        const uniq = [...new Set(list.map(sig))]
        const pages = [...new Set(list.map(b => b.path))]
        probe(`L1 ${k}`, uniq.length === 1,
            uniq.length === 1 ? `${list.length} 处 / ${pages.length} 页 全等 · ${uniq[0]}`
                              : `${uniq.length} 种几何:${uniq.join(' | ')}`)
    }

    // ── L2 · 不靠颜色的区分 ────────────────────────────────────────────────
    const enabled = all.filter(b => !b.disabled)
    const dest = enabled.filter(b => b.variant === 'destructive')
    const rev  = enabled.filter(b => b.variant === 'reversal')
    const sec  = enabled.filter(b => b.variant === 'secondary')
    const def  = enabled.filter(b => b.variant === 'default')
    if (dest.length) probe('L2 destructive 有左竖条', dest.every(b => b.rule), `${dest.length} 处`)
    if (rev.length)  probe('L2 reversal 左竖条是虚线', rev.every(b => b.rule && b.ruleImg), `${rev.length} 处`)
    if (dest.length && rev.length)
        probe('L2 实线 vs 虚线可分', dest.every(b => !b.ruleImg) && rev.every(b => b.ruleImg), '破坏=实心填充,撤销=重复渐变')

    // ── ★ BTN-3:行内的两个档【必须是同一处几何,一实一虚】(§10.1 ③)★ ──────
    //   这条比 L1 的跨页全等更强,而且【一处实例就成立】—— 它断的是设计律本身:
    //   破坏与撤销在行内只剩竖条这一条不经过颜色的判据,而竖条要分得开,
    //   两者的盒子必须先长得一模一样。**reversal/inline 在这棵树上取不到第二处,
    //   所以它的几何由这一条来证,不是由 L1。**
    // ★★【高度【不】进这条判据 —— 而这是第一版量出来才想清楚的】★★
    //   第一版把 h 也比进去,当场报红:destructive h=18 vs reversal h=22。
    //   查下去两边【都没错】:`size="inline"` 写的就是 `h-auto`,**行内档的高度
    //   按定义等于它周围那行字的高度** —— 18 来自 text-xs 的表格单元格,
    //   22 来自 text-sm 的正文。把它比进来,等于要求"句子里的按钮和表格里的按钮
    //   一样高",而那恰恰是行内档【不该】做的事(它要贴着上下文,不是贴着别的按钮)。
    //   ☞ 所以这条只比【库真正控制的那几样】:圆角 · 左右内边距 · 字重。
    //     这不是把断言放松,是把它说准 —— 一条比错了东西的断言,红也没有意义。
    const sig = (b) => `r=${b.radius} pl=${b.padL} pr=${b.padR} w=${b.weight}`
    const di = all.filter(b => b.variant === 'destructive' && b.size === 'inline')
    const ri = all.filter(b => b.variant === 'reversal' && b.size === 'inline')
    if (di.length && ri.length) {
        const ds = [...new Set(di.map(sig))], rs = [...new Set(ri.map(sig))]
        const same = ds.length === 1 && rs.length === 1 && ds[0] === rs[0]
        probe('L2 行内两档同几何(destructive/inline vs reversal/inline)', same,
            same ? `同一处几何 · ${ds[0]} —— 只差实线/虚线(高度按定义随上下文,不比)`
                 : `几何不同:destructive ${ds.join(' | ')}  ≠  reversal ${rs.join(' | ')}`)
    } else {
        probe('L2 行内两档同几何(destructive/inline vs reversal/inline)', false,
            `取样里 destructive/inline ${di.length} 处、reversal/inline ${ri.length} 处 —— 有一边是 0,这一条【没有被求值】`)
    }
    if (sec.length)  probe('L2 secondary 字重 400', sec.every(b => b.weight === '400'), `${sec.length} 处`)
    if (def.length)  probe('L2 default 字重 500', def.every(b => b.weight === '500'), `${def.length} 处`)

    // ── ★ BTN-3b · L2b:【盒子形态】的两个档也必须同几何,一实一虚 ────────────
    //   与 L2 行内那条同一条设计律(§10.1 ③),只是换到有底有边的盒子上。
    //   本刀把 destructive 与 reversal 第一次同时铺到 sm/xs 上,而这两个档在盒子里
    //   仍然只有【左竖条】这一条不经过颜色的判据 —— 竖条要分得开,盒子得先一样。
    //   ★ 它对【任何一处实例】都成立,所以 reversal/sm 只渲染得出一处也证得了。
    for (const sz of ['default', 'sm', 'xs']) {
        const d = all.filter(b => b.variant === 'destructive' && b.size === sz)
        const r = all.filter(b => b.variant === 'reversal' && b.size === sz)
        if (!d.length || !r.length) continue      // 这一档这一号本次没同时取到,交给 L4
        const ds = [...new Set(d.map(b => `h=${b.h} r=${b.radius} pl=${b.padL} pr=${b.padR}`))]
        const rs = [...new Set(r.map(b => `h=${b.h} r=${b.radius} pl=${b.padL} pr=${b.padR}`))]
        const same = ds.length === 1 && rs.length === 1 && ds[0] === rs[0]
        probe(`L2b 盒子两档同几何(destructive/${sz} vs reversal/${sz})`, same,
            same ? `同一处几何 · ${ds[0]} —— 只差实线/虚线`
                 : `几何不同:destructive ${ds.join(' | ')}  ≠  reversal ${rs.join(' | ')}`)
    }

    // ── ★★ BTN-3b · L4:一条【不需要线上数据】的左竖条判据 ★★ ────────────────
    //   为什么非要有它:destructive/sm 只有一个调用点,而线上 performance_reviews
    //   是 0 行 —— **没有任何取样能渲染它**。BTN-3 立过的规矩是「不许把
    //   『线上没有数据』写成『这一档是绿的』」,而它给的处置是【换一条更强的断言】,
    //   不是降门槛。这里照办:去问【库源码】,而不是问某一页。
    //
    //   它断的正是 §10.1 ③ 那条设计律本身,而且是 BTN-3 在行内档上真的踩到过的
    //   那个失败形状:`size` 的内边距把 `pl-3.5` 压掉,竖条于是画在字底下。
    //   ★ 所以它问的不是"类名在不在",是"有没有哪一条 compoundVariant 把这两个
    //     档的左竖条几何拿掉了,而没有另外补一条回来"。
    {
        const src = readFileSync(join(ROOT, 'app/components/ui/button.tsx'), 'utf8')
        // ★★【这个 helper 的第一版是【假红】的,而那件事本身值得留下来】★★
        //   第一版用 `indexOf('\n        ')`(8 空格)找下一个键 —— 而值那一行
        //   缩进 10 空格,**8 空格是它的前缀**,于是 `j` 当场落在值的第一行上,
        //   `grab()` 返回的是 `"\n        destructive:"`,**一个类名都没有**。
        //   三条 L4 于是全部报红,而库里那三样【一样不缺】。
        //   ☞ 与 AGENTS.md「一次没有咬人的注入是信息」是同一条的反面:
        //     **一条看不见那个性质的断言,红和绿都不是证据。**
        //   现在按【恰好 8 空格 + 一个非空格】切,把值整段包进来。
        const grab = (name) => {
            const re = new RegExp(`\\n {8}${name}:`)
            const m = re.exec(src)
            if (!m) return ''
            const rest = src.slice(m.index + m[0].length)
            const nxt = /\n {8}\S/.exec(rest)
            return rest.slice(0, nxt ? nxt.index : rest.length)
        }
        const dv = grab('destructive'), rv = grab('reversal')
        const bar = (s) => /before:w-\[3px\]/.test(s) && /before:left-0/.test(s) && /pl-3\.5/.test(s)
        probe('L4 destructive 在库源码里带 3px 左竖条 + 让位内边距', bar(dv),
            bar(dv) ? 'before:w-[3px] · before:left-0 · pl-3.5 三者都在'
                    : '缺了其中一样 —— 破坏档在盒子形态下会失去它唯一的非颜色判据')
        probe('L4 reversal 在库源码里带 3px 左竖条 + 让位内边距', bar(rv),
            bar(rv) ? 'before:w-[3px] · before:left-0 · pl-3.5 三者都在'
                    : '缺了其中一样 —— 撤销档在盒子形态下会失去它唯一的非颜色判据')
        // 一实一虚:destructive 是纯色填充,reversal 是重复渐变
        const solid  = /before:bg-destructive-text/.test(dv)
        const dashed = /repeating-linear-gradient/.test(rv)
        probe('L4 一实一虚在库源码里分得开', solid && dashed,
            solid && dashed ? 'destructive=纯色填充,reversal=重复渐变(虚线)'
                            : `destructive 纯色 ${solid} · reversal 虚线 ${dashed}`)
        // ★ 没有任何 size 的 compoundVariant 把这两个档的竖条几何拿掉
        //   （行内那三对是【保留】竖条、只丢底与描边的,所以它们不该被这条抓住）
        const cvs = src.slice(src.indexOf('compoundVariants'))
        const killsBar = /variant:\s*"(destructive|reversal)"[\s\S]{0,400}?before:hidden/.test(cvs)
        probe('L4 没有 compoundVariant 抹掉这两个档的左竖条', !killsBar,
            killsBar ? '★ 有一条 compoundVariant 把左竖条隐藏了 —— 那一档从此只剩颜色可分'
                     : '三对行内 compoundVariant 保留竖条、只丢底与描边(BTN-3 §13.4)')
    }

    // ★ 声明为"线上渲染不出"的组合,连同理由一起印出来 —— 不许悄悄省掉
    for (const u of UNRENDERABLE) {
        console.log(`  · UNRENDERABLE ${u.k} —— ${u.site}`)
        console.log(`      ${u.why}`)
    }

    // ── L3 · 禁用态读得清 ──────────────────────────────────────────────────
    const dis = all.filter(b => b.disabled)
    if (dis.length) {
        const worst = dis.reduce((a, b) => a.cr < b.cr ? a : b)
        probe('L3 禁用态对比度 ≥ 4.5', worst.cr >= 4.5,
            `最差 ${worst.cr}:1(${worst.path} "${worst.label}")· 共 ${dis.length} 处`)
    } else {
        console.log('  · 本次取样没有遇到禁用态按钮 —— L3 未取证(不算绿)')
    }

    console.log('')
    console.log(`共 ${results.length} 条断言,红 ${fail.length} 条。库按钮取样 ${all.length} 处 / ${PAGES.length + dynamic.length} 页(其中动态 ${dynamic.length} 页)。`)
    if (fail.length) { for (const f of fail) console.log('  ✗ ' + f); process.exitCode = 1 }
} catch (e) {
    console.error('✗ 探针自身出错:' + (e?.message ?? e))
    process.exitCode = 1
} finally {
    // ★ 顺序:先跑完清理的 REST 往返,再收子进程(LEAK-1)。
    await runPlan()
    killChildren()
    try { release() } catch {}
}
