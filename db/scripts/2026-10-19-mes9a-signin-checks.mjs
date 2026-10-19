#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// MES-9a · Verify 第 6 步 —— 【开 hook 之后马上:每一种账号登录、刷新、空闲登出、刷新令牌轮换,照旧】(委托书「Sign-in safety」)
// ════════════════════════════════════════════════════════════════════════════
// 一次性账号(前缀 mes9aprobe,scripts/ephemeral.mjs 的计划收尾),七个真账号一个都不用:
//   c_<角色>  七个线上角色(admin · cco · cfo · cto · finance · gm · warehouse)各一个同码克隆(cloneOf)
//   display   只挂真的 floor_display(realRole —— 大屏豁免只认那个真角色)
//   portal    一家一次性供应商下的一个一次性门户账号({ portalOf })
// 对每一个:
//   ① 登录(password grant)→ 令牌里的 role:员工 / 大屏 = authenticated,门户 = supplier_portal;
//   ② 拿这个令牌问一次库:员工 / 大屏调 current_user_permissions()(码数 = 它的码数);门户调 portal_me()(回它自己那一家),
//      并且它调 current_user_permissions() 被拒;
//   ③ 刷新(refresh_token grant)→ 新令牌的 role 不变、新的刷新令牌与旧的不同、新令牌照样问得动库;
//   ④ 空闲登出(PROOF_BASE 上的应用 —— 默认已部署的那一个,中间件的空闲判据是应用代码,hook 动不到它):活动 cookie 设成 29 分钟前 → 照常进;
//      31 分钟前 → 员工 307 /login?reason=ended(与今天一样),大屏照样进 /display(豁免照旧);
//   ⑤ 刷新令牌轮换:再刷一次之后等 11 秒(重用间隔 10 秒),拿【祖父】那个刷新令牌去刷 → refresh_token_already_used,而当前那个照样刷得动 ——
//      与 hook 关着时量到的一模一样(GoTrue 放行【当前令牌的父】的重用,回当前那个;见 readings/rotation-compare.txt)。
// 判决只从日志里最后那一行 `MES9A_SIGNIN_EXIT=` 读:0 = 每一格都照旧 · 3 = 有员工(或大屏)登录 / 刷新失败 —— 立刻关 hook ·
//   1 = 别的断言红 · 2 = 驱动自己坏了 · 5 = live-lock 被占 · 6 = 收尾没完成。
// 用法:PROOF_BASE=https://new-era-erp.vercel.app node db/scripts/2026-10-19-mes9a-signin-checks.mjs > <log> 2>&1
// ════════════════════════════════════════════════════════════════════════════
import { onlyWhenRunDirectly } from '../../scripts/lib/entrypoint.mjs'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { acquireOrExit, release, heldBy } from '../../scripts/liveLock.mjs'
import { openPlan, mintThrowaway, mintThrowawaySupplier, reapStalePlans, installExitHooks, exitAfterCleanup } from '../../scripts/ephemeral.mjs'

onlyWhenRunDirectly(import.meta.url)

const ROOT = dirname(dirname(dirname(fileURLToPath(import.meta.url))))
const BASE = process.env.PROOF_BASE || 'https://new-era-erp.vercel.app'
const ROLE_CLONES = ['admin', 'cco', 'cfo', 'cto', 'finance', 'gm', 'warehouse']
const ACTIVITY_COOKIE = 'evoltrya-last-activity'   // lib/session.ts —— 同一个名字

let locked = false
let staffFailure = false
installExitHooks({
    onFinish: (code) => {
        try { if (locked) release() } catch { /* 放锁失败不改判决 */ }
        console.log(`MES9A_SIGNIN_EXIT=${code}`)
    },
})

function env() {
    const txt = readFileSync(join(ROOT, '.env.local'), 'utf8')
    const get = (k) => (txt.match(new RegExp('^' + k + '=(.*)$', 'm'))?.[1] ?? '').trim().replace(/^"|"$/g, '')
    return { URL_: get('NEXT_PUBLIC_SUPABASE_URL'), ANON: get('NEXT_PUBLIC_SUPABASE_ANON_KEY') }
}
function roleOf(jwt) {
    try { return JSON.parse(Buffer.from(jwt.split('.')[1], 'base64url').toString()).role ?? null } catch { return null }
}
function must(cond, msg, staff = false) {
    if (!cond) { if (staff) staffFailure = true; throw new Error(`MES9A_SIGNIN|${msg}`) }
}
async function rpc(E, token, fn) {
    const r = await fetch(`${E.URL_}/rest/v1/rpc/${fn}`, { method: 'POST',
        headers: { apikey: E.ANON, Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, body: '{}' })
    const text = await r.text()
    let body = null
    try { body = JSON.parse(text) } catch { body = text }
    return { status: r.status, body }
}
async function refresh(E, refreshToken) {
    const r = await fetch(`${E.URL_}/auth/v1/token?grant_type=refresh_token`, { method: 'POST',
        headers: { apikey: E.ANON, 'Content-Type': 'application/json' }, body: JSON.stringify({ refresh_token: refreshToken }) })
    const j = await r.json().catch(() => null)
    return { status: r.status, session: j }
}
function cookieFor(E, session) {
    const name = 'sb-' + E.URL_.split('//')[1].split('.')[0] + '-auth-token'
    return `${name}=base64-${Buffer.from(JSON.stringify(session)).toString('base64url')}`
}
async function get(E, session, path, idleMinutes) {
    const ck = [cookieFor(E, session)]
    if (idleMinutes !== undefined) ck.push(`${ACTIVITY_COOKIE}=${Date.now() - idleMinutes * 60_000}`)
    const r = await fetch(BASE + path, { headers: { cookie: ck.join('; ') }, redirect: 'manual' })
    return { status: r.status, loc: r.headers.get('location') || '' }
}

async function main() {
    const other = heldBy()
    if (other) {
        console.error(`✗ live-lock 被【${other.holder}】(pid ${other.pid})占着 —— 等它跑完再来。`)
        return exitAfterCleanup(5)
    }
    acquireOrExit('db/scripts/2026-10-19-mes9a-signin-checks.mjs', { ownExit: false })
    locked = true
    openPlan('db/scripts/2026-10-19-mes9a-signin-checks.mjs')
    await reapStalePlans()
    const E = env()
    if (!E.URL_ || !E.ANON) throw new Error('MES9A_DRIVER|.env.local has no NEXT_PUBLIC_SUPABASE_URL / ANON key')
    try { const r = await fetch(BASE + '/login', { redirect: 'manual' }); must(r.status === 200, `${BASE}/login answered ${r.status}`) }
    catch (e) { throw new Error(`MES9A_DRIVER|no app at ${BASE}: ${e.message}`) }

    const stamp = Date.now()
    const who = []
    for (const r of ROLE_CLONES) who.push({ key: `copy of ${r}`, kind: 'staff', acct: await mintThrowaway({ prefix: 'mes9aprobe', label: `si-${r}`, stamp, codes: { cloneOf: r } }) })
    who.push({ key: 'display only (floor_display)', kind: 'display', acct: await mintThrowaway({ prefix: 'mes9aprobe', label: 'si-display', stamp, codes: { realRole: 'floor_display' } }) })
    const sup = await mintThrowawaySupplier({ prefix: 'mes9aprobe', label: 'si-supplier' })
    who.push({ key: 'throwaway portal user', kind: 'portal', acct: await mintThrowaway({ prefix: 'mes9aprobe', label: 'si-portal', stamp, codes: { portalOf: sup.supplierId } }) })

    // ① ② ③ ④ per account
    for (const w of who) {
        const a = w.acct
        const staff = w.kind !== 'portal'
        const role = roleOf(a.token)
        must(role === (staff ? 'authenticated' : 'supplier_portal'), `${w.key}: token role ${role}`, staff)
        let db
        if (staff) {
            const p = await rpc(E, a.token, 'current_user_permissions')
            must(p.status === 200 && Array.isArray(p.body) && p.body.length === a.codes.length,
                `${w.key}: current_user_permissions → ${p.status} ${JSON.stringify(p.body).slice(0, 120)} (expected ${a.codes.length} codes)`, true)
            db = `current_user_permissions() ${p.body.length} codes`
        } else {
            const p = await rpc(E, a.token, 'portal_me')
            must(p.status === 200 && p.body?.supplier?.name === sup.legalName, `${w.key}: portal_me → ${p.status} ${JSON.stringify(p.body).slice(0, 160)}`)
            const q = await rpc(E, a.token, 'current_user_permissions')
            must(q.status !== 200, `${w.key}: a portal session called current_user_permissions (${q.status})`)
            db = `portal_me() → its own supplier · current_user_permissions() refused (HTTP ${q.status})`
        }
        const f = await refresh(E, a.session.refresh_token)
        must(f.status === 200 && f.session?.access_token, `${w.key}: refresh → HTTP ${f.status} ${JSON.stringify(f.session).slice(0, 160)}`, staff)
        const role2 = roleOf(f.session.access_token)
        must(role2 === role, `${w.key}: refreshed token role ${role2} ≠ ${role}`, staff)
        must(f.session.refresh_token && f.session.refresh_token !== a.session.refresh_token, `${w.key}: refresh did not rotate the refresh token`, staff)
        const p2 = await rpc(E, f.session.access_token, staff ? 'current_user_permissions' : 'portal_me')
        must(p2.status === 200, `${w.key}: the refreshed token cannot query the database (HTTP ${p2.status})`, staff)
        w.oldRefresh = a.session.refresh_token
        w.session = f.session
        let idle = 'n/a (portal idle logout is this cut\'s app code — proved on the local app in the live verification)'
        if (w.kind === 'staff') {
            const s29 = await get(E, f.session, '/', 29)
            const s31 = await get(E, f.session, '/', 31)
            must(s29.status === 200, `${w.key}: at 29 min idle / answered ${s29.status} ${s29.loc}`, true)
            must(s31.status === 307 && s31.loc.includes('/login') && s31.loc.includes('reason=ended'), `${w.key}: at 31 min idle / answered ${s31.status} ${s31.loc}`, true)
            idle = '29 min → / 200 · 31 min → 307 /login?reason=ended'
        } else if (w.kind === 'display') {
            const s31 = await get(E, f.session, '/display', 31)
            must(s31.status === 200, `${w.key}: at 31 min idle /display answered ${s31.status} ${s31.loc} (the exemption is gone)`, true)
            idle = '31 min → /display 200 (exempt, as today)'
        }
        console.log(`SIGNIN|${w.key}|${a.email}|sign-in ok · token role ${role}|${db}|refresh ok · role ${role2} · refresh token rotated|idle: ${idle}`)
    }

    // ⑤ rotation, as today (measured with the hook off and on: docs/surveys/MES-9a/readings/rotation-compare.txt): GoTrue lets the PARENT of the
    //   active token be reused (it answers with the active child) and refuses an older one. So: refresh once more (C1 → C2), wait out the 10 s
    //   reuse interval, then the grandparent P must be refused with refresh_token_already_used — and C2 still refreshes.
    for (const w of who) {
        const c2 = await refresh(E, w.session.refresh_token)
        must(c2.status === 200 && c2.session?.refresh_token, `${w.key}: second refresh → HTTP ${c2.status}`, w.kind !== 'portal')
        w.c2 = c2.session.refresh_token
    }
    await new Promise((r) => setTimeout(r, 11_000))
    for (const w of who) {
        const again = await refresh(E, w.oldRefresh)
        must(again.status === 400 && String(again.session?.error_code ?? '') === 'refresh_token_already_used',
            `${w.key}: the grandparent refresh token reused after 11 s → HTTP ${again.status} ${again.session?.error_code ?? ''}`, w.kind !== 'portal')
        const still = await refresh(E, w.c2)
        must(still.status === 200, `${w.key}: the active refresh token stopped working after the reuse attempt (HTTP ${still.status})`, w.kind !== 'portal')
        console.log(`ROTATION|${w.key}|grandparent token reused after 11 s → HTTP ${again.status} ${again.session?.error_code} · active token still refreshes (HTTP ${still.status}) — as with the hook off`)
    }
    console.log('STEP|done')
    return exitAfterCleanup(0)
}

main().catch((e) => {
    console.error(String(e?.stack || e))
    return exitAfterCleanup(staffFailure ? 3 : String(e?.message || '').startsWith('MES9A_DRIVER') ? 2 : 1)
})
