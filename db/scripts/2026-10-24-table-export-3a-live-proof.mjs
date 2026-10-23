#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// TABLE-EXPORT-3a(Tim 2026-10-23)· 线上证明 —— 真浏览器读屏幕、按下「导出」读回文件;读库的那几句一律在回滚的事务里
// ════════════════════════════════════════════════════════════════════════════
// 委托书(TABLE-EXPORT-3 的裁定,Step 1 的线上证明):
//   F  损益表与资产负债表导出,文件里的合计与屏幕上的合计逐个相等;Excel 的版式(抬头 / 小计 / 合计加粗、明细缩一级)读回来;
//      CSV 第一列是行的种类(Q2)。
//   V  一张过账预览(折旧)导出,About 表写着「Preview as at <日期>, not posted」(Q5),合计行与屏幕相等。
//   P  付薪面板导出:每一行都在(不论勾选,Q4);【受限那一族之一】一个看得到行、不持 data.view_pay 的读者(hr.view + finance.view)在屏幕与文件里都读到 "Restricted"。
//   C  加工费结算面板:【受限那一族之二】不持 data.view_prices 的财务读者,屏幕与文件都读到 "Restricted"。
//   ✗  变更历史导出(Q7)【没有做】—— 读法实测太慢,按 Q7 停下;本脚本不证它。
// 只读:浏览器只发 GET 与点「导出」;线上提交的只有一次性账号与它们的授权(前缀 te3aprobe,共用造号器),由清理计划收走。
// 判决只从最后一行 `TE3A_PROOF_EXIT=` 读:0 = 全 PASS 且收尾干净 · 1 = 有 FAIL · 2 = 驱动坏了 · 5 = live-lock 被占 · 6 = 收尾没完成。
// 用法:PROOF_BASE=http://localhost:3197 PUPPETEER_DIR=<装着 puppeteer-core 的目录> node db/scripts/2026-10-24-table-export-3a-live-proof.mjs
// ════════════════════════════════════════════════════════════════════════════
import { mkdtempSync, readdirSync, readFileSync, existsSync } from 'node:fs'
import { join } from 'node:path'
import { tmpdir, homedir } from 'node:os'
import { createRequire } from 'node:module'
import { spawnSync } from 'node:child_process'
import ExcelJS from 'exceljs'
import { onlyWhenRunDirectly } from '../../scripts/lib/entrypoint.mjs'
import { acquireOrExit, release, heldBy } from '../../scripts/liveLock.mjs'
import { openPlan, mintThrowaway, reapStalePlans, installExitHooks, exitAfterCleanup } from '../../scripts/ephemeral.mjs'

onlyWhenRunDirectly(import.meta.url)

const BASE = process.env.PROOF_BASE || 'http://localhost:3197'
const PUP_DIR = process.env.PUPPETEER_DIR
const CHROME_ROOT = join(homedir(), '.cache/puppeteer/chrome-headless-shell')
const DSN = process.env.CHECK_MIRRORS_DSN || 'host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 user=postgres.wvywpohbwkiinmipmuku dbname=postgres'
const SCRIPT = 'db/scripts/2026-10-24-table-export-3a-live-proof.mjs'
// 期间:覆盖线上全部分录(2026-07-06 → 2027-09-05,以 postgres 读基表)—— 让每一节都有数
const PNL_FROM = '2026-01-01', PNL_TO = '2027-12-31', BS_AS_OF = '2027-12-31', DEP_DATE = '2027-12-31'

let locked = false, bad = 0, browser = null
const ok = (cond, what) => { console.log(`${cond ? 'PASS' : 'FAIL'}|${what}`); if (!cond) bad++; return cond }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const num = (s) => (s === null || s === undefined ? null : Number(String(s).replace(/[^0-9.-]/g, '')))

installExitHooks({
    onFinish: (code) => {
        try { if (locked) release() } catch { /* 放锁失败不改判决 */ }
        console.log('AFTER|nothing but the throwaway accounts and their grants was committed (removed by the plan); every database read as a throwaway ran in a transaction that was rolled back')
        console.log(`TE3A_PROOF_EXIT=${code}`)
    },
})

function parseCsv(text) {
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
    return rows
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

async function openAs(reader, path, { waitUntil = 'networkidle2', timeout = 120_000 } = {}) {
    const page = await browser.newPage()
    const cdp = await page.createCDPSession()
    const host = new URL(BASE).hostname
    await cdp.send('Network.setCookies', { cookies: [
        { name: reader.cookieName, value: reader.cookieValue, domain: host, path: '/' },
        { name: 'NEXT_LOCALE', value: 'en', domain: host, path: '/' },
    ] })
    const res = await page.goto(BASE + path, { waitUntil, timeout })
    return { page, cdp, status: res?.status() }
}

/** 在 `path` 上按出文件名前缀为 `fileName` 的那一对钮里的一颗;一页上几对钮时每一颗都试,直到那个名字的文件落下来。 */
async function exportOnce(reader, path, fileName, fmt) {
    const dir = mkdtempSync(join(tmpdir(), `te3a-${fileName}-${fmt}-`))
    const { page, cdp, status } = await openAs(reader, path)
    try {
        if (status !== 200) return { err: `HTTP ${status}` }
        await cdp.send('Browser.setDownloadBehavior', { behavior: 'allow', downloadPath: dir })
        await page.waitForFunction(() => {
            const b = document.querySelector('[data-slot="table-export"] button')
            return !!b && Object.keys(b).some((k) => k.startsWith('__react'))
        }, { timeout: 60_000 })
        const label = fmt === 'csv' ? 'Export CSV' : 'Export Excel'
        const n = await page.evaluate(() => document.querySelectorAll('[data-slot="table-export"]').length)
        const re = new RegExp(`^${fileName}_\\d{4}-\\d{2}-\\d{2}_\\d{4}\\.${fmt}$`)
        for (let i = 0; i < n; i++) {
            await page.evaluate((label, i) => {
                const bar = document.querySelectorAll('[data-slot="table-export"]')[i]
                const b = [...bar.querySelectorAll('button')].find((x) => x.textContent?.trim() === label)
                b?.click()
            }, label, i)
            const file = await waitForFile(dir, re, i === n - 1 ? 90_000 : 8_000)
            if (file) return { file, path: join(dir, file) }
        }
        const alert = await page.evaluate(() => [...document.querySelectorAll('[data-slot="table-export"] [role="alert"]')].map((x) => x.textContent).join(' | '))
        return { err: `no ${fmt} file matching ${re}${alert ? ` — on screen: ${alert}` : ''}` }
    } finally {
        await page.close()
    }
}

/** 一本 xlsx:第一张工作表的每一行(值 + 是否加粗 + 第一格缩进)与 About 表。 */
async function readXlsx(path) {
    const wb = new ExcelJS.Workbook()
    await wb.xlsx.readFile(path)
    const ws = wb.worksheets[0]
    const rows = []
    ws.eachRow((row, n) => {
        const vals = row.values.slice(1).map((v) => (v && typeof v === 'object' && 'result' in v ? v.result : v))
        rows.push({ n, vals, bold: !!row.font?.bold, indent: row.getCell(1).alignment?.indent ?? 0, fmt: row.getCell(vals.length).numFmt })
    })
    const about = {}
    wb.getWorksheet('About')?.eachRow((r) => { about[String(r.getCell(1).value)] = String(r.getCell(2).value) })
    return { sheets: wb.worksheets.map((w) => w.name), rows, about }
}

function csvRows(path) {
    return parseCsv(readFileSync(path, 'utf8')).filter((r) => r.length > 1 || r[0] !== '')
}

function psql(sql) {
    const r = spawnSync('psql', [DSN, '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-f', '-'], { input: sql, encoding: 'utf8', timeout: 120_000 })
    const lines = `${r.stdout ?? ''}\n${r.stderr ?? ''}`.split('\n').filter((l) => l.includes('PROOF|'))
    if (r.status !== 0) throw new Error(`TE3A_DRIVER|psql exit ${r.status}: ${(r.stderr ?? '').split('\n').slice(-4).join(' / ')}`)
    return lines.map((l) => l.slice(l.indexOf('PROOF|') + 6))
}

/** 屏幕上一张表里第一格是 `label` 的那一行的最后一格(报表的金额列)。 */
async function screenTotals(page, labels) {
    return page.evaluate((labels) => {
        const out = {}
        for (const tr of document.querySelectorAll('table tr')) {
            const tds = [...tr.querySelectorAll('td')]
            if (!tds.length) continue
            const first = tds[0].textContent?.replace(/\s+/g, ' ').trim() ?? ''
            // 毛利那一格后面紧跟着「(毛利率%)」,中间没有空格 —— 按前缀认
            for (const l of labels) if (first.startsWith(l)) out[l] = tds[tds.length - 1].textContent?.trim() ?? null
        }
        return out
    }, labels)
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

    if (!PUP_DIR || !existsSync(join(PUP_DIR, 'node_modules/puppeteer-core'))) throw new Error('TE3A_DRIVER|PUPPETEER_DIR has no node_modules/puppeteer-core')
    const puppeteer = createRequire(join(PUP_DIR, 'package.json'))('puppeteer-core')
    const ver = readdirSync(CHROME_ROOT).sort().pop()
    const exe = join(CHROME_ROOT, ver, 'chrome-headless-shell-mac-arm64', 'chrome-headless-shell')
    if (!existsSync(exe)) throw new Error(`TE3A_DRIVER|no chrome-headless-shell at ${exe}`)
    try { const r = await fetch(BASE + '/login', { redirect: 'manual' }); if (r.status !== 200) throw new Error(`HTTP ${r.status}`) }
    catch (e) { throw new Error(`TE3A_DRIVER|no app at ${BASE}: ${e.message}`) }
    browser = await puppeteer.launch({ executablePath: exe, headless: true, args: ['--no-sandbox'] })

    const stamp = Date.now()
    const fin = await mintThrowaway({ prefix: 'te3aprobe', label: 'fin', stamp, codes: ['module.finance.view', 'data.view_pay', 'data.view_prices'] })
    const blind = await mintThrowaway({ prefix: 'te3aprobe', label: 'blind', stamp, codes: ['module.finance.view'] })
    // 付薪那一族:payroll_lines_masked 的【行】只给 module.hr.view,或 module.finance.view 且 data.view_pay(payroll_lines_masked.sql:38)——
    //   只持 finance.view 的读者一行都看不到,于是没有一格可遮。看得到行、看不到钱的读者是 hr.view + finance.view、不持 data.view_pay。
    const payBlind = await mintThrowaway({ prefix: 'te3aprobe', label: 'payblind', stamp, codes: ['module.finance.view', 'module.hr.view'] })

    // ── F1 · 损益表 ─────────────────────────────────────────────────────────
    {
        const path = `/finance/pnl?date_from=${PNL_FROM}&date_to=${PNL_TO}`
        const { page, status } = await openAs(fin, path)
        let screen
        try { screen = await screenTotals(page, ['Gross Profit', 'Net Profit']) } finally { await page.close() }
        ok(status === 200 && screen['Net Profit'] && screen['Gross Profit'], `F1 ${path} → HTTP ${status}; screen gross ${screen['Gross Profit']} · net ${screen['Net Profit']}`)
        const x = await exportOnce(fin, path, 'finance-profit-and-loss', 'xlsx')
        if (ok(!x.err, `F1 P&L Excel downloaded${x.err ? ` — ${x.err}` : `: ${x.file}`}`)) {
            const w = await readXlsx(x.path)
            const net = w.rows.find((r) => r.vals[0] === 'Net Profit'), gross = w.rows.find((r) => String(r.vals[0]).startsWith('Gross Profit'))
            ok(net && num(net.vals[2]) === num(screen['Net Profit']) && typeof net.vals[2] === 'number',
               `F1 Excel net profit ${net?.vals[2]} (a number) = screen ${screen['Net Profit']}`)
            ok(gross && num(gross.vals[2]) === num(screen['Gross Profit']), `F1 Excel gross profit ${gross?.vals[2]} = screen ${screen['Gross Profit']}`)
            const heading = w.rows.find((r) => r.n > 1 && r.vals[1] == null && r.vals[2] == null)
            const detail = w.rows.find((r) => r.n > 1 && r.indent === 1)
            ok(heading?.bold && net?.bold && detail && !detail.bold,
               `F1 Excel layout: heading "${heading?.vals[0]}" bold · net profit bold · account line "${detail?.vals[0]} ${detail?.vals[1]}" indented one level, not bold`)
            ok(w.about['Period'] === `${PNL_FROM} → ${PNL_TO}`, `F1 About sheet period ${JSON.stringify(w.about['Period'])}`)
        }
        const c = await exportOnce(fin, path, 'finance-profit-and-loss', 'csv')
        if (ok(!c.err, `F1 P&L CSV downloaded${c.err ? ` — ${c.err}` : `: ${c.file}`}`)) {
            const rows = csvRows(c.path)
            const net = rows.find((r) => r[1] === 'Net Profit')
            const kinds = [...new Set(rows.slice(1).map((r) => r[0]))].sort()
            ok(rows[0][0] === 'Line type' && net?.[0] === 'Total' && num(net[3]) === num(screen['Net Profit']),
               `F1 CSV first column "${rows[0][0]}"; net profit line type ${JSON.stringify(net?.[0])}, amount ${net?.[3]} = screen; line types ${JSON.stringify(kinds)}`)
        }
    }

    // ── F2 · 资产负债表 ─────────────────────────────────────────────────────
    {
        const path = `/finance/balance-sheet?as_of=${BS_AS_OF}`
        const { page, status } = await openAs(fin, path)
        let screen
        try { screen = await screenTotals(page, ['Total Assets', 'Total Liabilities + Equity']) } finally { await page.close() }
        ok(status === 200 && screen['Total Assets'] && screen['Total Liabilities + Equity'],
           `F2 ${path} → HTTP ${status}; screen total assets ${screen['Total Assets']} · total liabilities + equity ${screen['Total Liabilities + Equity']}`)
        const x = await exportOnce(fin, path, 'finance-balance-sheet', 'xlsx')
        if (ok(!x.err, `F2 balance sheet Excel downloaded${x.err ? ` — ${x.err}` : `: ${x.file}`}`)) {
            const w = await readXlsx(x.path)
            const ta = w.rows.find((r) => r.vals[0] === 'Total Assets'), tl = w.rows.find((r) => r.vals[0] === 'Total Liabilities + Equity')
            ok(ta && num(ta.vals[2]) === num(screen['Total Assets']) && /"/.test(ta.fmt ?? ''),
               `F2 Excel total assets ${ta?.vals[2]} = screen ${screen['Total Assets']} (number format ${JSON.stringify(ta?.fmt)} carries the currency)`)
            ok(tl && num(tl.vals[2]) === num(screen['Total Liabilities + Equity']), `F2 Excel total liabilities + equity ${tl?.vals[2]} = screen ${screen['Total Liabilities + Equity']}`)
            ok(ta?.bold && tl?.bold, 'F2 both totals bold')
        }
        const c = await exportOnce(fin, path, 'finance-balance-sheet', 'csv')
        if (ok(!c.err, `F2 balance sheet CSV downloaded${c.err ? ` — ${c.err}` : `: ${c.file}`}`)) {
            const rows = csvRows(c.path)
            const ta = rows.find((r) => r[1] === 'Total Assets')
            ok(ta?.[0] === 'Total' && num(ta[3]) === num(screen['Total Assets']), `F2 CSV total assets line type ${JSON.stringify(ta?.[0])}, ${ta?.[3]} = screen`)
        }
    }

    // ── V · 折旧预览 ────────────────────────────────────────────────────────
    {
        const path = `/finance/assets?date=${DEP_DATE}`
        const { page, status } = await openAs(fin, path)
        let screenTotal
        try {
            screenTotal = await page.evaluate(() => {
                for (const tr of document.querySelectorAll('table tr')) {
                    // DataTable 的第一格可能是手机展开钮 —— 按内容认合计那一行,不按位置
                    const tds = [...tr.querySelectorAll('td')]
                    if (tds.some((td) => td.textContent?.trim() === 'Totals')) return tds[tds.length - 1].textContent?.trim() ?? null
                }
                return null
            })
        } finally { await page.close() }
        ok(status === 200 && screenTotal !== null, `V ${path} → HTTP ${status}; depreciation preview total on screen ${JSON.stringify(screenTotal)}`)
        const x = await exportOnce(fin, path, 'finance-depreciation-preview', 'xlsx')
        if (ok(!x.err, `V depreciation preview Excel downloaded${x.err ? ` — ${x.err}` : `: ${x.file}`}`)) {
            const w = await readXlsx(x.path)
            ok(w.about['Preview'] === `Preview as at ${DEP_DATE}, not posted`, `V About sheet: Preview = ${JSON.stringify(w.about['Preview'])}`)
            const tot = w.rows.find((r) => r.vals[0] === 'Totals')
            ok(tot && num(tot.vals[2]) === num(screenTotal), `V total row ${tot?.vals[2]} = screen ${screenTotal} (a line the preview itself computes, Q3)`)
        }
    }

    // ── P · 付薪面板:全部行导出 + 不持 data.view_pay 的读者读到 Restricted ─────────
    for (const [arm, reader] of [['sees', fin], ['blind', payBlind]]) {
        const path = '/finance/payroll-payments'
        const { page, status } = await openAs(reader, path)
        let screen
        try {
            screen = await page.evaluate(() => {
                const t = [...document.querySelectorAll('section table')][0]
                if (!t) return null
                const hs = [...t.querySelectorAll('thead th')].map((th) => th.textContent?.trim() ?? '')
                const ai = hs.findIndex((h) => h === 'Net pay')
                const rows = [...t.querySelectorAll('tbody tr')].map((tr) => [...tr.querySelectorAll('td')].map((td) => td.textContent?.trim() ?? ''))
                return { n: rows.length, amounts: rows.map((r) => r[ai]) }
            })
        } finally { await page.close() }
        ok(status === 200 && screen && screen.n > 0, `P ${arm} · ${path} → HTTP ${status}; first period has ${screen?.n} lines on screen`)
        ok(arm === 'blind' ? screen?.amounts.every((a) => a === 'Restricted') : screen?.amounts.every((a) => a !== 'Restricted' && a !== '—'),
           `P ${arm} · screen amounts ${JSON.stringify(screen?.amounts)} ${arm === 'blind' ? '(were "—")' : ''}`)
        for (const fmt of ['xlsx', 'csv']) {
            const x = await exportOnce(reader, path, 'finance-payroll-payment-lines', fmt)
            if (!ok(!x.err, `P ${arm} · payroll lines ${fmt} downloaded${x.err ? ` — ${x.err}` : `: ${x.file}`}`)) continue
            let amounts
            if (fmt === 'xlsx') {
                const w = await readXlsx(x.path)
                const hi = w.rows[0].vals.indexOf('Net pay')
                amounts = w.rows.slice(1).map((r) => r.vals[hi])
            } else {
                const rows = csvRows(x.path)
                const hi = rows[0].indexOf('Net pay')
                amounts = rows.slice(1).map((r) => r[hi])
            }
            ok(amounts.length === screen?.n, `P ${arm} · ${fmt} holds ${amounts.length} rows = screen ${screen?.n} (nothing ticked — every row, Q4)`)
            ok(arm === 'blind' ? amounts.every((a) => a === 'Restricted') : amounts.every((a) => a !== 'Restricted' && Number.isFinite(num(a))),
               `P ${arm} · ${fmt} amounts ${JSON.stringify(amounts)}`)
        }
    }

    // ── C · 加工费结算面板:不持 data.view_prices 的读者读到 Restricted ─────────────
    for (const [arm, reader] of [['sees', fin], ['blind', blind]]) {
        const path = '/finance/processing-costs'
        const { page, status } = await openAs(reader, path)
        let amounts
        try {
            amounts = await page.evaluate(() => {
                const t = [...document.querySelectorAll('table')].find((tb) => [...tb.querySelectorAll('thead th')].some((th) => th.textContent?.trim() === 'Amount'))
                if (!t) return null
                const hs = [...t.querySelectorAll('thead th')].map((th) => th.textContent?.trim() ?? '')
                const ai = hs.indexOf('Amount')
                return [...t.querySelectorAll('tbody tr')].map((tr) => [...tr.querySelectorAll('td')][ai]?.textContent?.trim() ?? '')
            })
        } finally { await page.close() }
        ok(status === 200 && amounts?.length > 0 && (arm === 'blind' ? amounts.every((a) => a === 'Restricted') : amounts.every((a) => a !== 'Restricted' && a !== '—')),
           `C ${arm} · ${path} → HTTP ${status}; screen amounts ${JSON.stringify(amounts)} ${arm === 'blind' ? '(were "—")' : ''}`)
        const name = await (async () => {
            for (const n of ['finance-processing-costs-actual', 'finance-processing-costs-estimate']) {
                const x = await exportOnce(reader, path, n, 'csv')
                if (!x.err) return { n, x }
            }
            return null
        })()
        if (ok(!!name, `C ${arm} · settle panel CSV downloaded${name ? `: ${name.x.file}` : ''}`)) {
            const rows = csvRows(name.x.path)
            const hi = rows[0].indexOf('Amount')
            const vals = rows.slice(1).map((r) => r[hi])
            ok(vals.length > 0 && (arm === 'blind' ? vals.every((a) => a === 'Restricted') : vals.every((a) => Number.isFinite(num(a)) && a !== 'Restricted')),
               `C ${arm} · ${name.n} amounts ${JSON.stringify(vals)}`)
        }
    }

    // ── 读回:一次性账号的身份在库里读同一组付薪行(回滚),行数与屏幕相等 ──────────────
    const [dbLine] = psql(`BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"${fin.userId}","role":"authenticated"}', true);
SELECT 'PROOF|' || count(*) FROM payroll_lines_masked WHERE payroll_period_id = (SELECT id FROM payroll_period_lookup WHERE status = 'posted' AND deleted_at IS NULL ORDER BY period_month DESC LIMIT 1);
ROLLBACK;`)
    console.log(`STEP|as the throwaway finance reader (rolled back): the newest posted payroll period has ${dbLine} lines`)

    console.log(bad ? `STEP|done with ${bad} FAIL` : 'STEP|done')
    return finish(bad ? 1 : 0)
}

main().catch((e) => {
    console.error(String(e?.stack || e))
    return finish(String(e?.message || '').startsWith('TE3A_DRIVER') ? 2 : 1)
})
