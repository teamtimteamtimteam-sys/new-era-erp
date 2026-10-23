#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// TABLE-EXPORT-2b-2(Tim 2026-10-23)· 线上证明 —— 真浏览器读屏幕、按下「导出」读回文件;读库的那几句一律在回滚的事务里
// ════════════════════════════════════════════════════════════════════════════
// 委托书:
//   I  /operation/capture/inbox:线上 ingest_inbox 2,005 行,过了旧的 200 行上限。第 1 页 200 行、第 2 页是另外 200 行(编号全部更小)、
//      翻页那一句说「Page 1 of ⌈N/200⌉ · N messages」(N 以 postgres 读基表);最后一页的行数 = N − 200 ×(页数 − 1);
//      导出 CSV 与 Excel 的行数 = N(导出前后各数一次,收件箱在这期间若收到新消息,落在两次之间也算对)。
//   R  看不见采购价的读者(purchasing / inbound / inventory 的查看码,不持 data.view_purchase_prices 与 data.view_prices)在 7 处假值里的几处
//      看到「Restricted」,对照读者(再加两个价格码)看到数:
//        R1 PO 头卡币种「USD @ Restricted」,不是「@ null」· R2 付款计划每一期金额「Restricted」,不是「0.00」·
//        R3 收货单价「Restricted」,不是「Unpriced」· R4 /inbound 的「未计价」一句说受限,不是一个数 · R5 /inventory/output/<物料> 成本合计「Restricted」,不是「0.00」。
//   N  /notifications 那一句「N unread」与顶栏徽标 = 库里的数:以一次性账号的身份(request.jwt.claims,SET LOCAL ROLE authenticated)
//      数「看得见的通知 − 自己读过而仍看得见的」,一笔事务,ROLLBACK。
// 只读:浏览器只发 GET 与点「导出」;线上提交的只有一次性账号与它们的授权(前缀 te2b2probe,共用造号器),由清理计划收走。
// 判决只从最后一行 `TE2B2_PROOF_EXIT=` 读:0 = 全 PASS 且收尾干净 · 1 = 有 FAIL · 2 = 驱动坏了 · 5 = live-lock 被占 · 6 = 收尾没完成。
// 用法:PROOF_BASE=http://localhost:3197 PUPPETEER_DIR=<装着 puppeteer-core 的目录> node db/scripts/2026-10-23-table-export-2b2-live-proof.mjs
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
const SCRIPT = 'db/scripts/2026-10-23-table-export-2b2-live-proof.mjs'

let locked = false, bad = 0, browser = null
const ok = (cond, what) => { console.log(`${cond ? 'PASS' : 'FAIL'}|${what}`); if (!cond) bad++; return cond }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

installExitHooks({
    onFinish: (code) => {
        try { if (locked) release() } catch { /* 放锁失败不改判决 */ }
        console.log('AFTER|nothing but the throwaway accounts and their grants was committed (removed by the plan); every database read as a throwaway ran in a transaction that was rolled back')
        console.log(`TE2B2_PROOF_EXIT=${code}`)
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

/** 在 `path` 上按名字为 `name` 的那张表的导出钮;`fileName` 是 Q9 的文件名前缀。 */
async function exportOnce(reader, path, fileName, fmt) {
    const dir = mkdtempSync(join(tmpdir(), `te2b2-${fileName}-${fmt}-`))
    const { page, cdp, status } = await openAs(reader, path)
    try {
        if (status !== 200) return { err: `HTTP ${status}` }
        await cdp.send('Browser.setDownloadBehavior', { behavior: 'allow', downloadPath: dir })
        await page.waitForFunction(() => {
            const b = document.querySelector('[data-slot="table-export"] button')
            return !!b && Object.keys(b).some((k) => k.startsWith('__react'))
        }, { timeout: 60_000 })
        const label = fmt === 'csv' ? 'Export CSV' : 'Export Excel'
        // 一页上可能有好几张表:按导出出来的文件名认那一张 —— 每一颗钮都试,直到那个名字的文件落下来
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

function csvBody(path) {
    const rows = parseCsv(readFileSync(path, 'utf8'))
    return { head: rows[0] ?? [], body: rows.slice(1).filter((r) => r.length > 1 || r[0] !== '') }
}

async function xlsxCells(path, header) {
    const wb = new ExcelJS.Workbook()
    await wb.xlsx.readFile(path)
    const ws = wb.worksheets[0]
    const headers = ws.getRow(1).values.slice(1)
    const idx = headers.indexOf(header)
    const vals = []
    ws.eachRow((row, n) => { if (n > 1) vals.push(idx >= 0 ? row.getCell(idx + 1).value : undefined) })
    const about = {}
    wb.getWorksheet('About')?.eachRow((r) => { about[String(r.getCell(1).value)] = String(r.getCell(2).value) })
    return { idx, vals, about }
}

/** psql 一次,读回带 `PROOF|` 前缀的那几行;非零退出码就抛(驱动坏了,不是 FAIL)。 */
function psql(sql) {
    const r = spawnSync('psql', [DSN, '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-f', '-'], { input: sql, encoding: 'utf8', timeout: 120_000 })
    const lines = `${r.stdout ?? ''}\n${r.stderr ?? ''}`.split('\n').filter((l) => l.includes('PROOF|'))
    if (r.status !== 0) throw new Error(`TE2B2_DRIVER|psql exit ${r.status}: ${(r.stderr ?? '').split('\n').slice(-4).join(' / ')}`)
    return lines.map((l) => l.slice(l.indexOf('PROOF|') + 6))
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

    if (!PUP_DIR || !existsSync(join(PUP_DIR, 'node_modules/puppeteer-core'))) throw new Error('TE2B2_DRIVER|PUPPETEER_DIR has no node_modules/puppeteer-core')
    const puppeteer = createRequire(join(PUP_DIR, 'package.json'))('puppeteer-core')
    const ver = readdirSync(CHROME_ROOT).sort().pop()
    const exe = join(CHROME_ROOT, ver, 'chrome-headless-shell-mac-arm64', 'chrome-headless-shell')
    if (!existsSync(exe)) throw new Error(`TE2B2_DRIVER|no chrome-headless-shell at ${exe}`)
    try { const r = await fetch(BASE + '/login', { redirect: 'manual' }); if (r.status !== 200) throw new Error(`HTTP ${r.status}`) }
    catch (e) { throw new Error(`TE2B2_DRIVER|no app at ${BASE}: ${e.message}`) }
    browser = await puppeteer.launch({ executablePath: exe, headless: true, args: ['--no-sandbox'] })

    const stamp = Date.now()
    const VIEW = ['module.purchasing.view', 'module.inbound.view', 'module.inventory.view']
    const blind = await mintThrowaway({ prefix: 'te2b2probe', label: 'blind', stamp, codes: VIEW })
    const sees = await mintThrowaway({ prefix: 'te2b2probe', label: 'sees', stamp, codes: [...VIEW, 'data.view_purchase_prices', 'data.view_prices'] })
    const ops = await mintThrowaway({ prefix: 'te2b2probe', label: 'ops', stamp, codes: ['module.processing.view'] })
    const ntf = await mintThrowaway({ prefix: 'te2b2probe', label: 'ntf', stamp, codes: ['module.materials.view', 'module.inventory.view'] })

    // ── I · 收件箱 ─────────────────────────────────────────────────────────────
    const inboxN = () => Number(psql(`SELECT 'PROOF|' || count(*) FROM ingest_inbox;`)[0])
    const n0 = inboxN()
    const pages = Math.ceil(n0 / 200)
    console.log(`STEP|ingest_inbox ${n0} rows (read as postgres, base table) → ${pages} pages of 200`)
    ok(n0 > 200, `I0 live holds more than the old 200-row limit: ${n0}`)
    const readPage = async (p) => {
        const { page, status } = await openAs(ops, `/operation/capture/inbox${p > 1 ? `?page=${p}` : ''}`)
        try {
            const r = await page.evaluate(() => ({
                // 第一格可能是手机展开钮 —— 按内容认编号那一格(「#123」),不按位置
                ids: [...document.querySelectorAll('tbody tr')].map((tr) => [...tr.querySelectorAll('td')].map((td) => td.textContent?.trim() ?? '').find((x) => /^#\d+$/.test(x)) ?? '').filter(Boolean).map((x) => Number(x.slice(1))),
                pager: document.querySelector('[data-inbox-pager]')?.textContent?.replace(/\s+/g, ' ').trim() ?? null,
            }))
            return { status, ...r }
        } finally { await page.close() }
    }
    const p1 = await readPage(1), p2 = await readPage(2), pl = await readPage(pages)
    ok(p1.status === 200 && p1.ids.length === 200, `I1 page 1 → HTTP ${p1.status}, ${p1.ids.length} rows`)
    ok(p1.pager?.includes(`Page 1 of ${pages}`) && p1.pager?.includes(`${n0.toLocaleString('en-US')} messages`), `I1 pager says ${JSON.stringify(p1.pager)}`)
    ok(p2.status === 200 && p2.ids.length === 200 && Math.max(...p2.ids) < Math.min(...p1.ids),
       `I2 page 2 → HTTP ${p2.status}, ${p2.ids.length} other rows, newest #${Math.max(...p2.ids)} < page 1's oldest #${Math.min(...p1.ids)}`)
    ok(pl.status === 200 && pl.ids.length === n0 - 200 * (pages - 1), `I3 last page ${pages} → ${pl.ids.length} rows (= ${n0} − 200 × ${pages - 1})`)
    for (const fmt of ['csv', 'xlsx']) {
        const x = await exportOnce(ops, '/operation/capture/inbox?page=2', 'operation-capture-inbox', fmt)
        const n1 = inboxN()
        if (ok(!x.err, `I4 inbox export from page 2 · ${fmt} downloaded${x.err ? ` — ${x.err}` : `: ${x.file}`}`)) {
            const rows = fmt === 'csv' ? csvBody(x.path).body.length : (await xlsxCells(x.path, 'Row')).vals.length
            ok(rows >= n0 && rows <= n1, `I4 ${fmt} holds ${rows} rows — every matching row, past the old 200 (inbox ${n0} before, ${n1} after)`)
        }
    }

    // ── R · 看不见价的读者 ───────────────────────────────────────────────────
    const [poLine] = psql(`SELECT 'PROOF|' || p.id || '|' || p.code || '|' || p.fx_rate FROM purchase_orders p
        WHERE p.deleted_at IS NULL AND p.currency <> (SELECT code FROM currencies WHERE is_base) AND p.estimated_total_ccy > 0
          AND EXISTS (SELECT 1 FROM purchase_order_payment_terms t WHERE t.purchase_order_id = p.id AND t.percentage IS NOT NULL)
          AND EXISTS (SELECT 1 FROM inbound_batches b WHERE b.purchase_order_id = p.id AND b.deleted_at IS NULL AND b.unit_price IS NOT NULL)
        ORDER BY p.code LIMIT 1;`)
    if (!poLine) throw new Error('TE2B2_DRIVER|live has no foreign-currency PO with percentage terms and a priced receipt')
    const [poId, poCode, fx] = poLine.split('|')
    console.log(`STEP|${poCode}: fx ${fx}, percentage terms and a priced receipt (read as postgres, base tables)`)
    for (const [arm, reader] of [['blind', blind], ['sees', sees]]) {
        const { page, status } = await openAs(reader, `/purchasing/orders/${poId}`)
        try {
            const r = await page.evaluate(() => {
                const text = document.body.innerText
                const tables = [...document.querySelectorAll('table')]
                const cellsUnder = (re) => {
                    const t = tables.find((tb) => [...tb.querySelectorAll('thead th')].some((th) => re.test(th.textContent ?? '')) && tb.querySelectorAll('tbody tr').length)
                    if (!t) return null
                    const hs = [...t.querySelectorAll('thead th')].map((th) => th.textContent?.trim() ?? '')
                    return { hs, rows: [...t.querySelectorAll('tbody tr')].map((tr) => [...tr.querySelectorAll('td')].map((td) => td.textContent?.trim() ?? '')) }
                }
                return { atLine: (text.match(/USD @ [^\n]*/) ?? [null])[0], terms: cellsUnder(/^Trigger|Due/i), receipts: cellsUnder(/^Arrival/i) }
            })
            ok(status === 200, `R ${arm} · /purchasing/orders/${poCode} → HTTP ${status}`)
            ok(arm === 'blind' ? r.atLine?.startsWith('USD @ Restricted') : r.atLine?.startsWith(`USD @ ${Number(fx)}`),
               `R1 ${arm} · header currency reads ${JSON.stringify(r.atLine)} ${arm === 'blind' ? '(was "USD @ null")' : `(stored ${fx})`}`)
            const ai = r.terms?.hs.findIndex((h) => /^Amount/i.test(h)) ?? -1
            const amounts = r.terms && ai >= 0 ? r.terms.rows.map((c) => c[ai]) : []
            ok(amounts.length > 0 && (arm === 'blind' ? amounts.every((a) => a === 'Restricted') : amounts.every((a) => a !== 'Restricted' && a !== '0.00')),
               `R2 ${arm} · payment-term amounts ${JSON.stringify(amounts)} ${arm === 'blind' ? '(were 0.00)' : ''}`)
            const ui = r.receipts?.hs.findIndex((h) => /Unit price/i.test(h)) ?? -1
            const prices = r.receipts && ui >= 0 ? r.receipts.rows.map((c) => c[ui]) : []
            ok(prices.length > 0 && (arm === 'blind' ? prices.every((p) => p === 'Restricted') : prices.some((p) => /\d/.test(p))),
               `R3 ${arm} · receipt unit prices ${JSON.stringify(prices)} ${arm === 'blind' ? '(were "Unpriced")' : ''}`)
        } finally { await page.close() }
    }
    for (const [arm, reader] of [['blind', blind], ['sees', sees]]) {
        const { page, status } = await openAs(reader, '/inbound')
        try {
            const badge = await page.evaluate(() => document.querySelector('[data-unpriced-badge="restricted"]')?.textContent?.trim() ?? null)
            ok(status === 200 && (arm === 'blind' ? badge === 'Unpriced batches: Restricted' : badge === null),
               `R4 ${arm} · /inbound → HTTP ${status}; restricted unpriced line ${JSON.stringify(badge)}`)
        } finally { await page.close() }
    }
    const [matLine] = psql(`SELECT 'PROOF|' || ob.material_id FROM output_batches ob JOIN processing_outputs po ON po.output_batch_id = ob.id
        WHERE ob.deleted_at IS NULL AND ob.remaining_qty > 0 AND po.unit_cost_base IS NOT NULL ORDER BY ob.code LIMIT 1;`)
    if (!matLine) throw new Error('TE2B2_DRIVER|live has no costed output batch in stock')
    for (const [arm, reader] of [['blind', blind], ['sees', sees]]) {
        const { page, status } = await openAs(reader, `/inventory/output/${matLine}`)
        try {
            const cost = await page.evaluate(() => {
                const p = [...document.querySelectorAll('p')].find((x) => /Cost value/i.test(x.textContent ?? ''))
                const m = (p?.innerText ?? '').match(/Cost value[^:]*:\s*([^·\n]+)/i)
                return m ? m[1].trim() : null
            })
            ok(status === 200 && (arm === 'blind' ? cost === 'Restricted' : cost !== null && cost !== 'Restricted' && cost !== '0.00'),
               `R5 ${arm} · /inventory/output/<material> → HTTP ${status}; cost value total ${JSON.stringify(cost)} ${arm === 'blind' ? '(was 0.00)' : ''}`)
        } finally { await page.close() }
    }

    // ── N · 未读数 = 库里的数 ───────────────────────────────────────────────
    const [dbLine] = psql(`BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"${ntf.userId}","role":"authenticated"}', true);
SELECT 'PROOF|' || (SELECT count(*) FROM notifications) || '|' ||
       (SELECT count(*) FROM notification_reads r JOIN notifications n ON n.id = r.notification_id WHERE r.user_id = '${ntf.userId}');
ROLLBACK;`)
    const [visible, readN] = dbLine.split('|').map(Number)
    const want = visible - readN
    console.log(`STEP|as the throwaway reader (rolled back): ${visible} visible notifications, ${readN} read → ${want} unread`)
    {
        const { page, status } = await openAs(ntf, '/notifications')
        try {
            const r = await page.evaluate(() => ({
                page: document.querySelector('[data-unread-count]')?.getAttribute('data-unread-count') ?? null,
                text: document.querySelector('[data-unread-count]')?.textContent?.trim() ?? null,
                bell: document.querySelector('[data-nav="unread-badge"]')?.textContent?.trim() ?? null,
            }))
            const bellWant = want === 0 ? null : want > 9 ? '9+' : String(want)
            ok(status === 200 && r.page === String(want), `N1 /notifications → HTTP ${status}; the page says ${JSON.stringify(r.text)} = database ${want}`)
            ok(r.bell === bellWant, `N2 the top-bar bell shows ${JSON.stringify(r.bell)} = database ${want} (${bellWant === null ? 'no badge at 0' : 'drawn as ' + bellWant})`)
        } finally { await page.close() }
    }

    console.log(bad ? `STEP|done with ${bad} FAIL` : 'STEP|done')
    return finish(bad ? 1 : 0)
}

main().catch((e) => {
    console.error(String(e?.stack || e))
    return finish(String(e?.message || '').startsWith('TE2B2_DRIVER') ? 2 : 1)
})
