#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// TABLE-EXPORT-2b-2 Part 1.3 · TABLE-EXPORT-2b-1 收尾 —— 对着【生产】(Vercel)只读地看一眼
// ════════════════════════════════════════════════════════════════════════════
// 委托书 1.3:一个没有 data.view_purchase_prices 的一次性账号打开 /tools/pricing/formulas,
//            处理费与折扣两格读「受限」/"Restricted";一个一次性员工打开 /me,它的导出答 HTTP 200。
//            然后收走账号,读回 0 残留。
// 只读:浏览器只发 GET;导出那一臂是一次 GET 导出路由。线上提交的只有一次性账号、它们的授权与一个一次性员工
//      (前缀 te2b1probe —— 这是 2b-1 的收尾,沿用 2b-1 的前缀,共用造号器),由清理计划收走。
// 判决只从最后一行 `TE2B1_CLOSEOUT_EXIT=` 读:0 = 全 PASS 且收尾干净 · 1 = 有 FAIL · 2 = 驱动坏了 · 5 = live-lock 被占 · 6 = 收尾没完成。
// 用法:PROOF_BASE=https://new-era-erp.vercel.app PUPPETEER_DIR=<装着 puppeteer-core 的目录> node db/scripts/2026-10-23-table-export-2b1-closeout-prod-check.mjs
// ════════════════════════════════════════════════════════════════════════════
import { readdirSync, existsSync } from 'node:fs'
import { join } from 'node:path'
import { homedir } from 'node:os'
import { createRequire } from 'node:module'
import { onlyWhenRunDirectly } from '../../scripts/lib/entrypoint.mjs'
import { acquireOrExit, release, heldBy } from '../../scripts/liveLock.mjs'
import { openPlan, mintThrowaway, reapStalePlans, installExitHooks, exitAfterCleanup } from '../../scripts/ephemeral.mjs'

onlyWhenRunDirectly(import.meta.url)

const BASE = process.env.PROOF_BASE || 'https://new-era-erp.vercel.app'
const PUP_DIR = process.env.PUPPETEER_DIR
const CHROME_ROOT = join(homedir(), '.cache/puppeteer/chrome-headless-shell')
const SCRIPT = 'db/scripts/2026-10-23-table-export-2b1-closeout-prod-check.mjs'

let locked = false, bad = 0, browser = null
const ok = (cond, what) => { console.log(`${cond ? 'PASS' : 'FAIL'}|${what}`); if (!cond) bad++; return cond }

installExitHooks({
    onFinish: (code) => {
        try { if (locked) release() } catch { /* 放锁失败不改判决 */ }
        console.log(`TE2B1_CLOSEOUT_EXIT=${code}`)
    },
})

async function openAs(reader, path) {
    const page = await browser.newPage()
    const cdp = await page.createCDPSession()
    const host = new URL(BASE).hostname
    await cdp.send('Network.setCookies', { cookies: [
        { name: reader.cookieName, value: reader.cookieValue, domain: host, path: '/' },
        { name: 'NEXT_LOCALE', value: 'en', domain: host, path: '/' },
    ] })
    const res = await page.goto(BASE + path, { waitUntil: 'networkidle2', timeout: 120_000 })
    return { page, status: res?.status() }
}

async function finish(code) {
    try { if (browser) await browser.close() } catch { /* 不改判决 */ }
    browser = null
    return exitAfterCleanup(code)
}

async function main() {
    const other = heldBy()
    if (other) { console.error(`✗ live-lock 被【${other.holder}】(pid ${other.pid})占着`); return exitAfterCleanup(5) }
    acquireOrExit(SCRIPT, { ownExit: false })
    locked = true
    openPlan(SCRIPT)
    await reapStalePlans()

    if (!PUP_DIR || !existsSync(join(PUP_DIR, 'node_modules/puppeteer-core'))) throw new Error('TE2B1C_DRIVER|PUPPETEER_DIR has no node_modules/puppeteer-core')
    const puppeteer = createRequire(join(PUP_DIR, 'package.json'))('puppeteer-core')
    const ver = readdirSync(CHROME_ROOT).sort().pop()
    const exe = join(CHROME_ROOT, ver, 'chrome-headless-shell-mac-arm64', 'chrome-headless-shell')
    if (!existsSync(exe)) throw new Error(`TE2B1C_DRIVER|no chrome-headless-shell at ${exe}`)
    browser = await puppeteer.launch({ executablePath: exe, headless: true, args: ['--no-sandbox'] })
    console.log(`STEP|base ${BASE}`)

    const stamp = Date.now()
    // 与 2b-1 证明里的 blind 臂同一组码:进得了定价模块、看得见一般价格,唯独没有 data.view_purchase_prices
    const blind = await mintThrowaway({ prefix: 'te2b1probe', label: 'closeout-blind', stamp,
        codes: ['module.pricing.view', 'data.view_prices'] })

    // ① /tools/pricing/formulas:按表头找处理费与折扣两列,逐行读;至少要有一行,并且【每一行】两格都是 Restricted
    {
        const { page, status } = await openAs(blind, '/tools/pricing/formulas')
        try {
            const t = await page.evaluate(() => {
                const table = document.querySelector('table')
                if (!table) return null
                const heads = [...table.querySelectorAll('thead th')].map((th) => th.textContent?.trim() ?? '')
                const ti = heads.findIndex((h) => /^Treatment/i.test(h)), di = heads.findIndex((h) => /^Discount/i.test(h))
                const rows = [...table.querySelectorAll('tbody tr')].map((tr) => [...tr.querySelectorAll('td')].map((td) => td.textContent?.trim() ?? ''))
                    .filter((cells) => cells.length === heads.length)
                return { heads, ti, di, cells: rows.map((c) => [c[0], c[ti], c[di]]) }
            })
            ok(status === 200 && !!t && t.ti >= 0 && t.di >= 0 && t.cells.length > 0,
               `/tools/pricing/formulas → HTTP ${status}; headers ${JSON.stringify(t?.heads)}; ${t?.cells.length ?? 0} formula rows`)
            if (t?.cells.length) for (const [code, tc, dc] of t.cells)
                ok(tc === 'Restricted' && dc === 'Restricted', `reader without data.view_purchase_prices · ${code}: treatment ${JSON.stringify(tc)} · discount ${JSON.stringify(dc)}`)
        } finally { await page.close() }
    }

    // ② 一次性员工:打开 /me,再按它的导出路由(请假那一张)
    const owner = await mintThrowaway({ prefix: 'te2b1probe', label: 'closeout-me', stamp, codes: ['module.tasks.view'],
        employee: { legal_name: 'TE2B1 Closeout', first_name: 'TE2B1', employment_type: 'full_time', work_category: 'office', hire_date: '2026-01-05' } })
    {
        const { page, status } = await openAs(owner, '/me')
        try {
            const n = await page.evaluate(() => document.querySelectorAll('[data-slot="table-export"]').length)
            ok(status === 200 && n > 0, `/me → HTTP ${status}; ${n} export bars on the page`)
        } finally { await page.close() }
        for (const route of ['/me/leave-requests/export', '/me/medical-claims/export', '/me/expense-claims/export']) {
            const r = await fetch(BASE + route, { headers: { cookie: owner.cookie } })
            let rows = '?'
            try { const j = await r.json(); rows = Array.isArray(j.rows) ? j.rows.length : '?' } catch { /* 非 JSON 就是失败 */ }
            ok(r.status === 200 && rows !== '?', `throwaway employee · ${route} → HTTP ${r.status}, ${rows} rows`)
        }
    }

    console.log(bad ? `STEP|done with ${bad} FAIL` : 'STEP|done')
    return finish(bad ? 1 : 0)
}

main().catch((e) => {
    console.error(String(e?.stack || e))
    return finish(String(e?.message || '').startsWith('TE2B1C_DRIVER') ? 2 : 1)
})
