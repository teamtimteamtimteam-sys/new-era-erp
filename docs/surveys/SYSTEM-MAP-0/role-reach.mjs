#!/usr/bin/env node
// SYSTEM-MAP-0 Part 3.2 · 每个角色今天的菜单可达性与提醒支 —— 只对【本地重建】跑。
// 身份:本地重建里为每个角色造一个合成用户(user_roles 一行,只在本地),以 authenticated + 它的 JWT sub 调 current_user_permissions()
//   —— 与 lib/permissions.ts getMyPermissions() 同一支函数;角色授权是线上只读读回、装进本地的(live-role-grants.sql → load-grants-local.sql)。
// 求值:lib/modules.ts 的 allows()(全站唯一求值器)+ menuFunctionsForModule();提醒支用 lib/reminders.ts 的 REMINDERS + specFor()
//   —— 与 app/tools/reminders/page.tsx 的 armAllowed 同一个表达式。
// 用法:LOCAL_DSN="host=/tmp/sm0sock port=55433 user=postgres dbname=scratch" node --experimental-strip-types docs/surveys/SYSTEM-MAP-0/role-reach.mjs
import { spawnSync } from 'node:child_process'
import { randomUUID } from 'node:crypto'
import * as M from '../../../lib/modules.ts'
import { REMINDERS, specFor } from '../../../lib/reminders.ts'

const DSN = process.env.LOCAL_DSN
if (!DSN || !/sm0sock|localhost|127\.0\.0\.1/.test(DSN)) { console.error('LOCAL_DSN must point at the local rebuild'); process.exit(2) }
const psql = (sql) => {
    const r = spawnSync('psql', [DSN, '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-f', '-'], { input: sql, encoding: 'utf8' })
    if (r.status !== 0) throw new Error(r.stderr)
    return r.stdout.trim()
}
const ROLES = ['admin', 'cfo', 'cco', 'cto', 'finance', 'gm', 'warehouse']
const out = {}
for (const role of ROLES) {
    const uid = randomUUID()
    psql(`INSERT INTO user_roles (user_id, role_id) SELECT '${uid}', id FROM roles WHERE code = '${role}'`)
    const perms = JSON.parse(psql(`BEGIN; SET LOCAL ROLE authenticated; SELECT set_config('request.jwt.claims', '{"sub":"${uid}","role":"authenticated"}', true) \\g /dev/null
SELECT to_json(current_user_permissions()); ROLLBACK;`).split('\n').find((l) => l.startsWith('[')))
    // 合成用户留在本地重建里(删 admin 那一行会撞 guard_last_admin;本地库用完整个丢掉)
    const modules = M.MODULES.map((m) => {
        const entries = M.menuFunctionsForModule(m.id).map((fn) => ({ href: fn.href, allowed: M.allows(fn.permission, perms) }))
        return { id: m.id, allowed: entries.some((e) => e.allowed), entries }
    })
    const reminders = REMINDERS.map((r) => ({ itemType: r.itemType, allowed: M.allows(specFor(r), perms) }))
    out[role] = { permCount: perms.length, perms, modules, reminders, hrAlerts: M.allows('module.hr.view', perms) }
}
console.log(JSON.stringify(out, null, 1))
