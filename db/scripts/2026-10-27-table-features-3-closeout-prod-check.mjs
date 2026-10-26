#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// SYSTEM-MAP-0 Part 1.2 · TABLE-FEATURES-3 收尾 —— 对着【生产】(Vercel)只读地看一眼,一个按钮都不按
// ════════════════════════════════════════════════════════════════════════════
// 委托书 1.2:一个一次性 finance 账号在 /finance/journal 上看到保存的视图菜单(= 生产跑的是 7fe1cd0),
//   在分录申请面板上看到带全选的批量条,什么都不按。然后收走账号,读回 0 残留。
//   ★ 开跑前量过(postgres,rolbypassrls,基表 journal_requests):线上 0 张分录申请 —— 面板在 0 张时整个不画
//     (JournalRequestsPanel.tsx `if (open.length === 0 && history.length === 0) return null`)。在线上造一张申请是委托书禁止的,
//     所以本脚本:① 断言 /finance/journal 上【没有】批量条,并把库里的 0 印在同一行;② 在同一个批量组件的另一个使用者
//     /finance/claims(库里有一张 submitted 报销单)上读带全选的批量条 —— 与 TF-3 交回 §3 的浏览器那一格同一处。
// 只读:浏览器只发 GET。线上提交的只有一次性账号与它的授权(前缀 tf3probe —— 沿用 TF-3 的前缀,与 TF-1 / TF-2 收尾同一个先例),
//      由清理计划收走。
// 判决只从最后一行 `TF3_CLOSEOUT_EXIT=` 读:0 = 全 PASS 且收尾干净 · 1 = 有 FAIL · 2 = 驱动坏了 · 5 = live-lock 被占 · 6 = 收尾没完成。
// 用法:PROOF_BASE=https://new-era-erp.vercel.app PUPPETEER_DIR=<装着 puppeteer-core 的目录> node db/scripts/2026-10-27-table-features-3-closeout-prod-check.mjs
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
const SCRIPT = 'db/scripts/2026-10-27-table-features-3-closeout-prod-check.mjs'

let locked = false, bad = 0, browser = null
const ok = (cond, what) => { console.log(`${cond ? 'PASS' : 'FAIL'}|${what}`); if (!cond) bad++; return cond }

installExitHooks({
    onFinish: (code) => {
        try { if (locked) release() } catch { /* 放锁失败不改判决 */ }
        console.log(`TF3_CLOSEOUT_EXIT=${code}`)
    },
})

function psql(sql) {
    const r = spawnSync('psql', [DSN, '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-f', '-'], { input: sql, encoding: 'utf8', timeout: 120_000 })
    if (r.status !== 0) throw new Error(`TF3C_DRIVER|psql exit ${r.status}: ${(r.stderr ?? '').split('\n').slice(-4).join(' / ')}`)
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

async function main() {
    const other = heldBy()
    if (other) { console.error(`✗ live-lock 被【${other.holder}】(pid ${other.pid})占着`); return exitAfterCleanup(5) }
    acquireOrExit(SCRIPT, { ownExit: false })
    locked = true
    openPlan(SCRIPT)
    await reapStalePlans()

    if (!PUP_DIR || !existsSync(join(PUP_DIR, 'node_modules/puppeteer-core'))) throw new Error('TF3C_DRIVER|PUPPETEER_DIR has no node_modules/puppeteer-core')
    const puppeteer = createRequire(join(PUP_DIR, 'package.json'))('puppeteer-core')
    const ver = readdirSync(CHROME_ROOT).sort().pop()
    const exe = join(CHROME_ROOT, ver, 'chrome-headless-shell-mac-arm64', 'chrome-headless-shell')
    if (!existsSync(exe)) throw new Error(`TF3C_DRIVER|no chrome-headless-shell at ${exe}`)
    browser = await puppeteer.launch({ executablePath: exe, headless: true, args: ['--no-sandbox'] })
    console.log(`STEP|base ${BASE}`)

    // ── 库里的数(以 postgres 读基表;rolbypassrls,RLS 不参与)──────
    const db = kvRows(psql(`
        SELECT 'PROOF|jr=' || (SELECT count(*) FROM journal_requests) || '|jr_open=' || (SELECT count(*) FROM journal_requests WHERE status = 'submitted')
            || '|claims_submitted=' || (SELECT count(*) FROM expense_claims WHERE status = 'submitted');`))[0]
    console.log(`STEP|database as postgres (base tables): ${JSON.stringify(db)}`)

    const fin = await mintThrowaway({ prefix: 'tf3probe', label: 'closeout', stamp: Date.now(),
        codes: ['module.finance.view', 'data.view_prices'] })

    const readPage = (page) => page.evaluate(() => {
        const sv = document.querySelector('[data-slot="saved-views"]')
        const bar = document.querySelector('[data-slot="bulk-bar"]')
        return {
            savedViews: !!sv,
            plain: !!sv?.querySelector('[data-view-plain="true"]'),
            save: !!sv?.querySelector('[data-view-save="open"]'),
            bar: !!bar,
            selectAll: !!bar?.querySelector('input[type="checkbox"]'),
            buttons: bar ? [...bar.querySelectorAll('button')].map((b) => b.innerText.trim()) : [],
            results: !!document.querySelector('[data-slot="bulk-results"]'),
            journalPanel: !!document.querySelector('section[aria-label] h2') && [...document.querySelectorAll('section[aria-label]')].some((s) => /manual journals awaiting approval/i.test(s.getAttribute('aria-label') ?? '')),
            url: location.pathname + location.search,
        }
    })

    // ① /finance/journal:保存的视图菜单在(= 7fe1cd0 已部署);0 张申请 → 面板与批量条都不在
    {
        const { page, status } = await openAs(fin, '/finance/journal')
        try {
            const r = await readPage(page)
            ok(status === 200 && r.savedViews && r.plain && r.save && r.url === '/finance/journal',
               `/finance/journal → HTTP ${status}: saved-views menu ${r.savedViews} ("Plain list" ${r.plain}, "Save view" ${r.save}); no redirect (${r.url})`)
            ok(Number(db.jr) === 0 ? (!r.bar && !r.journalPanel) : r.bar,
               `/finance/journal journal-request panel: database holds ${db.jr} journal requests (${db.jr_open} submitted) → panel drawn ${r.journalPanel}, bulk bar ${r.bar}`
               + (Number(db.jr) === 0 ? ' (0 requests: the panel draws nothing — not observable on production without creating one)' : ''))
        } finally { await page.close() }
    }

    // ② /finance/claims:同一个 BulkDecisionBar,带全选;什么都不按
    {
        const { page, status } = await openAs(fin, '/finance/claims')
        try {
            const r = await readPage(page)
            ok(status === 200 && Number(db.claims_submitted) > 0 && r.bar && r.selectAll && r.buttons.some((x) => /^Reject selected/.test(x)) && !r.results,
               `/finance/claims → HTTP ${status}: bulk bar ${r.bar}, select-all ${r.selectAll}, buttons ${JSON.stringify(r.buttons)}; nothing pressed (result list ${r.results}); database submitted claims ${db.claims_submitted}`)
        } finally { await page.close() }
    }

    console.log(bad ? `STEP|done with ${bad} FAIL` : 'STEP|done')
    return finish(bad ? 1 : 0)
}

main().catch((e) => {
    console.error(String(e?.stack || e))
    return finish(String(e?.message || '').startsWith('TF3C_DRIVER') ? 2 : 1)
})
