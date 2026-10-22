#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// CLAIM-RECEIPTS-1 收尾(PAYROLL-PAY-REVERSAL-1 Part 1.3,2026-10-22)· 对【生产部署】的一次只读检查
// ════════════════════════════════════════════════════════════════════════════
// Tim 2026-10-21 23:40 CST 确认了 5709a2c0 的部署。这一支只问两件事 —— 一个 finance 克隆(前缀 cr1probe,
// 与 CLAIM-RECEIPTS-1 的线上证明同一族,scripts/ephemeral.mjs 的共用造号器)打开:
//   C1  /finance/claims        —— 200,画出一张表,表头里有收据那一栏(「Receipts」)
//   C2  /settings/dictionaries —— 只【记】HTTP 状态与耗时(冒烟见过一次 500;慢已登记 SETTINGS-DICTIONARIES-30-SECOND-LOAD,本支不判、不查)
// 只发 GET;线上提交的只有那个一次性账号与它的授权,由清理计划收走。
// 判决只从日志里最后那一行 `CLOSEOUT_CHECK_EXIT=` 读:0 = C1 PASS 且收尾干净 · 1 = C1 FAIL · 2 = 驱动坏了 · 5 = live-lock 被占 · 6 = 收尾没完成。
// 用法:PROOF_BASE=https://new-era-erp.vercel.app node db/scripts/2026-10-22-claim-receipts-1-closeout-check.mjs > <log> 2>&1
// ════════════════════════════════════════════════════════════════════════════
import { onlyWhenRunDirectly } from '../../scripts/lib/entrypoint.mjs'
import { acquireOrExit, release, heldBy } from '../../scripts/liveLock.mjs'
import { openPlan, mintThrowaway, reapStalePlans, installExitHooks, exitAfterCleanup } from '../../scripts/ephemeral.mjs'

onlyWhenRunDirectly(import.meta.url)

const BASE = process.env.PROOF_BASE || 'https://new-era-erp.vercel.app'

let locked = false, bad = 0
const ok = (cond, what) => { console.log(`${cond ? 'PASS' : 'FAIL'}|${what}`); if (!cond) bad++; return cond }
async function getWith(cookie, path) {
    const t0 = Date.now()
    const r = await fetch(BASE + path, { headers: { cookie: `${cookie}; NEXT_LOCALE=en` }, redirect: 'manual' })
    const body = Buffer.from(await r.arrayBuffer()).toString('utf8')
    return { status: r.status, body, ms: Date.now() - t0 }
}

installExitHooks({
    onFinish: (code) => {
        try { if (locked) release() } catch { /* 放锁失败不改判决 */ }
        console.log(`CLOSEOUT_CHECK_EXIT=${code}`)
    },
})

async function main() {
    const other = heldBy()
    if (other) { console.error(`✗ live-lock 被【${other.holder}】(pid ${other.pid})占着`); return exitAfterCleanup(5) }
    acquireOrExit('db/scripts/2026-10-22-claim-receipts-1-closeout-check.mjs', { ownExit: false })
    locked = true
    openPlan('db/scripts/2026-10-22-claim-receipts-1-closeout-check.mjs')
    await reapStalePlans()
    try { const r = await fetch(BASE + '/login', { redirect: 'manual' }); if (r.status !== 200) throw new Error(`HTTP ${r.status}`) }
    catch (e) { throw new Error(`CR1C_DRIVER|no app at ${BASE}: ${e.message}`) }

    const fin = await mintThrowaway({ prefix: 'cr1probe', label: 'close', stamp: Date.now(), codes: { cloneOf: 'finance' } })
    console.log(`CLONE|finance copy holds ${fin.codes.length} codes`)

    const cl = await getWith(fin.cookie, '/finance/claims')
    ok(cl.status === 200 && cl.body.includes('<table') && cl.body.includes('>Receipts<'),
       `C1: ${BASE}/finance/claims HTTP ${cl.status} in ${cl.ms} ms, table rendered, receipts column header ("Receipts") drawn`)
    const d = await getWith(fin.cookie, '/settings/dictionaries')
    console.log(`RECORD|C2: ${BASE}/settings/dictionaries HTTP ${d.status} in ${d.ms} ms (${(d.ms / 1000).toFixed(1)} s) — recorded, not judged`)

    console.log(bad ? `STEP|done with ${bad} FAIL` : 'STEP|done')
    return exitAfterCleanup(bad ? 1 : 0)
}

main().catch((e) => {
    console.error(String(e?.stack || e))
    return exitAfterCleanup(String(e?.message || '').startsWith('CR1C_DRIVER') ? 2 : 1)
})
