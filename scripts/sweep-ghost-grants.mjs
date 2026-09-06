#!/usr/bin/env node
// scripts/sweep-ghost-grants.mjs —— 扫掉【认不到人】的授权与一次性账号
//
// ════════════════════════════════════════════════════════════════════════════
// ★★【为什么这一支【可以】动手,而 check-scratch-rows 【不可以】】★★
//
// `check-scratch-rows.mjs` 抬头写着本仓库最硬的一条:一次清扫必须【依据一个
// 它无法核实的判断去动手】—— 这一行是残骸,还是另一个进程此刻正在用的?
// **那句话对【按命名认】的清扫是对的,而这一支不按命名认。**
//
// 判据是一个【构造上可核实】的事实:
//
//     user_roles.user_id 在 auth.users 里【不存在】。
//
// 为什么它不可能误伤一次正在跑的运行:**一次正在跑的探针,它的账号还在**
// —— 账号在,user_id 就解析得出来,这一行按定义就不是幽灵。
// 于是 PRE-ACCOUNT-1 那条「一次按命名规则的清扫会把 IN-2026-0180 引用着的
// ZZ-SMOKE-PROBE 删掉」在这里【构造上】不成立:本支一张业务表都不碰。
//
// ★【所以年龄门槛在这一类上【故意】不适用,而这需要说清楚】★
//   `check-scratch-rows` 的 2 小时门槛是为【按命名认】的行准备的:那一类
//   分不出"正在跑的"与"残骸",只好用年龄当代理。**幽灵授权分得出**,
//   所以门槛在这里保护不了任何东西,只会把 5 条同样确定的残骸留到明天。
//   **不要把这个豁免抄到别的类别上** —— 在别的类别上那个门槛是承重的。
//
// 【三件事它【不】做】
//   · 不碰任何业务表(materials / suppliers / customers / …)——
//     那些要按引用逐行判,而那是人的活,不是脚本的活;
//   · 不碰 auth 行【存在】的授权 —— 哪怕那个人从没验证过邮箱。
//     判据是"auth 行不存在",不是"这个人登不进来"(后者是真人,不要动);
//   · 不碰非 @test.local 的账号。
//
// 用法:
//   node scripts/sweep-ghost-grants.mjs            # 只报告,不动手(默认)
//   node scripts/sweep-ghost-grants.mjs --apply    # 真的删
// 退出码:0 = 没有要扫的 / 扫干净了;1 = 有扫不掉的(逐条印出)
import { readFileSync } from 'node:fs'

const ROOT = new URL('..', import.meta.url).pathname
const env = readFileSync(ROOT + '.env.local', 'utf8')
const URL_ = env.match(/NEXT_PUBLIC_SUPABASE_URL=(\S+)/)[1]
const SERVICE = env.match(/SUPABASE_SERVICE_ROLE_KEY=(\S+)/)[1]
const APPLY = process.argv.includes('--apply')

const rest = (p, opts = {}) => fetch(URL_ + p, {
    ...opts,
    headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}`,
               'Content-Type': 'application/json', ...(opts.headers || {}) } })

async function rows(path, ctx) {
    const r = await rest(path)
    const body = await r.text()
    let out = null
    try { out = JSON.parse(body) } catch {}
    // 一次失败【不是】一个空集 —— 查询失败必须响亮,否则"没有幽灵"与
    // "我没查成"在退出码上是同一个字节。
    if (!r.ok || !Array.isArray(out))
        throw new Error(`查询失败(${ctx}): HTTP ${r.status} ${body.slice(0, 200)}`)
    return out
}

const failures = []
async function del(path, ctx) {
    if (!APPLY) return true
    const r = await rest(path, { method: 'DELETE' })
    if (!r.ok && r.status !== 404) {
        failures.push(`${ctx}: HTTP ${r.status} ${(await r.text()).slice(0, 200)}`)
        console.error(`  ✗ ${ctx} → HTTP ${r.status}`)
        return false
    }
    return true
}

const accounts = await (await rest('/auth/v1/admin/users?per_page=1000')).json()
const authUsers = accounts?.users ?? []
// 【分页截满就不要下判断】"没在这一页里"不再等于"不存在",而这一条错的方向
// 不对:它会诱人删掉一条真的授权。与 check-scratch-rows 逐字同一条规矩。
if (authUsers.length >= 1000) {
    console.error('✗ auth 账号可能不止一页(取到 1000 条)—— 拒绝动手。')
    process.exit(1)
}
const authIds = new Set(authUsers.map((u) => u.id))

const roleRows = await rows('/rest/v1/roles?select=id,code,is_system', '角色码')
const roleCode = new Map(roleRows.map((r) => [r.id, r.code]))
const systemRoleIds = new Set(roleRows.filter((r) => r.is_system).map((r) => r.id))

const grants = await rows(
    '/rest/v1/user_roles?select=id,user_id,role_id,granted_at,granted_by,revoked_at', '授权')
const live = grants.filter((g) => !g.revoked_at)
const ghosts = live.filter((g) => !authIds.has(g.user_id))

// ── 动手【之前】先证明还剩得下一个真管理员 ─────────────────────────────────
// guard_last_admin 是 BEFORE UPDATE OR DELETE 的触发器,所以它对【每一条】
// 删除都会跑一遍。它数的是 real_role_grants(auth 行存在 + 已确认 + 未封禁
// + 未删除),幽灵一条都数不进去 —— 所以扫掉幽灵不会让它拒绝。
// 但这件事【要量出来,不要推】:真管理员只有一个的时候,这一步就是最后的确认。
const realSystemHolders = live.filter((g) => systemRoleIds.has(g.role_id) && authIds.has(g.user_id))
console.log(`真的数得上的 is_system 持有人:${realSystemHolders.length} 个`)
for (const g of realSystemHolders) {
    const u = authUsers.find((x) => x.id === g.user_id)
    console.log(`  · ${roleCode.get(g.role_id)}  ${u?.email}  (confirmed=${u?.confirmed_at ? 'yes' : 'NO'})`)
}
if (!realSystemHolders.length) {
    console.error('\n✗ 一个真的管理员都没有 —— 拒绝动手。先补一个,再来扫。')
    process.exit(1)
}

// ── 幽灵授权 ────────────────────────────────────────────────────────────────
console.log(`\n【认不到人的授权】${ghosts.length} 条` + (APPLY ? '  —— 正在删' : '  (只报告;--apply 才动手)'))
const now = Date.now()
let okGrants = 0
for (const g of ghosts) {
    const ageH = ((now - new Date(g.granted_at).getTime()) / 3600000).toFixed(1)
    const mark = g.granted_by === g.user_id ? ' [自授=一次性]' : g.granted_by ? ' [granted_by 有值]' : ' [granted_by 空 —— 认不到产地]'
    console.log(`  · ${(roleCode.get(g.role_id) ?? '?').padEnd(10)} ${g.user_id}  (${ageH}h)${mark}`)
    if (await del(`/rest/v1/user_roles?id=eq.${g.id}`, `删授权 ${g.id}`)) okGrants++
}

// ── 一次性账号(@test.local),先收权限再删账号 ─────────────────────────────
// 【顺序反了就变成一条幽灵授权】—— 这正是这堆东西的来源。
const EPHEMERAL = /^(survey|probe|smoke|pdf)-/
const stale = authUsers.filter((u) => {
    const e = u.email ?? ''
    return e.endsWith('@test.local') && EPHEMERAL.test(e)
})
console.log(`\n【一次性账号 @test.local】${stale.length} 个` + (APPLY ? '  —— 正在删(先收权限,再删账号)' : '  (只报告)'))
let okAccounts = 0
for (const u of stale) {
    const ageH = ((now - new Date(u.created_at).getTime()) / 3600000).toFixed(1)
    const held = live.filter((g) => g.user_id === u.id).map((g) => roleCode.get(g.role_id) ?? '?')
    console.log(`  · ${u.email}  (${ageH}h)  持有:${held.length ? held.join(',') : '(无)'}`)
    const a = await del(`/rest/v1/user_roles?user_id=eq.${u.id}`, `收权限 ${u.email}`)
    const b = await del(`/auth/v1/admin/users/${u.id}`, `删账号 ${u.email}`)
    if (a && b) okAccounts++
}

if (!APPLY) {
    console.log('\n【本次没有动手】加 --apply 才真的删。')
    process.exit(0)
}
console.log(`\n扫掉授权 ${okGrants}/${ghosts.length} 条 · 账号 ${okAccounts}/${stale.length} 个`)
if (failures.length) {
    console.error(`\n✗ ${failures.length} 处失败:`)
    for (const f of failures) console.error('   ' + f)
    process.exit(1)
}
console.log('✓ 扫干净了。')
console.log('★ 但计数器归零【不等于】产地修好了 —— 产地是 LEAK-1 的 Item 2/3/4,')
console.log('  见 docs/known-issues.md 的 PROBE-KILL-LEAK。这已经是第【四】次扫这一堆。')
process.exit(0)
