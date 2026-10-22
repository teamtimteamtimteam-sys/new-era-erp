#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// TABLE-EXPORT-2a(Tim 2026-10-22)· 线上证明 —— 一个真浏览器按下「导出」,读回下载下来的文件
// ════════════════════════════════════════════════════════════════════════════
// 委托书:每一个本刀碰到的遮蔽族一格受限列的检查(两臂:受限的读者 / 有权限的读者,两臂必须分得开);
//         一张 part B 的页导出过它从前的上限(线上行数够的话);一颗没付的公积金钮(见下)。
//   P1 价格  /finance/invoices(服务端分页 → invoices/export)         data.view_prices      「Total」(Tim Q8:从前画成「—」)
//   P2 薪酬  /finance/journal(服务端分页 → journal/entries/export)   data.view_pay         「Amount (SGD)」—— 只有【来源 = Payroll】那几行被遮;
//            受限臂要求:Payroll 行全是「Restricted」、而且别的行至少一个数(两臂在同一张表里也分得开)。
//   P3 身份  /finance/credit-notes(服务端分页 → credit-notes/export) module.customers.view 「Customer」
//   (健康族:/finance/self-approved 有受限列,但线上 approval_log 里 self_decided 的行是 0 —— 那张表是空的,证不了;报告里点名。)
//   B1 /finance/freight(part B,从前 .limit(200)):线上 4 张,过不了从前的上限 —— 证的是「导出拿到的行数 = 库里的行数」与「没有超出时不画提示」。
//   G1 没有 module.finance.view 的人直接敲 /finance/invoices/export → 403 EXPORT_DENIED(与页面同一个判据)。
//   C1 /finance/payroll-payments 以财务读者打开:HTTP 200、没有错误边界。线上【没有】没付的公积金钮(唯一一期已付),
//      而造一期就得在线上提交单据 —— 公积金钮本身由 db/scripts/2026-10-23-table-export-2a-cpf-due-proof.mts 跑过(对照臂抛 RangeError)。
//      ★ 那颗钮按下去直接调 payCpf(没有确认框)= 在线上记一笔真的付款,所以本证明【不按】它。
//
// 只读:浏览器只发 GET 与点击导出;线上提交的只有一次性账号与它们的授权(前缀 te2probe,共用造号器),由清理计划收走。
// 判决只从最后一行 `TE2A_PROOF_EXIT=` 读:0 = 全 PASS 且收尾干净 · 1 = 有 FAIL · 2 = 驱动坏了 · 5 = live-lock 被占 · 6 = 收尾没完成。
// 用法:PROOF_BASE=http://localhost:3197 PUPPETEER_DIR=<装着 puppeteer-core 的目录> node db/scripts/2026-10-23-table-export-2a-live-proof.mjs
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

const BASE = process.env.PROOF_BASE || 'http://localhost:3197'
const PUP_DIR = process.env.PUPPETEER_DIR
const CHROME_ROOT = join(homedir(), '.cache/puppeteer/chrome-headless-shell')
const FIN = 'module.finance.view'

// 每一族:受限的读者只有 FIN;有权限的读者 FIN + data。`rowFilter` 给了就只看那几行(P2:来源 = Payroll)。
const FAMILIES = [
    { id: 'P1', family: 'prices', path: '/finance/invoices', name: 'invoices', data: 'data.view_prices', col: 'Total', hasDate: true },
    { id: 'P2', family: 'pay', path: '/finance/journal', name: 'journal-entries', data: 'data.view_pay', col: 'Amount (SGD)', hasDate: true, rowFilter: { col: 'Source', equals: 'Payroll' } },
    { id: 'P3', family: 'identity', path: '/finance/credit-notes', name: 'credit-notes', data: 'module.customers.view', col: 'Customer', hasDate: true, text: true },
]

let locked = false, bad = 0, browser = null
const ok = (cond, what) => { console.log(`${cond ? 'PASS' : 'FAIL'}|${what}`); if (!cond) bad++; return cond }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

// onFinish 必须是同步的:exitAfterCleanup 不等它(TABLE-EXPORT-1 第一次跑就栽在这里,判词那一行没写出来)。
installExitHooks({
    onFinish: (code) => {
        try { if (locked) release() } catch { /* 放锁失败不改判决 */ }
        console.log('AFTER|nothing but the throwaway accounts and their grants was committed (removed by the plan)')
        console.log(`TE2A_PROOF_EXIT=${code}`)
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
        else if (c === '\r') { /* CRLF 的前一半 */ }
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

async function openAs(reader, path) {
    const page = await browser.newPage()
    const cdp = await page.createCDPSession()
    const host = new URL(BASE).hostname
    await cdp.send('Network.setCookies', { cookies: [
        { name: reader.cookieName, value: reader.cookieValue, domain: host, path: '/', httpOnly: false, secure: false },
        { name: 'NEXT_LOCALE', value: 'en', domain: host, path: '/' },
    ] })
    const res = await page.goto(BASE + path, { waitUntil: 'networkidle2', timeout: 120_000 })
    return { page, cdp, status: res?.status() }
}

async function exportOnce(reader, fam, fmt) {
    const dir = mkdtempSync(join(tmpdir(), `te2a-${fam.id}-${fmt}-`))
    const { page, cdp, status } = await openAs(reader, fam.path)
    try {
        if (status !== 200) return { err: `HTTP ${status}` }
        await cdp.send('Browser.setDownloadBehavior', { behavior: 'allow', downloadPath: dir })
        // 等水合收尾(AGENTS.md:点之前等 __reactFiber,否则点击不会被 React 接住)
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
        const re = new RegExp(`^${fam.name}_\\d{4}-\\d{2}-\\d{2}_\\d{4}\\.${fmt}$`)
        const file = await waitForFile(dir, re, 90_000)
        if (!file) {
            const alert = await page.evaluate(() => document.querySelector('[data-slot="table-export"] [role="alert"]')?.textContent ?? '')
            return { err: `no ${fmt} file matching ${re} within 90 s${alert ? ` — on screen: ${alert}` : ''}` }
        }
        const notice = await page.evaluate(() => document.querySelector('[data-row-cap-notice]')?.textContent ?? null)
        return { file, path: join(dir, file), notice }
    } finally {
        await page.close()
    }
}

/** CSV 里一列的值;给了 rowFilter 就分成【命中】与【其余】两组。 */
function csvColumn(path, header, rowFilter) {
    const rows = parseCsv(readFileSync(path, 'utf8'))
    const idx = rows[0]?.indexOf(header) ?? -1
    const fIdx = rowFilter ? rows[0]?.indexOf(rowFilter.col) ?? -1 : -1
    const body = rows.slice(1).filter((r) => r.length > 1 || r[0] !== '')
    const hit = rowFilter ? body.filter((r) => r[fIdx] === rowFilter.equals) : body
    const rest = rowFilter ? body.filter((r) => r[fIdx] !== rowFilter.equals) : []
    return { idx, fIdx, n: body.length, values: idx < 0 ? [] : hit.map((r) => r[idx]), others: idx < 0 ? [] : rest.map((r) => r[idx]) }
}

async function xlsxFacts(path, header, rowFilter) {
    const wb = new ExcelJS.Workbook()
    await wb.xlsx.readFile(path)
    const ws = wb.worksheets[0]
    const headers = ws.getRow(1).values.slice(1)
    const idx = headers.indexOf(header)
    const fIdx = rowFilter ? headers.indexOf(rowFilter.col) : -1
    const vals = [], others = []
    let dates = 0
    ws.eachRow((row, n) => {
        if (n === 1) return
        const v = idx >= 0 ? row.getCell(idx + 1).value : undefined
        if (!rowFilter || row.getCell(fIdx + 1).value === rowFilter.equals) vals.push(v); else others.push(v)
        row.eachCell((c) => { if (c.value instanceof Date) dates++ })
    })
    const about = wb.getWorksheet('About')
    const aboutRows = {}
    about?.eachRow((r) => { aboutRows[String(r.getCell(1).value)] = String(r.getCell(2).value) })
    return { idx, vals, others, dates, about: aboutRows }
}

async function finish(code) {
    try { if (browser) await browser.close() } catch { /* 关浏览器失败不改判决 */ }
    browser = null
    return exitAfterCleanup(code)
}

const isNum = (s) => s !== '' && s !== 'Restricted' && Number.isFinite(Number(String(s).split(' ')[0].replace(/,/g, '')))

async function main() {
    const other = heldBy()
    if (other) { console.error(`✗ live-lock 被【${other.holder}】(pid ${other.pid})占着`); return exitAfterCleanup(5) }
    acquireOrExit('db/scripts/2026-10-23-table-export-2a-live-proof.mjs', { ownExit: false })
    locked = true
    openPlan('db/scripts/2026-10-23-table-export-2a-live-proof.mjs')
    await reapStalePlans()

    if (!PUP_DIR || !existsSync(join(PUP_DIR, 'node_modules/puppeteer-core'))) throw new Error('TE2A_DRIVER|PUPPETEER_DIR has no node_modules/puppeteer-core')
    const puppeteer = createRequire(join(PUP_DIR, 'package.json'))('puppeteer-core')
    const ver = readdirSync(CHROME_ROOT).sort().pop()
    const exe = join(CHROME_ROOT, ver, 'chrome-headless-shell-mac-arm64', 'chrome-headless-shell')
    if (!existsSync(exe)) throw new Error(`TE2A_DRIVER|no chrome-headless-shell at ${exe}`)
    try { const r = await fetch(BASE + '/login', { redirect: 'manual' }); if (r.status !== 200) throw new Error(`HTTP ${r.status}`) }
    catch (e) { throw new Error(`TE2A_DRIVER|no app at ${BASE}: ${e.message}`) }
    browser = await puppeteer.launch({ executablePath: exe, headless: true, args: ['--no-sandbox'] })

    const stamp = Date.now()
    for (const fam of FAMILIES) {
        const lo = fam.id.toLowerCase()
        const restricted = await mintThrowaway({ prefix: 'te2probe', label: `${lo}r`, stamp, codes: [FIN] })
        const permitted = await mintThrowaway({ prefix: 'te2probe', label: `${lo}p`, stamp, codes: [FIN, fam.data] })
        for (const [arm, reader] of [['restricted', restricted], ['permitted', permitted]]) {
            const csv = await exportOnce(reader, fam, 'csv')
            if (!ok(!csv.err, `${fam.id} ${fam.family} · ${arm} reader (${reader.codes.join(' + ')}) · ${fam.path} → CSV downloaded${csv.err ? ` — ${csv.err}` : `: ${csv.file}`}`)) continue
            const c = csvColumn(csv.path, fam.col, fam.rowFilter)
            const resN = c.values.filter((v) => v === 'Restricted').length
            const goodN = c.values.filter((v) => (fam.text ? v !== '' && v !== 'Restricted' : isNum(v))).length
            const otherNum = c.others.filter(isNum).length
            const scope = fam.rowFilter ? ` (rows where ${fam.rowFilter.col} = ${fam.rowFilter.equals}: ${c.values.length} of ${c.n})` : ''
            if (arm === 'restricted') {
                ok(c.idx >= 0 && c.values.length > 0 && resN === c.values.length,
                   `${fam.id} ${fam.family} · restricted · CSV "${fam.col}"${scope}: ${resN} "Restricted", ${goodN} values (want every one "Restricted")`)
                if (fam.rowFilter) ok(otherNum > 0, `${fam.id} ${fam.family} · restricted · CSV "${fam.col}" on the other ${c.others.length} rows: ${otherNum} numbers (the mask is the payroll rows only, not the column)`)
            } else {
                ok(c.idx >= 0 && goodN > 0 && resN === 0,
                   `${fam.id} ${fam.family} · permitted · CSV "${fam.col}"${scope}: ${goodN} values, ${resN} "Restricted" (want ≥1 value, 0 "Restricted")`)
            }
            const x = await exportOnce(reader, fam, 'xlsx')
            if (!ok(!x.err, `${fam.id} ${fam.family} · ${arm} · Excel downloaded${x.err ? ` — ${x.err}` : `: ${x.file}`}`)) continue
            const f = await xlsxFacts(x.path, fam.col, fam.rowFilter)
            const xGood = f.vals.filter((v) => (fam.text ? typeof v === 'string' && v !== '' && v !== 'Restricted' : typeof v === 'number')).length
            const xRes = f.vals.filter((v) => v === 'Restricted').length
            if (arm === 'restricted') {
                ok(f.idx >= 0 && f.vals.length > 0 && xRes === f.vals.length && xGood === 0,
                   `${fam.id} ${fam.family} · restricted · Excel "${fam.col}": ${f.vals.length} cells, ${xRes} "Restricted", ${xGood} values`)
            } else {
                ok(f.idx >= 0 && xGood > 0 && xRes === 0,
                   `${fam.id} ${fam.family} · permitted · Excel "${fam.col}": ${xGood} ${fam.text ? 'text values' : 'cells typed Number'}, ${xRes} "Restricted"`)
                if (fam.hasDate) ok(f.dates > 0, `${fam.id} ${fam.family} · permitted · Excel has ${f.dates} cells typed Date (dates are real dates, not text)`)
            }
            ok(f.about['Exported by'] === reader.email,
               `${fam.id} ${arm} · About sheet "Exported by" = ${f.about['Exported by'] ?? '(missing)'} (want ${reader.email})`)
        }
    }

    // B1:part B —— /finance/freight(从前 .limit(200))。导出拿到的行数 = 那条路由数出来的行数;没有超出时页上不画提示。
    const fin = await mintThrowaway({ prefix: 'te2probe', label: 'fin', stamp, codes: [FIN] })
    const freightRoute = await fetch(`${BASE}/finance/freight/export`, { headers: { cookie: fin.cookie }, redirect: 'manual' })
    const freightBody = await freightRoute.json().catch((e) => ({ parseError: String(e) }))
    const routeRows = Array.isArray(freightBody.rows) ? freightBody.rows.length : -1
    const fx = await exportOnce(fin, { id: 'B1', path: '/finance/freight', name: 'freight-documents' }, 'csv')
    if (ok(!fx.err, `B1 /finance/freight → CSV downloaded${fx.err ? ` — ${fx.err}` : `: ${fx.file}`}`)) {
        const n = parseCsv(readFileSync(fx.path, 'utf8')).slice(1).filter((r) => r.length > 1 || r[0] !== '').length
        ok(freightRoute.status === 200 && routeRows >= 0 && n === routeRows,
           `B1 /finance/freight/export → HTTP ${freightRoute.status}, ${routeRows} rows; the CSV has ${n} data rows (want equal)`)
        ok(routeRows > 200 ? fx.notice !== null : fx.notice === null,
           `B1 notice on the page: ${fx.notice === null ? 'none' : JSON.stringify(fx.notice)} (${routeRows} rows against the old limit of 200 — ${routeRows > 200 ? 'past it, a notice is due' : 'not past it, so no notice is due and "past the old limit" is NOT proven on live'})`)
    }

    // G1:没有 module.finance.view 的人直接敲导出路由 —— 与页面同一个判据,403
    const outsider = await mintThrowaway({ prefix: 'te2probe', label: 'outsider', stamp, codes: ['module.hr.view'] })
    for (const route of ['/finance/invoices/export', '/finance/bank/transfers/export', '/finance/journal/entries/export']) {
        const r = await fetch(`${BASE}${route}`, { headers: { cookie: outsider.cookie }, redirect: 'manual' })
        const body = await r.json().catch((e) => ({ parseError: String(e) }))
        ok(r.status === 403 && body.code === 'EXPORT_DENIED', `G1 ${route} as a reader without ${FIN} → HTTP ${r.status} ${JSON.stringify(body)}`)
    }

    // C1:付薪页以财务读者打开 —— 200,没有错误边界(公积金钮本身见 cpf-due 证明;线上没有没付的那一颗,本证明也不按任何钮)
    const { page, status } = await openAs(fin, '/finance/payroll-payments')
    try {
        const text = await page.evaluate(() => document.body.innerText)
        ok(status === 200 && !/Application error|Something went wrong|Unhandled Runtime Error/i.test(text),
           `C1 /finance/payroll-payments as a finance reader → HTTP ${status}, no error boundary on the page`)
    } finally { await page.close() }

    console.log(bad ? `STEP|done with ${bad} FAIL` : 'STEP|done')
    return finish(bad ? 1 : 0)
}

main().catch((e) => {
    console.error(String(e?.stack || e))
    return finish(String(e?.message || '').startsWith('TE2A_DRIVER') ? 2 : 1)
})
