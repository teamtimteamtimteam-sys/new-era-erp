#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// GOLIVE-1 Part 1 · COD-READERS 收尾 —— 对着【生产】(Vercel)只读地看一眼,一个按钮都不按(连菜单都不点开)
// ════════════════════════════════════════════════════════════════════════════
// 委托书 1.1 / 1.2:一个一次性 cfo 克隆(前缀 codrprobe,沿用 COD-READERS 的前缀)在生产上:
//   ① 顶栏十个按钮,物流紧跟销售(只读按钮的字,不点开)—— v1.4.80 的顶栏是九个、没有物流,所以这一条同时证明生产跑的是 bd127ff / 2bb34df;
//   ② 安全 › 销毁证书(/compliance/cod)画表、3 行(= 以 postgres 读基表的行数);页面上没有签发 / 作废的控件;
//   ③ COD-2026-0001 所在批次页上那一块是读者的样子:没有签发 / 作废控件;
//   ④ COD-2026-0001 的 PDF(GET,只读)字节 = AGENTS.md 的基线。
//   只发 GET、只读 DOM。一次一位读者;开跑前与收尾后各按 AGENTS.md「线上证明一次一位读者」的中止规则量一次库。
// 判决只从最后一行 `CODR_CLOSEOUT_EXIT=` 读:0 = 全 PASS 且收尾干净 · 1 = 有 FAIL 或中止 · 2 = 驱动坏了 · 5 = live-lock 被占 · 6 = 收尾没完成。
// 用法:PROOF_BASE=https://new-era-erp.vercel.app PUPPETEER_DIR=<装着 puppeteer-core 的目录> node db/scripts/2026-10-29-cod-readers-closeout-prod-check.mjs
// ════════════════════════════════════════════════════════════════════════════
import { readdirSync, existsSync } from 'node:fs'
import { join } from 'node:path'
import { homedir } from 'node:os'
import { createHash } from 'node:crypto'
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
const SCRIPT = 'db/scripts/2026-10-29-cod-readers-closeout-prod-check.mjs'
// AGENTS.md「两张已签发的 COD —— 字节基线」
const BASELINE = { code: 'COD-2026-0001', bytes: 34701, sha: 'ba299a4f3488fc543cdd1f410fabf6523434d39caa0dc58d6f376309c1f42101' }
const BAR = ['Workbench', 'Purchasing', 'Production', 'Quality', 'Sales', 'Logistics', 'Finance', 'People', 'Safety', 'Equipment']

let locked = false, bad = 0, browser = null
const ok = (cond, what) => { console.log(`${cond ? 'PASS' : 'FAIL'}|${what}`); if (!cond) bad++; return cond }

installExitHooks({
    onFinish: (code) => {
        try { if (locked) release() } catch { /* 放锁失败不改判决 */ }
        console.log(`CODR_CLOSEOUT_EXIT=${code}`)
    },
})

function psql(sql) {
    const r = spawnSync('psql', [DSN, '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-f', '-'], { input: sql, encoding: 'utf8', timeout: 120_000 })
    if (r.status !== 0) throw new Error(`CODRC_DRIVER|psql exit ${r.status}: ${(r.stderr ?? '').split('\n').slice(-4).join(' / ')}`)
    return (r.stdout ?? '').split('\n').filter((l) => l.startsWith('PROOF|')).map((l) => l.slice(6))
}

// ── 中止规则(AGENTS.md「线上证明一次一位读者」)──
function selectOne(tag) {
    const r = spawnSync('psql', [DSN, '-X', '-At'], { input: '\\timing on\nselect 1;\nselect 1;\nselect 1;\nselect 1;\nselect 1;\nexplain (analyze) select 1;\n', encoding: 'utf8', timeout: 120_000 })
    const out = r.stdout ?? ''
    const times = [...out.matchAll(/^Time: ([0-9.]+) ms/gm)].map((m) => Number(m[1])).slice(0, 5)
    const exec = Number((out.match(/Execution Time: ([0-9.]+) ms/) ?? [])[1])
    const med = [...times].sort((a, b) => a - b)[2]
    console.log(`SELECT1|${tag} client round trips ${times.map((x) => x.toFixed(0)).join(' / ')} ms (median ${med?.toFixed(0)}) · server execution ${exec} ms`)
    return { med, exec, max: Math.max(...times) }
}
/** Management API 的健康检查(只读;只取 name/status 两个字段) */
function health() {
    const tok = spawnSync('security', ['find-generic-password', '-s', 'Supabase CLI', '-w'], { encoding: 'utf8' }).stdout.trim()
    const r = spawnSync('curl', ['-s', '-m', '40', '-A', 'curl/8.4.0', '-H', `Authorization: Bearer ${tok}`,
        'https://api.supabase.com/v1/projects/wvywpohbwkiinmipmuku/health?services=db&services=rest'], { encoding: 'utf8', timeout: 60_000 })
    try { return JSON.parse(r.stdout).map((x) => `${x.name}=${x.status}`) } catch { return ['health=UNREADABLE'] }
}
function abortReason(tag) {
    const sel = selectOne(tag)
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
    const res = await page.goto(BASE + path, { waitUntil: 'networkidle2', timeout: 300_000 })
    return { page, status: res?.status() }
}

async function main() {
    const other = heldBy()
    if (other) { console.error(`✗ live-lock 被【${other.holder}】(pid ${other.pid})占着`); return exitAfterCleanup(5) }
    acquireOrExit(SCRIPT, { ownExit: false })
    locked = true
    openPlan(SCRIPT)
    await reapStalePlans()

    if (!PUP_DIR || !existsSync(join(PUP_DIR, 'node_modules/puppeteer-core'))) throw new Error('CODRC_DRIVER|PUPPETEER_DIR has no node_modules/puppeteer-core')
    const puppeteer = createRequire(join(PUP_DIR, 'package.json'))('puppeteer-core')
    const ver = readdirSync(CHROME_ROOT).sort().pop()
    const exe = join(CHROME_ROOT, ver, 'chrome-headless-shell-mac-arm64', 'chrome-headless-shell')
    if (!existsSync(exe)) throw new Error(`CODRC_DRIVER|no chrome-headless-shell at ${exe}`)
    console.log(`STEP|base ${BASE}`)

    { const why = abortReason('before the reader'); if (why) { console.log(`ABORT|${why}`); return finish(1) } }

    const cods = psql(`SELECT 'PROOF|' || coalesce(c.code, '') || ',' || c.status || ',' || c.inbound_batch_id FROM certificates_of_destruction c ORDER BY c.created_at, c.id;`)
        .map((l) => { const [code, status, batch] = l.split(','); return { code: code || null, status, batch } })
    console.log(`STEP|database as postgres (base tables): ${cods.length} certificates — ${cods.map((c) => `${c.code ?? '(no number)'} ${c.status}`).join(' · ')}`)
    const target = cods.find((c) => c.code === BASELINE.code)
    if (!target) throw new Error(`CODRC_DRIVER|${BASELINE.code} not found`)

    browser = await puppeteer.launch({ executablePath: exe, headless: true, args: ['--no-sandbox'] })
    const cfo = await mintThrowaway({ prefix: 'codrprobe', label: 'closeout-cfo', stamp: Date.now(), codes: { cloneOf: 'cfo' } })

    // ① 顶栏(只读按钮上的字,不点开)
    {
        const { page, status } = await openAs(cfo, '/')
        try {
            await page.waitForSelector('[data-nav="modules"] > div > button', { timeout: 120_000 }).catch(() => {})
            const labels = await page.$$eval('[data-nav="modules"] > div > button', (bs) => bs.map((b) => b.textContent.trim()))
            ok(status === 200 && JSON.stringify(labels) === JSON.stringify(BAR),
               `bar on / (HTTP ${status}) = ${labels.join(' · ')} (${labels.length} buttons; Logistics right after Sales: ${labels.indexOf('Logistics') === labels.indexOf('Sales') + 1}) ⇒ production serves bd127ff / 2bb34df`)
        } finally { await page.close() }
    }
    // ② /compliance/cod
    {
        const { page, status } = await openAs(cfo, '/compliance/cod')
        try {
            const s = await page.evaluate(() => {
                const t = document.querySelector('table[data-slot="data-table"]')
                const rows = t ? [...t.querySelectorAll(':scope > tbody > tr')].filter((tr) => !tr.classList.contains('sm:hidden') && tr.querySelectorAll('td').length > 1) : []
                const main = document.querySelector('main') ?? document.body
                const controls = [...main.querySelectorAll('button, a')].map((e) => e.textContent.trim()).filter((x) => /^(issue|void)\b/i.test(x))
                return { h1: document.querySelector('h1')?.textContent.trim() ?? null, table: !!t, rows: rows.length, controls, codControls: document.querySelectorAll('[data-cod-control]').length }
            })
            ok(status === 200 && s.table && s.rows === 3 && s.rows === cods.length && s.controls.length === 0 && s.codControls === 0,
               `/compliance/cod (HTTP ${status}, h1 "${s.h1}"): ${s.rows} rows (database ${cods.length}); Issue / Void controls on the page: ${s.controls.length + s.codControls}${s.controls.length ? ' — ' + s.controls.join(', ') : ''}`)
        } finally { await page.close() }
    }
    // ③ 批次页上的证书那一块
    {
        const { page, status } = await openAs(cfo, `/inbound/${target.batch}/edit`)
        try {
            const d = await page.evaluate(() => {
                const p = document.querySelector('[data-cod-panel]')
                return p ? { panel: p.getAttribute('data-cod-panel'), buttons: p.querySelectorAll('button').length,
                             issue: !!p.querySelector('[data-cod-control="issue"]'), void: !!p.querySelector('[data-cod-control="void"]'),
                             readOnly: !!p.querySelector('[data-cod-read-only]') } : { panel: null }
            })
            ok(status === 200 && d.panel === 'reader' && !d.issue && !d.void && d.buttons === 0 && d.readOnly,
               `${BASELINE.code} on /inbound/<batch>/edit (HTTP ${status}): panel ${d.panel ?? 'MISSING'}, issue ${d.issue ? 'SHOWN' : 'none'} · void ${d.void ? 'SHOWN' : 'none'} · buttons ${d.buttons}; read-only line ${d.readOnly ? 'shown' : 'none'} (nothing pressed)`)
        } finally { await page.close() }
    }
    // ④ PDF(GET,只读)
    {
        const r = await fetch(`${BASE}/inbound/${target.batch}/cod/pdf?cod=${encodeURIComponent(BASELINE.code)}`, { headers: { cookie: `${cfo.cookieName}=${cfo.cookieValue}` }, redirect: 'manual' })
        const buf = Buffer.from(await r.arrayBuffer())
        const sha = createHash('sha256').update(buf).digest('hex')
        ok(r.status === 200 && (r.headers.get('content-type') ?? '').startsWith('application/pdf') && sha === BASELINE.sha && buf.length === BASELINE.bytes,
           `${BASELINE.code} PDF: HTTP ${r.status} ${r.headers.get('content-type')}, ${buf.length} bytes, sha256 ${sha} — AGENTS.md baseline ${sha === BASELINE.sha && buf.length === BASELINE.bytes ? 'identical' : 'DIFFERENT'}`)
    }

    { const why = abortReason('after the reader'); if (why) { console.log(`ABORT|${why}`); return finish(1) } }
    console.log(bad ? `STEP|done with ${bad} FAIL` : 'STEP|done')
    return finish(bad ? 1 : 0)
}

main().catch((e) => {
    console.error(String(e?.stack || e))
    return finish(String(e?.message || '').startsWith('CODRC_DRIVER') ? 2 : 1)
})
