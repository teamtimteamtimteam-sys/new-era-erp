#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// CONTRACT-ESIGN(v1.4.85)· 线上证明 —— 一次一位读者,真浏览器,对着本刀代码的 next start(PROOF_BASE)读线上的库
// ════════════════════════════════════════════════════════════════════════════
// Tim 2026-10-30(裁定块末段):"the throwaway contract must be ACTIVE before signing; activate it through the real CFO activation path
//   inside the proof only if that can be done with throwaway accounts and fully removed afterwards; otherwise prove the signing path on the local
//   rebuild and prove on live only what does not need an active contract (upload, refusal of signing on a draft, the signatory list, the specimen,
//   the stamp), and say which."
//   ★ 走不了 CFO 那条路:decide_terms_request 写 approval_log(trg_approval_log_append_only:BEFORE UPDATE OR DELETE 一律拒)——
//     一次批准在线上留下一行【删不掉】的审批记录;而批的人要持真的 cfo 角色(require_approver_for → approval_level_eligible)。
//     两条都违反"一次性、收尾删干净"。所以签字那一条路在本地重建库上证(fixture 306 的 G / I / C / V 臂 + stampPdf 的本地读数),
//     线上只证不要生效合同的那几件:
//   A  admin 克隆:设置 · 合同签署人 —— 经真的表单把一次性员工加进名单;上传公司印章(线上此前 0 张才做);一份一次性【草稿】合同
//      (挂一家一次性供应商)上,经真的表单传一份 PDF:字节浏览器直传 contract-files、页面印出的 sha256 = 本地文件的 sha256 =
//      取件路由取回的字节的 sha256;一份冒充 PDF 的 PNG 在存任何字节之前按名拒;对方签回件在我方签过之前按名拒。
//   S  签署人(cfo 克隆 + 员工档案):/me 上画签名、存下;合同页上「签署」按不动、说出"合同不在生效中";签字页同样;
//      以一个刚凭密码登录的令牌调 contract_sign_begin → CONTRACT_SIGN_NOT_ACTIVE(密码时刻那一条排在它前面,所以这一句同时证明
//      线上令牌的 amr 里有 password 那一项、库读得到它)。
//   N  不在名单上的读者(finance 克隆):contract_sign_begin → CONTRACT_SIGN_NOT_SIGNATORY;印章对象读不到。
//   R  只持 module.suppliers.view 的读者(没有采购价码,Q8):合同页上合同文件那一块是「受限」与理由;那一行与那个对象都读不到。
//   版式:合同页(带文件)、签字页(签不了的那一态)、签署人名单与印章、/me 的签名板 —— 390 px 与 1440 px 整页不横向溢出。
//   收尾(计划先于东西落盘):合同(级联它的文件行)· contract-files 的对象 · 印章行与对象 · 样本行与对象 · 名单行 · 员工 · 授权 · 角色 · 账号 · 供应商。
// 中止规则(AGENTS.md「线上证明一次一位读者」):每一位读者之前与最后各量一次。
// 判决只从最后一行 `CES_PROOF_EXIT=` 读:0 = 全 PASS 且收尾干净 · 1 = 有 FAIL 或中止 · 2 = 驱动坏了 · 5 = live-lock 被占 · 6 = 收尾没完成。
// 用法:PROOF_BASE=http://localhost:3196 PUPPETEER_DIR=<装着 puppeteer-core 的目录> node db/scripts/2026-10-30-contract-esign-live-proof.mjs
// ════════════════════════════════════════════════════════════════════════════
import { readdirSync, existsSync, writeFileSync, readFileSync, mkdtempSync, rmSync } from 'node:fs'
import { join } from 'node:path'
import { homedir, tmpdir } from 'node:os'
import { createRequire } from 'node:module'
import { spawnSync } from 'node:child_process'
import { createHash, randomUUID } from 'node:crypto'
import { onlyWhenRunDirectly } from '../../scripts/lib/entrypoint.mjs'
import { acquireOrExit, release, heldBy } from '../../scripts/liveLock.mjs'
import { openPlan, planDelete, mintThrowaway, mintThrowawaySupplier, reapStalePlans, installExitHooks, exitAfterCleanup } from '../../scripts/ephemeral.mjs'

onlyWhenRunDirectly(import.meta.url)

const BASE = process.env.PROOF_BASE || 'http://localhost:3196'
const PUP_DIR = process.env.PUPPETEER_DIR
const CHROME_ROOT = join(homedir(), '.cache/puppeteer/chrome-headless-shell')
const DSN = process.env.CHECK_MIRRORS_DSN || 'host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 user=postgres.wvywpohbwkiinmipmuku dbname=postgres'
const SCRIPT = 'db/scripts/2026-10-30-contract-esign-live-proof.mjs'
const ROOT = new URL('../../', import.meta.url).pathname
const ENV = readFileSync(join(ROOT, '.env.local'), 'utf8')
const SB_URL = ENV.match(/NEXT_PUBLIC_SUPABASE_URL=(\S+)/)[1]
const ANON = ENV.match(/NEXT_PUBLIC_SUPABASE_ANON_KEY=(\S+)/)[1]
// 计划里的档位:我们自己造的行要排在员工(20)之前删;合同最先(它级联文件行,文件行再放开样本 / 印章 / 名单的外键)
const O = { CONTRACT: 11, OBJECT: 12, ASSET_ROWS: 13, SIGNATORY: 14 }

let locked = false, bad = 0, browser = null, tmp = null
const ok = (cond, what) => { console.log(`${cond ? 'PASS' : 'FAIL'}|${what}`); if (!cond) bad++; return cond }
const warnings = []
const sha = (b) => createHash('sha256').update(b).digest('hex')

installExitHooks({
    onFinish: (code) => {
        try { if (locked) release() } catch { /* 放锁失败不改判决 */ }
        try { if (tmp) rmSync(tmp, { recursive: true, force: true }) } catch { /* 临时文件 */ }
        for (const w of warnings) console.log(w)
        console.log('AFTER|committed on live by this run: a throwaway supplier and one draft contract on it, one contract file and its stored object, one signatory entry, one specimen and (if live had none) one company stamp with their stored objects, and the throwaway staff clones with their employee record, roles and grants — every one of them on the cleanup plan; nothing real was signed, stamped, uploaded onto or pressed')
        console.log(`CES_PROOF_EXIT=${code}`)
    },
})

function psql(sql) {
    const r = spawnSync('psql', [DSN, '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-f', '-'], { input: sql, encoding: 'utf8', timeout: 120_000 })
    if (r.status !== 0) throw new Error(`CES_DRIVER|psql exit ${r.status}: ${(r.stderr ?? '').split('\n').slice(-4).join(' / ')}`)
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
    page.on('pageerror', (e) => console.log(`PAGEERROR|${String(e).slice(0, 300)}`))
    return page
}
async function go(page, path, readySel) {
    const res = await page.goto(BASE + path, { waitUntil: 'networkidle2', timeout: 180_000 })
    if (readySel) await page.waitForFunction(hydrated(readySel), { timeout: 60_000 }).catch(() => {})
    return res?.status()
}
async function layout(page, path, label) {
    for (const w of [390, 1440]) {
        await page.setViewport({ width: w, height: w < 768 ? 844 : 900, isMobile: w < 768, hasTouch: w < 768 })
        await go(page, path)
        const g = await page.evaluate(() => ({ sw: document.documentElement.scrollWidth, iw: window.innerWidth }))
        ok(g.sw <= g.iw + 1, `LAYOUT ${w}px ${label}: page ${g.sw}px wide in a ${g.iw}px window — no sideways scroll`)
    }
    await page.setViewport({ width: 1440, height: 900 })
}
/** REST / RPC as a reader's token */
async function rpcAs(token, fn, body) {
    const r = await fetch(`${SB_URL}/rest/v1/rpc/${fn}`, { method: 'POST', headers: { apikey: ANON, Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, body: JSON.stringify(body) })
    const text = await r.text()
    let msg = null
    try { msg = JSON.parse(text)?.message ?? null } catch { /* 不是 JSON */ }
    return { status: r.status, text, message: msg }
}
async function passwordToken(reader) {
    const r = await fetch(`${SB_URL}/auth/v1/token?grant_type=password`, { method: 'POST', headers: { apikey: ANON, 'Content-Type': 'application/json' },
        body: JSON.stringify({ email: reader.email, password: reader.password }) })
    const j = await r.json()
    if (!r.ok || !j.access_token) throw new Error(`CES_DRIVER|password sign-in for ${reader.email}: HTTP ${r.status}`)
    // 只取 amr 一项(不印令牌本身)
    const claims = JSON.parse(Buffer.from(j.access_token.split('.')[1], 'base64url').toString('utf8'))
    // 这一次登录只为了拿一个刚凭密码签发的令牌;用完即登出这一个会话(scope=local)
    return { token: j.access_token, amr: claims.amr ?? null, logout: () => fetch(`${SB_URL}/auth/v1/logout?scope=local`, { method: 'POST', headers: { apikey: ANON, Authorization: `Bearer ${j.access_token}` } }) }
}
async function getAs(reader, path) {
    const r = await fetch(BASE + path, { headers: { cookie: `${reader.cookieName}=${reader.cookieValue}; NEXT_LOCALE=en` }, redirect: 'manual' })
    return { status: r.status, bytes: Buffer.from(await r.arrayBuffer()), headers: r.headers }
}

/** 一份真的两页 PDF(手写的最小结构,不靠库) */
function makePdf(name) {
    const objs = ['<< /Type /Catalog /Pages 2 0 R >>', '<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>',
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] >>', '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] >>']
    let out = '%PDF-1.4\n%CONTRACT-ESIGN live proof — throwaway, removed by the cleanup plan\n'
    const offs = []
    objs.forEach((o, i) => { offs.push(Buffer.byteLength(out)); out += `${i + 1} 0 obj\n${o}\nendobj\n` })
    const xref = Buffer.byteLength(out)
    out += `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n` + offs.map((o) => String(o).padStart(10, '0') + ' 00000 n \n').join('')
    out += `trailer\n<< /Size ${objs.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`
    const p = join(tmp, name)
    writeFileSync(p, out)
    return p
}
/** 一张 1×1 的 PNG(冒充 PDF 用)与一张 64×64 的红圈 PNG(印章用)*/
function makePng(name) {
    const px = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==', 'base64')
    const p = join(tmp, name)
    writeFileSync(p, px)
    return p
}

async function main() {
    const other = heldBy()
    if (other) { console.error(`✗ live-lock 被【${other.holder}】(pid ${other.pid})占着`); return exitAfterCleanup(5) }
    acquireOrExit(SCRIPT, { ownExit: false })
    locked = true
    openPlan(SCRIPT)
    await reapStalePlans()
    if (!PUP_DIR || !existsSync(join(PUP_DIR, 'node_modules/puppeteer-core'))) throw new Error('CES_DRIVER|PUPPETEER_DIR has no node_modules/puppeteer-core')
    const puppeteer = createRequire(join(PUP_DIR, 'package.json'))('puppeteer-core')
    const ver = readdirSync(CHROME_ROOT).sort().pop()
    const exe = join(CHROME_ROOT, ver, 'chrome-headless-shell-mac-arm64', 'chrome-headless-shell')
    tmp = mkdtempSync(join(tmpdir(), 'ces-proof-'))
    console.log(`STEP|base ${BASE}`)

    // ── 前提:线上没有任何签署人、样本、印章、合同文件(本刀新建的表)—— 否则这一次证明会动到别人的东西,停 ──
    const pre = psql(`SELECT 'PROOF|' || (SELECT count(*) FROM contract_signatories) || '|' || (SELECT count(*) FROM signature_specimens) || '|' || (SELECT count(*) FROM company_stamps) || '|' || (SELECT count(*) FROM contract_files);`)[0].split('|').map(Number)
    console.log(`STEP|live before (postgres, base tables): signatories ${pre[0]} · specimens ${pre[1]} · stamps ${pre[2]} · contract files ${pre[3]}`)
    if (pre.some((n) => n !== 0)) { console.log('ABORT|the new tables already hold rows on live — this proof would touch them; stopping'); return finish(1) }

    browser = await puppeteer.launch({ executablePath: exe, headless: true, args: ['--no-sandbox'] })
    const stamp = Date.now()

    // ── 一次性的东西:供应商 → 草稿合同(id 本地生成,删除步先落盘)──
    const sup = await mintThrowawaySupplier({ prefix: 'cesprobe', label: 'contract' })
    const supplierId = sup.id ?? sup.supplierId
    const contractId = randomUUID()
    planDelete(`/rest/v1/contracts?id=eq.${contractId}`, `删一次性合同 ${contractId}(级联它的合同文件行)`, O.CONTRACT)

    // ════════ A · admin 克隆 ════════
    { const why = abortReason('before the admin reader'); if (why) { console.log(`ABORT|${why}`); return finish(1) } }
    const admin = await mintThrowaway({ prefix: 'cesprobe', label: 'admin', stamp, codes: { cloneOf: 'admin' } })
    const signer = await mintThrowaway({ prefix: 'cesprobe', label: 'signer', stamp, codes: { cloneOf: 'cfo' },
        employee: { code: `ZZ-PROBE-CES-S-${stamp}`, legal_name: 'ZZ Probe CES signer', employment_type: 'full_time', work_category: 'office', hire_date: '2026-01-01' } })
    planDelete(`/rest/v1/signature_specimens?employee_id=eq.${signer.employeeId}`, '删一次性签字样本行', O.ASSET_ROWS)
    planDelete(`/rest/v1/company_stamps?created_by=eq.${admin.userId}`, '删一次性公司印章行', O.ASSET_ROWS)
    planDelete(`/rest/v1/contract_signatories?employee_id=eq.${signer.employeeId}`, '删一次性签署人行', O.SIGNATORY)
    // 草稿合同:以 admin 克隆的令牌写(写策略 action.contract_terms)
    {
        const r = await fetch(`${SB_URL}/rest/v1/contracts`, { method: 'POST', headers: { apikey: ANON, Authorization: `Bearer ${admin.token}`, 'Content-Type': 'application/json' },
            body: JSON.stringify({ id: contractId, supplier_id: supplierId, kind: 'supply', title: `ZZ-PROBE CES ${stamp}`, effective_from: '2026-10-01', status: 'draft' }) })
        if (!r.ok) throw new Error(`CES_DRIVER|create the throwaway contract: HTTP ${r.status} ${(await r.text()).slice(0, 200)}`)
    }
    const code = psql(`SELECT 'PROOF|' || code FROM contracts WHERE id = '${contractId}';`)[0]
    console.log(`STEP|throwaway draft contract ${code} on throwaway supplier ${supplierId}`)

    const pa = await pageAs(admin)
    const toStorage = []
    await pa.setRequestInterception(true)
    pa.on('request', (req) => {
        const m = req.url().match(/\/storage\/v1\/object\/contract-files\/([^?]+)/)
        if (m && req.method() !== 'GET' && req.method() !== 'OPTIONS') {
            const objPath = decodeURIComponent(m[1])
            planDelete('/storage/v1/object/contract-files', `删一次性合同文件对象 ${objPath}`, O.OBJECT,
                { method: 'DELETE', body: JSON.stringify({ prefixes: [objPath] }), headers: { 'Content-Type': 'application/json' } })
            toStorage.push({ path: objPath, len: Number(req.headers()['content-length'] ?? 0) })
        }
        req.continue()
    })
    // A1 · 名单:经真的表单加一次性签署人
    {
        const st = await go(pa, '/settings/signatories', '[data-signatory-add-button]')
        ok(st === 200, `A /settings/signatories (HTTP ${st}) opens for the admin clone`)
        await pa.click('[data-signatory-employee]')
        await pa.waitForSelector('[role="option"]', { timeout: 30_000 })
        const picked = await pa.evaluate((codeWanted) => {
            const o = [...document.querySelectorAll('[role="option"]')].find((x) => x.textContent.includes(codeWanted))
            if (!o) return false
            o.scrollIntoView(); return true
        }, `ZZ-PROBE-CES-S-${stamp}`)
        if (picked) {
            const opts = await pa.$$('[role="option"]')
            for (const o of opts) { if ((await o.evaluate((x) => x.textContent)).includes(`ZZ-PROBE-CES-S-${stamp}`)) { await o.click(); break } }
        }
        await pa.type('[data-signatory-title]', 'Probe Director')
        await pa.click('[data-signatory-add-button]')
        await pa.waitForSelector(`[data-signatory="ZZ-PROBE-CES-S-${stamp}"]`, { timeout: 60_000 }).catch(() => {})
        const listed = psql(`SELECT 'PROOF|' || count(*) || '|' || COALESCE(max(title), '') || '|' || COALESCE(max(added_by::text), '') FROM contract_signatories WHERE employee_id = '${signer.employeeId}' AND removed_at IS NULL;`)[0].split('|')
        const logged = Number(psql(`SELECT 'PROOF|' || count(*) FROM change_log WHERE table_name = 'contract_signatories' AND new ->> 'employee_id' = '${signer.employeeId}';`)[0])
        ok(picked && listed[0] === '1' && listed[1] === 'Probe Director' && listed[2] === admin.userId && logged >= 1,
           `A the throwaway employee was added through the form: ${listed[0]} active row, title "${listed[1]}", added by the admin clone; ${logged} change-log row(s)`)
    }
    // A2 · 公司印章:经真的表单上传(线上此前 0 张)
    {
        const png = makePng('stamp.png')
        await go(pa, '/settings/signatories', '[data-stamp-upload]')
        await (await pa.$('[data-stamp-input]')).uploadFile(png)
        await pa.click('[data-stamp-upload]')
        await pa.waitForSelector('[data-stamp-current]', { timeout: 60_000 }).catch(() => {})
        const row = psql(`SELECT 'PROOF|' || id || '|' || file_path || '|' || sha256 FROM company_stamps WHERE created_by = '${admin.userId}' AND superseded_at IS NULL;`)[0]?.split('|')
        if (row) planDelete('/storage/v1/object/signing-assets', `删一次性印章对象 ${row[1]}`, O.OBJECT,
            { method: 'DELETE', body: JSON.stringify({ prefixes: [row[1]] }), headers: { 'Content-Type': 'application/json' } })
        const shown = await pa.$('[data-stamp-current]')
        ok(!!row && !!shown, `A the company stamp was uploaded through the form: ${row ? row[1] : 'NO ROW'} (sha256 ${row?.[2]?.slice(0, 12)}…), shown on the page`)
    }
    // A3 · 合同文件:一份冒充 PDF 的 PNG 先被按名拒,然后一份真的 PDF 经表单直传
    {
        const st = await go(pa, `/contracts/${contractId}`, '[data-upload-button="original"]')
        ok(st === 200, `A /contracts/${code} (HTTP ${st}) opens; the contract files section is there`)
        const fake = join(tmp, 'not-a-pdf.pdf'); writeFileSync(fake, readFileSync(makePng('fake.png')))
        await (await pa.$('[data-file-input="original"]')).uploadFile(fake)
        const n0 = toStorage.length
        await pa.click('[data-upload-button="original"]')
        await pa.waitForFunction(() => /Only PDF files are accepted/.test(document.body.innerText), { timeout: 60_000 }).catch(() => {})
        const said = await pa.evaluate(() => /Only PDF files are accepted \(this one reads as image\/png\)/.test(document.body.innerText))
        const rows0 = Number(psql(`SELECT 'PROOF|' || count(*) FROM contract_files WHERE contract_id = '${contractId}';`)[0])
        ok(said && toStorage.length === n0 && rows0 === 0, `A a PNG named .pdf → "Only PDF files are accepted (this one reads as image/png)"; storage requests ${toStorage.length - n0}; rows ${rows0}`)

        await go(pa, `/contracts/${contractId}`, '[data-upload-button="original"]')
        const pdf = makePdf('contract.pdf')
        const want = sha(readFileSync(pdf))
        await (await pa.$('[data-file-input="original"]')).uploadFile(pdf)
        await pa.click('[data-upload-button="original"]')
        await pa.waitForSelector('[data-file-kind="original"]', { timeout: 120_000 }).catch(() => {})
        const shownSha = await pa.evaluate(() => document.querySelector('[data-file-kind="original"] [data-file-sha256]')?.getAttribute('data-file-sha256') ?? null)
        const row = psql(`SELECT 'PROOF|' || id || '|' || status || '|' || sha256 || '|' || file_size FROM contract_files WHERE contract_id = '${contractId}' AND kind = 'original';`)[0]?.split('|')
        const got = row ? await getAs(admin, `/contracts/${contractId}/files/${row[0]}`) : null
        ok(!!row && row[1] === 'current' && row[2] === want && shownSha === want && got?.status === 200 && sha(got.bytes) === want
           && got.headers.get('x-content-sha256') === want && toStorage.length >= 1 && Number(row[3]) === readFileSync(pdf).length,
           // ★ run 1:请求头里读不到 content-length(无头 Chrome 对 Blob 体不露这一格,读成 0)—— 改成比库里那一行的 file_size(取自存储对象的 metadata)
           `A a real PDF uploaded through the form, bytes straight from the browser to storage (${toStorage.length} storage upload request(s), stored ${row?.[3]} bytes = local file ${readFileSync(pdf).length} bytes): row ${row?.[1]}, stored sha256 = page sha256 = local file sha256 = re-downloaded bytes' sha256 (${want.slice(0, 16)}…); download route HTTP ${got?.status}`)
        globalThis.__fileId = row?.[0]
        // 对方签回件在我方签过之前按名拒
        const cs = await rpcAs(admin.token, 'contract_file_begin', { p_contract_id: contractId, p_kind: 'countersigned', p_file_name: 'back.pdf', p_file_type: 'application/pdf', p_file_size: 100 })
        ok(cs.message === `CONTRACT_COUNTERSIGN_NEEDS_SIGNED|${code}`, `A a countersigned copy before our side signed → ${cs.message}`)
        await layout(pa, `/contracts/${contractId}`, `/contracts/${code} with a file (admin)`)
        await layout(pa, '/settings/signatories', '/settings/signatories with one signatory and a stamp')
    }
    { const why = abortReason('after the admin reader'); if (why) { console.log(`ABORT|${why}`); return finish(1) } }

    // ════════ S · 签署人 ════════
    { const why = abortReason('before the signatory'); if (why) { console.log(`ABORT|${why}`); return finish(1) } }
    {
        const ps = await pageAs(signer)
        const st = await go(ps, '/me', '[data-signature-save]')
        const pad = await ps.$('[data-signature-pad]')
        ok(st === 200 && !!pad, `S /me (HTTP ${st}) shows the signature pad to the signatory`)
        await layout(ps, '/me', '/me with the signature pad')
        await go(ps, '/me', '[data-signature-save]')
        const box = await (await ps.$('[data-signature-pad]')).boundingBox()
        await ps.mouse.move(box.x + 20, box.y + box.height * 0.7)
        await ps.mouse.down()
        for (let i = 1; i <= 30; i++) await ps.mouse.move(box.x + 20 + i * 8, box.y + box.height * (0.7 - 0.4 * Math.sin(i / 4)))
        await ps.mouse.up()
        await ps.click('[data-signature-save]')
        await ps.waitForSelector('[data-signature-current]', { timeout: 60_000 }).catch(() => {})
        const row = psql(`SELECT 'PROOF|' || file_path || '|' || sha256 || '|' || created_by FROM signature_specimens WHERE employee_id = '${signer.employeeId}' AND superseded_at IS NULL;`)[0]?.split('|')
        if (row) planDelete('/storage/v1/object/signing-assets', `删一次性签字样本对象 ${row[0]}`, O.OBJECT,
            { method: 'DELETE', body: JSON.stringify({ prefixes: [row[0]] }), headers: { 'Content-Type': 'application/json' } })
        ok(!!row && row[2] === signer.userId && !!(await ps.$('[data-signature-current]')), `S the signatory drew and saved their signature: ${row?.[0] ?? 'NO ROW'}, recorded by themselves`)

        const sc = await go(ps, `/contracts/${contractId}`)
        const blockedText = await ps.evaluate((c) => document.querySelector(`[data-sign-blocked="${c}"]`)?.textContent.trim() ?? null, code)
        ok(sc === 200 && !!blockedText && /Only an active contract/.test(blockedText), `S the contract page: Sign is visible, unpressable, and says "${blockedText}"`)
        const sp = await go(ps, `/contracts/${contractId}/sign`)
        const signBlocked = await ps.evaluate((c) => document.querySelector(`[data-sign-blocked="${c}"]`)?.textContent.trim() ?? null, code)
        ok(sp === 200 && !!signBlocked && /Only an active contract/.test(signBlocked), `S /contracts/${code}/sign (HTTP ${sp}) says "${signBlocked}" — no signing form on a draft (Q1)`)
        await layout(ps, `/contracts/${contractId}/sign`, `/contracts/${code}/sign (draft: the refusal state)`)
        // 刚凭密码签发的令牌:amr 里有 password;库在密码那一条之后才判生效 —— 所以回 NOT_ACTIVE 就证明库读到了它
        const fresh = await passwordToken(signer)
        const r = await rpcAs(fresh.token, 'contract_sign_begin', { p_file_id: globalThis.__fileId, p_with_stamp: true, p_signature_page: 2, p_signature_x: 0.75, p_signature_y: 0.88, p_stamp_page: 2, p_stamp_x: 0.5, p_stamp_y: 0.88 })
        await fresh.logout()
        const amrOk = Array.isArray(fresh.amr) && fresh.amr.some((a) => a.method === 'password' && typeof a.timestamp === 'number')
        ok(amrOk && r.message === `CONTRACT_SIGN_NOT_ACTIVE|${code}|draft`,
           `S contract_sign_begin with a token just issued for the password (amr ${JSON.stringify((fresh.amr ?? []).map((a) => a.method))}) on the draft → ${r.message} — the password check passed on a live token and the draft refused (Q1 · Q5)`)
        const old = await rpcAs(signer.token, 'contract_sign_begin', { p_file_id: globalThis.__fileId, p_with_stamp: false, p_signature_page: 2, p_signature_x: 0.75, p_signature_y: 0.88 })
        console.log(`STEP|the same call with the cookie session's token (signed in ${Math.round((Date.now() - stamp) / 1000)} s ago) → ${old.message} (refused either way on a draft)`)
        const signedRows = Number(psql(`SELECT 'PROOF|' || count(*) FROM contract_files WHERE contract_id = '${contractId}' AND kind = 'signed';`)[0])
        ok(signedRows === 0, `S no signed version exists after the refusals (${signedRows} rows)`)
    }
    { const why = abortReason('after the signatory'); if (why) { console.log(`ABORT|${why}`); return finish(1) } }

    // ════════ N · 不在名单上的读者 ════════
    { const why = abortReason('before the non-signatory'); if (why) { console.log(`ABORT|${why}`); return finish(1) } }
    {
        const fin = await mintThrowaway({ prefix: 'cesprobe', label: 'finance', stamp, codes: { cloneOf: 'finance' } })
        const r = await rpcAs(fin.token, 'contract_sign_begin', { p_file_id: globalThis.__fileId, p_with_stamp: false, p_signature_page: 1, p_signature_x: 0.5, p_signature_y: 0.5 })
        ok(r.message === 'CONTRACT_SIGN_NOT_SIGNATORY', `N a finance clone (not on the list) → ${r.message}`)
        const stampPath = psql(`SELECT 'PROOF|' || file_path FROM company_stamps WHERE created_by = '${admin.userId}';`)[0]
        const s = await fetch(`${SB_URL}/storage/v1/object/authenticated/signing-assets/${stampPath}`, { headers: { apikey: ANON, Authorization: `Bearer ${fin.token}` } })
        const sAsSigner = await fetch(`${SB_URL}/storage/v1/object/authenticated/signing-assets/${stampPath}`, { headers: { apikey: ANON, Authorization: `Bearer ${signer.token}` } })
        ok(s.status !== 200 && sAsSigner.status === 200, `N the company stamp object: finance clone HTTP ${s.status} (refused), signatory HTTP ${sAsSigner.status}`)
        const v = await rpcAs(fin.token, 'contract_signatory_add', { p_employee_id: signer.employeeId, p_title: 'x' })
        ok(v.message === 'PERMISSION_DENIED|action.manage_signatories', `N the finance clone cannot change the signatory list → ${v.message}`)
    }
    { const why = abortReason('after the non-signatory'); if (why) { console.log(`ABORT|${why}`); return finish(1) } }

    // ════════ R · 读码有、采购价码没有(Q8)════════
    { const why = abortReason('before the restricted reader'); if (why) { console.log(`ABORT|${why}`); return finish(1) } }
    {
        const ro = await mintThrowaway({ prefix: 'cesprobe', label: 'nopriceread', stamp, codes: ['module.suppliers.view'] })
        const pr = await pageAs(ro)
        const st = await go(pr, `/contracts/${contractId}`)
        const restricted = await pr.evaluate((c) => document.querySelector(`[data-contract-files-restricted="${c}"]`)?.textContent.trim() ?? null, code)
        const rows = await fetch(`${SB_URL}/rest/v1/contract_files?select=id&contract_id=eq.${contractId}`, { headers: { apikey: ANON, Authorization: `Bearer ${ro.token}` } }).then((x) => x.json())
        const objPath = toStorage.at(-1)?.path
        const obj = await fetch(`${SB_URL}/storage/v1/object/authenticated/contract-files/${objPath}`, { headers: { apikey: ANON, Authorization: `Bearer ${ro.token}` } })
        const dl = await getAs(ro, `/contracts/${contractId}/files/${globalThis.__fileId}`)
        ok(st === 200 && !!restricted && /data\.view_purchase_prices/.test(restricted) && Array.isArray(rows) && rows.length === 0 && obj.status !== 200 && dl.status === 404,
           `R a reader with module.suppliers.view only: contract page HTTP ${st} shows "${restricted}"; rows ${Array.isArray(rows) ? rows.length : JSON.stringify(rows).slice(0, 80)}; stored object HTTP ${obj.status}; download route HTTP ${dl.status}`)
    }
    { const why = abortReason('after the restricted reader'); if (why) { console.log(`ABORT|${why}`); return finish(1) } }

    console.log(bad ? `STEP|done with ${bad} FAIL` : 'STEP|done')
    return finish(bad ? 1 : 0)
}

main().catch((e) => {
    console.error(String(e?.stack || e))
    return finish(String(e?.message || '').startsWith('CES_DRIVER') ? 2 : 1)
})
