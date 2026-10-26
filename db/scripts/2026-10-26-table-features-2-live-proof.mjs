#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// TABLE-FEATURES-2(Tim 2026-10-25 Q1 · Q5 / 2026-10-26 Q1–Q9)· 线上证明 —— 真浏览器读表尾与快捷区间;读库的那几句以 postgres 读基表、只读
// ════════════════════════════════════════════════════════════════════════════
// 委托书(Step 1 的线上证明):
//   T  一张表尾合计 = 同一组筛选下库里的和:/finance/expenses?date_from=2026-10-01&date_to=2026-10-31,每个币种一行,
//      与以 postgres 直接求和(冲销镜像记负数)逐币种相同。
//   R  一对冲销加起来是 0:/finance/payments 的「收款 · USD」= 库里【不在任何冲销对里】的收款之和(另一条算法),
//      而有冲销对的那一侧原件 + 镜像在净额规则下是 0。
//   C  一张混币种的清单每个币种一个合计:/finance/payments 表尾每个 (收/付, 币种) 恰好一行,币种集合 = 库里出现的币种。
//   P  收付款分开:表尾有「收款 · …」与「付款 · …」两组,数各自 = 库里那个方向的净额(Tim Q4,不轧差)。
//   M  看不见金额的读者读「受限」:持 module.finance.view、不持 data.view_prices 的一次性账号在 /finance/invoices
//      的表尾:合计与未结两格是「受限」,已收那一格是数;对照臂(持 data.view_prices)三格都是数,合计 = 库里非作废发票 total_base 之和。
//   D  快捷区间按新加坡时间给出预期的起止:/finance/journal(财务)与 /inbound(非财务)四个链接的 data-from/data-to
//      = 本脚本按 Asia/Singapore 的今天与库里的 fy_end 独立算出来的那四对;在 /inbound 上点「本月」,地址换成那一对,
//      两个日期框显示那一对,表里每一行的到货日都落在区间里。
// 只读:浏览器只发 GET、点链接;线上提交的只有一次性账号与它们的授权(前缀 tf2probe,共用造号器),由清理计划收走。
// 判决只从最后一行 `TF2_PROOF_EXIT=` 读:0 = 全 PASS 且收尾干净 · 1 = 有 FAIL · 2 = 驱动坏了 · 5 = live-lock 被占 · 6 = 收尾没完成。
// 用法:PROOF_BASE=http://localhost:3197 PUPPETEER_DIR=<装着 puppeteer-core 的目录> node db/scripts/2026-10-26-table-features-2-live-proof.mjs
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

const BASE = process.env.PROOF_BASE || 'http://localhost:3197'
const PUP_DIR = process.env.PUPPETEER_DIR
const CHROME_ROOT = join(homedir(), '.cache/puppeteer/chrome-headless-shell')
const DSN = process.env.CHECK_MIRRORS_DSN || 'host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 user=postgres.wvywpohbwkiinmipmuku dbname=postgres'
const SCRIPT = 'db/scripts/2026-10-26-table-features-2-live-proof.mjs'
const EXP_FROM = '2026-10-01', EXP_TO = '2026-10-31'

let locked = false, bad = 0, browser = null
const ok = (cond, what) => { console.log(`${cond ? 'PASS' : 'FAIL'}|${what}`); if (!cond) bad++; return cond }
const num = (s) => (s == null || s === '' ? null : Number(String(s).replace(/,/g, '')))
const near = (a, b) => a != null && b != null && Math.abs(a - b) < 0.005

installExitHooks({
    onFinish: (code) => {
        try { if (locked) release() } catch { /* 放锁失败不改判决 */ }
        console.log('AFTER|nothing but the throwaway accounts and their grants was committed (removed by the plan); the database reads were sums as postgres (base tables)')
        console.log(`TF2_PROOF_EXIT=${code}`)
    },
})

function psql(sql) {
    const r = spawnSync('psql', [DSN, '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-f', '-'], { input: sql, encoding: 'utf8', timeout: 120_000 })
    if (r.status !== 0) throw new Error(`TF2_DRIVER|psql exit ${r.status}: ${(r.stderr ?? '').split('\n').slice(-4).join(' / ')}`)
    return (r.stdout ?? '').split('\n').filter((l) => l.startsWith('PROOF|')).map((l) => l.slice(6))
}
const kvRows = (lines) => lines.map((l) => Object.fromEntries(l.split('|').map((p) => p.split('='))))

async function finish(code) {
    try { if (browser) await browser.close() } catch { /* 不改判决 */ }
    browser = null
    return exitAfterCleanup(code)
}

async function openAs(reader, path, viewport = { width: 1280, height: 900 }) {
    const page = await browser.newPage()
    await page.setViewport(viewport)
    const cdp = await page.createCDPSession()
    const host = new URL(BASE).hostname
    await cdp.send('Network.setCookies', { cookies: [
        { name: reader.cookieName, value: reader.cookieValue, domain: host, path: '/' },
        { name: 'NEXT_LOCALE', value: 'en', domain: host, path: '/' },
    ] })
    const res = await page.goto(BASE + path, { waitUntil: 'networkidle2', timeout: 120_000 })
    return { page, status: res?.status() }
}

/** 第一张 DataTable 的表尾:每一行 { label, cells: { <表头文字>: <格子文字> } }(桌面档,1280)。 */
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
// 独立于 lib/datePresets.ts 的第二份算术(证明要的是两条路对上,不是同一份代码对它自己)
function expectedPresets(today, fyM, fyD) {
    const [y, m] = today.split('-').map(Number)
    const dim = (yy, mm) => new Date(Date.UTC(yy, mm, 0)).getUTCDate()
    const f = (yy, mm, dd) => `${yy}-${String(mm).padStart(2, '0')}-${String(dd).padStart(2, '0')}`
    const lm = m === 1 ? 12 : m - 1, ly = m === 1 ? y - 1 : y
    const qs = [1, 4, 7, 10].filter((q) => q <= m).pop()
    const fyEnd = (yy) => f(yy, fyM, Math.min(fyD, dim(yy, fyM)))
    const endY = fyEnd(y) >= today ? y : y + 1
    const prev = new Date(Date.UTC(endY - 1, fyM - 1, Math.min(fyD, dim(endY - 1, fyM)) + 1))
    return {
        thisMonth: [f(y, m, 1), f(y, m, dim(y, m))],
        lastMonth: [f(ly, lm, 1), f(ly, lm, dim(ly, lm))],
        thisQuarter: [f(y, qs, 1), f(y, qs + 2, dim(y, qs + 2))],
        thisYear: [prev.toISOString().slice(0, 10), fyEnd(endY)],
    }
}

async function main() {
    const other = heldBy()
    if (other) { console.error(`✗ live-lock 被【${other.holder}】(pid ${other.pid})占着`); return exitAfterCleanup(5) }
    acquireOrExit(SCRIPT, { ownExit: false })
    locked = true
    openPlan(SCRIPT)
    await reapStalePlans()

    if (!PUP_DIR || !existsSync(join(PUP_DIR, 'node_modules/puppeteer-core'))) throw new Error('TF2_DRIVER|PUPPETEER_DIR has no node_modules/puppeteer-core')
    const puppeteer = createRequire(join(PUP_DIR, 'package.json'))('puppeteer-core')
    const ver = readdirSync(CHROME_ROOT).sort().pop()
    const exe = join(CHROME_ROOT, ver, 'chrome-headless-shell-mac-arm64', 'chrome-headless-shell')
    if (!existsSync(exe)) throw new Error(`TF2_DRIVER|no chrome-headless-shell at ${exe}`)
    try { const r = await fetch(BASE + '/login', { redirect: 'manual' }); if (r.status !== 200) throw new Error(`HTTP ${r.status}`) }
    catch (e) { throw new Error(`TF2_DRIVER|no app at ${BASE}: ${e.message}`) }
    browser = await puppeteer.launch({ executablePath: exe, headless: true, args: ['--no-sandbox'] })

    // ── 库里的数(以 postgres 读基表;rolbypassrls,RLS 不参与)──────────────
    const exp = kvRows(psql(`
        SELECT 'PROOF|ccy=' || e.currency || '|net=' || round(sum(CASE WHEN EXISTS (SELECT 1 FROM expenses o WHERE o.reversed_by_expense = e.id) THEN -e.amount_ccy ELSE e.amount_ccy END), 2)
          FROM expenses e WHERE e.expense_date BETWEEN '${EXP_FROM}' AND '${EXP_TO}' GROUP BY e.currency ORDER BY 1;`))
    const pay = kvRows(psql(`
        SELECT 'PROOF|dir=' || p.direction || '|ccy=' || p.currency
               || '|net=' || round(sum(CASE WHEN EXISTS (SELECT 1 FROM payments o WHERE o.reversed_by_payment = p.id) THEN -p.amount_ccy ELSE p.amount_ccy END), 2)
               || '|unpaired=' || round(COALESCE(sum(p.amount_ccy) FILTER (WHERE p.reversed_by_payment IS NULL AND NOT EXISTS (SELECT 1 FROM payments o WHERE o.reversed_by_payment = p.id)), 0), 2)
               || '|pairs=' || count(*) FILTER (WHERE p.reversed_by_payment IS NOT NULL)
               || '|pairnet=' || round(COALESCE(sum(CASE WHEN EXISTS (SELECT 1 FROM payments o WHERE o.reversed_by_payment = p.id) THEN -p.amount_ccy ELSE p.amount_ccy END)
                      FILTER (WHERE p.reversed_by_payment IS NOT NULL OR EXISTS (SELECT 1 FROM payments o WHERE o.reversed_by_payment = p.id)), 0), 2)
          FROM payments p GROUP BY p.direction, p.currency ORDER BY 1;`))
    const inv = kvRows(psql(`SELECT 'PROOF|total=' || round(sum(total_base), 2) || '|n=' || count(*) FROM invoices WHERE status <> 'void';`))[0]
    const fy = kvRows(psql(`SELECT 'PROOF|m=' || fy_end_month || '|d=' || fy_end_day FROM finance_settings LIMIT 1;`))[0]
    console.log(`STEP|database as postgres (base tables): expenses ${JSON.stringify(exp)} · payments ${JSON.stringify(pay)} · invoices non-void ${JSON.stringify(inv)} · fy_end ${fy.m}/${fy.d}`)

    const fin = await mintThrowaway({ prefix: 'tf2probe', label: 'finance', stamp: Date.now(), codes: ['module.finance.view'] })
    const finPrices = await mintThrowaway({ prefix: 'tf2probe', label: 'finprices', stamp: Date.now(), codes: ['module.finance.view', 'data.view_prices'] })
    const inb = await mintThrowaway({ prefix: 'tf2probe', label: 'inbound', stamp: Date.now(), codes: ['module.inbound.view'] })

    // ── T · 表尾 = 库里同一组筛选的和 ───────────────────────────────────────
    {
        const { page, status } = await openAs(fin, `/finance/expenses?date_from=${EXP_FROM}&date_to=${EXP_TO}`)
        try {
            const ft = await readFooter(page)
            const got = Object.fromEntries((ft ?? []).map((r) => [r.label.replace(/^Total · /, ''), num(Object.values(r.cells)[0])]))
            const want = Object.fromEntries(exp.map((r) => [r.ccy, Number(r.net)]))
            ok(status === 200 && exp.length > 0 && Object.keys(got).length === exp.length && exp.every((r) => near(got[r.ccy], Number(r.net))),
               `T /finance/expenses ${EXP_FROM}…${EXP_TO}: footer ${JSON.stringify(got)} = database (net, mirrors negative) ${JSON.stringify(want)}`)
        } finally { await page.close() }
    }

    // ── R · C · P · 收付款 ─────────────────────────────────────────────────
    {
        const { page, status } = await openAs(fin, '/finance/payments')
        try {
            const ft = await readFooter(page) ?? []
            const rows = ft.map((r) => {
                const m = /^(Received|Paid) · (\w+)$/.exec(r.label)
                return { dir: m?.[1] === 'Received' ? 'in' : m?.[1] === 'Paid' ? 'out' : null, ccy: m?.[2] ?? null, v: num(Object.values(r.cells)[0]), label: r.label }
            })
            const keys = rows.map((r) => `${r.dir}|${r.ccy}`)
            ok(status === 200 && rows.length === pay.length && new Set(keys).size === keys.length && pay.every((p) => keys.includes(`${p.dir}|${p.ccy}`)),
               `C one total per (direction, currency): footer rows ${JSON.stringify(rows.map((r) => r.label))}; database groups ${JSON.stringify(pay.map((p) => `${p.dir}|${p.ccy}`))}`)
            ok(rows.some((r) => r.dir === 'in') && rows.some((r) => r.dir === 'out') && pay.every((p) => near(rows.find((r) => r.dir === p.dir && r.ccy === p.ccy)?.v, Number(p.net))),
               `P received and paid shown apart, each = database net of that direction: ${JSON.stringify(rows.map((r) => [r.label, r.v]))}`)
            const paired = pay.filter((p) => Number(p.pairs) > 0)
            ok(paired.length > 0 && paired.every((p) => near(Number(p.pairnet), 0) && near(rows.find((r) => r.dir === p.dir && r.ccy === p.ccy)?.v, Number(p.unpaired))),
               `R a reversed pair adds 0: ${JSON.stringify(paired.map((p) => ({ group: `${p.dir}|${p.ccy}`, pairs: p.pairs, pairNet: p.pairnet, footer: rows.find((r) => r.dir === p.dir && r.ccy === p.ccy)?.v, sumOfUnpairedRows: p.unpaired })))}`)
        } finally { await page.close() }
    }

    // ── M · 「受限」与对照臂 ────────────────────────────────────────────────
    {
        const read = async (who) => {
            const { page, status } = await openAs(who, '/finance/invoices')
            try { return { status, ft: await readFooter(page) } } finally { await page.close() }
        }
        const masked = await read(fin), shown = await read(finPrices)
        const mc = masked.ft?.[0]?.cells ?? {}, sc = shown.ft?.[0]?.cells ?? {}
        const keyOf = (cells, re) => Object.keys(cells).find((k) => re.test(k))
        const kTotal = keyOf(sc, /^Total/i), kSettled = keyOf(sc, /^Settled|Received|Paid/i), kOpen = keyOf(sc, /^Open|Outstanding/i)
        ok(shown.status === 200 && kTotal && kSettled && kOpen && near(num(sc[kTotal]), Number(inv.total)),
           `M control (data.view_prices): footer ${JSON.stringify(shown.ft)}; total = database non-void total_base ${inv.total} (${inv.n} invoices)`)
        ok(masked.status === 200 && mc[kTotal] === 'Restricted' && mc[kOpen] === 'Restricted' && near(num(mc[kSettled]), num(sc[kSettled])),
           `M reader without data.view_prices: footer ${JSON.stringify(masked.ft)} — total and open read Restricted, settled is a number equal to the control's`)
    }

    // ── D · 快捷区间 ────────────────────────────────────────────────────────
    {
        const today = sgToday()
        const want = expectedPresets(today, Number(fy.m), Number(fy.d))
        for (const [who, path] of [[fin, '/finance/journal'], [inb, '/inbound']]) {
            const { page, status } = await openAs(who, path)
            try {
                const got = await page.evaluate(() => Object.fromEntries([...document.querySelectorAll('[data-slot="date-presets"] a[data-preset]')]
                    .map((a) => [a.dataset.preset, [a.dataset.from, a.dataset.to]])))
                ok(status === 200 && JSON.stringify(got) === JSON.stringify(want),
                   `D ${path} (SG today ${today}, fy_end ${fy.m}/${fy.d}): presets ${JSON.stringify(got)} = expected ${JSON.stringify(want)}`)
                if (path === '/inbound') {
                    await page.waitForFunction(() => Object.keys(document.querySelector('[data-slot="date-presets"] a') ?? {}).some((k) => k.startsWith('__react')), { timeout: 60_000 }).catch(() => {})
                    await Promise.all([page.waitForFunction((f) => location.search.includes(`date_from=${f}`), { timeout: 60_000 }, want.thisMonth[0]).catch(() => {}),
                        page.click('[data-slot="date-presets"] a[data-preset="thisMonth"]')])
                    await page.waitForNetworkIdle({ idleTime: 800, timeout: 60_000 }).catch(() => {})
                    const after = await page.evaluate(() => ({
                        url: location.pathname + location.search,
                        boxes: [...document.querySelectorAll('input')].map((i) => i.value).filter((v) => /\d{2}\/\d{2}\/\d{4}|\d{4}-\d{2}-\d{2}/.test(v)),
                        active: document.querySelector('[data-slot="date-presets"] a[aria-current="true"]')?.dataset.preset ?? null,
                    }))
                    const dmy = (s) => `${s.slice(8, 10)}/${s.slice(5, 7)}/${s.slice(0, 4)}`
                    const [f, t] = want.thisMonth
                    ok(after.url.includes(`date_from=${f}`) && after.url.includes(`date_to=${t}`) && after.active === 'thisMonth'
                       && after.boxes.some((v) => v === f || v === dmy(f)) && after.boxes.some((v) => v === t || v === dmy(t)),
                       `D click "This month" on /inbound → ${after.url}; date boxes ${JSON.stringify(after.boxes)}; active preset ${after.active}`)
                }
            } finally { await page.close() }
        }
    }

    console.log(bad ? `STEP|done with ${bad} FAIL` : 'STEP|done')
    return finish(bad ? 1 : 0)
}

main().catch((e) => {
    console.error(String(e?.stack || e))
    return finish(String(e?.message || '').startsWith('TF2_DRIVER') ? 2 : 1)
})
