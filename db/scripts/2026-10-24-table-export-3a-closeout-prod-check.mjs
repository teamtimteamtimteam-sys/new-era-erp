#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// TABLE-EXPORT-3b Part 1.2 · TABLE-EXPORT-3a 收尾 —— 对着【生产】(Vercel)只读地看一眼
// ════════════════════════════════════════════════════════════════════════════
// 委托书 1.2:一个一次性财务账号把损益表导出成 Excel(页面 HTTP 200,文件里的净利润 = 屏幕上的净利润);
//            一个不持付薪码的读者在 /finance/payroll-payments 上看见「受限」。然后收走账号,读回 0 残留。
//            P&L 的 Excel 钮在生产上存在 = 生产跑的是 f5f6054(3a)。
// 只读:浏览器只发 GET 与点「导出」(文件在浏览器里生成,不写库)。
//      线上提交的只有一次性账号与它们的授权(前缀 te3aprobe —— 这是 3a 的收尾,沿用 3a 的前缀,共用造号器),由清理计划收走。
// 判决只从最后一行 `TE3A_CLOSEOUT_EXIT=` 读:0 = 全 PASS 且收尾干净 · 1 = 有 FAIL · 2 = 驱动坏了 · 5 = live-lock 被占 · 6 = 收尾没完成。
// 用法:PROOF_BASE=https://new-era-erp.vercel.app PUPPETEER_DIR=<装着 puppeteer-core 的目录> node db/scripts/2026-10-24-table-export-3a-closeout-prod-check.mjs
// ════════════════════════════════════════════════════════════════════════════
import { mkdtempSync, readdirSync, existsSync } from 'node:fs'
import { join } from 'node:path'
import { tmpdir, homedir } from 'node:os'
import { createRequire } from 'node:module'
import ExcelJS from 'exceljs'
import { onlyWhenRunDirectly } from '../../scripts/lib/entrypoint.mjs'
import { acquireOrExit, release, heldBy } from '../../scripts/liveLock.mjs'
import { openPlan, mintThrowaway, reapStalePlans, installExitHooks, exitAfterCleanup } from '../../scripts/ephemeral.mjs'

onlyWhenRunDirectly(import.meta.url)

const BASE = process.env.PROOF_BASE || 'https://new-era-erp.vercel.app'
const PUP_DIR = process.env.PUPPETEER_DIR
const CHROME_ROOT = join(homedir(), '.cache/puppeteer/chrome-headless-shell')
const SCRIPT = 'db/scripts/2026-10-24-table-export-3a-closeout-prod-check.mjs'
// 与 3a 的线上证明同一个期间(覆盖线上全部分录)
const PNL_FROM = '2026-01-01', PNL_TO = '2027-12-31'

let locked = false, bad = 0, browser = null
const ok = (cond, what) => { console.log(`${cond ? 'PASS' : 'FAIL'}|${what}`); if (!cond) bad++; return cond }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const num = (s) => (s === null || s === undefined ? null : Number(String(s).replace(/[^0-9.-]/g, '')))

installExitHooks({
    onFinish: (code) => {
        try { if (locked) release() } catch { /* 放锁失败不改判决 */ }
        console.log(`TE3A_CLOSEOUT_EXIT=${code}`)
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
    return { page, cdp, status: res?.status() }
}

async function waitForFile(dir, re, timeoutMs) {
    const t0 = Date.now()
    while (Date.now() - t0 < timeoutMs) {
        const f = readdirSync(dir).find((n) => re.test(n))
        if (f) { await sleep(300); return f }
        await sleep(250)
    }
    return null
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

    if (!PUP_DIR || !existsSync(join(PUP_DIR, 'node_modules/puppeteer-core'))) throw new Error('TE3AC_DRIVER|PUPPETEER_DIR has no node_modules/puppeteer-core')
    const puppeteer = createRequire(join(PUP_DIR, 'package.json'))('puppeteer-core')
    const ver = readdirSync(CHROME_ROOT).sort().pop()
    const exe = join(CHROME_ROOT, ver, 'chrome-headless-shell-mac-arm64', 'chrome-headless-shell')
    if (!existsSync(exe)) throw new Error(`TE3AC_DRIVER|no chrome-headless-shell at ${exe}`)
    browser = await puppeteer.launch({ executablePath: exe, headless: true, args: ['--no-sandbox'] })
    console.log(`STEP|base ${BASE}`)

    const stamp = Date.now()
    // 与 3a 证明同一组码
    const fin = await mintThrowaway({ prefix: 'te3aprobe', label: 'closeout-fin', stamp, codes: ['module.finance.view', 'data.view_pay', 'data.view_prices'] })
    // 看得到付薪行、看不到钱:hr.view + finance.view,不持 data.view_pay(payroll_lines_masked.sql:38)
    const payBlind = await mintThrowaway({ prefix: 'te3aprobe', label: 'closeout-payblind', stamp, codes: ['module.finance.view', 'module.hr.view'] })

    // ① 损益表 Excel:净利润 = 屏幕
    {
        const path = `/finance/pnl?date_from=${PNL_FROM}&date_to=${PNL_TO}`
        const { page, cdp, status } = await openAs(fin, path)
        try {
            const screenNet = await page.evaluate(() => {
                for (const tr of document.querySelectorAll('table tr')) {
                    const tds = [...tr.querySelectorAll('td')]
                    if (tds.length && (tds[0].textContent ?? '').replace(/\s+/g, ' ').trim().startsWith('Net Profit')) return tds[tds.length - 1].textContent?.trim() ?? null
                }
                return null
            })
            ok(status === 200 && !!screenNet, `${path} → HTTP ${status}; screen net profit ${screenNet}`)
            const dir = mkdtempSync(join(tmpdir(), 'te3ac-pnl-'))
            await cdp.send('Browser.setDownloadBehavior', { behavior: 'allow', downloadPath: dir })
            const hydrated = await page.waitForFunction(() => {
                const b = document.querySelector('[data-slot="table-export"] button')
                return !!b && Object.keys(b).some((k) => k.startsWith('__react'))
            }, { timeout: 60_000 }).then(() => true, () => false)
            ok(hydrated, 'the P&L export bar is on the production page (= 3a is deployed)')
            if (hydrated) {
                await page.evaluate(() => {
                    const b = [...document.querySelectorAll('[data-slot="table-export"] button')].find((x) => x.textContent?.trim() === 'Export Excel')
                    b?.click()
                })
                const file = await waitForFile(dir, /^finance-profit-and-loss_\d{4}-\d{2}-\d{2}_\d{4}\.xlsx$/, 90_000)
                if (ok(!!file, `P&L Excel downloaded${file ? `: ${file}` : ' — no file'}`)) {
                    const wb = new ExcelJS.Workbook()
                    await wb.xlsx.readFile(join(dir, file))
                    let net = null
                    wb.worksheets[0].eachRow((row) => {
                        const vals = row.values.slice(1).map((v) => (v && typeof v === 'object' && 'result' in v ? v.result : v))
                        if (vals[0] === 'Net Profit') net = vals[2]
                    })
                    ok(typeof net === 'number' && net === num(screenNet), `Excel net profit ${net} (${typeof net}) = screen ${screenNet}`)
                }
            }
        } finally { await page.close() }
    }

    // ② 不持付薪码的读者在 /finance/payroll-payments 上读到「受限」
    {
        const path = '/finance/payroll-payments'
        const { page, status } = await openAs(payBlind, path)
        try {
            const s = await page.evaluate(() => {
                const t = [...document.querySelectorAll('section table')][0]
                if (!t) return null
                const hs = [...t.querySelectorAll('thead th')].map((th) => th.textContent?.trim() ?? '')
                const ai = hs.findIndex((h) => h === 'Net pay')
                const rows = [...t.querySelectorAll('tbody tr')].map((tr) => [...tr.querySelectorAll('td')].map((td) => td.textContent?.trim() ?? ''))
                return { n: rows.length, amounts: rows.map((r) => r[ai]) }
            })
            ok(status === 200 && s && s.n > 0 && s.amounts.every((a) => a === 'Restricted'),
               `${path} as a reader without data.view_pay → HTTP ${status}; ${s?.n} lines, net pay ${JSON.stringify(s?.amounts)}`)
        } finally { await page.close() }
    }

    console.log(bad ? `STEP|done with ${bad} FAIL` : 'STEP|done')
    return finish(bad ? 1 : 0)
}

main().catch((e) => {
    console.error(String(e?.stack || e))
    return finish(String(e?.message || '').startsWith('TE3AC_DRIVER') ? 2 : 1)
})
