#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// SYSTEM-MAP-3 live proof —— 单据链条在线上测试数据上画得出来、链接落得到地方、打不开的那几步写着「受限」+ 要的码;一个按钮都不按
// ════════════════════════════════════════════════════════════════════════════
// 委托书 Step 1:"live proof, read-only, on existing live test data with throwaway accounts (one per real role; realRole where a gate
//   needs a real holder): the bar renders on each chain's detail pages that have data, links resolve, and restricted steps show
//   「受限」 with the reason (for example warehouse on the finance steps); nothing pressed"。
// 【读者】七个线上角色各一个一次性克隆(cloneOf —— 那个真角色此刻的码)。看页面不靠"真持有人"(没有一扇门按审批角色认人),
//   所以一个 realRole 都不需要,cfo 的持有人数一下都不动。清理在 finally 里(exitAfterCleanup),成败都跑;读回由调用方另跑。
// 【页面】线上今天【有数据】的每一步各取一张(以 postgres 读基表;rolbypassrls):采购单 · 进料批 · 化验 · 应付 · 付款 · 对账单 ·
//   工单 · 加工 · 产出批 · 报价 · 销售订单 · 发货 · 柜 · 发票 · 收款 · 贷项通知单 · 请假 · 工资期间 · 付薪分录。
//   付款申请 · 考勤 · 加班批线上 0 张(Step 0 实测)—— 那三步只能由 fixture 296 在本地重建上证,这里照直报"没有可看的"。
// 【判据】每一位读者 × 每一张页面:
//   ① 页面 HTTP 200;读者进不了这一页(页面整页拒绝)→ 记下来,不判链条(那一页本来就不给他看);
//   ② 进得去 → 每一条该画的链都在(nav[data-chain=…]),每一步都在(data-chain-step 个数 = 链的步数),站的那一步标着 aria-current;
//   ③ 每一步要么是链接 / 单据号,要么是「还没有」,要么是「受限 —— 需要 <码>」/「受限 —— 只经过「X」才到得了」—— 一步都不许空着;
//   ④ 「受限」那几步恰好是读者【不持】那一步读码的那几步(读码由 document_types / lib/chains.ts 给出,与页面同一份判据)——
//      例如仓库读者在进料批页上:应付 / 付款申请 / 付款 / 对账单写着「受限 —— 需要 module.finance.view」;
//   ⑤ 链条上每一个链接都落得到地方:以同一个读者 GET 它(不跟随跳转),2xx(或 3xx 到一个不是登录页的地方),不是 404;
//   ⑥ 「全部关联记录」那一行在,并且打开得了(200)。
//   ⑦ 390px:采购单页上,链条收成一行(details 关着)与展开之后,整页都不横着溢出;展开之后 8 步都在。
// 判决只从最后一行 `SM3_PROOF_EXIT=` 读:0 = 全 PASS 且收尾干净 · 1 = 有 FAIL · 2 = 驱动坏了 · 5 = live-lock 被占 · 6 = 收尾没完成。
// 用法:PROOF_BASE=http://localhost:3196 PUPPETEER_DIR=<装着 puppeteer-core 的目录> node db/scripts/2026-10-27-system-map-3-live-proof.mjs
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
const SCRIPT = 'db/scripts/2026-10-27-system-map-3-live-proof.mjs'
const ROLES = ['admin', 'cfo', 'cco', 'cto', 'finance', 'gm', 'warehouse']

// lib/chains.ts 那一段字面量(与 scripts/check-chain-bar.mjs 同一种读法:不经 TypeScript)
const chainsSrc = readFileSync(new URL('../../lib/chains.ts', import.meta.url), 'utf8')
const CHAINS = (0, eval)('(' + chainsSrc.slice(chainsSrc.indexOf('// CHAINS-BEGIN') + 15, chainsSrc.indexOf('// CHAINS-END')) + ')')

let locked = false, bad = 0, browser = null
const ok = (cond, what) => { console.log(`${cond ? 'PASS' : 'FAIL'}|${what}`); if (!cond) bad++; return cond }

installExitHooks({
    onFinish: (code) => {
        try { if (locked) release() } catch { /* 放锁失败不改判决 */ }
        console.log('AFTER|nothing but the throwaway accounts, their roles and grants was committed (removed by the plan); the browser only sent GETs')
        console.log(`SM3_PROOF_EXIT=${code}`)
    },
})

function psql(sql) {
    const r = spawnSync('psql', [DSN, '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-f', '-'], { input: sql, encoding: 'utf8', timeout: 120_000 })
    if (r.status !== 0) throw new Error(`SM3_DRIVER|psql exit ${r.status}: ${(r.stderr ?? '').split('\n').slice(-4).join(' / ')}`)
    return (r.stdout ?? '').split('\n').filter((l) => l.startsWith('PROOF|')).map((l) => l.slice(6))
}

function selectOne(tag) {
    const r = spawnSync('psql', [DSN, '-X', '-At'], { input: '\\timing on\nselect 1;\nselect 1;\nselect 1;\nselect 1;\nselect 1;\nexplain (analyze) select 1;\n', encoding: 'utf8', timeout: 120_000 })
    const out = r.stdout ?? ''
    const times = [...out.matchAll(/^Time: ([0-9.]+) ms/gm)].map((m) => Number(m[1])).slice(0, 5)
    const exec = Number((out.match(/Execution Time: ([0-9.]+) ms/) ?? [])[1])
    const med = [...times].sort((a, b) => a - b)[2]
    console.log(`SELECT1|${tag} client round trips ${times.map((x) => x.toFixed(0)).join(' / ')} ms (median ${med?.toFixed(0)}) · server execution ${exec} ms`)
    return { med, exec, max: Math.max(...times) }
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

/** 一个链接落不落得到:以同一个读者 GET,不跟随跳转。同一个读者、同一个地址只问一次(一批单据在几张页面的链条上反复出现) */
const resolved = new Map()
async function resolves(reader, href) {
    const key = `${reader.userId}|${href.split('#')[0]}`
    if (!resolved.has(key)) resolved.set(key, resolveOnce(reader, href))
    return resolved.get(key)
}
async function resolveOnce(reader, href) {
    const url = new URL(href.split('#')[0], BASE)
    const r = await fetch(url, { redirect: 'manual', headers: { cookie: `${reader.cookieName}=${reader.cookieValue}; NEXT_LOCALE=en` } })
    const loc = r.headers.get('location') ?? ''
    return { status: r.status, ok: (r.status >= 200 && r.status < 300) || (r.status >= 300 && r.status < 400 && !/\/login/.test(loc)) }
}

async function main() {
    const other = heldBy()
    if (other) { console.error(`✗ live-lock 被【${other.holder}】(pid ${other.pid})占着`); return exitAfterCleanup(5) }
    acquireOrExit(SCRIPT, { ownExit: false })
    locked = true
    openPlan(SCRIPT)
    await reapStalePlans()

    if (!PUP_DIR || !existsSync(join(PUP_DIR, 'node_modules/puppeteer-core'))) throw new Error('SM3_DRIVER|PUPPETEER_DIR has no node_modules/puppeteer-core')
    const puppeteer = createRequire(join(PUP_DIR, 'package.json'))('puppeteer-core')
    const ver = readdirSync(CHROME_ROOT).sort().pop()
    const exe = join(CHROME_ROOT, ver, 'chrome-headless-shell-mac-arm64', 'chrome-headless-shell')
    if (!existsSync(exe)) throw new Error(`SM3_DRIVER|no chrome-headless-shell at ${exe}`)
    try { const r = await fetch(BASE + '/login', { redirect: 'manual' }); if (r.status !== 200) throw new Error(`HTTP ${r.status}`) }
    catch (e) { throw new Error(`SM3_DRIVER|no app at ${BASE}: ${e.message}`) }
    browser = await puppeteer.launch({ executablePath: exe, headless: true, args: ['--no-sandbox'] })

    // ── 每一步线上今天有数据的一张(以 postgres 读基表;rolbypassrls)──────────────────────
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
    for (const p of PAGES) ok(!!p.id, `live data: a ${p.name} to look at (${p.id ?? 'none'})`)
    console.log(`STEP|no live data (proved only by fixture 296 on the local rebuild): ${JSON.stringify(pick.none)}`)

    // 每一步的读码(与页面同一份判据:宿主步骤读 lib/chains.ts 的 permission,单据步骤读 document_types.view_permission)
    const vp = Object.fromEntries(psql(`SELECT 'PROOF|' || key || '=' || array_to_string(view_permission, ',') FROM document_types;`)
        .map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).split(',')]))
    const stepCodes = (s) => (s.permission ? [s.permission] : [...new Set(s.keys.flatMap((k) => vp[k] ?? []))])

    const stamp = Date.now()
    const readers = {}
    for (const role of ROLES) readers[role] = await mintThrowaway({ prefix: 'sm3probe', label: role, stamp, codes: { cloneOf: role } })

    // ★★ 一次一位读者,一张一张地开(Tim 2026-10-27 裁定;known-issues SM3-LIVE-PROOF-OUTAGE)—— 三位并行那一跑把免费档的库
    //   压到了 UNHEALTHY(约 22:38,23:07:01 重启)。读者之间量一次 select 1:库里的执行 > 50 ms 或这台机器上任何一次往返 > 1.5 s
    //   就中止(先收尾,finally 照样跑)。
    const report = {}
    let aborted = null
    for (const role of ROLES) {
        const why = abortReason(`before ${role}`, selectOne(`before ${role}`))
        if (why) { aborted = why; break }
        const reader = readers[role]
        const codes = new Set(reader.codes)
        report[role] = []
        for (const pg of PAGES) {
            if (!pg.id) continue
            const { page, status } = await openAs(reader, pg.path)
            try {
                const s = await page.evaluate(() => ({
                    refused: !!document.querySelector('[data-access-denied]') || /notFound|404/.test(document.title),
                    bars: [...document.querySelectorAll('nav[data-chain]')].map((n) => ({
                        chain: n.getAttribute('data-chain'), at: n.getAttribute('data-chain-at'),
                        steps: [...n.querySelectorAll('[data-chain-layout="chips"] [data-chain-step]')].map((e) => ({
                            id: e.getAttribute('data-chain-step'), state: e.getAttribute('data-chain-state'),
                            current: e.getAttribute('aria-current') === 'step', text: e.innerText.replace(/\s+/g, ' ').trim(),
                            links: [...e.querySelectorAll('a[href]')].map((a) => a.getAttribute('href')),
                        })),
                    })),
                    related: document.querySelector('[data-related-all]')?.getAttribute('href') ?? null,
                    budget: [...document.querySelectorAll('[data-chain-failed]')].some((e) => /DOCUMENT_CHAIN_WALK_BUDGET/.test(e.textContent)),
                    failed: document.querySelectorAll('[data-chain-failed]').length,
                }))
                // Tim 2026-10-28 11:25:走链被 2 秒上限拒,而【那一刻】库里的 select 1 < 50 ms、db 与 rest 健康 ⇒ 记下来,不停(上限按设计在起作用)
                if (s.budget) {
                    const sel = selectOne(`budget refusal · ${role} · ${pg.name}`)
                    const h = health()
                    if (sel.exec < 50 && h.includes('db=ACTIVE_HEALTHY') && h.includes('rest=ACTIVE_HEALTHY')) {
                        const w = `BUDGET_REFUSAL|${role} · ${pg.name}: a bar was refused with DOCUMENT_CHAIN_WALK_BUDGET; at that moment select 1 inside the database ${sel.exec} ms · ${h.join(' ')} — recorded, the page itself rendered (HTTP ${status})`
                        warnings.push(w); console.log(w)
                        ok(status === 200, `${role} · ${pg.name}: the page still rendered while its bar was refused (HTTP ${status})`)
                        report[role].push({ page: pg.name, status, budgetRefusal: true, select1: sel.exec })
                        continue
                    }
                    aborted = `${role} · ${pg.name}: a bar was refused with DOCUMENT_CHAIN_WALK_BUDGET while the database signals were abnormal (select 1 ${sel.exec} ms · ${h.join(' ')})`
                    break
                }
                if (status !== 200 || s.refused) {
                    report[role].push({ page: pg.name, status, refused: true })
                    ok(status === 200 || status === 404 || status === 403, `${role} · ${pg.name}: page refused for this role (HTTP ${status}) — not a chain page for this reader`)
                    continue
                }
                const states = []
                for (const [chainId, stepId] of Object.entries(pg.chains)) {
                    const chain = CHAINS.find((c) => c.id === chainId)
                    const bar = s.bars.find((b) => b.chain === chainId)
                    if (!ok(!!bar, `${role} · ${pg.name}: the ${chainId} chain is drawn`)) continue
                    ok(bar.at === stepId && bar.steps.length === chain.steps.length && bar.steps.filter((x) => x.current).length === 1
                        && bar.steps.find((x) => x.current)?.id === stepId,
                       `${role} · ${pg.name}: ${chainId} has all ${chain.steps.length} steps, "${stepId}" marked as here (${bar.steps.length} drawn)`)
                    for (const st of bar.steps) {
                        const def = chain.steps.find((x) => x.id === st.id)
                        const need = stepCodes(def)
                        const canOpen = need.some((c) => codes.has(c))
                        states.push(`${chainId}.${st.id}=${st.state}`)
                        ok(st.text.length > 0 && st.state !== null, `${role} · ${pg.name} · ${chainId}.${st.id}: not blank (${st.state}: "${st.text.slice(0, 70)}")`)
                        if (st.current) continue
                        if (!canOpen) {
                            ok(st.state === 'restricted' && /Restricted — needs /.test(st.text) && need.some((c) => st.text.includes(c)),
                               `${role} · ${pg.name} · ${chainId}.${st.id}: cannot open it (needs ${need.join(' / ')}) → shows "Restricted — needs …" (${st.state})`)
                        } else {
                            ok(st.state !== 'restricted', `${role} · ${pg.name} · ${chainId}.${st.id}: holds ${need.filter((c) => codes.has(c)).join(' / ')} → not restricted (${st.state})`)
                        }
                        for (const href of st.links) {
                            const r = await resolves(reader, href)
                            ok(r.ok, `${role} · ${pg.name} · ${chainId}.${st.id}: link ${href} resolves (HTTP ${r.status})`)
                        }
                    }
                }
                const rel = s.related ? await resolves(reader, s.related) : { ok: false, status: 'none' }
                ok(!!s.related && rel.ok, `${role} · ${pg.name}: "All related records" → ${s.related} (HTTP ${rel.status})`)
                report[role].push({ page: pg.name, status, states })
            } finally { await page.close() }
        }
        if (aborted) break
    }
    if (aborted) {
        console.log(`ABORT|${aborted} — the database is under load; stopping before the next reader (cleanup runs)`)
        return finish(1)
    }
    { const why = abortReason('after all readers', selectOne('after all readers')); if (why) { console.log(`ABORT|${why}`); return finish(1) } }
    console.log(`WARNINGS|${warnings.length}`)

    // ⑦ 390px:采购单页上的采购链,收起与展开,整页都不横着溢出
    {
        const reader = readers.cfo
        const { page } = await openAs(reader, `/purchasing/orders/${pick.purchase_order}`, { width: 390, height: 844 })
        try {
            const closed = await page.evaluate(() => ({ docW: document.documentElement.scrollWidth, vw: window.innerWidth,
                open: document.querySelector('nav[data-chain="purchasing"] details')?.open ?? null,
                summary: document.querySelector('nav[data-chain="purchasing"] summary')?.innerText.trim() ?? null }))
            ok(closed.open === false && closed.docW <= 390 && /step 1 of 8/.test(closed.summary ?? ''),
               `cfo · 390px · purchase order, chain collapsed: "${closed.summary}" · page ${closed.docW} px wide in a ${closed.vw} px viewport`)
            await page.click('nav[data-chain="purchasing"] summary')
            await page.waitForFunction(() => document.querySelector('nav[data-chain="purchasing"] details')?.open === true, { timeout: 10_000 })
            const opened = await page.evaluate(() => ({ docW: document.documentElement.scrollWidth, vw: window.innerWidth,
                steps: document.querySelectorAll('nav[data-chain="purchasing"] [data-chain-layout="list"] [data-chain-step]').length,
                height: Math.round(document.querySelector('nav[data-chain="purchasing"]').getBoundingClientRect().height) }))
            ok(opened.steps === 8 && opened.docW <= 390, `cfo · 390px · purchase order, chain opened: ${opened.steps} steps listed · bar ${opened.height} px tall · page ${opened.docW} px wide`)
            report.phone = { closed, opened }
        } finally { await page.close() }
    }

    if (OUT_JSON) writeFileSync(OUT_JSON, JSON.stringify(report, null, 2))
    console.log(bad ? `STEP|done with ${bad} FAIL` : 'STEP|done')
    return finish(bad ? 1 : 0)
}

main().catch((e) => {
    console.error(String(e?.stack || e))
    return finish(String(e?.message || '').startsWith('SM3_DRIVER') ? 2 : 1)
})
