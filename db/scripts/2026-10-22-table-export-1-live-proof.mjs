#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// TABLE-EXPORT-1(Tim 2026-10-22)· 线上证明 —— 一个真浏览器按下「导出」,读回下载下来的文件
// ════════════════════════════════════════════════════════════════════════════
// 委托书:每一个遮蔽族一格受限列的检查。本刀转完的列表页上【有】受限列的族是四个,每族两臂:
//   受限的读者(只有模块码)→ 那一列每一格都是「Restricted」,一个数都没有;
//   有权限的读者(模块码 + 数据码)→ 那一列至少一个数,一个「Restricted」都没有。
// 两臂分得开,这条判据才不是空转(AGENTS.md「一个分不出两臂的判据,不是判据」)。
//   F1 采购价  /purchasing/orders(服务端分页 → 走 export JSON 路由)   data.view_purchase_prices  「Subtotal (excl. GST)」
//   F2 价格    /inventory                                           data.view_prices           「Stock Value (SGD)」
//   F3 薪酬    /hr/payroll                                          data.view_pay              「Gross total」
//   F4 健康    /hr/claims                                           data.view_health           「Amount」
// 不在本刀转完的列表页上出现受限列的族(身份 · 银行 · 考评 · 销售记录)—— 报告里点名,这里不造一个假的。
// 每一格同时查:CSV 与 Excel 两份文件都下载下来;文件名合 Q9;Excel 里数是 Number、日期是 Date(Q7 / 硬规矩);
// About 表写着导出人(Q12);以及一条守卫:没有那个模块的人直接敲 /purchasing/orders/export → 403 EXPORT_DENIED(Q10 同一个判据)。
//
// 只读:浏览器只发 GET 与点击导出;线上提交的只有一次性账号与它们的授权(前缀 te1probe,共用造号器),由清理计划收走。
// 判决只从最后一行 `TE1_PROOF_EXIT=` 读:0 = 全 PASS 且收尾干净 · 1 = 有 FAIL · 2 = 驱动坏了 · 5 = live-lock 被占 · 6 = 收尾没完成。
// 用法:PROOF_BASE=http://localhost:3197 PUPPETEER_DIR=<装着 puppeteer-core 的目录> node db/scripts/2026-10-22-table-export-1-live-proof.mjs
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

const FAMILIES = [
    { id: 'F1', family: 'purchase prices', path: '/purchasing/orders', name: 'purchase-orders', module: 'module.purchasing.view', data: 'data.view_purchase_prices', col: 'Subtotal (excl. GST)', hasDate: true },
    { id: 'F2', family: 'prices', path: '/inventory', name: 'inventory', module: 'module.inventory.view', data: 'data.view_prices', col: 'Stock Value (SGD)', hasDate: false },
    { id: 'F3', family: 'pay', path: '/hr/payroll', name: 'hr-payroll-periods', module: 'module.hr.view', data: 'data.view_pay', col: 'Gross total', hasDate: true },
    { id: 'F4', family: 'health', path: '/hr/claims', name: 'hr-medical-claims', module: 'module.hr.view', data: 'data.view_health', col: 'Amount', hasDate: true },
]

let locked = false, bad = 0, browser = null
const ok = (cond, what) => { console.log(`${cond ? 'PASS' : 'FAIL'}|${what}`); if (!cond) bad++; return cond }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

// ★ onFinish 必须是同步的:exitAfterCleanup 不等它 —— 第一次跑时这里写成 async(先 await 关浏览器),
//   判词那一行于是在进程退出之后才轮到,日志里一行 TE1_PROOF_EXIT= 都没有(实测)。浏览器改在 finish() 里先关。
installExitHooks({
    onFinish: (code) => {
        try { if (locked) release() } catch { /* 放锁失败不改判决 */ }
        console.log('AFTER|nothing but the throwaway accounts and their grants was committed (removed by the plan)')
        console.log(`TE1_PROOF_EXIT=${code}`)
    },
})

/** 一份最小的 CSV 解析:引号、双引号转义、CRLF。lib/csv.ts 写出来的就是这个形状。 */
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

async function exportOnce(reader, fam, fmt) {
    const dir = mkdtempSync(join(tmpdir(), `te1-${fam.id}-${fmt}-`))
    const page = await browser.newPage()
    try {
        const cdp = await page.createCDPSession()
        await cdp.send('Browser.setDownloadBehavior', { behavior: 'allow', downloadPath: dir })
        const host = new URL(BASE).hostname
        await cdp.send('Network.setCookies', { cookies: [
            { name: reader.cookieName, value: reader.cookieValue, domain: host, path: '/', httpOnly: false, secure: false },
            { name: 'NEXT_LOCALE', value: 'en', domain: host, path: '/' },
        ] })
        const res = await page.goto(BASE + fam.path, { waitUntil: 'networkidle2', timeout: 120_000 })
        if (!res || res.status() !== 200) return { err: `HTTP ${res?.status()}` }
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
        return { file, path: join(dir, file) }
    } finally {
        await page.close()
    }
}

function csvColumn(path, header) {
    const rows = parseCsv(readFileSync(path, 'utf8'))
    const idx = rows[0]?.indexOf(header) ?? -1
    return { idx, values: idx < 0 ? [] : rows.slice(1).map((r) => r[idx]) }
}

async function xlsxFacts(path, header) {
    const wb = new ExcelJS.Workbook()
    await wb.xlsx.readFile(path)
    const ws = wb.worksheets[0]
    const headers = ws.getRow(1).values.slice(1)
    const idx = headers.indexOf(header)
    const vals = []
    let dates = 0
    ws.eachRow((row, n) => {
        if (n === 1) return
        if (idx >= 0) vals.push(row.getCell(idx + 1).value)
        row.eachCell((c) => { if (c.value instanceof Date) dates++ })
    })
    const about = wb.getWorksheet('About')
    const aboutRows = {}
    about?.eachRow((r) => { aboutRows[String(r.getCell(1).value)] = String(r.getCell(2).value) })
    return { idx, vals, dates, about: aboutRows }
}

async function finish(code) {
    try { if (browser) await browser.close() } catch { /* 关浏览器失败不改判决 */ }
    browser = null
    return exitAfterCleanup(code)
}

const isNum = (s) => s !== '' && s !== 'Restricted' && Number.isFinite(Number(String(s).split(' ')[0]))

async function main() {
    const other = heldBy()
    if (other) { console.error(`✗ live-lock 被【${other.holder}】(pid ${other.pid})占着`); return exitAfterCleanup(5) }
    acquireOrExit('db/scripts/2026-10-22-table-export-1-live-proof.mjs', { ownExit: false })
    locked = true
    openPlan('db/scripts/2026-10-22-table-export-1-live-proof.mjs')
    await reapStalePlans()

    if (!PUP_DIR || !existsSync(join(PUP_DIR, 'node_modules/puppeteer-core'))) throw new Error('TE1_DRIVER|PUPPETEER_DIR has no node_modules/puppeteer-core')
    const puppeteer = createRequire(join(PUP_DIR, 'package.json'))('puppeteer-core')
    const ver = readdirSync(CHROME_ROOT).sort().pop()
    const exe = join(CHROME_ROOT, ver, 'chrome-headless-shell-mac-arm64', 'chrome-headless-shell')
    if (!existsSync(exe)) throw new Error(`TE1_DRIVER|no chrome-headless-shell at ${exe}`)
    try { const r = await fetch(BASE + '/login', { redirect: 'manual' }); if (r.status !== 200) throw new Error(`HTTP ${r.status}`) }
    catch (e) { throw new Error(`TE1_DRIVER|no app at ${BASE}: ${e.message}`) }
    browser = await puppeteer.launch({ executablePath: exe, headless: true, args: ['--no-sandbox'] })

    const stamp = Date.now()
    for (const fam of FAMILIES) {
        const lo = fam.id.toLowerCase()
        const restricted = await mintThrowaway({ prefix: 'te1probe', label: `${lo}r`, stamp, codes: [fam.module] })
        const permitted = await mintThrowaway({ prefix: 'te1probe', label: `${lo}p`, stamp, codes: [fam.module, fam.data] })
        for (const [arm, reader] of [['restricted', restricted], ['permitted', permitted]]) {
            const csv = await exportOnce(reader, fam, 'csv')
            if (!ok(!csv.err, `${fam.id} ${fam.family} · ${arm} reader (${reader.codes.join(' + ')}) · ${fam.path} → CSV downloaded${csv.err ? ` — ${csv.err}` : `: ${csv.file}`}`)) continue
            const c = csvColumn(csv.path, fam.col)
            const restrictedN = c.values.filter((v) => v === 'Restricted').length
            const numN = c.values.filter(isNum).length
            const blankN = c.values.filter((v) => v === '').length
            if (arm === 'restricted') {
                ok(c.idx >= 0 && c.values.length > 0 && restrictedN === c.values.length,
                   `${fam.id} ${fam.family} · restricted · CSV column "${fam.col}": ${c.values.length} rows, ${restrictedN} "Restricted", ${numN} numbers, ${blankN} blank (want every row "Restricted")`)
            } else {
                ok(c.idx >= 0 && numN > 0 && restrictedN === 0,
                   `${fam.id} ${fam.family} · permitted · CSV column "${fam.col}": ${c.values.length} rows, ${numN} numbers, ${restrictedN} "Restricted" (want ≥1 number, 0 "Restricted")`)
            }
            const x = await exportOnce(reader, fam, 'xlsx')
            if (!ok(!x.err, `${fam.id} ${fam.family} · ${arm} · Excel downloaded${x.err ? ` — ${x.err}` : `: ${x.file}`}`)) continue
            const f = await xlsxFacts(x.path, fam.col)
            const xNum = f.vals.filter((v) => typeof v === 'number').length
            const xRes = f.vals.filter((v) => v === 'Restricted').length
            if (arm === 'restricted') {
                ok(f.idx >= 0 && f.vals.length > 0 && xRes === f.vals.length && xNum === 0,
                   `${fam.id} ${fam.family} · restricted · Excel column "${fam.col}": ${f.vals.length} cells, ${xRes} "Restricted", ${xNum} numbers`)
            } else {
                ok(f.idx >= 0 && xNum > 0 && xRes === 0,
                   `${fam.id} ${fam.family} · permitted · Excel column "${fam.col}": ${xNum} cells typed Number, ${xRes} "Restricted"`)
                if (fam.hasDate) ok(f.dates > 0, `${fam.id} ${fam.family} · permitted · Excel has ${f.dates} cells typed Date (dates are real dates, not text)`)
            }
            ok(f.about['Exported by'] === reader.email,
               `${fam.id} ${arm} · About sheet "Exported by" = ${f.about['Exported by'] ?? '(missing)'} (want ${reader.email})`)
        }
    }

    // Q10:没有那个模块的人直接敲分页表的 JSON 路由 —— 与页面同一个判据,403
    const outsider = await mintThrowaway({ prefix: 'te1probe', label: 'outsider', stamp, codes: ['module.hr.view'] })
    const r = await fetch(`${BASE}/purchasing/orders/export`, { headers: { cookie: outsider.cookie }, redirect: 'manual' })
    const body = await r.json().catch((e) => ({ parseError: String(e) }))
    ok(r.status === 403 && body.code === 'EXPORT_DENIED',
       `G1 /purchasing/orders/export as a reader without module.purchasing.view → HTTP ${r.status} ${JSON.stringify(body)}`)

    console.log(bad ? `STEP|done with ${bad} FAIL` : 'STEP|done')
    return finish(bad ? 1 : 0)
}

main().catch((e) => {
    console.error(String(e?.stack || e))
    return finish(String(e?.message || '').startsWith('TE1_DRIVER') ? 2 : 1)
})
