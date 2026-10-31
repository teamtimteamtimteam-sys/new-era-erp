#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// ESG-2 Part 1 · CONTRACT-ESIGN 收尾 —— 对着【生产】(Vercel)只读地看一眼,一个按钮都不按、一个文件都不传
// ════════════════════════════════════════════════════════════════════════════
// 委托书 1.1 / 1.2:一个一次性 cfo 克隆(前缀 esg2probe)在生产上:
//   ① /contracts 打得开、没有错误边界;
//   ② /settings/signatories(设置 › 合同签署人)HTTP 200 —— 这条路由只有 v1.4.85 有(06287697 加的),
//      旧的生产会给 404 ⇒ 200 说明生产跑的是 0628769 / f5ffe87。cfo 不持 action.manage_signatories,
//      所以那一页按门渲染成受限说明;记下它印的是什么。
//   两页各记一次耗时(线上不是尺子)。只发 GET、只读 DOM。一次一位读者;开跑前与收尾后各量一次库。
// 判决只从最后一行 `CE_CLOSEOUT_EXIT=` 读:0 = 全 PASS 且收尾干净 · 1 = 有 FAIL 或中止 · 2 = 驱动坏了 · 5 = live-lock 被占 · 6 = 收尾没完成。
// 用法:PROOF_BASE=https://new-era-erp.vercel.app PUPPETEER_DIR=<装着 puppeteer-core 的目录> node db/scripts/2026-10-31-esg-2-part1-prod-check.mjs
// ════════════════════════════════════════════════════════════════════════════
import { readdirSync, existsSync } from 'node:fs'
import { join } from 'node:path'
import { homedir } from 'node:os'
import { createRequire } from 'node:module'
import { spawnSync } from 'node:child_process'
import { onlyWhenRunDirectly } from '../../scripts/lib/entrypoint.mjs'
import { acquireOrExit, release, heldBy } from '../../scripts/liveLock.mjs'
import { openPlan, mintThrowaway, reapStalePlans, installExitHooks, exitAfterCleanup } from '../../scripts/ephemeral.mjs'

onlyWhenRunDirectly(import.meta.url)

const BASE = process.env.PROOF_BASE || 'https://new-era-erp.vercel.app'
const PUP_DIR = process.env.PUPPETEER_DIR
const CHROME_ROOT = join(homedir(), '.cache/puppeteer/chrome-headless-shell')
const DSN = process.env.CHECK_MIRRORS_DSN || 'host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 user=postgres.wvywpohbwkiinmipmuku dbname=postgres'
const SCRIPT = 'db/scripts/2026-10-31-esg-2-part1-prod-check.mjs'

let locked = false, bad = 0, browser = null
const ok = (cond, what) => { console.log(`${cond ? 'PASS' : 'FAIL'}|${what}`); if (!cond) bad++; return cond }

installExitHooks({
    onFinish: (code) => {
        try { if (locked) release() } catch { /* 放锁失败不改判决 */ }
        console.log(`CE_CLOSEOUT_EXIT=${code}`)
    },
})

// ── 中止规则(AGENTS.md「线上证明一次一位读者」)──
function selectOne(tag) {
    const r = spawnSync('psql', [DSN, '-X', '-At'], { input: '\\timing on\nselect 1;\nselect 1;\nselect 1;\nselect 1;\nselect 1;\nexplain (analyze) select 1;\n', encoding: 'utf8', timeout: 120_000 })
    const out = r.stdout ?? ''
    const times = [...out.matchAll(/^Time: ([0-9.]+) ms/gm)].map((m) => Number(m[1])).slice(0, 5)
    const exec = Number((out.match(/Execution Time: ([0-9.]+) ms/) ?? [])[1])
    const med = [...times].sort((a, b) => a - b)[2]
    console.log(`SELECT1|${tag} client round trips ${times.map((x) => x.toFixed(0)).join(' / ')} ms (median ${med?.toFixed(0)}) · server execution ${exec} ms`)
    return { med, exec, max: Math.max(...times) }
}
/** Management API 的健康检查(只读;只取 name/status 两个字段) */
function health() {
    const tok = spawnSync('security', ['find-generic-password', '-s', 'Supabase CLI', '-w'], { encoding: 'utf8' }).stdout.trim()
    const r = spawnSync('curl', ['-s', '-m', '40', '-A', 'curl/8.4.0', '-H', `Authorization: Bearer ${tok}`,
        'https://api.supabase.com/v1/projects/wvywpohbwkiinmipmuku/health?services=db&services=rest'], { encoding: 'utf8', timeout: 60_000 })
    try { return JSON.parse(r.stdout).map((x) => `${x.name}=${x.status}`) } catch { return ['health=UNREADABLE'] }
}
function abortReason(tag) {
    const sel = selectOne(tag)
    if (sel.max > 1500) console.log(`WARN|${tag}: a single round trip took ${sel.max.toFixed(0)} ms (> 1500 ms; recorded, not an abort)`)
    if (!(sel.exec <= 50)) return `${tag}: select 1 inside the database took ${sel.exec} ms (> 50 ms or unreadable)`
    if (!(sel.med <= 1500)) return `${tag}: median of five round trips ${sel.med?.toFixed(0)} ms (> 1500 ms or unreadable)`
    const h = health()
    console.log(`HEALTH|${tag}: ${h.join(' ')}`)
    if (!h.includes('db=ACTIVE_HEALTHY') || !h.includes('rest=ACTIVE_HEALTHY')) return `${tag}: Management API health ${h.join(' ')}`
    return null
}

async function finish(code) {
    try { if (browser) await browser.close() } catch { /* 不改判决 */ }
    browser = null
    return exitAfterCleanup(code)
}

async function openAs(reader, path) {
    const page = await browser.newPage()
    await page.setViewport({ width: 1440, height: 900 })
    const cdp = await page.createCDPSession()
    const host = new URL(BASE).hostname
    await cdp.send('Network.setCookies', { cookies: [
        { name: reader.cookieName, value: reader.cookieValue, domain: host, path: '/' },
        { name: 'NEXT_LOCALE', value: 'en', domain: host, path: '/' },
    ] })
    const res = await page.goto(BASE + path, { waitUntil: 'networkidle2', timeout: 300_000 })
    // 等水合收尾(AGENTS.md:点之前等 __reactFiber),否则那次点击不被 <Link> 接管
    await page.waitForFunction(() => { const e = document.querySelector('[data-nav="avatar-menu"] button'); return !!e && Object.keys(e).some((k) => k.startsWith('__react')) }, { timeout: 60_000 }).catch(() => {})
    return { page, status: res?.status() }
}

/** 页面上有没有 Next 的错误边界 / 我们自己的错误条 */
const errorProbe = () => {
    const txt = document.body.innerText
    return {
        h1: document.querySelector('h1')?.textContent.trim() ?? null,
        nextError: !!document.querySelector('[data-nextjs-error], #__next-error') || /Application error|Something went wrong|This page couldn.t load/i.test(txt),
        alerts: [...document.querySelectorAll('[role="alert"]')].map((e) => e.textContent.trim()).filter(Boolean),
    }
}

async function main() {
    const other = heldBy()
    if (other) { console.error(`✗ live-lock 被【${other.holder}】(pid ${other.pid})占着`); return exitAfterCleanup(5) }
    acquireOrExit(SCRIPT, { ownExit: false })
    locked = true
    openPlan(SCRIPT)
    await reapStalePlans()

    if (!PUP_DIR || !existsSync(join(PUP_DIR, 'node_modules/puppeteer-core'))) throw new Error('CEC_DRIVER|PUPPETEER_DIR has no node_modules/puppeteer-core')
    const puppeteer = createRequire(join(PUP_DIR, 'package.json'))('puppeteer-core')
    const ver = readdirSync(CHROME_ROOT).sort().pop()
    const exe = join(CHROME_ROOT, ver, 'chrome-headless-shell-mac-arm64', 'chrome-headless-shell')
    if (!existsSync(exe)) throw new Error(`CEC_DRIVER|no chrome-headless-shell at ${exe}`)
    console.log(`STEP|base ${BASE}`)

    { const why = abortReason('before the reader'); if (why) { console.log(`ABORT|${why}`); return finish(1) } }

    browser = await puppeteer.launch({ executablePath: exe, headless: true, args: ['--no-sandbox'] })
    const cfo = await mintThrowaway({ prefix: 'esg2probe', label: 'closeout-cfo', stamp: Date.now(), codes: { cloneOf: 'cfo' } })

    // ① 合同列表
    {
        const t0 = Date.now()
        const { page, status } = await openAs(cfo, '/contracts')
        const ms = Date.now() - t0
        try {
            const s = await page.evaluate(errorProbe)
            ok(status === 200 && !s.nextError, `/contracts (HTTP ${status}, h1 "${s.h1}", ${ms} ms to network idle): error boundary ${s.nextError ? 'SHOWN' : 'none'}; alerts ${s.alerts.length ? s.alerts.join(' | ') : 'none'}`)
        } finally { await page.close() }
    }
    // ② 设置 › 合同签署人(v1.4.85 才有的路由)
    {
        const t0 = Date.now()
        const { page, status } = await openAs(cfo, '/settings/signatories')
        const ms = Date.now() - t0
        try {
            const s = await page.evaluate(errorProbe)
            const main = await page.evaluate(() => (document.querySelector('main')?.innerText ?? document.body.innerText).replace(/\s+/g, ' ').slice(0, 300))
            ok(status === 200 && !s.nextError,
               `/settings/signatories (HTTP ${status}, h1 "${s.h1}", ${ms} ms to network idle): error boundary ${s.nextError ? 'SHOWN' : 'none'}; alerts ${s.alerts.length ? s.alerts.join(' | ') : 'none'}; ${status === 200 ? 'route exists ⇒ production serves 0628769 / f5ffe87 (v1.4.85)' : 'NOT 200 ⇒ NOT v1.4.85'}; main text: "${main}"`)
        } finally { await page.close() }
    }

    { const why = abortReason('after the reader'); if (why) { console.log(`ABORT|${why}`); return finish(1) } }
    console.log(bad ? `STEP|done with ${bad} FAIL` : 'STEP|done')
    return finish(bad ? 1 : 0)
}

main().catch((e) => {
    console.error(String(e?.stack || e))
    return finish(String(e?.message || '').startsWith('CEC_DRIVER') ? 2 : 1)
})
