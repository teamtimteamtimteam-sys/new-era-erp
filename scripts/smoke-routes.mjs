#!/usr/bin/env node
// scripts/smoke-routes.mjs — 路由冒烟:把 Tim 手点的事一次跑完(OPS 级,按需运行)。
//
// 【为什么存在】两页断了几个月、每道门都是绿的 —— build 只编译、从不渲染;
// RSC 的序列化错误、查询错误只有真的渲染那一页才炸。手点一页一页找,脚本一把全找。
//
// 做什么:清扫上次残留 → 起 dev server → 建一次性 admin 会话 + 一次性评估人
// fixture(两名 ZZ-SMOKE-* 员工 + 一行试用期评估,/my-reviews/[id] 以评估人
// 视角精确断言 200 —— 对 admin 它 404 是契约,等于从未渲染)→ 请求 app/ 下每一条
// 路由(动态段从库里取真实 id;状态门路由的预期值从被选中那一行算出来,精确断言)
// → 失败的连同【服务端】错误堆栈一起报 —— 浏览器那句话什么都不说,上两只虫都
// 因此多绕了一圈。收尾删掉全部临时行与会话;开跑的清扫兜住 finally 挡不住的 kill。
//
// 用法:node scripts/smoke-routes.mjs
// 退出码 0 = 全通;1 = 有失败 / 跳过清单漂移(EXPECTED_SKIPS)/ 脚本自身查询炸了
// 【不进 db/gate.py】整跑约 2-4 分钟且要起 dev server —— 慢门会被跳过,
// check_mirrors 的教训。按需跑:每次改了页面渲染层,或 Tim 又用手找到一只虫之后。
import { readFileSync, readdirSync, statSync, existsSync } from 'node:fs'
import { spawn, execSync } from 'node:child_process'
import { join } from 'node:path'

const ROOT = new URL('..', import.meta.url).pathname
const PORT = 3199
const env = readFileSync(join(ROOT, '.env.local'), 'utf8')
const URL_ = env.match(/NEXT_PUBLIC_SUPABASE_URL=(\S+)/)[1]
const ANON = env.match(/NEXT_PUBLIC_SUPABASE_ANON_KEY=(\S+)/)[1]
const SERVICE = env.match(/SUPABASE_SERVICE_ROLE_KEY=(\S+)/)[1]

// ── 路由枚举 ────────────────────────────────────────────────────────────────
function* walk(dir) {
    for (const name of readdirSync(dir)) {
        const p = join(dir, name)
        if (statSync(p).isDirectory()) yield* walk(p)
        else if (name === 'page.tsx' || name === 'route.ts') yield p
    }
}
const routes = [...walk(join(ROOT, 'app'))].map((p) =>
    p.slice(ROOT.length + 3).replace(/\/(page\.tsx|route\.ts)$/, '') || '/')

// ── 动态段的真实 id 从哪来(PostgREST + service key,随数据变化自动跟上)────
const ID_SOURCES = {
    '[id]': {
        '/customers': 'customers', '/finance/bank/statements': 'bank_statements',
        '/finance/expenses': 'expenses', '/finance/fx': 'fx_rates',
        '/finance/invoices': 'invoices', '/finance/journal': 'journal_entries',
        '/finance/payments': 'payments', '/hr/claims': 'medical_claims',
        '/hr/departments': 'departments', '/hr/employees': 'employees',
        '/hr/leave': 'leave_requests', '/hr/payroll': 'payroll_periods',
        '/hr/reviews': 'performance_reviews', '/hr/training': 'training_records',
        '/inbound/receive/done': 'inbound_batches', '/inbound': 'inbound_batches',
        '/materials': 'materials', '/metal-prices': 'metal_prices',
        '/my-reviews': 'performance_reviews', '/output': 'output_batches',
        '/pricing/formulas': 'pricing_formulas', '/processing': 'processing_runs',
        '/purchasing/orders': 'purchase_orders', '/purchasing/payment-terms': 'payment_term_templates',
        '/settings/permissions/roles': 'roles', '/stocktakes': 'stocktakes',
        '/suppliers': 'suppliers',
    },
    '[assayId]': { '': 'assay_results' },
    '[batchId]': { '': 'inbound_batches' },
    '[saleId]': { '': 'sales_records' },
    '[materialId]': { '': 'materials' },
}
// 预期中的"非 200":这些不是坏,是设计(第一轮全量报告逐条核实后收编)。
// /welcome 与 /set-password 曾在这里挂 [200,307]:两页对持会话的请求都是确定的
// 200(/welcome 根本没有重定向;/set-password 只在无会话时回 /login),宽松项
// 只会挡住"页面开始乱重定向"这个信号,所以删掉,让 2xx 兜底去断言。
const EXPECTED = {
    '/logout': [307, 303],          // 登出即重定向
    '/my-reviews/[id]': [404],      // admin 不是评估人 —— notFound 是契约;评估人视角在主循环后精确单测
    '/purchasing': [307],           // 索引页重定向到 /purchasing/orders
}
// 三条状态门路由:预期值从被选中的那一行【算出来】,精确断言 ——
// [200,307] 那种"两个都行"会静默放过一个开始乱重定向的守卫。
const STATUS_GUARDS = {
    '/hr/payroll/[id]/edit':                   { table: 'payroll_periods', redirects: (s) => s === 'posted' },      // 已过账不可编辑
    '/stocktakes/[id]/review':                 { table: 'stocktakes',      redirects: (s) => s !== 'open' },        // 非 open 不可复核
    '/finance/bank/statements/[id]/reconcile': { table: 'bank_statements', redirects: (s) => s === 'reconciled' },  // 已对平回详情
}
// 跳过清单要【断言】,不能只打印:一条路由从 ok 移到 skip 是覆盖回归,
// 而它看起来和"还没有数据"一模一样。集合变了(任一方向)都失败,点名差异。
// (/hr/reviews/[id] 与 /my-reviews/[id] 不在此列:评估人 fixture 自带一行评估,
// 这两条每次都真的渲染。)
const EXPECTED_SKIPS = new Set([
    '/hr/claims/[id]',    // medical_claims 空 —— 正常运营会产生;有数据那天此断言逼人收编
    '/hr/leave/[id]',     // leave_requests 空
])
// ── 冒烟临时行的标识 ─────────────────────────────────────────────────────────
// 员工行和评估行会出现在 HR 界面和待办板上 —— 必须一眼即知是脚本垃圾,不是一名
// 幽灵员工挂着一条像真的评估(与 smoke-* 账号前缀同一条理由)。code 自供:
// 取号触发器只在空值时才取,不烧 EMP-YYYY-NNNN 的无缝号。
const SCRATCH_EMP_PREFIX = 'ZZ-SMOKE-'
const SCRATCH_NAME = '【SMOKE 冒烟脚本临时行 · 勿动 · 随时可删】'

async function rest(path, opts = {}) {
    const r = await fetch(URL_ + path, { ...opts,
        headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, 'Content-Type': 'application/json', ...(opts.headers ?? {}) } })
    return r
}
// 有软删列的表跳过已删行 —— 详情页对已删行 404 是契约,不是坏。
// 【只列真有 deleted_at 列的表】expenses/invoices/sales_records 没有这列,曾被错列进来:
// 过滤报错被读成"没数据",四条路由悄悄失去覆盖(下面 restRows 就是那次的教训)。
const SOFT_DELETED = new Set(['customers','suppliers','materials','bank_statements',
    'inbound_batches','leave_requests','medical_claims','metal_prices','output_batches',
    'payroll_periods','payment_term_templates','pricing_formulas','processing_runs','purchase_orders',
    'review_cycles','stocktakes','training_records','fx_rates','employees','departments'])
// 查询失败 ≠ 没有数据:失败必须当场炸并点名路由和错误,绝不能记成 SKIP ——
// 与 check-i18n 的"解析出 0 个后缀是坏,不是空集"同一条规矩。
async function restRows(path, ctx) {
    const r = await rest(path)
    const body = await r.text()
    let rows = null
    try { rows = JSON.parse(body) } catch {}
    if (!r.ok || !Array.isArray(rows))
        throw new Error(`id 查询失败(${ctx}): HTTP ${r.status} ${body.slice(0, 300)}`)
    return rows
}
async function firstId(table, route) {
    const del = SOFT_DELETED.has(table) ? '&deleted_at=is.null' : ''
    const rows = await restRows(`/rest/v1/${table}?select=id&limit=1${del}`, `${route} ← ${table}`)
    return rows[0]?.id ?? null
}
async function restOk(path, opts, ctx) {
    const r = await rest(path, opts)
    if (!r.ok) throw new Error(`${ctx}: HTTP ${r.status} ${(await r.text()).slice(0, 300)}`)
    return r
}
async function signIn(email, password) {
    const sess = await (await fetch(URL_ + '/auth/v1/token?grant_type=password', { method: 'POST',
        headers: { apikey: ANON, 'Content-Type': 'application/json' },
        body: JSON.stringify({ email, password }) })).json()
    return 'sb-' + URL_.split('//')[1].split('.')[0] + '-auth-token=base64-'
        + Buffer.from(JSON.stringify(sess)).toString('base64url')
}
// 【开跑先扫,不只收尾再删】finally 挡不住 kill:上次崩掉的残留必须在开跑时清掉,
// 否则一次崩溃就把临时行永久留在库里 —— 别处的 fixture 靠事务回滚兜底,
// 本脚本驱动 HTTP 打真服务器,回滚不存在,清扫就是它唯一的机制。
async function sweepScratch() {
    const emps = await restRows(`/rest/v1/employees?select=id&code=like.${SCRATCH_EMP_PREFIX}*`, '清扫 ← employees')
    if (emps.length) {
        const ids = emps.map((e) => e.id).join(',')
        await restOk(`/rest/v1/performance_reviews?or=(employee_id.in.(${ids}),reviewer_employee_id.in.(${ids}))`,
            { method: 'DELETE' }, '清扫残留评估行')
        await restOk(`/rest/v1/employees?id=in.(${ids})`, { method: 'DELETE' }, '清扫残留员工行')
    }
    const page = await (await restOk('/auth/v1/admin/users?per_page=1000', {}, '清扫:列账号')).json()
    const stale = (page?.users ?? []).filter((u) =>
        (u.email ?? '').startsWith('smoke-') && (u.email ?? '').endsWith('@test.local'))
    for (const u of stale) {
        await rest(`/rest/v1/user_roles?user_id=eq.${u.id}`, { method: 'DELETE' })
        await restOk(`/auth/v1/admin/users/${u.id}`, { method: 'DELETE' }, `清扫账号 ${u.email}`)
    }
    if (emps.length || stale.length)
        console.log(`  清扫上次残留:${emps.length} 员工行 / ${stale.length} 账号`)
}


// ════════════════════════════════════════════════════════════════════════════
// 按角色的可达性(REACH-1)—— 「打得开,却从首页走不到」
// ════════════════════════════════════════════════════════════════════════════
// 【为什么要有】上面那一大圈以 admin 跑,而 admin 什么都有,所以一道【太紧】的门
// 在那里永远是 200;另一侧,纯静态的可达性走查只知道"代码里有没有这条链接",
// 不知道"这个人的屏幕上有没有渲染出来"。两者缺的是同一个东西:
// 【以某个角色的身份从 / 出发,只跟着他真的看得见的链接走】。
// /margin 就是这么漏掉的:它一直有两个入口,但都在模块内部 —— 财务侧的人看不见
// 加工那个,加工侧的人看不见财务那个,而全局导航里一个都没有。
//
// ── 这个检查【看不见】什么(绿灯不等于全覆盖)──────────────────────────────
// 1.【客户端渲染出来的链接】只在 useState / 展开 / 弹窗之后才出现的入口,这里抓不到:
//    我们读的是服务端吐出来的 HTML,不跑浏览器。要覆盖它就得引入 Playwright,
//    那是另一个量级的项目。凡是入口藏在交互后面的页面,本检查【什么也没说】。
// 2.【动态路由】/xxx/[id] 的可达性取决于"这个角色在列表页上看不看得见行"——
//    没有行就没有链接,而"没有数据"与"到不了"在走查眼里长得一模一样
//    (restricted-is-not-zero 那条病换了身测试的衣服)。所以断言【只覆盖静态路由】,
//    动态路由单独计数报出来,绝不悄悄算进"通过"。
// 3.【"打得开"是前提】一个人打不开的页面,谈不上"该有入口"—— 所以断言只覆盖
//    他【打得开】的静态路由。这一条不是偷懒:operations 打不开 /margin(缺
//    data.view_prices),对他而言那一页的入口有无都不改变什么;而 finance 打得开,
//    所以入口消失就必须被点名。注入验证时按角色分别验,别用一个角色的结果替另一个说话。
// 4. 它不判断"这个人【应不应该】看见这个入口"—— 那是产品判断。它只保证
//    "打得开"与"走得到"这两个集合对得上,不一致就点名。
// 【代价】三个角色各走一遍 = 在 134 条路由的主循环之后再抓 300~700 次页面,
// 整跑从 2-4 分钟涨到 10 分钟上下。所以它跟主循环一起【留在 gate 之外】(慢门会被
// 跳过,check_mirrors 的教训),按需跑。也别单独跳过主循环来"提速"—— 主循环顺带把
// 每条路由在 dev server 上编译过一遍,跳掉它编译就摊到 BFS 的每一次抓取上,反而更慢。
const REACH_ROLES = ['admin', 'operations', 'finance']

// 打得开却走不到、而且【是有意如此】的静态路由。drift 两个方向都失败:
// 多出来的要么是真漏了入口,要么是这里该添一行并写明理由。
const EXPECTED_UNREACHABLE = {
    admin: new Set(['/login', '/set-password', '/welcome']),
    operations: new Set(['/login', '/set-password', '/welcome',
        // metal_prices 的【读】策略是 USING (true) —— 行情是市场报价,数据自己声明
        // 它公开(理由在 lib/modules.ts 的长注释里)。所以任何人都打得开这一页,
        // 而入口挂在 pricing 模块里,operations 没有那个模块 —— 于是"打得开却走不到"
        // 对他成立,并且【是有意的】。要改的是产品判断(该不该给非定价角色一个入口),
        // 不是这个检查。
        '/metal-prices']),
    finance: new Set(['/login', '/set-password', '/welcome']),
}

// 拒绝页认【机器标记】不认文案:refusal() 与 requireManagePermissions() 的外层 div
// 都带 data-access-denied="1"。首跑时这里是一串文案字符串,于是漏掉了权限管理页
// 那一种拒绝,把 /settings/permissions 报成了"打得开却走不到"—— 误报比漏报更坏,
// 它教人忽略这条检查。新增任何一种拒绝屏,只要复用那两个组件就自动被认出来。
const DENIED_MARK = 'data-access-denied'

function hrefsIn(html) {
    const out = new Set()
    for (const m of html.matchAll(/href="([^"]+)"/g)) {
        const h = m[1].split('?')[0].split('#')[0]
        if (h.startsWith('/') && !h.startsWith('//')) out.add(h.replace(/\/+$/, '') || '/')
    }
    return out
}

async function reachabilityForRole(roleCode, base, mkSession) {
    const cookie = await mkSession(roleCode)
    const get = async (path) => {
        const r = await fetch(base + path, { headers: { cookie }, redirect: 'manual' })
        const body = r.status === 200 ? await r.text() : ''
        // CSV 导出之类的 Route Handler 不是页面 —— 谈不上"有没有入口"
        const isHtml = (r.headers.get('content-type') ?? '').includes('text/html')
        return { status: r.status, body, isHtml }
    }

    // ① 从 / 出发,只跟着【真的渲染出来的】链接走
    //
    // 【逐条打印,这不是装饰】本段一个角色要抓 200~330 个页面、跑好几分钟,
    // 而它此前【整段沉默、只在角色跑完才吐一行】—— 于是"还在跑"与"已经挂了"
    // 在屏幕上长得一模一样,人就会去轮询日志(2026-08-10 就是这么绕开
    // db/wait_for.sh 的)。start-and-leave 这个用法【依赖日志自己回答"活着吗"】,
    // 所以逐条进度是它的前提条件,不是可有可无的体贴。
    const seen = new Set(['/'])
    const queue = ['/']
    let visited = 0
    while (queue.length) {
        const cur = queue.shift()
        visited++
        console.log(`  [${roleCode} 走 ${visited}/${seen.size}] ${cur}`)
        const { status, body } = await get(cur)
        if (status !== 200) continue
        if (body.includes(DENIED_MARK)) continue   // 进不去的页面不往下走
        for (const h of hrefsIn(body)) {
            if (!seen.has(h)) { seen.add(h); queue.push(h) }
        }
    }

    // ② 静态路由里,他【打得开】哪些(200 且不是拒绝页)
    const staticRoutes = routes.filter((r) => !r.includes('[') && !r.startsWith('/api'))
    const openable = []
    let scanned = 0
    for (const r of staticRoutes) {
        scanned++
        console.log(`  [${roleCode} 试开 ${scanned}/${staticRoutes.length}] ${r}`)
        const { status, body, isHtml } = await get(r)
        if (status === 200 && !body.includes(DENIED_MARK) && isHtml) openable.push(r)
    }

    // ③ 打得开却走不到
    const unreachable = openable.filter((r) => !seen.has(r))
    const dynamicCount = routes.length - staticRoutes.length
    return { role: roleCode, reached: seen.size, openable: openable.length, unreachable, dynamicCount }
}

async function main() {
    const reachFailures = []
    await sweepScratch()

    // ── 一次性 admin 会话 ────────────────────────────────────────────────────
    const stamp = Date.now()
    const email = `smoke-${stamp}@test.local`
    const cu = await (await restOk('/auth/v1/admin/users', { method: 'POST',
        body: JSON.stringify({ email, password: 'smoke-pass-1', email_confirm: true }) }, '建 admin 账号')).json()
    const roleRows = await restRows('/rest/v1/roles?select=id&code=eq.admin', 'roles ← admin')
    await restOk('/rest/v1/user_roles', { method: 'POST',
        body: JSON.stringify({ user_id: cu.id, role_id: roleRows[0].id }) }, '授 admin 角色')
    const cookie = await signIn(email, 'smoke-pass-1')

    // ── 第二个一次性会话:评估人视角 ─────────────────────────────────────────
    // /my-reviews/[id] 对 admin 是 404 契约,等于那页从未真正渲染 —— 而它正是
    // 部门经理实际用的页。自己不能评自己(CHECK not_self_review),所以受评人、
    // 评估人两名临时员工;评估人不授任何角色:RLS 'select as reviewer' 只看
    // reviewer_employee_id,这同时也验证了"无角色的经理也能看自己的评估任务"。
    const email2 = `smoke-${stamp}-reviewer@test.local`
    const cu2 = await (await restOk('/auth/v1/admin/users', { method: 'POST',
        body: JSON.stringify({ email: email2, password: 'smoke-pass-2', email_confirm: true }) }, '建评估人账号')).json()
    const mkEmp = async (n, extra) => (await (await restOk('/rest/v1/employees', { method: 'POST',
        headers: { Prefer: 'return=representation' },
        body: JSON.stringify({ code: `${SCRATCH_EMP_PREFIX}${n}`, legal_name: `${SCRATCH_NAME} ${n}`,
            employment_type: 'full_time', work_category: 'office', hire_date: '2026-01-01', ...extra }) },
        `建临时员工 ${n}`)).json())[0]
    const reviewee = await mkEmp(1, {})
    const reviewer = await mkEmp(2, { user_id: cu2.id })
    const review = (await (await restOk('/rest/v1/performance_reviews', { method: 'POST',
        headers: { Prefer: 'return=representation' },
        body: JSON.stringify({ employee_id: reviewee.id, reviewer_employee_id: reviewer.id,
            review_type: 'probation', period_start: '2026-01-01', period_end: '2026-06-30',
            notes: SCRATCH_NAME }) }, '建临时评估行')).json())[0]
    const cookie2 = await signIn(email2, 'smoke-pass-2')

    // ── dev server ───────────────────────────────────────────────────────────
    const logChunks = []
    const dev = spawn('npx', ['next', 'dev', '-p', String(PORT)], { cwd: ROOT })
    dev.stdout.on('data', (d) => logChunks.push(d.toString()))
    dev.stderr.on('data', (d) => logChunks.push(d.toString()))
    // 【等待要有上限,而且到了上限要报名字】原先这里 for 60 次、每次 1 秒,
    // 到点【无论服务器起没起来都往下走】—— 服务器没起来时,后面 131 条路由
    // 全部连接失败,屏幕上是一百多条 fetch 错误,而真正的原因(dev server 没起来)
    // 一个字都没有。有上限不等于会报错:没有失败分支的等待,和没有上限的等待
    // 一样难查。同一形状让一个壳等过 2 小时 47 分钟,见 db/wait_for.sh 的抬头。
    const READY_TIMEOUT_MS = 90_000
    const readyStart = Date.now()
    let ready = false
    while (Date.now() - readyStart < READY_TIMEOUT_MS) {
        await new Promise((r) => setTimeout(r, 1000))
        if (logChunks.join('').includes('Ready in')) { ready = true; break }
        if (dev.exitCode !== null) break          // 进程死了就不必等满
    }
    if (!ready) {
        const why = dev.exitCode !== null
            ? `next dev 退出了(code ${dev.exitCode})`
            : `${Math.round((Date.now() - readyStart) / 1000)}s 内没有看到 "Ready in"`
        dev.kill()
        console.error(`✗ dev server 没起来:${why}`)
        console.error(logChunks.join('').split('\n').slice(-30).join('\n'))
        process.exit(1)
    }

    const failures = []
    let ok = 0
    const skipped = new Set()
    const serverStack = async (before) => {
        await new Promise((r) => setTimeout(r, 500))
        const errLog = logChunks.slice(before).join('')
        return [...errLog.matchAll(/⨯[\s\S]{0,600}?digest[^\n]*\n?\}/g)].map((m) => m[0]).join('\n')
            || errLog.split('\n').filter((l) => /Error|error|⨯/.test(l)).slice(0, 8).join('\n')
    }
    try {
        for (const route of routes.sort()) {
            let url = route
            let skip = null
            // 父子路由的 id 必须【配套】:先取子行,再用它的外键定父段
            // (assay_results 也有 deleted_at —— 不过滤的话,软删行 404 会在
            // 已经烧过一次的这条路由上原样复发)
            if (route === '/inbound/[id]/assays/[assayId]') {
                const rows = await restRows(
                    '/rest/v1/assay_results?select=id,inbound_batch_id&deleted_at=is.null&limit=1',
                    `${route} ← assay_results`)
                if (!rows[0]) { skipped.add(route); console.log(`  SKIP ${route}  (no data in assay_results)`); continue }
                url = route.replace('[id]', rows[0].inbound_batch_id).replace('[assayId]', rows[0].id)
            }
            // 状态门路由:取同一行的 id 和 status,预期值算出来、精确断言
            let exact = null
            const guard = STATUS_GUARDS[route]
            if (guard) {
                const rows = await restRows(
                    `/rest/v1/${guard.table}?select=id,status&deleted_at=is.null&limit=1`,
                    `${route} ← ${guard.table}`)
                if (!rows[0]) { skipped.add(route); console.log(`  SKIP ${route}  (no data in ${guard.table})`); continue }
                url = route.replace('[id]', rows[0].id)
                exact = [guard.redirects(rows[0].status) ? 307 : 200]
            }
            for (const [seg, srcs] of Object.entries(ID_SOURCES)) {
                if (!url.includes(seg)) continue
                const prefix = Object.keys(srcs).filter((p) => route.startsWith(p) || p === '')
                    .sort((a, b) => b.length - a.length)[0]
                const id = await firstId(srcs[prefix], route)
                if (!id) { skip = `no data in ${srcs[prefix]}`; break }
                url = url.replace(seg, id)
            }
            if (skip) { skipped.add(route); console.log(`  SKIP ${route}  (${skip})`); continue }
            const before = logChunks.length
            const res = await fetch(`http://localhost:${PORT}${url}`, {
                headers: { cookie }, redirect: 'manual' })
            const allow = EXPECTED[route] ?? []
            const pass = exact ? exact.includes(res.status)
                : (res.status >= 200 && res.status < 300) || allow.includes(res.status)
            if (pass) { ok++ }
            else {
                failures.push({ route, url, status: res.status,
                    expected: exact?.[0], stack: await serverStack(before) })
                console.log(`  FAIL ${route} → ${res.status}${exact ? ` (expected ${exact[0]})` : ''}`)
            }
        }

        // ── 评估人视角:以真正的评估人会话请求 /my-reviews/[id],精确 200 ——
        // 404 意味着守卫误伤、RLS 收紧过头或会话装配坏了,而 admin 那一遍看不见
        {
            const target = `/my-reviews/${review.id}`
            const before = logChunks.length
            const res = await fetch(`http://localhost:${PORT}${target}`, {
                headers: { cookie: cookie2 }, redirect: 'manual' })
            if (res.status === 200) { ok++ }
            else {
                failures.push({ route: '/my-reviews/[id] (as reviewer)', url: target,
                    status: res.status, expected: 200, stack: await serverStack(before) })
                console.log(`  FAIL /my-reviews/[id] (as reviewer) → ${res.status} (expected 200)`)
            }
        }

        // ── 按角色的可达性(REACH-1)────────────────────────────────────────
        // admin 一遍是对照(他什么都有);operations 与 finance 是 /margin 那道题的
        // 两边 —— 一个只有加工、一个只有财务,而没有任何 live 角色同时持有两者。
        const reachUsers = []
        const mkSession = async (roleCode) => {
            const em = `smoke-${stamp}-${roleCode}@test.local`
            const u = await (await restOk('/auth/v1/admin/users', { method: 'POST',
                body: JSON.stringify({ email: em, password: 'smoke-pass-3', email_confirm: true }) },
                `建 ${roleCode} 账号`)).json()
            const rr = await restRows(`/rest/v1/roles?select=id&code=eq.${roleCode}`, `roles ← ${roleCode}`)
            if (!rr.length) throw new Error(`角色 ${roleCode} 不存在 —— 可达性检查不能对着一个空角色跑`)
            await restOk('/rest/v1/user_roles', { method: 'POST',
                body: JSON.stringify({ user_id: u.id, role_id: rr[0].id }) }, `授 ${roleCode}`)
            reachUsers.push(u.id)
            return signIn(em, 'smoke-pass-3')
        }
        console.log('\n== 按角色的可达性(打得开却走不到)==')
        for (const roleCode of REACH_ROLES) {
            const r = await reachabilityForRole(roleCode, `http://localhost:${PORT}`, mkSession)
            const unexpected = r.unreachable.filter((x) => !EXPECTED_UNREACHABLE[r.role].has(x))
            const gone = [...EXPECTED_UNREACHABLE[r.role]].filter((x) => !r.unreachable.includes(x))
            console.log(`  ${r.role}: 走到 ${r.reached} · 打得开 ${r.openable} 条静态路由 · ` +
                `其中走不到 ${r.unreachable.length}(动态路由 ${r.dynamicCount} 条不在断言范围,见文件头第 2 条)`)
            for (const x of unexpected) {
                reachFailures.push(`${r.role} 打得开但从首页走不到:${x}`)
                console.log(`  ✗ ${r.role} 打得开却走不到:${x}`)
            }
            for (const x of gone) {
                reachFailures.push(`${r.role} 预期走不到的 ${x} 现在走得到了 —— 把它移出 EXPECTED_UNREACHABLE`)
                console.log(`  ✗ ${r.role} 预期走不到的 ${x} 现在走得到了`)
            }
        }
        for (const id of reachUsers) {
            await rest(`/rest/v1/user_roles?user_id=eq.${id}`, { method: 'DELETE' })
            await rest(`/auth/v1/admin/users/${id}`, { method: 'DELETE' })
        }
    } finally {
        dev.kill('SIGTERM')
        await rest(`/rest/v1/performance_reviews?id=eq.${review.id}`, { method: 'DELETE' })
        await rest(`/rest/v1/employees?id=in.(${reviewee.id},${reviewer.id})`, { method: 'DELETE' })
        await rest(`/auth/v1/admin/users/${cu2.id}`, { method: 'DELETE' })
        await rest(`/rest/v1/user_roles?user_id=eq.${cu.id}`, { method: 'DELETE' })
        await rest(`/auth/v1/admin/users/${cu.id}`, { method: 'DELETE' })
    }

    console.log(`\n== ${routes.length} routes + 1 reviewer-view check: ${ok} ok, ${skipped.size} skipped (no data), ${failures.length} FAILED`)
    for (const f of failures) {
        console.log(`\n✗ ${f.route} (${f.url}) → HTTP ${f.status}${f.expected ? ` (expected ${f.expected})` : ''}`)
        if (f.stack) console.log(f.stack.split('\n').map((l) => '    ' + l).join('\n'))
    }
    const extraSkips = [...skipped].filter((r) => !EXPECTED_SKIPS.has(r))
    const goneSkips = [...EXPECTED_SKIPS].filter((r) => !skipped.has(r))
    if (extraSkips.length)
        console.log(`\n✗ 预期之外的 SKIP —— 覆盖回归,查数据源,别默认"没数据": ${extraSkips.join(', ')}`)
    if (goneSkips.length)
        console.log(`\n✗ 预期会 SKIP 的路由跑起来了 —— 数据到位了,把它移出 EXPECTED_SKIPS: ${goneSkips.join(', ')}`)
    if (reachFailures.length) {
        console.log(`\n✗ 可达性 ${reachFailures.length} 处 —— "打得开却走不到"就是一个没有入口的页面:`)
        for (const r of reachFailures) console.log('   ' + r)
    }
    process.exit(failures.length || extraSkips.length || goneSkips.length || reachFailures.length ? 1 : 0)
}
main().catch((e) => {
    console.error(`\n✗ 冒烟中止(脚本自身的查询炸了,不是路由失败):\n${e.message ?? e}`)
    process.exit(1)
})
