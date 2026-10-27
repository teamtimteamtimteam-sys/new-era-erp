#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// SYSTEM-MAP-2 live proof —— 工作台 › 待办、首页的数、提醒页的审批支,七个线上角色各一个一次性账号,一个按钮都不按
// ════════════════════════════════════════════════════════════════════════════
// 委托书 Step 1:"for each [role], the to-do list and home count from the existing live test data, showing that every row is one the
//   role can actually decide and that no decidable item is missing (compare against the survey's table); the CFO-level requests appear
//   for cfo only; reminders' approval branches follow the same rule; nothing is pressed"。
// 【读者】Tim 2026-10-27 Q6:cfo · cco · cto · finance · gm · warehouse 用共享助手的 realRole(真角色 → 审批级别的真持有人),
//   admin 用克隆(助手拒绝真 admin)。清理在 finally 里,成败都跑;读回由调用方另跑(恰好一个 cfo 持有人、0 个一次性账号 / 角色 / 授权)。
// 【期望从哪来】docs/surveys/SYSTEM-MAP-2/README.md 那张表(每一种 → 线上哪几个角色批得了),写在下面 TYPE_ROLES —— 与 fixture 295
//   的矩阵是两条独立的路:那一边在本地重建上逐格调真的决定函数,这一边在线上按勘察表数。两边不许互相抄。
// 【库里的读】每一次都在一笔 BEGIN … ROLLBACK 里,以 authenticated + 那个账号的 claims(与页面同一个身份);
//   在途单据的清单以 postgres 读基表(rolbypassrls)。
// 【浏览器】next start(本树,对着线上),1440 与 390;只发 GET、只读 DOM。
// 判决只从最后一行 `SM2_PROOF_EXIT=` 读:0 = 全 PASS 且收尾干净 · 1 = 有 FAIL · 2 = 驱动坏了 · 5 = live-lock 被占 · 6 = 收尾没完成。
// 用法:PROOF_BASE=http://localhost:3197 PUPPETEER_DIR=<装着 puppeteer-core 的目录> node db/scripts/2026-10-27-system-map-2-live-proof.mjs
// ════════════════════════════════════════════════════════════════════════════
import { readdirSync, existsSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { homedir } from 'node:os'
import { createRequire } from 'node:module'
import { spawnSync } from 'node:child_process'
import { onlyWhenRunDirectly } from '../../scripts/lib/entrypoint.mjs'
import { acquireOrExit, release, heldBy } from '../../scripts/liveLock.mjs'
import { openPlan, mintThrowaway, reapStalePlans, installExitHooks, exitAfterCleanup } from '../../scripts/ephemeral.mjs'

onlyWhenRunDirectly(import.meta.url)

const BASE = process.env.PROOF_BASE || 'http://localhost:3197'
const PUP_DIR = process.env.PUPPETEER_DIR
const OUT_JSON = process.env.PROOF_JSON || null
const CHROME_ROOT = join(homedir(), '.cache/puppeteer/chrome-headless-shell')
const DSN = process.env.CHECK_MIRRORS_DSN || 'host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 user=postgres.wvywpohbwkiinmipmuku dbname=postgres'
const SCRIPT = 'db/scripts/2026-10-27-system-map-2-live-proof.mjs'
const ROLES = ['admin', 'cfo', 'cco', 'cto', 'finance', 'gm', 'warehouse']

// 勘察表(docs/surveys/SYSTEM-MAP-2/README.md §0.2):每一种 → 线上批得了它的角色。'tier' = 按金额:一级 finance + cfo,二级 cfo。
const CFO_LEVEL = ['payment_request', 'payroll_request', 'receipt_price_request', 'invoice_request', 'shipping_release',
    'journal_request', 'warehouse_request', 'terms_request', 'asset_disposal_request', 'gst_filing_request']
const TYPE_ROLES = {
    purchase_order: 'tier', expense_claim: 'tier',
    ...Object.fromEntries(CFO_LEVEL.map((t) => [t, ['cfo']])),
    salary_change_request: ['admin', 'cfo'], performance_review: ['admin', 'cfo'],
    overtime_batch: ['admin', 'warehouse'],
    leave_request: ['admin', 'cco', 'cfo', 'finance'], medical_claim: ['admin', 'cco', 'cfo', 'finance'],
    ncr: ['admin', 'cco', 'cto'], work_order: ['admin', 'finance'], blending_plan: ['admin', 'finance'],
    supplier: ['admin', 'cfo'], capture_draft: ['admin', 'cto', 'warehouse'],
    portal_certificate: ['admin', 'cco', 'cto', 'finance', 'warehouse'], payment_to_pay: ['admin', 'finance'],
}
// 提醒页上 CFO 级那十支(dashboard 的支名)
const CFO_ARMS = ['payment_request_pending', 'payroll_request_pending', 'receipt_price_request_pending', 'invoice_request_pending',
    'shipping_release_pending', 'journal_request_pending', 'warehouse_request_pending', 'terms_request_pending', 'asset_disposal_pending', 'gst_filing_pending']

let locked = false, bad = 0, browser = null
const ok = (cond, what) => { console.log(`${cond ? 'PASS' : 'FAIL'}|${what}`); if (!cond) bad++; return cond }

installExitHooks({
    onFinish: (code) => {
        try { if (locked) release() } catch { /* 放锁失败不改判决 */ }
        console.log('AFTER|nothing but the throwaway accounts, their roles and grants was committed (removed by the plan); every database read ran in a transaction that rolled back')
        console.log(`SM2_PROOF_EXIT=${code}`)
    },
})

function psql(sql) {
    const r = spawnSync('psql', [DSN, '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-f', '-'], { input: sql, encoding: 'utf8', timeout: 120_000 })
    if (r.status !== 0) throw new Error(`SM2_DRIVER|psql exit ${r.status}: ${(r.stderr ?? '').split('\n').slice(-4).join(' / ')}`)
    return (r.stdout ?? '').split('\n').filter((l) => l.startsWith('PROOF|')).map((l) => l.slice(6))
}
const json1 = (lines) => JSON.parse(lines[0] ?? 'null')

/** 以这个账号的身份读,整笔回滚 */
function asUser(userId, selectJson) {
    return json1(psql(`BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"${userId}","role":"authenticated"}', true) \\g /dev/null
SELECT 'PROOF|' || (${selectJson})::text;
ROLLBACK;`))
}

async function finish(code) {
    try { if (browser) await browser.close() } catch { /* 不改判决 */ }
    browser = null
    return exitAfterCleanup(code)
}

const hydrated = (sel) => `(() => { const e = document.querySelector(${JSON.stringify(sel)}); return !!e && Object.keys(e).some((k) => k.startsWith('__react')) })()`

async function openAs(reader, path, { width = 1440, height = 900 } = {}) {
    const page = await browser.newPage()
    await page.setViewport({ width, height, deviceScaleFactor: 1, isMobile: width < 768, hasTouch: width < 768 })
    const cdp = await page.createCDPSession()
    const host = new URL(BASE).hostname
    await cdp.send('Network.setCookies', { cookies: [
        { name: reader.cookieName, value: reader.cookieValue, domain: host, path: '/' },
        { name: 'NEXT_LOCALE', value: 'en', domain: host, path: '/' },
    ] })
    const res = await page.goto(BASE + path, { waitUntil: 'networkidle2', timeout: 120_000 })
    await page.waitForFunction(hydrated('[data-nav="avatar-menu"] button'), { timeout: 60_000 }).catch(() => {})
    return { page, status: res?.status() }
}

async function main() {
    const other = heldBy()
    if (other) { console.error(`✗ live-lock 被【${other.holder}】(pid ${other.pid})占着`); return exitAfterCleanup(5) }
    acquireOrExit(SCRIPT, { ownExit: false })
    locked = true
    openPlan(SCRIPT)
    await reapStalePlans()

    if (!PUP_DIR || !existsSync(join(PUP_DIR, 'node_modules/puppeteer-core'))) throw new Error('SM2_DRIVER|PUPPETEER_DIR has no node_modules/puppeteer-core')
    const puppeteer = createRequire(join(PUP_DIR, 'package.json'))('puppeteer-core')
    const ver = readdirSync(CHROME_ROOT).sort().pop()
    const exe = join(CHROME_ROOT, ver, 'chrome-headless-shell-mac-arm64', 'chrome-headless-shell')
    if (!existsSync(exe)) throw new Error(`SM2_DRIVER|no chrome-headless-shell at ${exe}`)
    try { const r = await fetch(BASE + '/login', { redirect: 'manual' }); if (r.status !== 200) throw new Error(`HTTP ${r.status}`) }
    catch (e) { throw new Error(`SM2_DRIVER|no app at ${BASE}: ${e.message}`) }
    browser = await puppeteer.launch({ executablePath: exe, headless: true, args: ['--no-sandbox'] })

    // ── 在途的每一种,以 postgres 读基表(rolbypassrls)—— 与勘察 live-pending.sql 同一组判据 ─────────────────
    const pending = json1(psql(`SELECT 'PROOF|' || coalesce(json_agg(x), '[]')::text FROM (
        SELECT 'purchase_order' AS t, po.id::text AS id, NULL::numeric AS amt, po.created_by::text AS raiser FROM purchase_orders po WHERE po.approval_status = 'pending' AND po.deleted_at IS NULL
        UNION ALL SELECT 'expense_claim', c.id::text, (SELECT b.amount_base FROM expense_claim_amount_base(c.id) b), c.created_by::text FROM expense_claims c WHERE c.status = 'submitted'
        UNION ALL SELECT 'payment_request', id::text, NULL, created_by::text FROM payment_requests WHERE status = 'submitted'
        UNION ALL SELECT 'payroll_request', id::text, NULL, created_by::text FROM payroll_requests WHERE status = 'submitted'
        UNION ALL SELECT 'receipt_price_request', id::text, NULL, created_by::text FROM receipt_price_requests WHERE status = 'submitted'
        UNION ALL SELECT 'invoice_request', id::text, NULL, created_by::text FROM invoice_requests WHERE status = 'submitted'
        UNION ALL SELECT 'shipping_release', id::text, NULL, created_by::text FROM shipping_releases WHERE status = 'submitted'
        UNION ALL SELECT 'journal_request', id::text, NULL, created_by::text FROM journal_requests WHERE status = 'submitted'
        UNION ALL SELECT 'warehouse_request', id::text, NULL, created_by::text FROM warehouse_requests WHERE status = 'submitted'
        UNION ALL SELECT 'terms_request', id::text, NULL, created_by::text FROM terms_requests WHERE status = 'submitted'
        UNION ALL SELECT 'asset_disposal_request', id::text, NULL, created_by::text FROM asset_disposal_requests WHERE status = 'submitted'
        UNION ALL SELECT 'gst_filing_request', id::text, NULL, created_by::text FROM gst_filing_requests WHERE status = 'submitted'
        UNION ALL SELECT 'salary_change_request', id::text, NULL, created_by::text FROM salary_change_requests WHERE status = 'submitted'
        UNION ALL SELECT 'overtime_batch', id::text, NULL, submitted_by::text FROM overtime_batches WHERE status = 'submitted'
        UNION ALL SELECT 'performance_review', id::text, NULL, submitted_by::text FROM performance_reviews WHERE status = 'submitted'
        UNION ALL SELECT 'leave_request', id::text, NULL, created_by::text FROM leave_requests WHERE status = 'pending' AND deleted_at IS NULL
        UNION ALL SELECT 'medical_claim', id::text, NULL, created_by::text FROM medical_claims WHERE status = 'submitted' AND deleted_at IS NULL
        UNION ALL SELECT 'ncr', id::text, NULL, opened_by::text FROM nonconformance_reports WHERE status = 'open'
        UNION ALL SELECT 'work_order', id::text, NULL, created_by::text FROM work_orders WHERE status = 'draft'
        UNION ALL SELECT 'blending_plan', id::text, NULL, created_by::text FROM blending_plans WHERE status = 'draft'
        UNION ALL SELECT 'supplier', id::text, NULL, created_by::text FROM suppliers WHERE status = 'pending_review' AND deleted_at IS NULL
        UNION ALL SELECT 'capture_draft', id::text, NULL, NULL FROM capture_drafts WHERE status = 'pending'
        UNION ALL SELECT 'portal_certificate', id::text, NULL, user_id::text FROM portal_certificate_submissions WHERE status = 'submitted'
        UNION ALL SELECT 'payment_to_pay', id::text, NULL, created_by::text FROM payment_requests WHERE status = 'approved'
    ) x;`))
    const [settings] = psql(`SELECT 'PROOF|' || json_build_object('thr', approval_threshold_base, 'on', approvals_enabled)::text FROM finance_settings LIMIT 1;`).map((l) => JSON.parse(l))
    const notifs = json1(psql(`SELECT 'PROOF|' || coalesce(json_agg(json_build_object('id', id, 'subject_type', subject_type)), '[]')::text FROM notifications;`))
    const stocktakes = json1(psql(`SELECT 'PROOF|' || coalesce(json_agg(id), '[]')::text FROM stocktakes WHERE status = 'open' AND deleted_at IS NULL;`))
    const byType = {}
    for (const p of pending) byType[p.t] = (byType[p.t] ?? 0) + 1
    console.log(`STEP|database as postgres (base tables): pending ${JSON.stringify(byType)} · approvals ${settings.on ? 'ON' : 'OFF'} threshold ${settings.thr} · notifications ${notifs.length} · open stocktakes ${stocktakes.length}`)

    const stamp = Date.now()
    const readers = {}
    for (const role of ROLES) {
        readers[role] = await mintThrowaway({ prefix: 'sm2probe', label: role, stamp,
            codes: role === 'admin' ? { cloneOf: 'admin' } : { realRole: role } })
    }
    const throwawayIds = new Set(Object.values(readers).map((r) => r.userId))
    ok(pending.every((p) => !throwawayIds.has(p.raiser)), 'no pending document was raised by a throwaway reader (four-eyes cannot hide anything here)')

    const report = {}
    for (const role of ROLES) {
        const reader = readers[role]
        const codes = new Set(reader.codes)
        // ── 期望(勘察表)────────────────────────────────────────────────────────
        const expected = []
        for (const p of pending) {
            const rule = TYPE_ROLES[p.t]
            let roles
            if (rule === 'tier') {
                const amt = p.t === 'expense_claim' ? p.amt : null
                if (p.t === 'expense_claim' && amt === null) roles = []
                else if (p.t === 'expense_claim') roles = Number(amt) >= Number(settings.thr) ? ['cfo'] : ['finance', 'cfo']
                else roles = ['finance', 'cfo'] // 采购单:今天线上 0 张;真有时按金额,这里不会走到
            } else roles = rule ?? []
            if (roles.includes(role)) expected.push(`${p.t}:${p.id}`)
        }
        for (const n of notifs) {
            const code = n.subject_type === 'material' ? 'module.materials.view' : n.subject_type === 'storage_location' ? 'module.inventory.view' : null
            if (code && codes.has(code)) expected.push(`notification:${n.id}`)
        }
        // ── 库里读到的(以这个账号,回滚)────────────────────────────────────────
        const got = asUser(reader.userId, `json_build_object(
            'rows', (SELECT coalesce(json_agg(json_build_object('t', item_type, 'id', item_id, 'kind', kind)), '[]') FROM waiting_for_me()),
            'count', waiting_for_me_count(),
            'reach', (SELECT json_object_agg(item_type, can_decide) FROM waiting_decision_reach()),
            'ops', (SELECT coalesce(json_agg(json_build_object('arm', o.item_type, 'id', o.item_id, 'code', o.item_code)), '[]')
                      FROM operations_now o JOIN decision_arms() d ON d.arm = o.item_type))`)
        const gotKeys = got.rows.map((r) => `${r.t}:${r.id}`).sort()
        const expKeys = [...expected].sort()
        ok(JSON.stringify(gotKeys) === JSON.stringify(expKeys),
           `T ${role}: to-do rows from the database = the survey table's expectation (${gotKeys.length}: ${gotKeys.map((k) => k.split(':')[0]).join(', ') || 'none'})`)
        ok(got.count === got.rows.length, `C ${role}: home count waiting_for_me_count() = ${got.count} = to-do rows ${got.rows.length}`)
        ok(!got.rows.some((r) => stocktakes.includes(r.id)), `S ${role}: no open stocktake on the to-do list (Q4 a)`)
        const cfoRows = got.rows.filter((r) => CFO_LEVEL.includes(r.t)).length
        ok(role === 'cfo' || cfoRows === 0, `F ${role}: CFO-level request rows on the to-do list = ${cfoRows}` + (role === 'cfo' ? ' (cfo)' : ' (must be 0)'))
        const reachCfo = CFO_LEVEL.filter((t) => got.reach[t]).length
        ok(role === 'cfo' ? reachCfo === CFO_LEVEL.length : reachCfo === 0,
           `F ${role}: can decide the CFO-level kinds (waiting_decision_reach) = ${reachCfo}/10` + (role === 'cfo' ? ' — cfo only' : ''))
        // 提醒页的审批支:每一行都对得上他待办上的一张(审批支只列他批得了的)
        const todoIds = new Set(got.rows.map((r) => r.id))
        const stray = got.ops.filter((o) => !todoIds.has(o.id))
        // parent-keyed 的支(工资期 · 收货 · 发票 · 销售单 · 员工 · GST 期 · 供应商)item_id 是主体,不是申请 —— 线上这些种类今天都是 0
        ok(stray.length === 0, `O ${role}: reminder approval-branch rows ${got.ops.length}, each one on the reader's to-do list (stray ${stray.length})`)
        report[role] = { expected: expKeys, got: gotKeys, count: got.count, reach: got.reach }

        // ── 浏览器:/workbench · / · /tools/reminders(只读 DOM)───────────────────
        {
            const { page, status } = await openAs(reader, '/workbench')
            try {
                const s = await page.evaluate(() => {
                    const t = document.querySelector('table[data-slot="data-table"]')
                    const rows = t ? [...t.querySelectorAll(':scope > tbody > tr')].filter((tr) => tr.querySelector('[data-todo-type]')) : []
                    return {
                        types: rows.map((tr) => tr.querySelector('[data-todo-type]').getAttribute('data-todo-type')),
                        links: rows.map((tr) => tr.querySelector('[data-todo-link]')?.getAttribute('href') ?? null),
                        checks: rows.filter((tr) => tr.querySelector('input[type="checkbox"]')).length,
                        bar: !!document.querySelector('[data-slot="bulk-bar"]'),
                        barButtons: [...document.querySelectorAll('[data-slot="bulk-bar"] button')].map((b) => b.innerText.trim()),
                        results: !!document.querySelector('[data-slot="bulk-results"]'),
                        empty: /Nothing is waiting for you/.test(document.body.innerText),
                        url: location.pathname,
                    }
                })
                ok(status === 200 && s.url === '/workbench' && s.types.length === got.rows.length && (got.rows.length > 0 || s.empty),
                   `W ${role} /workbench: HTTP ${status}, ${s.types.length} rows drawn (database ${got.rows.length})${s.empty ? ', says "Nothing is waiting for you"' : ''}; types ${s.types.join(', ') || '—'}`)
                ok(s.links.every((h) => h !== null), `W ${role} /workbench: every row links to its decision page (${s.links.join(' · ') || '—'})`)
                const claimRows = got.rows.filter((r) => r.t === 'expense_claim').length
                ok(!s.results && s.checks === claimRows && (claimRows === 0 ? !s.bar : s.bar && !s.barButtons.some((b) => /^Approve/.test(b))),
                   `W ${role} /workbench bulk: ${s.checks} row checkboxes (bulk-capable rows ${claimRows}), bulk bar ${s.bar} ${JSON.stringify(s.barButtons)} — expense claims are reject-only; nothing pressed`)
                report[role].workbench = s
            } finally { await page.close() }
        }
        {
            const { page, status } = await openAs(reader, '/')
            try {
                const c = await page.evaluate(() => {
                    const a = document.querySelector('[data-home-todo-count]')
                    return a ? { n: Number(a.getAttribute('data-home-todo-count')), href: a.getAttribute('href'), text: a.textContent.trim() } : null
                })
                ok(status === 200 && c && c.n === got.count && c.href === '/workbench', `H ${role} home: count link "${c?.text}" → ${c?.href} (database ${got.count})`)
            } finally { await page.close() }
        }
        {
            const { page, status } = await openAs(reader, '/tools/reminders')
            try {
                const r = await page.evaluate(() => ({
                    waiting: [...document.querySelectorAll('[data-reminder-arm]')].map((e) => e.getAttribute('data-reminder-arm')),
                    decidedBy: [...document.querySelectorAll('[data-reminder-decided-by]')].map((e) => ({ arm: e.getAttribute('data-reminder-decided-by'), text: e.innerText.trim() })),
                }))
                const cfoDecidedElsewhere = r.decidedBy.filter((d) => CFO_ARMS.includes(d.arm))
                const readsCfoArms = role !== 'warehouse' // warehouse 持不到这几支的读码,它们照旧在「需要权限」里带权限码
                ok(status === 200 && (role === 'cfo' ? cfoDecidedElsewhere.length === 0
                        : readsCfoArms ? cfoDecidedElsewhere.length > 0 && cfoDecidedElsewhere.every((d) => /CFO-level approver/.test(d.text)) : true),
                   `R ${role} /tools/reminders: CFO-level branches shown as "decided by the CFO-level approver" ${cfoDecidedElsewhere.length}/10` + (role === 'cfo' ? ' (cfo decides them: none restricted)' : ''))
                const claimArmWaiting = r.waiting.includes('expense_claim_pending')
                const claimOnTodo = got.rows.some((x) => x.t === 'expense_claim')
                ok(claimArmWaiting === claimOnTodo, `R ${role} /tools/reminders: expense-claim branch waiting ${claimArmWaiting} ⇔ on the to-do list ${claimOnTodo}`)
                report[role].reminders = r
            } finally { await page.close() }
        }
        {
            const { page } = await openAs(reader, '/workbench', { width: 390, height: 844 })
            try {
                const g = await page.evaluate(() => ({ docW: document.documentElement.scrollWidth, vw: innerWidth }))
                ok(g.docW <= g.vw, `P ${role} /workbench at 390 px: page ${g.docW} px wide in a ${g.vw} px viewport (no sideways scroll)`)
            } finally { await page.close() }
        }
    }

    if (OUT_JSON) writeFileSync(OUT_JSON, JSON.stringify(report, null, 2))
    console.log(bad ? `STEP|done with ${bad} FAIL` : 'STEP|done')
    return finish(bad ? 1 : 0)
}

main().catch((e) => {
    console.error(String(e?.stack || e))
    return finish(String(e?.message || '').startsWith('SM2_DRIVER') ? 2 : 1)
})
