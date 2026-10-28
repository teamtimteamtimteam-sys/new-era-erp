#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// SYSTEM-MAP-3 · 线上的性能预算(Tim 2026-10-27 23:05 第 4 步)—— 在任何一次再跑线上证明之前
// ════════════════════════════════════════════════════════════════════════════
// 「with ONE reader only, open each chain detail page that has live data once, sequentially, with at least 5 s between page loads,
//   and record the chain-walk time per page (database time and page time) and select 1 latency before and after.
//   Budget: every bar's walk under 1 s on live, and select 1 stays under 200 ms.」
// ★ 重申的预算(Tim 2026-10-27 23:45 裁定 3):走链在库里 < 1 s;select 1 在库里的执行 < 50 ms;
//   这台机器上任何一次往返 > 1.5 s 就中止(先收尾)—— 200 ms 那一条量的是网络(这台机器到新加坡的往返底线约 410 ms)。
// 【一位读者】一个一次性 cfo 克隆(cfo 那一刻的码 —— 四条链每一步它都打得开,于是每一步都真的走)。
// 【库里的时间】EXPLAIN (ANALYZE) 那一次走链(以这位读者的身份、整笔回滚)报的 Execution Time —— 服务端自己的数,不含网络。
// 【页面时间】浏览器打开那一页到 DOMContentLoaded(本机 next start 对着线上;含这台机器到新加坡的每一次往返,不是生产上的数)。
// 【select 1】同一条连接上 5 次的客户端往返(含网络)+ 服务端的 Execution Time。前后各量一次,每页之后再量一次。
// 页与页之间至少 5 s。判决只从最后一行 `SM3_PERF_EXIT=` 读:0 = 量完(预算是否守住看 BUDGET| 行)· 2 = 驱动坏了 · 6 = 收尾没完成。
// 用法:PROOF_BASE=http://localhost:3196 PUPPETEER_DIR=<…> node db/scripts/2026-10-27-system-map-3-perf-budget.mjs
// ════════════════════════════════════════════════════════════════════════════
import { readdirSync, existsSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { homedir } from 'node:os'
import { createRequire } from 'node:module'
import { spawnSync } from 'node:child_process'
import { onlyWhenRunDirectly } from '../../scripts/lib/entrypoint.mjs'
import { acquireOrExit, release, heldBy } from '../../scripts/liveLock.mjs'
import { openPlan, mintThrowaway, reapStalePlans, installExitHooks, exitAfterCleanup } from '../../scripts/ephemeral.mjs'

onlyWhenRunDirectly(import.meta.url)

const BASE = process.env.PROOF_BASE || 'http://localhost:3196'
const PUP_DIR = process.env.PUPPETEER_DIR
const OUT_JSON = process.env.PROOF_JSON || null
const CHROME_ROOT = join(homedir(), '.cache/puppeteer/chrome-headless-shell')
const DSN = process.env.CHECK_MIRRORS_DSN || 'host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 user=postgres.wvywpohbwkiinmipmuku dbname=postgres'
const SCRIPT = 'db/scripts/2026-10-27-system-map-3-perf-budget.mjs'

// lib/chains.ts 那一段字面量(与 scripts/check-chain-bar.mjs 同一种读法:不经 TypeScript)
const chainsSrc = readFileSync(new URL('../../lib/chains.ts', import.meta.url), 'utf8')
const CHAINS = (0, eval)('(' + chainsSrc.slice(chainsSrc.indexOf('// CHAINS-BEGIN') + 15, chainsSrc.indexOf('// CHAINS-END')) + ')')

let locked = false, browser = null

installExitHooks({
    onFinish: (code) => {
        try { if (locked) release() } catch { /* 放锁失败不改判决 */ }
        console.log('AFTER|nothing but the throwaway accounts, their roles and grants was committed (removed by the plan); the browser only sent GETs')
        console.log(`SM3_PERF_EXIT=${code}`)
    },
})

function psql(sql) {
    const r = spawnSync('psql', [DSN, '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-f', '-'], { input: sql, encoding: 'utf8', timeout: 120_000 })
    if (r.status !== 0) throw new Error(`SM3P_DRIVER|psql exit ${r.status}: ${(r.stderr ?? '').split('\n').slice(-4).join(' / ')}`)
    return (r.stdout ?? '').split('\n').filter((l) => l.startsWith('PROOF|')).map((l) => l.slice(6))
}

/** Management API 的健康检查(只读;只取 name/status 两个字段,别的一个字都不留) */
function health() {
    const tok = spawnSync('security', ['find-generic-password', '-s', 'Supabase CLI', '-w'], { encoding: 'utf8' }).stdout.trim()
    const r = spawnSync('curl', ['-s', '-m', '40', '-A', 'curl/8.4.0', '-H', `Authorization: Bearer ${tok}`,
        'https://api.supabase.com/v1/projects/wvywpohbwkiinmipmuku/health?services=db&services=rest'], { encoding: 'utf8', timeout: 60_000 })
    try { return JSON.parse(r.stdout).map((x) => `${x.name}=${x.status}`) } catch { return ['health=UNREADABLE'] }
}

/** Tim 2026-10-28 10:40 的中止规则:只认【库那一侧】的信号;单次往返 > 1.5 s 记下来不停 */
const warnings = []
function abortReason(tag, sel) {
    if (sel.max > 1500) { const w = `WARN|${tag}: a single round trip took ${sel.max.toFixed(0)} ms (> 1500 ms; recorded, not an abort)`; warnings.push(w); console.log(w) }
    if (sel.exec > 50) return `${tag}: select 1 inside the database took ${sel.exec} ms (> 50 ms)`
    if (sel.med > 1500) return `${tag}: median of five round trips ${sel.med.toFixed(0)} ms (> 1500 ms)`
    const h = health()
    console.log(`HEALTH|${tag}: ${h.join(' ')}`)
    if (!h.includes('db=ACTIVE_HEALTHY') || !h.includes('rest=ACTIVE_HEALTHY')) return `${tag}: Management API health ${h.join(' ')}`
    return null
}

async function finish(code) {
    try { if (browser) await browser.close() } catch { /* 不改判决 */ }
    browser = null
    return exitAfterCleanup(code)
}

async function openAs(reader, path, { width = 1440, height = 900 } = {}) {
    // ★ 每位读者一个自己的浏览器上下文:七位并行时,共用一个上下文的 cookie 会互相覆盖,页面就以最后登录的那一位画
    //   (第一跑实测:每一位都被画成了同一个人)
    if (!reader.ctx) reader.ctx = await browser.createBrowserContext()
    const page = await reader.ctx.newPage()
    await page.setViewport({ width, height, deviceScaleFactor: 1, isMobile: width < 768, hasTouch: width < 768 })
    const cdp = await page.createCDPSession()
    const host = new URL(BASE).hostname
    await cdp.send('Network.setCookies', { cookies: [
        { name: reader.cookieName, value: reader.cookieValue, domain: host, path: '/' },
        { name: 'NEXT_LOCALE', value: 'en', domain: host, path: '/' },
    ] })
    // 只读服务端画出来的 DOM —— 不等水合(链条是服务端组件;<details> 不靠 React 也开得了)
    const res = await page.goto(BASE + path, { waitUntil: 'domcontentloaded', timeout: 300_000 })
    return { page, status: res?.status() }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const walkDef = (c) => JSON.stringify({ steps: c.steps.map((s) => ({ keys: s.keys, filter: s.filter ?? null })), edges: c.edges })
// 每张页面上那一张单据是哪一种(线上产出批只有 OUT 一种有行 —— 由下面的查询核对)
const KEY = { 'purchase order': 'purchase_order', 'inbound batch': 'inbound_batch', assay: 'assay_result', payable: 'inbound_batch',
    payment: 'payment_out', 'bank statement': 'bank_statement', 'work order': 'work_order', 'processing run': 'processing_run',
    'output batch': 'output_batch', quote: 'quote', 'sales order': 'sales_order', shipment: 'shipment', container: 'container',
    invoice: 'invoice', receipt: 'payment_receipt', 'credit note': 'credit_note', leave: 'leave_request', 'payroll period': 'payroll_period',
    'payroll payment': 'journal_entry' }

function selectOne(tag) {
    const r = spawnSync('psql', [DSN, '-X', '-At'], { input: '\\timing on\nselect 1;\nselect 1;\nselect 1;\nselect 1;\nselect 1;\nexplain (analyze) select 1;\n', encoding: 'utf8', timeout: 120_000 })
    const out = r.stdout ?? ''
    const times = [...out.matchAll(/^Time: ([0-9.]+) ms/gm)].map((m) => Number(m[1])).slice(0, 5)
    const exec = Number((out.match(/Execution Time: ([0-9.]+) ms/) ?? [])[1])
    const med = [...times].sort((a, b) => a - b)[2]
    console.log(`SELECT1|${tag} client round trips ${times.map((x) => x.toFixed(0)).join(' / ')} ms (median ${med?.toFixed(0)}) · server execution ${exec} ms`)
    return { med, exec, max: Math.max(...times) }
}

function walkDbTime(userId, chain, stepIdx, key, id) {
    const sql = `BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"${userId}","role":"authenticated"}', true) \\g /dev/null
EXPLAIN (ANALYZE) SELECT * FROM document_chain_walk('${walkDef(chain)}'::jsonb, ${stepIdx}, '${key}', '${id}');
SELECT 'PROOF|' || count(*) FROM document_chain_walk('${walkDef(chain)}'::jsonb, ${stepIdx}, '${key}', '${id}');
ROLLBACK;`
    const r = spawnSync('psql', [DSN, '-X', '-At', '-v', 'ON_ERROR_STOP=1'], { input: sql, encoding: 'utf8', timeout: 120_000 })
    if (r.status !== 0 && /DOCUMENT_CHAIN_WALK_BUDGET/.test(r.stderr ?? '')) return { exec: NaN, rows: 0, budget: true }
    if (r.status !== 0) throw new Error(`SM3P_DRIVER|walk ${chain.id} ${key} ${id}: ${(r.stderr ?? '').split('\n').slice(-3).join(' / ')}`)
    const exec = Number(((r.stdout ?? '').match(/Execution Time: ([0-9.]+) ms/) ?? [])[1])
    const rows = Number(((r.stdout ?? '').match(/^PROOF\|(\d+)/m) ?? [])[1])
    return { exec, rows }
}

async function main() {
    const other = heldBy()
    if (other) { console.error(`✗ live-lock 被【${other.holder}】(pid ${other.pid})占着`); return exitAfterCleanup(5) }
    acquireOrExit(SCRIPT, { ownExit: false })
    locked = true
    openPlan(SCRIPT)
    await reapStalePlans()
    if (!PUP_DIR || !existsSync(join(PUP_DIR, 'node_modules/puppeteer-core'))) throw new Error('SM3P_DRIVER|PUPPETEER_DIR has no node_modules/puppeteer-core')
    const puppeteer = createRequire(join(PUP_DIR, 'package.json'))('puppeteer-core')
    const ver = readdirSync(CHROME_ROOT).sort().pop()
    const exe = join(CHROME_ROOT, ver, 'chrome-headless-shell-mac-arm64', 'chrome-headless-shell')
    browser = await puppeteer.launch({ executablePath: exe, headless: true, args: ['--no-sandbox'] })

    const before = selectOne('before')
    const pick = JSON.parse(psql(`SELECT 'PROOF|' || json_build_object(
        'purchase_order', (SELECT po.id FROM purchase_orders po WHERE po.deleted_at IS NULL AND EXISTS (SELECT 1 FROM inbound_batches b WHERE b.purchase_order_id = po.id) ORDER BY po.code LIMIT 1),
        'inbound_batch', (SELECT b.id FROM inbound_batches b WHERE b.purchase_order_id IS NOT NULL AND EXISTS (SELECT 1 FROM assay_results a WHERE a.inbound_batch_id = b.id) ORDER BY b.code LIMIT 1),
        'inbound_batch_any', (SELECT b.id FROM inbound_batches b WHERE b.purchase_order_id IS NOT NULL ORDER BY b.code LIMIT 1),
        'assay', (SELECT a.id || '|' || a.inbound_batch_id FROM assay_results a WHERE a.inbound_batch_id IS NOT NULL ORDER BY a.code LIMIT 1),
        'payable', (SELECT e.source_id FROM journal_entries e WHERE e.source_type = 'purchase' ORDER BY e.code LIMIT 1),
        'payment_out', (SELECT p.id FROM payments p WHERE p.code LIKE 'PMT-%' ORDER BY p.code LIMIT 1),
        'bank_statement', (SELECT s.id FROM bank_statements s ORDER BY s.code LIMIT 1),
        'work_order', (SELECT r.work_order_id FROM processing_runs r WHERE r.work_order_id IS NOT NULL LIMIT 1),
        'processing_run', (SELECT r.id FROM processing_runs r WHERE r.work_order_id IS NOT NULL LIMIT 1),
        'output_batch', (SELECT o.output_batch_id FROM processing_outputs o ORDER BY o.output_batch_id LIMIT 1),
        'quote', (SELECT q.id FROM quotes q WHERE q.converted_order_id IS NOT NULL LIMIT 1),
        'sales_order', (SELECT i.sales_order_id FROM invoices i WHERE i.sales_order_id IS NOT NULL ORDER BY i.code LIMIT 1),
        'shipment', (SELECT s.id FROM shipments s ORDER BY s.code LIMIT 1),
        'container', coalesce((SELECT s.container_id FROM shipments s WHERE s.container_id IS NOT NULL ORDER BY s.code LIMIT 1),
                              (SELECT c.id FROM containers c WHERE c.deleted_at IS NULL AND c.code ~ '^CTR-' ORDER BY c.code LIMIT 1)),
        'invoice', (SELECT i.id FROM invoices i WHERE i.sales_order_id IS NOT NULL ORDER BY i.code LIMIT 1),
        'payment_receipt', coalesce((SELECT a.payment_id FROM payment_allocations a JOIN payments p ON p.id = a.payment_id WHERE a.invoice_id IS NOT NULL AND p.code LIKE 'RCPT-%' LIMIT 1),
                                    (SELECT p.id FROM payments p WHERE p.code LIKE 'RCPT-%' ORDER BY p.code LIMIT 1)),
        'credit_note', (SELECT c.id FROM credit_notes c ORDER BY c.code LIMIT 1),
        'leave_request', (SELECT l.id FROM leave_requests l WHERE l.status = 'approved' AND l.deleted_at IS NULL ORDER BY l.code LIMIT 1),
        'payroll_period', (SELECT p.id FROM payroll_periods p WHERE p.deleted_at IS NULL ORDER BY p.code LIMIT 1),
        'payroll_payment', (SELECT pl.paid_journal_entry_id FROM payroll_lines pl WHERE pl.paid_journal_entry_id IS NOT NULL LIMIT 1),
        'none', json_build_object('payment_requests', (SELECT count(*) FROM payment_requests), 'attendance_periods', (SELECT count(*) FROM attendance_periods),
                                  'overtime_batches', (SELECT count(*) FROM overtime_batches)))::text;`)[0])
    console.log(`STEP|database as postgres (base tables): ${JSON.stringify(pick)}`)
    const [assayId, assayBatch] = String(pick.assay ?? '|').split('|')
    // 一张页面:地址 · 它画哪几条链(链 → 站的那一步)
    const PAGES = [
        { name: 'purchase order', id: pick.purchase_order, path: `/purchasing/orders/${pick.purchase_order}`, chains: { purchasing: 'purchase_order' } },
        { name: 'inbound batch', id: pick.inbound_batch ?? pick.inbound_batch_any, path: `/inbound/${pick.inbound_batch ?? pick.inbound_batch_any}/edit`, chains: { purchasing: 'inbound_batch', processing: 'input_batches' } },
        { name: 'assay', id: assayId, path: `/inbound/${assayBatch}/assays/${assayId}`, chains: { purchasing: 'assay' } },
        { name: 'payable', id: pick.payable, path: `/finance/payables/${pick.payable}`, chains: { purchasing: 'payable' } },
        { name: 'payment', id: pick.payment_out, path: `/finance/payments/${pick.payment_out}`, chains: { purchasing: 'payment' } },
        { name: 'bank statement', id: pick.bank_statement, path: `/finance/bank/statements/${pick.bank_statement}`, chains: { purchasing: 'bank_reconciliation' } },
        { name: 'work order', id: pick.work_order, path: `/operation/orders/${pick.work_order}`, chains: { processing: 'work_order' } },
        { name: 'processing run', id: pick.processing_run, path: `/operation/processing/${pick.processing_run}`, chains: { processing: 'processing_run' } },
        { name: 'output batch', id: pick.output_batch, path: `/output/${pick.output_batch}/edit`, chains: { processing: 'output_batches' } },
        { name: 'quote', id: pick.quote, path: `/sales/quotes/${pick.quote}`, chains: { sales: 'quote' } },
        { name: 'sales order', id: pick.sales_order, path: `/sales/orders/${pick.sales_order}`, chains: { sales: 'sales_order' } },
        { name: 'shipment', id: pick.shipment, path: `/sales/shipments/${pick.shipment}`, chains: { sales: 'shipment' } },
        { name: 'container', id: pick.container, path: `/logistics/containers/${pick.container}`, chains: { sales: 'container' } },
        { name: 'invoice', id: pick.invoice, path: `/finance/invoices/${pick.invoice}`, chains: { sales: 'invoice' } },
        { name: 'receipt', id: pick.payment_receipt, path: `/finance/payments/${pick.payment_receipt}`, chains: { sales: 'receipt' } },
        { name: 'credit note', id: pick.credit_note, path: `/finance/credit-notes/${pick.credit_note}`, chains: { sales: 'credit_note' } },
        { name: 'leave', id: pick.leave_request, path: `/hr/leave/${pick.leave_request}`, chains: { people: 'leave' } },
        { name: 'payroll period', id: pick.payroll_period, path: `/hr/payroll/${pick.payroll_period}`, chains: { people: 'payroll_period' } },
        { name: 'payroll payment', id: pick.payroll_payment, path: `/finance/journal/${pick.payroll_payment}`, chains: { people: 'payroll_payment' } },
    ]

    const outPrefix = psql(`SELECT 'PROOF|' || string_agg(DISTINCT split_part(code, '-', 1), ',') FROM output_batches;`)[0]
    console.log(`STEP|output batch prefixes with rows on live: ${outPrefix}`)
    const reader = await mintThrowaway({ prefix: 'sm3probe', label: 'perf-cfo', stamp: Date.now(), codes: { cloneOf: 'cfo' } })
    const results = []
    let worstWalk = 0, worstSel = before.med, worstExec = before.exec, worstTrip = before.max
    { const why = abortReason('before', before); if (why) { console.log(`ABORT|${why}`); return finish(1) } }
    for (const pg of PAGES) {
        if (!pg.id) { console.log(`SKIP|${pg.name}: no live data`); continue }
        await sleep(5000)
        const walks = []
        for (const [chainId, stepId] of Object.entries(pg.chains)) {
            const chain = CHAINS.find((c) => c.id === chainId)
            const idx = chain.steps.findIndex((s) => s.id === stepId)
            const w = walkDbTime(reader.userId, chain, idx, KEY[pg.name], pg.id)
            if (w.budget) { console.log(`ABORT|${pg.name} · ${chainId}: the walk was refused with DOCUMENT_CHAIN_WALK_BUDGET on live`); return finish(1) }
            walks.push({ chain: chainId, ms: w.exec, rows: w.rows })
            worstWalk = Math.max(worstWalk, w.exec)
            if (w.exec >= 1000) { const m = `WARN|${pg.name} · ${chainId}: walk ${w.exec.toFixed(1)} ms inside the database (1–2 s; recorded — CHAIN-WALK-COST owns it)`; warnings.push(m); console.log(m) }
        }
        await sleep(5000)
        const t0 = Date.now()
        const { page, status } = await openAs(reader, pg.path)
        const pageMs = Date.now() - t0
        const bars = await page.evaluate(() => document.querySelectorAll('nav[data-chain]').length)
        const failed = await page.evaluate(() => document.querySelectorAll('[data-chain-failed]').length)
        const budgetFail = await page.evaluate(() => [...document.querySelectorAll('[data-chain-failed]')].some((e) => /DOCUMENT_CHAIN_WALK_BUDGET/.test(e.textContent)))
        await page.close()
        if (budgetFail) { console.log(`ABORT|${pg.name}: the page's bar was refused with DOCUMENT_CHAIN_WALK_BUDGET`); return finish(1) }
        const sel = selectOne(`after ${pg.name}`)
        worstSel = Math.max(worstSel, sel.med)
        worstExec = Math.max(worstExec, sel.exec)
        worstTrip = Math.max(worstTrip, sel.max)
        { const why = abortReason(`after ${pg.name}`, sel); if (why) { console.log(`ABORT|${why} — stopping and cleaning up`); return finish(1) } }
        console.log(`PAGE|${pg.name} · HTTP ${status} · page ${pageMs} ms (local next start → live) · bars ${bars} · failed ${failed} · walk db ${walks.map((w) => `${w.chain} ${w.ms.toFixed(1)} ms (${w.rows} rows)`).join(' + ')}`)
        results.push({ page: pg.name, status, pageMs, bars, failed, walks, select1Median: sel.med, select1Server: sel.exec })
    }
    const after = selectOne('after all')
    console.log(`BUDGET|walk: worst database time ${worstWalk.toFixed(1)} ms against 1000 ms → ${worstWalk < 1000 ? 'HOLDS' : 'EXCEEDED'}`)
    worstExec = Math.max(worstExec, after.exec); worstTrip = Math.max(worstTrip, after.max)
    console.log(`BUDGET|select 1 inside the database: worst execution ${worstExec} ms against 50 ms → ${worstExec < 50 ? 'HOLDS' : 'EXCEEDED'}`)
    console.log(`BUDGET|round trips from this machine: worst single ${worstTrip.toFixed(0)} ms against the 1500 ms abort (medians ${before.med?.toFixed(0)} before · ${after.med?.toFixed(0)} after · worst median ${worstSel?.toFixed(0)}) → ${worstTrip <= 1500 ? 'HOLDS' : 'EXCEEDED'}`)
    { const why = abortReason('after all', after); if (why) console.log(`ABORT|${why}`) }
    console.log(`WARNINGS|${warnings.length}`)
    if (OUT_JSON) writeFileSync(OUT_JSON, JSON.stringify({ before, after, results, warnings }, null, 2))
    return finish(0)
}

main().catch((e) => { console.error(String(e?.stack || e)); return finish(String(e?.message || '').startsWith('SM3P_DRIVER') ? 2 : 1) })
