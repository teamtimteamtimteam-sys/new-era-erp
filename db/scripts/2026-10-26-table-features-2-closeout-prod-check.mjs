#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// TABLE-FEATURES-3 Part 1.3 · TABLE-FEATURES-2 收尾 —— 对着【生产】(Vercel)只读地看一眼
// ════════════════════════════════════════════════════════════════════════════
// 委托书 1.3:一个一次性 finance 账号在 /finance/invoices 上看到的表尾合计 = 库里同一组筛选的和;
//   /inbound 上点「This month」,日期框填的是新加坡时间的本月起止。然后收走账号,读回 0 残留。
//   ① /finance/invoices 不带筛选,与带 date_from/date_to 各读一次表尾的 Total。带筛选那一次取【有非作废发票的最近一个月】:
//      第一轮用的是本月,而本月 0 张,空表不画表尾 —— 那是探针挑错了筛选(tf2-closeout-prod-check-run1-probe-fault.txt);
//      库那一侧以 postgres 读【基表】invoices(rolbypassrls):status <> 'void'、issue_date 落在区间里的 sum(total_base)
//      —— 与 list_totals_invoices 走的是两条路(那一支读 invoice_status 视图)。表尾在 = 生产跑的是 f5a62e7。
//   ② /inbound:点「This month」→ 地址带上本月起止,两个日期框是那一对,链接标成当前;
//      预期值由本脚本按 Asia/Singapore 的今天独立算出来(不用 lib/datePresets.ts)。
// 只读:浏览器只发 GET 与点一个链接。线上提交的只有一次性账号与它的授权(前缀 tf2probe —— TF-2 的收尾沿用 TF-2 的前缀,
//      与 TF-1 收尾沿用 tf1probe 同一个先例),由清理计划收走。
// 判决只从最后一行 `TF2_CLOSEOUT_EXIT=` 读:0 = 全 PASS 且收尾干净 · 1 = 有 FAIL · 2 = 驱动坏了 · 5 = live-lock 被占 · 6 = 收尾没完成。
// 用法:PROOF_BASE=https://new-era-erp.vercel.app PUPPETEER_DIR=<装着 puppeteer-core 的目录> node db/scripts/2026-10-26-table-features-2-closeout-prod-check.mjs
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
const SCRIPT = 'db/scripts/2026-10-26-table-features-2-closeout-prod-check.mjs'

let locked = false, bad = 0, browser = null
const ok = (cond, what) => { console.log(`${cond ? 'PASS' : 'FAIL'}|${what}`); if (!cond) bad++; return cond }
const num = (s) => (s == null || s === '' ? null : Number(String(s).replace(/,/g, '')))
const near = (a, b) => a != null && b != null && Math.abs(a - b) < 0.005

installExitHooks({
    onFinish: (code) => {
        try { if (locked) release() } catch { /* 放锁失败不改判决 */ }
        console.log(`TF2_CLOSEOUT_EXIT=${code}`)
    },
})

function psql(sql) {
    const r = spawnSync('psql', [DSN, '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-f', '-'], { input: sql, encoding: 'utf8', timeout: 120_000 })
    if (r.status !== 0) throw new Error(`TF2C_DRIVER|psql exit ${r.status}: ${(r.stderr ?? '').split('\n').slice(-4).join(' / ')}`)
    return (r.stdout ?? '').split('\n').filter((l) => l.startsWith('PROOF|')).map((l) => l.slice(6))
}
const kvRows = (lines) => lines.map((l) => Object.fromEntries(l.split('|').map((p) => p.split('='))))

async function finish(code) {
    try { if (browser) await browser.close() } catch { /* 不改判决 */ }
    browser = null
    return exitAfterCleanup(code)
}

async function openAs(reader, path) {
    const page = await browser.newPage()
    await page.setViewport({ width: 1280, height: 900 })
    const cdp = await page.createCDPSession()
    const host = new URL(BASE).hostname
    await cdp.send('Network.setCookies', { cookies: [
        { name: reader.cookieName, value: reader.cookieValue, domain: host, path: '/' },
        { name: 'NEXT_LOCALE', value: 'en', domain: host, path: '/' },
    ] })
    const res = await page.goto(BASE + path, { waitUntil: 'networkidle2', timeout: 120_000 })
    return { page, status: res?.status() }
}

/** 第一张 DataTable 的表尾:每一行 { label, cells: { <表头文字>: <格子文字> } }(桌面档,1280)。与 TF-2 证明同一支读法。 */
async function readFooter(page) {
    return page.evaluate(() => {
        const t = document.querySelector('table[data-slot="data-table"] tfoot')?.closest('table')
        if (!t) return null
        const ths = [...t.querySelectorAll(':scope > thead > tr > th')].filter((th) => th.offsetParent !== null)
        return [...t.querySelectorAll(':scope > tfoot > tr')].map((tr) => {
            const tds = [...tr.children].filter((td) => td.offsetParent !== null)
            let col = 0
            const out = { label: null, cells: {} }
            tds.forEach((td, i) => {
                if (i === 0) out.label = td.innerText.trim()
                else { const h = ths[col]?.innerText?.trim()?.replace(/[↕▲▼]/g, '').trim(); if (td.innerText.trim()) out.cells[h] = td.innerText.trim() }
                col += td.colSpan || 1
            })
            return out
        })
    })
}

function sgToday() { return new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Singapore' }).format(new Date()) }
// 独立于 lib/datePresets.ts 的第二份算术:本月 = 新加坡今天所在月的 1 日 … 月末
function sgThisMonth() {
    const today = sgToday()
    const [y, m] = today.split('-').map(Number)
    const last = new Date(Date.UTC(y, m, 0)).getUTCDate()
    const f = (d) => `${y}-${String(m).padStart(2, '0')}-${String(d).padStart(2, '0')}`
    return { today, from: f(1), to: f(last) }
}

async function main() {
    const other = heldBy()
    if (other) { console.error(`✗ live-lock 被【${other.holder}】(pid ${other.pid})占着`); return exitAfterCleanup(5) }
    acquireOrExit(SCRIPT, { ownExit: false })
    locked = true
    openPlan(SCRIPT)
    await reapStalePlans()

    if (!PUP_DIR || !existsSync(join(PUP_DIR, 'node_modules/puppeteer-core'))) throw new Error('TF2C_DRIVER|PUPPETEER_DIR has no node_modules/puppeteer-core')
    const puppeteer = createRequire(join(PUP_DIR, 'package.json'))('puppeteer-core')
    const ver = readdirSync(CHROME_ROOT).sort().pop()
    const exe = join(CHROME_ROOT, ver, 'chrome-headless-shell-mac-arm64', 'chrome-headless-shell')
    if (!existsSync(exe)) throw new Error(`TF2C_DRIVER|no chrome-headless-shell at ${exe}`)
    browser = await puppeteer.launch({ executablePath: exe, headless: true, args: ['--no-sandbox'] })
    console.log(`STEP|base ${BASE}`)

    const tm = sgThisMonth()
    // ── 库里的数(以 postgres 读基表 invoices;rolbypassrls,RLS 不参与)──────
    const mon = kvRows(psql(`
        SELECT 'PROOF|from=' || date_trunc('month', max(issue_date))::date || '|to=' || (date_trunc('month', max(issue_date)) + interval '1 month - 1 day')::date
          FROM invoices WHERE status <> 'void';`))[0]
    const db = kvRows(psql(`
        SELECT 'PROOF|k=all|total=' || COALESCE(round(sum(total_base), 2), 0) || '|n=' || count(*) FROM invoices WHERE status <> 'void';
        SELECT 'PROOF|k=month|total=' || COALESCE(round(sum(total_base), 2), 0) || '|n=' || count(*) FROM invoices
         WHERE status <> 'void' AND issue_date BETWEEN '${mon.from}' AND '${mon.to}';`))
    const want = Object.fromEntries(db.map((r) => [r.k, r]))
    if (!(Number(want.month?.n) > 0)) throw new Error(`TF2C_DRIVER|the filtered month ${mon.from}…${mon.to} has no non-void invoices`)
    console.log(`STEP|database as postgres (base table invoices, non-void): ${JSON.stringify(want)} · SG today ${tm.today}`)

    const fin = await mintThrowaway({ prefix: 'tf2probe', label: 'closeout', stamp: Date.now(),
        codes: ['module.finance.view', 'data.view_prices', 'module.inbound.view'] })

    // ① /finance/invoices 表尾 = 库里同一组筛选的和
    for (const [k, path] of [['all', '/finance/invoices'], ['month', `/finance/invoices?date_from=${mon.from}&date_to=${mon.to}`]]) {
        const { page, status } = await openAs(fin, path)
        try {
            const ft = await readFooter(page)
            const cells = ft?.[0]?.cells ?? {}
            const kTotal = Object.keys(cells).find((h) => /^Total/i.test(h))
            ok(status === 200 && !!ft && !!kTotal && near(num(cells[kTotal]), Number(want[k].total)),
               `${path} → HTTP ${status}; footer ${JSON.stringify(ft)}; Total ${cells[kTotal] ?? '(none)'} = database ${want[k].total} (${want[k].n} non-void invoices)`)
        } finally { await page.close() }
    }

    // ② /inbound「This month」
    {
        const { page, status } = await openAs(fin, '/inbound')
        try {
            const link = await page.evaluate(() => {
                const a = document.querySelector('[data-slot="date-presets"] a[data-preset="thisMonth"]')
                return a ? [a.dataset.from, a.dataset.to] : null
            })
            ok(status === 200 && JSON.stringify(link) === JSON.stringify([tm.from, tm.to]),
               `/inbound → HTTP ${status}; "This month" link ${JSON.stringify(link)} = SG this month ${JSON.stringify([tm.from, tm.to])}`)
            await page.waitForFunction(() => Object.keys(document.querySelector('[data-slot="date-presets"] a') ?? {}).some((k) => k.startsWith('__react')), { timeout: 60_000 }).catch(() => {})
            await Promise.all([page.waitForFunction((f) => location.search.includes(`date_from=${f}`), { timeout: 60_000 }, tm.from).catch(() => {}),
                page.click('[data-slot="date-presets"] a[data-preset="thisMonth"]')])
            await page.waitForNetworkIdle({ idleTime: 800, timeout: 60_000 }).catch(() => {})
            const after = await page.evaluate(() => ({
                url: location.pathname + location.search,
                boxes: [...document.querySelectorAll('input')].map((i) => i.value).filter((v) => /\d{2}\/\d{2}\/\d{4}|\d{4}-\d{2}-\d{2}/.test(v)),
                active: document.querySelector('[data-slot="date-presets"] a[aria-current="true"]')?.dataset.preset ?? null,
            }))
            const dmy = (s) => `${s.slice(8, 10)}/${s.slice(5, 7)}/${s.slice(0, 4)}`
            ok(after.url.includes(`date_from=${tm.from}`) && after.url.includes(`date_to=${tm.to}`) && after.active === 'thisMonth'
               && after.boxes.some((v) => v === tm.from || v === dmy(tm.from)) && after.boxes.some((v) => v === tm.to || v === dmy(tm.to)),
               `click "This month" on /inbound → ${after.url}; date boxes ${JSON.stringify(after.boxes)}; active preset ${after.active}`)
        } finally { await page.close() }
    }

    console.log(bad ? `STEP|done with ${bad} FAIL` : 'STEP|done')
    return finish(bad ? 1 : 0)
}

main().catch((e) => {
    console.error(String(e?.stack || e))
    return finish(String(e?.message || '').startsWith('TF2C_DRIVER') ? 2 : 1)
})
