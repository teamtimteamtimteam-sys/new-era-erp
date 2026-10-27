#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// SYSTEM-MAP-1(Tim 2026-10-26 2.1–2.3 · 2026-10-27 D1–D4 · Q1–Q5)· 线上证明 —— 真浏览器读屏幕,读库的那几句只数行(以 postgres 读基表)
// ════════════════════════════════════════════════════════════════════════════
// 委托书(Step 1 的线上证明):一次性账号,每一个真角色一个(admin · cfo · cco · cto · finance · gm · warehouse —— 共用造号器,
//   codes: { cloneOf: <角色> },前缀 sm1probe),各自:
//   M  画出来的菜单:顶栏九个按钮逐个点开,读每一行(data-menu-href + 受限记号);每一条条目在【恰好一个】模块底下,
//      且与注册表(lib/modules.ts)对这个角色的答案逐条相同(进得去 / 受限);工具下拉只剩日历与单位换算。
//   A  头像菜单(Q5):没有 /me 与 /my-reviews,通知那一行还在。
//   W  工作台的条目(读出来,列在报告里)。
//   P  四张新页:进得去就画表,行数 = 库里的行数(以 postgres 读基表);进不去就是具名拒绝。/claims 的医疗金额:没有 data.view_health 的
//      读者(一次性账号没有员工档案,于是没有"自己的那一笔")看到的每一格都是「Restricted」,有的读者一格都不是;任何一格都不是空、不是 0.00。
//   另外三件,各一次:
//   H  (Q2)从 /claims 点一笔待决 / 驳回的一般报销 → 软导航到 /finance/claims#claim-<id>,那一行在视野里、带 data-hash-target 标亮。
//   D  (D1)/purchasing/orders 上把最后一个筛选清掉 → 地址是 ?view=plain(不回到默认视图);/contracts 的「全部」也指向 ?view=plain。
//   G  (Q1)顶栏的几何:390 · 1024 · 1280 · 1440,英文与中文,首页(没有搜索框)与 /tools/calendar(有)—— 任何宽度都不整页横向滚;每个宽度上用的是模块条还是「菜单」抽屉;
//      模块条与右边那一组不重叠;390 上抽屉里九个模块行 + 工具区 + 设置区,不横向溢出。
// 只读:浏览器只发 GET、点菜单与链接;线上提交的只有一次性账号、它们的角色与授权,由清理计划收走。
// 判决只从最后一行 `SM1_PROOF_EXIT=` 读:0 = 全 PASS 且收尾干净 · 1 = 有 FAIL · 2 = 驱动坏了 · 5 = live-lock 被占 · 6 = 收尾没完成。
// 用法:PROOF_BASE=http://localhost:3197 PUPPETEER_DIR=<装着 puppeteer-core 的目录> [PROOF_JSON=<写菜单读数的文件>] node db/scripts/2026-10-27-system-map-1-live-proof.mjs
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

const BASE = process.env.PROOF_BASE || 'http://localhost:3197'
const PUP_DIR = process.env.PUPPETEER_DIR
const OUT_JSON = process.env.PROOF_JSON || null
const CHROME_ROOT = join(homedir(), '.cache/puppeteer/chrome-headless-shell')
const DSN = process.env.CHECK_MIRRORS_DSN || 'host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 user=postgres.wvywpohbwkiinmipmuku dbname=postgres'
const SCRIPT = 'db/scripts/2026-10-27-system-map-1-live-proof.mjs'
const ROLES = ['admin', 'cfo', 'cco', 'cto', 'finance', 'gm', 'warehouse']
const NEW_PAGES = ['/claims', '/compliance/cod', '/compliance/supplier-certificates', '/operation/spare-parts']

let locked = false, bad = 0, browser = null
const ok = (cond, what) => { console.log(`${cond ? 'PASS' : 'FAIL'}|${what}`); if (!cond) bad++; return cond }

installExitHooks({
    onFinish: (code) => {
        try { if (locked) release() } catch { /* 放锁失败不改判决 */ }
        console.log('AFTER|nothing but the throwaway accounts, their roles and grants was committed (removed by the plan); the only database reads were row counts as postgres (base tables)')
        console.log(`SM1_PROOF_EXIT=${code}`)
    },
})

function psql(sql) {
    const r = spawnSync('psql', [DSN, '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-f', '-'], { input: sql, encoding: 'utf8', timeout: 120_000 })
    if (r.status !== 0) throw new Error(`SM1_DRIVER|psql exit ${r.status}: ${(r.stderr ?? '').split('\n').slice(-4).join(' / ')}`)
    return (r.stdout ?? '').split('\n').filter((l) => l.startsWith('PROOF|')).map((l) => l.slice(6))
}

async function finish(code) {
    try { if (browser) await browser.close() } catch { /* 不改判决 */ }
    browser = null
    return exitAfterCleanup(code)
}

const hydrated = (sel) => `(() => { const e = document.querySelector(${JSON.stringify(sel)}); return !!e && Object.keys(e).some((k) => k.startsWith('__react')) })()`

async function openAs(reader, path, { width = 1440, height = 900, locale = 'en', waitFor = '[data-nav="avatar-menu"] button' } = {}) {
    const page = await browser.newPage()
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

/** 顶栏九个按钮逐个点开,读每一行。 */
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
        await btns[i].click() // 收起
        await page.waitForFunction(() => !document.querySelector('[data-nav="modules"] [role="menu"]'), { timeout: 10_000 }).catch(() => {})
    }
    return out
}

async function main() {
    const other = heldBy()
    if (other) { console.error(`✗ live-lock 被【${other.holder}】(pid ${other.pid})占着`); return exitAfterCleanup(5) }
    acquireOrExit(SCRIPT, { ownExit: false })
    locked = true
    openPlan(SCRIPT)
    await reapStalePlans()

    if (!PUP_DIR || !existsSync(join(PUP_DIR, 'node_modules/puppeteer-core'))) throw new Error('SM1_DRIVER|PUPPETEER_DIR has no node_modules/puppeteer-core')
    const puppeteer = createRequire(join(PUP_DIR, 'package.json'))('puppeteer-core')
    const ver = readdirSync(CHROME_ROOT).sort().pop()
    const exe = join(CHROME_ROOT, ver, 'chrome-headless-shell-mac-arm64', 'chrome-headless-shell')
    if (!existsSync(exe)) throw new Error(`SM1_DRIVER|no chrome-headless-shell at ${exe}`)
    try { const r = await fetch(BASE + '/login', { redirect: 'manual' }); if (r.status !== 200) throw new Error(`HTTP ${r.status}`) }
    catch (e) { throw new Error(`SM1_DRIVER|no app at ${BASE}: ${e.message}`) }
    browser = await puppeteer.launch({ executablePath: exe, headless: true, args: ['--no-sandbox'] })

    // ── 注册表(期望)与库(行数,以 postgres 读基表)─────────────────────────────
    const reg = await import(pathToFileURL(join(process.cwd(), 'lib/modules.ts')).href)
    const db = psql(`
        SELECT 'PROOF|medical=' || (SELECT count(*) FROM medical_claims WHERE deleted_at IS NULL);
        SELECT 'PROOF|general=' || (SELECT count(*) FROM expense_claims);
        SELECT 'PROOF|cod=' || (SELECT count(*) FROM certificates_of_destruction);
        SELECT 'PROOF|certs=' || (SELECT count(*) FROM supplier_compliance sc JOIN suppliers s ON s.id = sc.supplier_id WHERE sc.deleted_at IS NULL AND s.deleted_at IS NULL);
        SELECT 'PROOF|spare=' || (SELECT count(*) FROM inbound_batches b JOIN materials m ON m.id = b.material_id WHERE b.deleted_at IS NULL AND m.kind_code = 'spare_part');
        SELECT 'PROOF|hashclaim=' || coalesce((SELECT id::text || ',' || code FROM expense_claims WHERE status IN ('submitted','rejected','withdrawn') ORDER BY created_at DESC LIMIT 1), '');
        SELECT 'PROOF|postatus=' || coalesce((SELECT status FROM purchase_orders GROUP BY status ORDER BY count(*) DESC LIMIT 1), '');
    `)
    const kv = Object.fromEntries(db.map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1)]))
    console.log(`STEP|database as postgres (base tables): medical claims ${kv.medical} · general claims ${kv.general} · CODs ${kv.cod} · supplier certificates ${kv.certs} · spare-part batches ${kv.spare} · anchor claim ${kv.hashclaim || '(none)'} · most common PO status ${kv.postatus}`)
    const expectRows = { '/claims': Number(kv.medical) + Number(kv.general), '/compliance/cod': Number(kv.cod), '/compliance/supplier-certificates': Number(kv.certs), '/operation/spare-parts': Number(kv.spare) }

    const stamp = Date.now()
    const readers = {}
    for (const role of ROLES) readers[role] = await mintThrowaway({ prefix: 'sm1probe', label: role, stamp, codes: { cloneOf: role } })
    const report = {}

    for (const role of ROLES) {
        const reader = readers[role]
        const perms = reader.codes
        const allowsFn = (fn) => reg.allows(fn.permission, perms)
        report[role] = {}

        // ── M · 顶栏菜单 ─────────────────────────────────────────────────────
        const { page } = await openAs(reader, '/', { waitFor: '[data-nav="modules"] > div > button' })
        try {
            const menus = await readBarMenus(page)
            report[role].bar = menus
            const barIds = reg.BAR_MODULE_IDS
            const labels = menus.map((m) => m.label)
            const wantLabels = barIds.map((id) => ({ workbench: 'Workbench', purchasing: 'Purchasing', production: 'Production', quality: 'Quality', sales: 'Sales', finance: 'Finance', people: 'People', safety: 'Safety', equipment: 'Equipment' })[id])
            ok(JSON.stringify(labels) === JSON.stringify(wantLabels), `M ${role}: bar = ${labels.join(' · ')}`)
            const homes = new Map()
            let mismatch = []
            menus.forEach((m, i) => {
                const id = barIds[i]
                const want = reg.MENU_FUNCTIONS.filter((f) => f.modules[0] === id)
                const got = m.rows
                for (const r of got) homes.set(r.href, [...(homes.get(r.href) ?? []), id])
                if (JSON.stringify(got.map((r) => r.href).sort()) !== JSON.stringify(want.map((f) => f.href).sort())) mismatch.push(`${id}: rows ≠ registry`)
                for (const f of want) {
                    const r = got.find((x) => x.href === f.href)
                    if (r && r.restricted === allowsFn(f)) mismatch.push(`${f.href}: ${r.restricted ? 'restricted' : 'open'} on screen, registry says ${allowsFn(f) ? 'open' : 'restricted'}`)
                }
            })
            const multi = [...homes].filter(([, ids]) => ids.length !== 1)
            const total = [...homes].length
            const restricted = menus.flatMap((m) => m.rows).filter((r) => r.restricted).length
            ok(multi.length === 0 && total > 0, `M ${role}: ${total} entries rendered across 9 modules, each under exactly one module${multi.length ? ' — DUPLICATES ' + multi.map(([h, ids]) => `${h}@${ids}`).join(', ') : ''} (${restricted} drawn restricted)`)
            ok(mismatch.length === 0, `M ${role}: every row matches the registry for this role${mismatch.length ? ' — ' + mismatch.join('; ') : ''}`)
            report[role].restrictedModules = menus.filter((m) => m.restricted).map((m) => m.label)
            report[role].workbench = menus[0].rows

            // 工具下拉
            await page.click('[data-nav="tools-menu"] > button')
            await page.waitForSelector('[data-nav="tools-menu"] [data-menu-href]', { timeout: 10_000 }).catch(() => {})
            const tools = await page.$$eval('[data-nav="tools-menu"] [data-menu-href]', (rs) => rs.map((r) => r.getAttribute('data-menu-href')))
            report[role].tools = tools
            ok(JSON.stringify(tools) === JSON.stringify(['/tools/calendar', '/tools/converter']), `M ${role}: Tools menu = ${tools.join(' · ')}`)
            await page.keyboard.press('Escape')

            // ── A · 头像菜单 ─────────────────────────────────────────────────
            await page.click('[data-nav="avatar-menu"] > button')
            await page.waitForSelector('[data-nav="avatar-menu"] [role="menu"]', { timeout: 10_000 })
            const avatar = await page.$$eval('[data-nav="avatar-menu"] [role="menu"] [data-menu-row]', (rs) => rs.map((r) => r.getAttribute('href') ?? r.getAttribute('data-nav') ?? r.textContent.trim().slice(0, 30)))
            report[role].avatar = avatar
            ok(!avatar.includes('/me') && !avatar.includes('/my-reviews') && avatar.includes('/notifications'),
               `A ${role}: avatar menu rows = ${avatar.join(' · ')} — no /me, no /my-reviews, notifications kept`)
            await page.keyboard.press('Escape')
        } finally { await page.close() }

        // ── P · 四张新页 ────────────────────────────────────────────────────
        for (const path of NEW_PAGES) {
            const fn = reg.FUNCTIONS.find((f) => f.href === path)
            const open = allowsFn(fn)
            const { page: p, status } = await openAs(reader, path, { waitFor: null })
            try {
                const s = await p.evaluate(() => {
                    const t = document.querySelector('table[data-slot="data-table"]')
                    const rows = t ? [...t.querySelectorAll(':scope > tbody > tr')].filter((tr) => !tr.classList.contains('sm:hidden') && tr.querySelectorAll('td').length > 1) : []
                    const head = t ? [...t.querySelectorAll(':scope > thead th')].map((th) => th.innerText.trim()) : []
                    return { table: !!t, rows: rows.length, head, text: document.body.innerText.slice(0, 4000), exportBtn: !!document.querySelector('[data-slot="table-export"]'), sortKeys: [...document.querySelectorAll('table[data-slot="data-table"] thead [data-sort-key]')].length }
                })
                const refused = !s.table && /Restricted|permission|not available to you|need/i.test(s.text)
                if (open) {
                    ok(status === 200 && s.table && s.rows === expectRows[path] && s.exportBtn && s.sortKeys > 0,
                       `P ${role} ${path}: opens, ${s.rows} rows (database ${expectRows[path]}), export bar ${s.exportBtn ? 'present' : 'MISSING'}, ${s.sortKeys} sortable headers`)
                    if (path === '/claims') {
                        const cells = await p.evaluate(() => {
                            const t = document.querySelector('table[data-slot="data-table"]')
                            const ths = [...t.querySelectorAll(':scope > thead th')]
                            const ki = ths.findIndex((th) => /^Kind/.test(th.innerText.trim())), ai = ths.findIndex((th) => /^Amount/.test(th.innerText.trim()))
                            return [...t.querySelectorAll(':scope > tbody > tr')].filter((tr) => tr.querySelectorAll('td').length > 1)
                                .map((tr) => ({ kind: tr.querySelectorAll('td')[ki]?.innerText.trim(), amount: tr.querySelectorAll('td')[ai]?.innerText.trim() }))
                        })
                        const med = cells.filter((c) => c.kind === 'Medical')
                        const restrictedCells = med.filter((c) => c.amount === 'Restricted').length
                        const wellFormed = cells.every((c) => c.amount === 'Restricted' || /^\d[\d,]*\.\d{2} [A-Z]{3}$/.test(c.amount ?? ''))
                        const noZeroForMasked = med.every((c) => c.amount !== '' && c.amount !== '0.00 SGD' || perms.includes('data.view_health'))
                        const health = perms.includes('data.view_health')
                        ok(wellFormed && noZeroForMasked && (health ? restrictedCells === 0 : restrictedCells === med.length),
                           `P ${role} /claims masking: data.view_health ${health ? 'held' : 'not held'} → ${restrictedCells}/${med.length} medical amounts read "Restricted"; every amount cell is "Restricted" or "<n.nn> <CCY>" (none blank)`)
                    }
                } else {
                    ok(!s.table && refused, `P ${role} ${path}: refused by name (no table drawn) — the menu shows it restricted`)
                }
            } finally { await p.close() }
        }

        // ── 390 · 抽屉 ──────────────────────────────────────────────────────
        const { page: ph } = await openAs(reader, '/', { width: 390, height: 844, waitFor: '[data-nav="menu-button"]' })
        try {
            await ph.click('[data-nav="menu-button"]')
            await ph.waitForSelector('[data-nav="sheet"]', { timeout: 10_000 })
            const d = await ph.evaluate(() => {
                const sheet = document.querySelector('[data-nav="sheet"]')
                const panel = sheet.querySelector('.menu-scroll')
                const mods = [...panel.children].filter((c) => c.matches('div.border-b, div[data-module-restricted]'))
                return { docW: document.documentElement.scrollWidth, vw: innerWidth, modules: mods.map((m) => m.innerText.split('\n')[0].trim()), sections: [...panel.querySelectorAll(':scope > div.mt-2 > p')].map((p) => p.innerText.trim()), panelOverflowX: panel.scrollWidth > panel.clientWidth }
            })
            report[role].drawer390 = d
            ok(d.docW <= d.vw && !d.panelOverflowX && d.modules.length === 9 && d.sections.length === 2,
               `G ${role} 390px drawer: ${d.modules.length} module rows (${d.modules.join(' · ')}) + sections ${d.sections.join(' / ')}; page ${d.docW}px wide at ${d.vw}px, panel no sideways overflow`)
        } finally { await ph.close() }
    }

    // ── H · 报销 → /finance/claims#claim-<id>,那一行在视野里并标亮 ───────────
    if (kv.hashclaim) {
        const [cid, ccode] = kv.hashclaim.split(',')
        const { page } = await openAs(readers.cfo, '/claims', { waitFor: `a[href="/finance/claims#claim-${cid}"]` })
        try {
            await page.evaluate(() => { window.__sm1soft = 1 })
            await page.click(`a[href="/finance/claims#claim-${cid}"]`)
            await page.waitForFunction((id) => location.pathname === '/finance/claims' && document.getElementById(`claim-${id}`)?.getAttribute('data-hash-target') === 'true', { timeout: 60_000 }, cid).catch(() => {})
            const h = await page.evaluate((id) => {
                const el = document.getElementById(`claim-${id}`)
                const r = el?.getBoundingClientRect()
                return { url: location.pathname + location.hash, soft: window.__sm1soft === 1, marked: el?.getAttribute('data-hash-target') === 'true', tag: el?.tagName,
                         inView: !!r && r.top >= 0 && r.bottom <= innerHeight, bg: el ? getComputedStyle(el).backgroundColor : null }
            }, cid)
            ok(h.url === `/finance/claims#claim-${cid}` && h.soft && h.marked && h.inView && h.bg !== 'rgba(0, 0, 0, 0)',
               `H cfo clicks ${ccode} on /claims → ${h.url} by soft navigation (${h.soft}); <${h.tag}> in view ${h.inView}, highlighted ${h.marked} (background ${h.bg})`)
        } finally { await page.close() }
    } else console.log('SKIP|H no submitted / rejected / withdrawn general claim on live')

    // ── D · 清掉最后一个筛选 → ?view=plain ──────────────────────────────────
    {
        const st = kv.postatus
        const { page } = await openAs(readers.finance, `/purchasing/orders?status=${encodeURIComponent(st)}`, { waitFor: 'select' })
        try {
            await page.evaluate(() => { window.__sm1soft = 1 })
            const sel = await page.evaluateHandle((v) => [...document.querySelectorAll('select')].find((s) => s.value === v) ?? null, st)
            const found = await sel.evaluate((s) => !!s)
            if (found) {
                await sel.select('')
                await page.waitForFunction(() => location.search !== '' && !location.search.includes('status='), { timeout: 30_000 }).catch(() => {})
            }
            const d = await page.evaluate(() => ({ search: location.search, plainBold: document.querySelector('[data-view-plain="true"]')?.getAttribute('aria-current') === 'true' }))
            ok(found && d.search === '?view=plain' && d.plainBold, `D finance on /purchasing/orders?status=${st}: clearing the status filter → ${d.search} ("Plain list" marked current: ${d.plainBold})`)
        } finally { await page.close() }
        const { page: c } = await openAs(readers.finance, '/contracts?side=buy', { waitFor: null })
        try {
            const all = await c.$eval('[data-filter="contract-side"] a', (a) => a.getAttribute('href')).catch(() => null)
            ok(all === '/contracts?view=plain', `D /contracts?side=buy: the "All" side link is ${all}`)
        } finally { await c.close() }
    }

    // ── G · 顶栏几何:1024 · 1280 · 1440,英文与中文 ──────────────────────────
    report.geometry = []
    for (const role of ['admin', 'warehouse']) {
        for (const locale of ['en', 'zh']) {
            // 首页不画搜索框(SearchShell 在 / 上返回 null),别的页面在 ≥768px 上画一格 200px 的 —— 两种都量,后者才是最挤的那一种
            for (const [where, width] of [390, 1024, 1280, 1440].flatMap((w) => [['/', w], ['/tools/calendar', w]])) {
                const { page } = await openAs(readers[role], where, { width, height: 900, locale, waitFor: '[data-nav="avatar-menu"] button' })
                try {
                    const g = await page.evaluate(() => {
                        const vis = (e) => !!e && getComputedStyle(e).display !== 'none' && e.getBoundingClientRect().width > 0
                        const row = document.querySelector('[data-nav="modules"]')
                        const btn = document.querySelector('[data-nav="menu-button"]')
                        const right = document.querySelector('[data-nav="avatar-menu"]')?.parentElement
                        const rowR = vis(row) ? row.getBoundingClientRect() : null
                        const lastBtn = vis(row) ? [...row.querySelectorAll(':scope > div > button')].at(-1)?.getBoundingClientRect() : null
                        const rightR = right?.getBoundingClientRect()
                        return { docW: document.documentElement.scrollWidth, vw: innerWidth, mode: vis(row) ? 'module row' : vis(btn) ? 'menu drawer' : 'NEITHER',
                                 rowW: rowR ? Math.round(rowR.width * 10) / 10 : null, lastRight: lastBtn ? Math.round(lastBtn.right) : null, rightLeft: rightR ? Math.round(rightR.left) : null,
                                 header: Math.round(document.querySelector('header')?.getBoundingClientRect().height ?? 0) }
                    })
                    report.geometry.push({ role, locale, width, where, ...g })
                    // 反事实(只读,注入一条样式):在走抽屉的宽度上把模块条硬画出来,它放得下吗?—— 这就是「为什么这里用退路」的读数
                    if (g.mode === 'menu drawer' && width >= 640) {
                        const cf = await page.evaluate(() => {
                            const st = document.createElement('style')
                            st.textContent = '[data-nav="modules"]{display:flex!important}[data-nav="menu-button"]{display:none!important}'
                            document.head.appendChild(st)
                            const row = document.querySelector('[data-nav="modules"]')
                            const last = [...row.querySelectorAll(':scope > div > button')].at(-1)?.getBoundingClientRect()
                            const right = document.querySelector('[data-nav="avatar-menu"]')?.parentElement?.getBoundingClientRect()
                            const r = { lastRight: Math.round(last?.right ?? 0), rightLeft: Math.round(right?.left ?? 0), docW: document.documentElement.scrollWidth }
                            st.remove()
                            return r
                        })
                        console.log(`INFO|G counterfactual ${role} ${locale} ${width}px ${where}: forcing the module row → last button ends ${cf.lastRight}px, right group starts ${cf.rightLeft}px, page ${cf.docW}px — ${cf.lastRight > cf.rightLeft || cf.docW > width ? 'does NOT fit (fallback needed)' : 'would fit'}`)
                    }
                    const fits = g.mode !== 'module row' || (g.lastRight !== null && g.rightLeft !== null && g.lastRight <= g.rightLeft)
                    ok(g.docW <= g.vw && g.mode !== 'NEITHER' && fits,
                       `G ${role} ${locale} ${width}px ${where}: ${g.mode}${g.rowW ? ` (row ${g.rowW}px, last button ends ${g.lastRight}px, right group starts ${g.rightLeft}px)` : ''}; page ${g.docW}px wide, header ${g.header}px`)
                } finally { await page.close() }
            }
        }
    }

    if (OUT_JSON) writeFileSync(OUT_JSON, JSON.stringify(report, null, 2))
    console.log(`STEP|${bad === 0 ? 'all PASS' : `${bad} FAIL`}`)
    return finish(bad === 0 ? 0 : 1)
}

main().catch(async (e) => {
    console.error(`SM1_DRIVER|${e?.stack ?? e}`)
    await finish(2)
})
