#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// U1-A · 线上的角色对照表 —— 「以七个真账号的权限、外加一个没有任何 HR 权限的普通员工,读同一组东西:看得见什么、什么是受限」
// ════════════════════════════════════════════════════════════════════════════
// 【读什么】一张工资分录(发薪那一张,一人一行)· 一个工资期 · 工资申请 · 一张医疗报销 · 一张带事由的请假单 ·
//   设备保养建议那张视图 · 自己的 /me。每一样两条路:API(以那个人的令牌直接问 PostgREST)与屏幕(以那个人的会话取页面)。
// 【受测的人】八个一次性账号,与冒烟同一套 ephemeral 计划,跑完收走 —— 线上那七个真账号一个都不碰:
//   七个各持一个真角色(admin · cfo · finance · cco · cto · gm · warehouse —— 线上七个账号各自的那一个),
//   第八个不持任何角色,绑一个一次性的员工档案(ZZ-SMOKE- 前缀,随计划删掉)—— "一个没有 HR 权限的普通员工"。
// 【只读】不写任何一张单据;唯一的写是账号、授权与那一个员工档案,全部经计划收回。
// 【判据】每一格都对着裁定写:持 data.view_pay 的人看得见工资分录与工资期的数,不持的人是「受限」(API:工资分录的行不在、
//   遮蔽视图里是 null;屏幕:Restricted);健康数据同理按 data.view_health(本人除外);设备保养的钱按 module.finance.view。
// 退出码:0 = 全过;1 = 有断言失败;2 = 探针自己坏了。★ 判决只从日志里那一行 `U1A_PROBE_EXIT=` 读。
// 用法:node scripts/probe-u1a.mjs [--inject=<case>]   见 INJECTIONS —— 每一种都必须让一条具体的断言变红。
// ════════════════════════════════════════════════════════════════════════════
import { readFileSync, writeFileSync } from 'node:fs'
import { spawn, execSync } from 'node:child_process'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { acquireOrExit, release } from './liveLock.mjs'
import { openPlan, planDelete, ephemeralGrantBody, runPlan, reapStalePlans, installExitHooks, exitAfterCleanup, ORDER } from './ephemeral.mjs'

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)))
const PORT = 3187            // 不与冒烟(3199)、版式(3198)、1b-1 … 1d-3(3196 … 3188)探针撞
const env = readFileSync(join(ROOT, '.env.local'), 'utf8')
const URL_ = env.match(/NEXT_PUBLIC_SUPABASE_URL=(\S+)/)[1]
const ANON = env.match(/NEXT_PUBLIC_SUPABASE_ANON_KEY=(\S+)/)[1]
const SERVICE = env.match(/SUPABASE_SERVICE_ROLE_KEY=(\S+)/)[1]
const INJECT = (process.argv.find((a) => a.startsWith('--inject=')) || '').slice(9) || null
const INJECTIONS = {
    'cto-sees-pay': '当作 cto 经 API 读到了工资分录的金额 —— 工资分录那一格必须红',
    'screen-zero': '当作分录页对 cto 印了 0.00 而不是 Restricted —— 屏幕那一格必须红',
    'warehouse-cost': '当作仓库读到了维修花费 —— 设备保养那一格必须红',
}
if (INJECT && !INJECTIONS[INJECT]) {
    console.error(`✗ --inject=${INJECT} 不认识。可选:${Object.keys(INJECTIONS).join(' / ')}`)
    console.log('U1A_PROBE_EXIT=2')
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
    return {
        token: sess.access_token,
        cookie: 'sb-' + URL_.split('//')[1].split('.')[0] + '-auth-token=base64-' + Buffer.from(JSON.stringify(sess)).toString('base64url'),
    }
}
/** 以一个人的令牌问 PostgREST:{ status, rows | null, code } —— 42501 与 0 行分开说 */
async function asUser(who, path) {
    const r = await fetch(URL_ + path, { headers: { apikey: ANON, Authorization: `Bearer ${who.token}` } })
    const body = await r.text()
    let j = null
    try { j = JSON.parse(body) } catch { /* 非 JSON */ }
    return { status: r.status, rows: Array.isArray(j) ? j : null, code: j && !Array.isArray(j) ? j.code : null, raw: body.slice(0, 200) }
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
const THROWN = /Application error: a server-side exception|__next_error__/
const strip = (html) => html.replace(/<script[\s\S]*?<\/script>/g, ' ').replace(/<[^>]+>/g, ' ').replace(/&[a-z#0-9]+;/g, ' ').replace(/\s+/g, ' ')
const failures = []
const passed = []
const skipped = []
function check(label, ok, why) { (ok ? passed : failures).push(ok ? label : `${label}: ${why}`) }
const table = []   // 角色对照表的每一格:{ reader, item, api, screen }
const put = (reader, item, api, screen) => table.push({ reader, item, api, screen })

const ROLES = ['admin', 'cfo', 'finance', 'cco', 'cto', 'gm', 'warehouse']

async function main() {
    acquireOrExit('scripts/probe-u1a.mjs', { ownExit: false })
    openPlan('scripts/probe-u1a.mjs')
    await reapStalePlans()
    if (!sweepStalePort()) return exitAfterCleanup(2)

    // ── 受测的行(线上真有的;以 service_role 读,绕过 RLS,是真行数)───────────────────────────────────
    const payJe = (await restRows('/rest/v1/payroll_lines?select=paid_journal_entry_id&paid_journal_entry_id=not.is.null&limit=1', 'a paid payroll line'))[0]?.paid_journal_entry_id
    const period = (await restRows('/rest/v1/payroll_periods?select=id,code,gross_total,currency&order=code&limit=1', 'a payroll period'))[0]
    const payJeLines = payJe ? await restRows(`/rest/v1/journal_lines?select=id,debit,credit,line_memo&entry_id=eq.${payJe}`, 'pay-run lines') : []
    const payJeRow = payJe ? (await restRows(`/rest/v1/journal_entries?select=code,entry_date&id=eq.${payJe}`, 'pay-run code'))[0] : null
    const payJeCode = payJeRow?.code ?? null
    const requests = await restRows('/rest/v1/payroll_requests?select=id', 'payroll requests')
    const claim = (await restRows('/rest/v1/medical_claims?select=id,code,employee_id,description,amount_sgd&description=not.is.null&order=code&limit=1', 'a medical claim'))[0]
    const leave = (await restRows('/rest/v1/leave_requests?select=id,code,employee_id,reason&reason=not.is.null&order=code&limit=1', 'a leave request'))[0]
    const advice = await restRows('/rest/v1/equipment_maintenance?select=id,equipment_id', 'maintenance rows')
    const memo = payJeLines.find((l) => l.line_memo && /^EMP-/.test(l.line_memo))?.line_memo ?? null
    const amountText = payJeLines.length ? Number(Math.max(...payJeLines.map((l) => Number(l.debit) + Number(l.credit)))).toLocaleString('en-US', { minimumFractionDigits: 2 }) : null
    console.log(`· live: pay-run ${payJeCode} (${payJeLines.length} lines, memo «${memo}», ${amountText}) · period ${period?.code} · ${requests.length} payroll request(s) · claim ${claim?.code} · leave ${leave?.code} · ${advice.length} maintenance row(s)`)
    if (!payJe || !period || !claim || !leave) throw new Error('a subject is missing on live')

    // ── 八个一次性账号 ─────────────────────────────────────────────────────────────────────────────
    const stamp = Date.now()
    const who = {}
    for (const roleCode of [...ROLES, 'employee']) {
        const email = `u1aprobe-${stamp}-${roleCode}@test.local`
        const r = await rest('/auth/v1/admin/users', { method: 'POST', body: JSON.stringify({ email, password: 'u1a-probe-1', email_confirm: true }) })
        if (!r.ok) throw new Error(`建 ${roleCode} 账号失败:HTTP ${r.status} ${(await r.text()).slice(0, 200)}`)
        const u = await r.json()
        planDelete(`/rest/v1/user_roles?user_id=eq.${u.id}`, `revoke ${roleCode} grant ${u.id}`, ORDER.GRANT)
        planDelete(`/auth/v1/admin/users/${u.id}`, `delete ${roleCode} account ${u.id}`, ORDER.ACCOUNT)
        if (roleCode === 'employee') {
            // 普通员工:不持任何角色,绑一个一次性的员工档案(ZZ-SMOKE- 前缀,check-scratch-rows 认得)
            const e = await rest('/rest/v1/employees', { method: 'POST', headers: { Prefer: 'return=representation' },
                body: JSON.stringify({ code: `ZZ-SMOKE-U1A-${stamp}`, legal_name: 'ZZ U1A Probe', employment_type: 'full_time',
                    work_category: 'office', hire_date: '2026-01-01', user_id: u.id }) })
            if (!e.ok) throw new Error(`建员工档案失败:HTTP ${e.status} ${(await e.text()).slice(0, 200)}`)
            const row = (await e.json())[0]
            planDelete(`/rest/v1/employees?id=eq.${row.id}`, `delete probe employee ${row.code}`, ORDER.EMPLOYEE)
        } else {
            const rr = await restRows(`/rest/v1/roles?select=id&code=eq.${roleCode}`, `roles ← ${roleCode}`)
            const g = await rest('/rest/v1/user_roles', { method: 'POST', body: JSON.stringify(ephemeralGrantBody(u.id, rr[0].id)) })
            if (!g.ok) throw new Error(`授 ${roleCode} 失败:HTTP ${g.status} ${(await g.text()).slice(0, 200)}`)
        }
        who[roleCode] = await signIn(email, 'u1a-probe-1')
    }
    // 每个读者持什么(以 service_role 读真角色的码 —— 判据从这里推,不从记忆里写死)
    const perms = {}
    for (const roleCode of ROLES) {
        const rr = await restRows(`/rest/v1/role_permissions?select=permission_code,roles!inner(code)&roles.code=eq.${roleCode}`, `perms ← ${roleCode}`)
        perms[roleCode] = new Set(rr.map((x) => x.permission_code))
    }
    perms.employee = new Set()
    const has = (r, c) => perms[r].has(c)

    const logChunks = []
    const dev = spawn('npx', ['next', 'start', '-p', String(PORT)], { cwd: ROOT })
    devProc = dev
    dev.stdout.on('data', (d) => logChunks.push(d.toString()))
    dev.stderr.on('data', (d) => logChunks.push(d.toString()))
    const t0 = Date.now()
    let ready = false
    while (Date.now() - t0 < 90_000) {
        await new Promise((r) => setTimeout(r, 1000))
        if (/Ready in|started server|Local:/.test(logChunks.join(''))) { ready = true; break }
        if (dev.exitCode !== null) break
    }
    if (!ready) {
        console.error('✗ next start 没起来:\n' + logChunks.join('').split('\n').slice(-25).join('\n'))
        console.log('U1A_PROBE_EXIT=2')
        return exitAfterCleanup(2)
    }

    try {
        const get = async (role, path) => {
            const r = await fetch(`http://localhost:${PORT}${path}`, { headers: { cookie: `${who[role].cookie}; NEXT_LOCALE=en` }, redirect: 'manual' })
            return { status: r.status, body: await r.text() }
        }
        const pageState = (p, num) => {
            if (p.status >= 300 && p.status < 400) return 'redirect'
            if (p.status !== 200 || THROWN.test(p.body)) return `HTTP ${p.status}`
            const t = strip(p.body)
            if (/You do not have access|Restricted · |module you do not have/i.test(t) && !num) return 'refused (page)'
            return t
        }

        for (const r of [...ROLES, 'employee']) {
            const pay = has(r, 'data.view_pay'), fin = has(r, 'module.finance.view'), hr = has(r, 'module.hr.view'), health = has(r, 'data.view_health')

            // ── ① 工资分录(发薪那一张)──
            const api = await asUser(who[r], `/rest/v1/journal_lines?select=id,debit,credit&entry_id=eq.${payJe}`)
            const apiM = await asUser(who[r], `/rest/v1/journal_lines_masked?select=id,debit,credit,line_memo,amounts_restricted&entry_id=eq.${payJe}`)
            let apiRows = api.rows?.length ?? 0
            if (INJECT === 'cto-sees-pay' && r === 'cto') apiRows = payJeLines.length
            const apiText = !fin ? `0 rows (no finance)` : pay ? `${apiRows} lines with amounts` : `${apiRows} lines (base) · masked view ${apiM.rows?.length ?? 0} lines, amounts ${apiM.rows?.every((x) => x.debit === null && x.amounts_restricted) ? 'null' : 'VISIBLE'}`
            check(`journal [${r}] API: ${pay ? 'every line and amount' : fin ? 'no line on the base table, masked view all Restricted' : 'nothing'}`,
                !fin ? apiRows === 0 : pay ? apiRows === payJeLines.length : apiRows === 0 && apiM.rows?.length === payJeLines.length && apiM.rows.every((x) => x.debit === null && x.credit === null && x.amounts_restricted),
                apiText)
            if (fin && !pay) check(`journal [${r}] API: the line memo is visible (Q3)`, apiM.rows?.some((x) => x.line_memo === memo), `memo ${JSON.stringify(apiM.rows?.map((x) => x.line_memo))}`)
            const jp = await get(r, `/finance/journal/${payJe}`)
            const js = pageState(jp, true)
            let jsText = typeof js === 'string' && js.length > 40 ? (js.includes(amountText) ? `amount ${amountText}` : js.includes('Restricted') ? 'Restricted' : 'no amount') : js
            if (INJECT === 'screen-zero' && r === 'cto') jsText = '0.00'
            const jsMemo = typeof js === 'string' && memo ? js.includes(memo) : false
            check(`journal [${r}] screen: ${pay ? 'the amount' : fin ? 'Restricted, memo shown' : 'no access'}`,
                !fin ? !/amount|Restricted/.test(jsText) || jp.status !== 200 || js.includes('You do not have access') : pay ? jsText.startsWith('amount') && jsMemo : jsText === 'Restricted' && jsMemo,
                `${jsText} · memo ${jsMemo}`)
            put(r, 'Payroll journal (pay run)', apiText, !fin ? 'no finance access' : `${jsText}${jsMemo ? ' · memo shown' : ''}`)
            // 陷阱(Tim 的裁定):受限的金额读作 Restricted,绝不是 0.00 —— 分录页(含它的审计记录)与汇总那一页(分录列表)都要问
            const ZERO = /(^|[^\d.,])0\.00(?!\d)/
            if (fin && !pay) check(`journal [${r}] screen: no amount reads 0.00`, typeof js === 'string' && !ZERO.test(js), 'a bare 0.00 on the pay-run page')
            if (fin) {
                const jl = await get(r, `/finance/journal?date_from=${payJeRow.entry_date}&date_to=${payJeRow.entry_date}`)
                const jt = pageState(jl, true)
                const at = typeof jt === 'string' ? jt.indexOf(payJeCode) : -1
                const seg = at >= 0 ? jt.slice(at, at + 400).split(/JE-\d{4}-\d{4}/)[1] ?? jt.slice(at, at + 400) : ''
                const jlText = at < 0 ? `${payJeCode} not on the list` : seg.includes(amountText) ? `amount ${amountText}` : ZERO.test(seg) ? '0.00' : seg.includes('Restricted') ? 'Restricted' : 'no amount'
                check(`journal list [${r}] summary: ${pay ? 'the amount' : 'Restricted, never 0.00'}`, pay ? jlText.startsWith('amount') : jlText === 'Restricted', jlText)
                put(r, 'Journal list (summary)', '—', jlText)
            }

            // ── ② 工资期 ──
            const ppM = await asUser(who[r], `/rest/v1/payroll_periods_masked?select=gross_total,net_pay_total&id=eq.${period.id}`)
            const ppB = await asUser(who[r], `/rest/v1/payroll_periods?select=gross_total&id=eq.${period.id}`)
            const ppApi = !hr ? `0 rows (no HR)` : `masked view: totals ${ppM.rows?.[0]?.gross_total === null ? 'null' : ppM.rows?.[0]?.gross_total} · base column ${ppB.code === '42501' ? 'refused (42501)' : `HTTP ${ppB.status}`}`
            check(`payroll period [${r}] API`, !hr ? (ppM.rows?.length ?? 0) === 0 && ppB.code === '42501'
                : ppB.code === '42501' && (pay ? ppM.rows?.[0]?.gross_total !== null : ppM.rows?.[0]?.gross_total === null), ppApi)
            const pp = await get(r, `/hr/payroll/${period.id}`)
            const ps = pageState(pp, true)
            const totText = Number(period.gross_total).toLocaleString('en-US', { minimumFractionDigits: 2 })
            const psText = typeof ps === 'string' && ps.length > 40 ? (ps.includes(totText) ? `totals ${totText}` : ps.includes('Restricted') ? 'Restricted' : 'no totals') : ps
            check(`payroll period [${r}] screen`, !hr ? psText !== `totals ${totText}` : pay ? psText.startsWith('totals') : psText === 'Restricted', psText)
            put(r, 'Payroll period totals', ppApi, !hr ? (typeof ps === 'string' && ps.length > 40 ? 'no HR access (page refuses)' : ps) : psText)

            // ── ③ 工资申请 ──
            const prM = await asUser(who[r], '/rest/v1/payroll_requests_masked?select=id,snapshot,amount_base')
            const prB = await asUser(who[r], '/rest/v1/payroll_requests?select=snapshot')
            put(r, 'Payroll request', `live has ${requests.length} · masked view ${prM.rows?.length ?? prM.code} rows · base snapshot ${prB.code === '42501' ? 'refused (42501)' : `HTTP ${prB.status}`}`,
                'no request on live to open')
            check(`payroll request [${r}] API: the snapshot column is refused on the base table`, prB.code === '42501', `HTTP ${prB.status} ${prB.code}`)

            // ── ④ 医疗报销 ──
            // 一次性账号没有一个是那张报销单 / 请假单的本人 —— 本人那一支由 fixture 247 HL 臂与回滚的线上证明证
            const mcM = await asUser(who[r], `/rest/v1/medical_claims_masked?select=description,amount_sgd&id=eq.${claim.id}`)
            const mcB = await asUser(who[r], `/rest/v1/medical_claims?select=description&id=eq.${claim.id}`)
            const mcApi = !hr ? `0 rows (no HR) · base ${mcB.code === '42501' ? '42501' : mcB.status}` : `masked view: description ${mcM.rows?.[0]?.description === null ? 'null' : 'text'}, amount ${mcM.rows?.[0]?.amount_sgd === null ? 'null' : mcM.rows?.[0]?.amount_sgd} · base ${mcB.code === '42501' ? 'refused (42501)' : mcB.status}`
            check(`medical claim [${r}] API`, mcB.code === '42501' && (!hr ? (mcM.rows?.length ?? 0) === 0 : health ? mcM.rows?.[0]?.description !== null : mcM.rows?.[0]?.description === null && mcM.rows?.[0]?.amount_sgd === null), mcApi)
            const cp = await get(r, `/hr/claims/${claim.id}`)
            const cs = pageState(cp, true)
            const csText = typeof cs === 'string' && cs.length > 40 ? (cs.includes(claim.description) ? 'description shown' : cs.includes('Restricted') ? 'Restricted' : 'no description') : cs
            check(`medical claim [${r}] screen`, !hr ? csText !== 'description shown' : health ? csText === 'description shown' : csText === 'Restricted', csText)
            put(r, 'Medical claim', mcApi, !hr ? 'no HR access' : csText)

            // ── ⑤ 请假单 ──
            const lvM = await asUser(who[r], `/rest/v1/leave_requests_masked?select=reason,certificate_ref&id=eq.${leave.id}`)
            const lvB = await asUser(who[r], `/rest/v1/leave_requests?select=reason&id=eq.${leave.id}`)
            const lvApi = !hr ? `0 rows (no HR) · base ${lvB.code === '42501' ? '42501' : lvB.status}` : `masked view: reason ${lvM.rows?.[0]?.reason === null ? 'null' : 'text'} · base ${lvB.code === '42501' ? 'refused (42501)' : lvB.status}`
            check(`leave request [${r}] API`, lvB.code === '42501' && (!hr ? (lvM.rows?.length ?? 0) === 0 : health ? lvM.rows?.[0]?.reason !== null : lvM.rows?.[0]?.reason === null), lvApi)
            const lp = await get(r, `/hr/leave/${leave.id}`)
            const ls = pageState(lp, true)
            const lsText = typeof ls === 'string' && ls.length > 40 ? (ls.includes(leave.reason) ? 'reason shown' : ls.includes('Restricted') ? 'Restricted' : 'no reason') : ls
            check(`leave request [${r}] screen`, !hr ? lsText !== 'reason shown' : health ? lsText === 'reason shown' : lsText === 'Restricted', lsText)
            put(r, 'Leave request reason', lvApi, !hr ? 'no HR access' : lsText)

            // ── ⑥ 设备保养建议(API 那一条路;页面上它只在财务的资产页)──
            const ad = await asUser(who[r], '/rest/v1/equipment_maintenance_advice?select=maintenance_id,work_cost_base,equipment_cost_base,pct_of_equipment_cost')
            const proc = has(r, 'module.processing.view')
            let costs = (ad.rows ?? []).filter((x) => x.work_cost_base !== null || x.equipment_cost_base !== null || x.pct_of_equipment_cost !== null).length
            if (INJECT === 'warehouse-cost' && r === 'warehouse') costs = 1
            const adText = `${ad.rows?.length ?? ad.code} row(s), ${(ad.rows?.length ?? 0) ? (costs ? 'costs shown' : 'costs null') : '—'}`
            check(`maintenance advice [${r}] API`, (fin || proc ? (ad.rows?.length ?? 0) === advice.length : (ad.rows?.length ?? 0) === 0)
                && (fin ? true : costs === 0), adText)
            put(r, 'Equipment maintenance advice', adText, fin ? 'asset page (finance) shows the costs' : '—')

            // ── ⑦′ HR 记在员工身上的备注(Q6):基表那一列谁都读不到;视图只给持 hr.view 的人 ──
            const nB = await asUser(who[r], '/rest/v1/employees?select=notes&limit=1')
            check(`HR notes [${r}] API: the base column is refused`, nB.code === '42501', `HTTP ${nB.status} ${nB.code}`)
            if (r === 'employee') {
                const nM = await asUser(who[r], '/rest/v1/employees_masked?select=code,notes,separation_notes')
                const own = nM.rows?.filter((x) => String(x.code).startsWith('ZZ-SMOKE-U1A-')) ?? []
                check('HR notes [employee] own row: notes withheld', own.length === 1 && own[0].notes === null && own[0].separation_notes === null, JSON.stringify(nM.rows ?? nM.code).slice(0, 200))
                put(r, 'HR notes on own record', `base column refused (42501) · own row via employees_masked: notes ${own[0]?.notes === null ? 'null' : 'VISIBLE'}`, '—')
            }

            // ── ⑦ 自己的 /me ──
            const me = await get(r, '/me')
            const mel = await asUser(who[r], '/rest/v1/rpc/my_period_labels')
            check(`/me [${r}] opens`, me.status === 200 && !THROWN.test(me.body), `HTTP ${me.status}`)
            put(r, 'Own /me', `my_period_labels: ${Array.isArray(mel.rows) ? `${mel.rows.length} row(s)` : mel.code ?? mel.status}`, me.status === 200 ? 'opens (HTTP 200)' : `HTTP ${me.status}`)
        }
    } finally {
        await runPlan()
        dev.kill()
    }

    console.log('\n== 角色对照表 ==')
    console.log('| reader | item | API | screen |')
    console.log('|---|---|---|---|')
    for (const x of table) console.log(`| ${x.reader} | ${x.item} | ${x.api} | ${x.screen} |`)
    writeFileSync(join(ROOT, '.survey-out', 'u1a-role-table.json'), JSON.stringify(table, null, 1))
    console.log('\n== 结果 ==')
    for (const p of passed) console.log('  ✓ ' + p)
    for (const s of skipped) console.log('  · SKIP ' + s)
    for (const f of failures) console.log('  ✗ ' + f)
    if (INJECT) console.log(`\n· 本跑带着注入 --inject=${INJECT}(${INJECTIONS[INJECT]})`)
    const code = failures.length ? 1 : (process.exitCode || 0)
    console.log(`\n${passed.length} passed · ${failures.length} failed · ${skipped.length} skipped`)
    console.log(`U1A_PROBE_EXIT=${code}`)
    return exitAfterCleanup(code)
}

let devProc = null
installExitHooks({ onFinish: () => {
    try { if (devProc && devProc.exitCode === null) devProc.kill() } catch {}
    try { release() } catch {}
} })

main().catch(async (e) => {
    console.error('✗ 探针自己坏了:' + (e?.stack || e))
    console.log('U1A_PROBE_EXIT=2')
    return exitAfterCleanup(2)
})
