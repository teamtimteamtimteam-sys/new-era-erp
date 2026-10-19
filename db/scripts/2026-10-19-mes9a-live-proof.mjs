#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// MES-9a(2026-10-19)· 线上验证 —— 供应商门户的身份与隔离,经 HTTP、对着线上、以一次性账号(前缀 mes9aprobe)
// ════════════════════════════════════════════════════════════════════════════
// PROOF_BASE 上是一台【跑本刀代码、连线上】的 next(中间件、根布局、页面与服务端动作都是应用代码,只有 HTTP 看得见它们);
// 浏览器是 chrome-headless-shell(PUPPETEER_CORE 指向一份 puppeteer-core 的 ESM 入口)。七个真账号一个都不用:
//   cco   = 线上 cco 角色的同码克隆 —— 在供应商页上【经页面】开、撤销门户账号(服务端动作 → service role 建 auth 账号 → 库里写链接)
//   staff = 同一个克隆,用来证明员工会话打不开 /portal
//   c_<角色> = 七个线上角色各一个同码克隆 —— 只读:每一个打开供应商页与 /settings/accounts,记下看不看得见门户账号那一块、按不按得动「开」
// 布景:两家一次性供应商 A、B(ZZ-PROBE),各一位一次性联系人(邮箱就是登录名,mes9aprobe-…@test.local)。
// 证明(每一条都打印一行 PASS / FAIL):
//   ① cco 克隆经页面给 A、B 的联系人各开一个门户账号;
//   ② 两个门户用户各自经 /login 登录 → 被扣在 /set-password(初始密码必须换)→ 换掉 → 落在 /portal,页面上是自己那一家;
//   ③ 门户会话打开员工路由(/ · /suppliers · /settings/accounts · /me · /finance/journal · /inventory · /suppliers/<A>/edit)→ 一律那一句拒绝、出路指回 /portal;
//   ④ 经 PostgREST:portal_me / portal_export_my_data 只回自己那一家(对方的编号、名字、邮箱一个字都没有);一个没有角色的会话读得到的
//      每一个关系(db/norole-surface-baseline.tsv 的 rows 行)与九个权限 / 价格 / 科目对象,门户会话一个都读不到;员工的函数调不到;
//      19 个桶一个都列不出来;
//   ⑤ /portal/my-data 下载到的是自己的;
//   ⑥ cco 克隆经页面撤销 A → A 手里那个还没过期的令牌下一次调 portal_me 被拒;A 重新登录被拒;B 照常;
//   ⑦ 员工会话打开 /portal → 那一句拒绝,出路指回首页;
//   ⑧ 七个角色的克隆:供应商页上门户账号那一块看不看得见、「开」按不按得动;/settings/accounts 那一句"门户账号不在这里"与 V38 · V40 那一块。
// 收尾:计划里的每一步(链接 → 联系人 → 供应商 → 账号 / 角色 / 授权)删掉;残留由 docs/surveys/MES-9a/live-readings.sql 另外读回(以 postgres)。
// 判决只从日志里最后那一行 `MES9A_PROOF_EXIT=` 读:0 = 每一格 PASS 且收尾读回干净 · 1 = 有 FAIL · 2 = 驱动坏了 · 5 = live-lock 被占 · 6 = 收尾没完成。
// 用法:PROOF_BASE=http://localhost:3196 PUPPETEER_CORE=<…/puppeteer-core.js> node db/scripts/2026-10-19-mes9a-live-proof.mjs > <log> 2>&1
// ════════════════════════════════════════════════════════════════════════════
import { onlyWhenRunDirectly } from '../../scripts/lib/entrypoint.mjs'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { acquireOrExit, release, heldBy } from '../../scripts/liveLock.mjs'
import { openPlan, planDelete, mintThrowaway, mintThrowawaySupplier, mintThrowawayContact, reapStalePlans, installExitHooks,
         exitAfterCleanup, ORDER } from '../../scripts/ephemeral.mjs'

onlyWhenRunDirectly(import.meta.url)

const ROOT = dirname(dirname(dirname(fileURLToPath(import.meta.url))))
const BASE = process.env.PROOF_BASE || 'http://localhost:3196'
const CHROME = join(process.env.HOME, '.cache/puppeteer/chrome-headless-shell/mac_arm-152.0.7977.54/chrome-headless-shell-mac-arm64/chrome-headless-shell')
const ROLE_CLONES = ['admin', 'cco', 'cfo', 'cto', 'finance', 'gm', 'warehouse']
const NOROLE_OBJECTS = ['user_roles', 'roles', 'role_permissions', 'permissions', 'metal_prices', 'metal_price_indices', 'pricing_settings',
                        'accounts', 'collection_promise_status', 'suppliers', 'counterparty_contacts', 'supplier_portal_users',
                        'supplier_portal_accounts', 'account_settings', 'purchase_orders', 'inbound_batches', 'cod_issues', 'po_issues']
const STAFF_ROUTES = ['/', '/suppliers', '/settings/accounts', '/me', '/finance/journal', '/inventory']

let locked = false, browser = null, bad = 0
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const ok = (cond, what) => { console.log(`${cond ? 'PASS' : 'FAIL'}|${what}`); if (!cond) bad++; return cond }
installExitHooks({
    beforeFinish: async () => { try { if (browser) await browser.close() } catch { /* 浏览器已经没了 */ } },
    onFinish: (code) => {
        try { if (locked) release() } catch { /* 放锁失败不改判决 */ }
        console.log('AFTER|residue is read separately, as postgres, by docs/surveys/MES-9a/live-readings.sql (after the plan ran)')
        console.log(`MES9A_PROOF_EXIT=${code}`)
    },
})

function env() {
    const txt = readFileSync(join(ROOT, '.env.local'), 'utf8')
    const get = (k) => (txt.match(new RegExp('^' + k + '=(.*)$', 'm'))?.[1] ?? '').trim().replace(/^"|"$/g, '')
    return { URL_: get('NEXT_PUBLIC_SUPABASE_URL'), ANON: get('NEXT_PUBLIC_SUPABASE_ANON_KEY'), SERVICE: get('SUPABASE_SERVICE_ROLE_KEY') }
}
let E
const svc = async (path, init = {}) => {
    const r = await fetch(E.URL_ + path, { ...init, headers: { apikey: E.SERVICE, Authorization: `Bearer ${E.SERVICE}`, 'Content-Type': 'application/json', ...(init.headers || {}) } })
    const t = await r.text(); let b = null; try { b = JSON.parse(t) } catch { b = t }
    return { status: r.status, body: b }
}
const asUser = async (token, path, init = {}) => {
    const r = await fetch(E.URL_ + path, { ...init, headers: { apikey: E.ANON, Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', ...(init.headers || {}) } })
    const t = await r.text(); let b = null; try { b = JSON.parse(t) } catch { b = t }
    return { status: r.status, body: b }
}
const roleOf = (jwt) => { try { return JSON.parse(Buffer.from(jwt.split('.')[1], 'base64url').toString()).role } catch { return null } }
const authCookieName = () => 'sb-' + E.URL_.split('//')[1].split('.')[0] + '-auth-token'

async function sessionFromPage(page) {
    const name = authCookieName()
    const jar = (await page.cookies(BASE)).filter((c) => c.name === name || c.name.startsWith(name + '.'))
    const parts = jar.some((c) => c.name === name) ? jar.filter((c) => c.name === name)
        : jar.sort((a, b) => Number(a.name.split('.').pop()) - Number(b.name.split('.').pop()))
    const raw = parts.map((c) => c.value).join('')
    if (!raw) return null
    return JSON.parse(Buffer.from(raw.replace(/^base64-/, ''), 'base64url').toString('utf8'))
}
async function getWith(cookie, path) {
    const r = await fetch(BASE + path, { headers: { cookie: `${cookie}; NEXT_LOCALE=en` }, redirect: 'manual' })
    return { status: r.status, loc: r.headers.get('location') || '', body: r.status === 200 ? await r.text() : '', type: r.headers.get('content-type') || '' }
}
const cookieOf = (session) => `${authCookieName()}=base64-${Buffer.from(JSON.stringify(session)).toString('base64url')}`

async function staffPage(acct) {
    const ctx = await browser.createBrowserContext()
    const page = await ctx.newPage()
    await page.setCookie({ name: acct.cookieName, value: acct.cookieValue, url: BASE }, { name: 'NEXT_LOCALE', value: 'en', url: BASE })
    return { ctx, page }
}
async function waitFor(page, sel, ms = 60000) {
    await page.waitForSelector(sel, { timeout: ms })
}
async function hydrated(page) {
    await page.waitForFunction(() => { const b = document.querySelector('button'); return !!b && Object.keys(b).some((k) => k.startsWith('__react')) }, { timeout: 60000 })
}

async function createViaPage(cco, supplierId, contactId, password) {
    const { ctx, page } = await staffPage(cco)
    try {
        await page.goto(`${BASE}/suppliers/${supplierId}/edit`, { waitUntil: 'networkidle0' })
        await waitFor(page, '[data-form="portal-create"] select')
        await hydrated(page)
        await page.select('[data-form="portal-create"] select', contactId)
        await page.type('[data-form="portal-create"] input[type="password"]', password)
        await page.$$eval('[data-form="portal-create"] button', (bs) => bs.find((b) => !b.disabled)?.click())
        await page.waitForSelector('[data-saved="portal-create"], [data-error="portal-create"]', { timeout: 60000 })
        const saved = await page.$('[data-saved="portal-create"]')
        const text = await page.$eval('[data-saved="portal-create"], [data-error="portal-create"]', (e) => e.textContent)
        return { saved: !!saved, text }
    } finally { await ctx.close() }
}

async function revokeViaPage(cco, supplierId, linkId, reason) {
    const { ctx, page } = await staffPage(cco)
    try {
        await page.goto(`${BASE}/suppliers/${supplierId}/edit`, { waitUntil: 'networkidle0' })
        const row = `[data-portal-account="${linkId}"]`
        await waitFor(page, `${row} [data-action="portal-revoke"]`)
        await hydrated(page)
        await page.click(`${row} [data-action="portal-revoke"]`)
        await waitFor(page, `${row} [data-field="revoke_reason"]`)
        await page.type(`${row} [data-field="revoke_reason"]`, reason)
        await page.$$eval(`${row} button`, (bs) => bs.find((b) => /Revoke now|立即撤销/.test(b.textContent || ''))?.click())
        await page.waitForSelector(`${row}[data-state="revoked"], ${row} [data-error="portal-row"]`, { timeout: 60000 })
        const state = await page.$eval(row, (e) => e.getAttribute('data-state'))
        return state
    } finally { await ctx.close() }
}

async function portalFirstSignIn(email, initial, next) {
    const ctx = await browser.createBrowserContext()
    const page = await ctx.newPage()
    try {
        await page.setCookie({ name: 'NEXT_LOCALE', value: 'en', url: BASE })
        const seen = []
        page.on('framenavigated', (f) => { if (f === page.mainFrame()) seen.push(new URL(f.url()).pathname) })
        await page.goto(`${BASE}/login`, { waitUntil: 'networkidle0' })
        await page.type('input[name="email"]', email)
        await page.type('input[name="password"]', initial)
        await Promise.all([page.waitForNavigation({ waitUntil: 'networkidle0' }).catch(() => null), page.click('form button[type="submit"]')])
        // 判据是【那张换密码的表单在屏幕上】(只有 /set-password 有 confirm 那一格),地址栏另记一笔 —— 两件事分开报
        await page.waitForSelector('input[name="confirm"]', { timeout: 30000 }).catch(() => null)
        const forcedForm = await page.$('input[name="confirm"]') !== null
        const urlAtForm = new URL(page.url()).pathname
        // 地址栏停在登录动作 redirect() 的落点(/portal)而屏幕上是换密码表单 —— 员工走同一条机制时一模一样
        // (db/scripts/2026-10-19-mes9a-first-signin-address.mjs:gm 克隆 → 地址 / ,表单在;刷新 → /set-password)。
        // 所以这里断言的是【被扣住】:表单在屏幕上,刷新之后中间件把它送到 /set-password,而不是放进 /portal。
        if (forcedForm) await page.reload({ waitUntil: 'networkidle0' })
        const afterReload = new URL(page.url()).pathname
        const formAfterReload = await page.$('input[name="confirm"]') !== null
        const forced = { forcedForm, urlAtForm, afterReload, formAfterReload, seen: [...seen] }
        if (!forcedForm) return { forced, landed: urlAtForm, home: false, code: null, session: await sessionFromPage(page) }
        await hydrated(page)
        await page.type('input[name="password"]', next)
        await page.type('input[name="confirm"]', next)
        await Promise.all([page.waitForNavigation({ waitUntil: 'networkidle0' }).catch(() => null), page.click('form button[type="submit"]')])
        for (let i = 0; i < 60 && !new URL(page.url()).pathname.startsWith('/portal'); i++) await sleep(500)
        const landed = new URL(page.url()).pathname
        const home = await page.$('[data-portal-home]') !== null
        const code = home ? await page.$eval('[data-portal-supplier]', (e) => e.getAttribute('data-portal-supplier')) : null
        const session = await sessionFromPage(page)
        return { forced, landed, home, code, session }
    } finally { await ctx.close() }
}

async function overflowAs(session, path, width) {
    const ctx = await browser.createBrowserContext()
    const page = await ctx.newPage()
    try {
        await page.setViewport({ width, height: 900 })
        const v = cookieOf(session).split('=').slice(1).join('=')
        await page.setCookie({ name: authCookieName(), value: v, url: BASE }, { name: 'NEXT_LOCALE', value: 'en', url: BASE })
        await page.goto(BASE + path, { waitUntil: 'networkidle0' })
        return await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth)
    } finally { await ctx.close() }
}

async function approvalsWidths(acct, width) {
    const ctx = await browser.createBrowserContext()
    const page = await ctx.newPage()
    try {
        await page.setViewport({ width, height: 900 })
        await page.setCookie({ name: acct.cookieName, value: acct.cookieValue, url: BASE }, { name: 'NEXT_LOCALE', value: 'en', url: BASE })
        await page.goto(BASE + '/settings/approvals', { waitUntil: 'networkidle0' })
        await page.waitForSelector('#apr-l1', { timeout: 60000 })
        return await page.evaluate(() => {
            const read = () => ({ l1: Math.round(document.getElementById('apr-l1').getBoundingClientRect().width),
                                  l2: Math.round(document.getElementById('apr-l2').getBoundingClientRect().width),
                                  overflow: document.documentElement.scrollWidth - window.innerWidth })
            const after = read()
            for (const id of ['apr-l1', 'apr-l2']) document.getElementById(id).classList.remove('max-w-full')
            const before = read()
            for (const id of ['apr-l1', 'apr-l2']) document.getElementById(id).classList.add('max-w-full')
            const back = read()
            return { before, after, back }
        })
    } finally { await ctx.close() }
}

async function anonymiseViaPage(cco, supplierId, linkId) {
    const { ctx, page } = await staffPage(cco)
    try {
        await page.goto(`${BASE}/suppliers/${supplierId}/edit`, { waitUntil: 'networkidle0' })
        const row = `[data-portal-account="${linkId}"]`
        await waitFor(page, `${row} [data-action="portal-anonymise"]`)
        await hydrated(page)
        await page.click(`${row} [data-action="portal-anonymise"]`)
        await page.waitForSelector(`${row}[data-state="anonymised"], ${row} [data-error="portal-row"]`, { timeout: 60000 })
        return await page.$eval(row, (e) => e.getAttribute('data-state'))
    } finally { await ctx.close() }
}

async function main() {
    const other = heldBy()
    if (other) { console.error(`✗ live-lock 被【${other.holder}】(pid ${other.pid})占着`); return exitAfterCleanup(5) }
    acquireOrExit('db/scripts/2026-10-19-mes9a-live-proof.mjs', { ownExit: false })
    locked = true
    openPlan('db/scripts/2026-10-19-mes9a-live-proof.mjs')
    await reapStalePlans()
    E = env()
    try { const r = await fetch(BASE + '/login', { redirect: 'manual' }); if (r.status !== 200) throw new Error(`HTTP ${r.status}`) }
    catch (e) { throw new Error(`MES9A_DRIVER|no next server at ${BASE}: ${e.message}`) }
    const pc = process.env.PUPPETEER_CORE
    if (!pc) throw new Error('MES9A_DRIVER|PUPPETEER_CORE is not set')
    const puppeteer = (await import(pc)).default
    browser = await puppeteer.launch({ executablePath: CHROME, headless: true, args: ['--no-sandbox'] })

    const stamp = Date.now()
    const cco = await mintThrowaway({ prefix: 'mes9aprobe', label: 'lp-cco', stamp, codes: { cloneOf: 'cco' } })
    console.log(`· cco clone ${cco.email} (${cco.codes.length} codes)`)
    const A = await mintThrowawaySupplier({ prefix: 'mes9aprobe', label: 'lp-a' })
    const B = await mintThrowawaySupplier({ prefix: 'mes9aprobe', label: 'lp-b' })
    const emailA = `mes9aprobe-${stamp}-pa@test.local`, emailB = `mes9aprobe-${stamp}-pb@test.local`
    const cA = await mintThrowawayContact({ supplierId: A.supplierId, name: 'ZZ-PROBE Ada', email: emailA })
    const cB = await mintThrowawayContact({ supplierId: B.supplierId, name: 'ZZ-PROBE Bea', email: emailB })
    console.log(`· suppliers A ${A.code} · B ${B.code}`)

    // ① create both through the supplier page as the cco clone
    const users = {}
    for (const [key, S, C, email] of [['A', A, cA, emailA], ['B', B, cB, emailB]]) {
        const initial = `init-${stamp}-${key}-Aa1!`
        const res = await createViaPage(cco, S.supplierId, C.contactId, initial)
        const look = await svc(`/rest/v1/supplier_portal_users?supplier_id=eq.${S.supplierId}&select=id,user_id,contact_id`)
        const link = Array.isArray(look.body) ? look.body[0] : null
        if (link) {
            planDelete(`/rest/v1/supplier_portal_users?id=eq.${link.id}`, `删门户链接 ${email}`, ORDER.PORTAL_LINK)
            planDelete(`/auth/v1/admin/users/${link.user_id}`, `删门户账号 ${email}`, ORDER.ACCOUNT)
        }
        ok(res.saved && link && link.contact_id === C.contactId, `① ${key}: created through the supplier page as the cco clone — "${(res.text || '').slice(0, 90)}" · link ${link?.id ?? 'none'}`)
        users[key] = { S, C, email, initial, link }
    }
    if (!users.A.link || !users.B.link) throw new Error('MES9A_LIVE|a portal account was not created; nothing further can be proved')

    // ② first sign-in: forced password change, then /portal
    for (const key of ['A', 'B']) {
        const u = users[key]
        u.password = `next-${stamp}-${key}-Bb2!`
        const r = await portalFirstSignIn(u.email, u.initial, u.password)
        u.session = r.session
        ok(r.forced.forcedForm && r.forced.formAfterReload && r.forced.afterReload === '/set-password',
           `② ${key}: first sign-in is held on the change-password form (initial password must be changed) — address ${r.forced.urlAtForm} (as for staff) · after a reload ${r.forced.afterReload} · navigations ${r.forced.seen.join(' → ')}`)
        ok(r.landed === '/portal' && r.home && r.code === u.S.code, `② ${key}: after the change it lands on ${r.landed} showing supplier ${r.code}`)
        ok(roleOf(r.session?.access_token) === 'supplier_portal', `② ${key}: its token's role is ${roleOf(r.session?.access_token)}`)
    }

    // layout of /portal as a portal user (the layout survey's own session is a staff one): page overflow at 390 and 1280 px
    for (const w of [390, 1280]) {
        const o = await overflowAs(users.A.session, '/portal', w)
        ok(o <= 1, `layout: /portal as a portal user at ${w} px — page overflow ${o} px`)
    }

    // ③ staff routes refused (hard navigation), /portal opens with its own supplier only
    for (const key of ['A', 'B']) {
        const u = users[key], other = key === 'A' ? users.B : users.A
        const ck = cookieOf(u.session)
        for (const path of [...STAFF_ROUTES, `/suppliers/${u.S.supplierId}/edit`]) {
            const g = await getWith(ck, path)
            ok(g.status === 200 && g.body.includes('data-access-denied') && g.body.includes('href="/portal"') && !g.body.includes('data-nav'),
               `③ ${key}: ${path} → ${g.status}${g.loc ? ' ' + g.loc : ''} · refused with a way back to /portal`)
        }
        const p = await getWith(ck, '/portal')
        ok(p.status === 200 && p.body.includes(`data-portal-supplier="${u.S.code}"`) && !p.body.includes(other.S.code) && !p.body.includes(other.email),
           `③ ${key}: /portal → ${p.status}, its own supplier ${u.S.code}, nothing of the other`)
    }

    // ④ PostgREST as each portal user
    const base = readFileSync(join(ROOT, 'db/norole-surface-baseline.tsv'), 'utf8').split('\n')
        .filter((l) => l.startsWith('rows\t')).map((l) => l.split('\t')[1].replace(/^(norole|display):/, '').replace(/^public\./, ''))
    const rels = [...new Set([...base, ...NOROLE_OBJECTS])]
    for (const key of ['A', 'B']) {
        const u = users[key], other = key === 'A' ? users.B : users.A
        const t = u.session.access_token
        const me = await asUser(t, '/rest/v1/rpc/portal_me', { method: 'POST', body: '{}' })
        const ex = await asUser(t, '/rest/v1/rpc/portal_export_my_data', { method: 'POST', body: '{}' })
        const meTxt = JSON.stringify(me.body), exTxt = JSON.stringify(ex.body)
        ok(me.status === 200 && me.body?.supplier?.code === u.S.code && !meTxt.includes(other.S.code) && !meTxt.includes(other.email),
           `④ ${key}: portal_me → its own supplier only`)
        ok(ex.status === 200 && exTxt.includes(u.email) && !exTxt.includes(other.email) && !exTxt.includes(other.S.code),
           `④ ${key}: portal_export_my_data → its own data only`)
        let readable = []
        for (const r of rels) {
            const q = await asUser(t, `/rest/v1/${encodeURIComponent(r)}?select=*&limit=1`)
            if (q.status === 200 && Array.isArray(q.body) && q.body.length > 0) readable.push(r)
            if (q.status === 200 && Array.isArray(q.body) && q.body.length === 0) readable.push(r + '(0 rows, but not refused)')
        }
        ok(readable.length === 0, `④ ${key}: ${rels.length} relations (every no-role-readable relation + the internal ones) — refused all${readable.length ? '; READ: ' + readable.join(', ') : ''}`)
        const fns = ['current_user_permissions', 'session_is_floor_display_only', 'approvals_enabled', 'portal_actor_labels']
        const callable = []
        for (const f of fns) {
            const q = await asUser(t, `/rest/v1/rpc/${f}`, { method: 'POST', body: f === 'portal_actor_labels' ? '{"p_user_ids":[]}' : '{}' })
            if (q.status === 200) callable.push(f)
        }
        ok(callable.length === 0, `④ ${key}: staff functions (${fns.join(', ')}) — refused all${callable.length ? '; CALLED: ' + callable.join(', ') : ''}`)
        const buckets = (await svc('/storage/v1/bucket')).body
        let listed = []
        for (const b of (Array.isArray(buckets) ? buckets : [])) {
            const l = await fetch(`${E.URL_}/storage/v1/object/list/${b.id}`, { method: 'POST',
                headers: { apikey: E.ANON, Authorization: `Bearer ${t}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ prefix: '', limit: 5 }) })
            const j = await l.json().catch(() => null)
            if (l.ok && Array.isArray(j) && j.length > 0) listed.push(b.id)
        }
        ok(Array.isArray(buckets) && buckets.length === 19 && listed.length === 0, `④ ${key}: storage — ${Array.isArray(buckets) ? buckets.length : '?'} buckets, lists nothing${listed.length ? '; LISTED: ' + listed.join(', ') : ''}`)
        // ⑤ the export route
        const dl = await getWith(cookieOf(u.session), '/portal/my-data')
        ok(dl.status === 200 && dl.type.includes('application/json') && dl.body.includes(u.email) && !dl.body.includes(other.email),
           `⑤ ${key}: /portal/my-data → ${dl.status} ${dl.type.split(';')[0]}, its own data only`)
    }

    // ⑥ revoke A through the supplier page; A's next call refused; B still works
    const stateA = await revokeViaPage(cco, users.A.S.supplierId, users.A.link.id, 'MES-9a live proof: revoke')
    ok(stateA === 'revoked', `⑥ A revoked through the supplier page (row state ${stateA})`)
    const nextA = await asUser(users.A.session.access_token, '/rest/v1/rpc/portal_me', { method: 'POST', body: '{}' })
    ok(nextA.status !== 200 && /PORTAL_ACCESS_REVOKED|PORTAL_SESSION_ENDED/.test(JSON.stringify(nextA.body)),
       `⑥ A's next call with its still-unexpired token → HTTP ${nextA.status} ${JSON.stringify(nextA.body).slice(0, 80)}`)
    const reA = await fetch(`${E.URL_}/auth/v1/token?grant_type=password`, { method: 'POST', headers: { apikey: E.ANON, 'Content-Type': 'application/json' },
        body: JSON.stringify({ email: users.A.email, password: users.A.password }) })
    const reAj = await reA.json().catch(() => null)
    ok(!reA.ok, `⑥ A cannot sign in again → HTTP ${reA.status} ${reAj?.error_code ?? reAj?.msg ?? ''}`)
    const pageA = await getWith(cookieOf(users.A.session), '/portal')
    ok(pageA.status !== 200 || !pageA.body.includes('data-portal-home'), `⑥ A's browser session on /portal → ${pageA.status} ${pageA.loc}`)
    const nextB = await asUser(users.B.session.access_token, '/rest/v1/rpc/portal_me', { method: 'POST', body: '{}' })
    ok(nextB.status === 200 && nextB.body?.supplier?.code === users.B.S.code, `⑥ B still works (portal_me → ${nextB.status})`)

    // ⑥b anonymise A's contact on request (after the revoke) through the page: contact blanked, sign-in email replaced, account kept
    const stA = await anonymiseViaPage(cco, users.A.S.supplierId, users.A.link.id)
    const ct = await svc(`/rest/v1/counterparty_contacts?id=eq.${users.A.C.contactId}&select=name,email,phone,deleted_at,anonymised_at`)
    const au = await svc(`/auth/v1/admin/users/${users.A.link.user_id}`)
    ok(stA === 'anonymised' && ct.body?.[0]?.name === 'Anonymised' && ct.body?.[0]?.email === null && ct.body?.[0]?.anonymised_at
       && String(au.body?.email ?? '').startsWith('anonymised-') && au.body?.id === users.A.link.user_id,
       `⑥b A's contact anonymised through the page (row ${stA}; contact ${ct.body?.[0]?.name}/${ct.body?.[0]?.email}; sign-in email ${au.body?.email}; account kept)`)

    // ⑦ a staff session on /portal
    const st = await getWith(cco.cookie, '/portal')
    ok(st.status === 200 && st.body.includes('data-access-denied') && !st.body.includes('data-portal-home'), `⑦ a staff copy (cco clone) on /portal → refused`)

    // ⑧ the seven roles' permissions: who sees the section, who can create
    console.log('ROLES|role|codes|supplier page|portal section|can create (action.manage_portal_users)|/settings/accounts|V38/V40 panel · portal note')
    for (const r of ROLE_CLONES) {
        const c = await mintThrowaway({ prefix: 'mes9aprobe', label: `rt-${r}`, stamp, codes: { cloneOf: r } })
        const sp = await getWith(c.cookie, `/suppliers/${users.B.S.supplierId}/edit`)
        const section = sp.body.includes('data-section="supplier-portal-accounts"')
        const denied = sp.body.includes('data-access-denied')
        const gated = sp.body.includes('data-permission-required="action.manage_portal_users"')
        const canCreate = section && sp.body.includes('data-form="portal-create"') && !gated
        const ac = await getWith(c.cookie, '/settings/accounts')
        const acOpen = ac.status === 200 && !ac.body.includes('data-access-denied')
        if (r === 'admin') {
            for (const w of [1280, 390]) {
                const m = await approvalsWidths(c, w)
                console.log(`APPROVALS|${w} px|without max-w-full: selects ${m.before.l1}/${m.before.l2} px, page overflow ${m.before.overflow} px|with it: ${m.after.l1}/${m.after.l2} px, overflow ${m.after.overflow} px|put back: ${m.back.l1}/${m.back.l2} px, overflow ${m.back.overflow} px`)
                if (w === 1280) ok(m.before.l1 === m.after.l1 && m.before.l2 === m.after.l2 && m.after.overflow <= 1, `fold-in: /settings/approvals at 1280 px — select widths unchanged by the fix (${m.after.l1}/${m.after.l2} px)`)
                else ok(m.after.overflow <= 1 && m.before.overflow > 1 && m.back.overflow === m.after.overflow, `fold-in: /settings/approvals at 390 px — page overflow ${m.before.overflow} → ${m.after.overflow} px`)
            }
        }
        console.log(`ROLES|${r}|${c.codes.length}|${sp.status}${denied ? ' refused' : ''}|${section ? 'sees' : 'no'}|${canCreate ? 'yes' : section ? 'no (shown, unpressable, names the code)' : '—'}|${acOpen ? 'opens' : 'refused'}|${acOpen ? (ac.body.includes('data-section="account-settings"') && ac.body.includes('data-note="portal-accounts-elsewhere"') ? 'both shown' : 'MISSING') : '—'}`)
    }
    console.log(bad ? `STEP|done with ${bad} FAIL` : 'STEP|done')
    return exitAfterCleanup(bad ? 1 : 0)
}

main().catch((e) => {
    console.error(String(e?.stack || e))
    return exitAfterCleanup(String(e?.message || '').startsWith('MES9A_DRIVER') ? 2 : 1)
})
