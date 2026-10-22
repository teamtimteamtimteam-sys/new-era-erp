#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// PAYROLL-PAY-REVERSAL-1 收尾(TABLE-EXPORT-1 Part 1.3,2026-10-22)· 对【生产部署】的一次只读检查
// ════════════════════════════════════════════════════════════════════════════
// Tim 2026-10-22 19:07 CST 确认了 daec5c95 的部署。这一支只问两件事 —— 一个 finance 克隆(前缀 ppr1probe,与本刀线上证明同一族,
// scripts/ephemeral.mjs 的共用造号器;带一份员工档案,入职 2026-09-01,好让 /me 有东西可画)打开:
//   C1  JE-2026-0018 的凭证页(一张工资付款)—— 200;「Request reversal」钮 disabled,旁边那句指向 /finance/payroll-payments
//   C2  /me —— 200;「Every leave type」那张表画出
// 只发 GET;线上提交的只有那个一次性账号、它的授权与员工档案,由清理计划收走。
// 判决只从日志里最后那一行 `CLOSEOUT_CHECK_EXIT=` 读:0 = 两格 PASS 且收尾干净 · 1 = 有 FAIL · 2 = 驱动坏了 · 5 = live-lock 被占 · 6 = 收尾没完成。
// 用法:PROOF_BASE=https://new-era-erp.vercel.app node db/scripts/2026-10-22-payroll-pay-reversal-1-closeout-check.mjs > <log> 2>&1
// ════════════════════════════════════════════════════════════════════════════
import { spawnSync } from 'node:child_process'
import { onlyWhenRunDirectly } from '../../scripts/lib/entrypoint.mjs'
import { acquireOrExit, release, heldBy } from '../../scripts/liveLock.mjs'
import { openPlan, mintThrowaway, reapStalePlans, installExitHooks, exitAfterCleanup } from '../../scripts/ephemeral.mjs'

onlyWhenRunDirectly(import.meta.url)

const BASE = process.env.PROOF_BASE || 'https://new-era-erp.vercel.app'
const DSN = process.env.CHECK_MIRRORS_DSN || 'host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 user=postgres.wvywpohbwkiinmipmuku dbname=postgres'

let locked = false, bad = 0
const ok = (cond, what) => { console.log(`${cond ? 'PASS' : 'FAIL'}|${what}`); if (!cond) bad++; return cond }
function psql(sql) {
    const r = spawnSync('psql', [DSN, '-X', '-At', '-v', 'ON_ERROR_STOP=1'], { input: sql, encoding: 'utf8' })
    if (r.status !== 0) throw new Error(`PPR1C_DRIVER|psql: ${r.stderr}`)
    return (r.stdout || '').trim()
}
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
    acquireOrExit('db/scripts/2026-10-22-payroll-pay-reversal-1-closeout-check.mjs', { ownExit: false })
    locked = true
    openPlan('db/scripts/2026-10-22-payroll-pay-reversal-1-closeout-check.mjs')
    await reapStalePlans()
    try { const r = await fetch(BASE + '/login', { redirect: 'manual' }); if (r.status !== 200) throw new Error(`HTTP ${r.status}`) }
    catch (e) { throw new Error(`PPR1C_DRIVER|no app at ${BASE}: ${e.message}`) }

    const stamp = Date.now()
    const fin = await mintThrowaway({ prefix: 'ppr1probe', label: 'fin', stamp, codes: { cloneOf: 'finance' },
        employee: { code: `ZZ-PROBE-PPR1C-${stamp}`, legal_name: 'ZZ Probe PPR1 close-out', employment_type: 'full_time', work_category: 'office', hire_date: '2026-09-01' } })
    console.log(`CLONE|finance copy holds ${fin.codes.length} codes · employee ${fin.employeeId ? 'with profile' : 'NO PROFILE'}`)

    const j18 = psql(`SELECT id FROM journal_entries WHERE code = 'JE-2026-0018';`)
    const jp = await getWith(fin.cookie, `/finance/journal/${j18}`)
    const disabledBtn = /<button[^>]*\sdisabled=""[^>]*>Request reversal<\/button>/.test(jp.body)
    ok(jp.status === 200 && disabledBtn && jp.body.includes('This is a payroll payment') && jp.body.includes('href="/finance/payroll-payments"'),
       `C1: ${BASE}/finance/journal/JE-2026-0018 HTTP ${jp.status} in ${jp.ms} ms: "Request reversal" rendered disabled=${disabledBtn}, pointer to /finance/payroll-payments drawn`)
    const me = await getWith(fin.cookie, '/me')
    ok(me.status === 200 && me.body.includes('Every leave type') && me.body.includes('Hospitalisation Leave'),
       `C2: ${BASE}/me HTTP ${me.status} in ${me.ms} ms: the "Every leave type" table is drawn`)

    console.log(bad ? `STEP|done with ${bad} FAIL` : 'STEP|done')
    return exitAfterCleanup(bad ? 1 : 0)
}

main().catch((e) => {
    console.error(String(e?.stack || e))
    return exitAfterCleanup(String(e?.message || '').startsWith('PPR1C_DRIVER') ? 2 : 1)
})
