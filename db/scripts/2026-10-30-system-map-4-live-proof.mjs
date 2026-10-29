#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// SYSTEM-MAP-4(v1.4.83,Tim 2026-10-29 的 19 条 · 2026-10-30 Q1–Q6)· 线上证明 —— 七个角色、一次一位,真浏览器读屏幕
// ════════════════════════════════════════════════════════════════════════════
// 委托书 Step 1:"live proof, one reader at a time, all seven roles: rendered bar and every module menu, every entry under exactly one module,
//   each new button present and leading to its page (or behaving as Tim ruled when the reader lacks permission), the date button opening the
//   calendar; nothing pressed"。一次性账号 = 每个真角色一个克隆(共用造号器,codes: { cloneOf },前缀 sm4probe)。
//   N  顶栏:十个按钮,新名字(Operation · HR · ESG);逐个点开读每一行 —— 每一张菜单与注册表逐条相同(行、进得去 / 受限),
//      每一条条目在【恰好一个】模块底下;离开菜单的十四条一条都不在任何菜单里。
//   B  每一颗新入口钮(Tim Q2):在宿主页上、在它该在的位置(左右顺序);读者进得去 → 是一条链接,点的地址 = 目标页,
//      GET 那个地址 200 且不是拒绝页;进不去 → 禁用 + 「· 受限」+ data-module-restricted。另两条既有链接(地磅 → 确认读数、
//      设备概览 → 可靠性)与定价页上的换算卡一并量。
//   Y  /operation/yield → 307 到 /operation/balance#yield(带着筛选);平衡页上有 #yield 那一段。
//   E  ESG:/safety(概览,四条陈述各按自己的码:进得去画数、进不去画「受限」)· /safety/energy · /safety/recovery 按注册表开或拒。
//   D  日期钮:1440 与 390 都在、写的是新加坡的今天(DD/MM/YYYY)、指向 /tools/calendar;点它 → 日历页 200。
//   G  390 抽屉:十个模块行 + 只有「设置」一个区(工具区删了),不横向溢出;顶栏几何(admin):1024 · 1280 · 1366 · 1440,英文与中文。
// 中止规则(AGENTS.md「线上证明一次一位读者」):库里 select 1 > 50 ms · 五次往返中位数 > 1.5 s · health 不健康 → 停、收尾、报告;
//   单次往返 > 1.5 s 记下不停;DOCUMENT_CHAIN_WALK_BUDGET 拒绝在库那一侧正常时记下不停(Tim 2026-10-29)。
// 只读:浏览器只发 GET、点菜单、点日期钮(一条链接);一个按钮都不按。线上提交的只有一次性账号、它们的角色与授权,由清理计划收走。
// PROOF_ONLY=geometry 只跑 G 的几何那一段(admin 一位)。
// 判决只从最后一行 `SM4_PROOF_EXIT=` 读:0 = 全 PASS 且收尾干净 · 1 = 有 FAIL 或中止 · 2 = 驱动坏了 · 5 = live-lock 被占 · 6 = 收尾没完成。
// 用法:PROOF_BASE=http://localhost:3195 PUPPETEER_DIR=<装着 puppeteer-core 的目录> [PROOF_JSON=<out.json>] [PROOF_ONLY=geometry] node db/scripts/2026-10-30-system-map-4-live-proof.mjs
// ════════════════════════════════════════════════════════════════════════════
import { readdirSync, existsSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { homedir } from 'node:os'
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
/** 给人眼看的截图(只给 admin,只截入口钮所在的宿主页);不给就不截 */
const SHOTS = process.env.PROOF_SHOTS || null
const CHROME_ROOT = join(homedir(), '.cache/puppeteer/chrome-headless-shell')
const DSN = process.env.CHECK_MIRRORS_DSN || 'host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 user=postgres.wvywpohbwkiinmipmuku dbname=postgres'
const SCRIPT = 'db/scripts/2026-10-30-system-map-4-live-proof.mjs'
const ROLES = ONLY === 'geometry' ? ['admin'] : ['admin', 'warehouse', 'cfo', 'cco', 'cto', 'finance', 'gm']
const BAR_EN = { workbench: 'Workbench', purchasing: 'Purchasing', production: 'Operation', quality: 'Quality', sales: 'Sales', logistics: 'Logistics',
    finance: 'Finance', people: 'HR', safety: 'ESG', equipment: 'Equipment' }
// 离开菜单的十四条(Tim 2026-10-29 第 1 · 3 · 4 · 5 · 6 · 8 · 9 · 10 · 12 · 17 · 18 · 19 条)
const LEFT_MENU = ['/notifications', '/purchasing/payment-terms', '/purchasing/discrepancies', '/tools/converter', '/inventory/locations', '/inventory/scan',
    '/stocktakes', '/operation/blending', '/operation/yield', '/operation/capture', '/inventory/reports', '/compliance/cod', '/compliance/supplier-certificates',
    '/operation/equipment/reliability']
// 宿主页 → 它右上角的入口钮,从左到右(Tim 的位置 + 滚问第 6 条的顺序)
const BUTTONS = [
    { host: '/purchasing/orders', targets: ['/purchasing/payment-terms'] },
    { host: '/inbound', targets: ['/compliance/cod', '/purchasing/discrepancies'] },
    { host: '/inventory', targets: ['/inventory/reports', '/inventory/scan', '/stocktakes', '/inventory/locations'] },
    { host: '/output', targets: ['/operation/blending'] },
    { host: '/suppliers', targets: ['/compliance/supplier-certificates'] },
]
// 既有的链接(第 5 · 10 · 19 条):宿主页上有一条 href = 目标的链接
const LINKS = [
    { host: '/tools/pricing', target: '/tools/converter', fn: '/tools/pricing' },
    { host: '/operation/weighbridge', target: '/operation/capture', fn: '/operation/weighbridge' },
    { host: '/operation/equipment', target: '/operation/equipment/reliability', fn: '/operation/equipment' },
]

let locked = false, bad = 0, browser = null
const ok = (cond, what) => { console.log(`${cond ? 'PASS' : 'FAIL'}|${what}`); if (!cond) bad++; return cond }

installExitHooks({
    onFinish: (code) => {
        try { if (locked) release() } catch { /* 放锁失败不改判决 */ }
        console.log('AFTER|nothing but the throwaway accounts, their roles and grants was committed (removed by the plan); the browser only sent GETs, opened menus and followed links')
        console.log(`SM4_PROOF_EXIT=${code}`)
    },
})

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

/** 一次 GET(带读者的会话、不跟跳转)。拒绝页的标记:data-access-denied 或 restricted 的状态块。 */
async function getAs(reader, path) {
    const r = await fetch(BASE + path, { headers: { cookie: `${reader.cookieName}=${reader.cookieValue}; NEXT_LOCALE=en` }, redirect: 'manual' })
    const html = r.status === 200 ? await r.text() : ''
    return { status: r.status, location: r.headers.get('location'), denied: /data-access-denied="1"/.test(html), html }
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

/** 新加坡的今天,DD/MM/YYYY(与 DateButton 的 formatDate(businessToday()) 同一个答案 —— 这里独立算一遍,不 import 它) */
function sgToday() {
    const ymd = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Singapore' }).format(new Date())
    const [y, m, d] = ymd.split('-')
    return `${d}/${m}/${y}`
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
                    const date = document.querySelector('header [data-nav="date-button"]')
                    const rowR = vis(row) ? row.getBoundingClientRect() : null
                    const lastBtn = vis(row) ? [...row.querySelectorAll(':scope > div > button')].at(-1)?.getBoundingClientRect() : null
                    const rightR = right?.getBoundingClientRect()
                    return { docW: document.documentElement.scrollWidth, vw: innerWidth, search: vis(sh), date: vis(date), dateW: vis(date) ? Math.round(date.getBoundingClientRect().width * 10) / 10 : null,
                             mode: vis(row) ? 'module row' : vis(btn) ? 'menu drawer' : 'NEITHER',
                             buttons: vis(row) ? row.querySelectorAll(':scope > div > button').length : null,
                             rowW: rowR ? Math.round(rowR.width * 10) / 10 : null, lastRight: lastBtn ? Math.round(lastBtn.right) : null, rightLeft: rightR ? Math.round(rightR.left) : null }
                })
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
                const narrowest = width - spare
                report.push({ locale, width, ...g, counterfactual: cf, spare, narrowestFit: narrowest })
                console.log(`WIDTH|${locale} ${width}px /tools/calendar (search box ${g.search ? 'drawn' : 'NOT drawn'}, date button ${g.dateW}px): ${g.mode}; the ${cf.buttons}-button row measures ${cf.rowW}px, last button ends ${cf.lastRight}px, right group starts ${cf.rightLeft}px → spare ${spare}px (fits from ${narrowest}px); page ${g.docW}px wide`)
                const fits = g.mode !== 'module row' || (g.lastRight !== null && g.rightLeft !== null && g.lastRight <= g.rightLeft)
                ok(g.docW <= g.vw && g.mode !== 'NEITHER' && fits && g.search && g.date,
                   `G ${reader.label} ${locale} ${width}px /tools/calendar: ${g.mode}${g.rowW ? ` (${g.buttons} buttons, row ${g.rowW}px, last button ends ${g.lastRight}px, right group starts ${g.rightLeft}px)` : ''}; date button ${g.date ? 'drawn' : 'MISSING'}; page ${g.docW}px wide, no sideways scroll`)
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

    if (!PUP_DIR || !existsSync(join(PUP_DIR, 'node_modules/puppeteer-core'))) throw new Error('SM4_DRIVER|PUPPETEER_DIR has no node_modules/puppeteer-core')
    const puppeteer = createRequire(join(PUP_DIR, 'package.json'))('puppeteer-core')
    const ver = readdirSync(CHROME_ROOT).sort().pop()
    const exe = join(CHROME_ROOT, ver, 'chrome-headless-shell-mac-arm64', 'chrome-headless-shell')
    if (!existsSync(exe)) throw new Error(`SM4_DRIVER|no chrome-headless-shell at ${exe}`)
    try { const r = await fetch(BASE + '/login', { redirect: 'manual' }); if (r.status !== 200) throw new Error(`HTTP ${r.status}`) }
    catch (e) { throw new Error(`SM4_DRIVER|no app at ${BASE}: ${e.message}`) }
    browser = await puppeteer.launch({ executablePath: exe, headless: true, args: ['--no-sandbox'] })

    const reg = await import(pathToFileURL(join(process.cwd(), 'lib/modules.ts')).href)
    const fnOf = (href) => reg.FUNCTIONS.find((f) => f.href === href)
    const report = { geometry: [], roles: {}, warnings }
    const today = sgToday()

    const stamp = Date.now()
    for (const role of ROLES) {
        { const why = abortReason(`before ${role}`); if (why) { console.log(`ABORT|${why}`); return finish(1) } }
        const reader = await mintThrowaway({ prefix: 'sm4probe', label: role, stamp, codes: { cloneOf: role } })
        reader.label = role
        const perms = reader.codes
        const rr = (report.roles[role] = {})
        const opens = (href) => reg.allows(fnOf(href).permission, perms)

        if (ONLY === 'geometry') { await geometry(reader, report.geometry); continue }

        // ── N · 顶栏与每一张菜单 ─────────────────────────────────────────────
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
                    if (JSON.stringify(m.rows.map((r) => r.href).sort()) !== JSON.stringify(want.map((f) => f.href).sort())) mismatch.push(`${id}: rows ${m.rows.map((r) => r.href).join(',')} ≠ registry ${want.map((f) => f.href).join(',')}`)
                    for (const f of want) {
                        const r = m.rows.find((x) => x.href === f.href)
                        const open = reg.allows(f.permission, perms)
                        if (r && r.restricted === open) mismatch.push(`${f.href}: ${r.restricted ? 'restricted' : 'open'} on screen, registry says ${open ? 'open' : 'restricted'}`)
                    }
                })
                const multi = [...homes].filter(([, ids]) => ids.length !== 1)
                const leaked = LEFT_MENU.filter((h) => homes.has(h))
                ok(multi.length === 0 && homes.size > 0, `N ${role}: ${homes.size} entries rendered across 10 modules, each under exactly one module${multi.length ? ' — DUPLICATES ' + multi.map(([h, ids]) => `${h}@${ids}`).join(', ') : ''}`)
                ok(mismatch.length === 0, `N ${role}: every row of every menu matches the registry for this role (same rows, open/restricted)${mismatch.length ? ' — ' + mismatch.join('; ') : ''}`)
                ok(leaked.length === 0, `N ${role}: none of the ${LEFT_MENU.length} entries that left the menu is in any menu${leaked.length ? ' — STILL THERE: ' + leaked.join(', ') : ''}`)
                const fmt = (id) => menus[barIds.indexOf(id)].rows.map((r) => `${r.href}${r.restricted ? ' (restricted)' : ''}`).join(' · ')
                const titles = Object.fromEntries(barIds.map((id, i) => [id, menus[i].title]))
                ok(titles.production === 'Operation' && titles.people === 'HR' && titles.safety === 'Environment, social and governance',
                   `N ${role}: hover titles — Operation "${titles.production}" · HR "${titles.people}" · ESG "${titles.safety}"`)
                console.log(`MENU|${role} Operation: ${fmt('production')}`)
                console.log(`MENU|${role} ESG: ${fmt('safety')}`)
                console.log(`MENU|${role} Equipment: ${fmt('equipment')}`)
            } finally { await page.close() }
        }

        // ── B · 入口钮 ───────────────────────────────────────────────────────
        rr.buttons = []
        for (const b of BUTTONS) {
            const hostOpen = opens(b.host)
            const { page, status } = await openAs(reader, b.host, { waitFor: null })
            try {
                if (SHOTS && role === 'admin') await page.screenshot({ path: join(SHOTS, `admin-1440${b.host.replaceAll('/', '_')}.png`) })
                const seen = await page.evaluate(() => [...document.querySelectorAll('main [data-entry-button], [data-entry-button]')]
                    .map((e) => ({ href: e.getAttribute('data-entry-button'), tag: e.tagName, link: e.tagName === 'A' ? e.getAttribute('href') : null,
                                   restricted: e.hasAttribute('data-module-restricted'), text: e.textContent.trim(),
                                   disabled: !!e.querySelector('button[disabled]'), left: Math.round(e.getBoundingClientRect().left), top: Math.round(e.getBoundingClientRect().top) })))
                const order = seen.map((s) => s.href)
                const rowSorted = [...seen].sort((a, z) => (a.top - z.top) || (a.left - z.left)).map((s) => s.href)
                ok(status === 200 && hostOpen && JSON.stringify(order) === JSON.stringify(b.targets) && JSON.stringify(rowSorted) === JSON.stringify(b.targets),
                   `B ${role} ${b.host} (HTTP ${status}): entry buttons left to right = ${rowSorted.join(' · ') || 'NONE'}`)
                for (const target of b.targets) {
                    const s = seen.find((x) => x.href === target)
                    const want = opens(target)
                    if (!s) { ok(false, `B ${role} ${b.host} → ${target}: button MISSING`); continue }
                    if (want) {
                        const g = await getAs(reader, s.link ?? '')
                        rr.buttons.push({ host: b.host, target, link: s.link, http: g.status })
                        ok(s.tag === 'A' && s.link === target && !s.restricted && g.status === 200 && !g.denied,
                           `B ${role} ${b.host} → "${s.text}": a link to ${s.link}; GET it → HTTP ${g.status}${g.denied ? ' DENIED' : ''} (reader may open it)`)
                    } else {
                        rr.buttons.push({ host: b.host, target, restricted: true })
                        ok(s.restricted && s.disabled && /Restricted/.test(s.text),
                           `B ${role} ${b.host} → "${s.text}": reader lacks the target's permission → drawn disabled with the Restricted suffix and marker`)
                    }
                }
            } finally { await page.close() }
        }
        for (const l of LINKS) {
            if (!opens(l.fn)) { console.log(`STEP|${role} ${l.host}: reader cannot open the host page — its link is not measured`); continue }
            const g = await getAs(reader, l.host)
            const has = g.html.includes(`href="${l.target}"`)
            const t = await getAs(reader, l.target)
            ok(g.status === 200 && has && (opens(l.target) ? t.status === 200 && !t.denied : true),
               `B ${role} ${l.host} (HTTP ${g.status}): link to ${l.target} ${has ? 'present' : 'MISSING'}; GET it → HTTP ${t.status}${t.denied ? ' (named refusal)' : ''}`)
        }

        // ── Y · 得率并进平衡页 ───────────────────────────────────────────────
        if (opens('/operation/balance')) {
            const y = await getAs(reader, '/operation/yield?month=2026-08&group=machine')
            const bal = await getAs(reader, '/operation/balance?month=2026-08&group=machine')
            ok(y.status === 307 && y.location?.endsWith('/operation/balance?month=2026-08&group=machine#yield') && bal.status === 200 && bal.html.includes('id="yield"'),
               `Y ${role} /operation/yield?month=2026-08&group=machine → HTTP ${y.status} to ${y.location}; /operation/balance has the #yield section: ${bal.html.includes('id="yield"')}`)
        }

        // ── E · ESG ─────────────────────────────────────────────────────────
        for (const href of ['/safety', '/safety/energy', '/safety/recovery']) {
            const g = await getAs(reader, href)
            const want = opens(href)
            ok(g.status === 200 && g.denied === !want, `E ${role} ${href}: HTTP ${g.status}, ${g.denied ? 'named refusal' : 'opens'} (registry: ${want ? 'opens' : 'refuses'})`)
            if (href === '/safety' && want) {
                const fig = (k) => { const m = g.html.match(new RegExp(`data-esg="${k}"`)); return !!m }
                const restrictedCount = (g.html.match(/data-overview-restricted="1"/g) ?? []).length
                const expectRestricted = ['module.safety.view', 'module.safety.view', 'module.suppliers.view', 'data.view_cod'].filter((c) => !perms.includes(c)).length
                ok(restrictedCount === expectRestricted,
                   `E ${role} /safety: ${restrictedCount} statement(s) drawn Restricted (expected ${expectRestricted} from the reader's codes); safety ${fig('safety')} · certificates ${fig('certificates')} · cod ${fig('cod')}`)
            }
        }

        // ── D · 日期钮 ───────────────────────────────────────────────────────
        for (const width of [1440, 390]) {
            const { page } = await openAs(reader, '/', { width, height: width < 768 ? 844 : 900, waitFor: '[data-nav="date-button"]' })
            try {
                const d = await page.evaluate(() => {
                    const a = document.querySelector('header [data-nav="date-button"]')
                    const r = a?.getBoundingClientRect()
                    return a ? { text: a.textContent.trim(), href: a.getAttribute('href'), visible: !!r && r.width > 0 && getComputedStyle(a).display !== 'none', w: Math.round(r.width) } : null
                })
                let landed = null
                if (SHOTS && role === 'admin') await page.screenshot({ path: join(SHOTS, `admin-${width}-home.png`) })
                if (d?.visible) {
                    await Promise.all([page.waitForNavigation({ waitUntil: 'networkidle2', timeout: 60_000 }).catch(() => {}), page.click('header [data-nav="date-button"]')])
                    landed = { url: new URL(page.url()).pathname, h1: await page.evaluate(() => document.querySelector('h1')?.textContent.trim() ?? null) }
                }
                ok(!!d && d.visible && d.text === today && d.href === '/tools/calendar' && landed?.url === '/tools/calendar',
                   `D ${role} ${width}px: date button ${d?.visible ? `"${d.text}" (${d.w}px)` : 'MISSING'}, Singapore today ${today}; clicked → ${landed?.url ?? '—'} (h1 "${landed?.h1 ?? ''}")`)
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
                ok(d.docW <= d.vw && !d.panelOverflowX && d.modules.length === 10 && d.sections.length === 1 && /settings/i.test(d.sections[0] ?? ''),
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
    console.error(`SM4_DRIVER|${e?.stack ?? e}`)
    await finish(2)
})
