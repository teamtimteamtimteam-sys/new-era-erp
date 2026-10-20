#!/usr/bin/env node
// MES-9c(2026-10-20)· F19 的"之前"在 HTTP 上的读数:【已部署的】应用(还是 MES-9b 的页面代码 —— 一次调用读完那一组操作的全部行)以 cfo 与 admin 的
//   同码一次性克隆(前缀 mes9cprobe)打开 /settings/change-history,记状态码与耗时。只读;两个克隆由清理计划删掉。
// 判决只从最后一行 `F19_BEFORE_EXIT=` 读:0 = 量到了(不论页面是 200 还是 500 —— 这是一次测量,不是一条断言)· 2 = 驱动坏了。
// 用法:PROOF_BASE=https://new-era-erp.vercel.app node db/scripts/2026-10-20-mes9c-f19-deployed-before.mjs > <log> 2>&1
import { onlyWhenRunDirectly } from '../../scripts/lib/entrypoint.mjs'
import { acquireOrExit, release, heldBy } from '../../scripts/liveLock.mjs'
import { openPlan, mintThrowaway, reapStalePlans, installExitHooks, exitAfterCleanup } from '../../scripts/ephemeral.mjs'

onlyWhenRunDirectly(import.meta.url)
const BASE = process.env.PROOF_BASE || 'https://new-era-erp.vercel.app'
let locked = false
installExitHooks({ onFinish: (code) => { try { if (locked) release() } catch { /* 放锁失败不改判决 */ } console.log(`F19_BEFORE_EXIT=${code}`) } })
async function main() {
    const other = heldBy()
    if (other) { console.error(`✗ live-lock 被【${other.holder}】占着`); return exitAfterCleanup(5) }
    acquireOrExit('db/scripts/2026-10-20-mes9c-f19-deployed-before.mjs', { ownExit: false }); locked = true
    openPlan('db/scripts/2026-10-20-mes9c-f19-deployed-before.mjs')
    await reapStalePlans()
    const stamp = Date.now()
    for (const r of ['cfo', 'admin']) {
        const c = await mintThrowaway({ prefix: 'mes9cprobe', label: `f19b-${r}`, stamp, codes: { cloneOf: r } })
        const t0 = Date.now()
        const res = await fetch(BASE + '/settings/change-history', { headers: { cookie: `${c.cookie}; NEXT_LOCALE=en` }, redirect: 'manual' })
        const body = await res.text()
        console.log(`F19_BEFORE|deployed|${r}|HTTP ${res.status}|${Date.now() - t0} ms|${body.includes('data-trail-entry') ? 'entries listed' : body.includes('statement timeout') ? 'statement timeout' : 'no entries'}`)
    }
    return exitAfterCleanup(0)
}
main().catch((e) => { console.error(String(e?.stack || e)); return exitAfterCleanup(2) })
