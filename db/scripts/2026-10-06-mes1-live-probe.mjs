#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// MES-1(2026-10-06)· 线上验证 —— 一台探针网关从登记到停用,全程走真的 HTTPS
// ════════════════════════════════════════════════════════════════════════════
// 【委托书 §Live verification】登记探针网关 ZZ-PROBE-GW-<stamp> 与一台设备,发钥匙;经 HTTPS:心跳、一条 connection_test、
//   一次重复、一次同序号不同内容、一次错钥匙;以登录的员工处理收件箱;两把钥匙并存地换钥匙、撤旧的、确认线路照常;停用网关。
// 【两种身份】
//   · 网关那一侧 = 匿名:apikey = 公开的 anon key,调 /rest/v1/rpc/ingest_submit —— 与厂商文档(docs/integration/gateway-interface.md)
//     逐字同一种调法。它够得着的只有那一支函数。
//   · 员工那一侧 = 一个一次性账号(mintThrowaway,前缀 mes1probe,只持 action.manage_devices + module.processing.view),
//     以它的令牌调 save_device / issue_gateway_key / ingest_process_pending / discard_inbox_row / revoke_gateway_key / retire_device,
//     并读 pending_values / gateway_health / operations_now。跑完按 ephemeral 计划收走(账号、授权、一次性角色)。
// 【留下什么】探针网关、它带的设备、钥匙两行(哈希)、传输日志、收件箱、中断 —— 采集层只可追加,这些行留在线上当测试数据
//   (docs/known-wrong-until-cutover.md 一行)。另有两行【未知网关】的拒绝日志,报上来的编号同样以 ZZ-PROBE-GW- 开头。
// 【判决】只从日志里最后那一行 `MES1_PROBE_EXIT=` 读(exitAfterCleanup 的 onFinish 打的)。
//   0 = 全过 · 1 = 有断言失败 · 2 = 探针自己坏了 · 5 = live-lock 被占 · 6 = 收尾没完成。
// 用法:node db/scripts/2026-10-06-mes1-live-probe.mjs  (结果另写一份 JSON 到 --out=<path>)
// ════════════════════════════════════════════════════════════════════════════
import { onlyWhenRunDirectly } from '../../scripts/lib/entrypoint.mjs'
import { readFileSync, writeFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { acquireOrExit, release, heldBy } from '../../scripts/liveLock.mjs'
import { openPlan, mintThrowaway, reapStalePlans, installExitHooks, exitAfterCleanup } from '../../scripts/ephemeral.mjs'

onlyWhenRunDirectly(import.meta.url)

const ROOT = dirname(dirname(dirname(fileURLToPath(import.meta.url))))
const env = readFileSync(join(ROOT, '.env.local'), 'utf8')
const URL_ = env.match(/NEXT_PUBLIC_SUPABASE_URL=(\S+)/)[1]
const ANON = env.match(/NEXT_PUBLIC_SUPABASE_ANON_KEY=(\S+)/)[1]
const OUT = (process.argv.find((a) => a.startsWith('--out=')) || '').slice('--out='.length) || null

let locked = false
installExitHooks({ onFinish: (code) => {
    try { if (locked) release() } catch { /* 放锁失败不改判决 */ }
    console.log(`MES1_PROBE_EXIT=${code}`)
} })

const failures = []
const evidence = []
function check(label, ok, got) {
    const line = `${ok ? '✓' : '✗'} ${label} —— ${typeof got === 'string' ? got : JSON.stringify(got)}`
    console.log(line)
    evidence.push({ label, ok, got })
    if (!ok) failures.push(label)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

/** 网关那一侧:匿名、HTTPS、与厂商文档同一种调法。 */
async function gw(gateway, key, body) {
    const r = await fetch(URL_ + '/rest/v1/rpc/ingest_submit', { method: 'POST',
        headers: { apikey: ANON, Authorization: `Bearer ${ANON}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ p_gateway: gateway, p_key: key, p_body: body }) })
    const text = await r.text()
    let j = null
    try { j = JSON.parse(text) } catch { /* 下面按原文报 */ }
    return { status: r.status, body: j, raw: text.slice(0, 300) }
}
/** 员工那一侧:以一次性账号的令牌调 RPC。失败不吞:非 2xx 抛出,带原文。 */
async function rpc(token, fn, body = {}) {
    const r = await fetch(URL_ + '/rest/v1/rpc/' + fn, { method: 'POST',
        headers: { apikey: ANON, Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
        body: JSON.stringify(body) })
    const text = await r.text()
    if (!r.ok) throw new Error(`RPC ${fn}: HTTP ${r.status} ${text.slice(0, 300)}`)
    return text ? JSON.parse(text) : null
}
/** 员工那一侧的读:失败 ≠ 空集。 */
async function read(token, path) {
    const r = await fetch(URL_ + '/rest/v1/' + path, { headers: { apikey: ANON, Authorization: `Bearer ${token}` } })
    const text = await r.text()
    let j = null
    try { j = JSON.parse(text) } catch { /* 下面统一报 */ }
    if (!r.ok || !Array.isArray(j)) throw new Error(`读 ${path}: HTTP ${r.status} ${text.slice(0, 300)}`)
    return j
}

async function main() {
    const other = heldBy()
    if (other) {
        console.error(`✗ live-lock 被【${other.holder}】(pid ${other.pid})占着 —— 等它跑完再来。`)
        return exitAfterCleanup(5)
    }
    acquireOrExit('db/scripts/2026-10-06-mes1-live-probe.mjs', { ownExit: false })
    locked = true
    openPlan('db/scripts/2026-10-06-mes1-live-probe.mjs')
    await reapStalePlans()

    const stamp = Date.now()
    const GW_NAME = `ZZ-PROBE-GW-${stamp}`
    const DEV_NAME = `ZZ-PROBE-DEV-${stamp}`
    const S = await mintThrowaway({ prefix: 'mes1probe', label: 'staff', stamp,
        codes: ['action.manage_devices', 'module.processing.view'] })
    const T = S.token
    console.log(`· staff: ${S.email} ← ${S.roleCode}(${S.codes.join(', ')})`)

    // ── ① 登记:网关先不给心跳间隔 —— V5 必须出现在「待补的标准值」里 ────────────────
    const gwSave = await rpc(T, 'save_device', { p_fields: { name: GW_NAME, kind: 'gateway', station: 'MES-1 live probe' } })
    const gwId = gwSave
    const [gwRow] = await read(T, `devices?select=id,code,name,kind&id=eq.${gwId}`)
    check('① 网关登记,编号保存时生成 DEV-YYYY-NNNN', /^DEV-\d{4}-\d{4}$/.test(gwRow?.code ?? ''), gwRow)
    const GW = gwRow.code
    const pv1 = await read(T, `pending_values?select=value_code,item_code,href&value_code=eq.V5&item_code=eq.${GW}`)
    check('① 间隔没给:pending_values 有这台网关的 V5 一行', pv1.length === 1, pv1)
    const h0 = await read(T, `gateway_health?select=status,active_keys&gateway_id=eq.${gwId}`)
    check('① 还没听到过:gateway_health = not_yet_heard', h0[0]?.status === 'not_yet_heard', h0)

    const devSave = await rpc(T, 'save_device', { p_fields: { name: DEV_NAME, kind: 'scale', gateway_id: gwId,
        data_class: 'connection_test', station: 'MES-1 live probe' } })
    const devId = devSave
    const [devRow] = await read(T, `devices?select=id,code,gateway_id&id=eq.${devId}`)
    check('① 设备登记在这台网关下', devRow?.gateway_id === gwId, devRow)
    const DEV = devRow.code

    const k1 = await rpc(T, 'issue_gateway_key', { p_gateway_id: gwId })
    check('① 发钥匙:密钥只在这一次返回,形状 ngk_ + 64 hex', /^ngk_[0-9a-f]{64}$/.test(k1?.secret ?? ''), { prefix: k1?.prefix })
    const K1 = k1.secret
    const masked = await read(T, `gateway_keys_masked?select=key_prefix,key_hash&gateway_id=eq.${gwId}`)
    check('① 钥匙表经遮蔽视图读:哈希永远是 NULL(never 规则)', masked.length === 1 && masked[0].key_hash === null, masked)
    const baseRead = await fetch(URL_ + `/rest/v1/gateway_keys?select=key_hash&gateway_id=eq.${gwId}`,
        { headers: { apikey: ANON, Authorization: `Bearer ${T}` } })
    check('① 基表的 key_hash 列对员工也不可读(列级授权外)', baseRead.status === 401 || baseRead.status === 403,
        `HTTP ${baseRead.status} ${(await baseRead.text()).slice(0, 120)}`)

    // ── ② 网关那一侧,经 HTTPS ───────────────────────────────────────────────
    const hb = await gw(GW, K1, { heartbeat: true })
    check('② 心跳 → {"ok": true}', hb.status === 200 && hb.body?.ok === true && Object.keys(hb.body).length === 1, hb.body ?? hb.raw)

    const ct = await gw(GW, K1, { stream: 'probe', messages: [
        { seq: 1, device: DEV, class: 'connection_test', payload: { text: 'MES-1 live probe' },
          site_from: new Date(Date.now() - 2000).toISOString(), site_to: new Date().toISOString(), dataset_ref: `probe-${stamp}` },
        { seq: 2, device: DEV, class: 'connection_test', payload: {} },
        { seq: 3, device: 'DEV-0000-0000', class: 'connection_test', payload: { text: 'x' } },
    ] })
    check('② connection_test:seq 1 与 2 收下,不认识的设备按名退回', ct.body?.ok === true
        && JSON.stringify(ct.body.accepted) === '[1,2]' && ct.body.rejected?.[0]?.code === 'DEVICE_NOT_ON_THIS_GATEWAY', ct.body ?? ct.raw)

    const dup = await gw(GW, K1, { stream: 'probe', messages: [
        { seq: 1, device: DEV, class: 'connection_test', payload: { text: 'MES-1 live probe' } } ] })
    check('② 重复:同序号同内容 → duplicates [1],什么都不再存', dup.body?.ok === true
        && JSON.stringify(dup.body.duplicates) === '[1]' && dup.body.accepted?.length === 0, dup.body ?? dup.raw)

    const reuse = await gw(GW, K1, { stream: 'probe', messages: [
        { seq: 1, device: DEV, class: 'connection_test', payload: { text: 'different content' } } ] })
    check('② 同序号不同内容 → rejected SEQ_REUSED', reuse.body?.ok === true && reuse.body.rejected?.[0]?.code === 'SEQ_REUSED'
        && reuse.body.accepted?.length === 0, reuse.body ?? reuse.raw)

    const wrong = await gw(GW, 'ngk_' + '0'.repeat(64), { heartbeat: true })
    const onlyRefused = (b) => b && Object.keys(b).length === 2 && b.ok === false && b.code === 'refused'
    check('② 错钥匙 → 只有 {"ok": false, "code": "refused"}', wrong.status === 200 && onlyRefused(wrong.body), wrong.body ?? wrong.raw)
    const unknown = await gw(`ZZ-PROBE-GW-UNKNOWN-${stamp}`, K1, { heartbeat: true })
    check('② 不认识的网关 → 同一句 refused(分不出来)', unknown.status === 200 && onlyRefused(unknown.body), unknown.body ?? unknown.raw)

    // ── ③ 员工处理收件箱(module.processing.view)────────────────────────────────
    const proc = await rpc(T, 'ingest_process_pending', { p_limit: 200 })
    check('③ Process received:两行处理,一行转换、一行失败', proc?.processed >= 2 && proc?.transformed >= 1 && proc?.failed >= 1, proc)
    const inbox = await read(T, `ingest_inbox?select=id,seq,status,error_code,transform_result&gateway_id=eq.${gwId}&order=seq`)
    const r1 = inbox.find((r) => r.seq === 1), r2 = inbox.find((r) => r.seq === 2)
    check('③ seq 1 transformed,结果 = 那句文字', r1?.status === 'transformed' && r1?.transform_result?.text === 'MES-1 live probe', r1)
    check('③ seq 2 failed,码 = CONNECTION_TEST_TEXT_REQUIRED(内容错:存下、看得见地失败)',
        r2?.status === 'failed' && r2?.error_code === 'CONNECTION_TEST_TEXT_REQUIRED', r2)
    const remind = await read(T, `operations_now?select=item_type,item_id,subject&item_type=eq.capture_inbox_failed`)
    check('③ 提醒 capture_inbox_failed 出现,指着那台设备', remind.some((x) => x.item_id === devId), remind)
    await rpc(T, 'discard_inbox_row', { p_id: r2.id, p_reason: 'MES-1 live probe: deliberately empty payload' })
    const [r2b] = await read(T, `ingest_inbox?select=status,error_code,discard_reason&id=eq.${r2.id}`)
    check('③ 带理由丢弃:状态 discarded,失败码留着', r2b?.status === 'discarded' && r2b?.error_code === 'CONNECTION_TEST_TEXT_REQUIRED', r2b)
    const remind2 = await read(T, `operations_now?select=item_id&item_type=eq.capture_inbox_failed`)
    check('③ 丢弃之后提醒消失', !remind2.some((x) => x.item_id === devId), remind2)

    // ── ④ 心跳间隔给了 → V5 消失;沉默超过间隔 → 回来时记一段中断 ──────────────────
    await rpc(T, 'save_device', { p_id: gwId, p_fields: { heartbeat_interval_s: 5 } })
    const pv2 = await read(T, `pending_values?select=value_code&value_code=eq.V5&item_code=eq.${GW}`)
    check('④ 间隔给了:V5 那一行自己消失', pv2.length === 0, pv2)
    await sleep(7000)
    const hs = await read(T, `gateway_health?select=status&gateway_id=eq.${gwId}`)
    check('④ 7 秒没听到(间隔 5 秒):gateway_health = silent', hs[0]?.status === 'silent', hs)
    const silentArm = await read(T, `operations_now?select=item_id&item_type=eq.gateway_silent`)
    check('④ 提醒 gateway_silent 出现,指着这台网关', silentArm.some((x) => x.item_id === gwId), silentArm)
    const hb2 = await gw(GW, K1, { heartbeat: true })
    const out = await read(T, `gateway_outages?select=silent_from,silent_to,interval_s&gateway_id=eq.${gwId}`)
    check('④ 回来的那一次心跳记下一段中断', hb2.body?.ok === true && out.length === 1 && out[0].interval_s === 5, out)

    // ── ⑤ 换钥匙:两把并存 → 撤旧的 → 线路照常 ──────────────────────────────────
    const k2 = await rpc(T, 'issue_gateway_key', { p_gateway_id: gwId })
    const K2 = k2.secret
    const h2 = await read(T, `gateway_health?select=active_keys&gateway_id=eq.${gwId}`)
    check('⑤ 新钥匙发出,两把同时有效', h2[0]?.active_keys === 2, h2)
    const both1 = await gw(GW, K1, { stream: 'probe', messages: [{ seq: 4, device: DEV, class: 'connection_test', payload: { text: 'old key' } }] })
    const both2 = await gw(GW, K2, { stream: 'probe', messages: [{ seq: 5, device: DEV, class: 'connection_test', payload: { text: 'new key' } }] })
    check('⑤ 两把都收得下', JSON.stringify(both1.body?.accepted) === '[4]' && JSON.stringify(both2.body?.accepted) === '[5]',
        { old: both1.body, new: both2.body })
    await rpc(T, 'revoke_gateway_key', { p_key_id: k1.key_id, p_reason: 'MES-1 live probe: rotation' })
    const old = await gw(GW, K1, { heartbeat: true })
    check('⑤ 撤掉的旧钥匙 → refused', old.body?.ok === false && old.body?.code === 'refused', old.body)
    const keep = await gw(GW, K2, { stream: 'probe', messages: [{ seq: 6, device: DEV, class: 'connection_test', payload: { text: 'after rotation' } }] })
    check('⑤ 新钥匙照常', JSON.stringify(keep.body?.accepted) === '[6]', keep.body)
    const proc2 = await rpc(T, 'ingest_process_pending', { p_limit: 200 })
    check('⑤ 换钥匙之后的三行也处理掉', proc2?.transformed >= 3, proc2)

    // ── ⑥ 传输日志:每一次都在,确切理由只在这里 ────────────────────────────────
    const tx = await read(T, `ingest_transmissions?select=kind,result,presented_key_prefix,client_address,bucket_count&gateway_id=eq.${gwId}&order=id`)
    const results = tx.filter((t) => t.kind === 'call').map((t) => t.result)
    check('⑥ 传输日志按次记下:accepted 与 bad_key / revoked_key 分得开', results.includes('bad_key') && results.includes('revoked_key')
        && results.filter((r) => r === 'accepted').length >= 6, results)
    const hbRows = tx.filter((t) => t.kind === 'heartbeat_hour')
    check('⑥ 心跳只让这一小时的那一行桶往上长', hbRows.length >= 1 && hbRows.reduce((a, t) => a + t.bucket_count, 0) >= 2, hbRows)
    const addr = [...new Set(tx.map((t) => t.client_address))]
    check('⑥ 调用方地址原样存下(未经核实)或 not available', addr.every((a) => typeof a === 'string' && a.length > 0),
        addr.map((a) => (a === 'not available' ? a : a.replace(/\d+(?=[.:]?[^.:]*$)/, 'x'))))

    // ── ⑦ 停用:设备、网关(连同钥匙)──────────────────────────────────────────
    await rpc(T, 'retire_device', { p_id: devId, p_reason: 'MES-1 live probe finished' })
    await rpc(T, 'retire_device', { p_id: gwId, p_reason: 'MES-1 live probe finished' })
    const h3 = await read(T, `gateway_health?select=status,active_keys&gateway_id=eq.${gwId}`)
    check('⑦ 网关停用:status retired,有效钥匙 0', h3[0]?.status === 'retired' && h3[0]?.active_keys === 0, h3)
    const dead = await gw(GW, K2, { heartbeat: true })
    check('⑦ 停用之后连新钥匙也 → refused', dead.body?.ok === false && dead.body?.code === 'refused', dead.body)

    console.log(`· probe gateway ${GW} (${GW_NAME}) id ${gwId} · device ${DEV} id ${devId}`)
    if (OUT) writeFileSync(OUT, JSON.stringify({ stamp, gateway: { id: gwId, code: GW, name: GW_NAME }, device: { id: devId, code: DEV, name: DEV_NAME },
        staff: S.email, evidence, failures }, null, 2))
    console.log(failures.length ? `✗ ${failures.length} 条断言失败:${failures.join(' · ')}` : `✓ 全部 ${evidence.length} 条断言通过`)
    return exitAfterCleanup(failures.length ? 1 : 0)
}

main().catch((e) => { console.error('✗ 探针自己坏了:' + (e?.stack || e)); return exitAfterCleanup(2) })
