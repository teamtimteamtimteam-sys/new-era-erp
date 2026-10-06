#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// MES-2(2026-10-06)· Q31 —— 一次【满 500 条消息】的网关调用,在线上要多久(对着 anon 的 3 秒语句上限)
// ════════════════════════════════════════════════════════════════════════════
// 【为什么】docs/known-issues.md 的 MES1-ANON-STATEMENT-TIMEOUT-3S:ingest_submit 以 anon 跑,线上 anon 的
//   statement_timeout = 3s;满额一批从来没有被量过(fixture 249 的 SIZE 臂发的是 501 条,在逐条循环之前就被
//   too_many 拒掉了)。MES-2 Step 0 Q31(Tim):这是 MES-2 的【第一个线上步骤,在任何 DDL 之前】。
// 【怎么量】一台探针网关 + 一台 connection_test 设备(不产生草稿);三次 500 条小消息、三次 500 条贴着 256 KB 上限的消息;
//   每一次调用都用一条新的 stream,于是每一条都走完整的逐条工作(信封、设备、数据类、该序号以前有没有);
//   每一次之前先发一次心跳当往返基线。报:每一次的墙钟、心跳基线、两者之差(服务端的估计)。
// 【判据(Q31)】≤ 1.5 s(上限的一半)→ 不动,关掉那条已知问题;> 1.5 s → MES-2 的迁移里把循环改成按批的,再量;
//   仍 > 1.5 s → 降 max_messages。**永远不加函数级的 statement_timeout(那要 Tim)。**
// 【留下什么】3,000 行收件箱、6 + 6 行传输日志(心跳桶另计)、网关与设备各一台(停用)—— 采集层只可追加,
//   留作测试数据(docs/known-wrong-until-cutover.md 一行)。收件箱那 3,000 行在最后由员工处理成 transformed,
//   不留一堆 received 在收件箱里。
// 【身份】网关一侧 = 匿名(公开 anon key);员工一侧 = mintThrowaway(前缀 mes2probe,只持 action.manage_devices +
//   module.processing.view),跑完收走。
// 【判决】只从最后那一行 `MES2_TIMING_EXIT=` 读:0 = 量完 · 1 = 有一次调用没被接受 · 2 = 脚本坏了 · 5 = live-lock 被占。
// 用法:node db/scripts/2026-10-06-mes2-batch-timing.mjs --out=<path.json>
// ════════════════════════════════════════════════════════════════════════════
import { readFileSync, writeFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { performance } from 'node:perf_hooks'
import { acquireOrExit, release, heldBy } from '../../scripts/liveLock.mjs'
import { openPlan, mintThrowaway, reapStalePlans, installExitHooks, exitAfterCleanup } from '../../scripts/ephemeral.mjs'

const ROOT = dirname(dirname(dirname(fileURLToPath(import.meta.url))))
const env = readFileSync(join(ROOT, '.env.local'), 'utf8')
const URL_ = env.match(/NEXT_PUBLIC_SUPABASE_URL=(\S+)/)[1]
const ANON = env.match(/NEXT_PUBLIC_SUPABASE_ANON_KEY=(\S+)/)[1]
const OUT = (process.argv.find((a) => a.startsWith('--out=')) || '').slice('--out='.length) || null

let locked = false
installExitHooks({ onFinish: (code) => {
    try { if (locked) release() } catch { /* 放锁失败不改判决 */ }
    console.log(`MES2_TIMING_EXIT=${code}`)
} })

async function gw(gateway, key, body) {
    const payload = JSON.stringify({ p_gateway: gateway, p_key: key, p_body: body })
    const t0 = performance.now()
    const r = await fetch(URL_ + '/rest/v1/rpc/ingest_submit', { method: 'POST',
        headers: { apikey: ANON, Authorization: `Bearer ${ANON}`, 'Content-Type': 'application/json' }, body: payload })
    const text = await r.text()
    const ms = performance.now() - t0
    let j = null
    try { j = JSON.parse(text) } catch { /* 下面按原文报 */ }
    return { status: r.status, body: j, raw: text.slice(0, 300), ms, sentBytes: Buffer.byteLength(payload) }
}
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
    try { j = JSON.parse(text) } catch { /* 下面统一报 */ }
    if (!r.ok || !Array.isArray(j)) throw new Error(`读 ${path}: HTTP ${r.status} ${text.slice(0, 300)}`)
    return j
}

/** 500 条消息;pad 让整批贴着 256 KB(jsonb::text 比 JSON.stringify 每条多十来个空格,所以目标留 ~6 KB 余量)。 */
function batch(device, stream, pad) {
    const messages = []
    for (let i = 1; i <= 500; i++) {
        const payload = pad ? { text: `timing ${i}`, pad: 'x'.repeat(pad) } : { text: `timing ${i}` }
        messages.push({ seq: i, device, class: 'connection_test', payload })
    }
    return { stream, messages }
}

async function main() {
    const other = heldBy()
    if (other) { console.error(`✗ live-lock 被【${other.holder}】(pid ${other.pid})占着。`); return exitAfterCleanup(5) }
    acquireOrExit('db/scripts/2026-10-06-mes2-batch-timing.mjs', { ownExit: false })
    locked = true
    openPlan('db/scripts/2026-10-06-mes2-batch-timing.mjs')
    await reapStalePlans()

    const stamp = Date.now()
    const S = await mintThrowaway({ prefix: 'mes2probe', label: 'staff', stamp, codes: ['action.manage_devices', 'module.processing.view'] })
    const T = S.token
    const gwId = await rpc(T, 'save_device', { p_fields: { name: `ZZ-PROBE-GW-T${stamp}`, kind: 'gateway', station: 'MES-2 Q31 timing' } })
    const [g] = await read(T, `devices?select=code&id=eq.${gwId}`)
    const devId = await rpc(T, 'save_device', { p_fields: { name: `ZZ-PROBE-DEV-T${stamp}`, kind: 'scale', gateway_id: gwId,
        data_class: 'connection_test', station: 'MES-2 Q31 timing' } })
    const [d] = await read(T, `devices?select=code&id=eq.${devId}`)
    const key = (await rpc(T, 'issue_gateway_key', { p_gateway_id: gwId })).secret
    console.log(`· gateway ${g.code} · device ${d.code} · staff ${S.email}`)

    // 预热一次(TLS 握手、连接池),不计入
    await gw(g.code, key, { heartbeat: true })

    // 贴着上限的 pad:先量一次不带 pad 的批的字节,再把余量平均分到 500 条上
    const bare = Buffer.byteLength(JSON.stringify(batch(d.code, 'x', 0)))
    const pad = Math.floor((256000 - 8000 - bare) / 500)
    const runs = []
    let notAccepted = 0
    for (const [kind, p] of [['small', 0], ['small', 0], ['small', 0], ['near-cap', pad], ['near-cap', pad], ['near-cap', pad]]) {
        const hb = await gw(g.code, key, { heartbeat: true })
        const stream = `timing-${kind}-${runs.length + 1}-${stamp}`
        const r = await gw(g.code, key, batch(d.code, stream, p))
        const ok = r.status === 200 && r.body?.ok === true && Array.isArray(r.body?.accepted) && r.body.accepted.length === 500
        if (!ok) notAccepted++
        const row = { kind, stream, sentBytes: r.sentBytes, status: r.status, accepted: r.body?.accepted?.length ?? null,
            rejected: r.body?.rejected?.length ?? null, code: r.body?.code ?? null, callMs: Math.round(r.ms), heartbeatMs: Math.round(hb.ms),
            serverEstimateMs: Math.round(r.ms - hb.ms), raw: ok ? undefined : r.raw }
        runs.push(row)
        console.log(`${ok ? '✓' : '✗'} ${kind.padEnd(8)} ${String(r.sentBytes).padStart(7)} B · call ${row.callMs} ms · heartbeat ${row.heartbeatMs} ms · server ≈ ${row.serverEstimateMs} ms · HTTP ${r.status} accepted ${row.accepted}${ok ? '' : ' ' + r.raw}`)
    }

    // 服务端那一侧也读一次:每一次数据调用的传输日志行(收到的字节、条数)
    const tx = await read(T, `ingest_transmissions?select=id,kind,result,bytes,message_count,received_at&gateway_id=eq.${gwId}&kind=eq.call&order=id`)
    console.log(`· transmission rows (data): ${tx.length} · ${tx.map((t) => `${t.result}/${t.message_count}/${t.bytes}B`).join(' · ')}`)

    // 收件箱的 3,000 行处理成 transformed(不把一堆 received 留给同事)
    let processed = 0
    for (let i = 0; i < 8; i++) {
        const p = await rpc(T, 'ingest_process_pending', { p_limit: 500 })
        processed += p?.processed ?? 0
        if (!p?.processed) break
    }
    const left = await read(T, `ingest_inbox?select=status&device_id=eq.${devId}&status=neq.transformed`)
    console.log(`· processed ${processed} inbox rows · not transformed: ${left.length}`)

    await rpc(T, 'retire_device', { p_id: devId, p_reason: 'MES-2 Q31 timing finished' })
    await rpc(T, 'retire_device', { p_id: gwId, p_reason: 'MES-2 Q31 timing finished' })

    const worst = Math.max(...runs.map((r) => r.serverEstimateMs))
    const worstCall = Math.max(...runs.map((r) => r.callMs))
    console.log(`· worst server estimate ${worst} ms · worst whole call ${worstCall} ms · threshold 1500 ms · anon limit 3000 ms`)
    if (OUT) writeFileSync(OUT, JSON.stringify({ stamp, gateway: { id: gwId, code: g.code }, device: { id: devId, code: d.code },
        pad, runs, transmissions: tx, processed, notTransformed: left.length, worstServerEstimateMs: worst, worstCallMs: worstCall }, null, 2))
    return exitAfterCleanup(notAccepted ? 1 : 0)
}

main().catch((e) => { console.error('✗ 脚本坏了:' + (e?.stack || e)); return exitAfterCleanup(2) })
