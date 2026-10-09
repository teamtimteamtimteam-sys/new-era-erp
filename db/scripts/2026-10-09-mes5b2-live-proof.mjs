#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// MES-5b-2(2026-10-09)· 线上验证的驱动 —— 一次性账号造好,把 SQL 证明在一笔回滚的事务里跑完,账号收走
// ════════════════════════════════════════════════════════════════════════════
// 与 db/scripts/2026-10-09-mes5b2-live-proof.mjs 同一个形状(只换了账号与文件名):
//   ① 造账号(scripts/ephemeral.mjs 的 mintThrowaway —— 授权的唯一入口,删除步先于它要删的东西落盘):
//      dev / cap / ops / fin 四个恰好持所需码的一次性角色,外加七个真角色【此刻的码】的克隆(cloneOf —— 它们【不是】真角色,
//      审批判据认不到它们;证明里只拿它们读,不动手);
//   ② 以 psql 跑 db/scripts/2026-10-09-mes5b2-live-proof.sql(BEGIN … ROLLBACK),邮箱经 -v 传进去(SQL 自己再断言每一个都是
//      mes5b2probe-…@test.local);
//   ③ 按计划收走账号、授权、一次性角色,并读回线上 0 残留。
// 【判决】只从日志里最后那一行 `MES5B2_PROOF_EXIT=` 读(exitAfterCleanup 的 onFinish 打的)。
//   0 = 证明走完(STEP|done)且 psql 退 0 · 1 = 证明红了 · 2 = 驱动自己坏了 · 5 = live-lock 被占 · 6 = 收尾没完成。
// 用法:node db/scripts/2026-10-09-mes5b2-live-proof.mjs > <log> 2>&1
// ════════════════════════════════════════════════════════════════════════════
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawnSync } from 'node:child_process'
import { acquireOrExit, release, heldBy } from '../../scripts/liveLock.mjs'
import { openPlan, mintThrowaway, reapStalePlans, installExitHooks, exitAfterCleanup } from '../../scripts/ephemeral.mjs'

const ROOT = dirname(dirname(dirname(fileURLToPath(import.meta.url))))
const SQL = join(ROOT, 'db/scripts/2026-10-09-mes5b2-live-proof.sql')
const DSN = process.env.CHECK_MIRRORS_DSN || 'host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 user=postgres.wvywpohbwkiinmipmuku dbname=postgres'

let locked = false
installExitHooks({ onFinish: (code) => {
    try { if (locked) release() } catch { /* 放锁失败不改判决 */ }
    console.log(`MES5B2_PROOF_EXIT=${code}`)
} })

const ROLE_CLONES = ['admin', 'finance', 'warehouse', 'cto', 'cco', 'cfo', 'gm']

async function main() {
    const other = heldBy()
    if (other) {
        console.error(`✗ live-lock 被【${other.holder}】(pid ${other.pid})占着 —— 等它跑完再来。`)
        return exitAfterCleanup(5)
    }
    acquireOrExit('db/scripts/2026-10-09-mes5b2-live-proof.mjs', { ownExit: false })
    locked = true
    openPlan('db/scripts/2026-10-09-mes5b2-live-proof.mjs')
    await reapStalePlans()

    const stamp = Date.now()
    const who = {}
    const mint = async (key, label, codes) => {
        const a = await mintThrowaway({ prefix: 'mes5b2probe', label, stamp, codes })
        who[key] = a.email
        console.log(`· ${key}: ${a.email} ← ${a.roleCode} (${a.codes.length} codes${Array.isArray(codes) ? ': ' + a.codes.join(', ') : ''})`)
    }
    await mint('dev', 'dev', ['module.processing.view', 'action.manage_devices'])
    await mint('cap', 'cap', ['module.processing.view', 'action.confirm_capture'])
    await mint('ops', 'ops', ['module.processing.view', 'module.processing.edit', 'action.processing_commit', 'action.processing_aftercare',
                              'module.inbound.view'])
    await mint('fin', 'fin', ['module.finance.view', 'module.finance.edit', 'data.view_prices', 'data.view_purchase_prices'])
    for (const r of ROLE_CLONES) await mint(`c_${r}`, `c-${r}`, { cloneOf: r })

    const args = ['-X', '-v', 'ON_ERROR_STOP=1']
    for (const [k, v] of Object.entries(who)) args.push('-v', `${k}=${v}`)
    args.push('-f', SQL, DSN)
    const t0 = Date.now()
    const res = spawnSync('psql', args, { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 })
    const out = (res.stdout || '') + (res.stderr || '')
    for (const line of out.split('\n')) {
        const m = line.match(/(STEP\|.*|ROLE\|.*|AFTER\|.*|ERROR:.*|MES5B2_LIVE\|.*)$/)
        if (m) console.log(m[1].replace(/^NOTICE:\s*/, ''))
        else if (/^ROLE\||^AFTER\|/.test(line)) console.log(line)
    }
    console.log(`· psql exit ${res.status} in ${((Date.now() - t0) / 1000).toFixed(1)}s`)
    const done = /STEP\|done\|/.test(out)
    if (res.status !== 0 || !done) {
        console.log('✗ 证明没有走完 —— psql 原文的末尾:')
        console.log(out.split('\n').slice(-25).join('\n'))
        return exitAfterCleanup(1)
    }
    console.log('✓ 证明走完(STEP|done),整笔已回滚')
    return exitAfterCleanup(0)
}

main().catch((e) => { console.error('✗ 驱动自己坏了:' + (e?.stack || e)); return exitAfterCleanup(2) })
