#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// TABLE-EXPORT-2b-1(Tim 2026-10-23)· 线上证明 —— 一个真浏览器按下「导出」读回文件;一次【整支回滚】的保存
// ════════════════════════════════════════════════════════════════════════════
// 委托书:
//   F1 价格(采购条款)/tools/pricing/formulas「Treatment (USD/t)」「Discount %」—— 两臂:看不见采购条款的读者(pricing.view + data.view_prices)
//      屏幕与 CSV / Excel 都是「Restricted」;看得见的读者(再加 data.view_purchase_prices)是数。线上只有一张公式,方向 both(按采购那一侧遮)。
//   F2 同一个看不见的读者打开那张公式的编辑页:加工费 / 折扣 / 比例三处画「Restricted」,没有那两个输入框(只 GET,不保存)。
//   Q5 ★ 整支回滚的保存:看不见条款的人(持 module.pricing.edit)照从前编辑页的样子提交 0 / 0 / 空比例 + 改名 →
//      申请里的拟议条款(terms_requests.proposed)加工费 · 折扣 · 比例 = 公式此刻的值;对照臂(看得见的人送同样的 0)→ 拟议的是 0。
//      psql 一笔事务、以一次性账号的身份(request.jwt.claims)调那扇门,读回,ROLLBACK;回滚之后申请数与公式条款逐字未变。
//   C1 /settings/change-history:线上 change_log 79,000+ 行。?show=500 → 「这份清单最多显示最新的 500 条」那一句在;?show=20 → 不在、「更早」链接在。
//   M1 /me 的一张导出由它的主人按下:一次性员工(没有请假)导出「请假」→ CSV 0 行(线上另有 6 张别人的请假 —— 一张都不许出现);
//      不是员工的账号直接敲那条路由 → 403 EXPORT_DENIED。
// 只读:浏览器只发 GET 与点「导出」;线上提交的只有一次性账号、它们的授权与一个一次性员工(前缀 te2b1probe,共用造号器),由清理计划收走。
//   Q5 那一臂在 psql 的一笔事务里,最后 ROLLBACK —— 不提交任何申请。
// 判决只从最后一行 `TE2B1_PROOF_EXIT=` 读:0 = 全 PASS 且收尾干净 · 1 = 有 FAIL · 2 = 驱动坏了 · 5 = live-lock 被占 · 6 = 收尾没完成。
// 用法:PROOF_BASE=http://localhost:3197 PUPPETEER_DIR=<装着 puppeteer-core 的目录> node db/scripts/2026-10-23-table-export-2b1-live-proof.mjs
// ════════════════════════════════════════════════════════════════════════════
import { mkdtempSync, readdirSync, readFileSync, existsSync } from 'node:fs'
import { join } from 'node:path'
import { tmpdir, homedir } from 'node:os'
import { createRequire } from 'node:module'
import { spawnSync } from 'node:child_process'
import ExcelJS from 'exceljs'
import { onlyWhenRunDirectly } from '../../scripts/lib/entrypoint.mjs'
import { acquireOrExit, release, heldBy } from '../../scripts/liveLock.mjs'
import { openPlan, mintThrowaway, reapStalePlans, installExitHooks, exitAfterCleanup } from '../../scripts/ephemeral.mjs'

onlyWhenRunDirectly(import.meta.url)

const BASE = process.env.PROOF_BASE || 'http://localhost:3197'
const PUP_DIR = process.env.PUPPETEER_DIR
const CHROME_ROOT = join(homedir(), '.cache/puppeteer/chrome-headless-shell')
const DSN = process.env.CHECK_MIRRORS_DSN || 'host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 user=postgres.wvywpohbwkiinmipmuku dbname=postgres'
const SCRIPT = 'db/scripts/2026-10-23-table-export-2b1-live-proof.mjs'

let locked = false, bad = 0, browser = null
const ok = (cond, what) => { console.log(`${cond ? 'PASS' : 'FAIL'}|${what}`); if (!cond) bad++; return cond }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

installExitHooks({
    onFinish: (code) => {
        try { if (locked) release() } catch { /* 放锁失败不改判决 */ }
        console.log('AFTER|nothing but the throwaway accounts, their grants and one throwaway employee was committed (removed by the plan); the Q5 save was rolled back')
        console.log(`TE2B1_PROOF_EXIT=${code}`)
    },
})

function parseCsv(text) {
    const rows = []; let row = [], cell = '', q = false
    const s = text.replace(/^﻿/, '')
    for (let i = 0; i < s.length; i++) {
        const c = s[i]
        if (q) { if (c === '"' && s[i + 1] === '"') { cell += '"'; i++ } else if (c === '"') q = false; else cell += c }
        else if (c === '"') q = true
        else if (c === ',') { row.push(cell); cell = '' }
        else if (c === '\r') { /* CRLF */ }
        else if (c === '\n') { row.push(cell); rows.push(row); row = []; cell = '' }
        else cell += c
    }
    if (cell !== '' || row.length) { row.push(cell); rows.push(row) }
    return rows
}

async function waitForFile(dir, re, timeoutMs) {
    const t0 = Date.now()
    while (Date.now() - t0 < timeoutMs) {
        const f = readdirSync(dir).find((n) => re.test(n))
        if (f) { await sleep(300); return f }
        await sleep(250)
    }
    return null
}

async function openAs(reader, path, { waitUntil = 'networkidle2', timeout = 120_000 } = {}) {
    const page = await browser.newPage()
    const cdp = await page.createCDPSession()
    const host = new URL(BASE).hostname
    await cdp.send('Network.setCookies', { cookies: [
        { name: reader.cookieName, value: reader.cookieValue, domain: host, path: '/' },
        { name: 'NEXT_LOCALE', value: 'en', domain: host, path: '/' },
    ] })
    const res = await page.goto(BASE + path, { waitUntil, timeout })
    return { page, cdp, status: res?.status() }
}

/** 在 `path` 上按名字为 `name` 的那张表的导出钮;`fileName` 是 Q9 的文件名前缀。 */
async function exportOnce(reader, path, fileName, fmt) {
    const dir = mkdtempSync(join(tmpdir(), `te2b1-${fileName}-${fmt}-`))
    const { page, cdp, status } = await openAs(reader, path)
    try {
        if (status !== 200) return { err: `HTTP ${status}` }
        await cdp.send('Browser.setDownloadBehavior', { behavior: 'allow', downloadPath: dir })
        await page.waitForFunction(() => {
            const b = document.querySelector('[data-slot="table-export"] button')
            return !!b && Object.keys(b).some((k) => k.startsWith('__react'))
        }, { timeout: 60_000 })
        const label = fmt === 'csv' ? 'Export CSV' : 'Export Excel'
        // 一页上可能有好几张表:按导出出来的文件名认那一张 —— 每一颗钮都试,直到那个名字的文件落下来
        const n = await page.evaluate(() => document.querySelectorAll('[data-slot="table-export"]').length)
        const re = new RegExp(`^${fileName}_\\d{4}-\\d{2}-\\d{2}_\\d{4}\\.${fmt}$`)
        for (let i = 0; i < n; i++) {
            await page.evaluate((label, i) => {
                const bar = document.querySelectorAll('[data-slot="table-export"]')[i]
                const b = [...bar.querySelectorAll('button')].find((x) => x.textContent?.trim() === label)
                b?.click()
            }, label, i)
            const file = await waitForFile(dir, re, i === n - 1 ? 90_000 : 8_000)
            if (file) return { file, path: join(dir, file) }
        }
        const alert = await page.evaluate(() => [...document.querySelectorAll('[data-slot="table-export"] [role="alert"]')].map((x) => x.textContent).join(' | '))
        return { err: `no ${fmt} file matching ${re}${alert ? ` — on screen: ${alert}` : ''}` }
    } finally {
        await page.close()
    }
}

function csvBody(path) {
    const rows = parseCsv(readFileSync(path, 'utf8'))
    return { head: rows[0] ?? [], body: rows.slice(1).filter((r) => r.length > 1 || r[0] !== '') }
}

async function xlsxCells(path, header) {
    const wb = new ExcelJS.Workbook()
    await wb.xlsx.readFile(path)
    const ws = wb.worksheets[0]
    const headers = ws.getRow(1).values.slice(1)
    const idx = headers.indexOf(header)
    const vals = []
    ws.eachRow((row, n) => { if (n > 1) vals.push(idx >= 0 ? row.getCell(idx + 1).value : undefined) })
    const about = {}
    wb.getWorksheet('About')?.eachRow((r) => { about[String(r.getCell(1).value)] = String(r.getCell(2).value) })
    return { idx, vals, about }
}

/** psql 一次,读回带 `PROOF|` 前缀的那几行;非零退出码就抛(驱动坏了,不是 FAIL)。 */
function psql(sql) {
    const r = spawnSync('psql', [DSN, '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-f', '-'], { input: sql, encoding: 'utf8', timeout: 120_000 })
    const lines = `${r.stdout ?? ''}\n${r.stderr ?? ''}`.split('\n').filter((l) => l.includes('PROOF|'))
    if (r.status !== 0) throw new Error(`TE2B1_DRIVER|psql exit ${r.status}: ${(r.stderr ?? '').split('\n').slice(-4).join(' / ')}`)
    return lines.map((l) => l.slice(l.indexOf('PROOF|') + 6))
}

async function finish(code) {
    try { if (browser) await browser.close() } catch { /* 不改判决 */ }
    browser = null
    return exitAfterCleanup(code)
}

async function main() {
    const other = heldBy()
    if (other) { console.error(`✗ live-lock 被【${other.holder}】(pid ${other.pid})占着`); return exitAfterCleanup(5) }
    acquireOrExit(SCRIPT, { ownExit: false })
    locked = true
    openPlan(SCRIPT)
    await reapStalePlans()

    if (!PUP_DIR || !existsSync(join(PUP_DIR, 'node_modules/puppeteer-core'))) throw new Error('TE2B1_DRIVER|PUPPETEER_DIR has no node_modules/puppeteer-core')
    const puppeteer = createRequire(join(PUP_DIR, 'package.json'))('puppeteer-core')
    const ver = readdirSync(CHROME_ROOT).sort().pop()
    const exe = join(CHROME_ROOT, ver, 'chrome-headless-shell-mac-arm64', 'chrome-headless-shell')
    if (!existsSync(exe)) throw new Error(`TE2B1_DRIVER|no chrome-headless-shell at ${exe}`)
    try { const r = await fetch(BASE + '/login', { redirect: 'manual' }); if (r.status !== 200) throw new Error(`HTTP ${r.status}`) }
    catch (e) { throw new Error(`TE2B1_DRIVER|no app at ${BASE}: ${e.message}`) }
    browser = await puppeteer.launch({ executablePath: exe, headless: true, args: ['--no-sandbox'] })

    const stamp = Date.now()
    const blind = await mintThrowaway({ prefix: 'te2b1probe', label: 'blind', stamp,
        codes: ['module.pricing.view', 'module.pricing.edit', 'data.view_prices'] })
    const sees = await mintThrowaway({ prefix: 'te2b1probe', label: 'sees', stamp,
        codes: ['module.pricing.view', 'module.pricing.edit', 'data.view_prices', 'data.view_purchase_prices'] })

    // ── 公式:线上那一张(方向 both → 按采购那一侧遮)──────────────────────────────
    const [formulaLine] = psql(`SELECT 'PROOF|' || id || '|' || code || '|' || direction || '|' || treatment_charge_usd_per_tonne || '|' || flat_discount_pct
        || '|' || (SELECT count(*) FROM pricing_formula_metals m WHERE m.formula_id = f.id)
        FROM pricing_formulas f WHERE deleted_at IS NULL AND is_active AND direction IN ('both','purchase') ORDER BY code LIMIT 1;`)
    if (!formulaLine) throw new Error('TE2B1_DRIVER|live has no active purchase/both formula to prove against')
    const [fId, fCode, fDir, fTreat, fDisc, fMetals] = formulaLine.split('|')
    console.log(`STEP|formula ${fCode} (direction ${fDir}): treatment ${fTreat} · discount ${fDisc} · ${fMetals} payable lines (read as postgres, base table)`)

    // F1 屏幕 + 导出,两臂
    for (const [arm, reader] of [['restricted', blind], ['permitted', sees]]) {
        const { page, status } = await openAs(reader, '/tools/pricing/formulas')
        let rowText = ''
        try {
            rowText = await page.evaluate((code) => [...document.querySelectorAll('tr')].find((tr) => tr.textContent?.includes(code))?.textContent ?? '', fCode)
        } finally { await page.close() }
        ok(status === 200 && (arm === 'restricted' ? rowText.includes('Restricted') : !rowText.includes('Restricted')),
           `F1 ${arm} reader (${reader.codes.join(' + ')}) · /tools/pricing/formulas → HTTP ${status}; the ${fCode} row on screen ${rowText.includes('Restricted') ? 'shows' : 'does not show'} "Restricted"`)
        const csv = await exportOnce(reader, '/tools/pricing/formulas', 'pricing-formulas', 'csv')
        if (ok(!csv.err, `F1 ${arm} · CSV downloaded${csv.err ? ` — ${csv.err}` : `: ${csv.file}`}`)) {
            const { head, body } = csvBody(csv.path)
            const row = body.find((r) => r[head.indexOf('Code')]?.startsWith(fCode))
            const tc = row?.[head.indexOf('Treatment (USD/t)')], dc = row?.[head.indexOf('Discount %')]
            ok(arm === 'restricted' ? tc === 'Restricted' && dc === 'Restricted' : tc !== 'Restricted' && Number(tc) === Number(fTreat) && Number(dc) === Number(fDisc),
               `F1 ${arm} · CSV ${fCode}: "Treatment (USD/t)" = ${JSON.stringify(tc)}, "Discount %" = ${JSON.stringify(dc)} (stored ${fTreat} / ${fDisc})`)
        }
        const x = await exportOnce(reader, '/tools/pricing/formulas', 'pricing-formulas', 'xlsx')
        if (ok(!x.err, `F1 ${arm} · Excel downloaded${x.err ? ` — ${x.err}` : `: ${x.file}`}`)) {
            const f = await xlsxCells(x.path, 'Treatment (USD/t)')
            ok(arm === 'restricted' ? f.vals.length > 0 && f.vals.every((v) => v === 'Restricted') : f.vals.some((v) => typeof v === 'number'),
               `F1 ${arm} · Excel "Treatment (USD/t)": ${JSON.stringify(f.vals)} (${arm === 'restricted' ? 'want every cell "Restricted"' : 'want a cell typed Number'})`)
            ok(f.about['Exported by'] === reader.email, `F1 ${arm} · About sheet "Exported by" = ${f.about['Exported by'] ?? '(missing)'}`)
        }
    }

    // F2 编辑页(只 GET)
    {
        const { page, status } = await openAs(blind, `/tools/pricing/formulas/${fId}/edit`)
        try {
            const facts = await page.evaluate(() => ({
                treatInput: !!document.querySelector('input[name="treatment_charge_usd_per_tonne"]'),
                discInput: !!document.querySelector('input[name="flat_discount_pct"]'),
                payBridge: !!document.querySelector('input[name="payables_json"]'),
                restricted: (document.body.innerText.match(/Restricted/g) ?? []).length,
            }))
            ok(status === 200 && !facts.treatInput && !facts.discInput && !facts.payBridge && facts.restricted >= 3,
               `F2 blind reader · edit page → HTTP ${status}; treatment input ${facts.treatInput}, discount input ${facts.discInput}, payables bridge ${facts.payBridge}, "Restricted" × ${facts.restricted} (want no inputs, ≥ 3 "Restricted")`)
        } finally { await page.close() }
    }

    // Q5 整支回滚的保存(psql,一笔事务,ROLLBACK)
    {
        const claims = (u) => `SELECT set_config('request.jwt.claims', '{"sub":"${u}","role":"authenticated"}', true);`
        const terms = (name) => `jsonb_build_object('name', ${sqlLit(name)}, 'direction', ${sqlLit(fDir)}, 'price_basis', 'spot',
            'treatment_charge_usd_per_tonne', 0, 'flat_discount_pct', 0, 'metals', '[]'::jsonb)`
        const before = psql(`SELECT 'PROOF|' || (SELECT count(*) FROM terms_requests) || '|' || formula_terms_state('${fId}')::text;`)[0]
        const lines = psql(`BEGIN;
${claims(blind.userId)}
SET LOCAL ROLE authenticated;
SELECT 'PROOF|blind|' || submit_formula_change_request('${fId}', ${terms(`${fCode} te2b1 blind`)}, 'TE2B1 live proof (rolled back)')::text;
RESET ROLE;
SELECT 'PROOF|blind-proposed|' || (SELECT proposed::text FROM terms_requests WHERE formula_id = '${fId}' AND status = 'submitted' ORDER BY created_at DESC LIMIT 1);
SELECT 'PROOF|state|' || formula_terms_state('${fId}')::text;
ROLLBACK;
BEGIN;
${claims(sees.userId)}
SET LOCAL ROLE authenticated;
SELECT 'PROOF|sees|' || submit_formula_change_request('${fId}', ${terms(`${fCode} te2b1 sees`)}, 'TE2B1 live proof control (rolled back)')::text;
RESET ROLE;
SELECT 'PROOF|sees-proposed|' || (SELECT proposed::text FROM terms_requests WHERE formula_id = '${fId}' AND status = 'submitted' ORDER BY created_at DESC LIMIT 1);
ROLLBACK;`)
        const after = psql(`SELECT 'PROOF|' || (SELECT count(*) FROM terms_requests) || '|' || formula_terms_state('${fId}')::text;`)[0]
        const pick = (tag) => lines.find((l) => l.startsWith(tag + '|'))?.slice(tag.length + 1) ?? null
        const state = JSON.parse(pick('state') ?? 'null')
        const bp = JSON.parse(pick('blind-proposed') ?? 'null')
        const sp = JSON.parse(pick('sees-proposed') ?? 'null')
        console.log(`STEP|Q5 blind submit → ${pick('blind')} · control submit → ${pick('sees')}`)
        ok(!!bp && !!state && Number(bp.treatment_charge_usd_per_tonne) === Number(state.treatment_charge_usd_per_tonne)
            && Number(bp.flat_discount_pct) === Number(state.flat_discount_pct) && JSON.stringify(bp.metals) === JSON.stringify(state.metals)
            && bp.name === `${fCode} te2b1 blind`,
           `Q5 blind editor (no data.view_purchase_prices) sent 0 / 0 / [] → the request proposes treatment ${bp?.treatment_charge_usd_per_tonne}, discount ${bp?.flat_discount_pct}, ${bp?.metals?.length} payable lines, name ${JSON.stringify(bp?.name)} (stored ${state?.treatment_charge_usd_per_tonne} / ${state?.flat_discount_pct} / ${state?.metals?.length})`)
        ok(!!sp && Number(sp.treatment_charge_usd_per_tonne) === 0 && Number(sp.flat_discount_pct) === 0,
           `Q5 control · an editor who sees the terms sent the same 0 / 0 → the request proposes ${sp?.treatment_charge_usd_per_tonne} / ${sp?.flat_discount_pct} (the arms separate)`)
        ok(before === after, `Q5 rolled back · terms_requests count and the formula's terms before = after: ${before === after ? 'identical' : `${before} → ${after}`}`)
    }

    // C1 change-history 停在 500
    {
        const reader = await mintThrowaway({ prefix: 'te2b1probe', label: 'log', stamp, codes: ['data.view_change_log'] })
        for (const [show, want] of [['500', true], ['20', false]]) {
            // ?show=500 读 500 次操作:第一次跑在 networkidle2 / 120 s 上超时(readings/live-proof-run1-change-history-timeout.txt)——
            //   等 load,再等那一节画出来(分页那一行),上限 300 s
            const t0 = Date.now()
            const { page, status } = await openAs(reader, `/settings/change-history?show=${show}`, { waitUntil: 'load', timeout: 300_000 })
            // 等判据读的那两样之一画出来(停止提示 / 「更早」链接);到点不抛,照屏幕上有什么报(第二次跑在一个不存在的 <main> 上等空了)
            await page.waitForFunction(() => !!document.querySelector('[data-change-history-stop]')
                || [...document.querySelectorAll('a')].some((a) => /show=\d+/.test(a.getAttribute('href') ?? '')), { timeout: 60_000 }).catch(() => {})
            console.log(`STEP|C1 ?show=${show} loaded in ${Math.round((Date.now() - t0) / 1000)} s`)
            try {
                const f = await page.evaluate(() => ({
                    notice: document.querySelector('[data-change-history-stop]')?.textContent ?? null,
                    older: [...document.querySelectorAll('a')].some((a) => /show=\d+/.test(a.getAttribute('href') ?? '')),
                    head: document.body.innerText.slice(0, 160).replace(/\s+/g, ' '),
                }))
                if (f.notice === null && !f.older) console.log(`STEP|C1 ?show=${show} on screen: ${f.head}`)
                ok(status === 200 && (want ? f.notice !== null && !f.older : f.notice === null && f.older),
                   `C1 /settings/change-history?show=${show} → HTTP ${status}; stop notice ${f.notice === null ? 'absent' : JSON.stringify(f.notice)}; "older" link ${f.older ? 'present' : 'absent'}`)
            } finally { await page.close() }
        }
    }

    // M1 /me 的一张导出,由它的主人按下
    {
        const [others] = psql(`SELECT 'PROOF|' || (SELECT count(*) FROM leave_requests WHERE deleted_at IS NULL);`)
        const owner = await mintThrowaway({ prefix: 'te2b1probe', label: 'me', stamp, codes: ['module.tasks.view'],
            employee: { legal_name: 'TE2B1 Probe', first_name: 'TE2B1', employment_type: 'full_time', work_category: 'office', hire_date: '2026-01-05' } })
        const csv = await exportOnce(owner, '/me', 'me-leave-requests', 'csv')
        if (ok(!csv.err, `M1 owner · /me → leave requests CSV downloaded${csv.err ? ` — ${csv.err}` : `: ${csv.file}`}`)) {
            const { head, body } = csvBody(csv.path)
            ok(head.includes('Ref') && body.length === 0,
               `M1 owner · the CSV has ${body.length} data rows (the throwaway employee has none; live holds ${others} leave requests of other people — none may appear) · headers ${JSON.stringify(head)}`)
        }
        const r = await fetch(`${BASE}/me/leave-requests/export`, { headers: { cookie: owner.cookie } })
        const j = await r.json().catch((e) => ({ parseError: String(e) }))
        ok(r.status === 200 && Array.isArray(j.rows) && j.rows.length === 0, `M1 owner · /me/leave-requests/export → HTTP ${r.status}, ${Array.isArray(j.rows) ? j.rows.length : '?'} rows`)
        const nobody = await fetch(`${BASE}/me/leave-requests/export`, { headers: { cookie: blind.cookie } })
        const nb = await nobody.json().catch((e) => ({ parseError: String(e) }))
        ok(nobody.status === 403 && nb.code === 'EXPORT_DENIED', `M1 an account with no employee profile → HTTP ${nobody.status} ${JSON.stringify(nb)}`)
    }

    console.log(bad ? `STEP|done with ${bad} FAIL` : 'STEP|done')
    return finish(bad ? 1 : 0)
}

function sqlLit(s) { return `'${String(s).replace(/'/g, "''")}'` }

main().catch((e) => {
    console.error(String(e?.stack || e))
    return finish(String(e?.message || '').startsWith('TE2B1_DRIVER') ? 2 : 1)
})
