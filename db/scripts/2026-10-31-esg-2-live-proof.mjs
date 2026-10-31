#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// ESG-2(v1.4.86)· 线上证明 —— 七个真角色,一次一位读者,真浏览器,对着本刀代码的 next start(PROOF_BASE)读线上的库
// ════════════════════════════════════════════════════════════════════════════
// 委托书 Step 1:"live proof, one reader at a time, all seven roles: each new page opens or reads 「受限」 as its gate says, masking holds,
//   throwaway register entries are removed; nothing real is pressed." 以及 LIVE SAFETY:"if a register's design makes an entry undeletable,
//   prove it on the local rebuild instead and say so."
//   ★ 本刀的四样登记【写下就删不掉】(电网因子 · 公司制度 · 举报与状态 · 误工天数的更正 —— 守卫语句级按名拒 UPDATE / DELETE,Q2 · Q10 · Q14 · Q7),
//     必修培训停用而不删,标准日工时一写就改了 Tim 要自己填的那一格。所以这一支【一行都不写】:写的那一半在本地重建库上由 fixture 307 证
//     (P F S H L C T D W 九臂 + 两格注入,docs/surveys/ESG-2/readings/fixture-307-injections.txt),线上只证读的那一半:
//   每一位读者(admin · cco · cfo · cto · finance · gm · warehouse 的克隆,realRole 那一份码):
//     ① 五张页面(/safety · /safety/energy · /safety/rates · /safety/training · /safety/policies · /safety/whistleblowing)各自打开或画「受限」,
//        与注册表的门逐一相同;ESG 概览上五条新陈述各自是 ok / unanswerable / restricted,与各自的码相同;
//     ② 遮蔽:以这位读者的令牌调 esg_safety_rates → injury_visible 与 data.view_health 相同;whistleblowing_report_readable(false / true)
//        与 data.view_whistleblowing / _escalated 相同;whistleblowing_report_rows / my_concerns 都是零行(线上没有举报);
//        esg_set_grid_factor 以一个不合理的值调:持 action.manage_esg 的人得到 ESG_GRID_FACTOR_VALUE_INVALID(门过了、值被拒,什么都没写),
//        不持的人得到 PERMISSION_DENIED|action.manage_esg。
//   另加一位带员工档案的 cfo 克隆:/me 上「提出一个关切」那一块画出来(不按);HR › 培训 › 新建上有「它满足的必修培训」(admin 克隆)。
// 中止规则(AGENTS.md「线上证明一次一位读者」):每一位读者之前与之后各量一次。
// 判决只从最后一行 `ESG2_PROOF_EXIT=` 读:0 = 全 PASS 且收尾干净 · 1 = 有 FAIL 或中止 · 2 = 驱动坏了 · 5 = live-lock 被占 · 6 = 收尾没完成。
// 用法:PROOF_BASE=http://localhost:3196 PUPPETEER_DIR=<装着 puppeteer-core 的目录> node db/scripts/2026-10-31-esg-2-live-proof.mjs
// ════════════════════════════════════════════════════════════════════════════
import { readdirSync, existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { homedir } from 'node:os'
import { createRequire } from 'node:module'
import { spawnSync } from 'node:child_process'
import { onlyWhenRunDirectly } from '../../scripts/lib/entrypoint.mjs'
import { acquireOrExit, release, heldBy } from '../../scripts/liveLock.mjs'
import { openPlan, mintThrowaway, reapStalePlans, installExitHooks, exitAfterCleanup } from '../../scripts/ephemeral.mjs'

onlyWhenRunDirectly(import.meta.url)

const BASE = process.env.PROOF_BASE || 'http://localhost:3196'
const PUP_DIR = process.env.PUPPETEER_DIR
const CHROME_ROOT = join(homedir(), '.cache/puppeteer/chrome-headless-shell')
const DSN = process.env.CHECK_MIRRORS_DSN || 'host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 user=postgres.wvywpohbwkiinmipmuku dbname=postgres'
const SCRIPT = 'db/scripts/2026-10-31-esg-2-live-proof.mjs'
const ROOT = new URL('../../', import.meta.url).pathname
const ENV = readFileSync(join(ROOT, '.env.local'), 'utf8')
const SB_URL = ENV.match(/NEXT_PUBLIC_SUPABASE_URL=(\S+)/)[1]
const ANON = ENV.match(/NEXT_PUBLIC_SUPABASE_ANON_KEY=(\S+)/)[1]
const ROLES = ['admin', 'cco', 'cfo', 'cto', 'finance', 'gm', 'warehouse']

let locked = false, bad = 0, browser = null
const ok = (cond, what) => { console.log(`${cond ? 'PASS' : 'FAIL'}|${what}`); if (!cond) bad++; return cond }
const warnings = []

installExitHooks({
    onFinish: (code) => {
        try { if (locked) release() } catch { /* 放锁失败不改判决 */ }
        for (const w of warnings) console.log(w)
        console.log('AFTER|committed on live by this run: the throwaway staff clones (one per real role, plus one cfo clone with an employee record) with their roles and grants — every one of them on the cleanup plan; no register entry, setting, report or correction was written, and nothing was pressed')
        console.log(`ESG2_PROOF_EXIT=${code}`)
    },
})

function psql(sql) {
    const r = spawnSync('psql', [DSN, '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-f', '-'], { input: sql, encoding: 'utf8', timeout: 120_000 })
    if (r.status !== 0) throw new Error(`ESG2_DRIVER|psql exit ${r.status}: ${(r.stderr ?? '').split('\n').slice(-4).join(' / ')}`)
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
    const s = selectOne(tag)
    if (s.max > 1500) { const w = `WARN|${tag}: a single round trip took ${s.max.toFixed(0)} ms (> 1500 ms; recorded, not an abort)`; warnings.push(w); console.log(w) }
    if (!(s.exec <= 50)) return `${tag}: select 1 inside the database took ${s.exec} ms (> 50 ms or unreadable)`
    if (!(s.med <= 1500)) return `${tag}: median of five round trips ${s.med?.toFixed(0)} ms (> 1500 ms or unreadable)`
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
    page.on('pageerror', (e) => console.log(`PAGEERROR|${String(e).slice(0, 300)}`))
    return page
}
async function open(page, path) {
    const t0 = Date.now()
    const res = await page.goto(BASE + path, { waitUntil: 'networkidle2', timeout: 180_000 })
    const s = await page.evaluate(() => ({
        denied: !!document.querySelector('[data-access-denied="1"]'),
        nextError: !!document.querySelector('[data-nextjs-error], #__next-error') || /Application error|Something went wrong|This page couldn.t load/i.test(document.body.innerText),
        text: document.body.innerText,
    }))
    return { status: res?.status(), ms: Date.now() - t0, ...s }
}
/** ESG 概览上一条陈述的状态(按标题找那一节,读 data-overview-figure) */
async function figure(page, title) {
    return page.evaluate((t) => {
        const sec = [...document.querySelectorAll('section[data-overview-figure]')].find((s) => s.querySelector('h2')?.textContent.trim() === t)
        return sec ? sec.getAttribute('data-overview-figure') : 'MISSING'
    }, title)
}
async function rpcAs(token, fn, body) {
    const r = await fetch(`${SB_URL}/rest/v1/rpc/${fn}`, { method: 'POST', headers: { apikey: ANON, Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, body: JSON.stringify(body) })
    const text = await r.text()
    let json = null
    try { json = JSON.parse(text) } catch { /* 不是 JSON */ }
    return { status: r.status, json, message: json && !Array.isArray(json) && typeof json === 'object' ? json.message ?? null : null }
}
async function restAs(token, path) {
    const r = await fetch(`${SB_URL}/rest/v1/${path}`, { headers: { apikey: ANON, Authorization: `Bearer ${token}` } })
    return { status: r.status, json: await r.json().catch(() => null) }
}

async function main() {
    const other = heldBy()
    if (other) { console.error(`✗ live-lock 被【${other.holder}】(pid ${other.pid})占着`); return exitAfterCleanup(5) }
    acquireOrExit(SCRIPT, { ownExit: false })
    locked = true
    openPlan(SCRIPT)
    await reapStalePlans()
    if (!PUP_DIR || !existsSync(join(PUP_DIR, 'node_modules/puppeteer-core'))) throw new Error('ESG2_DRIVER|PUPPETEER_DIR has no node_modules/puppeteer-core')
    const puppeteer = createRequire(join(PUP_DIR, 'package.json'))('puppeteer-core')
    const ver = readdirSync(CHROME_ROOT).sort().pop()
    const exe = join(CHROME_ROOT, ver, 'chrome-headless-shell-mac-arm64', 'chrome-headless-shell')
    console.log(`STEP|base ${BASE}`)

    // 前提与收尾都数同一组(postgres,基表):本刀新表在线上应当一直是空的(或只有引导的那一行设定),这一支一行都不写
    const count = () => psql(`SELECT 'PROOF|' || json_build_object('factors', (SELECT count(*) FROM grid_emission_factors), 'hours', (SELECT COALESCE(standard_hours_per_day::text, 'NULL') FROM esg_settings),
        'required', (SELECT count(*) FROM required_trainings), 'policies', (SELECT count(*) FROM company_policies), 'reports', (SELECT count(*) FROM whistleblowing_reports),
        'updates', (SELECT count(*) FROM whistleblowing_updates), 'corrections', (SELECT count(*) FROM incident_days_lost_corrections),
        'linked_records', (SELECT count(*) FROM training_records WHERE required_training_id IS NOT NULL))::text;`)[0]
    const before = count()
    console.log(`STEP|live before (postgres, base tables): ${before}`)

    // 每一个角色此刻在线上的码(postgres 读 role_permissions)—— 期望值从这里推,不从记忆推
    const codes = JSON.parse(psql(`SELECT 'PROOF|' || json_object_agg(r.code, (SELECT array_agg(rp.permission_code) FROM role_permissions rp WHERE rp.role_id = r.id))::text FROM roles r WHERE r.code IN (${ROLES.map((r) => `'${r}'`).join(',')});`)[0])
    const has = (role, c) => (codes[role] ?? []).includes(c)

    browser = await puppeteer.launch({ executablePath: exe, headless: true, args: ['--no-sandbox'] })
    const stamp = Date.now()

    for (const role of ROLES) {
        { const why = abortReason(`before ${role}`); if (why) { console.log(`ABORT|${why}`); return finish(1) } }
        const reader = await mintThrowaway({ prefix: 'esg2probe', label: role, stamp, codes: { cloneOf: role } })
        const p = await pageAs(reader)
        const exp = {
            energy: has(role, 'module.finance.view') || has(role, 'module.processing.view'),
            rates: has(role, 'module.safety.view'),
            training: has(role, 'module.hr.view'),
            policies: true,
            wb: has(role, 'data.view_whistleblowing') || has(role, 'data.view_whistleblowing_escalated'),
            health: has(role, 'data.view_health'),
            manage: has(role, 'action.manage_esg'),
            plain: has(role, 'data.view_whistleblowing'),
            escalated: has(role, 'data.view_whistleblowing_escalated'),
        }
        console.log(`STEP|${role}: codes → energy ${exp.energy} · rates ${exp.rates} · training ${exp.training} · whistleblowing ${exp.wb} (plain ${exp.plain}, escalated ${exp.escalated}) · health ${exp.health} · manage_esg ${exp.manage}`)
        try {
            for (const [path, want] of [['/safety/energy', exp.energy], ['/safety/rates', exp.rates], ['/safety/training', exp.training],
                                        ['/safety/policies', exp.policies], ['/safety/whistleblowing', exp.wb]]) {
                const r = await open(p, path)
                const opened = r.status === 200 && !r.denied && !r.nextError
                const deniedOk = r.status === 200 && r.denied && !r.nextError
                ok(want ? opened : deniedOk, `${role} ${path} (HTTP ${r.status}, ${r.ms} ms): ${r.denied ? 'refused by name (受限)' : r.nextError ? 'ERROR BOUNDARY' : 'opens'} — gate says ${want ? 'opens' : 'refuses'}`)
                if (path === '/safety/rates' && opened) {
                    const restrictedLine = /injury figures are restricted \(data\.view_health\)/.test(r.text)
                    ok(restrictedLine === !exp.health, `${role} /safety/rates: injury figures ${restrictedLine ? 'restricted (data.view_health)' : 'visible'} — data.view_health ${exp.health}`)
                    const hoursState = /Not set — no month has hours worked or a rate until it is\./.test(r.text)
                    ok(hoursState, `${role} /safety/rates: standard hours per day reads "Not set" (ships unset, Q4)`)
                }
                if (path === '/safety/energy' && opened) {
                    ok(/No grid emission factor has been set/.test(r.text), `${role} /safety/energy: the grid factor panel reads "not set" (ships unset, Q1)`)
                    const gated = await p.evaluate(() => !!document.querySelector('[data-form="grid-factor"]')?.closest('fieldset[disabled]'))
                    ok(gated === !exp.manage, `${role} /safety/energy: the factor form is ${gated ? 'visible and unpressable (needs action.manage_esg)' : 'pressable'} — action.manage_esg ${exp.manage}`)
                }
            }
            // ESG 概览:五条新陈述
            const ov = await open(p, '/safety')
            ok(ov.status === 200 && !ov.denied && !ov.nextError, `${role} /safety (HTTP ${ov.status}, ${ov.ms} ms) opens`)
            if (ov.status === 200 && !ov.denied) {
                const f = {
                    scope2: await figure(p, 'Scope 2 emissions'), rates: await figure(p, 'Lost-time injuries'), training: await figure(p, 'Training compliance'),
                    policies: await figure(p, 'Company policies'), wb: await figure(p, 'Open whistleblowing reports'),
                }
                // 线上:没有电费单 → Scope 2 是 unanswerable;没有必修培训 → 培训 unanswerable;没有制度 → 制度 unanswerable
                ok(f.scope2 === (exp.energy ? 'unanswerable' : 'restricted'), `${role} overview · Scope 2: ${f.scope2} (no bill on live; energy codes ${exp.energy})`)
                ok(f.rates === (!exp.rates ? 'restricted' : exp.health ? 'ok' : 'restricted'), `${role} overview · lost-time injuries: ${f.rates} (data.view_health ${exp.health})`)
                ok(f.training === (exp.training ? 'unanswerable' : 'restricted'), `${role} overview · training: ${f.training} (no required training on live; module.hr.view ${exp.training})`)
                ok(f.policies === 'unanswerable', `${role} overview · policies: ${f.policies} (no policy on live)`)
                ok(f.wb === (exp.wb ? 'ok' : 'restricted'), `${role} overview · open reports: ${f.wb} (report codes ${exp.wb})`)
            }
            // 遮蔽与门,以这位读者自己的令牌
            const year = new Date().getFullYear()
            const rates = await rpcAs(reader.token, 'esg_safety_rates', { p_year: year })
            if (exp.rates) {
                const vis = Array.isArray(rates.json) ? [...new Set(rates.json.map((r) => r.injury_visible))] : null
                const ltiNullWhenHidden = Array.isArray(rates.json) && rates.json.every((r) => r.injury_visible || (r.lti === null && r.days_lost === null && r.ltifr === null))
                ok(Array.isArray(vis) && vis.length === 1 && vis[0] === exp.health && ltiNullWhenHidden,
                   `${role} esg_safety_rates(${year}): ${Array.isArray(rates.json) ? rates.json.length : rates.message} rows · injury_visible ${JSON.stringify(vis)} · hidden rows carry no injury figures ${ltiNullWhenHidden}`)
            } else {
                ok(rates.message === 'PERMISSION_DENIED|module.safety.view', `${role} esg_safety_rates refused → ${rates.message}`)
            }
            const rPlain = await rpcAs(reader.token, 'whistleblowing_report_readable', { p_concerns_cco: false })
            const rEsc = await rpcAs(reader.token, 'whistleblowing_report_readable', { p_concerns_cco: true })
            ok(rPlain.json === exp.plain && rEsc.json === exp.escalated,
               `${role} whistleblowing_report_readable: unmarked ${rPlain.json} (data.view_whistleblowing ${exp.plain}) · concerning the CCO ${rEsc.json} (data.view_whistleblowing_escalated ${exp.escalated})`)
            const rows = await restAs(reader.token, 'whistleblowing_report_rows?select=id')
            const mine = await rpcAs(reader.token, 'my_concerns', {})
            ok(Array.isArray(rows.json) && rows.json.length === 0 && Array.isArray(mine.json) && mine.json.length === 0,
               `${role} whistleblowing_report_rows ${Array.isArray(rows.json) ? rows.json.length : rows.status} row(s) · my_concerns ${Array.isArray(mine.json) ? mine.json.length : mine.status} (live has no report)`)
            const gf = await rpcAs(reader.token, 'esg_set_grid_factor', { p_year: year, p_kg_co2_per_kwh: 0, p_source: 'esg-2 live proof (refused by value)' })
            ok(exp.manage ? gf.message === 'ESG_GRID_FACTOR_VALUE_INVALID' : gf.message === 'PERMISSION_DENIED|action.manage_esg',
               `${role} esg_set_grid_factor with value 0 → ${gf.message} (${exp.manage ? 'the gate passed, the value was refused, nothing written' : 'no action.manage_esg'})`)
        } finally {
            await p.close().catch(() => {})
        }
        { const why = abortReason(`after ${role}`); if (why) { console.log(`ABORT|${why}`); return finish(1) } }
    }

    // ── /me 上「提出一个关切」(带员工档案的 cfo 克隆;不按)· HR 培训表单上的必修培训(admin 克隆)──
    { const why = abortReason('before the employee reader'); if (why) { console.log(`ABORT|${why}`); return finish(1) } }
    {
        const emp = await mintThrowaway({ prefix: 'esg2probe', label: 'employee', stamp, codes: { cloneOf: 'cfo' },
            employee: { code: `ZZ-PROBE-ESG2-E-${stamp}`, legal_name: 'ZZ Probe ESG2 employee', employment_type: 'full_time', work_category: 'office', hire_date: '2026-01-01' } })
        const p = await pageAs(emp)
        try {
            const r = await open(p, '/me')
            const shown = await p.evaluate(() => !!document.querySelector('[data-section="raise-concern"]') && !!document.querySelector('[data-open="raise-concern"]'))
            const mineList = await p.evaluate(() => !!document.querySelector('[data-my-concerns]'))
            ok(r.status === 200 && shown && !mineList, `E /me (HTTP ${r.status}): "Raise a concern" is there for an employee; no "Concerns you raised" list (none filed)`)
            // 版式:把表单展开(只是一个界面开关,不写任何东西;发送钮一次都不按),390 px 与 1440 px 量整页宽度
            for (const w of [390, 1440]) {
                await p.setViewport({ width: w, height: w < 768 ? 844 : 900, isMobile: w < 768, hasTouch: w < 768 })
                await p.goto(BASE + '/me', { waitUntil: 'networkidle2', timeout: 180_000 })
                await p.waitForFunction(() => { const e = document.querySelector('[data-open="raise-concern"]'); return !!e && Object.keys(e).some((k) => k.startsWith('__react')) }, { timeout: 60_000 }).catch(() => {})
                await p.click('[data-open="raise-concern"]')
                await p.waitForSelector('[data-form="raise-concern"]', { timeout: 30_000 }).catch(() => {})
                const g = await p.evaluate(() => ({ sw: document.documentElement.scrollWidth, iw: window.innerWidth, form: !!document.querySelector('[data-form="raise-concern"]'),
                    confidential: document.querySelector('[data-confidential]')?.textContent.trim() ?? null }))
                ok(g.form && g.sw <= g.iw + 1 && /Confidential, not anonymous/.test(g.confidential ?? ''),
                   `E LAYOUT ${w}px /me with the concern form open: page ${g.sw}px in a ${g.iw}px window; the form says "${(g.confidential ?? '').slice(0, 60)}…" — the Send button was not pressed`)
            }
        } finally { await p.close().catch(() => {}) }
    }
    { const why = abortReason('after the employee reader'); if (why) { console.log(`ABORT|${why}`); return finish(1) } }
    { const why = abortReason('before the HR form reader'); if (why) { console.log(`ABORT|${why}`); return finish(1) } }
    {
        const adm = await mintThrowaway({ prefix: 'esg2probe', label: 'hrform', stamp, codes: { cloneOf: 'admin' } })
        const p = await pageAs(adm)
        try {
            const r = await open(p, '/hr/training/new')
            const sel = await p.evaluate(() => { const s = document.querySelector('select[name="required_training_id"]'); return s ? s.options.length : -1 })
            ok(r.status === 200 && sel === 1, `H /hr/training/new (HTTP ${r.status}): "Required training it satisfies" select present with ${sel} option(s) (only "not a required training": live has no required training)`)
        } finally { await p.close().catch(() => {}) }
    }
    { const why = abortReason('after the HR form reader'); if (why) { console.log(`ABORT|${why}`); return finish(1) } }

    const after = count()
    ok(after === before, `live after (postgres, base tables): ${after} — unchanged from before`)
    console.log(bad ? `STEP|done with ${bad} FAIL` : 'STEP|done')
    return finish(bad ? 1 : 0)
}

main().catch((e) => {
    console.error(String(e?.stack || e))
    return finish(String(e?.message || '').startsWith('ESG2_DRIVER') ? 2 : 1)
})
