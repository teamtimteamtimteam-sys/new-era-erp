#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// AUDIT-TRAIL-1d-1 · 页面这一层的探针 —— 「以【真角色的码】的身份把账号、设置与员工那几页取回来,看屏幕上说了什么」
// ════════════════════════════════════════════════════════════════════════════
// 【为什么在 fixture 之外还要它】fixture 244 证的是读法;每一个账号一段(Q24)、员工页上账号的镜像对人事读者是 Restricted(Q21)、
//   角色页说出授给了谁(Q22)、审批方针那一段只说它那四列(Q25)、六本字典各一段(M11)、导入批次那一块与"谁"一栏(Q24)、
//   删掉的角色与员工只读打开 / 具名拒绝(Q25 · Q26)、中文界面里审计记录那一段逐字不变(折入 3)住在页面上。形状照 probe-at1c3.mjs。
// 【受测的人】两个一次性账号(与冒烟同一套 ephemeral 计划,跑完收走 —— 线上那七个真账号一个都不碰):
//   admin(持 manage_permissions 与 data.view_deleted)· gm(每一个模块,持 hr.view,【不】持 manage_permissions、【不】持 data.view_deleted)。
//   ★ U1-B(2026-10-05,GHOST-GRANTS):上面说的「授某角色」现在是【一次性克隆】—— 恰好持那个真角色此刻的码,
//     不是真角色本身;「admin」那一位是一次性全码角色(admin 自 ROLE-1 起只剩三个系统码)。没有一格依赖真角色码。
// 退出码:0 = 全过;1 = 有断言失败;2 = 探针自己坏了。★ 判决只从日志里那一行 `AT1D1_PROBE_EXIT=` 读。
// 用法:node scripts/probe-at1d1.mjs [--inject=<case>]   见 INJECTIONS —— 每一种都必须让一条具体的断言变红。
// ════════════════════════════════════════════════════════════════════════════
import { readFileSync } from 'node:fs'
import { spawn, execSync } from 'node:child_process'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { acquireOrExit, release } from './liveLock.mjs'
import { openPlan, mintThrowaway, runPlan, reapStalePlans, installExitHooks, exitAfterCleanup } from './ephemeral.mjs'
import { machineTokens } from '../lib/trail/machineTokens.ts'

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)))
const PORT = 3190            // 不与冒烟(3199)、版式(3198)、角色探针(3197)、1b-1 … 1c-3(3196 … 3191)探针撞
const env = readFileSync(join(ROOT, '.env.local'), 'utf8')
const URL_ = env.match(/NEXT_PUBLIC_SUPABASE_URL=(\S+)/)[1]
const SERVICE = env.match(/SUPABASE_SERVICE_ROLE_KEY=(\S+)/)[1]
const INJECT = (process.argv.find((a) => a.startsWith('--inject=')) || '').slice(9) || null
const INJECTIONS = {
    'mirror-leak': '期望 gm 在员工页上【读得到】账号事件 —— Q21 那一条必须红',
    'no-grant': '期望 cto 角色页上【没有】授权 —— Q22 那一条必须红',
    'refusal-wrong': '期望 gm 读到删掉的员工而不是一句拒绝 —— Q26 那一条必须红',
    'cjk': '往中文那一份里塞一个中文字 —— 折入 3 那几条必须红',
}
if (INJECT && !INJECTIONS[INJECT]) {
    console.error(`✗ --inject=${INJECT} 不认识。可选:${Object.keys(INJECTIONS).join(' / ')}`)
    console.log('AT1D1_PROBE_EXIT=2')
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
    acquireOrExit('scripts/probe-at1d1.mjs', { ownExit: false })
    openPlan('scripts/probe-at1d1.mjs')
    await reapStalePlans()
    if (!sweepStalePort()) return exitAfterCleanup(2)

    // ── 受测的行(线上真有的;每一种的条数照直报 —— 以 service_role 读,绕过 RLS,是真行数)──────────────────────────
    // user_directory 的谓词问的是读者有没有 manage_permissions —— 以 service_role 读它恒为 0 行(那是一次权限答复,不是一次测量)。
    //   账号名单从 auth 的管理接口读(service_role)
    const au = await rest('/auth/v1/admin/users?per_page=200')
    if (!au.ok) throw new Error(`auth admin users: HTTP ${au.status}`)
    const accounts = ((await au.json()).users ?? []).map((u) => ({ user_id: u.id, email: u.email }))
    if (!accounts.length) throw new Error('auth admin users: 0 accounts — the probe cannot be blind')
    const linked = await restRows('/rest/v1/employees?select=id,code,user_id&deleted_at=is.null&user_id=not.is.null&order=code', 'linked employees')
    const liveEmps = await restRows('/rest/v1/employees?select=id,code&deleted_at=is.null&order=code', 'live employees')
    const delEmp = await restRows('/rest/v1/employees?select=id,code&deleted_at=not.is.null&order=code&limit=1', 'a deleted employee')
    const delRole = await restRows('/rest/v1/roles?select=id,code&deleted_at=not.is.null&order=code&limit=1', 'a deleted role')
    const cto = (await restRows('/rest/v1/roles?select=id&code=eq.cto', 'cto role'))[0]
    const ctoGrants = await restRows(`/rest/v1/user_roles?select=id,user_id&role_id=eq.${cto.id}`, 'cto grants')
    const dept = (await restRows('/rest/v1/departments?select=id&deleted_at=is.null&order=code&limit=1', 'a department'))[0]
    const trn = (await restRows('/rest/v1/training_records?select=id&deleted_at=is.null&limit=1', 'a training record'))[0]
    const one = async (path, ctx) => (await restRows(path, ctx))[0] ?? null
    const po = await one('/rest/v1/purchase_orders?select=id,code&order=code&limit=1', 'a purchase order')
    const je = await one('/rest/v1/journal_entries?select=id,code&code=eq.JE-2026-0001', 'JE-2026-0001')
    console.log(`· live: ${accounts.length} accounts · ${linked.length} linked employees · ${ctoGrants.length} cto grants · deleted: ${delEmp.length} employee, ${delRole.length} role`)

    // ── 两个一次性账号:admin · gm ─────────────────────────────────────────────────────
    const stamp = Date.now()
    const cookies = {}
    for (const roleCode of ['admin', 'gm']) {
        // ★ U1-B(2026-10-05,GHOST-GRANTS):此前授的是【真角色】本身(含真 admin)。现在经 mintThrowaway:
        //   admin → 一次性全码角色('all' —— 本探针拿 admin 当"什么都看得见"的那位读者);
        //   其余 → 一次性克隆({ cloneOf }:恰好持那个真角色此刻的码)。本探针的每一格都是"持这些码的人
        //   页面上看见什么"(打不打得开、横幅、受限、具名拒绝),没有一格问"这个人是不是审批人",
        //   所以不需要真角色码。邮箱形状不变:at1d1probe-<stamp>-<角色>@test.local。
        const tw = await mintThrowaway({ prefix: 'at1d1probe', label: roleCode, stamp, password: 'at1d1-probe-1',
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
        console.log('AT1D1_PROBE_EXIT=2')
        return exitAfterCleanup(2)
    }

    try {
        const get = async (role, path, locale = 'en') => {
            const r = await fetch(`http://localhost:${PORT}${path}`, { headers: { cookie: `${cookies[role]}; NEXT_LOCALE=${locale}` } })
            return { status: r.status, body: await r.text() }
        }
        const rendered = (p) => p.status === 200 && !THROWN.test(p.body)

        // ── Q24:每一个账号一段,每一段有它的建立(线上的七个真账号:记录开始之前那一行)──────────────────────
        const a = await get('admin', '/settings/accounts')
        const real = accounts.filter((x) => !String(x.email ?? '').startsWith('at1d1probe-'))
        const per = real.map((x) => ({ email: x.email, sec: sectionAt(a.body, `account-trail-${x.user_id}`) }))
        check(`Q24 [admin] /settings/accounts: one trail per account (${real.length}), each with its creation`,
            rendered(a) && per.every((x) => x.sec.state === 'entries' && /Account created/.test(x.sec.text)),
            per.filter((x) => x.sec.state !== 'entries' || !/Account created/.test(x.sec.text)).map((x) => `${x.email}: ${x.sec.state}`).join(', '))

        // ── Q21 · Q24:员工页上的账号镜像 —— admin 读得到账号的建立;gm(hr.view,无 manage_permissions)那几行是 Restricted ──
        if (linked.length) {
            const e = linked[0]
            const ea = await get('admin', `/hr/employees/${e.id}`)
            const eg = await get('gm', `/hr/employees/${e.id}`)
            const ta = sectionAt(ea.body, 'audit-trail'), tg = sectionAt(eg.body, 'audit-trail')
            check(`Q24 [admin] /hr/employees/${e.code}: the mirror shows the login account's creation`,
                rendered(ea) && ta.state === 'entries' && /Account created/.test(ta.text), `state ${ta.state}`)
            const wantLeak = INJECT === 'mirror-leak'
            check(`Q21 [gm]    /hr/employees/${e.code}: account events read Restricted, never "Account created"`,
                rendered(eg) && tg.state === 'entries' && (wantLeak ? /Account created/.test(tg.text) : (!/Account created/.test(tg.text) && /Restricted/.test(tg.text))),
                `state ${tg.state}, created ${/Account created/.test(tg.text)}, restricted ${/Restricted/.test(tg.text)}`)
        } else skipped.push('Q21 mirror: no employee is linked to a login account on live')

        // ── Q22:cto 角色页说出授给了谁 ────────────────────────────────────────────────────────
        const rp = await get('admin', `/settings/roles/${cto.id}`)
        const rt = sectionAt(rp.body, 'audit-trail')
        const wantGrant = INJECT !== 'no-grant'
        check(`Q22 [admin] /settings/roles (cto): «Role granted to …» for each of its ${ctoGrants.length} grant(s)`,
            rendered(rp) && rt.state === 'entries' && ((rt.text.match(/Role granted to /g) ?? []).length >= ctoGrants.length) === wantGrant,
            `state ${rt.state}, «Role granted to» ×${(rt.text.match(/Role granted to /g) ?? []).length}`)

        // ── Q25:审批方针那一段只说它那四列 ──────────────────────────────────────────────────
        const ap = await get('admin', '/settings/approvals')
        const at = sectionAt(ap.body, 'audit-trail')
        check(`Q25 [admin] /settings/approvals: the policy trail («Approvals switched on»), no lock or GST wording`,
            rendered(ap) && at.state === 'entries' && /Approvals switched on/.test(at.text) && !/Period lock|GST|Month closed/.test(at.text)
            && !/Changes to this policy/.test(ap.body), `state ${at.state}, text «${at.text.slice(0, 160)}»`)

        // ── M11:六本字典各一段 ───────────────────────────────────────────────────────────────
        const dp = await get('admin', '/settings/dictionaries')
        const dsec = ['substances', 'battery_chemistries', 'material_kinds', 'inbound_safety_states', 'laboratories', 'inbound_source_reasons']
            .map((t) => ({ t, sec: sectionAt(dp.body, `dict-trail-${t}`) }))
        check(`M11 [admin] /settings/dictionaries: one trail per dictionary (6), none refused`,
            rendered(dp) && dsec.every((x) => ['entries', 'empty'].includes(x.sec.state)), dsec.map((x) => `${x.t}: ${x.sec.state}`).join(', '))

        // ── Q24:导入批次那一块与"谁"一栏 ──────────────────────────────────────────────────────
        const ip = await get('admin', '/settings/import')
        const it = sectionAt(ip.body, 'audit-trail')
        check(`Q24 [admin] /settings/import: the batch block («imported from a file») and the Who column`,
            rendered(ip) && it.state === 'entries' && /imported from a file/.test(it.text) && />Who</.test(ip.body), `state ${it.state}`)

        // ── Q25 · Q26:删掉的角色、删掉的员工 —— 只读 + 横幅;不持 data.view_deleted 的人一句具名拒绝 ────────────────
        if (delRole.length) {
            const d = await get('admin', `/settings/roles/${delRole[0].id}`)
            check(`Q25 [admin] deleted role ${delRole[0].code}: read-only with «Deleted on …» and its trail`,
                rendered(d) && /data-ended-banner="deleted"/.test(d.body) && /Deleted on /.test(d.body) && /data-ended-readonly/.test(d.body)
                && sectionAt(d.body, 'audit-trail').state === 'entries', `HTTP ${d.status}`)
        } else skipped.push('Q25: no deleted role on live')
        if (delEmp.length) {
            const d = await get('admin', `/hr/employees/${delEmp[0].id}`)
            check(`Q26 [admin] deleted employee ${delEmp[0].code}: read-only with «Deleted on …» and its trail`,
                rendered(d) && /data-ended-banner="deleted"/.test(d.body) && /data-ended-readonly/.test(d.body) && sectionAt(d.body, 'audit-trail').state === 'entries',
                `HTTP ${d.status}`)
            const g = await get('gm', `/hr/employees/${delEmp[0].id}`)
            const refused = /This record has been deleted/.test(g.body) && !/data-ended-banner/.test(g.body)
            check(`Q26 [gm]    deleted employee ${delEmp[0].code}: a named refusal, not a 404`,
                g.status === 200 && !THROWN.test(g.body) && (INJECT === 'refusal-wrong' ? !refused : refused), `HTTP ${g.status}, refused ${refused}`)
        } else skipped.push('Q26: no deleted employee on live')
        const sd = await get('admin', '/settings/deleted')
        check(`Q25 · Q26 [admin] /settings/deleted links the deleted role and employee`,
            rendered(sd) && (!delRole.length || sd.body.includes(`/settings/roles/${delRole[0].id}`)) && (!delEmp.length || sd.body.includes(`/hr/employees/${delEmp[0].id}`))
            && !sd.body.includes('deleted' + '.kind.'), `HTTP ${sd.status}`)

        // ── 每一页的每一段:没有机器字;中文界面逐字相同 ──────────────────────────────────────────
        const pages = ['/settings/accounts', '/settings/approvals', '/settings/dictionaries', '/settings/import', `/settings/roles/${cto.id}`,
            ...liveEmps.map((e) => `/hr/employees/${e.id}`), dept && `/hr/departments/${dept.id}/edit`, trn && `/hr/training/${trn.id}/edit`,
            po && `/purchasing/orders/${po.id}`, je && `/finance/journal/${je.id}`, '/finance/settings'].filter(Boolean)
        for (const path of pages) {
            const p = await get('admin', path)
            const secs = trailSections(p.body)
            const text = secs.join(' ')
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
    console.log(`AT1D1_PROBE_EXIT=${code}`)
    return exitAfterCleanup(code)
}

let devProc = null
installExitHooks({ onFinish: () => {
    try { if (devProc && devProc.exitCode === null) devProc.kill() } catch {}
    try { release() } catch {}
} })

main().catch(async (e) => {
    console.error('✗ 探针自己坏了:' + (e?.stack || e))
    console.log('AT1D1_PROBE_EXIT=2')
    return exitAfterCleanup(2)
})
