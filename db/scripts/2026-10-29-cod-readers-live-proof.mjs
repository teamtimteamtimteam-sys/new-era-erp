#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// COD-READERS(v1.4.81,Tim 2026-10-29)· 线上证明 —— 七个角色、一次一位,真浏览器读屏幕;读库的那几句只数行 / 取哈希(以 postgres 读基表)
// ════════════════════════════════════════════════════════════════════════════
// 委托书 Step 1:"live proof, one reader at a time, all seven roles: who sees the list, opens a COD and its PDF, and who sees the write
//   controls (only admin and warehouse); nothing pressed" + 加的 D:"each of the seven roles' rendered bar and its Logistics and Sales menus,
//   every row under exactly one module"。一次性账号 = 每个真角色一个克隆(共用造号器,codes: { cloneOf },前缀 codrprobe)。
//   N  顶栏:十个按钮(物流紧跟销售);逐个点开读每一行;每一条条目在【恰好一个】模块底下;物流与销售两张菜单与注册表逐条相同(进得去 / 受限)。
//   L  /compliance/cod:持 data.view_cod 的进得去、画表、行数 = 库里的行数、每一张已签发 / 作废的有一条 PDF 链接;不持的具名拒绝。
//   D  每一张证书所在的批次页(/inbound/<id>/edit):证书那一块在、编号对;签发人(action.issue_cod)看得见写的控件,读者一个都看不见、
//      也看不见内部存档那条链接,看得见「只读」那一句。
//   F  每一张已签发证书的 PDF(GET …/cod/pdf?cod=<号>,只读):200、application/pdf、字节的 sha256 = cod_issues.sha256 = AGENTS.md 的基线。
//   S  /documents/cod(全局搜索的落点):读者进得去。
//   G  390 抽屉:十个模块行 + 工具区 + 设置区,不横向溢出;顶栏几何:1024 · 1280 · 1366 · 1440,英文与中文,在一张带搜索框的页面上(/tools/calendar)。
// 中止规则(AGENTS.md「线上证明一次一位读者」,本刀改过的那一版):库里 select 1 > 50 ms · 五次往返中位数 > 1.5 s · health 不健康 → 停、收尾、报告;
//   单次往返 > 1.5 s 记下不停;一次 DOCUMENT_CHAIN_WALK_BUDGET 拒绝在库那一侧正常时【记下不停】(Tim 2026-10-29,免费档不升)。
// 只读:浏览器只发 GET、点菜单;一个按钮都不按(签发、作废一概不碰)。线上提交的只有一次性账号、它们的角色与授权,由清理计划收走。
// PROOF_ONLY=geometry 只跑 G 的几何那一段(admin 一位;选分界用,在整门之前)。
// 判决只从最后一行 `CODR_PROOF_EXIT=` 读:0 = 全 PASS 且收尾干净 · 1 = 有 FAIL 或中止 · 2 = 驱动坏了 · 5 = live-lock 被占 · 6 = 收尾没完成。
// 用法:PROOF_BASE=http://localhost:3195 PUPPETEER_DIR=<装着 puppeteer-core 的目录> [PROOF_JSON=<out.json>] [PROOF_ONLY=geometry] node db/scripts/2026-10-29-cod-readers-live-proof.mjs
// ════════════════════════════════════════════════════════════════════════════
import { readdirSync, existsSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { homedir } from 'node:os'
import { createHash } from 'node:crypto'
import { createRequire } from 'node:module'
import { spawnSync } from 'node:child_process'
import { pathToFileURL } from 'node:url'
import { onlyWhenRunDirectly } from '../../scripts/lib/entrypoint.mjs'
import { acquireOrExit, release, heldBy } from '../../scripts/liveLock.mjs'
import { openPlan, mintThrowaway, reapStalePlans, installExitHooks, exitAfterCleanup } from '../../scripts/ephemeral.mjs'

onlyWhenRunDirectly(import.meta.url)

const BASE = process.env.PROOF_BASE || 'http://localhost:3195'
const PUP_DIR = process.env.PUPPETEER_DIR
const OUT_JSON = process.env.PROOF_JSON || null
const ONLY = process.env.PROOF_ONLY || null
const CHROME_ROOT = join(homedir(), '.cache/puppeteer/chrome-headless-shell')
const DSN = process.env.CHECK_MIRRORS_DSN || 'host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 user=postgres.wvywpohbwkiinmipmuku dbname=postgres'
const SCRIPT = 'db/scripts/2026-10-29-cod-readers-live-proof.mjs'
const ROLES = ONLY === 'geometry' ? ['admin'] : ['admin', 'warehouse', 'cfo', 'cco', 'cto', 'finance', 'gm']
const ISSUERS = new Set(['admin', 'warehouse'])
// AGENTS.md「两张已签发的 COD —— 字节基线」
const BASELINE = {
    'COD-2026-0001': { bytes: 34701, sha: 'ba299a4f3488fc543cdd1f410fabf6523434d39caa0dc58d6f376309c1f42101' },
    'COD-2026-0002': { bytes: 34746, sha: '717661f6a8166b5f9342324586208e21f29c217aa5d3c047b009e00f2513a4f9' },
}
const BAR_EN = { workbench: 'Workbench', purchasing: 'Purchasing', production: 'Production', quality: 'Quality', sales: 'Sales', logistics: 'Logistics',
    finance: 'Finance', people: 'People', safety: 'Safety', equipment: 'Equipment' }

let locked = false, bad = 0, browser = null
const ok = (cond, what) => { console.log(`${cond ? 'PASS' : 'FAIL'}|${what}`); if (!cond) bad++; return cond }

installExitHooks({
    onFinish: (code) => {
        try { if (locked) release() } catch { /* 放锁失败不改判决 */ }
        console.log('AFTER|nothing but the throwaway accounts, their roles and grants was committed (removed by the plan); the browser only sent GETs and opened menus')
        console.log(`CODR_PROOF_EXIT=${code}`)
    },
})

function psql(sql) {
    const r = spawnSync('psql', [DSN, '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-f', '-'], { input: sql, encoding: 'utf8', timeout: 120_000 })
    if (r.status !== 0) throw new Error(`CODR_DRIVER|psql exit ${r.status}: ${(r.stderr ?? '').split('\n').slice(-4).join(' / ')}`)
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

/** Management API 的健康检查(只读;只取 name/status 两个字段) */
function health() {
    const tok = spawnSync('security', ['find-generic-password', '-s', 'Supabase CLI', '-w'], { encoding: 'utf8' }).stdout.trim()
    const r = spawnSync('curl', ['-s', '-m', '40', '-A', 'curl/8.4.0', '-H', `Authorization: Bearer ${tok}`,
        'https://api.supabase.com/v1/projects/wvywpohbwkiinmipmuku/health?services=db&services=rest'], { encoding: 'utf8', timeout: 60_000 })
    try { return JSON.parse(r.stdout).map((x) => `${x.name}=${x.status}`) } catch { return ['health=UNREADABLE'] }
}

const warnings = []
function abortReason(tag) {
    const sel = selectOne(tag)
    if (sel.max > 1500) { const w = `WARN|${tag}: a single round trip took ${sel.max.toFixed(0)} ms (> 1500 ms; recorded, not an abort)`; warnings.push(w); console.log(w) }
    if (!(sel.exec <= 50)) return `${tag}: select 1 inside the database took ${sel.exec} ms (> 50 ms)`
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

const hydrated = (sel) => `(() => { const e = document.querySelector(${JSON.stringify(sel)}); return !!e && Object.keys(e).some((k) => k.startsWith('__react')) })()`

async function openAs(reader, path, { width = 1440, height = 900, locale = 'en', waitFor = '[data-nav="avatar-menu"] button' } = {}) {
    if (!reader.ctx) reader.ctx = await browser.createBrowserContext()
    const page = await reader.ctx.newPage()
    await page.setViewport({ width, height, deviceScaleFactor: 1, isMobile: width < 768, hasTouch: width < 768 })
    const cdp = await page.createCDPSession()
    const host = new URL(BASE).hostname
    await cdp.send('Network.setCookies', { cookies: [
        { name: reader.cookieName, value: reader.cookieValue, domain: host, path: '/' },
        { name: 'NEXT_LOCALE', value: locale, domain: host, path: '/' },
    ] })
    const res = await page.goto(BASE + path, { waitUntil: 'networkidle2', timeout: 120_000 })
    if (waitFor) await page.waitForFunction(hydrated(waitFor), { timeout: 60_000 }).catch(() => {})
    return { page, status: res?.status() }
}

/** 顶栏按钮逐个点开,读每一行。 */
async function readBarMenus(page) {
    const n = await page.$$eval('[data-nav="modules"] > div > button', (bs) => bs.length)
    const out = []
    for (let i = 0; i < n; i++) {
        const btns = await page.$$('[data-nav="modules"] > div > button')
        const meta = await btns[i].evaluate((b) => ({ label: b.textContent.trim(), title: b.getAttribute('title'), restricted: b.hasAttribute('data-module-restricted') }))
        await btns[i].click()
        await page.waitForSelector('[data-nav="modules"] [role="menu"]', { timeout: 10_000 })
        const rows = await page.$$eval('[data-nav="modules"] [role="menu"] [data-menu-href]', (rs) => rs.map((r) => ({ href: r.getAttribute('data-menu-href'), restricted: r.hasAttribute('data-module-restricted') })))
        out.push({ ...meta, rows })
        await btns[i].click()
        await page.waitForFunction(() => !document.querySelector('[data-nav="modules"] [role="menu"]'), { timeout: 10_000 }).catch(() => {})
    }
    return out
}

/** 顶栏几何(只读;反事实那一格注入一条样式再撤掉) */
async function geometry(reader, report) {
    for (const locale of ['en', 'zh']) {
        for (const width of [1024, 1280, 1366, 1440]) {
            const { page } = await openAs(reader, '/tools/calendar', { width, height: 900, locale })
            try {
                const g = await page.evaluate(() => {
                    const vis = (e) => !!e && getComputedStyle(e).display !== 'none' && e.getBoundingClientRect().width > 0
                    const row = document.querySelector('[data-nav="modules"]')
                    const btn = document.querySelector('[data-nav="menu-button"]')
                    const right = document.querySelector('[data-nav="avatar-menu"]')?.parentElement
                    const sh = document.querySelector('header [data-nav="search-shell"], header [data-nav="search-trigger"]')
                    const search = vis(sh)
                    const rowR = vis(row) ? row.getBoundingClientRect() : null
                    const lastBtn = vis(row) ? [...row.querySelectorAll(':scope > div > button')].at(-1)?.getBoundingClientRect() : null
                    const rightR = right?.getBoundingClientRect()
                    return { docW: document.documentElement.scrollWidth, vw: innerWidth, search, mode: vis(row) ? 'module row' : vis(btn) ? 'menu drawer' : 'NEITHER',
                             buttons: vis(row) ? row.querySelectorAll(':scope > div > button').length : null,
                             rowW: rowR ? Math.round(rowR.width * 10) / 10 : null, lastRight: lastBtn ? Math.round(lastBtn.right) : null, rightLeft: rightR ? Math.round(rightR.left) : null }
                })
                // 反事实:把模块条硬画出来(在模块条已经画着的宽度上也量一次,同一个读法),它放得下吗、要多宽才放得下
                const cf = await page.evaluate(() => {
                    const st = document.createElement('style')
                    st.textContent = '[data-nav="modules"]{display:flex!important}[data-nav="menu-button"]{display:none!important}'
                    document.head.appendChild(st)
                    const row = document.querySelector('[data-nav="modules"]')
                    const btns = [...row.querySelectorAll(':scope > div > button')]
                    const last = btns.at(-1)?.getBoundingClientRect()
                    const right = document.querySelector('[data-nav="avatar-menu"]')?.parentElement?.getBoundingClientRect()
                    const r = { buttons: btns.length, rowW: Math.round(row.getBoundingClientRect().width * 10) / 10, lastRight: Math.round(last?.right ?? 0), rightLeft: Math.round(right?.left ?? 0), docW: document.documentElement.scrollWidth }
                    st.remove()
                    return r
                })
                const spare = cf.rightLeft - cf.lastRight
                // 右边那一组靠 ml-auto 贴右:视口每宽 1px,它的左缘就右移 1px —— 于是放得下的最窄宽度 = 此刻宽度 − 余量
                const narrowest = width - spare
                const rec = { locale, width, ...g, counterfactual: cf, spare, narrowestFit: narrowest }
                report.push(rec)
                console.log(`WIDTH|${locale} ${width}px /tools/calendar (search box ${g.search ? 'drawn' : 'NOT drawn'}): ${g.mode}; the ${cf.buttons}-button row measures ${cf.rowW}px, last button ends ${cf.lastRight}px, right group starts ${cf.rightLeft}px → spare ${spare}px (fits from ${narrowest}px); page ${g.docW}px wide`)
                const fits = g.mode !== 'module row' || (g.lastRight !== null && g.rightLeft !== null && g.lastRight <= g.rightLeft)
                ok(g.docW <= g.vw && g.mode !== 'NEITHER' && fits && g.search,
                   `G ${reader.label} ${locale} ${width}px /tools/calendar: ${g.mode}${g.rowW ? ` (${g.buttons} buttons, row ${g.rowW}px, last button ends ${g.lastRight}px, right group starts ${g.rightLeft}px)` : ''}; page ${g.docW}px wide, no sideways scroll`)
            } finally { await page.close() }
        }
    }
}

async function main() {
    const other = heldBy()
    if (other) { console.error(`✗ live-lock 被【${other.holder}】(pid ${other.pid})占着`); return exitAfterCleanup(5) }
    acquireOrExit(SCRIPT, { ownExit: false })
    locked = true
    openPlan(SCRIPT)
    await reapStalePlans()

    if (!PUP_DIR || !existsSync(join(PUP_DIR, 'node_modules/puppeteer-core'))) throw new Error('CODR_DRIVER|PUPPETEER_DIR has no node_modules/puppeteer-core')
    const puppeteer = createRequire(join(PUP_DIR, 'package.json'))('puppeteer-core')
    const ver = readdirSync(CHROME_ROOT).sort().pop()
    const exe = join(CHROME_ROOT, ver, 'chrome-headless-shell-mac-arm64', 'chrome-headless-shell')
    if (!existsSync(exe)) throw new Error(`CODR_DRIVER|no chrome-headless-shell at ${exe}`)
    try { const r = await fetch(BASE + '/login', { redirect: 'manual' }); if (r.status !== 200) throw new Error(`HTTP ${r.status}`) }
    catch (e) { throw new Error(`CODR_DRIVER|no app at ${BASE}: ${e.message}`) }
    browser = await puppeteer.launch({ executablePath: exe, headless: true, args: ['--no-sandbox'] })

    const reg = await import(pathToFileURL(join(process.cwd(), 'lib/modules.ts')).href)
    const report = { geometry: [], roles: {}, warnings }

    // ── 库(以 postgres 读基表):每一张证书、它的存档哈希 ─────────────────────
    const cods = psql(`SELECT 'PROOF|' || c.id || ',' || coalesce(c.code, '') || ',' || c.status || ',' || c.inbound_batch_id || ',' || coalesce(i.sha256, '')
                         FROM certificates_of_destruction c LEFT JOIN cod_issues i ON i.cod_id = c.id ORDER BY c.created_at, c.id;`)
        .map((l) => { const [id, code, status, batch, sha] = l.split(','); return { id, code: code || null, status, batch, sha: sha || null } })
    console.log(`STEP|database as postgres (base tables): ${cods.length} certificates — ${cods.map((c) => `${c.code ?? '(no number)'} ${c.status}`).join(' · ')}`)
    const stored = cods.filter((c) => c.status !== 'pending' && c.code)

    const stamp = Date.now()
    for (const role of ROLES) {
        { const why = abortReason(`before ${role}`); if (why) { console.log(`ABORT|${why}`); return finish(1) } }
        const reader = await mintThrowaway({ prefix: 'codrprobe', label: role, stamp, codes: { cloneOf: role } })
        reader.label = role
        const perms = reader.codes
        const rr = (report.roles[role] = {})

        if (ONLY === 'geometry') { await geometry(reader, report.geometry); continue }

        const canView = perms.includes('data.view_cod'), canIssue = perms.includes('action.issue_cod')
        ok(canView === true && canIssue === ISSUERS.has(role), `R ${role}: the clone holds data.view_cod ${canView} · action.issue_cod ${canIssue} (ruled: view yes · issue ${ISSUERS.has(role) ? 'yes' : 'no'})`)

        // ── N · 顶栏与菜单 ───────────────────────────────────────────────────
        {
            const { page } = await openAs(reader, '/', { waitFor: '[data-nav="modules"] > div > button' })
            try {
                const menus = await readBarMenus(page)
                rr.bar = menus
                const barIds = reg.BAR_MODULE_IDS
                const labels = menus.map((m) => m.label)
                ok(JSON.stringify(labels) === JSON.stringify(barIds.map((id) => BAR_EN[id])) && labels.length === 10,
                   `N ${role}: bar = ${labels.join(' · ')} (${labels.length} buttons)`)
                const homes = new Map(); const mismatch = []
                menus.forEach((m, i) => {
                    const id = barIds[i]
                    const want = reg.MENU_FUNCTIONS.filter((f) => f.modules[0] === id)
                    for (const r of m.rows) homes.set(r.href, [...(homes.get(r.href) ?? []), id])
                    // 集合相同(财务按第三级分组画,顺序不是数组顺序 —— 第一跑在这里误报过);物流与销售两张的【顺序】下面逐条另判
                    if (JSON.stringify(m.rows.map((r) => r.href).sort()) !== JSON.stringify(want.map((f) => f.href).sort())) mismatch.push(`${id}: rows ${m.rows.map((r) => r.href).join(',')} ≠ registry ${want.map((f) => f.href).join(',')}`)
                    for (const f of want) {
                        const r = m.rows.find((x) => x.href === f.href)
                        const open = reg.allows(f.permission, perms)
                        if (r && r.restricted === open) mismatch.push(`${f.href}: ${r.restricted ? 'restricted' : 'open'} on screen, registry says ${open ? 'open' : 'restricted'}`)
                    }
                })
                const multi = [...homes].filter(([, ids]) => ids.length !== 1)
                ok(multi.length === 0 && homes.size > 0, `N ${role}: ${homes.size} entries rendered across 10 modules, each under exactly one module${multi.length ? ' — DUPLICATES ' + multi.map(([h, ids]) => `${h}@${ids}`).join(', ') : ''}`)
                ok(mismatch.length === 0, `N ${role}: every row matches the registry for this role (same rows, open/restricted)${mismatch.length ? ' — ' + mismatch.join('; ') : ''}`)
                const lg = menus[barIds.indexOf('logistics')], sl = menus[barIds.indexOf('sales')]
                const fmt = (m) => m.rows.map((r) => `${r.href}${r.restricted ? ' (restricted)' : ''}`).join(' · ')
                ok(JSON.stringify(lg.rows.map((r) => r.href)) === JSON.stringify(['/logistics', '/logistics/containers', '/logistics/forwarders', '/logistics/lanes', '/logistics/shipping', '/finance/freight']) && lg.title?.startsWith('Logistics'),
                   `N ${role}: Logistics menu (title "${lg.title}") = ${fmt(lg)}`)
                ok(JSON.stringify(sl.rows.map((r) => r.href)) === JSON.stringify(['/sales', '/sales/quotes', '/sales/orders', '/sales/customers', '/sales/commissions']) && sl.title?.startsWith('Sales') && !/logistics/i.test(sl.title ?? ''),
                   `N ${role}: Sales menu (title "${sl.title}") = ${fmt(sl)}`)
            } finally { await page.close() }
        }

        // ── L · /compliance/cod ──────────────────────────────────────────────
        {
            const { page, status } = await openAs(reader, '/compliance/cod', { waitFor: null })
            try {
                const s = await page.evaluate(() => {
                    const t = document.querySelector('table[data-slot="data-table"]')
                    const rows = t ? [...t.querySelectorAll(':scope > tbody > tr')].filter((tr) => !tr.classList.contains('sm:hidden') && tr.querySelectorAll('td').length > 1) : []
                    const pdf = [...document.querySelectorAll('a[href*="/cod/pdf?cod="]')].map((a) => a.getAttribute('href'))
                    return { table: !!t, rows: rows.length, pdf: [...new Set(pdf)], text: document.body.innerText.slice(0, 3000) }
                })
                rr.list = { status, rows: s.rows, pdf: s.pdf }
                ok(status === 200 && s.table && s.rows === cods.length && s.pdf.length === stored.length,
                   `L ${role} /compliance/cod: opens (HTTP ${status}), ${s.rows} rows (database ${cods.length}), ${s.pdf.length} PDF links (issued or voided: ${stored.length})`)
            } finally { await page.close() }
        }

        // ── D · 每一张证书所在的批次页 ───────────────────────────────────────
        rr.detail = []
        for (const c of cods) {
            const { page, status } = await openAs(reader, `/inbound/${c.batch}/edit`, { waitFor: null })
            try {
                const d = await page.evaluate(() => {
                    const p = document.querySelector('[data-cod-panel]')
                    return p ? { panel: p.getAttribute('data-cod-panel'), text: p.innerText, buttons: p.querySelectorAll('button').length,
                                 issue: !!p.querySelector('[data-cod-control="issue"]'), void: !!p.querySelector('[data-cod-control="void"]'),
                                 internal: !!p.querySelector('[data-cod-link="internal"]'), storedLink: p.querySelector('[data-cod-link="stored"]')?.getAttribute('href') ?? null,
                                 readOnly: !!p.querySelector('[data-cod-read-only]') }
                             : { panel: null }
                })
                const budget = await page.evaluate(() => [...document.querySelectorAll('[data-chain-failed]')].some((e) => /DOCUMENT_CHAIN_WALK_BUDGET/.test(e.textContent ?? '')))
                if (budget) {
                    // AGENTS.md ONE-READER(本刀改过):在库那一侧此刻正常时【记下】,不正常时【中止】
                    const why = abortReason(`${role} budget refusal on /inbound/${c.batch}/edit`)
                    if (why) { console.log(`ABORT|a chain was refused with DOCUMENT_CHAIN_WALK_BUDGET while ${why}`); return finish(1) }
                    const w = `BUDGET_REFUSAL|${role} /inbound/${c.batch}/edit: a chain bar was refused with DOCUMENT_CHAIN_WALK_BUDGET; at that moment select 1 < 50 ms and db/rest healthy — recorded, not an abort (Tim 2026-10-29)`
                    warnings.push(w); console.log(w)
                }
                rr.detail.push({ cod: c.code ?? c.id, status: c.status, http: status, ...d, text: undefined })
                const numberShown = c.code ? (d.text ?? '').includes(c.code) : true
                const writeOk = canIssue
                    ? d.panel === 'issuer' && (c.status !== 'pending' || d.issue) && !d.readOnly
                    : d.panel === 'reader' && d.buttons === 0 && !d.issue && !d.void && !d.internal && d.readOnly
                const storedOk = c.status === 'pending' ? d.storedLink === null : d.storedLink === `/inbound/${c.batch}/cod/pdf?cod=${encodeURIComponent(c.code)}`
                ok(status === 200 && !!d.panel && numberShown && writeOk && storedOk,
                   `D ${role} ${c.code ?? '(pending)'} on /inbound/${c.batch}/edit: panel ${d.panel ?? 'MISSING'}; number ${c.code ? (numberShown ? 'shown' : 'NOT shown') : 'none yet'}; ` +
                   `write controls: issue ${d.issue ? 'shown' : 'none'} · void ${d.void ? 'shown' : 'none'} · buttons ${d.buttons}; internal copy link ${d.internal ? 'shown' : 'none'}; ` +
                   `stored PDF link ${d.storedLink ? 'shown' : 'none'}; read-only line ${d.readOnly ? 'shown' : 'none'} (nothing pressed)`)
            } finally { await page.close() }
        }

        // ── F · 存下的 PDF(GET,只读)───────────────────────────────────────
        rr.pdf = []
        for (const c of stored) {
            const r = await fetch(`${BASE}/inbound/${c.batch}/cod/pdf?cod=${encodeURIComponent(c.code)}`, { headers: { cookie: `${reader.cookieName}=${reader.cookieValue}` }, redirect: 'manual' })
            const buf = Buffer.from(await r.arrayBuffer())
            const sha = createHash('sha256').update(buf).digest('hex')
            const base = BASELINE[c.code]
            rr.pdf.push({ code: c.code, http: r.status, type: r.headers.get('content-type'), bytes: buf.length, sha })
            ok(r.status === 200 && (r.headers.get('content-type') ?? '').startsWith('application/pdf') && sha === c.sha && (!base || (sha === base.sha && buf.length === base.bytes)),
               `F ${role} ${c.code} PDF: HTTP ${r.status} ${r.headers.get('content-type')}, ${buf.length} bytes, sha256 ${sha.slice(0, 12)}… = cod_issues ${sha === c.sha}${base ? ` = AGENTS.md baseline ${sha === base.sha && buf.length === base.bytes}` : ''}`)
        }

        // ── S · /documents/cod(搜索的落点)──────────────────────────────────
        {
            const { page, status } = await openAs(reader, '/documents/cod', { waitFor: null })
            try {
                const t = await page.evaluate(() => ({ table: !!document.querySelector('table'), text: document.body.innerText.slice(0, 2000) }))
                ok(status === 200 && t.table && !/Restricted|not available to you/i.test(t.text.split('\n').slice(0, 12).join(' ')),
                   `S ${role} /documents/cod: opens (HTTP ${status}), table ${t.table ? 'drawn' : 'MISSING'}`)
            } finally { await page.close() }
        }

        // ── G · 390 抽屉 ────────────────────────────────────────────────────
        {
            const { page } = await openAs(reader, '/', { width: 390, height: 844, waitFor: '[data-nav="menu-button"]' })
            try {
                await page.click('[data-nav="menu-button"]')
                await page.waitForSelector('[data-nav="sheet"]', { timeout: 10_000 })
                const d = await page.evaluate(() => {
                    const sheet = document.querySelector('[data-nav="sheet"]')
                    const panel = sheet.querySelector('.menu-scroll')
                    const mods = [...panel.children].filter((c) => c.matches('div.border-b, div[data-module-restricted]'))
                    return { docW: document.documentElement.scrollWidth, vw: innerWidth, modules: mods.map((m) => m.innerText.split('\n')[0].trim()),
                             sections: [...panel.querySelectorAll(':scope > div.mt-2 > p')].map((p) => p.innerText.trim()), panelOverflowX: panel.scrollWidth > panel.clientWidth }
                })
                rr.drawer390 = d
                ok(d.docW <= d.vw && !d.panelOverflowX && d.modules.length === 10 && d.sections.length === 2,
                   `G ${role} 390px drawer: ${d.modules.length} module rows (${d.modules.join(' · ')}) + sections ${d.sections.join(' / ')}; page ${d.docW}px wide at ${d.vw}px, panel no sideways overflow`)
            } finally { await page.close() }
        }

        if (role === 'admin') await geometry(reader, report.geometry)
        try { await reader.ctx?.close() } catch { /* 不改判决 */ }
    }
    { const why = abortReason('after all readers'); if (why) { console.log(`ABORT|${why}`); return finish(1) } }

    if (OUT_JSON) writeFileSync(OUT_JSON, JSON.stringify(report, null, 2))
    console.log(`STEP|${bad === 0 ? 'all PASS' : `${bad} FAIL`} · ${warnings.length} warning(s) recorded`)
    return finish(bad === 0 ? 0 : 1)
}

main().catch(async (e) => {
    console.error(`CODR_DRIVER|${e?.stack ?? e}`)
    await finish(2)
})
