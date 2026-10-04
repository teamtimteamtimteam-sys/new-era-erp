#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// AUDIT-TRAIL-1d-3 · 页面这一层的探针 —— 「以【真角色】的身份把工资与评审那几页取回来,看屏幕上说了什么」
// ════════════════════════════════════════════════════════════════════════════
// 【为什么在 fixture 之外还要它】fixture 246 证的是读法;每一个工资期的页底一段、申请那一块下面不再有"以往的申请"(Q27)、
//   每一份评审的页底一段、轮次那一块、整张评分刻度一段(M11)、选了月份之后 KPI 那一块、中文界面里审计记录那一段逐字不变
//   (折入 3)住在页面上。/me 上没有评审与 KPI 的审计记录(Q14 · Q16)—— 页面那一层按源码断言(一次性账号没有员工档案,
//   /me 对它早返回)。形状照 probe-at1d2.mjs。
// 【受测的人】三个一次性账号(与冒烟同一套 ephemeral 计划,跑完收走 —— 线上那七个真账号一个都不碰):
//   admin · gm(持 hr.view 与 data.view_reviews,不持 data.view_pay —— Q7 的读者)· warehouse(不持 hr.view)。
//   Q19(/me 上期间的编号与月份)要一个【绑着员工档案、又有考勤行或工资单】的账号 —— 一次性账号两样都没有,而给它造考勤行或
//   工资单就是在线上写一个月的考勤 / 工资;它由 fixture 246 的 Q 臂与线上回滚的证明(以 warehouse 那个真账号的身份)证。
// 退出码:0 = 全过;1 = 有断言失败;2 = 探针自己坏了。★ 判决只从日志里那一行 `AT1D3_PROBE_EXIT=` 读。
// 用法:node scripts/probe-at1d3.mjs [--inject=<case>]   见 INJECTIONS —— 每一种都必须让一条具体的断言变红。
// ════════════════════════════════════════════════════════════════════════════
import { readFileSync } from 'node:fs'
import { spawn, execSync } from 'node:child_process'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { acquireOrExit, release } from './liveLock.mjs'
import { openPlan, planDelete, ephemeralGrantBody, runPlan, reapStalePlans, installExitHooks, exitAfterCleanup, ORDER } from './ephemeral.mjs'
import { machineTokens } from '../lib/trail/machineTokens.ts'

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)))
const PORT = 3188            // 不与冒烟(3199)、版式(3198)、角色探针(3197)、1b-1 … 1d-2(3196 … 3189)探针撞
const env = readFileSync(join(ROOT, '.env.local'), 'utf8')
const URL_ = env.match(/NEXT_PUBLIC_SUPABASE_URL=(\S+)/)[1]
const ANON = env.match(/NEXT_PUBLIC_SUPABASE_ANON_KEY=(\S+)/)[1]
const SERVICE = env.match(/SUPABASE_SERVICE_ROLE_KEY=(\S+)/)[1]
const INJECT = (process.argv.find((a) => a.startsWith('--inject=')) || '').slice(9) || null
const INJECTIONS = {
    'q27-history': '当作工资期页上还画着"以往的申请"那一段 —— Q27 那一条必须红',
    'me-review-trail': '当作 /me 的源码里多了一段评审的审计记录 —— Q14 那一条必须红',
    'machine': '往每一段里塞一个 uuid —— 机器字那几条必须红',
    'cjk': '往中文那一份里塞一个中文字 —— 折入 3 那几条必须红',
}
if (INJECT && !INJECTIONS[INJECT]) {
    console.error(`✗ --inject=${INJECT} 不认识。可选:${Object.keys(INJECTIONS).join(' / ')}`)
    console.log('AT1D3_PROBE_EXIT=2')
    process.exit(2)
}

const rest = (path, opts = {}) => fetch(URL_ + path, {
    ...opts, headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, 'Content-Type': 'application/json', ...(opts.headers || {}) },
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
        method: 'POST', headers: { apikey: ANON, 'Content-Type': 'application/json' }, body: JSON.stringify({ email, password }),
    })).json()
    if (!sess?.access_token) throw new Error(`登录失败(${email}):${JSON.stringify(sess).slice(0, 200)}`)
    return 'sb-' + URL_.split('//')[1].split('.')[0] + '-auth-token=base64-' + Buffer.from(JSON.stringify(sess)).toString('base64url')
}
function sweepStalePort() {
    let pids = []
    try { pids = execSync(`lsof -ti tcp:${PORT} || true`, { encoding: 'utf8' }).split('\n').map((s) => s.trim()).filter(Boolean) } catch { return true }
    for (const pid of pids) {
        let ppid = null
        try { ppid = execSync(`ps -o ppid= -p ${pid}`, { encoding: 'utf8' }).trim() } catch { continue }
        if (ppid === '1') { try { process.kill(Number(pid), 'SIGKILL') } catch { /* gone */ } }
        else { console.error(`✗ 端口 ${PORT} 被 pid=${pid} 占着,不杀。`); return false }
    }
    return true
}

// 与 probe-at1b3.mjs 同一个判据(404 由状态码回答,不由 RSC 负载里那句 not-found 文字回答)
const THROWN = /Application error: a server-side exception|__next_error__/
const failures = []
const passed = []
const skipped = []
function check(label, ok, why) { (ok ? passed : failures).push(ok ? label : `${label}: ${why}`) }

function trailSections(html) {
    const out = []
    for (const m of html.matchAll(/<section[^>]*data-audit-trail="[^"]*"[^>]*>([\s\S]*?)<\/section>/g)) {
        out.push(m[1].replace(/<span[^>]*data-trail-typed=""[^>]*>[\s\S]*?<\/span>/g, ' ').replace(/<[^>]+>/g, ' ').replace(/&[a-z#0-9]+;/g, ' ').replace(/\s+/g, ' '))
    }
    return out
}

/** 一页上 id="<anchor>" 起的那一段:状态与文字(剥掉人敲的字) */
function sectionAt(html, anchor) {
    const from = html.indexOf(`id="${anchor}"`)
    if (from < 0) return { state: '(none)', text: '' }
    const i = html.indexOf('data-audit-trail="', from)
    if (i < 0) return { state: '(none)', text: '' }
    const state = html.slice(i + 18, html.indexOf('"', i + 18))
    const start = html.lastIndexOf('<section', i), end = html.indexOf('</section>', i)
    const text = html.slice(start, end).replace(/<span[^>]*data-trail-typed=""[^>]*>[\s\S]*?<\/span>/g, ' ').replace(/<[^>]+>/g, ' ')
        .replace(/&[a-z#0-9]+;/g, ' ').replace(/\s+/g, ' ')
    return { state, text, html: html.slice(start, end) }
}

async function main() {
    acquireOrExit('scripts/probe-at1d3.mjs', { ownExit: false })
    openPlan('scripts/probe-at1d3.mjs')
    await reapStalePlans()
    if (!sweepStalePort()) return exitAfterCleanup(2)

    // ── 受测的行(线上真有的;以 service_role 读,绕过 RLS,是真行数)──────────────────────────
    const periods = await restRows('/rest/v1/payroll_periods?select=id,code&order=code', 'payroll periods')
    const reviews = await restRows('/rest/v1/performance_reviews?select=id,status&order=created_at', 'performance reviews')
    const cycles = await restRows('/rest/v1/review_cycles?select=id,name&order=name', 'review cycles')
    const kpiCycles = await restRows('/rest/v1/kpi_cycles?select=id,name&deleted_at=is.null&order=period_start', 'kpi cycles')
    const kpiEntries = await restRows('/rest/v1/kpi_entries?select=id,cycle_id', 'kpi entries')
    const one = async (path, ctx) => (await restRows(path, ctx))[0] ?? null
    const leave = await one('/rest/v1/leave_requests?select=id,code&order=code&limit=1', 'a leave request')
    const emp = await one('/rest/v1/employees?select=id,code&deleted_at=is.null&order=code&limit=1', 'an employee')
    const kpiMonths = kpiCycles.filter((c) => kpiEntries.some((e) => e.cycle_id === c.id))
    console.log(`· live: ${periods.length} payroll periods · ${reviews.length} performance reviews · ${cycles.length} review cycles · ${kpiEntries.length} KPI entries in ${kpiCycles.length} KPI months`)

    // ── 三个一次性账号:admin · gm · warehouse ─────────────────────────────────────────────────────
    const stamp = Date.now()
    const cookies = {}
    for (const roleCode of ['admin', 'gm', 'warehouse']) {
        const email = `at1d3probe-${stamp}-${roleCode}@test.local`
        const r = await rest('/auth/v1/admin/users', { method: 'POST', body: JSON.stringify({ email, password: 'at1d3-probe-1', email_confirm: true }) })
        if (!r.ok) throw new Error(`建 ${roleCode} 账号失败:HTTP ${r.status} ${(await r.text()).slice(0, 200)}`)
        const u = await r.json()
        planDelete(`/rest/v1/user_roles?user_id=eq.${u.id}`, `revoke ${roleCode} grant ${u.id}`, ORDER.GRANT)
        planDelete(`/auth/v1/admin/users/${u.id}`, `delete ${roleCode} account ${u.id}`, ORDER.ACCOUNT)
        const rr = await restRows(`/rest/v1/roles?select=id&code=eq.${roleCode}`, `roles ← ${roleCode}`)
        const g = await rest('/rest/v1/user_roles', { method: 'POST', body: JSON.stringify(ephemeralGrantBody(u.id, rr[0].id)) })
        if (!g.ok) throw new Error(`授 ${roleCode} 失败:HTTP ${g.status} ${(await g.text()).slice(0, 200)}`)
        cookies[roleCode] = await signIn(email, 'at1d3-probe-1')
    }

    const logChunks = []
    const dev = spawn('npx', ['next', 'dev', '-p', String(PORT)], { cwd: ROOT })
    devProc = dev
    dev.stdout.on('data', (d) => logChunks.push(d.toString()))
    dev.stderr.on('data', (d) => logChunks.push(d.toString()))
    const t0 = Date.now()
    let ready = false
    while (Date.now() - t0 < 90_000) {
        await new Promise((r) => setTimeout(r, 1000))
        if (logChunks.join('').includes('Ready in')) { ready = true; break }
        if (dev.exitCode !== null) break
    }
    if (!ready) {
        console.error('✗ dev server 没起来:\n' + logChunks.join('').split('\n').slice(-25).join('\n'))
        console.log('AT1D3_PROBE_EXIT=2')
        return exitAfterCleanup(2)
    }

    try {
        const get = async (role, path, locale = 'en') => {
            const r = await fetch(`http://localhost:${PORT}${path}`, { headers: { cookie: `${cookies[role]}; NEXT_LOCALE=${locale}` } })
            return { status: r.status, body: await r.text() }
        }
        const rendered = (p) => p.status === 200 && !THROWN.test(p.body)

        // ── 每一个工资期:页底一段(建立是记录开始之前的那一条);Q27 —— 申请那一块下面不再有"以往的申请" ─────────────
        for (const x of periods) {
            const p = await get('admin', `/hr/payroll/${x.id}`)
            const t = sectionAt(p.body, 'audit-trail')
            check(`payroll [admin] ${x.code}: the trail has the period's recording`, rendered(p) && t.state === 'entries' && /Payroll recorded|Pay lines saved/.test(t.text),
                `HTTP ${p.status}, state ${t.state}, «${t.text.slice(0, 160)}»`)
            const old = INJECT === 'q27-history' || p.body.includes('Earlier requests')
            check(`Q27 [admin] ${x.code}: the request panel no longer lists "Earlier requests" (the trail replaced it)`, rendered(p) && !old, 'the old history section is still drawn')
            const g = await get('gm', `/hr/payroll/${x.id}`)
            check(`payroll [gm] ${x.code}: rendered for an hr.view reader without data.view_pay`, rendered(g) && sectionAt(g.body, 'audit-trail').state === 'entries', `HTTP ${g.status}`)
        }
        if (!periods.length) skipped.push('payroll: no payroll period on live (fixture 246 PP and the rolled-back proof cover it)')
        // ── 每一份评审:页底一段(线上 0 份时照直说)────────────────────────────────────────────
        for (const r of reviews) {
            const p = await get('admin', `/hr/reviews/${r.id}`)
            const t = sectionAt(p.body, 'audit-trail')
            check(`review [admin] ${r.id.slice(0, 8)}: the trail opens with the review's opening`, rendered(p) && t.state === 'entries' && /review opened/.test(t.text),
                `HTTP ${p.status}, state ${t.state}`)
        }
        if (!reviews.length) skipped.push('reviews: no performance review on live (fixture 246 RV · MR · RX, the smoke\'s throwaway review and the rolled-back proof cover it)')
        // ── 轮次那一块 · 评分刻度一段(M11)· KPI 那一块(选了一个有条目的月份)────────────────────────────
        const cp = await get('admin', '/hr/reviews/cycles')
        check(`cycles [admin] /hr/reviews/cycles: the block is drawn (live cycles: ${cycles.length})`, rendered(cp) && ['entries', 'empty'].includes(sectionAt(cp.body, 'audit-trail').state), `HTTP ${cp.status}`)
        const sp = await get('admin', '/hr/reviews/scale')
        const st = sectionAt(sp.body, 'audit-trail')
        check('M11 [admin] /hr/reviews/scale: one trail for the whole scale, with «Rating added»', rendered(sp) && st.state === 'entries' && st.text.includes('Rating added'),
            `HTTP ${sp.status}, state ${st.state}`)
        for (const m of kpiMonths) {
            const kp = await get('gm', `/hr/kpi/score?cycle=${m.id}`)
            const kt = sectionAt(kp.body, 'audit-trail')
            check(`KPI [gm] ${m.name}: the block lists the month's entries, «KPI entries generated»`, rendered(kp) && kt.state === 'entries' && /KPI entr(y|ies) generated/.test(kt.text),
                `HTTP ${kp.status}, state ${kt.state}, «${kt.text.slice(0, 160)}»`)
        }
        if (!kpiMonths.length) skipped.push('KPI: no KPI month with entries on live')
        // 一个看不见分数的读者(不持 data.view_reviews):那一块根本不画(页面那一支已经说了一句具名的"受限")
        if (kpiMonths.length) {
            const wh = await get('warehouse', `/hr/kpi/score?cycle=${kpiMonths[0].id}`)
            check('KPI [warehouse] the page refuses a reader without hr.view, and draws no KPI trail', !wh.body.includes('data-audit-trail="entries"'), `HTTP ${wh.status}`)
        }
        // ── Q14 · Q16:/me 上没有评审与 KPI 的审计记录(按源码:/me 只认三种自己的单据)────────────────────
        {
            let meSrc = ['app/me/page.tsx', 'app/me/MyLeavePanel.tsx', 'app/me/MyClaimsPanel.tsx'].map((f) => readFileSync(join(ROOT, f), 'utf8')).join('\n')
            if (INJECT === 'me-review-trail') meSrc += '\n<AuditTrail subject="my_review" id={x} show={20} />'
            const subs = [...meSrc.matchAll(/<AuditTrail[^>]*subject="([a-z_]+)"/g)].map((m) => m[1])
            const allowed = new Set(['my_leave_request', 'my_medical_claim', 'my_expense_claim'])
            check(`Q14 · Q16 /me: only the three own-request trails (${[...new Set(subs)].join(', ')}), no review or KPI trail`,
                subs.length >= 3 && subs.every((s) => allowed.has(s)), `subjects on /me: ${subs.join(', ')}`)
        }

        // ── 每一页的每一段:没有机器字;中文界面逐字相同(1d-3 的页 + 1d-2 / 1d-1 各一页作对照)──────────────────
        const pages = [...periods.map((x) => `/hr/payroll/${x.id}`), ...reviews.map((r) => `/hr/reviews/${r.id}`),
            '/hr/reviews/cycles', '/hr/reviews/scale', ...kpiMonths.map((m) => `/hr/kpi/score?cycle=${m.id}`),
            leave && `/hr/leave/${leave.id}`, emp && `/hr/employees/${emp.id}`].filter(Boolean)
        for (const path of pages) {
            const p = await get('admin', path)
            const secs = trailSections(p.body)
            let text = secs.join(' ')
            if (INJECT === 'machine') text += ' 6f1c2a9e-3b4d-4e5f-8a9b-0c1d2e3f4a5b'
            const hits = machineTokens(text)
            check(`page [admin] ${path}: ${secs.length} trail section(s) rendered, no machine token`, rendered(p) && secs.length > 0 && !hits.length,
                `HTTP ${p.status}, sections ${secs.length}, tokens ${hits.slice(0, 4).map((h) => h.token).join(', ')}`)
            const z = await get('admin', path, 'zh')
            let zt = trailSections(z.body).join(' | ')
            const et = secs.join(' | ')
            if (INJECT === 'cjk') zt += ' 受限'
            let at2 = 0
            while (at2 < zt.length && zt[at2] === et[at2]) at2++
            check(`fold-in 3 [admin] ${path}: every trail section reads the same in the Chinese interface (${et.length} chars)`, z.status === 200 && zt.length > 0 && zt === et,
                `zh ${zt.length} chars vs en ${et.length}; they part at ${at2}: zh "…${zt.slice(Math.max(0, at2 - 40), at2 + 30)}…" · en "…${et.slice(Math.max(0, at2 - 40), at2 + 30)}…"`)
        }
    } finally {
        await runPlan()
        dev.kill()
    }

    console.log('\n== 结果 ==')
    for (const p of passed) console.log('  ✓ ' + p)
    for (const s of skipped) console.log('  · SKIP ' + s)
    for (const f of failures) console.log('  ✗ ' + f)
    if (INJECT) console.log(`\n· 本跑带着注入 --inject=${INJECT}(${INJECTIONS[INJECT]})`)
    const code = failures.length ? 1 : (process.exitCode || 0)
    console.log(`\n${passed.length} passed · ${failures.length} failed · ${skipped.length} skipped`)
    console.log(`AT1D3_PROBE_EXIT=${code}`)
    return exitAfterCleanup(code)
}

let devProc = null
installExitHooks({ onFinish: () => {
    try { if (devProc && devProc.exitCode === null) devProc.kill() } catch {}
    try { release() } catch {}
} })

main().catch(async (e) => {
    console.error('✗ 探针自己坏了:' + (e?.stack || e))
    console.log('AT1D3_PROBE_EXIT=2')
    return exitAfterCleanup(2)
})
