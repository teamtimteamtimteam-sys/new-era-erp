#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// EXPENSE-MULTILINE-1 收尾(CLAIM-RECEIPTS-1 Part 1.3,2026-10-21)· 对【生产部署】的一次只读检查
// ════════════════════════════════════════════════════════════════════════════
// Tim 2026-10-21 00:58 CST 确认了 7636a66c 的部署。这一支只问一件事:部署着的应用对着迁移之后的库,
// 那三张在破窗里坏掉的页面是不是回来了 —— 一个 finance 克隆(前缀 em1probe,与本刀的线上证明同一族,scripts/ephemeral.mjs 的共用造号器)打开:
//   C1  /finance/expenses           —— 200,画出一张表,线上的 EXP-2026-0007 在里面
//   C2  /finance/expenses/<EXP-0007> —— 200,行表(「Lines」)在,那一行是 6120
//   C3  /finance/claims             —— 200,画出一张表,在途的 CLM-2026-0004 按笔画出(「Item 1」)
// 只发 GET;线上提交的只有那个一次性账号与它的授权,由清理计划收走。
// 判决只从日志里最后那一行 `CLOSEOUT_CHECK_EXIT=` 读:0 = 三格 PASS 且收尾干净 · 1 = 有 FAIL · 2 = 驱动坏了 · 5 = live-lock 被占 · 6 = 收尾没完成。
// 用法:PROOF_BASE=https://new-era-erp.vercel.app node db/scripts/2026-10-21-expense-multiline-1-closeout-check.mjs > <log> 2>&1
// ════════════════════════════════════════════════════════════════════════════
import { onlyWhenRunDirectly } from '../../scripts/lib/entrypoint.mjs'
import { spawnSync } from 'node:child_process'
import { acquireOrExit, release, heldBy } from '../../scripts/liveLock.mjs'
import { openPlan, mintThrowaway, reapStalePlans, installExitHooks, exitAfterCleanup } from '../../scripts/ephemeral.mjs'

onlyWhenRunDirectly(import.meta.url)

const BASE = process.env.PROOF_BASE || 'https://new-era-erp.vercel.app'
const DSN = process.env.CHECK_MIRRORS_DSN || 'host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 user=postgres.wvywpohbwkiinmipmuku dbname=postgres'

let locked = false, bad = 0
const ok = (cond, what) => { console.log(`${cond ? 'PASS' : 'FAIL'}|${what}`); if (!cond) bad++; return cond }
function psql(sql) {
    const r = spawnSync('psql', [DSN, '-X', '-At', '-v', 'ON_ERROR_STOP=1'], { input: sql, encoding: 'utf8' })
    return { code: r.status, out: (r.stdout || ''), err: (r.stderr || '') }
}
async function getWith(cookie, path) {
    const r = await fetch(BASE + path, { headers: { cookie: `${cookie}; NEXT_LOCALE=en` }, redirect: 'manual' })
    return { status: r.status, body: Buffer.from(await r.arrayBuffer()).toString('utf8') }
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
    acquireOrExit('db/scripts/2026-10-21-expense-multiline-1-closeout-check.mjs', { ownExit: false })
    locked = true
    openPlan('db/scripts/2026-10-21-expense-multiline-1-closeout-check.mjs')
    await reapStalePlans()
    try { const r = await fetch(BASE + '/login', { redirect: 'manual' }); if (r.status !== 200) throw new Error(`HTTP ${r.status}`) }
    catch (e) { throw new Error(`EM1C_DRIVER|no app at ${BASE}: ${e.message}`) }

    const fin = await mintThrowaway({ prefix: 'em1probe', label: 'close', stamp: Date.now(), codes: { cloneOf: 'finance' } })
    console.log(`CLONE|finance copy holds ${fin.codes.length} codes`)

    const list = await getWith(fin.cookie, '/finance/expenses')
    ok(list.status === 200 && list.body.includes('<table') && list.body.includes('EXP-2026-0007'),
       `C1: ${BASE}/finance/expenses HTTP ${list.status}, table rendered (<table> present, EXP-2026-0007 in it)`)
    const e7 = psql(`SELECT id FROM expenses WHERE code = 'EXP-2026-0007';`).out.trim()
    const d7 = await getWith(fin.cookie, `/finance/expenses/${e7}`)
    ok(d7.status === 200 && d7.body.includes('<table') && d7.body.includes('>Lines<') && d7.body.includes('6120'),
       `C2: ${BASE}/finance/expenses/<EXP-2026-0007> HTTP ${d7.status}, lines table rendered ("Lines", the one line on 6120)`)
    const cl = await getWith(fin.cookie, '/finance/claims')
    ok(cl.status === 200 && cl.body.includes('<table') && cl.body.includes('CLM-2026-0004') && cl.body.includes('Item 1'),
       `C3: ${BASE}/finance/claims HTTP ${cl.status}, table rendered, pending CLM-2026-0004 drawn item by item ("Item 1")`)

    console.log(bad ? `STEP|done with ${bad} FAIL` : 'STEP|done')
    return exitAfterCleanup(bad ? 1 : 0)
}

main().catch((e) => {
    console.error(String(e?.stack || e))
    return exitAfterCleanup(String(e?.message || '').startsWith('EM1C_DRIVER') ? 2 : 1)
})
