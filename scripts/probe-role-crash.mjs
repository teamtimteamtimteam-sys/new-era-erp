#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// FIX-2b · 角色形状的探针 —— 「以【那个人】的身份把那一页真的取回来」
//
// ★ 它存在的理由,比它检查的那条缺陷活得久 ★
//   scripts/smoke-routes.mjs 是以 **admin** 登录跑的(见它 1685 行:建号之后
//   立刻授 admin)。admin 持有全部 39 个权限码,于是**任何"少了一个码才会发生"
//   的缺陷,对冒烟都是结构性不可见的** —— 不是它没跑到那一页,是它跑到了、
//   而那一页对 admin 是好的。唯一的多角色通路是 `--reach`,而它在这棵树上
//   结构性发红(约 96 条假失败),所以实际上没有任何一道自动化门以
//   【非 admin】的身份取过一次页面。
//
//   FIX-2b 撞上的那条缺陷正是这个形状:/inbound/[id]/edit 对 warehouse 与
//   operations 在【挂着采购单】的批次上抛异常(purchase_orders 的 RLS 要
//   module.purchasing.view,两个角色都没有 → `.single()` 得 0 行 → PostgREST
//   报 PGRST116 → lib/db-helpers.ts:36 的 mustOne 抛)。它在线上活着,而
//   六个人里两个人每天都会踩到 —— 冒烟一次都没有说过话。
//
//   ★ 所以这支探针的判据不是"那一页对不对",是【它以谁的身份取的】。★
//
// ── 它做什么 ────────────────────────────────────────────────────────────────
//   对每个受测角色:建一个一次性账号 → 授那个角色 → 登录 → 用**它的 cookie**
//   取几条真实路由 → 断言 HTTP 200 且页面里没有 Next 的错误边界。
//   受测的批次【按名挑】:一条挂着采购单、一条没挂 —— 因为这条缺陷只在
//   前者上发生,而"随手拿第一行"会得到一个时好时坏的探针(ID_FILTERS 那一课)。
//
// ── 退出码 ──────────────────────────────────────────────────────────────────
//   0 = 全部断言过;1 = 有断言失败;2 = 探针自己坏了(起不来 / 建不了会话)。
//   ★ 判决只从日志里那一行 `ROLE_PROBE_EXIT=` 读 —— 不看启动器的状态。
//
//   用法:node scripts/probe-role-crash.mjs [--roles=warehouse,operations]
//         [--inject=<case>]   见下面 INJECTIONS:把一个断言【故意弄假】,
//                             用来证明这道断言真的会咬人。
// ════════════════════════════════════════════════════════════════════════════
import { readFileSync } from 'node:fs'
import { spawn, execSync } from 'node:child_process'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { acquireOrExit, release } from './liveLock.mjs'

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)))
const PORT = 3197            // 不是 3198(版式探针的),也不是 3199(冒烟的)
const env = readFileSync(join(ROOT, '.env.local'), 'utf8')
const URL_ = env.match(/NEXT_PUBLIC_SUPABASE_URL=(\S+)/)[1]
const ANON = env.match(/NEXT_PUBLIC_SUPABASE_ANON_KEY=(\S+)/)[1]
const SERVICE = env.match(/SUPABASE_SERVICE_ROLE_KEY=(\S+)/)[1]

const argRoles = process.argv.find((a) => a.startsWith('--roles='))
const ROLES = argRoles ? argRoles.slice(8).split(',').map((s) => s.trim()) : ['warehouse', 'operations']
const INJECT = (process.argv.find((a) => a.startsWith('--inject=')) || '').slice(9) || null

// ── 故障注入 ────────────────────────────────────────────────────────────────
// ★ 一次不改变任何东西的注入,与一道从不触发的检查分不开(FIX-2a / UI-1d /
//   COPY-1 各栽过一次)。所以注入在**探针自己这一侧**,而且每一种都必须让
//   一条【具体的】断言变红,并把它的名字印出来。
const INJECTIONS = {
    // 把"挂着采购单的那条批次"换成"没挂的那条" —— 若断言仍然全绿,说明
    // 这支探针根本没有在测那条有采购单的路径。
    'no-po-batch': 'withPo 换成 withoutPo(该让 with-po 那条断言失去意义)',
    // 把断言的期望码改成 500 —— 修好之后这一定红。
    'expect-500': '把 with-po 的期望 HTTP 改成 500',
    // 不授角色就登录 —— 该在 requireModule 那一层被挡成拒绝页,而不是 200。
    'no-role': '建账号但不授任何角色',
}
if (INJECT && !INJECTIONS[INJECT]) {
    console.error(`✗ --inject=${INJECT} 不认识。可选:${Object.keys(INJECTIONS).join(' / ')}`)
    console.log('ROLE_PROBE_EXIT=2')
    process.exit(2)
}

const rest = (path, opts = {}) =>
    fetch(URL_ + path, {
        ...opts,
        headers: {
            apikey: SERVICE, Authorization: `Bearer ${SERVICE}`,
            'Content-Type': 'application/json', ...(opts.headers || {}),
        },
    })

async function restRows(path, ctx) {
    const r = await rest(path)
    const body = await r.text()
    let rows = null
    try { rows = JSON.parse(body) } catch { /* 下面统一报 */ }
    if (!r.ok || !Array.isArray(rows)) throw new Error(`${ctx}: HTTP ${r.status} ${body.slice(0, 300)}`)
    return rows
}

async function signIn(email, password) {
    const sess = await (await fetch(URL_ + '/auth/v1/token?grant_type=password', {
        method: 'POST', headers: { apikey: ANON, 'Content-Type': 'application/json' },
        body: JSON.stringify({ email, password }),
    })).json()
    if (!sess?.access_token) throw new Error(`登录失败(${email}):${JSON.stringify(sess).slice(0, 200)}`)
    return 'sb-' + URL_.split('//')[1].split('.')[0] + '-auth-token=base64-'
        + Buffer.from(JSON.stringify(sess)).toString('base64url')
}

// 只杀【证明得了是孤儿】的(ppid = 1)—— 见 smoke-routes.mjs 的同名理由:
// 无差别清扫会杀掉别人正在跑的那一个。
function sweepStalePort() {
    let pids = []
    try {
        pids = execSync(`lsof -ti tcp:${PORT} || true`, { encoding: 'utf8' })
            .split('\n').map((s) => s.trim()).filter(Boolean)
    } catch { return }
    for (const pid of pids) {
        let ppid = null
        try { ppid = execSync(`ps -o ppid= -p ${pid}`, { encoding: 'utf8' }).trim() } catch { continue }
        if (ppid === '1') {
            console.log(`· 扫掉一个占着 ${PORT} 的孤儿进程 pid=${pid}`)
            try { process.kill(Number(pid), 'SIGKILL') } catch { /* 已经没了 */ }
        } else {
            console.error(`✗ 端口 ${PORT} 被 pid=${pid}(父进程 ${ppid} 还活着)占着 —— 那是别人正在跑的东西,不杀。`)
            console.log('ROLE_PROBE_EXIT=2')
            process.exit(2)
        }
    }
}

const failures = []
const results = []

// ════════════════════════════════════════════════════════════════════════════
// ★★【判据被改过一次,而第一版分不出两臂 —— 这一段是那次的记录】★★
//
//   第一版断言的是 `HTTP === 200`。它对着一条【真的在抛异常】的页面【全绿】,
//   而那条异常就写在服务器日志里:
//       ⨯ Error: 查询失败(采购单表头): PGRST116 … at page.tsx:334
//
//   **原因是 App Router 是流式的**:外壳先冲出去,状态码那一刻就定了 200;
//   服务端组件之后抛的异常只能落在【正文里】。所以对一个 RSC 抛错的页面,
//   HTTP 状态**根本不是那个信号** —— dev 与 prod 都不是。
//
//   ★ 判据因此换成【这一页有没有把自己渲染出来】★:正文里必须出现这条记录
//     自己的编号(它在标题旁边)。渲染成功 → 有;半路抛掉 → 没有。
//     两臂由此分得开,而且这个判据不依赖 dev/prod 的错误页长什么样。
//   状态码仍然记下来并断言,只是它不再是【唯一】的那一条 —— 一个 500 也要红。
//
//   这与仓库里已经付过账的那一条是同一课(UI-1d fu2:
//   「一个分不出两臂的判据不是判据」)。写在这里,因为下一个人会想简化它。
// ════════════════════════════════════════════════════════════════════════════
const THROWN = /查询失败\(|Application error: a server-side exception|__next_error__/

function assertPage(label, got, want, body, mustContain) {
    const thrown = THROWN.test(body)
    const rendered = mustContain ? body.includes(mustContain) : true
    results.push({ label, got, want, thrown, rendered, mustContain })
    if (got !== want) failures.push(`${label}: HTTP ${got},期望 ${want}`)
    if (want === 200 && thrown) failures.push(`${label}: 正文里有服务端组件抛出的异常(HTTP ${got})`)
    if (want === 200 && !rendered) failures.push(`${label}: 正文里找不到 ${JSON.stringify(mustContain)} —— 这一页没有渲染出来`)
}

async function main() {
    acquireOrExit('scripts/probe-role-crash.mjs')
    sweepStalePort()

    // ── 按名挑受测的行(不赌)────────────────────────────────────────────────
    const withPo = await restRows(
        '/rest/v1/inbound_batches?select=id,code&purchase_order_id=not.is.null&deleted_at=is.null&limit=1',
        '挂着采购单的批次')
    const withoutPo = await restRows(
        '/rest/v1/inbound_batches?select=id,code&purchase_order_id=is.null&deleted_at=is.null&limit=1',
        '没挂采购单的批次')
    if (!withPo.length || !withoutPo.length) {
        console.error('✗ 线上找不到"挂着采购单"与"没挂"各一条批次 —— 这支探针的两条对照臂缺了一边。')
        console.log('ROLE_PROBE_EXIT=2')
        process.exit(2)
    }
    const withOutputBatch = await restRows(
        '/rest/v1/output_batches?select=id,code&deleted_at=is.null&limit=1', '产出批次')
    console.log(`· 受测批次:挂单 ${withPo[0].code} · 无单 ${withoutPo[0].code}`
        + (withOutputBatch.length ? ` · 产出 ${withOutputBatch[0].code}` : ''))

    // ── 建会话(每个角色一个)──────────────────────────────────────────────
    const stamp = Date.now()
    const made = []
    const cookies = {}
    for (const roleCode of ROLES) {
        const email = `roleprobe-${stamp}-${roleCode}@test.local`
        const r = await rest('/auth/v1/admin/users', {
            method: 'POST',
            body: JSON.stringify({ email, password: 'role-probe-1', email_confirm: true }),
        })
        if (!r.ok) throw new Error(`建 ${roleCode} 账号失败:HTTP ${r.status} ${(await r.text()).slice(0, 200)}`)
        const u = await r.json()
        made.push(u.id)
        if (INJECT !== 'no-role') {
            const rr = await restRows(`/rest/v1/roles?select=id&code=eq.${roleCode}`, `roles ← ${roleCode}`)
            if (!rr.length) throw new Error(`角色 ${roleCode} 不在册`)
            const g = await rest('/rest/v1/user_roles', {
                method: 'POST', body: JSON.stringify({ user_id: u.id, role_id: rr[0].id }),
            })
            if (!g.ok) throw new Error(`授 ${roleCode} 失败:HTTP ${g.status} ${(await g.text()).slice(0, 200)}`)
        }
        cookies[roleCode] = await signIn(email, 'role-probe-1')
    }

    // ── dev server ──────────────────────────────────────────────────────────
    const logChunks = []
    const dev = spawn('npx', ['next', 'dev', '-p', String(PORT)], { cwd: ROOT })
    dev.stdout.on('data', (d) => logChunks.push(d.toString()))
    dev.stderr.on('data', (d) => logChunks.push(d.toString()))
    const READY_TIMEOUT_MS = 90_000
    const t0 = Date.now()
    let ready = false
    while (Date.now() - t0 < READY_TIMEOUT_MS) {
        await new Promise((r) => setTimeout(r, 1000))
        if (logChunks.join('').includes('Ready in')) { ready = true; break }
        if (dev.exitCode !== null) break
    }
    if (!ready) {
        dev.kill()
        console.error('✗ dev server 没起来:\n' + logChunks.join('').split('\n').slice(-25).join('\n'))
        await cleanup(made)
        console.log('ROLE_PROBE_EXIT=2')
        process.exit(2)
    }

    const poBatch = INJECT === 'no-po-batch' ? withoutPo[0] : withPo[0]
    const wantWithPo = INJECT === 'expect-500' ? 500 : 200

    try {
        for (const roleCode of ROLES) {
            const cookie = cookies[roleCode]
            const get = async (path) => {
                const r = await fetch(`http://localhost:${PORT}${path}`, { headers: { cookie } })
                return { status: r.status, body: await r.text() }
            }
            // 第一次取会触发编译,慢 —— 但结果一样;不预热,免得预热本身吞掉一次失败。
            const a = await get(`/inbound/${poBatch.id}/edit`)
            assertPage(`[${roleCode}] /inbound/[id]/edit(挂着采购单 ${poBatch.code})`,
                a.status, wantWithPo, a.body, poBatch.code)

            const b = await get(`/inbound/${withoutPo[0].id}/edit`)
            assertPage(`[${roleCode}] /inbound/[id]/edit(没挂采购单 ${withoutPo[0].code})`,
                b.status, 200, b.body, withoutPo[0].code)

            if (withOutputBatch.length) {
                const c = await get(`/output/${withOutputBatch[0].id}/edit`)
                assertPage(`[${roleCode}] /output/[id]/edit(${withOutputBatch[0].code})`,
                    c.status, 200, c.body, withOutputBatch[0].code)
            }
            const d = await get('/inbound')
            assertPage(`[${roleCode}] /inbound(列表)`, d.status, 200, d.body, withPo[0].code)
        }
    } finally {
        dev.kill()
        await cleanup(made)
    }

    console.log('\n== 结果 ==')
    for (const r of results) {
        const bad = r.got !== r.want || (r.want === 200 && (r.thrown || !r.rendered))
        const why = [r.thrown ? '正文里有抛出的异常' : null, r.rendered ? null : `没找到 ${r.mustContain}`]
            .filter(Boolean).join('、')
        console.log(`  ${bad ? '✗' : '✓'} ${r.label} → HTTP ${r.got}${why ? '(' + why + ')' : ''}`)
    }
    if (INJECT) console.log(`\n· 本跑带着注入 --inject=${INJECT}(${INJECTIONS[INJECT]})`)
    if (failures.length) {
        console.error(`\n✗ ${failures.length} 条断言失败:`)
        for (const f of failures) console.error('   · ' + f)
        console.log('ROLE_PROBE_EXIT=1')
        process.exit(1)
    }
    console.log(`\n✓ ${results.length} 条断言全过(角色:${ROLES.join('、')})`)
    console.log('ROLE_PROBE_EXIT=0')
    process.exit(0)
}

// 清理是【两半】,而且两半都要说话 —— 见 smoke-routes.mjs 的 CLEANUP-A:
// 只删账号不删授权,会留下一条谁也解析不出来的幽灵授权。
async function cleanup(userIds) {
    for (const id of userIds) {
        const a = await rest(`/rest/v1/user_roles?user_id=eq.${id}`, { method: 'DELETE' })
        if (!a.ok) console.error(`  ✗ 清理失败(授权 ${id}):HTTP ${a.status}`)
        const b = await rest(`/auth/v1/admin/users/${id}`, { method: 'DELETE' })
        if (!b.ok) console.error(`  ✗ 清理失败(账号 ${id}):HTTP ${b.status}`)
    }
}

process.on('exit', release)
process.on('SIGINT', () => { release(); process.exit(130) })
process.on('SIGTERM', () => { release(); process.exit(143) })

main().catch(async (e) => {
    console.error('✗ 探针自己坏了:' + (e?.stack || e))
    console.log('ROLE_PROBE_EXIT=2')
    process.exit(2)
})
