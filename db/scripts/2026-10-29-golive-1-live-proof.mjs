#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// GOLIVE-1(v1.4.82,Tim 2026-10-29)· 线上证明 —— 七个角色 + 一位匿名读者 + 一位门户读者 + 一位只持 action.metal_prices 的读者,一次一位
// ════════════════════════════════════════════════════════════════════════════
// 委托书 Step 1:"live proof, one reader at a time, all seven roles plus one anonymous reader and one portal reader: each row's effect where live
//   data allows (metal prices, contracts masking, container overview, the employee form's 「受限」 for a reader without data.view_identity with
//   nothing saved), the public COD verify page and the supplier portal still working; nothing pressed"。
//   一次性账号 = 每个真角色一个克隆(共用造号器,codes: { cloneOf },前缀 golive1probe);门户读者 = 一家一次性供应商 + 它的门户账号;
//   第 1 行的读者 = 一个只持 action.metal_prices 的一次性角色(线上没有这样的真角色 —— 这一位是"将来只给这个码的人")。
//   每位读者(页面只发 GET,REST 只读;一个按钮都不按,表单一个都不交):
//   H  / 打得开(HTTP 200)
//   C  第 6 行:/logistics/containers 画出的行数 = 以 postgres 读到的未删货柜数;/logistics 的货柜那一格不是「受限」
//   K  第 12 行:/contracts 打得开(持 suppliers.view 的);以这位读者的令牌经 PostgREST 读 sales_settlements.amount_usd / contract_refining_charges
//      的价格列 → 拒(42501),读 *_masked → 200(线上合同 0 份、结算 0 行 —— 行上的遮蔽在 fixture 303 证,这里证的是门)
//   E  第 11 行:/hr/employees/<一名不是本人的员工>/edit —— 不持 data.view_identity 而持 hr.edit 的(cco):四格里画在页面上的都是「受限」
//      (data-identity-masked),一个 identity_no / work_email / work_phone 的输入框都没有;持 data.view_identity 的(finance):输入框在。什么都不存
//   S  第 4 行:/suppliers/<一家已批准的>/edit —— 持 suppliers.view 的读者看得见那句「改身份会回待审」(data-supplier-requeue-warning)
//   M  第 1 行(只那一位读者):PostgREST metal_prices / index_market_calendar / pricing_settings 都读得到行(与 postgres 读到的数相同)
//   A  匿名(不带会话):/verify/cod/<COD-2026-0001 的令牌> 200、写着证书号;PostgREST 以 anon 钥匙读 collection_promise_status → 拒;/login 200
//   P  门户:/portal 200、写着它那一家的代码;/portal/certificates 200
// 中止规则(AGENTS.md「线上证明一次一位读者」):库里 select 1 > 50 ms · 五次往返中位数 > 1.5 s · health 不健康 → 停、收尾、报告;
//   单次往返 > 1.5 s 记下不停;一次 DOCUMENT_CHAIN_WALK_BUDGET 拒绝在库那一侧正常时记下不停。
// 判决只从最后一行 `GOLIVE1_PROOF_EXIT=` 读:0 = 全 PASS 且收尾干净 · 1 = 有 FAIL 或中止 · 2 = 驱动坏了 · 5 = live-lock 被占 · 6 = 收尾没完成。
// 用法:PROOF_BASE=http://localhost:3195 PUPPETEER_DIR=<装着 puppeteer-core 的目录> [PROOF_JSON=<out.json>] node db/scripts/2026-10-29-golive-1-live-proof.mjs
// ════════════════════════════════════════════════════════════════════════════
import { readdirSync, existsSync, writeFileSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { homedir } from 'node:os'
import { createRequire } from 'node:module'
import { spawnSync } from 'node:child_process'
import { onlyWhenRunDirectly } from '../../scripts/lib/entrypoint.mjs'
import { acquireOrExit, release, heldBy } from '../../scripts/liveLock.mjs'
import { openPlan, mintThrowaway, mintThrowawaySupplier, reapStalePlans, installExitHooks, exitAfterCleanup } from '../../scripts/ephemeral.mjs'

onlyWhenRunDirectly(import.meta.url)

const BASE = process.env.PROOF_BASE || 'http://localhost:3195'
const PUP_DIR = process.env.PUPPETEER_DIR
const OUT_JSON = process.env.PROOF_JSON || null
const CHROME_ROOT = join(homedir(), '.cache/puppeteer/chrome-headless-shell')
const DSN = process.env.CHECK_MIRRORS_DSN || 'host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 user=postgres.wvywpohbwkiinmipmuku dbname=postgres'
const SCRIPT = 'db/scripts/2026-10-29-golive-1-live-proof.mjs'
const ROLES = ['admin', 'warehouse', 'cfo', 'cco', 'cto', 'finance', 'gm']

let locked = false, bad = 0, browser = null
const ok = (cond, what) => { console.log(`${cond ? 'PASS' : 'FAIL'}|${what}`); if (!cond) bad++; return cond }
const warnings = []

installExitHooks({
    onFinish: (code) => {
        try { if (locked) release() } catch { /* 放锁失败不改判决 */ }
        console.log('AFTER|nothing but the throwaway accounts, their roles and grants, one throwaway supplier and its portal account was committed (removed by the plan); pages were only read, no form was sent')
        console.log(`GOLIVE1_PROOF_EXIT=${code}`)
    },
})

function psql(sql) {
    const r = spawnSync('psql', [DSN, '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-f', '-'], { input: sql, encoding: 'utf8', timeout: 120_000 })
    if (r.status !== 0) throw new Error(`GL1_DRIVER|psql exit ${r.status}: ${(r.stderr ?? '').split('\n').slice(-4).join(' / ')}`)
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

function env() {
    const txt = readFileSync('.env.local', 'utf8')
    const get = (k) => (txt.match(new RegExp('^' + k + '=(.*)$', 'm'))?.[1] ?? '').trim().replace(/^"|"$/g, '')
    return { URL_: get('NEXT_PUBLIC_SUPABASE_URL'), ANON: get('NEXT_PUBLIC_SUPABASE_ANON_KEY') }
}
let E
const rest = async (token, path) => {
    const r = await fetch(E.URL_ + path, { headers: { apikey: E.ANON, Authorization: `Bearer ${token ?? E.ANON}` } })
    const t = await r.text(); let b = null; try { b = JSON.parse(t) } catch { b = t }
    return { status: r.status, body: b }
}

async function openAs(reader, path) {
    if (!browser) throw new Error('GL1_DRIVER|no browser')
    const ctx = await browser.createBrowserContext()
    const page = await ctx.newPage()
    await page.setViewport({ width: 1440, height: 900 })
    const host = new URL(BASE).hostname
    const cookies = [{ name: 'NEXT_LOCALE', value: 'en', domain: host, path: '/' }]
    if (reader) cookies.push({ name: reader.cookieName, value: reader.cookieValue, domain: host, path: '/' })
    const cdp = await page.createCDPSession()
    await cdp.send('Network.setCookies', { cookies })
    const res = await page.goto(BASE + path, { waitUntil: 'networkidle2', timeout: 180_000 })
    return { page, ctx, status: res?.status() }
}
async function budgetCheck(page, who, path) {
    const budget = await page.evaluate(() => [...document.querySelectorAll('[data-chain-failed]')].some((e) => /DOCUMENT_CHAIN_WALK_BUDGET/.test(e.textContent ?? '')))
    if (!budget) return null
    const why = abortReason(`${who} budget refusal on ${path}`)
    if (why) return `a chain was refused with DOCUMENT_CHAIN_WALK_BUDGET while ${why}`
    const w = `BUDGET_REFUSAL|${who} ${path}: refused with DOCUMENT_CHAIN_WALK_BUDGET while select 1 < 50 ms and db/rest healthy — recorded, not an abort (Tim 2026-10-29)`
    warnings.push(w); console.log(w)
    return null
}

async function main() {
    const other = heldBy()
    if (other) { console.error(`✗ live-lock 被【${other.holder}】(pid ${other.pid})占着`); return exitAfterCleanup(5) }
    acquireOrExit(SCRIPT, { ownExit: false })
    locked = true
    openPlan(SCRIPT)
    await reapStalePlans()
    E = env()

    if (!PUP_DIR || !existsSync(join(PUP_DIR, 'node_modules/puppeteer-core'))) throw new Error('GL1_DRIVER|PUPPETEER_DIR has no node_modules/puppeteer-core')
    const puppeteer = createRequire(join(PUP_DIR, 'package.json'))('puppeteer-core')
    const ver = readdirSync(CHROME_ROOT).sort().pop()
    const exe = join(CHROME_ROOT, ver, 'chrome-headless-shell-mac-arm64', 'chrome-headless-shell')
    try { const r = await fetch(BASE + '/login', { redirect: 'manual' }); if (r.status !== 200) throw new Error(`HTTP ${r.status}`) }
    catch (e) { throw new Error(`GL1_DRIVER|no app at ${BASE}: ${e.message}`) }
    browser = await puppeteer.launch({ executablePath: exe, headless: true, args: ['--no-sandbox'] })
    const report = { roles: {}, warnings }

    // ── 库(以 postgres 读基表 —— rolbypassrls,真行数)──────────────────────────
    const facts = JSON.parse(psql(`SELECT 'PROOF|' || json_build_object(
        'containers', (SELECT count(*) FROM containers WHERE deleted_at IS NULL),
        'metal_prices', (SELECT count(*) FROM metal_prices), 'calendar', (SELECT count(*) FROM index_market_calendar), 'pricing_settings', (SELECT count(*) FROM pricing_settings),
        'contracts', (SELECT count(*) FROM contracts), 'settlements', (SELECT count(*) FROM sales_settlements),
        'supplier', (SELECT id FROM suppliers WHERE code = 'SUP-2026-0003' AND status = 'approved'),
        'employee', (SELECT e.id FROM employees e WHERE e.deleted_at IS NULL AND e.user_id IS DISTINCT FROM '01ae00e4-306f-4527-8537-10291e4750c7' AND e.user_id IS DISTINCT FROM '476bf8c8-c248-4352-9a75-945bf52ca390'
                       ORDER BY (e.residency_status = 'work_pass') DESC, e.code LIMIT 1),
        'employee_work_pass', (SELECT e.residency_status = 'work_pass' FROM employees e WHERE e.deleted_at IS NULL AND e.user_id IS DISTINCT FROM '01ae00e4-306f-4527-8537-10291e4750c7' AND e.user_id IS DISTINCT FROM '476bf8c8-c248-4352-9a75-945bf52ca390'
                       ORDER BY (e.residency_status = 'work_pass') DESC, e.code LIMIT 1),
        'cod_token', (SELECT verification_token FROM certificates_of_destruction WHERE code = 'COD-2026-0001'))::text;`)[0])
    console.log(`STEP|database as postgres (base tables): containers ${facts.containers} · metal_prices ${facts.metal_prices} · calendar ${facts.calendar} · pricing_settings ${facts.pricing_settings} · contracts ${facts.contracts} · settlements ${facts.settlements} · supplier SUP-2026-0003 ${facts.supplier ? 'approved' : 'MISSING'} · employee for E ${facts.employee ? 'found' : 'MISSING'} (work pass ${facts.employee_work_pass})`)
    const expectMasked = facts.employee_work_pass ? 4 : 3

    const stamp = Date.now()
    for (const role of ROLES) {
        { const why = abortReason(`before ${role}`); if (why) { console.log(`ABORT|${why}`); return finish(1) } }
        const reader = await mintThrowaway({ prefix: 'golive1probe', label: role, stamp, codes: { cloneOf: role } })
        const perms = reader.codes
        const has = (c) => perms.includes(c)
        const rr = (report.roles[role] = {})
        // H
        {
            const { ctx, status } = await openAs(reader, '/')
            ok(status === 200, `H ${role}: / → HTTP ${status}`)
            await ctx.close()
        }
        // C
        {
            const { page, ctx, status } = await openAs(reader, '/logistics/containers')
            const n = await page.evaluate(() => {
                const t = document.querySelector('table[data-slot="data-table"]')
                return t ? [...t.querySelectorAll(':scope > tbody > tr')].filter((tr) => !tr.classList.contains('sm:hidden') && tr.querySelectorAll('td').length > 1).length : -1
            })
            rr.containers = n
            ok(status === 200 && n === facts.containers, `C ${role}: /logistics/containers → HTTP ${status}, ${n} rows (database ${facts.containers}; reader holds module.logistics.view ${has('module.logistics.view')})`)
            await ctx.close()
            const ov = await openAs(reader, '/logistics')
            const restricted = await ov.page.evaluate(() => /module\.purchasing\.view|module\.logistics\.view/.test(document.querySelector('main')?.innerText ?? '') && /Restricted/.test(document.querySelector('main')?.innerText ?? ''))
            ok(ov.status === 200 && !restricted, `C ${role}: /logistics → HTTP ${ov.status}, the containers figure is ${restricted ? 'RESTRICTED' : 'drawn (not restricted)'}`)
            await ov.ctx.close()
        }
        // K
        {
            const { page, ctx, status } = await openAs(reader, '/contracts')
            const why = await budgetCheck(page, role, '/contracts')
            if (why) { console.log(`ABORT|${why}`); await ctx.close(); return finish(1) }
            const err = await page.evaluate(() => /Application error|Something went wrong/i.test(document.body.innerText))
            ok(has('module.suppliers.view') ? status === 200 && !err : true, `K ${role}: /contracts → HTTP ${status}${err ? ' ERROR TEXT' : ''} (suppliers.view ${has('module.suppliers.view')})`)
            await ctx.close()
            const base1 = await rest(reader.token, '/rest/v1/sales_settlements?select=amount_usd&limit=1')
            const base2 = await rest(reader.token, '/rest/v1/contract_refining_charges?select=usd_per_tonne_of_metal&limit=1')
            const m1 = await rest(reader.token, '/rest/v1/sales_settlements_masked?select=amount_usd&limit=1')
            const m2 = await rest(reader.token, '/rest/v1/contract_refining_charges_masked?select=usd_per_tonne_of_metal&limit=1')
            const denied = (r) => r.status >= 400 && JSON.stringify(r.body).includes('42501')
            ok(denied(base1) && denied(base2) && m1.status === 200 && m2.status === 200,
               `K ${role}: PostgREST base price columns → ${base1.status} / ${base2.status} (42501 ${denied(base1)} / ${denied(base2)}); masked companions → ${m1.status} / ${m2.status}`)
        }
        // E
        if (facts.employee && has('module.hr.view')) {
            const { page, ctx, status } = await openAs(reader, `/hr/employees/${facts.employee}/edit`)
            const d = await page.evaluate(() => ({
                masked: document.querySelectorAll('[data-identity-masked]').length,
                inputs: ['identity_no', 'work_email', 'work_phone', 'work_pass_no'].filter((n) => document.querySelector(`input[name="${n}"]`)).length,
            }))
            rr.employee = d
            const seesIdentity = has('data.view_identity')
            ok(status === 200 && (seesIdentity ? d.masked === 0 && d.inputs === expectMasked : d.masked === expectMasked && d.inputs === 0),
               `E ${role}: /hr/employees/<id>/edit → HTTP ${status}; data.view_identity ${seesIdentity}: ${d.masked} field(s) drawn 「受限」, ${d.inputs} identity input(s) (nothing saved)`)
            await ctx.close()
        }
        // S
        if (facts.supplier && has('module.suppliers.view')) {
            const { page, ctx, status } = await openAs(reader, `/suppliers/${facts.supplier}/edit`)
            const w = await page.evaluate(() => !!document.querySelector('[data-supplier-requeue-warning]'))
            ok(status === 200 && w, `S ${role}: /suppliers/<SUP-2026-0003>/edit → HTTP ${status}; the "back to review" warning is ${w ? 'shown' : 'MISSING'} (nothing pressed)`)
            await ctx.close()
        }
    }

    // M · 只持 action.metal_prices 的一位
    {
        { const why = abortReason('before metal-only'); if (why) { console.log(`ABORT|${why}`); return finish(1) } }
        const m = await mintThrowaway({ prefix: 'golive1probe', label: 'metal-only', stamp, codes: ['action.metal_prices'] })
        const a = await rest(m.token, '/rest/v1/metal_prices?select=id')
        const b = await rest(m.token, '/rest/v1/index_market_calendar?select=index_code')
        const c = await rest(m.token, '/rest/v1/pricing_settings?select=id')
        const n = (r) => Array.isArray(r.body) ? r.body.length : -1
        ok(a.status === 200 && b.status === 200 && c.status === 200 && n(a) === Math.min(facts.metal_prices, 1000) && n(b) === Math.min(facts.calendar, 1000) && n(c) === facts.pricing_settings,
           `M metal-only: metal_prices ${n(a)} (database ${facts.metal_prices}) · index_market_calendar ${n(b)} (database ${facts.calendar}) · pricing_settings ${n(c)} (database ${facts.pricing_settings})`)
    }

    // A · 匿名
    {
        { const why = abortReason('before anonymous'); if (why) { console.log(`ABORT|${why}`); return finish(1) } }
        const r = await fetch(`${BASE}/verify/cod/${facts.cod_token}`, { redirect: 'manual' })
        const body = await r.text()
        ok(r.status === 200 && body.includes('COD-2026-0001'), `A anonymous: /verify/cod/<token of COD-2026-0001> → HTTP ${r.status}, ${body.includes('COD-2026-0001') ? 'names the certificate' : 'DOES NOT name the certificate'}`)
        const cp = await rest(null, '/rest/v1/collection_promise_status?select=*&limit=1')
        ok(cp.status >= 400, `A anonymous: PostgREST collection_promise_status with the anon key → HTTP ${cp.status}`)
        const login = await fetch(`${BASE}/login`, { redirect: 'manual' })
        ok(login.status === 200, `A anonymous: /login → HTTP ${login.status}`)
    }

    // P · 门户
    {
        { const why = abortReason('before portal'); if (why) { console.log(`ABORT|${why}`); return finish(1) } }
        const S = await mintThrowawaySupplier({ prefix: 'golive1probe', label: 'portal-sup' })
        const P = await mintThrowaway({ prefix: 'golive1probe', label: 'portal', stamp, codes: { portalOf: S.supplierId } })
        const get = async (path) => { const r = await fetch(BASE + path, { headers: { cookie: `${P.cookieName}=${P.cookieValue}; NEXT_LOCALE=en` }, redirect: 'manual' }); return { status: r.status, body: await r.text() } }
        const home = await get('/portal')
        ok(home.status === 200 && home.body.includes(`data-portal-supplier="${S.code}"`), `P portal: /portal → HTTP ${home.status}, ${home.body.includes(`data-portal-supplier="${S.code}"`) ? `names its own supplier ${S.code}` : 'DOES NOT name its supplier'}`)
        const certs = await get('/portal/certificates')
        ok(certs.status === 200, `P portal: /portal/certificates → HTTP ${certs.status}`)
    }

    { const why = abortReason('after the last reader'); if (why) { console.log(`ABORT|${why}`); return finish(1) } }
    if (OUT_JSON) writeFileSync(OUT_JSON, JSON.stringify(report, null, 2))
    console.log(bad ? `STEP|done with ${bad} FAIL` : `STEP|done (${warnings.length} warning(s))`)
    return finish(bad ? 1 : 0)
}

main().catch((e) => {
    console.error(String(e?.stack || e))
    return finish(String(e?.message || '').startsWith('GL1_DRIVER') ? 2 : 1)
})
