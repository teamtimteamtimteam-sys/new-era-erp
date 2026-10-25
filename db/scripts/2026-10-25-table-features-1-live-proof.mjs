#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// TABLE-FEATURES-1(Tim 2026-10-25)· 线上证明 —— 真浏览器读屏幕、点表头、按「导出」读回文件;读库的那几句只数行(以 postgres 读基表)
// ════════════════════════════════════════════════════════════════════════════
// 委托书(Step 1 的线上证明):
//   J  一张【在数据库里排】的列表,两个方向、跨页:/finance/journal 按编号升序把每一页读完、再降序把每一页读完 ——
//      升序拼起来是有序的、等于降序拼起来倒过来、行数 = 页面自己报的总数;按降序导出的 CSV 与屏幕降序逐行同序。
//   B  一张【在浏览器里排】的列表:/inventory/locations 点编号表头 → 升序;再点 → 降序(两个读数互为倒序,且各自有序)。
//   E  一份【结束了的记录】上排序与导出照样能用:删掉的产出批 OUT-2026-0248 的库存流水坐在结束块(`<fieldset disabled>`)里 ——
//      表头点得下去(顺序反过来),Excel 与 CSV 都落下来,行数 = 那一批的 inventory_movements;同一块里的写入控件仍然是禁用的。
//   S  粘性表头:桌面(1280×800)上一张比屏幕高的表(/finance/journal)表头是 sticky,把它的盒子往下滚 300px,表头仍贴在盒子顶上;
//      390×844 上表头不是 sticky,盒子没有高度上界。
//   P  付款按收付日排(Q7):/finance/payments 不带参数时,屏幕上的编号顺序 = 库里 payment_date desc, created_at desc, id 的顺序。
// 只读:浏览器只发 GET、点表头(在浏览器里排 / 换地址)与点「导出」(文件在浏览器里生成);线上提交的只有一次性账号与它们的授权
// (前缀 tf1probe,共用造号器),由清理计划收走。
// 判决只从最后一行 `TF1_PROOF_EXIT=` 读:0 = 全 PASS 且收尾干净 · 1 = 有 FAIL · 2 = 驱动坏了 · 5 = live-lock 被占 · 6 = 收尾没完成。
// 用法:PROOF_BASE=http://localhost:3197 PUPPETEER_DIR=<装着 puppeteer-core 的目录> node db/scripts/2026-10-25-table-features-1-live-proof.mjs
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
const SCRIPT = 'db/scripts/2026-10-25-table-features-1-live-proof.mjs'
// 删掉的产出批(以 postgres 读基表,2026-10-25:deleted_at 非空,inventory_movements 5 行)
const OUT = { id: '51f935b6-7aca-4395-b357-ac1fb58bed95', code: 'OUT-2026-0248' }
const JOURNAL_CODE_KEY = process.env.JOURNAL_CODE_KEY || 'code'

let locked = false, bad = 0, browser = null
const ok = (cond, what) => { console.log(`${cond ? 'PASS' : 'FAIL'}|${what}`); if (!cond) bad++; return cond }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const en = (a, b) => a.localeCompare(b, 'en', { numeric: true })
const isSorted = (xs, dir) => xs.every((x, i) => i === 0 || (dir === 'asc' ? en(xs[i - 1], x) <= 0 : en(xs[i - 1], x) >= 0))

installExitHooks({
    onFinish: (code) => {
        try { if (locked) release() } catch { /* 放锁失败不改判决 */ }
        console.log('AFTER|nothing but the throwaway accounts and their grants was committed (removed by the plan); the only database reads were row counts and orders as postgres (base tables)')
        console.log(`TF1_PROOF_EXIT=${code}`)
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

function psql(sql) {
    const r = spawnSync('psql', [DSN, '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-f', '-'], { input: sql, encoding: 'utf8', timeout: 120_000 })
    if (r.status !== 0) throw new Error(`TF1_DRIVER|psql exit ${r.status}: ${(r.stderr ?? '').split('\n').slice(-4).join(' / ')}`)
    return (r.stdout ?? '').split('\n').filter((l) => l.startsWith('PROOF|')).map((l) => l.slice(6))
}

async function finish(code) {
    try { if (browser) await browser.close() } catch { /* 不改判决 */ }
    browser = null
    return exitAfterCleanup(code)
}

async function openAs(reader, path, viewport = { width: 1280, height: 800 }) {
    const page = await browser.newPage()
    await page.setViewport(viewport)
    const cdp = await page.createCDPSession()
    const host = new URL(BASE).hostname
    await cdp.send('Network.setCookies', { cookies: [
        { name: reader.cookieName, value: reader.cookieValue, domain: host, path: '/' },
        { name: 'NEXT_LOCALE', value: 'en', domain: host, path: '/' },
    ] })
    const res = await page.goto(BASE + path, { waitUntil: 'networkidle2', timeout: 120_000 })
    await page.waitForFunction(() => {
        const b = document.querySelector('table[data-slot="data-table"]')
        return !!b && Object.keys(document.querySelector('[data-slot="table-export"] button, [data-slot="table-export"] [role="button"]') ?? {}).some((k) => k.startsWith('__react'))
    }, { timeout: 60_000 }).catch(() => {})
    return { page, cdp, status: res?.status() }
}

/** 第 `ti` 张 DataTable 里,表头带 data-sort-key=key 的那一列,在 tbody 每一行里的文字。 */
async function columnText(page, key, ti = 0) {
    return page.evaluate((key, ti) => {
        const t = document.querySelectorAll('table[data-slot="data-table"]')[ti]
        if (!t) return null
        const ths = [...t.querySelectorAll(':scope > thead > tr > th')]
        const ci = ths.findIndex((th) => th.querySelector(`[data-sort-key="${key}"]`))
        if (ci < 0) return null
        return [...t.querySelectorAll(':scope > tbody > tr')].filter((tr) => !tr.classList.contains('sm:hidden'))
            .map((tr) => tr.querySelectorAll(':scope > td')[ci]?.innerText?.trim() ?? null)
    }, key, ti)
}

async function main() {
    const other = heldBy()
    if (other) { console.error(`✗ live-lock 被【${other.holder}】(pid ${other.pid})占着`); return exitAfterCleanup(5) }
    acquireOrExit(SCRIPT, { ownExit: false })
    locked = true
    openPlan(SCRIPT)
    await reapStalePlans()

    if (!PUP_DIR || !existsSync(join(PUP_DIR, 'node_modules/puppeteer-core'))) throw new Error('TF1_DRIVER|PUPPETEER_DIR has no node_modules/puppeteer-core')
    const puppeteer = createRequire(join(PUP_DIR, 'package.json'))('puppeteer-core')
    const ver = readdirSync(CHROME_ROOT).sort().pop()
    const exe = join(CHROME_ROOT, ver, 'chrome-headless-shell-mac-arm64', 'chrome-headless-shell')
    if (!existsSync(exe)) throw new Error(`TF1_DRIVER|no chrome-headless-shell at ${exe}`)
    try { const r = await fetch(BASE + '/login', { redirect: 'manual' }); if (r.status !== 200) throw new Error(`HTTP ${r.status}`) }
    catch (e) { throw new Error(`TF1_DRIVER|no app at ${BASE}: ${e.message}`) }
    browser = await puppeteer.launch({ executablePath: exe, headless: true, args: ['--no-sandbox'] })

    const db = psql(`
        SELECT 'PROOF|journal=' || (SELECT count(*) FROM journal_entries);
        SELECT 'PROOF|outmov=' || (SELECT count(*) FROM inventory_movements WHERE output_batch_id = '${OUT.id}');
        SELECT 'PROOF|outdeleted=' || (SELECT (deleted_at IS NOT NULL)::text FROM output_batches WHERE id = '${OUT.id}');
        SELECT 'PROOF|payorder=' || (SELECT string_agg(code, ',' ORDER BY payment_date DESC, created_at DESC, id) FROM payments);
    `)
    const kv = Object.fromEntries(db.map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1)]))
    console.log(`STEP|database as postgres (base tables): journal_entries ${kv.journal} · ${OUT.code} movements ${kv.outmov}, deleted ${kv.outdeleted} · payments order ${kv.payorder}`)

    const stamp = Date.now()
    const finance = await mintThrowaway({ prefix: 'tf1probe', label: 'finance', stamp, codes: ['module.finance.view'] })
    const inventory = await mintThrowaway({ prefix: 'tf1probe', label: 'inventory', stamp, codes: ['module.inventory.view'] })
    const batches = await mintThrowaway({ prefix: 'tf1probe', label: 'output', stamp, codes: ['module.output.view', 'module.inventory.view'] })

    // ── J · 在数据库里排,两个方向、跨页 ─────────────────────────────────────
    {
        const read = async (dir) => {
            const all = []; let total = null
            for (let p = 1; p <= 20; p++) {
                const { page, status } = await openAs(finance, `/finance/journal?sort=${JOURNAL_CODE_KEY}&dir=${dir}&page=${p}`)
                try {
                    if (status !== 200) throw new Error(`TF1_DRIVER|journal page ${p} HTTP ${status}`)
                    const codes = await columnText(page, JOURNAL_CODE_KEY)
                    if (!codes) throw new Error(`TF1_DRIVER|journal has no header with data-sort-key=${JOURNAL_CODE_KEY}`)
                    if (total === null) total = await page.evaluate(() => {
                        const m = document.body.innerText.match(/Page \d+ of (\d+)/)
                        return m ? Number(m[1]) : null
                    })
                    all.push(...codes)
                    if (total !== null && p >= total) break
                } finally { await page.close() }
            }
            return { all, pages: total }
        }
        const asc = await read('asc'), desc = await read('desc')
        ok(asc.pages > 1 && asc.all.length === Number(kv.journal) && isSorted(asc.all, 'asc'),
           `J /finance/journal ascending by code over ${asc.pages} pages: ${asc.all.length} rows (journal_entries ${kv.journal}), in order; first ${asc.all[0]} … last ${asc.all.at(-1)}`)
        ok(desc.all.length === asc.all.length && JSON.stringify(desc.all) === JSON.stringify([...asc.all].reverse()),
           `J descending over ${desc.pages} pages is the ascending list reversed (first ${desc.all[0]} … last ${desc.all.at(-1)})`)
        // 降序导出 = 屏幕降序
        const { page, cdp } = await openAs(finance, `/finance/journal?sort=${JOURNAL_CODE_KEY}&dir=desc`)
        try {
            const dir = mkdtempSync(join(tmpdir(), 'tf1-journal-'))
            await cdp.send('Browser.setDownloadBehavior', { behavior: 'allow', downloadPath: dir })
            await page.evaluate(() => [...document.querySelectorAll('[data-slot="table-export"] button')].find((b) => b.textContent?.trim() === 'Export CSV')?.click())
            const f = await waitForFile(dir, /\.csv$/, 90_000)
            const rows = f ? parseCsv(readFileSync(join(dir, f), 'utf8')) : []
            const ci = rows[0]?.findIndex((h) => /code/i.test(h)) ?? -1
            const fileCodes = rows.slice(1).map((r) => r[ci])
            ok(!!f && ci >= 0 && JSON.stringify(fileCodes) === JSON.stringify(desc.all),
               `J export CSV of the descending list: ${f ?? 'no file'} — ${fileCodes.length} rows in the screen's descending order`)
        } finally { await page.close() }
    }

    // ── B · 在浏览器里排 ────────────────────────────────────────────────────
    {
        const { page, status } = await openAs(inventory, '/inventory/locations')
        try {
            const keys = await page.evaluate(() => [...document.querySelectorAll('table[data-slot="data-table"] thead [data-sort-key]')].map((e) => e.getAttribute('data-sort-key')))
            const key = keys.includes('code') ? 'code' : keys[0]
            const before = await columnText(page, key)
            await page.click(`table[data-slot="data-table"] thead [data-sort-key="${key}"]`)
            const asc = await columnText(page, key)
            await page.click(`table[data-slot="data-table"] thead [data-sort-key="${key}"]`)
            const desc = await columnText(page, key)
            ok(status === 200 && asc?.length >= 2 && isSorted(asc, 'asc') && isSorted(desc, 'desc') && JSON.stringify(desc) === JSON.stringify([...asc].reverse()),
               `B /inventory/locations sorted in the browser by "${key}" (sortable headers ${JSON.stringify(keys)}): before ${JSON.stringify(before)} → asc ${JSON.stringify(asc)} → desc ${JSON.stringify(desc)}`)
        } finally { await page.close() }
    }

    // ── E · 结束了的记录上:排序与导出 ───────────────────────────────────────
    {
        const path = `/output/${OUT.id}/edit`
        const { page, cdp, status } = await openAs(batches, path)
        try {
            const facts = await page.evaluate(() => {
                const fs = document.querySelector('fieldset[data-ended-readonly]')
                const t = fs ? [...fs.querySelectorAll('table[data-slot="data-table"]')].find((x) => x.querySelector('[data-sort-key]')) : null
                const sortCtl = t?.querySelector('thead [data-sort-key]')
                const bar = t?.closest('[data-table-box]')?.parentElement?.querySelector('[data-slot="table-export"]')
                const writes = fs ? [...fs.querySelectorAll('button, input, select, textarea')].filter((e) => !e.closest('[data-slot="table-export"]')) : []
                return {
                    ended: !!fs && fs.disabled,
                    sortTag: sortCtl?.tagName ?? null, sortRole: sortCtl?.getAttribute('role') ?? null,
                    exportTags: bar ? [...bar.children].map((c) => `${c.tagName}${c.getAttribute('role') ? '[' + c.getAttribute('role') + ']' : ''}`) : [],
                    writeControls: writes.length, writeEnabled: writes.filter((e) => e.matches(':enabled')).length,
                    tableIndex: t ? [...document.querySelectorAll('table[data-slot="data-table"]')].indexOf(t) : -1,
                    sortKey: sortCtl?.getAttribute('data-sort-key') ?? null,
                }
            })
            ok(status === 200 && facts.ended && facts.sortRole === 'button' && facts.sortTag === 'SPAN' && facts.writeControls > 0 && facts.writeEnabled === 0
               && facts.exportTags.length === 2 && facts.exportTags.every((x) => x === 'SPAN[button]'),
               `E ${path} (${OUT.code}, deleted): ended block disabled; the movements table's sort header is a <span role=button> (fieldset cannot disable it); export bar ${JSON.stringify(facts.exportTags)}; write controls in the block ${facts.writeControls}, enabled ${facts.writeEnabled}`)
            if (facts.tableIndex >= 0) {
                const before = await columnText(page, facts.sortKey, facts.tableIndex)
                const sel = `table[data-slot="data-table"] thead [data-sort-key="${facts.sortKey}"]`
                await page.evaluate((sel, ti) => document.querySelectorAll('table[data-slot="data-table"]')[ti].querySelector(sel.split(' ').slice(-1)[0]).click(), sel, facts.tableIndex)
                const a = await columnText(page, facts.sortKey, facts.tableIndex)
                await page.evaluate((sel, ti) => document.querySelectorAll('table[data-slot="data-table"]')[ti].querySelector(sel.split(' ').slice(-1)[0]).click(), sel, facts.tableIndex)
                const d = await columnText(page, facts.sortKey, facts.tableIndex)
                ok(a?.length === Number(kv.outmov) && JSON.stringify(d) === JSON.stringify([...a].reverse()) && JSON.stringify(a) !== JSON.stringify(d),
                   `E sorting inside the ended block by "${facts.sortKey}": ${a?.length} rows (= ${kv.outmov} movements); before ${JSON.stringify(before)} → asc ${JSON.stringify(a)} → desc ${JSON.stringify(d)}`)
                for (const fmt of ['xlsx', 'csv']) {
                    const dir = mkdtempSync(join(tmpdir(), `tf1-ended-${fmt}-`))
                    await cdp.send('Browser.setDownloadBehavior', { behavior: 'allow', downloadPath: dir })
                    const label = fmt === 'csv' ? 'Export CSV' : 'Export Excel'
                    await page.evaluate((ti, label) => {
                        const t = document.querySelectorAll('table[data-slot="data-table"]')[ti]
                        const bar = t.closest('[data-table-box]').parentElement.querySelector('[data-slot="table-export"]')
                        ;[...bar.querySelectorAll('[role="button"], button')].find((x) => x.textContent?.trim() === label)?.click()
                    }, facts.tableIndex, label)
                    const f = await waitForFile(dir, new RegExp(`^batch-movements_.*\\.${fmt}$`), 90_000)
                    let n = null
                    if (f && fmt === 'csv') n = parseCsv(readFileSync(join(dir, f), 'utf8')).length - 1
                    if (f && fmt === 'xlsx') { const wb = new ExcelJS.Workbook(); await wb.xlsx.readFile(join(dir, f)); n = wb.worksheets[0].rowCount - 1 }
                    ok(!!f && n === Number(kv.outmov), `E export ${fmt} on the ended record: ${f ?? 'no file'} — ${n} rows (= ${kv.outmov} movements)`)
                }
            }
        } finally { await page.close() }
    }

    // ── S · 粘性表头:桌面有,390 没有 ───────────────────────────────────────
    for (const [label, vp, expectSticky] of [['desktop 1280×800', { width: 1280, height: 800 }, true], ['phone 390×844', { width: 390, height: 844 }, false]]) {
        const { page } = await openAs(finance, '/finance/journal', vp)
        try {
            const r = await page.evaluate(async () => {
                const t = document.querySelector('table[data-slot="data-table"]')
                const box = t.closest('[data-table-box]')
                const th = [...t.querySelectorAll('thead th')].find((x) => getComputedStyle(x).display !== 'none')
                const pos = getComputedStyle(th).position
                const maxH = getComputedStyle(box).maxHeight
                const tall = box.scrollHeight > box.clientHeight
                box.scrollTop = 300
                await new Promise((r) => setTimeout(r, 200))
                const gap = Math.round(th.getBoundingClientRect().top - box.getBoundingClientRect().top)
                return { pos, maxH, tall, scrolled: box.scrollTop, gap }
            })
            if (expectSticky) ok(r.pos === 'sticky' && r.tall && r.scrolled > 0 && Math.abs(r.gap) <= 1,
                `S ${label} /finance/journal: header position ${r.pos}, box max-height ${r.maxH}, table taller than its box ${r.tall}; box scrolled ${r.scrolled}px and the header sits ${r.gap}px from the box top`)
            else ok(r.pos !== 'sticky' && r.maxH === 'none',
                `S ${label} /finance/journal: header position ${r.pos} (not sticky), box max-height ${r.maxH}`)
        } finally { await page.close() }
    }

    // ── P · 付款按收付日 ─────────────────────────────────────────────────────
    {
        const { page, status } = await openAs(finance, '/finance/payments')
        try {
            const codes = await columnText(page, 'code')
            const want = (kv.payorder ?? '').split(',').filter(Boolean)
            ok(status === 200 && codes?.length === want.length && JSON.stringify(codes) === JSON.stringify(want),
               `P /finance/payments default order = payment_date desc, created_at desc, id: screen ${JSON.stringify(codes)} · database ${JSON.stringify(want)}`)
        } finally { await page.close() }
    }

    console.log(bad ? `STEP|done with ${bad} FAIL` : 'STEP|done')
    return finish(bad ? 1 : 0)
}

main().catch((e) => {
    console.error(String(e?.stack || e))
    return finish(String(e?.message || '').startsWith('TF1_DRIVER') ? 2 : 1)
})
