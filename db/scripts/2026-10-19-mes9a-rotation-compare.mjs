#!/usr/bin/env node
// MES-9a · Verify 第 6 步的补充 —— 【刷新令牌轮换的样子,hook 关着与开着各量一次】(委托书「refresh-token rotation stays exactly as today」)
// 一个一次性账号(仓库角色的同码克隆,前缀 mes9aprobe):登录 → P;刷新 P → C1;等 11 秒(重用间隔 10 秒)再拿 P 去刷;
// 再刷 C1 → C2;等 11 秒拿 P(此刻它是祖父)去刷;最后拿 C2 去刷。打印每一步的 HTTP 状态与返回的错误码。不碰 hook 的开关 —— 由调用者在两次之间切。
// 判决:日志里最后那一行 MES9A_ROTATION_EXIT=(0 = 走完)。用法:LABEL=hook-off node db/scripts/2026-10-19-mes9a-rotation-compare.mjs
import { onlyWhenRunDirectly } from '../../scripts/lib/entrypoint.mjs'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { acquireOrExit, release, heldBy } from '../../scripts/liveLock.mjs'
import { openPlan, mintThrowaway, reapStalePlans, installExitHooks, exitAfterCleanup } from '../../scripts/ephemeral.mjs'
onlyWhenRunDirectly(import.meta.url)
const ROOT = dirname(dirname(dirname(fileURLToPath(import.meta.url))))
const LABEL = process.env.LABEL || 'run'
let locked = false
installExitHooks({ onFinish: (code) => { try { if (locked) release() } catch { /* */ } console.log(`MES9A_ROTATION_EXIT=${code}`) } })
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
async function main() {
    if (heldBy()) return exitAfterCleanup(5)
    acquireOrExit('db/scripts/2026-10-19-mes9a-rotation-compare.mjs', { ownExit: false }); locked = true
    openPlan('db/scripts/2026-10-19-mes9a-rotation-compare.mjs'); await reapStalePlans()
    const txt = readFileSync(join(ROOT, '.env.local'), 'utf8')
    const get = (k) => (txt.match(new RegExp('^' + k + '=(.*)$', 'm'))?.[1] ?? '').trim().replace(/^"|"$/g, '')
    const URL_ = get('NEXT_PUBLIC_SUPABASE_URL'), ANON = get('NEXT_PUBLIC_SUPABASE_ANON_KEY')
    const refresh = async (rt) => {
        const r = await fetch(`${URL_}/auth/v1/token?grant_type=refresh_token`, { method: 'POST', headers: { apikey: ANON, 'Content-Type': 'application/json' }, body: JSON.stringify({ refresh_token: rt }) })
        const j = await r.json().catch(() => null)
        return { status: r.status, rt: j?.refresh_token ?? null, code: j?.error_code ?? j?.code ?? '' }
    }
    const a = await mintThrowaway({ prefix: 'mes9aprobe', label: `rot-${LABEL}`, codes: { cloneOf: 'warehouse' } })
    const P = a.session.refresh_token
    const c1 = await refresh(P)
    console.log(`ROT|${LABEL}|refresh P → ${c1.status} (C1 ${c1.rt ? 'issued' : 'none'})`)
    await sleep(11_000)
    const reP = await refresh(P)
    console.log(`ROT|${LABEL}|reuse P (the parent of the active token) after 11 s → ${reP.status} ${reP.code}${reP.rt ? ' · returned ' + (reP.rt === c1.rt ? 'C1 itself' : 'a new token') : ''}`)
    const c2 = await refresh(c1.rt)
    console.log(`ROT|${LABEL}|refresh C1 → ${c2.status} ${c2.code}`)
    await sleep(11_000)
    const reP2 = await refresh(P)
    console.log(`ROT|${LABEL}|reuse P (now a grandparent) after 11 s → ${reP2.status} ${reP2.code}`)
    const useC2 = c2.rt ? await refresh(c2.rt) : { status: 'n/a', code: '' }
    console.log(`ROT|${LABEL}|then refresh C2 → ${useC2.status} ${useC2.code}`)
    return exitAfterCleanup(0)
}
main().catch((e) => { console.error(String(e?.stack || e)); return exitAfterCleanup(1) })
