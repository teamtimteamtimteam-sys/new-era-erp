#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// CLAIM-RECEIPTS-1 Q14(Tim 2026-10-21):【门户上传在生产上真正收得下多大】—— 量一次,不存任何东西
// ════════════════════════════════════════════════════════════════════════════
// Step 0 推断(没量过):Vercel 的函数请求体有上限(它的文档写 4.5 MB),于是门户承诺的 10 MB 在生产上过不去;MES-9c 的 10.2 MB 拒绝
//   是对着本地 next start 证的。这一支对着【部署着的应用】量那个数。
// 【怎么做到一个字节都不存】每一次 POST 的文件都是【故意认不出来的字节】(头一个字节 0x00):路由读完请求体、按文件头认不出类型,
//   交给库的是 application/octet-stream,portal_submission_begin 按名拒 PORTAL_UPLOAD_TYPE_NOT_ACCEPTED —— 在任何一行登记、任何一个字节
//   存下之前。所以:
//     303 → ?error=PORTAL_UPLOAD_TYPE_NOT_ACCEPTED   = 请求体【到了】应用(这个大小被平台收下)
//     303 → ?error=PORTAL_UPLOAD_TOO_LARGE          = 应用按 Content-Length 拒(> 10 MB + 64 KB),请求体没读
//     413 / 别的                                    = 平台在应用之前就拒了(记下状态码与回的那几个字)
//   先粗扫(1 · 2 · 3 · 4 · 4.5 · 5 · 6 · 8 · 9.9 MB),再在最大的收下与最小的拒之间二分到 16 KB。
// 一次性:一家供应商 + 一个门户账号(前缀 cr1probe,scripts/ephemeral.mjs 的共用造号器),由清理计划收走。
// 前后以 postgres 数:门户申请行 · portal-uploads 里的对象 —— 两个数必须不变。
// 判决只从日志里最后那一行 `Q14_EXIT=` 读:0 = 量到了且什么都没存 · 1 = 存了东西或读不出判断 · 2 = 驱动坏了 · 5 = live-lock 被占 · 6 = 收尾没完成。
// 用法:PROOF_BASE=https://new-era-erp.vercel.app node db/scripts/2026-10-21-claim-receipts-1-q14-portal-upload-limit.mjs > <log> 2>&1
// ════════════════════════════════════════════════════════════════════════════
import { onlyWhenRunDirectly } from '../../scripts/lib/entrypoint.mjs'
import { spawnSync } from 'node:child_process'
import { acquireOrExit, release, heldBy } from '../../scripts/liveLock.mjs'
import { openPlan, mintThrowaway, mintThrowawaySupplier, reapStalePlans, installExitHooks, exitAfterCleanup } from '../../scripts/ephemeral.mjs'

onlyWhenRunDirectly(import.meta.url)

const BASE = process.env.PROOF_BASE || 'https://new-era-erp.vercel.app'
const DSN = process.env.CHECK_MIRRORS_DSN || 'host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 user=postgres.wvywpohbwkiinmipmuku dbname=postgres'
const MB = 1048576

let locked = false, bad = 0
const ok = (cond, what) => { console.log(`${cond ? 'PASS' : 'FAIL'}|${what}`); if (!cond) bad++; return cond }
function psql(sql) {
    const r = spawnSync('psql', [DSN, '-X', '-At', '-v', 'ON_ERROR_STOP=1'], { input: sql, encoding: 'utf8' })
    return (r.stdout || '').trim()
}
const counts = () => psql(`SELECT (SELECT count(*) FROM portal_certificate_submissions) || '|' || (SELECT count(*) FROM storage.objects WHERE bucket_id = 'portal-uploads');`)

async function post(cookie, fileBytes) {
    const bytes = Buffer.alloc(fileBytes)          // 全 0:认不出的文件头
    const fd = new FormData()
    fd.set('cert_type', 'nea_import')
    fd.set('file', new Blob([bytes], { type: 'application/pdf' }), 'q14-probe.pdf')
    const req = new Request(BASE + '/portal/certificates/upload', { method: 'POST', body: fd, headers: { cookie: `${cookie}; NEXT_LOCALE=en` }, redirect: 'manual' })
    const body = Buffer.from(await req.clone().arrayBuffer())
    const t0 = Date.now()
    const r = await fetch(req)
    const loc = r.headers.get('location') || ''
    const text = r.status >= 400 ? (await r.text()).slice(0, 120).replace(/\s+/g, ' ') : ''
    const err = (loc.match(/error=([A-Z_]+)/) || [])[1] || null
    const verdict = r.status === 303 && err === 'PORTAL_UPLOAD_TYPE_NOT_ACCEPTED' ? 'reached-app'
        : r.status === 303 && err === 'PORTAL_UPLOAD_TOO_LARGE' ? 'app-refused-size'
        : r.status === 413 ? 'platform-refused' : 'other'
    console.log(`TRY|file ${fileBytes} B (${(fileBytes / MB).toFixed(3)} MB) · request body ${body.length} B · HTTP ${r.status}${err ? ' → ' + err : ''}${text ? ' · ' + text : ''} · ${Date.now() - t0} ms · ${verdict}`)
    return verdict
}

installExitHooks({
    onFinish: (code) => {
        try { if (locked) release() } catch { /* 放锁失败不改判决 */ }
        console.log(`Q14_EXIT=${code}`)
    },
})

async function main() {
    const other = heldBy()
    if (other) { console.error(`✗ live-lock 被【${other.holder}】(pid ${other.pid})占着`); return exitAfterCleanup(5) }
    acquireOrExit('db/scripts/2026-10-21-claim-receipts-1-q14-portal-upload-limit.mjs', { ownExit: false })
    locked = true
    openPlan('db/scripts/2026-10-21-claim-receipts-1-q14-portal-upload-limit.mjs')
    await reapStalePlans()
    try { const r = await fetch(BASE + '/login', { redirect: 'manual' }); if (r.status !== 200) throw new Error(`HTTP ${r.status}`) }
    catch (e) { throw new Error(`Q14_DRIVER|no app at ${BASE}: ${e.message}`) }

    const before = counts()
    console.log(`BEFORE(postgres)|portal submissions|portal-uploads objects = ${before}`)
    const sup = await mintThrowawaySupplier({ prefix: 'cr1probe', label: 'q14' })
    const p = await mintThrowaway({ prefix: 'cr1probe', label: 'q14p', stamp: Date.now(), codes: { portalOf: sup.supplierId } })

    const coarse = [1, 2, 3, 4, 4.5, 5, 6, 8, 9.9].map((m) => Math.round(m * MB))
    let lo = 0, hi = null
    for (const n of coarse) {
        const v = await post(p.cookie, n)
        if (v === 'reached-app') lo = Math.max(lo, n)
        else if (v === 'platform-refused' || v === 'other') { hi = n; break }
    }
    if (hi !== null && lo > 0) {
        while (hi - lo > 16 * 1024) {
            const mid = Math.round((lo + hi) / 2)
            const v = await post(p.cookie, mid)
            if (v === 'reached-app') lo = mid
            else hi = mid
        }
    }
    console.log(`RESULT|largest file that reached the app: ${lo} B (${(lo / MB).toFixed(3)} MB) · smallest refused before it: ${hi ?? 'none up to 9.9 MB'}${hi ? ` B (${(hi / MB).toFixed(3)} MB)` : ''}`)
    ok(lo > 0, 'at least one size reached the app (the measurement has a lower bound)')

    const after = counts()
    console.log(`AFTER(postgres)|portal submissions|portal-uploads objects = ${after}`)
    ok(after === before, `nothing stored: portal submissions and portal-uploads objects ${before} → ${after}`)
    console.log(bad ? `STEP|done with ${bad} FAIL` : 'STEP|done')
    return exitAfterCleanup(bad ? 1 : 0)
}

main().catch((e) => {
    console.error(String(e?.stack || e))
    return exitAfterCleanup(String(e?.message || '').startsWith('Q14_DRIVER') ? 2 : 1)
})
