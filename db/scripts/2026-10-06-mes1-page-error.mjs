#!/usr/bin/env node
// MES-1 · 一次性诊断(DEV_LOG=<文件> node db/scripts/2026-10-06-mes1-page-error.mjs <路径>…):以一个全码一次性账号起 next dev,取两条设备页,把服务端的报错原样印出来。跑完收走账号。
import { openSync } from 'node:fs'
import { spawn } from 'node:child_process'
import { acquireOrExit, release, heldBy } from '../../scripts/liveLock.mjs'
import { openPlan, mintThrowaway, reapStalePlans, installExitHooks, exitAfterCleanup } from '../../scripts/ephemeral.mjs'
const LOG = process.env.DEV_LOG
let locked = false, dev = null
installExitHooks({ onFinish: (code) => { try { if (dev) process.kill(-dev.pid, 'SIGTERM') } catch { /* 已经退了 */ } ; try { if (locked) release() } catch {} ; console.log(`PAGEERR_EXIT=${code}`) } })
async function main() {
    if (heldBy()) { console.error('lock held'); return exitAfterCleanup(5) }
    acquireOrExit('db/scripts/2026-10-06-mes1-page-error.mjs', { ownExit: false }); locked = true
    openPlan('db/scripts/2026-10-06-mes1-page-error.mjs'); await reapStalePlans()
    const S = await mintThrowaway({ prefix: 'mes1probe', label: 'page', codes: 'all' })
    const fd = openSync(LOG, 'w')
    dev = spawn('npx', ['next', 'dev', '-p', '3197'], { detached: true, stdio: ['ignore', fd, fd] })
    for (let i = 0; i < 90; i++) { try { const r = await fetch('http://localhost:3197/login'); if (r.status < 500) break } catch {} ; await new Promise((r) => setTimeout(r, 1000)) }
    for (const p of process.argv.slice(2)) {
        const r = await fetch('http://localhost:3197' + p, { headers: { cookie: S.cookie }, redirect: 'manual' })
        console.log(`${r.status} ${p}`)
    }
    await new Promise((r) => setTimeout(r, 1500))
    return exitAfterCleanup(0)
}
main().catch((e) => { console.error(e); return exitAfterCleanup(2) })
