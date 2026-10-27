#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// SYSTEM-MAP-2 Part 1 · SYSTEM-MAP-1 收尾 —— 对着【生产】(Vercel)只读地看一眼,一个按钮都不按
// ════════════════════════════════════════════════════════════════════════════
// 委托书 1.1 / 1.2:一个一次性 cfo 克隆(cfo 角色的码,不是 cfo 角色本身)在生产上看到:
//   ① 顶栏第一个是 Workbench,一共九个按钮(= 生产跑的是 b89219c / b8a4bea —— v1.4.76 没有这一排);
//   ② 人事 › 报销(/claims)打开、有行(行数与库里的数并排印);
//   ③ 头像菜单里没有 /me、没有 /my-reviews。
//   只点开头像菜单(一个下拉,不是一次写入);别的什么都不按。然后收走账号,读回 0 残留由调用方另读。
// 只读:浏览器只发 GET。线上提交的只有一次性账号与它的角色、授权(前缀 sm1probe —— 沿用 SYSTEM-MAP-1 的前缀,
//      与 TF-3 收尾沿用 tf3probe 同一个先例),由清理计划收走。
// 判决只从最后一行 `SM1_CLOSEOUT_EXIT=` 读:0 = 全 PASS 且收尾干净 · 1 = 有 FAIL · 2 = 驱动坏了 · 5 = live-lock 被占 · 6 = 收尾没完成。
// 用法:PROOF_BASE=https://new-era-erp.vercel.app PUPPETEER_DIR=<装着 puppeteer-core 的目录> node db/scripts/2026-10-27-system-map-1-closeout-prod-check.mjs
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
const SCRIPT = 'db/scripts/2026-10-27-system-map-1-closeout-prod-check.mjs'
const WANT_BAR = ['Workbench', 'Purchasing', 'Production', 'Quality', 'Sales', 'Finance', 'People', 'Safety', 'Equipment']

let locked = false, bad = 0, browser = null
const ok = (cond, what) => { console.log(`${cond ? 'PASS' : 'FAIL'}|${what}`); if (!cond) bad++; return cond }

installExitHooks({
    onFinish: (code) => {
        try { if (locked) release() } catch { /* 放锁失败不改判决 */ }
        console.log(`SM1_CLOSEOUT_EXIT=${code}`)
    },
})

function psql(sql) {
    const r = spawnSync('psql', [DSN, '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-f', '-'], { input: sql, encoding: 'utf8', timeout: 120_000 })
    if (r.status !== 0) throw new Error(`SM1C_DRIVER|psql exit ${r.status}: ${(r.stderr ?? '').split('\n').slice(-4).join(' / ')}`)
    return (r.stdout ?? '').split('\n').filter((l) => l.startsWith('PROOF|')).map((l) => l.slice(6))
}

async function finish(code) {
    try { if (browser) await browser.close() } catch { /* 不改判决 */ }
    browser = null
    return exitAfterCleanup(code)
}

const hydrated = (sel) => `(() => { const e = document.querySelector(${JSON.stringify(sel)}); return !!e && Object.keys(e).some((k) => k.startsWith('__react')) })()`

async function openAs(reader, path) {
    const page = await browser.newPage()
    await page.setViewport({ width: 1440, height: 900 })
    const cdp = await page.createCDPSession()
    const host = new URL(BASE).hostname
    await cdp.send('Network.setCookies', { cookies: [
        { name: reader.cookieName, value: reader.cookieValue, domain: host, path: '/' },
        { name: 'NEXT_LOCALE', value: 'en', domain: host, path: '/' },
    ] })
    const res = await page.goto(BASE + path, { waitUntil: 'networkidle2', timeout: 120_000 })
    await page.waitForFunction(hydrated('[data-nav="avatar-menu"] button'), { timeout: 60_000 }).catch(() => {})
    return { page, status: res?.status() }
}

async function main() {
    const other = heldBy()
    if (other) { console.error(`✗ live-lock 被【${other.holder}】(pid ${other.pid})占着`); return exitAfterCleanup(5) }
    acquireOrExit(SCRIPT, { ownExit: false })
    locked = true
    openPlan(SCRIPT)
    await reapStalePlans()

    if (!PUP_DIR || !existsSync(join(PUP_DIR, 'node_modules/puppeteer-core'))) throw new Error('SM1C_DRIVER|PUPPETEER_DIR has no node_modules/puppeteer-core')
    const puppeteer = createRequire(join(PUP_DIR, 'package.json'))('puppeteer-core')
    const ver = readdirSync(CHROME_ROOT).sort().pop()
    const exe = join(CHROME_ROOT, ver, 'chrome-headless-shell-mac-arm64', 'chrome-headless-shell')
    if (!existsSync(exe)) throw new Error(`SM1C_DRIVER|no chrome-headless-shell at ${exe}`)
    browser = await puppeteer.launch({ executablePath: exe, headless: true, args: ['--no-sandbox'] })
    console.log(`STEP|base ${BASE}`)

    // ── 库里的数(以 postgres 读基表;rolbypassrls,RLS 不参与)──────
    const kv = Object.fromEntries(psql(`
        SELECT 'PROOF|medical=' || (SELECT count(*) FROM medical_claims WHERE deleted_at IS NULL);
        SELECT 'PROOF|general=' || (SELECT count(*) FROM expense_claims);
    `).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1)]))
    const claims = Number(kv.medical) + Number(kv.general)
    console.log(`STEP|database as postgres (base tables): medical claims ${kv.medical} · general claims ${kv.general}`)

    const cfo = await mintThrowaway({ prefix: 'sm1probe', label: 'closeout-cfo', stamp: Date.now(), codes: { cloneOf: 'cfo' } })

    // ① 顶栏 + ③ 头像菜单(在首页读;只点开头像下拉)
    {
        const { page, status } = await openAs(cfo, '/')
        try {
            const bar = await page.$$eval('[data-nav="modules"] > div > button', (bs) => bs.map((b) => b.textContent.trim()))
            ok(status === 200 && bar.length === 9 && bar[0] === 'Workbench' && JSON.stringify(bar) === JSON.stringify(WANT_BAR),
               `/ → HTTP ${status}: bar has ${bar.length} buttons = ${bar.join(' · ')} (Workbench first)`)
            await page.click('[data-nav="avatar-menu"] > button')
            await page.waitForSelector('[data-nav="avatar-menu"] [role="menu"]', { timeout: 10_000 })
            const avatar = await page.$$eval('[data-nav="avatar-menu"] [role="menu"] [data-menu-row]', (rs) => rs.map((r) => r.getAttribute('href') ?? r.getAttribute('data-nav') ?? r.textContent.trim().slice(0, 30)))
            const hrefs = await page.$$eval('[data-nav="avatar-menu"] [role="menu"] a[href]', (as) => as.map((a) => a.getAttribute('href')))
            ok(!hrefs.includes('/me') && !hrefs.includes('/my-reviews') && !avatar.includes('/me') && !avatar.includes('/my-reviews'),
               `avatar menu rows = ${avatar.join(' · ')} — no /me, no /my-reviews (links: ${hrefs.join(', ')})`)
            await page.keyboard.press('Escape')
        } finally { await page.close() }
    }

    // ② 人事 › 报销 → /claims 有行
    {
        const { page, status } = await openAs(cfo, '/claims')
        try {
            const s = await page.evaluate(() => {
                const t = document.querySelector('table[data-slot="data-table"]')
                const rows = t ? [...t.querySelectorAll(':scope > tbody > tr')].filter((tr) => tr.querySelectorAll('td').length > 1) : []
                return { table: !!t, rows: rows.length, url: location.pathname }
            })
            // 菜单里人事那一格确实指向 /claims(读注册表画出来的那一行,不点)
            ok(status === 200 && s.url === '/claims' && s.table && s.rows > 0 && s.rows === claims,
               `/claims → HTTP ${status}: table ${s.table}, ${s.rows} rows (database ${claims}); no redirect (${s.url})`)
        } finally { await page.close() }
        const { page: p2 } = await openAs(cfo, '/')
        try {
            const btns = await p2.$$('[data-nav="modules"] > div > button')
            const labels = await Promise.all(btns.map((b) => b.evaluate((x) => x.textContent.trim())))
            const i = labels.indexOf('People')
            let rows = []
            if (i >= 0) {
                await btns[i].click()
                await p2.waitForSelector('[data-nav="modules"] [role="menu"]', { timeout: 10_000 })
                rows = await p2.$$eval('[data-nav="modules"] [role="menu"] [data-menu-href]', (rs) => rs.map((r) => ({ href: r.getAttribute('data-menu-href'), text: r.textContent.trim(), restricted: r.hasAttribute('data-module-restricted') })))
            }
            const claimRow = rows.find((r) => r.href === '/claims')
            ok(!!claimRow && !claimRow.restricted, `People menu has Claims → /claims (${claimRow ? JSON.stringify(claimRow.text) : 'missing'}), not restricted; menu opened, nothing pressed`)
        } finally { await p2.close() }
    }

    console.log(bad ? `STEP|done with ${bad} FAIL` : 'STEP|done')
    return finish(bad ? 1 : 0)
}

main().catch((e) => {
    console.error(String(e?.stack || e))
    return finish(String(e?.message || '').startsWith('SM1C_DRIVER') ? 2 : 1)
})
