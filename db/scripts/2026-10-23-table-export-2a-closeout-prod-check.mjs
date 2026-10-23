#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// TABLE-EXPORT-2b Part 1.2 · TABLE-EXPORT-2a 收尾 —— 对着【生产】(Vercel)只读地看一眼
// ════════════════════════════════════════════════════════════════════════════
// 委托书 1.2:一个一次性财务账号把发票列表导出成 .xlsx 与 .csv(HTTP 200,行数 = 列表上的「Total」),
//            再打开 /finance/payroll-payments,不报错。然后收走账号,读回 0 残留。
// 只读:浏览器只发 GET 与点「导出」;线上提交的只有一次性账号与它的授权(前缀 te2probe,共用造号器),由清理计划收走。
// 判决只从最后一行 `TE2A_CLOSEOUT_EXIT=` 读:0 = 全 PASS 且收尾干净 · 1 = 有 FAIL · 2 = 驱动坏了 · 5 = live-lock 被占 · 6 = 收尾没完成。
// 用法:PROOF_BASE=https://new-era-erp.vercel.app PUPPETEER_DIR=<装着 puppeteer-core 的目录> node db/scripts/2026-10-23-table-export-2a-closeout-prod-check.mjs
// ════════════════════════════════════════════════════════════════════════════
import { mkdtempSync, readdirSync, readFileSync, existsSync } from 'node:fs'
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

let locked = false, bad = 0, browser = null
const ok = (cond, what) => { console.log(`${cond ? 'PASS' : 'FAIL'}|${what}`); if (!cond) bad++; return cond }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

installExitHooks({
    onFinish: (code) => {
        try { if (locked) release() } catch { /* 放锁失败不改判决 */ }
        console.log(`TE2A_CLOSEOUT_EXIT=${code}`)
    },
})

function csvRows(text) {
    const rows = []; let row = [], cell = '', q = false
    const s = text.replace(/^﻿/, '')
    for (let i = 0; i < s.length; i++) {
        const c = s[i]
        if (q) { if (c === '"' && s[i + 1] === '"') { cell += '"'; i++ } else if (c === '"') q = false; else cell += c }
        else if (c === '"') q = true
        else if (c === ',') { row.push(cell); cell = '' }
        else if (c === '\r') { /* CRLF */ }
        else if (c === '\n') { row.push(cell); rows.push(row); row = []; cell = '' }
        else cell += c
    }
    if (cell !== '' || row.length) { row.push(cell); rows.push(row) }
    return rows.slice(1).filter((r) => r.length > 1 || r[0] !== '')
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

async function exportInvoices(reader, fmt) {
    const dir = mkdtempSync(join(tmpdir(), `te2a-closeout-${fmt}-`))
    const { page, cdp, status } = await openAs(reader, '/finance/invoices')
    try {
        if (status !== 200) return { err: `HTTP ${status}` }
        const listTotal = await page.evaluate(() => {
            const p = [...document.querySelectorAll('p')].find((x) => /^Total: \d+$/.test(x.textContent?.trim() ?? ''))
            return p ? Number(p.textContent.trim().slice(7)) : null
        })
        await cdp.send('Browser.setDownloadBehavior', { behavior: 'allow', downloadPath: dir })
        await page.waitForFunction(() => {
            const b = document.querySelector('[data-slot="table-export"] button')
            return !!b && Object.keys(b).some((k) => k.startsWith('__react'))
        }, { timeout: 60_000 })
        const label = fmt === 'csv' ? 'Export CSV' : 'Export Excel'
        const clicked = await page.evaluate((label) => {
            const b = [...document.querySelectorAll('[data-slot="table-export"] button')].find((x) => x.textContent?.trim() === label)
            if (!b) return false
            b.click(); return true
        }, label)
        if (!clicked) return { err: `no "${label}" button` }
        const file = await waitForFile(dir, new RegExp(`^invoices_\\d{4}-\\d{2}-\\d{2}_\\d{4}\\.${fmt}$`), 90_000)
        if (!file) return { err: `no ${fmt} file within 90 s` }
        return { status, listTotal, file, path: join(dir, file) }
    } finally {
        await page.close()
    }
}

async function finish(code) {
    try { if (browser) await browser.close() } catch { /* 不改判决 */ }
    browser = null
    return exitAfterCleanup(code)
}

async function main() {
    const other = heldBy()
    if (other) { console.error(`✗ live-lock 被【${other.holder}】(pid ${other.pid})占着`); return exitAfterCleanup(5) }
    acquireOrExit('db/scripts/2026-10-23-table-export-2a-closeout-prod-check.mjs', { ownExit: false })
    locked = true
    openPlan('db/scripts/2026-10-23-table-export-2a-closeout-prod-check.mjs')
    await reapStalePlans()

    if (!PUP_DIR || !existsSync(join(PUP_DIR, 'node_modules/puppeteer-core'))) throw new Error('TE2A_DRIVER|PUPPETEER_DIR has no node_modules/puppeteer-core')
    const puppeteer = createRequire(join(PUP_DIR, 'package.json'))('puppeteer-core')
    const ver = readdirSync(CHROME_ROOT).sort().pop()
    const exe = join(CHROME_ROOT, ver, 'chrome-headless-shell-mac-arm64', 'chrome-headless-shell')
    if (!existsSync(exe)) throw new Error(`TE2A_DRIVER|no chrome-headless-shell at ${exe}`)
    browser = await puppeteer.launch({ executablePath: exe, headless: true, args: ['--no-sandbox'] })
    console.log(`STEP|base ${BASE}`)

    const fin = await mintThrowaway({ prefix: 'te2probe', label: 'closeout', codes: { cloneOf: 'finance' } })
    console.log(`STEP|throwaway reader holds a copy of the finance role's ${fin.codes.length} codes`)

    const csv = await exportInvoices(fin, 'csv')
    if (ok(!csv.err, `/finance/invoices → HTTP ${csv.status ?? '?'}, CSV downloaded${csv.err ? ` — ${csv.err}` : `: ${csv.file}`}`)) {
        const n = csvRows(readFileSync(csv.path, 'utf8')).length
        ok(csv.listTotal !== null && n === csv.listTotal, `CSV data rows ${n} = the list's "Total: ${csv.listTotal}"`)
    }
    const xl = await exportInvoices(fin, 'xlsx')
    if (ok(!xl.err, `/finance/invoices → HTTP ${xl.status ?? '?'}, Excel downloaded${xl.err ? ` — ${xl.err}` : `: ${xl.file}`}`)) {
        const wb = new ExcelJS.Workbook()
        await wb.xlsx.readFile(xl.path)
        const n = wb.worksheets[0].actualRowCount - 1
        ok(xl.listTotal !== null && n === xl.listTotal, `Excel data rows ${n} = the list's "Total: ${xl.listTotal}"`)
    }

    const { page, status } = await openAs(fin, '/finance/payroll-payments')
    try {
        const text = await page.evaluate(() => document.body.innerText)
        ok(status === 200 && !/Application error|Something went wrong|Unhandled Runtime Error/i.test(text),
           `/finance/payroll-payments → HTTP ${status}, no error boundary on the page`)
    } finally { await page.close() }

    console.log(bad ? `STEP|done with ${bad} FAIL` : 'STEP|done')
    return finish(bad ? 1 : 0)
}

main().catch((e) => {
    console.error(String(e?.stack || e))
    return finish(String(e?.message || '').startsWith('TE2A_DRIVER') ? 2 : 1)
})
