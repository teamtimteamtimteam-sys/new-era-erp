#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// AUDIT-TRAIL-1d-2 · 页面这一层的探针 —— 「以【真角色的码】的身份把请假与考勤那几页取回来,看屏幕上说了什么」
// ════════════════════════════════════════════════════════════════════════════
// 【为什么在 fixture 之外还要它】fixture 245 证的是读法;每一张请假 / 医疗报销 / 加班批 / 考勤期间的页底一段、假别与公共假期
//   各一段(M11)、发放那一块、费用页够得到那张医疗报销(Q37)、只持 overtime_approve 的仓库打得开加班那一页(M1)、
//   中文界面里审计记录那一段逐字不变(折入 3)住在页面上。形状照 probe-at1d1.mjs。
// 【受测的人】三个一次性账号(与冒烟同一套 ephemeral 计划,跑完收走 —— 线上那七个真账号一个都不碰):
//   admin · gm(每一个模块,持 hr.view)· warehouse(持 overtime_approve,不持 hr.view —— Q20 的读者)。
//   /me 那两块要一个【绑着员工档案】的账号,一次性账号没有 —— 它们由 fixture 245 的 M 臂与线上回滚的证明(以真员工的身份)证。
//   ★ U1-B(2026-10-05,GHOST-GRANTS):上面说的「授某角色」现在是【一次性克隆】—— 恰好持那个真角色此刻的码,
//     不是真角色本身;「admin」那一位是一次性全码角色(admin 自 ROLE-1 起只剩三个系统码)。没有一格依赖真角色码。
// 退出码:0 = 全过;1 = 有断言失败;2 = 探针自己坏了。★ 判决只从日志里那一行 `AT1D2_PROBE_EXIT=` 读。
// 用法:node scripts/probe-at1d2.mjs [--inject=<case>]   见 INJECTIONS —— 每一种都必须让一条具体的断言变红。
// ════════════════════════════════════════════════════════════════════════════
import { readFileSync } from 'node:fs'
import { spawn, execSync } from 'node:child_process'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { acquireOrExit, release } from './liveLock.mjs'
import { openPlan, mintThrowaway, runPlan, reapStalePlans, installExitHooks, exitAfterCleanup } from './ephemeral.mjs'
import { machineTokens } from '../lib/trail/machineTokens.ts'

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)))
const PORT = 3189            // 不与冒烟(3199)、版式(3198)、角色探针(3197)、1b-1 … 1d-1(3196 … 3190)探针撞
const env = readFileSync(join(ROOT, '.env.local'), 'utf8')
const URL_ = env.match(/NEXT_PUBLIC_SUPABASE_URL=(\S+)/)[1]
const SERVICE = env.match(/SUPABASE_SERVICE_ROLE_KEY=(\S+)/)[1]
const INJECT = (process.argv.find((a) => a.startsWith('--inject=')) || '').slice(9) || null
const INJECTIONS = {
    'q37-missing': '期望费用页上【没有】那张医疗报销 —— Q37 那一条必须红',
    'machine': '往每一段里塞一个 uuid —— 机器字那几条必须红',
    'cjk': '往中文那一份里塞一个中文字 —— 折入 3 那几条必须红',
}
if (INJECT && !INJECTIONS[INJECT]) {
    console.error(`✗ --inject=${INJECT} 不认识。可选:${Object.keys(INJECTIONS).join(' / ')}`)
    console.log('AT1D2_PROBE_EXIT=2')
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
    acquireOrExit('scripts/probe-at1d2.mjs', { ownExit: false })
    openPlan('scripts/probe-at1d2.mjs')
    await reapStalePlans()
    if (!sweepStalePort()) return exitAfterCleanup(2)

    // ── 受测的行(线上真有的;以 service_role 读,绕过 RLS,是真行数)──────────────────────────
    const leaves = await restRows('/rest/v1/leave_requests?select=id,code&order=code', 'leave requests')
    const claims = await restRows('/rest/v1/medical_claims?select=id,code,expense_id&order=code', 'medical claims')
    const batches = await restRows('/rest/v1/overtime_batches?select=id,label&order=label', 'overtime batches')
    const periods = await restRows('/rest/v1/attendance_periods?select=id,code&order=code', 'attendance periods')
    const grants = await restRows('/rest/v1/leave_grants?select=id,leave_year&order=leave_year', 'leave grants')
    const one = async (path, ctx) => (await restRows(path, ctx))[0] ?? null
    const po = await one('/rest/v1/purchase_orders?select=id,code&order=code&limit=1', 'a purchase order')
    const emp = await one('/rest/v1/employees?select=id,code&deleted_at=is.null&order=code&limit=1', 'an employee')
    console.log(`· live: ${leaves.length} leave requests · ${claims.length} medical claims · ${batches.length} overtime batches · ${periods.length} attendance periods · ${grants.length} leave grants`)

    // ── 三个一次性账号:admin · gm · warehouse ─────────────────────────────────────────────────────
    const stamp = Date.now()
    const cookies = {}
    for (const roleCode of ['admin', 'gm', 'warehouse']) {
        // ★ U1-B(2026-10-05,GHOST-GRANTS):此前授的是【真角色】本身(含真 admin)。现在经 mintThrowaway:
        //   admin → 一次性全码角色('all' —— 本探针拿 admin 当"什么都看得见"的那位读者);
        //   其余 → 一次性克隆({ cloneOf }:恰好持那个真角色此刻的码)。本探针的每一格都是"持这些码的人
        //   页面上看见什么"(打不打得开、横幅、受限、具名拒绝),没有一格问"这个人是不是审批人",
        //   所以不需要真角色码。邮箱形状不变:at1d2probe-<stamp>-<角色>@test.local。
        const tw = await mintThrowaway({ prefix: 'at1d2probe', label: roleCode, stamp, password: 'at1d2-probe-1',
            codes: roleCode === 'admin' ? 'all' : { cloneOf: roleCode } })
        cookies[roleCode] = tw.cookie
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
        console.log('AT1D2_PROBE_EXIT=2')
        return exitAfterCleanup(2)
    }

    try {
        const get = async (role, path, locale = 'en') => {
            const r = await fetch(`http://localhost:${PORT}${path}`, { headers: { cookie: `${cookies[role]}; NEXT_LOCALE=${locale}` } })
            return { status: r.status, body: await r.text() }
        }
        const rendered = (p) => p.status === 200 && !THROWN.test(p.body)

        // ── 每一张请假:页底一段,有它的申请;gm(持 hr.view)也读得到 ───────────────────────────────
        for (const l of leaves) {
            const p = await get('admin', `/hr/leave/${l.id}`)
            const t = sectionAt(p.body, 'audit-trail')
            check(`leave [admin] ${l.code}: the trail opens with «Leave requested»`, rendered(p) && t.state === 'entries' && /Leave requested: /.test(t.text),
                `HTTP ${p.status}, state ${t.state}, «${t.text.slice(0, 120)}»`)
        }
        if (leaves.length) {
            const g = await get('gm', `/hr/leave/${leaves[0].id}`)
            check(`leave [gm] ${leaves[0].code}: rendered for an hr.view reader`, rendered(g) && sectionAt(g.body, 'audit-trail').state === 'entries', `HTTP ${g.status}`)
        }
        // ── 医疗报销:页底一段;Q37 —— 付它的那张费用单的页上读得到这张报销单 ─────────────────────────────
        for (const c of claims) {
            const p = await get('admin', `/hr/claims/${c.id}`)
            const t = sectionAt(p.body, 'audit-trail')
            check(`claim [admin] ${c.code}: the trail opens with «Medical claim submitted»`, rendered(p) && t.state === 'entries' && /Medical claim submitted: /.test(t.text),
                `HTTP ${p.status}, state ${t.state}, «${t.text.slice(0, 120)}»`)
            if (c.expense_id) {
                const e = await get('admin', `/finance/expenses/${c.expense_id}`)
                const et = sectionAt(e.body, 'audit-trail')
                const has = new RegExp(`Medical claim [a-z]+[^·]*· ${c.code}`).test(et.text)
                check(`Q37 [admin] the expense of ${c.code}: its trail names the claim`, rendered(e) && (INJECT === 'q37-missing' ? !has : has),
                    `HTTP ${e.status}, state ${et.state}, «${et.text.slice(0, 200)}»`)
            } else skipped.push(`Q37: ${c.code} has no expense`)
        }
        // ── 加班(M1)· 考勤:每一张一段(线上 0 张时照直说)──────────────────────────────────────
        for (const b of batches) {
            const p = await get('warehouse', `/hr/overtime/${b.id}`)
            check(`overtime [warehouse] ${b.label}: rendered with its trail (M1)`, rendered(p) && sectionAt(p.body, 'audit-trail').state === 'entries', `HTTP ${p.status}`)
        }
        if (!batches.length) skipped.push('overtime: no overtime batch on live (fixture 245 O · D and the rolled-back proof cover it)')
        if (!periods.length) skipped.push('attendance: no attendance period on live (fixture 245 A and the rolled-back proof cover it)')
        // ── 假别 · 公共假期(M11):各一段,有记录开始之前的建立 ─────────────────────────────────────
        for (const [path, word] of [['/hr/leave/types', 'Leave type added'], ['/hr/leave/holidays', 'Public holiday added']]) {
            const p = await get('admin', path)
            const t = sectionAt(p.body, 'audit-trail')
            check(`M11 [admin] ${path}: one trail for the whole table, with «${word}»`, rendered(p) && t.state === 'entries' && t.text.includes(word),
                `HTTP ${p.status}, state ${t.state}`)
        }
        const gp = await get('admin', '/hr/leave/grants')
        check(`grants [admin] /hr/leave/grants: the block is drawn (live grants this year: ${grants.filter((g) => g.leave_year === new Date().getFullYear()).length})`,
            rendered(gp) && ['entries', 'empty'].includes(sectionAt(gp.body, 'audit-trail').state), `HTTP ${gp.status}`)

        // ── 每一页的每一段:没有机器字;中文界面逐字相同 ──────────────────────────────────────────
        const pages = [...leaves.map((l) => `/hr/leave/${l.id}`), ...claims.map((c) => `/hr/claims/${c.id}`),
            ...claims.filter((c) => c.expense_id).map((c) => `/finance/expenses/${c.expense_id}`),
            ...batches.map((b) => `/hr/overtime/${b.id}`), ...periods.map((x) => `/hr/attendance/${x.id}`),
            '/hr/leave/types', '/hr/leave/holidays', '/hr/leave/grants',
            emp && `/hr/employees/${emp.id}`, po && `/purchasing/orders/${po.id}`].filter(Boolean)
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
    console.log(`AT1D2_PROBE_EXIT=${code}`)
    return exitAfterCleanup(code)
}

let devProc = null
installExitHooks({ onFinish: () => {
    try { if (devProc && devProc.exitCode === null) devProc.kill() } catch {}
    try { release() } catch {}
} })

main().catch(async (e) => {
    console.error('✗ 探针自己坏了:' + (e?.stack || e))
    console.log('AT1D2_PROBE_EXIT=2')
    return exitAfterCleanup(2)
})
