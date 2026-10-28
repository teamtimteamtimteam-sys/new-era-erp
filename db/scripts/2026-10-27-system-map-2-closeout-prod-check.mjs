#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// SYSTEM-MAP-3 Part 1 · SYSTEM-MAP-2 收尾 —— 对着【生产】(Vercel)只读地看一眼,一个按钮都不按
// ════════════════════════════════════════════════════════════════════════════
// 委托书 1.1 / 1.2:一个一次性 cfo 克隆(cfo 角色的码,不是 cfo 角色本身)在生产上看到:
//   ① 工作台 › 待办(/workbench)打开、画出行;首页那一个数 = 画出来的行数(= 生产跑的是 2e0d047 / 899100a ——
//      v1.4.77 没有 /workbench,也没有 data-home-todo-count);
//   ② 提醒页上至少一支 CFO 级审批支画在「受限」里,写着 "decided by the CFO-level approver"
//      (克隆持有 cfo 的码,但不持有 cfo 这个审批角色,所以那十支它一支都批不了)。
//   只发 GET、只读 DOM。库里那一份以这个账号的身份读(authenticated + claims),整笔回滚。
// 线上提交的只有一次性账号与它的角色、授权(前缀 sm2probe —— 沿用 SYSTEM-MAP-2 的前缀,与 SM1 收尾沿用 sm1probe 同一个先例),
//   由清理计划收走;读回由调用方另读(docs/surveys/SYSTEM-MAP-3/readings/readback-part1.sql)。
// 判决只从最后一行 `SM2_CLOSEOUT_EXIT=` 读:0 = 全 PASS 且收尾干净 · 1 = 有 FAIL · 2 = 驱动坏了 · 5 = live-lock 被占 · 6 = 收尾没完成。
// 用法:PROOF_BASE=https://new-era-erp.vercel.app PUPPETEER_DIR=<装着 puppeteer-core 的目录> node db/scripts/2026-10-27-system-map-2-closeout-prod-check.mjs
// ════════════════════════════════════════════════════════════════════════════
import { readdirSync, existsSync } from 'node:fs'
import { join } from 'node:path'
import { homedir } from 'node:os'
import { createRequire } from 'node:module'
import { spawnSync } from 'node:child_process'
import { onlyWhenRunDirectly } from '../../scripts/lib/entrypoint.mjs'
import { acquireOrExit, release, heldBy } from '../../scripts/liveLock.mjs'
import { openPlan, mintThrowaway, reapStalePlans, installExitHooks, exitAfterCleanup } from '../../scripts/ephemeral.mjs'

onlyWhenRunDirectly(import.meta.url)

const BASE = process.env.PROOF_BASE || 'https://new-era-erp.vercel.app'
const PUP_DIR = process.env.PUPPETEER_DIR
const CHROME_ROOT = join(homedir(), '.cache/puppeteer/chrome-headless-shell')
const DSN = process.env.CHECK_MIRRORS_DSN || 'host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 user=postgres.wvywpohbwkiinmipmuku dbname=postgres'
const SCRIPT = 'db/scripts/2026-10-27-system-map-2-closeout-prod-check.mjs'
// 提醒页上 CFO 级那十支(与 2026-10-27-system-map-2-live-proof.mjs 同一张单)
const CFO_ARMS = ['payment_request_pending', 'payroll_request_pending', 'receipt_price_request_pending', 'invoice_request_pending',
    'shipping_release_pending', 'journal_request_pending', 'warehouse_request_pending', 'terms_request_pending', 'asset_disposal_pending', 'gst_filing_pending']

let locked = false, bad = 0, browser = null
const ok = (cond, what) => { console.log(`${cond ? 'PASS' : 'FAIL'}|${what}`); if (!cond) bad++; return cond }

installExitHooks({
    onFinish: (code) => {
        try { if (locked) release() } catch { /* 放锁失败不改判决 */ }
        console.log(`SM2_CLOSEOUT_EXIT=${code}`)
    },
})

function psql(sql) {
    const r = spawnSync('psql', [DSN, '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-f', '-'], { input: sql, encoding: 'utf8', timeout: 120_000 })
    if (r.status !== 0) throw new Error(`SM2C_DRIVER|psql exit ${r.status}: ${(r.stderr ?? '').split('\n').slice(-4).join(' / ')}`)
    return (r.stdout ?? '').split('\n').filter((l) => l.startsWith('PROOF|')).map((l) => l.slice(6))
}

/** 以这个账号的身份读,整笔回滚 */
function asUser(userId, selectJson) {
    return JSON.parse(psql(`BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"${userId}","role":"authenticated"}', true) \\g /dev/null
SELECT 'PROOF|' || (${selectJson})::text;
ROLLBACK;`)[0] ?? 'null')
}

async function finish(code) {
    try { if (browser) await browser.close() } catch { /* 不改判决 */ }
    browser = null
    return exitAfterCleanup(code)
}

const hydrated = (sel) => `(() => { const e = document.querySelector(${JSON.stringify(sel)}); return !!e && Object.keys(e).some((k) => k.startsWith('__react')) })()`

async function openAs(reader, path) {
    const page = await browser.newPage()
    await page.setViewport({ width: 1440, height: 900 })
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

    if (!PUP_DIR || !existsSync(join(PUP_DIR, 'node_modules/puppeteer-core'))) throw new Error('SM2C_DRIVER|PUPPETEER_DIR has no node_modules/puppeteer-core')
    const puppeteer = createRequire(join(PUP_DIR, 'package.json'))('puppeteer-core')
    const ver = readdirSync(CHROME_ROOT).sort().pop()
    const exe = join(CHROME_ROOT, ver, 'chrome-headless-shell-mac-arm64', 'chrome-headless-shell')
    if (!existsSync(exe)) throw new Error(`SM2C_DRIVER|no chrome-headless-shell at ${exe}`)
    browser = await puppeteer.launch({ executablePath: exe, headless: true, args: ['--no-sandbox'] })
    console.log(`STEP|base ${BASE}`)

    const cfo = await mintThrowaway({ prefix: 'sm2probe', label: 'closeout-cfo', stamp: Date.now(), codes: { cloneOf: 'cfo' } })
    const db = asUser(cfo.userId, `json_build_object(
        'rows', (SELECT count(*) FROM waiting_for_me()),
        'count', waiting_for_me_count(),
        'types', (SELECT coalesce(json_agg(DISTINCT item_type), '[]') FROM waiting_for_me()))`)
    console.log(`STEP|database as the clone (authenticated + its claims, rolled back): waiting_for_me() ${db.rows} rows, waiting_for_me_count() ${db.count}, types ${db.types.join(', ') || '—'}`)

    // ① 工作台 › 待办 + 首页的数
    let drawn = -1
    {
        const { page, status } = await openAs(cfo, '/workbench')
        try {
            const s = await page.evaluate(() => {
                const t = document.querySelector('table[data-slot="data-table"]')
                const rows = t ? [...t.querySelectorAll(':scope > tbody > tr')].filter((tr) => tr.querySelector('[data-todo-type]')) : []
                return { url: location.pathname, rows: rows.length, types: [...new Set(rows.map((tr) => tr.querySelector('[data-todo-type]').getAttribute('data-todo-type')))],
                    empty: /Nothing is waiting for you/.test(document.body.innerText) }
            })
            drawn = s.rows
            ok(status === 200 && s.url === '/workbench' && s.rows > 0 && s.rows === db.rows,
               `/workbench → HTTP ${status}: ${s.rows} to-do rows drawn (database ${db.rows}); types ${s.types.join(', ') || '—'}${s.empty ? '; says "Nothing is waiting for you"' : ''}`)
        } finally { await page.close() }
    }
    {
        const { page, status } = await openAs(cfo, '/')
        try {
            const c = await page.evaluate(() => {
                const a = document.querySelector('[data-home-todo-count]')
                return a ? { n: Number(a.getAttribute('data-home-todo-count')), href: a.getAttribute('href'), text: a.textContent.trim() } : null
            })
            ok(status === 200 && !!c && c.n === drawn && c.href === '/workbench',
               `home → HTTP ${status}: count link "${c?.text}" → ${c?.href}; count ${c?.n} = rows drawn on /workbench ${drawn}`)
        } finally { await page.close() }
    }
    // ② 提醒页:CFO 级审批支画成「decided by the CFO-level approver」
    {
        const { page, status } = await openAs(cfo, '/tools/reminders')
        try {
            const r = await page.evaluate(() => [...document.querySelectorAll('[data-reminder-decided-by]')]
                .map((e) => ({ arm: e.getAttribute('data-reminder-decided-by'), text: e.innerText.trim().replace(/\s+/g, ' ').slice(0, 120) })))
            const cfoArms = r.filter((d) => CFO_ARMS.includes(d.arm))
            ok(status === 200 && cfoArms.length > 0 && cfoArms.every((d) => /CFO-level approver/.test(d.text)),
               `/tools/reminders → HTTP ${status}: ${cfoArms.length}/10 CFO-level branches under "restricted", each "decided by the CFO-level approver" (e.g. ${cfoArms[0] ? `${cfoArms[0].arm}: "${cfoArms[0].text}"` : '—'})`)
        } finally { await page.close() }
    }

    console.log(bad ? `STEP|done with ${bad} FAIL` : 'STEP|done')
    return finish(bad ? 1 : 0)
}

main().catch((e) => {
    console.error(String(e?.stack || e))
    return finish(String(e?.message || '').startsWith('SM2C_DRIVER') ? 2 : 1)
})
