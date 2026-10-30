#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// GOLIVE-2(v1.4.84)· 线上证明 —— 一次一位读者,真浏览器,对着本刀代码的 next start(PROOF_BASE)读线上的库
// ════════════════════════════════════════════════════════════════════════════
// 委托书 Step 1:"live proof, one reader at a time: a throwaway portal upload of about 9 MB that registers and is then removed; change history
//   and dictionaries open for the seven roles with their timings recorded (live is not the yardstick); the masked contract copies where live data
//   allows; nothing pressed"。
//   U  门户直传(第 9 行):一家一次性供应商(ZZ-PROBE)的一次性门户账号,在 /portal/certificates 上经【真的那张表单】交一份 ≈ 9 MB 的 PDF ——
//      ① 页面写着 V39 的上限(10 MB);② 字节走浏览器 → 存储(拦截到的那一次 storage 上传 ≈ 9 MB),发给应用(next)的每一个请求体都 < 64 KB;
//      ③ 落回 ?submitted=1;库里那一行 submitted、file_size = 文件大小,portal-uploads 里那个对象的大小 = 文件大小;
//      ④ 一份 11 MB 的文件在【任何一个字节存下之前】按名拒(PORTAL_UPLOAD_TOO_LARGE):没有新行、没有 storage 请求。
//      收尾(清理计划,先于东西落盘):申请行(按供应商)→ 存储对象(上传请求放行之前才写进计划)→ 门户链接 → 联系人 → 供应商 → 账号。
//      ★ 这是 MES9C-LIVE-STORAGE-UPLOAD-BY-POLICY-NOT-BY-API 一直没证到的那一次真的上传。
//   C  变更记录(第 13 行):七个真角色各一个克隆,/settings/change-history(show=20 · show=500)与 /settings/dictionaries 的 HTTP 与耗时;
//      不持 data.view_change_log 的读者得到具名拒绝;cfo 再取一次最近一天的导出(./export,JSON)。
//   M  合同条款副本(Q4 · Q6):线上有副本 / 条款申请就读一份(看不见价格码的读者那三样是 null);没有就照直说"线上没有可读的",不造数据。
// 中止规则(AGENTS.md「线上证明一次一位读者」):每一位读者之前与最后各量一次 —— 库里 select 1 > 50 ms · 五次往返中位数 > 1.5 s ·
//   health 不健康 → 停、收尾、报告;单次往返 > 1.5 s 记下不停。
// 判决只从最后一行 `GL2_PROOF_EXIT=` 读:0 = 全 PASS 且收尾干净 · 1 = 有 FAIL 或中止 · 2 = 驱动坏了 · 5 = live-lock 被占 · 6 = 收尾没完成。
// 用法:PROOF_BASE=http://localhost:3196 PUPPETEER_DIR=<装着 puppeteer-core 的目录> node db/scripts/2026-10-30-golive-2-live-proof.mjs
// ════════════════════════════════════════════════════════════════════════════
import { readdirSync, existsSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs'
import { join } from 'node:path'
import { homedir, tmpdir } from 'node:os'
import { createRequire } from 'node:module'
import { spawnSync } from 'node:child_process'
import { randomBytes } from 'node:crypto'
import { onlyWhenRunDirectly } from '../../scripts/lib/entrypoint.mjs'
import { acquireOrExit, release, heldBy } from '../../scripts/liveLock.mjs'
import { openPlan, planDelete, ORDER, mintThrowaway, mintThrowawaySupplier, reapStalePlans, installExitHooks, exitAfterCleanup } from '../../scripts/ephemeral.mjs'

onlyWhenRunDirectly(import.meta.url)

const BASE = process.env.PROOF_BASE || 'http://localhost:3196'
const PUP_DIR = process.env.PUPPETEER_DIR
const CHROME_ROOT = join(homedir(), '.cache/puppeteer/chrome-headless-shell')
const DSN = process.env.CHECK_MIRRORS_DSN || 'host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 user=postgres.wvywpohbwkiinmipmuku dbname=postgres'
const SCRIPT = 'db/scripts/2026-10-30-golive-2-live-proof.mjs'
const ROLES = ['admin', 'warehouse', 'cfo', 'cco', 'cto', 'finance', 'gm']
const ONLY = process.env.PROOF_ONLY || null      // 'upload' | 'pages' —— 只跑那一段(重跑一段时用)

let locked = false, bad = 0, browser = null, tmp = null
const ok = (cond, what) => { console.log(`${cond ? 'PASS' : 'FAIL'}|${what}`); if (!cond) bad++; return cond }
const warnings = []

installExitHooks({
    onFinish: (code) => {
        try { if (locked) release() } catch { /* 放锁失败不改判决 */ }
        try { if (tmp) rmSync(tmp, { recursive: true, force: true }) } catch { /* 临时文件 */ }
        for (const w of warnings) console.log(w)
        console.log('AFTER|committed on live by this run: the throwaway supplier, contact, portal account and link, one certificate submission and its stored object, and the throwaway staff clones with their roles and grants — every one of them on the cleanup plan; nothing else was pressed')
        console.log(`GL2_PROOF_EXIT=${code}`)
    },
})

function psql(sql) {
    const r = spawnSync('psql', [DSN, '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-f', '-'], { input: sql, encoding: 'utf8', timeout: 120_000 })
    if (r.status !== 0) throw new Error(`GL2_DRIVER|psql exit ${r.status}: ${(r.stderr ?? '').split('\n').slice(-4).join(' / ')}`)
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
function health() {
    const tok = spawnSync('security', ['find-generic-password', '-s', 'Supabase CLI', '-w'], { encoding: 'utf8' }).stdout.trim()
    const r = spawnSync('curl', ['-s', '-m', '40', '-A', 'curl/8.4.0', '-H', `Authorization: Bearer ${tok}`,
        'https://api.supabase.com/v1/projects/wvywpohbwkiinmipmuku/health?services=db&services=rest'], { encoding: 'utf8', timeout: 60_000 })
    try { return JSON.parse(r.stdout).map((x) => `${x.name}=${x.status}`) } catch { return ['health=UNREADABLE'] }
}
function abortReason(tag) {
    const sel = selectOne(tag)
    if (sel.max > 1500) { const w = `WARN|${tag}: a single round trip took ${sel.max.toFixed(0)} ms (> 1500 ms; recorded, not an abort)`; warnings.push(w); console.log(w) }
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

const hydrated = (sel) => `(() => { const e = document.querySelector(${JSON.stringify(sel)}); return !!e && Object.keys(e).some((k) => k.startsWith('__react')) })()`
async function pageAs(reader) {
    if (!reader.ctx) reader.ctx = await browser.createBrowserContext()
    const page = await reader.ctx.newPage()
    await page.setViewport({ width: 1440, height: 900 })
    const cdp = await page.createCDPSession()
    const host = new URL(BASE).hostname
    await cdp.send('Network.setCookies', { cookies: [
        { name: reader.cookieName, value: reader.cookieValue, domain: host, path: '/' },
        { name: 'NEXT_LOCALE', value: 'en', domain: host, path: '/' },
    ] })
    return page
}
async function timedGet(reader, path) {
    const t0 = Date.now()
    const r = await fetch(BASE + path, { headers: { cookie: `${reader.cookieName}=${reader.cookieValue}; NEXT_LOCALE=en` }, redirect: 'manual' })
    const html = await r.text()
    return { status: r.status, ms: Date.now() - t0, html, denied: /data-access-denied="1"/.test(html) }
}
/** 一份有效 PDF 文件头、其余随机字节的文件 */
function makePdf(name, bytes) {
    const head = Buffer.from('%PDF-1.4\n%GOLIVE-2 live proof — throwaway, removed by the cleanup plan\n')
    const p = join(tmp, name)
    writeFileSync(p, Buffer.concat([head, randomBytes(bytes - head.length)]))
    return p
}

async function proveUpload() {
    { const why = abortReason('before the portal reader'); if (why) { console.log(`ABORT|${why}`); return false } }
    const sup = await mintThrowawaySupplier({ prefix: 'gl2probe', label: 'upload' })
    const supplierId = sup.id ?? sup.supplierId
    // 申请行按供应商删(先于任何一次上传落盘;它指着门户链接与供应商,都是 RESTRICT,所以排在 PORTAL_LINK 之前)
    planDelete(`/rest/v1/portal_certificate_submissions?supplier_id=eq.${supplierId}`, `删一次性供应商的证书申请 ${supplierId}`, ORDER.OTHER)
    const portal = await mintThrowaway({ prefix: 'gl2probe', label: 'portal', stamp: Date.now(), codes: { portalOf: supplierId } })
    const limits = psql(`SELECT 'PROOF|' || portal_upload_max_bytes || '|' || array_to_string(portal_upload_types, ',') FROM account_settings LIMIT 1;`)[0]?.split('|')
    const maxBytes = Number(limits?.[0])
    console.log(`STEP|V39 (account_settings, as postgres): max ${maxBytes} bytes · types ${limits?.[1]}`)

    const page = await pageAs(portal)
    page.on('console', (m) => { if (['error', 'warn'].includes(m.type())) console.log(`CONSOLE|${m.type()}|${m.text().slice(0, 300)}`) })
    page.on('pageerror', (e) => console.log(`PAGEERROR|${String(e).slice(0, 300)}`))
    page.on('requestfailed', (r) => console.log(`REQFAILED|${r.method()} ${r.url().slice(0, 160)} ${r.failure()?.errorText ?? ''}`))
    /** 按下提交,等地址栏落到 re;等不到就说出它落在哪里、页面上写着什么(而不是只抛一个 TimeoutError) */
    const submitAndWait = async (re, timeout) => {
        try {
            await Promise.all([page.waitForFunction((src) => new RegExp(src).test(location.search), { timeout }, re.source),
                               page.click('[data-form="portal-upload"] button[type="submit"]')])
            return true
        } catch (e) {
            const st = await page.evaluate(() => ({ url: location.href, busy: !!document.querySelector('[data-upload-busy]'),
                notice: document.querySelector('[data-upload-notice]')?.textContent.trim() ?? null })).catch(() => null)
            console.log(`STEP|submit did not land on ${re}: ${String(e).slice(0, 120)} · page ${JSON.stringify(st)} · requests to the app ${JSON.stringify(toApp.slice(-4))}`)
            return false
        }
    }
    const toApp = [], toStorage = []
    await page.setRequestInterception(true)
    page.on('request', (req) => {
        const u = req.url()
        if (u.startsWith(BASE) && req.method() !== 'GET') {
            const len = Number(req.headers()['content-length'] ?? (req.postData()?.length ?? 0))
            toApp.push({ url: u.replace(BASE, ''), method: req.method(), len })
        }
        const m = u.match(/\/storage\/v1\/object\/portal-uploads\/([^?]+)/)
        if (m && req.method() !== 'GET' && req.method() !== 'OPTIONS') {
            const objPath = decodeURIComponent(m[1])
            // ★ 先把删它的那一步落盘,再放行这次上传(LEAK-1:计划先于东西)
            planDelete('/storage/v1/object/portal-uploads', `删一次性证书文件 ${objPath}`, ORDER.OTHER,
                { method: 'DELETE', body: JSON.stringify({ prefixes: [objPath] }), headers: { 'Content-Type': 'application/json' } })
            toStorage.push({ path: objPath, method: req.method(), len: Number(req.headers()['content-length'] ?? 0) })
        }
        req.continue()
    })
    try {
        const res = await page.goto(BASE + '/portal/certificates', { waitUntil: 'networkidle2', timeout: 120_000 })
        await page.waitForFunction(hydrated('[data-form="portal-upload"] button[type="submit"]'), { timeout: 60_000 }).catch(() => {})
        const lim = await page.evaluate(() => document.querySelector('[data-limits="set"]')?.textContent.trim() ?? null)
        ok(res?.status() === 200 && !!lim && lim.includes(String(Math.round(maxBytes / 1048576))),
           `U /portal/certificates (HTTP ${res?.status()}): the page states "${lim}" — V39 says ${maxBytes} bytes`)
        // 版式(委托书:门户上传页 390 px 与桌面):整页不横向溢出
        for (const w of [1440, 390]) {
            await page.setViewport({ width: w, height: w < 768 ? 844 : 900, isMobile: w < 768, hasTouch: w < 768 })
            await page.goto(BASE + '/portal/certificates', { waitUntil: 'networkidle2', timeout: 120_000 })
            const g = await page.evaluate(() => ({ sw: document.documentElement.scrollWidth, iw: window.innerWidth }))
            ok(g.sw <= g.iw + 1, `U layout ${w}px /portal/certificates: page ${g.sw}px wide in a ${g.iw}px window — no sideways scroll`)
        }
        await page.setViewport({ width: 1440, height: 900 })
        await page.goto(BASE + '/portal/certificates', { waitUntil: 'networkidle2', timeout: 120_000 })
        await page.waitForFunction(hydrated('[data-form="portal-upload"] button[type="submit"]'), { timeout: 60_000 }).catch(() => {})
        const form = await page.$('[data-form="portal-upload"]')
        ok(!!form && (await page.evaluate(() => document.querySelector('[data-form="portal-upload"]')?.getAttribute('data-upload-path'))) === 'direct',
           'U the upload form is the direct-to-storage one (data-upload-path="direct"); the old multipart route is gone')

        // ④ 先证拒:11 MB → 库在任何一个字节存下之前按名拒
        const big = makePdf('golive2-11mb.pdf', 11 * 1024 * 1024)
        await page.select('select[name="cert_type"]', await page.$eval('select[name="cert_type"] option:not([disabled])', (o) => o.value))
        await (await page.$('input[type="file"][name="file"]')).uploadFile(big)
        const nStore0 = toStorage.length
        await submitAndWait(/[?&]error=/, 120_000)
        const code = new URL(page.url()).searchParams.get('error')
        const rowsBig = Number(psql(`SELECT 'PROOF|' || count(*) FROM portal_certificate_submissions WHERE supplier_id = '${supplierId}';`)[0])
        ok(code === 'PORTAL_UPLOAD_TOO_LARGE' && toStorage.length === nStore0 && rowsBig === 0,
           `U an 11 MB file (11,534,336 bytes) → ?error=${code}; storage requests ${toStorage.length - nStore0}; submission rows ${rowsBig} — refused before a byte was stored`)

        // ①–③ 9 MB 交上去
        await page.goto(BASE + '/portal/certificates', { waitUntil: 'networkidle2', timeout: 120_000 })
        await page.waitForFunction(hydrated('[data-form="portal-upload"] button[type="submit"]'), { timeout: 60_000 }).catch(() => {})
        const size = 9 * 1024 * 1024 + 4321
        const file = makePdf('golive2-9mb.pdf', size)
        await page.select('select[name="cert_type"]', await page.$eval('select[name="cert_type"] option:not([disabled])', (o) => o.value))
        await page.type('input[name="cert_no"]', 'ZZ-GOLIVE2-PROOF')
        await (await page.$('input[type="file"][name="file"]')).uploadFile(file)
        const t0 = Date.now()
        await submitAndWait(/[?&](submitted|error)=/, 300_000)
        const ms = Date.now() - t0
        const landed = new URL(page.url()).searchParams
        const notice = await page.evaluate(() => document.querySelector('[data-upload-notice]')?.getAttribute('data-upload-notice') ?? null)
        ok(landed.get('submitted') === '1' && notice === 'ok', `U a ${size}-byte PDF → landed on ?${landed.toString()} (notice "${notice}") in ${(ms / 1000).toFixed(1)} s`)
        const biggestToApp = Math.max(0, ...toApp.map((r) => r.len))
        const up = toStorage[toStorage.length - 1]
        ok(!!up && up.method === 'POST' && toApp.every((r) => r.len < 64 * 1024),
           `U bytes went browser → storage: storage ${up ? `${up.method} portal-uploads/${up.path}` : 'NONE'}; requests to the app ${toApp.length}, largest body ${biggestToApp} bytes (< 65,536)`)
        const row = psql(`SELECT 'PROOF|' || s.status || '|' || s.file_size || '|' || s.file_type || '|' || s.storage_path || '|' || coalesce((o.metadata ->> 'size'), 'none')
                            FROM portal_certificate_submissions s LEFT JOIN storage.objects o ON o.bucket_id = 'portal-uploads' AND o.name = s.storage_path
                           WHERE s.supplier_id = '${supplierId}' ORDER BY s.created_at;`)
        console.log(`STEP|database as postgres: ${row.length} submission row(s): ${row.join(' ; ')}`)
        const last = row[row.length - 1]?.split('|') ?? []
        ok(row.length === 1 && last[0] === 'submitted' && Number(last[1]) === size && last[2] === 'application/pdf' && Number(last[4]) === size && (!up || last[3] === up.path),
           `U one submission, status submitted, file_size ${last[1]}, stored object ${last[4]} bytes at the registered path — registered and confirmed`)
    } finally {
        await page.close()
    }
    { const why = abortReason('after the portal reader'); if (why) { console.log(`ABORT|${why}`); return false } }
    return true
}

async function provePages() {
    const perms = Object.fromEntries(psql(`SELECT 'PROOF|' || r.code || '|' || coalesce(string_agg(rp.permission_code, ',' ORDER BY rp.permission_code), '')
        FROM roles r LEFT JOIN role_permissions rp ON rp.role_id = r.id WHERE r.code IN (${ROLES.map((r) => `'${r}'`).join(',')}) GROUP BY r.code;`)
        .map((l) => { const [c, p] = l.split('|'); return [c, p.split(',')] }))
    for (const role of ROLES) {
        { const why = abortReason(`before ${role}`); if (why) { console.log(`ABORT|${why}`); return false } }
        const reader = await mintThrowaway({ prefix: 'gl2probe', label: `pages-${role}`, stamp: Date.now(), codes: { cloneOf: role } })
        const canLog = perms[role]?.includes('data.view_change_log')
        for (const show of [20, 500]) {
            const g = await timedGet(reader, `/settings/change-history${show === 20 ? '' : `?show=${show}`}`)
            const entries = (g.html.match(/data-trail-entry/g) ?? []).length
            const stop = /data-change-history-stop/.test(g.html)
            ok(g.status === 200 && g.denied === !canLog,
               `C ${role} /settings/change-history${show === 20 ? '' : `?show=${show}`}: HTTP ${g.status} in ${(g.ms / 1000).toFixed(1)} s — ${g.denied ? 'named refusal (no data.view_change_log)' : `${entries} entry marker(s)${stop ? ', the 500 stop notice' : ''}`}`)
            console.log(`TIME|${role}|change-history show=${show}|${g.ms}`)
        }
        const d = await timedGet(reader, '/settings/dictionaries')
        const sections = (d.html.match(/data-audit-trail=/g) ?? []).length
        ok(d.status === 200, `D ${role} /settings/dictionaries: HTTP ${d.status} in ${(d.ms / 1000).toFixed(1)} s — ${d.denied || /data-state="restricted"/.test(d.html) ? 'restricted' : `${sections} dictionary section(s) (one audit trail each)`}`)
        console.log(`TIME|${role}|dictionaries|${d.ms}`)
        if (role === 'cfo') {
            const today = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Singapore' }).format(new Date())
            const t0 = Date.now()
            const r = await fetch(`${BASE}/settings/change-history/export?from=${today}&to=${today}`, { headers: { cookie: `${reader.cookieName}=${reader.cookieValue}; NEXT_LOCALE=en`, accept: 'application/json' } })
            const body = await r.json().catch(() => null)
            const n = Number(psql(`SELECT 'PROOF|' || count(*) FROM change_log WHERE occurred_at >= '${today}'::date::timestamptz AND occurred_at < ('${today}'::date + 1)::timestamptz;`)[0])
            ok(r.status === 200 && Array.isArray(body?.rows) && body.changes === n,
               `C cfo export ${today}..${today}: HTTP ${r.status} in ${((Date.now() - t0) / 1000).toFixed(1)} s — ${body?.changes ?? '?'} recorded changes counted (postgres reads ${n} in the base table), ${body?.rows?.length ?? '?'} file rows (one per field changed)`)
            const tooLong = await fetch(`${BASE}/settings/change-history/export?from=2025-01-01&to=2026-12-31`, { headers: { cookie: `${reader.cookieName}=${reader.cookieValue}`, accept: 'application/json' } })
            ok(tooLong.status === 400 && (await tooLong.json().catch(() => ({}))).code === 'EXPORT_RANGE_TOO_LONG', `C cfo export over 730 days: HTTP ${tooLong.status} EXPORT_RANGE_TOO_LONG (Q7: at most 366 days)`)
        }
    }
    { const why = abortReason('after the last reader'); if (why) { console.log(`ABORT|${why}`); return false } }
    return true
}

function proveCopies() {
    const n = psql(`SELECT 'PROOF|' || (SELECT count(*) FROM contract_document_terms) || '|' || (SELECT count(*) FROM terms_requests WHERE contract_id IS NOT NULL) || '|' || (SELECT count(*) FROM contracts);`)[0].split('|')
    if (Number(n[0]) === 0 && Number(n[1]) === 0) {
        console.log(`STEP|M live data does not allow the masked-copy reading: contract_document_terms ${n[0]} rows · contract terms requests ${n[1]} · contracts ${n[2]} (postgres, base tables). Fixture 304 proves the masking on the rebuild; nothing was created on live to show it.`)
        return
    }
    console.log(`STEP|M live holds ${n[0]} frozen copies and ${n[1]} contract terms requests — reading them is a separate, read-only step (not reached today)`)
}

async function main() {
    const other = heldBy()
    if (other) { console.error(`✗ live-lock 被【${other.holder}】(pid ${other.pid})占着`); return exitAfterCleanup(5) }
    acquireOrExit(SCRIPT, { ownExit: false })
    locked = true
    openPlan(SCRIPT)
    await reapStalePlans()
    if (!PUP_DIR || !existsSync(join(PUP_DIR, 'node_modules/puppeteer-core'))) throw new Error('GL2_DRIVER|PUPPETEER_DIR has no node_modules/puppeteer-core')
    const puppeteer = createRequire(join(PUP_DIR, 'package.json'))('puppeteer-core')
    const ver = readdirSync(CHROME_ROOT).sort().pop()
    const exe = join(CHROME_ROOT, ver, 'chrome-headless-shell-mac-arm64', 'chrome-headless-shell')
    if (!existsSync(exe)) throw new Error(`GL2_DRIVER|no chrome-headless-shell at ${exe}`)
    tmp = mkdtempSync(join(tmpdir(), 'gl2proof-'))
    console.log(`STEP|base ${BASE}`)
    browser = await puppeteer.launch({ executablePath: exe, headless: true, args: ['--no-sandbox'] })
    if (!ONLY || ONLY === 'upload') { if (!(await proveUpload())) return finish(1) }
    if (!ONLY || ONLY === 'pages') { if (!(await provePages())) return finish(1) }
    if (!ONLY || ONLY === 'copies') proveCopies()
    console.log(bad ? `STEP|done with ${bad} FAIL` : 'STEP|done')
    return finish(bad ? 1 : 0)
}

main().catch((e) => {
    console.error(String(e?.stack || e))
    return finish(String(e?.message || '').startsWith('GL2_DRIVER') ? 2 : 1)
})
