#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// MES-6a-2(2026-10-10)· 线上验证的驱动 —— 一次性账号造好,把 SQL 证明在一笔回滚的事务里跑完,账号收走
// ════════════════════════════════════════════════════════════════════════════
// 与 db/scripts/2026-10-09-mes6a1-live-proof.mjs 同一个形状(只换了账号、文件名,以及末尾那一段 ppm 的写法):
//   ① 造账号(scripts/ephemeral.mjs 的 mintThrowaway —— 授权的唯一入口,删除步先于它要删的东西落盘):
//      cco / fin / rec / apl / sal / iv 六个恰好持所需码的一次性角色;外加七个真角色【此刻的码】的克隆(cloneOf —— 它们【不是】
//      真角色;证明里只拿它们读,不动手);
//   ② 以 psql 跑 db/scripts/2026-10-10-mes6a2-live-proof.sql(BEGIN … ROLLBACK),邮箱经 -v 传进去(SQL 自己再断言每一个都是
//      mes6a2probe-…@test.local);
//   ③ 拿 SQL 读回的原样含量(STEP|ppm|…)过 lib/substances.ts 的 contentText —— 屏幕上那一句由同一支函数写出(Q29);
//   ④ 按计划收走账号、授权、一次性角色,并读回线上 0 残留。
// 【判决】只从日志里最后那一行 `MES6A2_PROOF_EXIT=` 读(exitAfterCleanup 的 onFinish 打的)。
//   0 = 证明走完(STEP|done)且 psql 退 0 · 1 = 证明红了 · 2 = 驱动自己坏了 · 5 = live-lock 被占 · 6 = 收尾没完成。
// 用法:node db/scripts/2026-10-10-mes6a2-live-proof.mjs > <log> 2>&1
// ════════════════════════════════════════════════════════════════════════════
import { onlyWhenRunDirectly } from '../../scripts/lib/entrypoint.mjs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawnSync } from 'node:child_process'
import { acquireOrExit, release, heldBy } from '../../scripts/liveLock.mjs'
import { openPlan, mintThrowaway, reapStalePlans, installExitHooks, exitAfterCleanup } from '../../scripts/ephemeral.mjs'

onlyWhenRunDirectly(import.meta.url)

const ROOT = dirname(dirname(dirname(fileURLToPath(import.meta.url))))
const SQL = join(ROOT, 'db/scripts/2026-10-10-mes6a2-live-proof.sql')
const DSN = process.env.CHECK_MIRRORS_DSN || 'host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 user=postgres.wvywpohbwkiinmipmuku dbname=postgres'

let locked = false
installExitHooks({ onFinish: (code) => {
    try { if (locked) release() } catch { /* 放锁失败不改判决 */ }
    console.log(`MES6A2_PROOF_EXIT=${code}`)
} })

const ROLE_CLONES = ['admin', 'finance', 'warehouse', 'cto', 'cco', 'cfo', 'gm']

async function main() {
    const other = heldBy()
    if (other) {
        console.error(`✗ live-lock 被【${other.holder}】(pid ${other.pid})占着 —— 等它跑完再来。`)
        return exitAfterCleanup(5)
    }
    acquireOrExit('db/scripts/2026-10-10-mes6a2-live-proof.mjs', { ownExit: false })
    locked = true
    openPlan('db/scripts/2026-10-10-mes6a2-live-proof.mjs')
    await reapStalePlans()

    const stamp = Date.now()
    const who = {}
    const mint = async (key, label, codes) => {
        const a = await mintThrowaway({ prefix: 'mes6a2probe', label, stamp, codes })
        who[key] = a.email
        console.log(`· ${key}: ${a.email} ← ${a.roleCode} (${a.codes.length} codes${Array.isArray(codes) ? ': ' + a.codes.join(', ') : ''})`)
    }
    await mint('cco', 'cco', ['action.contract_terms', 'module.customers.view', 'module.customers.edit', 'module.suppliers.view',
                              'module.pricing.view', 'module.pricing.edit', 'data.view_prices', 'data.view_purchase_prices'])
    await mint('fin', 'fin', ['action.metal_prices', 'module.pricing.view', 'data.view_prices', 'data.view_purchase_prices'])
    await mint('rec', 'rec', ['module.inbound.view', 'module.inbound.edit', 'module.output.view', 'module.output.edit'])
    await mint('apl', 'apl', ['module.output.view', 'module.inbound.view', 'action.apply_assay'])
    await mint('sal', 'sal', ['module.customers.view', 'module.customers.edit', 'module.output.view', 'module.pricing.view', 'data.view_prices'])
    await mint('iv', 'iv', ['module.inbound.view', 'module.output.view'])
    for (const r of ROLE_CLONES) await mint(`c_${r}`, `c-${r}`, { cloneOf: r })

    const args = ['-X', '-v', 'ON_ERROR_STOP=1']
    for (const [k, v] of Object.entries(who)) args.push('-v', `${k}=${v}`)
    args.push('-f', SQL, DSN)
    const t0 = Date.now()
    const res = spawnSync('psql', args, { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 })
    const out = (res.stdout || '') + (res.stderr || '')
    for (const line of out.split('\n')) {
        const m = line.match(/(STEP\|.*|ROLE\|.*|AFTER\|.*|ERROR:.*|MES6A2_LIVE\|.*)$/)
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
    // ③ 屏幕上的写法:SQL 读回的原样含量(metal=pct=role)过 lib/substances.ts 的 contentText —— 与化验页、批次含量面板同一支函数
    const ppmLine = out.split('\n').find((l) => /STEP\|ppm\|/.test(l))
    if (ppmLine) {
        const { contentText } = await import(join(ROOT, 'lib/substances.ts'))
        const shown = ppmLine.replace(/^.*STEP\|ppm\|/, '').split(',').map((x) => { const [m, pct, role] = x.split('='); return `${m} ${contentText(pct, role)}` })
        console.log(`STEP|display|${shown.join(' · ')}`)
    }
    console.log('✓ 证明走完(STEP|done),整笔已回滚')
    return exitAfterCleanup(0)
}

main().catch((e) => { console.error('✗ 驱动自己坏了:' + (e?.stack || e)); return exitAfterCleanup(2) })
