#!/usr/bin/env node
// scripts/check-dock-nonempty.mjs — 没有任何角色的默认 dock 是空的。
//
// ════════════════════════════════════════════════════════════════════════════
// 【它守的是 Tim 的 4c,而那条保证此前【没有任何检查看着】】
// 原话:**新同事第一次登录时 dock 不能是空的,因为"空的 dock"是一个没有人会
// 发现的功能。** lib/dock.ts 靠一条【任何登录用户都进得去】的候选来兑现它。
//
// ★【本刀的发现:那条保证一直悬在一个巧合上】★
// 到 TOOLS-1 之前,全注册表 82 条里【恰好只有一条】判据是恒真的
// (金属行情那一条的 `{ all: [] }` —— 它当时还住在一级),而它恰好排在候选清单末位。
// 没有任何东西要求这两件事成立 —— 于是本刀差一点就在收窄那一条时,
// 把 employee 角色(**即将到岗的六位同事拿到的那个角色**)的 dock 打到 0,
// 而【构建、闸、冒烟没有一样会红】。
//
// 【所以这不是"再加一条注释",是把注释换成机制】——
// 与 OPS-7 用脚本替掉两句"记得检查 B1 与 is_system"、
// `wait_for.sh` 替掉"记得给等待加上限",是同一次替换。
//
// 【判据】对 live 上每一个未删角色,按它的权限算 defaultDock();任何一个为 0 → 红。
// 【它连库】所以它【不进 npm run build】(那道门必须离得开网络),按需跑:
//     npm run check:dock
// 改 DOCK_DEFAULT_CANDIDATES、改任何一条注册表判据、发账号之前,都跑一次。
//
// 退出码 0 = 每个角色都拿得到至少一条;1 = 有角色为 0;2 = 取数或解析失败
// (**解析出 0 个角色不是"通过",是解析器坏了** —— 空集上通过的检查什么都没证明)。
// ════════════════════════════════════════════════════════════════════════════
import { readFileSync } from 'node:fs'
import { FUNCTIONS, allows } from '../lib/modules.ts'

const env = readFileSync('.env.local', 'utf8')
const URL_ = env.match(/NEXT_PUBLIC_SUPABASE_URL=(\S+)/)?.[1]
const SVC = env.match(/SUPABASE_SERVICE_ROLE_KEY=(\S+)/)?.[1]
if (!URL_ || !SVC) {
    console.error('✗ check-dock:.env.local 里读不到 SUPABASE URL / service key')
    process.exit(2)
}

// 【候选清单从 lib/dock.ts 的源码现读,不抄第二份】抄一份就会与它漂开,
// 而漂开之后这道检查守的就是另一份清单了 —— 本仓库对"同一件事的两份实现"付过账。
const dockSrc = readFileSync('lib/dock.ts', 'utf8')
const mCand = dockSrc.match(/DOCK_DEFAULT_CANDIDATES[^=]*=\s*\[([\s\S]*?)\n\]/)
if (!mCand) {
    console.error('✗ check-dock:lib/dock.ts 里找不到 DOCK_DEFAULT_CANDIDATES —— 解析器坏了')
    process.exit(2)
}
const CANDIDATES = [...mCand[1].matchAll(/'([^']+)'/g)].map((x) => x[1])
const mMax = dockSrc.match(/DOCK_MAX\s*=\s*(\d+)/)
if (!mMax || CANDIDATES.length === 0) {
    console.error(`✗ check-dock:候选解析出 ${CANDIDATES.length} 条、DOCK_MAX=${mMax?.[1]} —— 解析器坏了,不是空清单`)
    process.exit(2)
}
const DOCK_MAX = Number(mMax[1])

const h = { apikey: SVC, Authorization: `Bearer ${SVC}` }
const get = async (path) => {
    const r = await fetch(URL_ + path, { headers: h })
    if (!r.ok) { console.error(`✗ check-dock:${path} → HTTP ${r.status}`); process.exit(2) }
    return r.json()
}

const roles = await get('/rest/v1/roles?select=id,code&deleted_at=is.null&order=code')
const rolePerms = await get('/rest/v1/role_permissions?select=role_id,permission_code')
// 【零个角色不是"通过"】—— 那是取数坏了(fixture 88 那一课)
if (roles.length === 0) {
    console.error('✗ check-dock:live 上解析出 0 个角色 —— 取数坏了,不是"没有角色"')
    process.exit(2)
}

/** 与 lib/dock.ts 的 defaultDock 同形:候选里【他进得去】的前 DOCK_MAX 条。 */
const dockFor = (perms) => CANDIDATES.filter((href) => {
    const fn = FUNCTIONS.find((f) => f.href === href)
    return fn ? allows(fn.permission, perms) : false
}).slice(0, DOCK_MAX)

const rows = roles.map((r) => {
    const perms = rolePerms.filter((x) => x.role_id === r.id).map((x) => x.permission_code)
    return { role: r.code, perms: perms.length, dock: dockFor(perms) }
})

const w = Math.max(...rows.map((r) => r.role.length), 4)
console.log(`候选 ${CANDIDATES.length} 条 · DOCK_MAX=${DOCK_MAX} · 角色 ${rows.length} 个`)
console.log(`${'role'.padEnd(w)}  perms  dock  第一条`)
for (const r of rows) {
    console.log(`${r.role.padEnd(w)}  ${String(r.perms).padStart(5)}  ${String(r.dock.length).padStart(4)}  ${r.dock[0] ?? '—'}`)
}

const empty = rows.filter((r) => r.dock.length === 0)
if (empty.length) {
    console.error(`\n✗ check-dock:${empty.length} 个角色的默认 dock 是【空的】:${empty.map((r) => r.role).join(', ')}`)
    console.error('   Tim 的 4c:新同事第一次登录时 dock 不能是空的 —— "空的 dock"是一个没有人会发现的功能。')
    console.error('   修法:让候选清单里至少有一条【这个角色进得去】的条目。')
    console.error('   注意这通常不是 dock 的毛病,而是某条注册表判据刚刚被收窄了。')
    process.exit(1)
}
console.log(`\n✓ check-dock:${rows.length} 个角色,每一个都拿得到至少一条 dock(最少的是 ${
    Math.min(...rows.map((r) => r.dock.length))} 条)`)
