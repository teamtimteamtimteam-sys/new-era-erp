#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// TABLE-EXPORT-3c(Tim 2026-10-25)· 线上证明 —— 真浏览器读屏幕、按下「导出」读回文件;读库的那几句只数行(以 postgres 读基表)
// ════════════════════════════════════════════════════════════════════════════
// 委托书(Step 1 的线上证明,Tim 2026-10-25):
//   T  一条共享的历史留痕在两张不同的页上导出:批次的库存流水(MovementTimelineTable)在进料批编辑页与成品批编辑页,
//      文件行数 = 库里那一批的 inventory_movements 行数,About 表写着那一批的编号。
//   P  一张加工单的表导出:PROC-2026-0001 的投入,行数 = processing_inputs 行数,看不见那一批的读者读到批号 / 物料 / 电芯结构「Restricted」;
//      同一页的产出表由不持价格码的读者导出,分摊成本与单位成本两格写 "Restricted"(屏幕上同一处是「受限」)。
//   S  备件的金额列(Tim Q1):不持价格码的读者在机器页上看得见那一列的表头、看不见被删掉的那句「金额只给看得见价格的人」,
//      导出文件的表头里有那一列。★ 线上 maintenance_part_issues 0 行(以 postgres 读基表),于是「一格写 Restricted」在线上【量不到】——
//      不写一笔出库(那是一笔真交易),照直报出来。
//   V  一份预览带着它的 About 说明导出(Tim Q2c):计价器(只算不存)上算一次,价格明细的 Excel 里 About 表写「Price preview as at …」。
// 只读:浏览器只发 GET 与点「导出」(文件在浏览器里生成);线上提交的只有一次性账号与它们的授权(前缀 te3cprobe,共用造号器),由清理计划收走。
// 判决只从最后一行 `TE3C_PROOF_EXIT=` 读:0 = 全 PASS 且收尾干净 · 1 = 有 FAIL · 2 = 驱动坏了 · 5 = live-lock 被占 · 6 = 收尾没完成。
// 用法:PROOF_BASE=http://localhost:3197 PUPPETEER_DIR=<装着 puppeteer-core 的目录> node db/scripts/2026-10-25-table-export-3c-live-proof.mjs
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
const SCRIPT = 'db/scripts/2026-10-25-table-export-3c-live-proof.mjs'

let locked = false, bad = 0, browser = null
const ok = (cond, what) => { console.log(`${cond ? 'PASS' : 'FAIL'}|${what}`); if (!cond) bad++; return cond }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

installExitHooks({
    onFinish: (code) => {
        try { if (locked) release() } catch { /* 放锁失败不改判决 */ }
        console.log('AFTER|nothing but the throwaway accounts and their grants was committed (removed by the plan); the only database reads were row counts as postgres (base tables); nothing else was written')
        console.log(`TE3C_PROOF_EXIT=${code}`)
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
    const dir = mkdtempSync(join(tmpdir(), `te3c-${fileName}-${fmt}-`))
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
    if (r.status !== 0) throw new Error(`TE3C_DRIVER|psql exit ${r.status}: ${(r.stderr ?? '').split('\n').slice(-4).join(' / ')}`)
    return lines.map((l) => l.slice(l.indexOf('PROOF|') + 6))
}

async function finish(code) {
    try { if (browser) await browser.close() } catch { /* 不改判决 */ }
    browser = null
    return exitAfterCleanup(code)
}

// 证明用的记录(以 postgres 读基表,2026-10-25):IN-2026-0001 流水 10 行 · OUT-2026-0118 流水 8 行 ·
//   PROC-2026-0001 投入 1 行、产出 2 行 · FA-2026-0001 是一台有保养记录的机器 · PF-2026-0001 是一条在用的计价公式,2026-07-30 有镍钴价。
const INB = { id: '662bfff7-6121-454c-b37b-fd69a90c3b99', code: 'IN-2026-0001' }
const OUT = { id: '12dd44fb-7400-4122-81bf-3fd1f9c9e2a7', code: 'OUT-2026-0118' }
const RUN = { id: 'e99b1da4-36a8-4f33-84b6-9fdceb568032', code: 'PROC-2026-0001' }
const EQ = { id: 'a1560d88-de19-40fe-b78b-3bfa4079762b', code: 'FA-2026-0001' }
const CALC = '/tools/pricing/calculator?formula=b92ff252-c1e6-428d-8454-8bbb489f257a&quantity=1000&date=2026-07-30&ni=10&co=5'

const R = 'Restricted'
const bodyRows = async (x, fmt) => (fmt === 'xlsx' ? (await readXlsx(x.path)).rows.map((r) => r.vals) : csvRows(x.path))

async function main() {
    const other = heldBy()
    if (other) { console.error(`✗ live-lock 被【${other.holder}】(pid ${other.pid})占着`); return exitAfterCleanup(5) }
    acquireOrExit(SCRIPT, { ownExit: false })
    locked = true
    openPlan(SCRIPT)
    await reapStalePlans()

    if (!PUP_DIR || !existsSync(join(PUP_DIR, 'node_modules/puppeteer-core'))) throw new Error('TE3C_DRIVER|PUPPETEER_DIR has no node_modules/puppeteer-core')
    const puppeteer = createRequire(join(PUP_DIR, 'package.json'))('puppeteer-core')
    const ver = readdirSync(CHROME_ROOT).sort().pop()
    const exe = join(CHROME_ROOT, ver, 'chrome-headless-shell-mac-arm64', 'chrome-headless-shell')
    if (!existsSync(exe)) throw new Error(`TE3C_DRIVER|no chrome-headless-shell at ${exe}`)
    try { const r = await fetch(BASE + '/login', { redirect: 'manual' }); if (r.status !== 200) throw new Error(`HTTP ${r.status}`) }
    catch (e) { throw new Error(`TE3C_DRIVER|no app at ${BASE}: ${e.message}`) }
    browser = await puppeteer.launch({ executablePath: exe, headless: true, args: ['--no-sandbox'] })

    const counts = Object.fromEntries(psql(`
        SELECT 'PROOF|in=' || (SELECT count(*) FROM inventory_movements WHERE inbound_batch_id = '${INB.id}');
        SELECT 'PROOF|out=' || (SELECT count(*) FROM inventory_movements WHERE output_batch_id = '${OUT.id}');
        SELECT 'PROOF|inputs=' || (SELECT count(*) FROM processing_inputs WHERE run_id = '${RUN.id}');
        SELECT 'PROOF|outputs=' || (SELECT count(*) FROM processing_outputs WHERE run_id = '${RUN.id}');
        SELECT 'PROOF|parts=' || (SELECT count(*) FROM maintenance_part_issues i JOIN equipment_maintenance m ON m.id = i.maintenance_id
                                   WHERE m.equipment_id = '${EQ.id}' AND i.kind = 'issue');
    `).map((l) => l.split('=')).map(([k, v]) => [k, Number(v)]))
    console.log(`STEP|database counts as postgres (base tables): ${JSON.stringify(counts)}`)

    const stamp = Date.now()
    const batches = await mintThrowaway({ prefix: 'te3cprobe', label: 'batches', stamp, codes: ['module.inbound.view', 'module.output.view', 'module.inventory.view'] })   // 流水行的读策略是 module.inventory.view(第一跑漏了它,屏幕与文件都是 0 行)
    const procBlind = await mintThrowaway({ prefix: 'te3cprobe', label: 'procblind', stamp, codes: ['module.processing.view'] })
    const pricing = await mintThrowaway({ prefix: 'te3cprobe', label: 'pricing', stamp, codes: ['module.pricing.view', 'data.view_prices', 'data.view_purchase_prices'] })

    // ── T · 一条共享留痕在两张页上 ──────────────────────────────────────────
    for (const [where, path, n, code] of [
        ['inbound', `/inbound/${INB.id}/edit`, counts.in, INB.code],
        ['output', `/output/${OUT.id}/edit`, counts.out, OUT.code],
    ]) {
        for (const fmt of ['xlsx', 'csv']) {
            const x = await exportOnce(batches, path, 'batch-movements', fmt)
            if (!ok(!x.err, `T ${where} · ${path} batch movements ${fmt} downloaded${x.err ? ` — ${x.err}` : `: ${x.file}`}`)) continue
            const rows = (await bodyRows(x, fmt)).slice(1)
            let about = ''
            if (fmt === 'xlsx') about = JSON.stringify((await readXlsx(x.path)).about)
            ok(rows.length === n && n > 0 && (fmt === 'csv' || about.includes(code)),
               `T ${where} · ${fmt}: ${rows.length} rows = ${n} inventory_movements of ${code}${fmt === 'xlsx' ? `; About ${about}` : ''}; first row ${JSON.stringify(rows[0])}`)
        }
    }

    // ── P · 加工单的表 ─────────────────────────────────────────────────────
    {
        const path = `/operation/processing/${RUN.id}`
        for (const fmt of ['xlsx', 'csv']) {
            const x = await exportOnce(procBlind, path, 'processing-run-inputs', fmt)
            if (ok(!x.err, `P ${RUN.code} inputs ${fmt} downloaded${x.err ? ` — ${x.err}` : `: ${x.file}`}`)) {
                const rows = (await bodyRows(x, fmt)).slice(1)
                // 这位读者只持 module.processing.view:投入那一批(进料批要 module.inbound.view)它读不到 —— 批号 / 物料 / 电芯结构写 Restricted,数量照常是数
                ok(rows.length === counts.inputs && counts.inputs > 0 && rows[0][0] === R && rows[0][1] === R && Number(rows[0][3]) === 1000,
                   `P inputs · ${fmt}: ${rows.length} rows = ${counts.inputs} processing_inputs; row ${JSON.stringify(rows[0])} (batch / material / construction Restricted for a reader who cannot see the batch)`)
            }
            const y = await exportOnce(procBlind, path, 'processing-run-outputs', fmt)
            if (ok(!y.err, `P ${RUN.code} outputs ${fmt} downloaded${y.err ? ` — ${y.err}` : `: ${y.file}`}`)) {
                const all = await bodyRows(y, fmt)
                const head = all[0].map(String), rows = all.slice(1)
                const ci = head.findIndex((h) => h.startsWith('Allocated Cost')), ui = head.findIndex((h) => h.startsWith('Unit Cost'))
                ok(rows.length === counts.outputs && ci >= 0 && ui >= 0 && rows.every((r) => r[ci] === R && r[ui] === R),
                   `P outputs · ${fmt} as a reader without data.view_prices: ${rows.length} rows = ${counts.outputs} processing_outputs; allocated cost ${JSON.stringify(rows.map((r) => r[ci]))} · unit cost ${JSON.stringify(rows.map((r) => r[ui]))}`)
            }
        }
    }

    // ── S · 备件金额列(Q1)──────────────────────────────────────────────────
    {
        const path = `/operation/equipment/${EQ.id}`
        const { page, status } = await openAs(procBlind, path)
        let s = null
        try {
            s = await page.evaluate(() => ({
                text: document.body.innerText,
                heads: [...document.querySelectorAll('table thead th')].map((th) => th.textContent?.trim() ?? ''),
            }))
        } finally { await page.close() }
        const colShown = s.heads.includes('Still out, at landed cost')
        const sentenceGone = !s.text.includes('Amounts are shown only to people who can see prices.')
        ok(status === 200 && colShown && sentenceGone,
           `S ${path} (${EQ.code}) as a reader without data.view_prices → HTTP ${status}; value column header on screen: ${colShown}; "amounts only for people who can see prices" sentence gone: ${sentenceGone}`)
        for (const fmt of ['xlsx', 'csv']) {
            const x = await exportOnce(procBlind, path, 'equipment-spare-parts', fmt)
            if (!ok(!x.err, `S spare parts ${fmt} downloaded${x.err ? ` — ${x.err}` : `: ${x.file}`}`)) continue
            const all = await bodyRows(x, fmt)
            ok(all[0].map(String).includes('Still out, at landed cost') && all.length - 1 === counts.parts,
               `S spare parts · ${fmt}: header ${JSON.stringify(all[0])}; ${all.length - 1} rows = ${counts.parts} issues on live`)
        }
        console.log(`NOT-MEASURED|S the "Restricted" value cell itself: maintenance_part_issues has ${counts.parts} issue rows for ${EQ.code} (as postgres, base table) — issuing a part is a real transaction, so it is not recorded for a proof`)
    }

    // ── V · 预览带着它的 About 说明 ─────────────────────────────────────────
    {
        const { page, cdp, status } = await openAs(pricing, CALC)
        try {
            await page.waitForFunction(() => {
                const b = document.querySelector('form button[type="submit"]')
                return !!b && Object.keys(b).some((k) => k.startsWith('__react'))
            }, { timeout: 60_000 })
            await page.evaluate(() => document.querySelector('form button[type="submit"]').click())
            const got = await page.waitForFunction(() => {
                const b = document.querySelector('[data-slot="table-export"] button')
                return !!b && Object.keys(b).some((k) => k.startsWith('__react'))
            }, { timeout: 60_000 }).then(() => true, () => false)
            const err = got ? null : await page.evaluate(() => document.querySelector('.bg-red-100')?.textContent ?? null)
            if (ok(status === 200 && got, `V ${CALC} → HTTP ${status}; price breakdown drawn with an export pair${err ? ` — error on screen: ${err}` : ''}`)) {
                for (const fmt of ['xlsx', 'csv']) {
                    const dir = mkdtempSync(join(tmpdir(), `te3c-preview-${fmt}-`))
                    await cdp.send('Browser.setDownloadBehavior', { behavior: 'allow', downloadPath: dir })
                    await page.evaluate((label) => {
                        const bar = document.querySelector('[data-slot="table-export"]')
                        ;[...bar.querySelectorAll('button')].find((x) => x.textContent?.trim() === label)?.click()
                    }, fmt === 'csv' ? 'Export CSV' : 'Export Excel')
                    const file = await waitForFile(dir, new RegExp(`^pricing-price-breakdown_\\d{4}-\\d{2}-\\d{2}_\\d{4}\\.${fmt}$`), 60_000)
                    if (!ok(!!file, `V price breakdown ${fmt} downloaded${file ? `: ${file}` : ' — no file'}`)) continue
                    if (fmt === 'xlsx') {
                        const w = await readXlsx(join(dir, file))
                        ok(/^Price preview as at \d{4}-\d{2}-\d{2} \d{2}:\d{2}/.test(w.about['Preview'] ?? '') && w.rows.length > 1,
                           `V xlsx: sheets ${JSON.stringify(w.sheets)}; About "Preview" = "${w.about['Preview']}"; ${w.rows.length - 1} metal rows; first ${JSON.stringify(w.rows[1]?.vals)}`)
                    } else {
                        const rows = csvRows(join(dir, file))
                        ok(rows.length > 1, `V csv: ${rows.length - 1} metal rows (CSV is pure data, Q12)`)
                    }
                }
            }
        } finally { await page.close() }
    }

    console.log(bad ? `STEP|done with ${bad} FAIL` : 'STEP|done')
    return finish(bad ? 1 : 0)
}

main().catch((e) => {
    console.error(String(e?.stack || e))
    return finish(String(e?.message || '').startsWith('TE3C_DRIVER') ? 2 : 1)
})
