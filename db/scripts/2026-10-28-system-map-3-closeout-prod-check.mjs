#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// CHAIN-WALK-COST Part 1 · SYSTEM-MAP-3 收尾 —— 对着【生产】(Vercel)只读地看一眼,一个按钮都不按
// ════════════════════════════════════════════════════════════════════════════
// 委托书 1.1 / 1.2:一个一次性 cfo 克隆(cfo 角色的码,不是 cfo 角色本身)在生产上:
//   ① 打开一张采购单详情页 —— 页面画完之后,链条那一格画出采购链(nav[data-chain="purchasing"]),
//      或者写着「这一次没有画出来」([data-chain-failed]);两者任一 = 生产跑的是 5567a85 / 5e6d58f
//      (v1.4.78 的采购单页上两样都没有);
//   ② 从那一页的「全部关联记录」打开 /related/<种类>/<id>,HTTP 200、画出分组。
//   只发 GET、只读 DOM。一次一位读者;开跑前与收尾后各按 AGENTS.md「线上证明一次一位读者」的中止规则量一次库。
// 线上提交的只有一次性账号与它的角色、授权(前缀 sm3probe —— 沿用 SYSTEM-MAP-3 的前缀,与 SM2 收尾沿用 sm2probe 同一个先例),
//   由清理计划收走;读回由调用方另读(docs/surveys/CHAIN-WALK-COST/readings/readback-part1.sql)。
// 判决只从最后一行 `SM3_CLOSEOUT_EXIT=` 读:0 = 全 PASS 且收尾干净 · 1 = 有 FAIL 或中止 · 2 = 驱动坏了 · 5 = live-lock 被占 · 6 = 收尾没完成。
// 用法:PROOF_BASE=https://new-era-erp.vercel.app PUPPETEER_DIR=<装着 puppeteer-core 的目录> node db/scripts/2026-10-28-system-map-3-closeout-prod-check.mjs
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
const SCRIPT = 'db/scripts/2026-10-28-system-map-3-closeout-prod-check.mjs'

let locked = false, bad = 0, browser = null
const ok = (cond, what) => { console.log(`${cond ? 'PASS' : 'FAIL'}|${what}`); if (!cond) bad++; return cond }

installExitHooks({
    onFinish: (code) => {
        try { if (locked) release() } catch { /* 放锁失败不改判决 */ }
        console.log(`SM3_CLOSEOUT_EXIT=${code}`)
    },
})

function psql(sql) {
    const r = spawnSync('psql', [DSN, '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-f', '-'], { input: sql, encoding: 'utf8', timeout: 120_000 })
    if (r.status !== 0) throw new Error(`SM3C_DRIVER|psql exit ${r.status}: ${(r.stderr ?? '').split('\n').slice(-4).join(' / ')}`)
    return (r.stdout ?? '').split('\n').filter((l) => l.startsWith('PROOF|')).map((l) => l.slice(6))
}

// ── 中止规则(AGENTS.md「线上证明一次一位读者」,与 2026-10-27-system-map-3-live-proof.mjs 同一组判据)──
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
function abortReason(tag, sel) {
    if (sel.max > 1500) console.log(`WARN|${tag}: a single round trip took ${sel.max.toFixed(0)} ms (> 1500 ms; recorded, not an abort)`)
    if (!(sel.exec <= 50)) return `${tag}: select 1 inside the database took ${sel.exec} ms (> 50 ms or unreadable)`
    if (!(sel.med <= 1500)) return `${tag}: median of five round trips ${sel.med?.toFixed(0)} ms (> 1500 ms or unreadable)`
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

async function openAs(reader, path) {
    const page = await browser.newPage()
    await page.setViewport({ width: 1440, height: 900 })
    const cdp = await page.createCDPSession()
    const host = new URL(BASE).hostname
    await cdp.send('Network.setCookies', { cookies: [
        { name: reader.cookieName, value: reader.cookieValue, domain: host, path: '/' },
        { name: 'NEXT_LOCALE', value: 'en', domain: host, path: '/' },
    ] })
    const res = await page.goto(BASE + path, { waitUntil: 'domcontentloaded', timeout: 300_000 })
    return { page, status: res?.status() }
}

async function main() {
    const other = heldBy()
    if (other) { console.error(`✗ live-lock 被【${other.holder}】(pid ${other.pid})占着`); return exitAfterCleanup(5) }
    acquireOrExit(SCRIPT, { ownExit: false })
    locked = true
    openPlan(SCRIPT)
    await reapStalePlans()

    if (!PUP_DIR || !existsSync(join(PUP_DIR, 'node_modules/puppeteer-core'))) throw new Error('SM3C_DRIVER|PUPPETEER_DIR has no node_modules/puppeteer-core')
    const puppeteer = createRequire(join(PUP_DIR, 'package.json'))('puppeteer-core')
    const ver = readdirSync(CHROME_ROOT).sort().pop()
    const exe = join(CHROME_ROOT, ver, 'chrome-headless-shell-mac-arm64', 'chrome-headless-shell')
    if (!existsSync(exe)) throw new Error(`SM3C_DRIVER|no chrome-headless-shell at ${exe}`)
    console.log(`STEP|base ${BASE}`)

    { const why = abortReason('before the reader', selectOne('before the reader')); if (why) { console.log(`ABORT|${why}`); return finish(1) } }

    // 采购链最长的那一张采购单(批次最多;以 postgres 读基表,rolbypassrls)
    const po = JSON.parse(psql(`SELECT 'PROOF|' || json_build_object('id', p.id, 'code', p.code)::text
        FROM purchase_orders p LEFT JOIN inbound_batches b ON b.purchase_order_id = p.id
        GROUP BY p.id, p.code ORDER BY count(b.id) DESC, p.code LIMIT 1;`)[0])
    console.log(`STEP|purchase order ${po.code} (${po.id}) — most inbound batches, read as postgres on base tables`)

    browser = await puppeteer.launch({ executablePath: exe, headless: true, args: ['--no-sandbox'] })
    const cfo = await mintThrowaway({ prefix: 'sm3probe', label: 'closeout-cfo', stamp: Date.now(), codes: { cloneOf: 'cfo' } })

    let related = null
    {
        const { page, status } = await openAs(cfo, `/purchasing/orders/${po.id}`)
        try {
            // 页面画完之后链条那一格才定 —— 等到画出来或写着没画出来(上限 120 s)
            await page.waitForFunction(() => !!document.querySelector('nav[data-chain="purchasing"], [data-chain-failed]'), { timeout: 120_000 }).catch(() => {})
            const s = await page.evaluate(() => {
                const nav = document.querySelector('nav[data-chain="purchasing"]')
                return {
                    url: location.pathname,
                    h1: document.querySelector('h1')?.textContent.trim() ?? null,
                    drawn: !!nav,
                    at: nav?.getAttribute('data-chain-at') ?? null,
                    steps: nav ? [...nav.querySelectorAll('[data-chain-layout="chips"] [data-chain-step]')].map((e) => `${e.getAttribute('data-chain-step')}=${e.getAttribute('data-chain-state')}`) : [],
                    failed: [...document.querySelectorAll('[data-chain-failed]')].map((e) => e.textContent.trim().slice(0, 160)),
                    related: document.querySelector('[data-related-all]')?.getAttribute('href') ?? null,
                }
            })
            related = s.related
            ok(status === 200 && s.url === `/purchasing/orders/${po.id}` && (s.drawn || s.failed.length > 0),
               `/purchasing/orders/<${po.code}> → HTTP ${status}, h1 "${s.h1}": ${s.drawn
                   ? `purchasing chain drawn, at ${s.at}, ${s.steps.length} steps (${s.steps.join(' · ')})`
                   : `chain not drawn — "${s.failed.join(' | ')}"`}`)
            if (s.drawn && s.failed.length) console.log(`STEP|also on the page: ${s.failed.length} "could not be drawn" cell(s): ${s.failed.join(' | ')}`)
        } finally { await page.close() }
    }
    {
        const ok0 = ok(!!related && related.startsWith('/related/'), `"All related records" link on the page → ${related}`)
        if (ok0) {
            const { page, status } = await openAs(cfo, related)
            try {
                const r = await page.evaluate(() => ({
                    url: location.pathname,
                    h1: document.querySelector('h1')?.textContent.trim() ?? null,
                    links: document.querySelectorAll('main a[href^="/related/"]').length,
                    error: /Application error|Something went wrong/i.test(document.body.innerText),
                }))
                ok(status === 200 && r.url === related && !r.error,
                   `${related} → HTTP ${status}, h1 "${r.h1}", ${r.links} group link(s)${r.error ? ', ERROR TEXT ON PAGE' : ''}`)
            } finally { await page.close() }
        }
    }

    { const why = abortReason('after the reader', selectOne('after the reader')); if (why) { console.log(`ABORT|${why}`); return finish(1) } }
    console.log(bad ? `STEP|done with ${bad} FAIL` : 'STEP|done')
    return finish(bad ? 1 : 0)
}

main().catch((e) => {
    console.error(String(e?.stack || e))
    return finish(String(e?.message || '').startsWith('SM3C_DRIVER') ? 2 : 1)
})
