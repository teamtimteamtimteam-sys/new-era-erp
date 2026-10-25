#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// TABLE-EXPORT-3c Part 1.2 · TABLE-EXPORT-3b 收尾 —— 对着【生产】(Vercel)只读地看一眼
// ════════════════════════════════════════════════════════════════════════════
// 委托书 1.2:一个不持价格码的一次性账号把 PO-2026-0009 的明细导出(Excel 与 CSV),小计 / GST / 合计三行读作 "Restricted";
//            同一张单的付款条件里,预计日期那一格不再是「—」。然后收走账号,读回 0 残留。
//            明细表上方画着一对导出钮 = 生产跑的是 7fe03e1(3b)。
// ★ 预计日期:线上 24 条付款条件里有预计日期的是 0 条(以 postgres 读基表,2026-10-25),所以这里【证不了】"画出一个日期",
//   证得了的是 3b 修掉的那个缺陷不在了 —— 从前 formatDate(undefined) 吐出「—」,被当成日期值画在格子里;
//   现在没有估计日的一期画「not estimated yet」。判别臂在 PO-2026-0002(见 ③);PO-2026-0009 那一格分不出 3b 之前与之后。
// 只读:浏览器只发 GET 与点「导出」(文件在浏览器里生成,不写库)。
//      线上提交的只有一次性账号与它的授权(前缀 te3bprobe —— 这是 3b 的收尾,沿用 3b 的前缀,共用造号器),由清理计划收走。
// 判决只从最后一行 `TE3B_CLOSEOUT_EXIT=` 读:0 = 全 PASS 且收尾干净 · 1 = 有 FAIL · 2 = 驱动坏了 · 5 = live-lock 被占 · 6 = 收尾没完成。
// 用法:PROOF_BASE=https://new-era-erp.vercel.app PUPPETEER_DIR=<装着 puppeteer-core 的目录> node db/scripts/2026-10-25-table-export-3b-closeout-prod-check.mjs
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
const SCRIPT = 'db/scripts/2026-10-25-table-export-3b-closeout-prod-check.mjs'
// 与 3b 线上证明 R1 同一张单(带税、1 行、2 期付款条件)
const PO = { id: '14956797-c2ef-49a2-acbd-8b3eae2d79e0', code: 'PO-2026-0009' }
// 判别臂用的单:三期都挂在有保管人的事件上(on_shipment · on_arrival · post_assay),以 postgres 读基表,2026-10-25
const PO2 = { id: '79c9228c-5168-4add-97a0-44cff9e37993', code: 'PO-2026-0002' }
const R = 'Restricted'

let locked = false, bad = 0, browser = null
const ok = (cond, what) => { console.log(`${cond ? 'PASS' : 'FAIL'}|${what}`); if (!cond) bad++; return cond }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

installExitHooks({
    onFinish: (code) => {
        try { if (locked) release() } catch { /* 放锁失败不改判决 */ }
        console.log(`TE3B_CLOSEOUT_EXIT=${code}`)
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
    wb.worksheets[0].eachRow((row) => rows.push(row.values.slice(1).map((v) => (v && typeof v === 'object' && 'result' in v ? v.result : v))))
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

async function main() {
    const other = heldBy()
    if (other) { console.error(`✗ live-lock 被【${other.holder}】(pid ${other.pid})占着`); return exitAfterCleanup(5) }
    acquireOrExit(SCRIPT, { ownExit: false })
    locked = true
    openPlan(SCRIPT)
    await reapStalePlans()

    if (!PUP_DIR || !existsSync(join(PUP_DIR, 'node_modules/puppeteer-core'))) throw new Error('TE3BC_DRIVER|PUPPETEER_DIR has no node_modules/puppeteer-core')
    const puppeteer = createRequire(join(PUP_DIR, 'package.json'))('puppeteer-core')
    const ver = readdirSync(CHROME_ROOT).sort().pop()
    const exe = join(CHROME_ROOT, ver, 'chrome-headless-shell-mac-arm64', 'chrome-headless-shell')
    if (!existsSync(exe)) throw new Error(`TE3BC_DRIVER|no chrome-headless-shell at ${exe}`)
    browser = await puppeteer.launch({ executablePath: exe, headless: true, args: ['--no-sandbox'] })
    console.log(`STEP|base ${BASE}`)

    // 与 3b 证明 R1 的 poblind 同一组码:看得到采购单,不持任何价格码
    const poBlind = await mintThrowaway({ prefix: 'te3bprobe', label: 'closeout-poblind', stamp: Date.now(), codes: ['module.purchasing.view'] })

    const path = `/purchasing/orders/${PO.id}`
    const page = await browser.newPage()
    const cdp = await page.createCDPSession()
    const host = new URL(BASE).hostname
    await cdp.send('Network.setCookies', { cookies: [
        { name: poBlind.cookieName, value: poBlind.cookieValue, domain: host, path: '/' },
        { name: 'NEXT_LOCALE', value: 'en', domain: host, path: '/' },
    ] })
    try {
        const res = await page.goto(BASE + path, { waitUntil: 'networkidle2', timeout: 120_000 })
        const status = res?.status()
        const hydrated = await page.waitForFunction(() => {
            const b = document.querySelector('[data-slot="table-export"] button')
            return !!b && Object.keys(b).some((k) => k.startsWith('__react'))
        }, { timeout: 60_000 }).then(() => true, () => false)
        const bars = await page.evaluate(() => document.querySelectorAll('[data-slot="table-export"]').length)
        ok(status === 200 && hydrated && bars > 0, `${path} (${PO.code}) as a reader without price codes → HTTP ${status}; ${bars} export pair(s) on the page (= 3b is deployed)`)

        // ② 付款条件:预计日期那一列没有一格是「—」
        const terms = await page.evaluate(() => {
            for (const t of document.querySelectorAll('table')) {
                const hs = [...t.querySelectorAll('thead th')].map((th) => th.textContent?.trim() ?? '')
                const ei = hs.findIndex((h) => h === 'Expected date')
                if (ei < 0) continue
                return [...t.querySelectorAll('tbody tr')].map((tr) => [...tr.querySelectorAll('td')][ei]?.innerText?.replace(/\s+/g, ' ').trim() ?? null)
            }
            return null
        })
        ok(Array.isArray(terms) && terms.length === 2 && terms.every((c) => c && c !== '—' && !c.startsWith('— ')),
           `PO payment terms · Expected date cells ${JSON.stringify(terms)} (none is "—")`)

        // ① 明细导出:1 行 + 三行合计,三行合计读作 Restricted
        if (hydrated) {
            for (const fmt of ['xlsx', 'csv']) {
                const dir = mkdtempSync(join(tmpdir(), `te3bc-${fmt}-`))
                await cdp.send('Browser.setDownloadBehavior', { behavior: 'allow', downloadPath: dir })
                const label = fmt === 'csv' ? 'Export CSV' : 'Export Excel'
                const re = new RegExp(`^purchasing-order-lines_\\d{4}-\\d{2}-\\d{2}_\\d{4}\\.${fmt}$`)
                let file = null
                for (let i = 0; i < bars && !file; i++) {
                    await page.evaluate((label, i) => {
                        const bar = document.querySelectorAll('[data-slot="table-export"]')[i]
                        ;[...bar.querySelectorAll('button')].find((x) => x.textContent?.trim() === label)?.click()
                    }, label, i)
                    file = await waitForFile(dir, re, i === bars - 1 ? 90_000 : 8_000)
                }
                if (!ok(!!file, `PO lines ${fmt} downloaded${file ? `: ${file}` : ' — no file'}`)) continue
                const rows = fmt === 'xlsx' ? await readXlsxRows(join(dir, file)) : parseCsv(readFileSync(join(dir, file), 'utf8'))
                const head = rows[0], body = rows.slice(1)
                const last3 = body.slice(-3)
                const labels = last3.map((r) => r.find((v) => typeof v === 'string' && v !== '' && v !== R))
                const amounts = last3.map((r) => r[head.length - 1])
                ok(body.length === 4 && amounts.every((v) => v === R),
                   `PO lines ${fmt}: ${body.length} rows (1 line + 3 totals ${JSON.stringify(labels)}); total amounts ${JSON.stringify(amounts)}`)
            }
        }
    } finally { await page.close() }

    // ③ 判别臂:PO-2026-0009 的两期(on_order · acceptance_complete)在 payment_event_owners 里没有保管人,
    //   于是控件在 3b 之前与之后都画「不需要估计」那一句 —— 上面那一格【分不出】3b 修没修。
    //   PO-2026-0002 的三期(on_shipment · on_arrival · post_assay)都有保管人:3b 之前那三格画的是「—」(formatDate 的空值),
    //   3b 之后不持编辑码的读者读到「not estimated yet」。
    {
        const p2 = await browser.newPage()
        const c2 = await p2.createCDPSession()
        await c2.send('Network.setCookies', { cookies: [
            { name: poBlind.cookieName, value: poBlind.cookieValue, domain: host, path: '/' },
            { name: 'NEXT_LOCALE', value: 'en', domain: host, path: '/' },
        ] })
        try {
            const res = await p2.goto(`${BASE}/purchasing/orders/${PO2.id}`, { waitUntil: 'networkidle2', timeout: 120_000 })
            const cells = await p2.evaluate(() => {
                for (const t of document.querySelectorAll('table')) {
                    const hs = [...t.querySelectorAll('thead th')].map((th) => th.textContent?.trim() ?? '')
                    const ei = hs.findIndex((h) => h === 'Expected date')
                    if (ei < 0) continue
                    return [...t.querySelectorAll('tbody tr')].map((tr) => [...tr.querySelectorAll('td')][ei]?.innerText?.replace(/\s+/g, ' ').trim() ?? null)
                }
                return null
            })
            ok(res?.status() === 200 && Array.isArray(cells) && cells.length === 3 && cells.every((c) => c?.startsWith('not estimated yet')),
               `${PO2.code} payment terms (owned events) · Expected date cells ${JSON.stringify(cells)} (each "not estimated yet", none "—")`)
        } finally { await p2.close() }
    }

    console.log(bad ? `STEP|done with ${bad} FAIL` : 'STEP|done')
    return finish(bad ? 1 : 0)
}

main().catch((e) => {
    console.error(String(e?.stack || e))
    return finish(String(e?.message || '').startsWith('TE3BC_DRIVER') ? 2 : 1)
})
