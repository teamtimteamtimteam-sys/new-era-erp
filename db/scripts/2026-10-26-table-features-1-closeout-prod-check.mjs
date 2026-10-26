#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// TABLE-FEATURES-2 Part 1.2 · TABLE-FEATURES-1 收尾 —— 对着【生产】(Vercel)只读地看一眼
// ════════════════════════════════════════════════════════════════════════════
// 委托书 1.2:一个一次性 finance 账号在 /finance/journal 上按日期两个方向排(第一行变了),
//   并打开一张删掉的产出批,它的导出照样按得下去;然后收走账号,读回 0 残留。
//   ① /finance/journal:日期表头是一条排序链接(= 生产跑的是 a27417a);默认日期降序 → 点一次升序 → 再点一次降序;
//      两次点击各自换了地址(?sort=date&dir=…),每一次屏幕上的日期都有序,而第一行在升序与降序之间变了。
//   ② /output/<OUT-2026-0248>/edit(已删):HTTP 200;结束块是禁用的;移动表的导出钮是 <span role=button>,
//      按下去 Excel 与 CSV 都落下来,行数 = 屏幕上那张表的行数。导出在浏览器里生成,没有单独的 HTTP 回应 —— 照直报。
// 只读:浏览器只发 GET、点表头(换地址)与点「导出」。线上提交的只有一次性账号与它的授权
//      (前缀 tf1probe —— 这是 TF-1 的收尾,沿用 TF-1 的前缀,与 3c 收尾沿用 te3cprobe 同一个先例),由清理计划收走。
// 判决只从最后一行 `TF1_CLOSEOUT_EXIT=` 读:0 = 全 PASS 且收尾干净 · 1 = 有 FAIL · 2 = 驱动坏了 · 5 = live-lock 被占 · 6 = 收尾没完成。
// 用法:PROOF_BASE=https://new-era-erp.vercel.app PUPPETEER_DIR=<装着 puppeteer-core 的目录> node db/scripts/2026-10-26-table-features-1-closeout-prod-check.mjs
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
const SCRIPT = 'db/scripts/2026-10-26-table-features-1-closeout-prod-check.mjs'
// 与 TF-1 线上证明 E 同一张删掉的产出批(以 postgres 读基表,2026-10-25:deleted_at 非空,inventory_movements 5 行)
const OUT = { id: '51f935b6-7aca-4395-b357-ac1fb58bed95', code: 'OUT-2026-0248' }

let locked = false, bad = 0, browser = null
const ok = (cond, what) => { console.log(`${cond ? 'PASS' : 'FAIL'}|${what}`); if (!cond) bad++; return cond }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
// 屏幕上的日期是 DD/MM/YYYY;比较前换成 YYYYMMDD(第一轮按字符串比,是探针的错 —— closeout-prod-check-run1-probe-faults.txt)
const ymd = (s) => { const m = /^(\d{2})\/(\d{2})\/(\d{4})$/.exec(s ?? ''); return m ? m[3] + m[2] + m[1] : null }
const ordered = (xs, dir) => { const ys = xs.map(ymd); return ys.every((y) => y) && ys.every((x, i) => i === 0 || (dir === 'asc' ? ys[i - 1] <= x : ys[i - 1] >= x)) }

installExitHooks({
    onFinish: (code) => {
        try { if (locked) release() } catch { /* 放锁失败不改判决 */ }
        console.log(`TF1_CLOSEOUT_EXIT=${code}`)
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

async function openAs(reader, path) {
    const page = await browser.newPage()
    await page.setViewport({ width: 1280, height: 800 })
    const cdp = await page.createCDPSession()
    const host = new URL(BASE).hostname
    await cdp.send('Network.setCookies', { cookies: [
        { name: reader.cookieName, value: reader.cookieValue, domain: host, path: '/' },
        { name: 'NEXT_LOCALE', value: 'en', domain: host, path: '/' },
    ] })
    const res = await page.goto(BASE + path, { waitUntil: 'networkidle2', timeout: 120_000 })
    await page.waitForFunction(() => {
        const b = document.querySelector('[data-slot="table-export"] button, [data-slot="table-export"] [role="button"]')
        return !!b && Object.keys(b).some((k) => k.startsWith('__react'))
    }, { timeout: 60_000 }).catch(() => {})
    return { page, cdp, status: res?.status() }
}

/** 第一张 DataTable 里 code 与 date 两列每一行的文字,外加日期表头的 aria-sort。 */
async function journalRead(page) {
    return page.evaluate(() => {
        const t = document.querySelector('table[data-slot="data-table"]')
        if (!t) return null
        const ths = [...t.querySelectorAll(':scope > thead > tr > th')]
        const ix = (k) => ths.findIndex((th) => th.querySelector(`[data-sort-key="${k}"]`))
        const ci = ix('code'), di = ix('date')
        const link = t.querySelector('thead [data-sort-key="date"]')
        const rows = [...t.querySelectorAll(':scope > tbody > tr')].filter((tr) => !tr.classList.contains('sm:hidden'))
        return {
            dateLinkTag: link?.tagName ?? null,
            ariaSort: di >= 0 ? ths[di].getAttribute('aria-sort') : null,
            codes: rows.map((tr) => tr.querySelectorAll(':scope > td')[ci]?.innerText?.trim() ?? null),
            dates: rows.map((tr) => tr.querySelectorAll(':scope > td')[di]?.innerText?.trim() ?? null),
            url: location.pathname + location.search,
        }
    })
}

async function main() {
    const other = heldBy()
    if (other) { console.error(`✗ live-lock 被【${other.holder}】(pid ${other.pid})占着`); return exitAfterCleanup(5) }
    acquireOrExit(SCRIPT, { ownExit: false })
    locked = true
    openPlan(SCRIPT)
    await reapStalePlans()

    if (!PUP_DIR || !existsSync(join(PUP_DIR, 'node_modules/puppeteer-core'))) throw new Error('TF1C_DRIVER|PUPPETEER_DIR has no node_modules/puppeteer-core')
    const puppeteer = createRequire(join(PUP_DIR, 'package.json'))('puppeteer-core')
    const ver = readdirSync(CHROME_ROOT).sort().pop()
    const exe = join(CHROME_ROOT, ver, 'chrome-headless-shell-mac-arm64', 'chrome-headless-shell')
    if (!existsSync(exe)) throw new Error(`TF1C_DRIVER|no chrome-headless-shell at ${exe}`)
    browser = await puppeteer.launch({ executablePath: exe, headless: true, args: ['--no-sandbox'] })
    console.log(`STEP|base ${BASE}`)

    // 一个 finance 账号;删掉的产出批要 output + inventory 两个模块码(与 TF-1 证明 E 的 output 账号同一组码)
    const reader = await mintThrowaway({ prefix: 'tf1probe', label: 'closeout', stamp: Date.now(),
        codes: ['module.finance.view', 'module.output.view', 'module.inventory.view'] })

    // ① 日记账按日期两个方向
    {
        const { page, status } = await openAs(reader, '/finance/journal')
        try {
            const r0 = await journalRead(page)
            ok(status === 200 && r0?.dateLinkTag === 'A', `/finance/journal → HTTP ${status}; the date header is a sort link (${r0?.dateLinkTag}) = a27417a is deployed; default aria-sort ${r0?.ariaSort}`)
            if (r0?.dateLinkTag === 'A') {
                const reads = []
                for (const want of ['asc', 'desc']) {
                    await Promise.all([page.waitForNavigation({ waitUntil: 'networkidle2', timeout: 120_000 }).catch(() => {}),
                        page.click('table[data-slot="data-table"] thead a[data-sort-key="date"]')])
                    await page.waitForFunction((w) => location.search.includes(`dir=${w}`), { timeout: 60_000 }, want).catch(() => {})
                    await sleep(500)
                    const r = await journalRead(page)
                    reads.push(r)
                    ok(r?.url.includes('sort=date') && r.url.includes(`dir=${want}`) && r.dates.length > 1 && ordered(r.dates, want),
                       `click date header → ${r?.url}; aria-sort ${r?.ariaSort}; ${r?.dates.length} rows, dates ${want} in order; first row ${r?.codes[0]} ${r?.dates[0]}`)
                }
                const [a, d] = reads
                ok(a && d && a.codes[0] !== d.codes[0], `first row changes between ascending (${a?.codes[0]} ${a?.dates[0]}) and descending (${d?.codes[0]} ${d?.dates[0]})`)
            }
        } finally { await page.close() }
    }

    // ② 删掉的产出批上的导出
    {
        const path = `/output/${OUT.id}/edit`
        const { page, cdp, status } = await openAs(reader, path)
        try {
            const f = await page.evaluate(() => {
                const fs = document.querySelector('fieldset[data-ended-readonly]')
                const t = fs ? [...fs.querySelectorAll('table[data-slot="data-table"]')].find((x) => x.querySelector('[data-sort-key]')) : null
                const bar = t?.closest('[data-table-box]')?.parentElement?.querySelector('[data-slot="table-export"]')
                return {
                    ended: !!fs && fs.disabled,
                    exportTags: bar ? [...bar.children].map((c) => `${c.tagName}${c.getAttribute('role') ? '[' + c.getAttribute('role') + ']' : ''}`) : [],
                    tableIndex: t ? [...document.querySelectorAll('table[data-slot="data-table"]')].indexOf(t) : -1,
                    screenRows: t ? [...t.querySelectorAll(':scope > tbody > tr')].filter((tr) => !tr.classList.contains('sm:hidden')).length : null,
                }
            })
            ok(status === 200 && f.ended && f.exportTags.length === 2 && f.exportTags.every((x) => x === 'SPAN[button]'),
               `${path} (${OUT.code}, deleted) → HTTP ${status}; ended block disabled ${f.ended}; export bar ${JSON.stringify(f.exportTags)}; movements on screen ${f.screenRows}`)
            if (f.tableIndex >= 0) {
                for (const fmt of ['xlsx', 'csv']) {
                    const dir = mkdtempSync(join(tmpdir(), `tf1c-ended-${fmt}-`))
                    await cdp.send('Browser.setDownloadBehavior', { behavior: 'allow', downloadPath: dir })
                    const label = fmt === 'csv' ? 'Export CSV' : 'Export Excel'
                    await page.evaluate((ti, label) => {
                        const t = document.querySelectorAll('table[data-slot="data-table"]')[ti]
                        const bar = t.closest('[data-table-box]').parentElement.querySelector('[data-slot="table-export"]')
                        ;[...bar.querySelectorAll('[role="button"], button')].find((x) => x.textContent?.trim() === label)?.click()
                    }, f.tableIndex, label)
                    const file = await waitForFile(dir, new RegExp(`^batch-movements_.*\\.${fmt}$`), 90_000)
                    let n = null
                    if (file && fmt === 'csv') n = parseCsv(readFileSync(join(dir, file), 'utf8')).length - 1
                    if (file && fmt === 'xlsx') { const wb = new ExcelJS.Workbook(); await wb.xlsx.readFile(join(dir, file)); n = wb.worksheets[0].rowCount - 1 }
                    ok(!!file && n === f.screenRows && n > 0, `export ${fmt} on the deleted batch (generated in the browser, no separate HTTP response): ${file ?? 'no file'} — ${n} rows (screen ${f.screenRows})`)
                }
            }
        } finally { await page.close() }
    }

    console.log(bad ? `STEP|done with ${bad} FAIL` : 'STEP|done')
    return finish(bad ? 1 : 0)
}

main().catch((e) => {
    console.error(String(e?.stack || e))
    return finish(String(e?.message || '').startsWith('TF1C_DRIVER') ? 2 : 1)
})
