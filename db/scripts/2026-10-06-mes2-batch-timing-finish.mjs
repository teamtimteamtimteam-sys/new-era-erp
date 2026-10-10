#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// MES-2(2026-10-06)· Q31 计时探针的收尾 —— 2026-10-06-mes2-batch-timing.mjs 那一跑在第五次调用时死在网络上(fetch failed),
//   它的收尾(处理收件箱、停用设备与网关)没有跑到。这一支只做那三件事,别的什么都不碰:
//   ① 以一次性员工(mes2probe,只持 action.manage_devices + module.processing.view)把探针网关 DEV-2026-0003 的
//      received 行处理成 transformed(ingest_process_pending —— 它只取 received,全库按 id 顺序;线上此刻没有别人的 received 行,
//      开跑前先读一次确认,有别人的就停);② 停用设备 DEV-2026-0004;③ 停用网关 DEV-2026-0003(连同它的钥匙)。
// 【判决】只从 `MES2_FINISH_EXIT=` 读:0 = 做完 · 1 = 有一步没达到 · 2 = 脚本坏了 · 3 = 收件箱里有别人的 received 行,没动 · 5 = 锁被占。
// ════════════════════════════════════════════════════════════════════════════
import { onlyWhenRunDirectly } from '../../scripts/lib/entrypoint.mjs'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { acquireOrExit, release, heldBy } from '../../scripts/liveLock.mjs'
import { openPlan, mintThrowaway, reapStalePlans, installExitHooks, exitAfterCleanup } from '../../scripts/ephemeral.mjs'

onlyWhenRunDirectly(import.meta.url)

const ROOT = dirname(dirname(dirname(fileURLToPath(import.meta.url))))
const env = readFileSync(join(ROOT, '.env.local'), 'utf8')
const URL_ = env.match(/NEXT_PUBLIC_SUPABASE_URL=(\S+)/)[1]
const ANON = env.match(/NEXT_PUBLIC_SUPABASE_ANON_KEY=(\S+)/)[1]
let locked = false
installExitHooks({ onFinish: (code) => { try { if (locked) release() } catch { /* */ } console.log(`MES2_FINISH_EXIT=${code}`) } })

async function rpc(token, fn, body = {}) {
    const r = await fetch(URL_ + '/rest/v1/rpc/' + fn, { method: 'POST',
        headers: { apikey: ANON, Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, body: JSON.stringify(body) })
    const text = await r.text()
    if (!r.ok) throw new Error(`RPC ${fn}: HTTP ${r.status} ${text.slice(0, 300)}`)
    return text ? JSON.parse(text) : null
}
async function read(token, path) {
    const r = await fetch(URL_ + '/rest/v1/' + path, { headers: { apikey: ANON, Authorization: `Bearer ${token}` } })
    const text = await r.text()
    let j = null
    try { j = JSON.parse(text) } catch { /* */ }
    if (!r.ok || !Array.isArray(j)) throw new Error(`读 ${path}: HTTP ${r.status} ${text.slice(0, 300)}`)
    return j
}

async function main() {
    const other = heldBy()
    if (other) { console.error(`✗ live-lock 被【${other.holder}】占着。`); return exitAfterCleanup(5) }
    acquireOrExit('db/scripts/2026-10-06-mes2-batch-timing-finish.mjs', { ownExit: false })
    locked = true
    openPlan('db/scripts/2026-10-06-mes2-batch-timing-finish.mjs')
    await reapStalePlans()
    const S = await mintThrowaway({ prefix: 'mes2probe', label: 'finish', codes: ['action.manage_devices', 'module.processing.view'] })
    const T = S.token
    const [g] = await read(T, 'devices?select=id,code,retired_at&code=eq.DEV-2026-0003')
    const [d] = await read(T, 'devices?select=id,code,retired_at&code=eq.DEV-2026-0004')
    const foreign = await read(T, `ingest_inbox?select=id&status=eq.received&or=(gateway_id.is.null,gateway_id.neq.${g.id})`)
    if (foreign.length) { console.error(`✗ 收件箱里有 ${foreign.length} 行别人的 received —— 不处理,停。`); return exitAfterCleanup(3) }
    let processed = 0
    for (let i = 0; i < 8; i++) {
        const p = await rpc(T, 'ingest_process_pending', { p_limit: 500 })
        console.log(`· ingest_process_pending → ${JSON.stringify(p)}`)
        processed += p?.processed ?? 0
        if (!p?.processed) break
    }
    const left = await read(T, `ingest_inbox?select=status&gateway_id=eq.${g.id}&status=neq.transformed`)
    console.log(`· processed ${processed} · not transformed on the probe gateway: ${left.length}`)
    if (!d.retired_at) await rpc(T, 'retire_device', { p_id: d.id, p_reason: 'MES-2 Q31 timing finished' })
    if (!g.retired_at) await rpc(T, 'retire_device', { p_id: g.id, p_reason: 'MES-2 Q31 timing finished' })
    const h = await read(T, `gateway_health?select=status,active_keys&gateway_id=eq.${g.id}`)
    console.log(`· gateway ${g.code}: ${JSON.stringify(h)}`)
    const ok = left.length === 0 && h[0]?.status === 'retired' && h[0]?.active_keys === 0
    return exitAfterCleanup(ok ? 0 : 1)
}
main().catch((e) => { console.error('✗ 脚本坏了:' + (e?.stack || e)); return exitAfterCleanup(2) })
