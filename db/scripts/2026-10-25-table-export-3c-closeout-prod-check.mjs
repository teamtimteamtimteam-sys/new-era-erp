#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// TABLE-FEATURES-1 Part 1.2 · TABLE-EXPORT-3c 收尾 —— 对着【生产】(Vercel)只读地看一眼
// ════════════════════════════════════════════════════════════════════════════
// 委托书 1.2:一个一次性账号导出一张加工单的表与关联页的表(HTTP 200,文件行数 = 屏幕行数),然后收走账号,读回 0 残留。
//   ① /operation/processing/<PROC-2026-0001>:画着导出钮(= 生产跑的是 f156ee1,3c 才给加工单的表挂上导出);
//      产出表(processing-run-outputs)的 Excel 与 CSV 行数 = 同一张表在屏幕上画出来的行数。
//   ② /related/processing_run/<PROC-2026-0001>/output_batch:关联页(keyset,服务端导出路由);
//      Excel 与 CSV 行数 = 屏幕上的 data-related-total,也 = 屏幕上画出来的行数(不足一页时两者相等)。
// 只读:浏览器只发 GET 与点「导出」(关联页的导出是一次 GET 到 /export 路由)。线上提交的只有一次性账号与它的授权
//      (前缀 te3cprobe —— 这是 3c 的收尾,沿用 3c 的前缀,与 3b 收尾沿用 te3bprobe 同一个先例),由清理计划收走。
// 判决只从最后一行 `TE3C_CLOSEOUT_EXIT=` 读:0 = 全 PASS 且收尾干净 · 1 = 有 FAIL · 2 = 驱动坏了 · 5 = live-lock 被占 · 6 = 收尾没完成。
// 用法:PROOF_BASE=https://new-era-erp.vercel.app PUPPETEER_DIR=<装着 puppeteer-core 的目录> node db/scripts/2026-10-25-table-export-3c-closeout-prod-check.mjs
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
const SCRIPT = 'db/scripts/2026-10-25-table-export-3c-closeout-prod-check.mjs'
// 与 3c 线上证明 P 同一张单。search_related('processing_run', 它) 以 postgres 读:output_batch 2 · inbound_batch 1(2026-10-25)
const RUN = { id: 'e99b1da4-36a8-4f33-84b6-9fdceb568032', code: 'PROC-2026-0001' }

let locked = false, bad = 0, browser = null
const ok = (cond, what) => { console.log(`${cond ? 'PASS' : 'FAIL'}|${what}`); if (!cond) bad++; return cond }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

installExitHooks({
    onFinish: (code) => {
        try { if (locked) release() } catch { /* 放锁失败不改判决 */ }
        console.log(`TE3C_CLOSEOUT_EXIT=${code}`)
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
    return rows.filter((r) => r.length > 1 || r[0] !== '')
}

async function readXlsxRows(path) {
    const wb = new ExcelJS.Workbook()
    await wb.xlsx.readFile(path)
    const rows = []
    wb.worksheets[0].eachRow((row) => rows.push(row.values.slice(1)))
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

async function finish(code) {
    try { if (browser) await browser.close() } catch { /* 不改判决 */ }
    browser = null
    return exitAfterCleanup(code)
}

/**
 * 打开 path,逐对按导出钮直到名为 fileName 的文件落下;返回 HTTP 状态、按中的那一对所在表在屏幕上画出的行数、两个文件的数据行数。
 * 屏幕行数:那一对钮所在的 DataTable 外壳里 tbody 的行(视口 1280,桌面档,不画展开行;空态那一行会被数成 1,而空表不是这里的对象)。
 */
async function exportAndCount(reader, path, fileName) {
    const page = await browser.newPage()
    await page.setViewport({ width: 1280, height: 900 })
    const cdp = await page.createCDPSession()
    const host = new URL(BASE).hostname
    await cdp.send('Network.setCookies', { cookies: [
        { name: reader.cookieName, value: reader.cookieValue, domain: host, path: '/' },
        { name: 'NEXT_LOCALE', value: 'en', domain: host, path: '/' },
    ] })
    const out = { status: null, bars: 0, screenRows: null, extra: null, files: {} }
    try {
        const res = await page.goto(BASE + path, { waitUntil: 'networkidle2', timeout: 120_000 })
        out.status = res?.status()
        if (out.status !== 200) return out
        const hydrated = await page.waitForFunction(() => {
            const b = document.querySelector('[data-slot="table-export"] button')
            return !!b && Object.keys(b).some((k) => k.startsWith('__react'))
        }, { timeout: 60_000 }).then(() => true, () => false)
        out.bars = await page.evaluate(() => document.querySelectorAll('[data-slot="table-export"]').length)
        out.extra = await page.evaluate(() => document.querySelector('[data-related-total]')?.getAttribute('data-related-total') ?? null)
        if (!hydrated) return out
        let barIdx = null
        for (const fmt of ['xlsx', 'csv']) {
            const dir = mkdtempSync(join(tmpdir(), `te3cc-${fileName}-${fmt}-`))
            await cdp.send('Browser.setDownloadBehavior', { behavior: 'allow', downloadPath: dir })
            const label = fmt === 'csv' ? 'Export CSV' : 'Export Excel'
            const re = new RegExp(`^${fileName}_\\d{4}-\\d{2}-\\d{2}_\\d{4}\\.${fmt}$`)
            const order = barIdx === null ? [...Array(out.bars).keys()] : [barIdx]
            let file = null
            for (const i of order) {
                await page.evaluate((label, i) => {
                    const bar = document.querySelectorAll('[data-slot="table-export"]')[i]
                    ;[...bar.querySelectorAll('button')].find((x) => x.textContent?.trim() === label)?.click()
                }, label, i)
                file = await waitForFile(dir, re, i === order[order.length - 1] ? 90_000 : 8_000)
                if (file) { barIdx = i; break }
            }
            if (!file) { out.files[fmt] = { err: `no file matching ${re}` }; continue }
            const rows = fmt === 'xlsx' ? await readXlsxRows(join(dir, file)) : parseCsv(readFileSync(join(dir, file), 'utf8'))
            out.files[fmt] = { file, dataRows: rows.length - 1 }
        }
        if (barIdx !== null) {
            out.screenRows = await page.evaluate((i) => {
                const bar = document.querySelectorAll('[data-slot="table-export"]')[i]
                // 钮在 DataTable 外壳的控件区里;同一个外壳里的那一张 <table> 就是它导出的那张
                const shell = bar.closest('[data-slot="table-export"]').parentElement.parentElement
                const t = shell.querySelector('table[data-slot="data-table"]')
                return t ? t.querySelectorAll(':scope > tbody > tr').length : null
            }, barIdx)
        }
        return out
    } finally { await page.close() }
}

async function main() {
    const other = heldBy()
    if (other) { console.error(`✗ live-lock 被【${other.holder}】(pid ${other.pid})占着`); return exitAfterCleanup(5) }
    acquireOrExit(SCRIPT, { ownExit: false })
    locked = true
    openPlan(SCRIPT)
    await reapStalePlans()

    if (!PUP_DIR || !existsSync(join(PUP_DIR, 'node_modules/puppeteer-core'))) throw new Error('TE3CC_DRIVER|PUPPETEER_DIR has no node_modules/puppeteer-core')
    const puppeteer = createRequire(join(PUP_DIR, 'package.json'))('puppeteer-core')
    const ver = readdirSync(CHROME_ROOT).sort().pop()
    const exe = join(CHROME_ROOT, ver, 'chrome-headless-shell-mac-arm64', 'chrome-headless-shell')
    if (!existsSync(exe)) throw new Error(`TE3CC_DRIVER|no chrome-headless-shell at ${exe}`)
    browser = await puppeteer.launch({ executablePath: exe, headless: true, args: ['--no-sandbox'] })
    console.log(`STEP|base ${BASE}`)

    // 看得见加工单与成品批(关联页的主语与目标各自的模块码)
    const reader = await mintThrowaway({ prefix: 'te3cprobe', label: 'closeout', stamp: Date.now(), codes: ['module.processing.view', 'module.output.view'] })

    // ① 加工单的产出表
    {
        const path = `/operation/processing/${RUN.id}`
        const r = await exportAndCount(reader, path, 'processing-run-outputs')
        ok(r.status === 200 && r.bars > 0, `${path} (${RUN.code}) → HTTP ${r.status}; ${r.bars} export pair(s) on the page (= 3c is deployed)`)
        for (const fmt of ['xlsx', 'csv']) {
            const f = r.files[fmt]
            ok(!!f && !f.err && r.screenRows != null && r.screenRows > 0 && f.dataRows === r.screenRows,
               `processing-run outputs · ${fmt}: ${f?.err ?? `${f?.file} — ${f?.dataRows} data rows`}; screen ${r.screenRows} rows`)
        }
    }
    // ② 关联页:这张加工单的成品批
    {
        const path = `/related/processing_run/${RUN.id}/output_batch`
        const r = await exportAndCount(reader, path, 'related-output-batch')
        const total = r.extra == null ? null : Number(r.extra)
        ok(r.status === 200 && r.bars > 0 && total != null && total > 0,
           `${path} → HTTP ${r.status}; ${r.bars} export pair(s); data-related-total ${r.extra}`)
        for (const fmt of ['xlsx', 'csv']) {
            const f = r.files[fmt]
            ok(!!f && !f.err && f.dataRows === total && f.dataRows === r.screenRows,
               `related output batches · ${fmt}: ${f?.err ?? `${f?.file} — ${f?.dataRows} data rows`}; screen ${r.screenRows} rows, total ${total}`)
        }
    }

    console.log(bad ? `STEP|done with ${bad} FAIL` : 'STEP|done')
    return finish(bad ? 1 : 0)
}

main().catch((e) => {
    console.error(String(e?.stack || e))
    return finish(String(e?.message || '').startsWith('TE3CC_DRIVER') ? 2 : 1)
})
