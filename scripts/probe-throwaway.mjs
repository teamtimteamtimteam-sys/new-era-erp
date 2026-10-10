#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// U1-B(2026-10-05)· mintThrowaway 的线上自证 —— 「造得出、用得上、拒得住、收得干净」
// ════════════════════════════════════════════════════════════════════════════
// 【为什么要它】scripts/check-throwaway-grants.mjs 证的是【写法】:没有脚本绕过 mintThrowaway。
//   它证不了 mintThrowaway 自己在线上真的做对了 —— 角色真的是非系统的、码真的恰好是要的那几个、
//   会话真的拿得到这些码、admin 真的被拒、收尾之后线上真的一行不剩。这几件只有对着线上跑一遍才知道。
//
// 【它造什么】三个一次性账号(前缀 twprobe-,与冒烟同一套 ephemeral 计划,跑完收走):
//   A  codes: 'all'                       —— 全码角色 probe-twprobe-all-<stamp>
//   B  codes: { cloneOf: 'warehouse' }    —— 恰好持 warehouse 此刻的码,但【不是】warehouse
//   C  codes: ['module.hr.view'] + 员工档案 ZZ-SMOKE-THROWAWAY-<stamp>(user_id 绑到 C)
//   外加一次 { realRole: 'admin' } —— 必须抛 THROWAWAY_REFUSES_SYSTEM_ROLE,而且什么都没造。
//
// 【断言】(都经 service REST 读回,不信 mintThrowaway 自己的返回值)
//   ① 每个一次性角色:恰好一行,is_system = false,is_active = true;它的码 = 期望的码(一个不多一个不少)。
//      期望的码走【另一条路】读:A 读 permissions 全表;B 经 roles!inner(code) 联表读 warehouse 的码;C 是写死的那一个。
//   ② 每个账号:auth 行在、邮箱对;授权恰好一条、指着那个角色、granted_by = 自己(自授标记)、未撤销。
//   ③ 会话真的用得上:以那个人的令牌调 current_user_permissions(),拿到的集合 = 期望的码;
//      C 再以 has_permission 问一正一负(module.hr.view 有、module.finance.view 没有)。
//   ④ C 的员工档案在,user_id = C,id = mintThrowaway 先登记删除步时用的那个 id。
//   ⑤ { realRole: 'admin' }:真路径抛 THROWAWAY_REFUSES_SYSTEM_ROLE|admin;dryRun 路径也抛;
//      两次之后计划里没有多一步、线上没有那个邮箱的账号。
//   ⑥ 收尾(runPlan)之后读回:按邮箱前缀的 auth 账号 0、按 user_id 的授权 0、按 code 的角色 0、按 code 的员工 0。
//
// 【故障注入】--inject=<case>,每一种都必须让一条具体的断言变红:
//   leftover      收尾前从计划里抽掉一步(C 的"删角色")—— ⑥ 必须红并点名那个角色;
//                 然后本支【自己把它删掉】并再读一次,线上照样干净,退出码照样是红的(1)。
//   cleanup-hang  收尾时装上 installCleanupNetworkFault('hang') —— 必须退 6(收尾没完成),
//                 计划留在 .ephemeral/ 里,下一支脚本开跑时 reapStalePlans 照它补删。
//   refusal-off   以注入开关绕过 is_system 拒绝 —— ⑤ 必须红。★ 这一格【只走 dryRun】:
//                 注入开关只在 dryRun 里被认(mintThrowaway 里有闸),而 dryRun 什么都不造,
//                 所以这一格绝不会真的授出 admin;⑤ 后半句(什么都没造)照样要绿。
//   不认识的注入 → 退 2。
//
// 退出码:0 = 全过;1 = 有断言失败;2 = 探针自己坏了 / 用法错;5 = live-lock 被别人占着;6 = 收尾没完成。
//   ★ 判决只从日志里那一行 `THROWAWAY_PROBE_EXIT=` 读 —— 它是本支打的最后一行,由 exitAfterCleanup 的 onFinish 打,
//     印的是进程【真的】会退的那个数(收尾没完成的 6 也在内)。每一条出口都走 exitAfterCleanup(PAY-REQ-1)。
// 用法:node scripts/probe-throwaway.mjs [--inject=leftover|cleanup-hang|refusal-off]
// ════════════════════════════════════════════════════════════════════════════
import { onlyWhenRunDirectly } from './lib/entrypoint.mjs'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { acquireOrExit, release, heldBy } from './liveLock.mjs'
import { openPlan, mintThrowaway, runPlan, reapStalePlans, installExitHooks, exitAfterCleanup,
         installCleanupNetworkFault } from './ephemeral.mjs'

onlyWhenRunDirectly(import.meta.url)

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)))
const env = readFileSync(join(ROOT, '.env.local'), 'utf8')
const URL_ = env.match(/NEXT_PUBLIC_SUPABASE_URL=(\S+)/)[1]
const ANON = env.match(/NEXT_PUBLIC_SUPABASE_ANON_KEY=(\S+)/)[1]
const SERVICE = env.match(/SUPABASE_SERVICE_ROLE_KEY=(\S+)/)[1]

let locked = false
installExitHooks({ onFinish: (code) => {
    try { if (locked) release() } catch { /* 放锁失败不改判决 */ }
    console.log(`THROWAWAY_PROBE_EXIT=${code}`)
} })

const INJECT = (process.argv.find((a) => a.startsWith('--inject=')) || '').slice('--inject='.length) || null
const INJECTIONS = {
    'leftover': '收尾前从计划里抽掉 C 的"删角色"一步 —— 收尾后的读回必须红并点名那个角色(然后本支自己删掉它)',
    'cleanup-hang': '收尾时发往库的每一次往返都挂住 —— 必须退 6,计划留给 reapStalePlans',
    'refusal-off': '以注入开关绕过 is_system 拒绝(只走 dryRun,什么都不造)—— "admin 被拒"那一格必须红',
}

const rest = (path, opts = {}) => fetch(URL_ + path, {
    ...opts, headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, 'Content-Type': 'application/json', ...(opts.headers || {}) },
})
/** service 读:失败 ≠ 空集(与 restRows / mustRows 同一条规矩)。 */
async function rows(path, ctx) {
    const r = await rest(path)
    const body = await r.text()
    let j = null
    try { j = JSON.parse(body) } catch { /* 下面统一报 */ }
    if (!r.ok || !Array.isArray(j)) throw new Error(`${ctx}: HTTP ${r.status} ${body.slice(0, 300)}`)
    return j
}
/** 以那个人的令牌调一支 RPC。 */
async function rpcAs(token, fn, body = {}) {
    const r = await fetch(URL_ + '/rest/v1/rpc/' + fn, { method: 'POST',
        headers: { apikey: ANON, Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
        body: JSON.stringify(body) })
    const text = await r.text()
    let j = null
    try { j = JSON.parse(text) } catch { /* 非 JSON */ }
    return { status: r.status, body: j, raw: text.slice(0, 200) }
}
async function authUsersAll() {
    const r = await rest('/auth/v1/admin/users?per_page=1000')
    const j = await r.json().catch(() => null)
    if (!r.ok || !Array.isArray(j?.users)) throw new Error(`auth 账号列表: HTTP ${r.status}`)
    // 分页截满就不要下"不存在"的判断(与 check-scratch-rows 同一条规矩)
    if (j.users.length >= 1000) throw new Error('auth 账号可能不止一页(取到 1000 条)—— "没在这一页里"不等于"不存在"')
    return j.users
}

const failures = []
const passed = []
function check(label, ok, why) { (ok ? passed : failures).push(ok ? label : `${label}: ${why}`) }
const sameSet = (a, b) => a.size === b.size && [...a].every((x) => b.has(x))
const diff = (a, b) => {
    const more = [...a].filter((x) => !b.has(x)), less = [...b].filter((x) => !a.has(x))
    return `多 ${more.length}${more.length ? '(' + more.slice(0, 5).join(',') + ')' : ''} · 少 ${less.length}${less.length ? '(' + less.slice(0, 5).join(',') + ')' : ''}`
}

async function main() {
    if (INJECT && !INJECTIONS[INJECT]) {
        console.error(`✗ --inject=${INJECT} 不认识。可选:${Object.keys(INJECTIONS).join(' / ')}`)
        return exitAfterCleanup(2)
    }
    if (INJECT) console.log(`!! 故障注入:${INJECT} —— ${INJECTIONS[INJECT]}`)
    // 锁被别人占着:acquireOrExit 会直接 process.exit(5),而那样打不出最后那一行 —— 先问一句。
    const other = heldBy()
    if (other) {
        console.error(`✗ live-lock 被【${other.holder}】(pid ${other.pid})占着 —— 等它跑完再来。`)
        return exitAfterCleanup(5)
    }
    acquireOrExit('scripts/probe-throwaway.mjs', { ownExit: false })
    locked = true
    const plan = openPlan('scripts/probe-throwaway.mjs')
    await reapStalePlans()

    const stamp = Date.now()
    const P = 'twprobe'
    const EMP_CODE = `ZZ-SMOKE-THROWAWAY-${stamp}`

    // ── 三个一次性账号 ─────────────────────────────────────────────────────────
    const A = await mintThrowaway({ prefix: P, label: 'all', codes: 'all', stamp })
    const B = await mintThrowaway({ prefix: P, label: 'clonewh', codes: { cloneOf: 'warehouse' }, stamp })
    const C = await mintThrowaway({ prefix: P, label: 'hrview', codes: ['module.hr.view'], stamp,
        employee: { code: EMP_CODE, legal_name: 'ZZ Throwaway Probe', employment_type: 'full_time',
                    work_category: 'office', hire_date: '2026-01-01' } })
    const minted = [A, B, C]
    console.log(`· minted: ${minted.map((t) => `${t.email} ← ${t.roleCode}(${t.codes.length} 码)`).join(' · ')}`)

    // ── 期望的码:走【另一条路】读,不用 mintThrowaway 返回的那份 ─────────────────
    const expect = new Map()
    expect.set(A, new Set((await rows('/rest/v1/permissions?select=code', 'permissions 全表')).map((p) => p.code)))
    expect.set(B, new Set((await rows('/rest/v1/role_permissions?select=permission_code,roles!inner(code)&roles.code=eq.warehouse',
        'warehouse 的码(联表)')).map((x) => x.permission_code)))
    expect.set(C, new Set(['module.hr.view']))
    check('期望的码读得到(A 全表、B warehouse 都不是 0)', expect.get(A).size > 0 && expect.get(B).size > 0,
        `A ${expect.get(A).size} · B ${expect.get(B).size} —— 零码的期望会让"相等"那一格空转`)

    const warehouseRole = (await rows('/rest/v1/roles?select=id,code&code=eq.warehouse', 'warehouse 角色'))[0]

    for (const t of minted) {
        const tag = t.roleCode
        // ① 角色
        const rr = await rows(`/rest/v1/roles?select=id,code,is_system,is_active,deleted_at&code=eq.${t.roleCode}`, `roles ← ${tag}`)
        check(`① [${tag}] 一次性角色恰好一行、非系统、启用中`,
            rr.length === 1 && rr[0].is_system === false && rr[0].is_active === true && rr[0].deleted_at === null && rr[0].id === t.roleId,
            JSON.stringify(rr).slice(0, 200))
        check(`① [${tag}] 角色码以 probe- 开头`, t.roleCode.startsWith('probe-'), t.roleCode)
        const rp = new Set((await rows(`/rest/v1/role_permissions?select=permission_code&role_id=eq.${t.roleId}`, `role_permissions ← ${tag}`))
            .map((x) => x.permission_code))
        check(`① [${tag}] 角色的码恰好是期望的 ${expect.get(t).size} 个`, sameSet(rp, expect.get(t)), diff(rp, expect.get(t)))
        // ② 账号与授权
        const ur = await rest(`/auth/v1/admin/users/${t.userId}`)
        const uj = await ur.json().catch(() => null)
        check(`② [${tag}] auth 账号在、邮箱对`, ur.ok && uj?.email === t.email, `HTTP ${ur.status} ${uj?.email}`)
        const g = await rows(`/rest/v1/user_roles?select=user_id,role_id,granted_by,revoked_at&user_id=eq.${t.userId}`, `user_roles ← ${tag}`)
        check(`② [${tag}] 授权恰好一条、指着它的角色、自授标记、未撤销`,
            g.length === 1 && g[0].role_id === t.roleId && g[0].granted_by === t.userId && g[0].revoked_at === null,
            JSON.stringify(g).slice(0, 200))
        // ③ 会话用得上
        const cup = await rpcAs(t.token, 'current_user_permissions')
        const got = new Set(Array.isArray(cup.body) ? cup.body : [])
        check(`③ [${tag}] 以它的令牌 current_user_permissions() = 期望的码`,
            cup.status === 200 && sameSet(got, expect.get(t)), `HTTP ${cup.status} · ${diff(got, expect.get(t))} ${cup.status === 200 ? '' : cup.raw}`)
    }
    // B 不是 warehouse 本身(同码、不同角色 —— 按角色码认人的审批判据认不到它)
    check('① [clone] B 的角色与 warehouse 不是同一行', warehouseRole && B.roleId !== warehouseRole.id, `B ${B.roleId} · warehouse ${warehouseRole?.id}`)
    // ③ C 一正一负
    const hp = await rpcAs(C.token, 'has_permission', { p_code: 'module.hr.view' })
    const hn = await rpcAs(C.token, 'has_permission', { p_code: 'module.finance.view' })
    check('③ [C] has_permission(module.hr.view) = true', hp.status === 200 && hp.body === true, `HTTP ${hp.status} ${hp.raw}`)
    check('③ [C] has_permission(module.finance.view) = false', hn.status === 200 && hn.body === false, `HTTP ${hn.status} ${hn.raw}`)
    // ④ C 的员工档案
    const emp = await rows(`/rest/v1/employees?select=id,code,user_id&code=eq.${EMP_CODE}`, `employees ← ${EMP_CODE}`)
    check('④ [C] 员工档案在、绑着 C、id 是先登记的那一个',
        emp.length === 1 && emp[0].user_id === C.userId && emp[0].id === C.employeeId, JSON.stringify(emp).slice(0, 200))

    // ── ⑤ admin 必须被拒,而且什么都没造 ─────────────────────────────────────────
    const refusedEmail = `${P}-${stamp}-sysrefuse@test.local`
    const stepsBefore = plan.steps.length
    let outcome
    try {
        if (INJECT === 'refusal-off') {
            // ★ 只走 dryRun:mintThrowaway 只在 dryRun 里认这个开关,而 dryRun 不造任何东西。
            const r = await mintThrowaway({ prefix: P, label: 'sysrefuse', codes: { realRole: 'admin' }, stamp,
                                            dryRun: true, __injectRefusalOff: true })
            outcome = `没有抛 —— 返回了 ${r.kind}/${r.roleCode}(dryRun=${r.dryRun})`
        } else {
            await mintThrowaway({ prefix: P, label: 'sysrefuse', codes: { realRole: 'admin' }, stamp })
            outcome = '没有抛 —— ★ 真路径授出了 admin'
        }
    } catch (e) { outcome = e.message }
    check('⑤ { realRole: admin } 抛 THROWAWAY_REFUSES_SYSTEM_ROLE|admin', outcome.startsWith('THROWAWAY_REFUSES_SYSTEM_ROLE|admin'), outcome)
    if (INJECT !== 'refusal-off') {
        let dry
        try { await mintThrowaway({ prefix: P, label: 'sysrefusedry', codes: { realRole: 'admin' }, stamp, dryRun: true }); dry = '没有抛' }
        catch (e) { dry = e.message }
        check('⑤ dryRun 路径也拒(拒绝在 dryRun 返回之前)', dry.startsWith('THROWAWAY_REFUSES_SYSTEM_ROLE|admin'), dry)
    }
    const usersNow = await authUsersAll()
    check('⑤ 拒绝之后计划里没有多一步', plan.steps.length === stepsBefore, `${stepsBefore} → ${plan.steps.length}`)
    check('⑤ 拒绝之后线上没有那个邮箱的账号', !usersNow.some((u) => u.email === refusedEmail), refusedEmail)

    // ── 收尾 ───────────────────────────────────────────────────────────────────
    if (INJECT === 'cleanup-hang') {
        console.log(`\n· 断言 ${passed.length} 过 · ${failures.length} 败(收尾之前)`)
        for (const f of failures) console.log('  ✗ ' + f)
        console.log('· 注入 cleanup-hang:收尾的每一次往返都会挂住 —— 期望退 6,计划留在 .ephemeral/ 给 reapStalePlans')
        installCleanupNetworkFault('hang')
        return exitAfterCleanup(failures.length ? 1 : 0)
    }
    let dropped = null
    if (INJECT === 'leftover') {
        // 直接动内存里的计划(openPlan 返回的就是 runPlan 要跑的那一份)—— 只为证明读回咬得到漏删。
        const idx = plan.steps.findIndex((s) => s.path === `/rest/v1/roles?code=eq.${C.roleCode}`)
        if (idx < 0) throw new Error('注入 leftover 找不到 C 的"删角色"一步 —— 这一格什么也证明不了')
        dropped = plan.steps.splice(idx, 1)[0]
        console.log(`!! 注入 leftover:从计划里抽掉了「${dropped.ctx}」`)
    }
    await runPlan()

    // ⑥ 收尾之后读回:一行不剩
    const leftovers = []
    const after = await authUsersAll()
    for (const u of after.filter((x) => (x.email ?? '').startsWith(`${P}-${stamp}-`))) leftovers.push(`auth 账号 ${u.email}`)
    for (const t of minted) {
        const g = await rows(`/rest/v1/user_roles?select=id&user_id=eq.${t.userId}`, `读回 user_roles ← ${t.email}`)
        if (g.length) leftovers.push(`授权 × ${g.length} ← ${t.email}`)
        const r = await rows(`/rest/v1/roles?select=id&code=eq.${t.roleCode}`, `读回 roles ← ${t.roleCode}`)
        if (r.length) leftovers.push(`角色 ${t.roleCode}`)
    }
    const anyRole = await rows(`/rest/v1/roles?select=code&code=like.probe-${P}-*-${stamp}`, '读回 roles ← 本跑的命名空间')
    for (const r of anyRole) if (!leftovers.includes(`角色 ${r.code}`)) leftovers.push(`角色 ${r.code}`)
    const empLeft = await rows(`/rest/v1/employees?select=id&code=eq.${EMP_CODE}`, `读回 employees ← ${EMP_CODE}`)
    if (empLeft.length) leftovers.push(`员工 ${EMP_CODE}`)
    check('⑥ 收尾之后线上一行不剩(账号 / 授权 / 角色 / 员工)', leftovers.length === 0, `剩下:${leftovers.join('、')}`)

    if (dropped) {
        // 注入的漏删由本支自己收走,线上照样干净;退出码照样是红的(上面那一格红了)。
        console.log(`· 注入 leftover:自己收走漏下的那一步 —— ${dropped.how?.method ?? 'DELETE'} ${dropped.path}`)
        const d = await rest(dropped.path, { method: 'DELETE' })
        const again = await rows(`/rest/v1/roles?select=id&code=eq.${C.roleCode}`, `再读 roles ← ${C.roleCode}`)
        if (!d.ok || again.length) {
            console.error(`✗✗ 自己收不走:HTTP ${d.status},还剩 ${again.length} 行 —— 手工删 ${C.roleCode}(check-scratch-rows 会报它)`)
            failures.push(`注入 leftover 的自收尾失败:${C.roleCode} 还在`)
        } else {
            console.log(`  ✓ ${C.roleCode} 已删,再读 0 行`)
        }
    }

    console.log(`\n== probe-throwaway:${passed.length} 过 · ${failures.length} 败${INJECT ? `(注入 ${INJECT})` : ''} ==`)
    for (const p of passed) console.log('  ✓ ' + p)
    for (const f of failures) console.log('  ✗ ' + f)
    return exitAfterCleanup(failures.length ? 1 : 0)
}

main().catch((e) => {
    console.error('✗ 探针自己坏了:' + (e?.stack || e))
    return exitAfterCleanup(2)
})
