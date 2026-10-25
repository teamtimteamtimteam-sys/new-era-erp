#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// TABLE-EXPORT-3b(Tim 2026-10-25)· 线上证明 —— 真浏览器读屏幕、按下「导出」读回文件;读库的那几句一律在回滚的事务里
// ════════════════════════════════════════════════════════════════════════════
// 委托书(Step 1 的线上证明):
//   R  「受限」那一族至少三张,由不持那个码的读者导出,文件里写 "Restricted"(屏幕上同一处是「受限」),其中一行是被遮的合计行(Tim 2026-10-25 Q1):
//      R1 采购单明细(不持 data.view_purchase_prices)—— 单价、行金额与净额 / 税额 / 总额三行合计;对照臂(持码)那三行是数。
//      R2 库存成品批次(不持 data.view_prices)—— 单位成本、成本价值。
//      R3 员工的薪资历史(不持 data.view_pay)—— 薪资各列。
//   T  一条历史留痕导出:入库批次的改价历史(持价码),行数 = 库里那一批的 price_history 行数。
//   E  一张可编辑的表导出:/hr/leave/types,行数 = 屏幕行数,写的是已保存的值。
//   M  权限矩阵的码清单(Q2):财务角色的那一对导出里有 data.view_pay,「已授予」= Yes;矩阵那一对也下载得到。
// 只读:浏览器只发 GET 与点「导出」(文件在浏览器里生成);线上提交的只有一次性账号与它们的授权(前缀 te3bprobe,共用造号器),由清理计划收走。
// 判决只从最后一行 `TE3B_PROOF_EXIT=` 读:0 = 全 PASS 且收尾干净 · 1 = 有 FAIL · 2 = 驱动坏了 · 5 = live-lock 被占 · 6 = 收尾没完成。
// 用法:PROOF_BASE=http://localhost:3197 PUPPETEER_DIR=<装着 puppeteer-core 的目录> node db/scripts/2026-10-25-table-export-3b-live-proof.mjs
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
const SCRIPT = 'db/scripts/2026-10-25-table-export-3b-live-proof.mjs'

let locked = false, bad = 0, browser = null
const ok = (cond, what) => { console.log(`${cond ? 'PASS' : 'FAIL'}|${what}`); if (!cond) bad++; return cond }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

installExitHooks({
    onFinish: (code) => {
        try { if (locked) release() } catch { /* 放锁失败不改判决 */ }
        console.log('AFTER|nothing but the throwaway accounts and their grants was committed (removed by the plan); every database read as a throwaway ran in a transaction that was rolled back')
        console.log(`TE3B_PROOF_EXIT=${code}`)
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
    const dir = mkdtempSync(join(tmpdir(), `te3b-${fileName}-${fmt}-`))
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
    if (r.status !== 0) throw new Error(`TE3B_DRIVER|psql exit ${r.status}: ${(r.stderr ?? '').split('\n').slice(-4).join(' / ')}`)
    return lines.map((l) => l.slice(l.indexOf('PROOF|') + 6))
}

async function finish(code) {
    try { if (browser) await browser.close() } catch { /* 不改判决 */ }
    browser = null
    return exitAfterCleanup(code)
}

// 证明用的记录(以 postgres 读基表,2026-10-25):PO-2026-0009 带税、1 行;MAT-2026-0001 有 10 张成品批次;EMP-2026-0001 有 1 条薪资行;
//   IN-2026-0001 有 2 条改价记录;财务角色持 data.view_pay。
const PO = { id: '14956797-c2ef-49a2-acbd-8b3eae2d79e0', code: 'PO-2026-0009' }
const MAT = '5d4c059f-ff78-4e0d-b117-6be775a05f7e'
const EMP = '81cf6510-7ee0-4017-bc85-273c900f2e13'
const INB = { id: '662bfff7-6121-454c-b37b-fd69a90c3b99', code: 'IN-2026-0001' }
const FIN_ROLE = 'f1478269-8587-459e-a50b-a2c7419770cf'

const R = 'Restricted'
const flat = (rows) => rows.flatMap((r) => r.vals)

async function main() {
    const other = heldBy()
    if (other) { console.error(`✗ live-lock 被【${other.holder}】(pid ${other.pid})占着`); return exitAfterCleanup(5) }
    acquireOrExit(SCRIPT, { ownExit: false })
    locked = true
    openPlan(SCRIPT)
    await reapStalePlans()

    if (!PUP_DIR || !existsSync(join(PUP_DIR, 'node_modules/puppeteer-core'))) throw new Error('TE3B_DRIVER|PUPPETEER_DIR has no node_modules/puppeteer-core')
    const puppeteer = createRequire(join(PUP_DIR, 'package.json'))('puppeteer-core')
    const ver = readdirSync(CHROME_ROOT).sort().pop()
    const exe = join(CHROME_ROOT, ver, 'chrome-headless-shell-mac-arm64', 'chrome-headless-shell')
    if (!existsSync(exe)) throw new Error(`TE3B_DRIVER|no chrome-headless-shell at ${exe}`)
    try { const r = await fetch(BASE + '/login', { redirect: 'manual' }); if (r.status !== 200) throw new Error(`HTTP ${r.status}`) }
    catch (e) { throw new Error(`TE3B_DRIVER|no app at ${BASE}: ${e.message}`) }
    browser = await puppeteer.launch({ executablePath: exe, headless: true, args: ['--no-sandbox'] })

    const stamp = Date.now()
    const poBlind = await mintThrowaway({ prefix: 'te3bprobe', label: 'poblind', stamp, codes: ['module.purchasing.view'] })
    const poSees = await mintThrowaway({ prefix: 'te3bprobe', label: 'posees', stamp, codes: ['module.purchasing.view', 'data.view_purchase_prices', 'data.view_prices'] })
    const invBlind = await mintThrowaway({ prefix: 'te3bprobe', label: 'invblind', stamp, codes: ['module.inventory.view'] })
    const hrBlind = await mintThrowaway({ prefix: 'te3bprobe', label: 'hrblind', stamp, codes: ['module.hr.view'] })
    const inbSees = await mintThrowaway({ prefix: 'te3bprobe', label: 'inbsees', stamp, codes: ['module.inbound.view', 'data.view_purchase_prices', 'data.view_prices'] })
    const perms = await mintThrowaway({ prefix: 'te3bprobe', label: 'perms', stamp, codes: ['action.manage_permissions'] })

    const screenText = async (reader, path) => {
        const { page, status } = await openAs(reader, path)
        try { return { status, text: await page.evaluate(() => document.body.innerText) } } finally { await page.close() }
    }

    // ── R1 · 采购单明细:单价 / 行金额 / 三行合计 ───────────────────────────
    {
        const path = `/purchasing/orders/${PO.id}`
        const s = await screenText(poBlind, path)
        ok(s.status === 200 && s.text.includes(R), `R1 ${path} (${PO.code}) as a reader without data.view_purchase_prices → HTTP ${s.status}; screen shows "${R}": ${s.text.includes(R)}`)
        for (const [arm, reader] of [['blind', poBlind], ['sees', poSees]]) {
            for (const fmt of ['xlsx', 'csv']) {
                const x = await exportOnce(reader, path, 'purchasing-order-lines', fmt)
                if (!ok(!x.err, `R1 ${arm} · PO lines ${fmt} downloaded${x.err ? ` — ${x.err}` : `: ${x.file}`}`)) continue
                const rows = fmt === 'xlsx' ? (await readXlsx(x.path)).rows.map((r) => r.vals) : csvRows(x.path)
                const head = rows[0], body = rows.slice(1)
                const last3 = body.slice(-3)
                const labels = last3.map((r) => r.find((v) => typeof v === 'string' && v !== '' && v !== R))
                const amountCol = head.length - 1
                const lastAmounts = last3.map((r) => r[amountCol])
                if (arm === 'blind') {
                    ok(body.length === 4 && lastAmounts.every((v) => v === R) && flat([{ vals: body[0] }]).filter((v) => v === R).length >= 2,
                       `R1 blind · ${fmt}: ${body.length} rows (1 line + 3 totals ${JSON.stringify(labels)}); total amounts ${JSON.stringify(lastAmounts)}; line row ${JSON.stringify(body[0])}`)
                } else {
                    ok(body.length === 4 && lastAmounts.every((v) => v !== R && v !== '' && v != null) && !flat(body.map((v) => ({ vals: v }))).includes(R),
                       `R1 sees · ${fmt}: total amounts ${JSON.stringify(lastAmounts)} (numbers, no "${R}" anywhere)`)
                }
            }
        }
    }

    // ── R2 · 成品批次:单位成本 / 成本价值 ───────────────────────────────────
    {
        const path = `/inventory/output/${MAT}`
        const s = await screenText(invBlind, path)
        ok(s.status === 200 && s.text.includes(R), `R2 ${path} as a reader without data.view_prices → HTTP ${s.status}; screen shows "${R}": ${s.text.includes(R)}`)
        for (const fmt of ['xlsx', 'csv']) {
            const x = await exportOnce(invBlind, path, 'inventory-output-material-batches', fmt)
            if (!ok(!x.err, `R2 output batches ${fmt} downloaded${x.err ? ` — ${x.err}` : `: ${x.file}`}`)) continue
            const rows = fmt === 'xlsx' ? (await readXlsx(x.path)).rows.map((r) => r.vals) : csvRows(x.path)
            const body = rows.slice(1)
            const perRow = body.map((r) => r.filter((v) => v === R).length)
            ok(body.length > 0 && perRow.every((n) => n >= 2), `R2 ${fmt}: ${body.length} batch rows, "${R}" cells per row ${JSON.stringify(perRow)} (unit cost + cost value)`)
        }
    }

    // ── R3 · 员工薪资历史 ────────────────────────────────────────────────────
    {
        const path = `/hr/employees/${EMP}`
        const s = await screenText(hrBlind, path)
        ok(s.status === 200 && s.text.includes(R), `R3 ${path} as a reader without data.view_pay → HTTP ${s.status}; screen shows "${R}": ${s.text.includes(R)}`)
        for (const fmt of ['xlsx', 'csv']) {
            const x = await exportOnce(hrBlind, path, 'hr-employee-pay-history', fmt)
            if (!ok(!x.err, `R3 pay history ${fmt} downloaded${x.err ? ` — ${x.err}` : `: ${x.file}`}`)) continue
            const rows = fmt === 'xlsx' ? (await readXlsx(x.path)).rows.map((r) => r.vals) : csvRows(x.path)
            const body = rows.slice(1)
            ok(body.length === 1 && body[0].filter((v) => v === R).length >= 2, `R3 ${fmt}: ${body.length} pay row ${JSON.stringify(body[0])}`)
        }
    }

    // ── T · 改价历史(留痕) ──────────────────────────────────────────────────
    {
        const [dbN] = psql(`SELECT 'PROOF|' || count(*) FROM price_history WHERE inbound_batch_id = '${INB.id}';`)
        const path = `/inbound/${INB.id}/edit`
        const x = await exportOnce(inbSees, path, 'inbound-price-history', 'xlsx')
        if (ok(!x.err, `T ${INB.code} price history Excel downloaded${x.err ? ` — ${x.err}` : `: ${x.file}`}`)) {
            const w = await readXlsx(x.path)
            const body = w.rows.slice(1).map((r) => r.vals)
            const nums = body.map((r) => r.filter((v) => typeof v === 'number').length)
            ok(body.length === Number(dbN) && nums.every((n) => n >= 1) && !flat(body.map((v) => ({ vals: v }))).includes(R),
               `T ${body.length} rows in the file = ${dbN} price_history rows in the database (as postgres, base table); number cells per row ${JSON.stringify(nums)}; sheets ${JSON.stringify(w.sheets)}`)
        }
    }

    // ── E · 可编辑的表:假别 ──────────────────────────────────────────────────
    {
        const path = '/hr/leave/types'
        const { page, status } = await openAs(hrBlind, path)
        let n
        try { n = await page.evaluate(() => document.querySelectorAll('table[data-slot="editable-table"] tbody tr').length) } finally { await page.close() }
        const x = await exportOnce(hrBlind, path, 'hr-leave-types', 'xlsx')
        if (ok(status === 200 && !x.err, `E ${path} → HTTP ${status}; ${n} rows on screen; Excel ${x.err ?? x.file}`)) {
            const w = await readXlsx(x.path)
            ok(w.rows.length - 1 === n && n > 0, `E file has ${w.rows.length - 1} rows = screen ${n}; header ${JSON.stringify(w.rows[0].vals)}`)
        }
        const c = await exportOnce(hrBlind, path, 'hr-leave-types', 'csv')
        ok(!c.err && csvRows(c.path).length - 1 === n, `E CSV ${c.err ?? c.file}: ${c.err ? '' : csvRows(c.path).length - 1} rows`)
    }

    // ── M · 权限矩阵:矩阵 + 码清单(Q2) ─────────────────────────────────────
    {
        const path = `/settings/roles/${FIN_ROLE}`
        const m = await exportOnce(perms, path, 'settings-role-modules', 'xlsx')
        if (ok(!m.err, `M ${path} (finance) module matrix Excel downloaded${m.err ? ` — ${m.err}` : `: ${m.file}`}`)) {
            const w = await readXlsx(m.path)
            ok(w.rows.length > 1, `M matrix: ${w.rows.length - 1} module rows; header ${JSON.stringify(w.rows[0].vals)}`)
        }
        for (const fmt of ['xlsx', 'csv']) {
            const x = await exportOnce(perms, path, 'settings-role-data-actions', fmt)
            if (!ok(!x.err, `M card codes ${fmt} downloaded${x.err ? ` — ${x.err}` : `: ${x.file}`}`)) continue
            const rows = fmt === 'xlsx' ? (await readXlsx(x.path)).rows.map((r) => r.vals) : csvRows(x.path)
            const pay = rows.find((r) => r.includes('data.view_pay'))
            const codes = rows.slice(1).map((r) => r[1])
            ok(!!pay && pay[pay.length - 1] === 'Yes' && codes.every((c) => /^(data|action)\./.test(String(c))),
               `M ${fmt}: ${rows.length - 1} card codes (all data.* / action.*); data.view_pay row ${JSON.stringify(pay)}`)
        }
    }

    console.log(bad ? `STEP|done with ${bad} FAIL` : 'STEP|done')
    return finish(bad ? 1 : 0)
}

main().catch((e) => {
    console.error(String(e?.stack || e))
    return finish(String(e?.message || '').startsWith('TE3B_DRIVER') ? 2 : 1)
})
