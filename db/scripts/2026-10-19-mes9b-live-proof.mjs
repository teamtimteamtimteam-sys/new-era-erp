#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// MES-9b(2026-10-19)· 线上验证 —— 供应商在门户里看得见什么,对着线上、以一次性账号(前缀 mes9bprobe)
// ════════════════════════════════════════════════════════════════════════════
// PROOF_BASE 上是一台【跑本刀代码、连线上】的 next(页面与取档路由是应用代码,只有 HTTP 看得见它们)。七个真账号一个都不用。
// ★ Tim 的裁定 4(2026-10-19):线上【不提交】任何一次性的签发档,也【不用】session_replication_role 或任何绕过触发器的办法;线上的证明一律在
//   回滚的事务里,HTTP 只证不需要已提交单据的那些。取档的 HTTP 一半(存下的 PDF、重算哈希、409、下载记录)在本地重建库上证 ——
//   db/scripts/2026-10-19-mes9b-local-download-proof.mjs。
//   【HTTP 腿】两家一次性供应商 A、B(mintThrowawaySupplier),各一个一次性门户账号(mintThrowaway { portalOf },经 GoTrue 的密码登录):
//     落在 /portal、只见自己那一家;员工路由一律拒;/portal/documents 与 /portal/deliveries 是"一份签发档都没有"的空状态;PostgREST 的两支清单只回
//     自己那一家的空表;对线上【真的、别家的】签发档(一张采购单 · 一张对账单 · 一张销毁证书的签发记录)portal_document_open 一律
//     PORTAL_DOCUMENT_NOT_FOUND、取档路由 404 —— 函数在写任何东西之前就拒,读回下载记录 0 行;Storage API 以门户令牌取一份真的证书 → 拒,
//     三个单据桶一样都列不出来;员工会话打开取档路由 403;三页在 390 / 1280 px 的整页溢出。
//   【事务腿,不提交,触发器全开】采购单(签发 · 草稿)、对账单(签发)、收货(带单价与备注)、销毁证书(签发 · 作废)、地磅单(自己的 · 两家共用的)
//     只活在一笔【最后必然 ROLLBACK】的事务里;门户函数以两个门户账号【真令牌里的声明】、在 supplier_portal 角色下调;线上那条门户存储策略
//     以同一身份判线上已有的对象(一个都看不见)。
//   另外:七个真角色的同码克隆打开 A 的供应商页 —— 门户那一块与下载记录那一块看不看得见(只读)。
// 判决只从日志里最后那一行 `MES9B_PROOF_EXIT=` 读:0 = 每一格 PASS 且收尾干净 · 1 = 有 FAIL · 2 = 驱动坏了 · 5 = live-lock 被占 · 6 = 收尾没完成。
// 残留由 docs/surveys/MES-9b/live-readings.sql 另外读回(以 postgres)。
// 用法:PROOF_BASE=http://localhost:3196 node db/scripts/2026-10-19-mes9b-live-proof.mjs > <log> 2>&1
// ════════════════════════════════════════════════════════════════════════════
import { onlyWhenRunDirectly } from '../../scripts/lib/entrypoint.mjs'
import { readFileSync, writeFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawnSync } from 'node:child_process'
import { randomUUID } from 'node:crypto'
import { acquireOrExit, release, heldBy } from '../../scripts/liveLock.mjs'
import { openPlan, mintThrowaway, mintThrowawaySupplier, reapStalePlans, installExitHooks, exitAfterCleanup } from '../../scripts/ephemeral.mjs'

onlyWhenRunDirectly(import.meta.url)

const ROOT = dirname(dirname(dirname(fileURLToPath(import.meta.url))))
const BASE = process.env.PROOF_BASE || 'http://localhost:3196'
const DSN = process.env.CHECK_MIRRORS_DSN || 'host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 user=postgres.wvywpohbwkiinmipmuku dbname=postgres'
const ROLE_CLONES = ['admin', 'cco', 'cfo', 'cto', 'finance', 'gm', 'warehouse']
const CHROME = join(process.env.HOME, '.cache/puppeteer/chrome-headless-shell/mac_arm-152.0.7977.54/chrome-headless-shell-mac-arm64/chrome-headless-shell')
let browser = null

let locked = false, bad = 0
const ok = (cond, what) => { console.log(`${cond ? 'PASS' : 'FAIL'}|${what}`); if (!cond) bad++; return cond }

function psql(sql, label) {
    const r = spawnSync('psql', [DSN, '-X', '-At', '-v', 'ON_ERROR_STOP=1'], { input: sql, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 })
    return { code: r.status, out: (r.stdout || ''), err: (r.stderr || ''), label }
}
const lit = (s) => `'${String(s).replace(/'/g, "''")}'`

async function finish(code) {
    try { if (browser) { await browser.close(); browser = null } } catch { /* 浏览器已经没了 */ }
    return exitAfterCleanup(code || (bad ? 1 : 0))
}
installExitHooks({
    beforeFinish: async () => {
        try { if (browser) await browser.close() } catch { /* 浏览器已经没了 */ }
    },
    onFinish: (code) => {
        try { if (locked) release() } catch { /* 放锁失败不改判决 */ }
        console.log('AFTER|nothing but the throwaway suppliers, contacts, links and accounts was committed (removed by the plan); residue is read separately, as postgres, by docs/surveys/MES-9b/live-readings.sql')
        console.log(`MES9B_PROOF_EXIT=${code}`)
    },
})

function env() {
    const txt = readFileSync(join(ROOT, '.env.local'), 'utf8')
    const get = (k) => (txt.match(new RegExp('^' + k + '=(.*)$', 'm'))?.[1] ?? '').trim().replace(/^"|"$/g, '')
    return { URL_: get('NEXT_PUBLIC_SUPABASE_URL'), ANON: get('NEXT_PUBLIC_SUPABASE_ANON_KEY'), SERVICE: get('SUPABASE_SERVICE_ROLE_KEY') }
}
let E
const asUser = async (token, path, init = {}) => {
    const r = await fetch(E.URL_ + path, { ...init, headers: { apikey: E.ANON, Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', ...(init.headers || {}) } })
    const t = await r.text(); let b = null; try { b = JSON.parse(t) } catch { b = t }
    return { status: r.status, body: b }
}
const claimsOf = (jwt) => JSON.parse(Buffer.from(jwt.split('.')[1], 'base64url').toString())
async function getWith(cookie, path) {
    const r = await fetch(BASE + path, { headers: { cookie: `${cookie}; NEXT_LOCALE=en` }, redirect: 'manual' })
    const buf = Buffer.from(await r.arrayBuffer())
    return { status: r.status, type: r.headers.get('content-type') || '', buf, body: buf.toString('utf8') }
}
async function main() {
    const other = heldBy()
    if (other) { console.error(`✗ live-lock 被【${other.holder}】(pid ${other.pid})占着`); return exitAfterCleanup(5) }
    acquireOrExit('db/scripts/2026-10-19-mes9b-live-proof.mjs', { ownExit: false })
    locked = true
    openPlan('db/scripts/2026-10-19-mes9b-live-proof.mjs')
    await reapStalePlans()
    E = env()
    try { const r = await fetch(BASE + '/login', { redirect: 'manual' }); if (r.status !== 200) throw new Error(`HTTP ${r.status}`) }
    catch (e) { throw new Error(`MES9B_DRIVER|no next server at ${BASE}: ${e.message}`) }

    const stamp = Date.now()
    const A = await mintThrowawaySupplier({ prefix: 'mes9bprobe', label: 'lp-a' })
    const B = await mintThrowawaySupplier({ prefix: 'mes9bprobe', label: 'lp-b' })
    const pA = await mintThrowaway({ prefix: 'mes9bprobe', label: 'lp-pa', stamp, codes: { portalOf: A.supplierId } })
    const pB = await mintThrowaway({ prefix: 'mes9bprobe', label: 'lp-pb', stamp, codes: { portalOf: B.supplierId } })
    const users = { A: { S: A, P: pA }, B: { S: B, P: pB } }
    ok(claimsOf(pA.token).role === 'supplier_portal' && claimsOf(pB.token).role === 'supplier_portal',
       `sign-in: both throwaway portal accounts signed in over HTTP (password grant) and hold a supplier_portal token (A ${A.code} · B ${B.code})`)
    const logCount = () => Number(psql(`SELECT count(*) FROM portal_document_downloads WHERE portal_user_id IN (${lit(pA.linkId)}, ${lit(pB.linkId)});`).out.trim())

    // ── HTTP leg: nothing committed but the throwaway suppliers, contacts, links and accounts ──
    // the live, real issued documents of other suppliers (one per kind that exists on live — supplier_statement_issues is empty today)
    const real = psql(`SELECT 'purchase_order|' || id FROM (SELECT id FROM po_issues ORDER BY issued_at LIMIT 1) x
                        UNION ALL SELECT 'supplier_statement|' || id FROM (SELECT id FROM supplier_statement_issues ORDER BY issued_at LIMIT 1) y
                        UNION ALL SELECT 'cod|' || id FROM (SELECT id FROM cod_issues ORDER BY issued_at LIMIT 1) z;`).out.trim().split('\n').filter(Boolean)
    const realPath = psql(`SELECT file_path FROM cod_issues ORDER BY issued_at LIMIT 1;`).out.trim()
    for (const k of ['A', 'B']) {
        const u = users[k], o = k === 'A' ? users.B : users.A
        const ck = u.P.cookie
        const home = await getWith(ck, '/portal')
        ok(home.status === 200 && home.body.includes(`data-portal-supplier="${u.S.code}"`) && home.body.includes('href="/portal/documents"')
           && home.body.includes('href="/portal/deliveries"') && !home.body.includes(o.S.code),
           `HTTP ${k}: /portal → ${home.status}, its own supplier ${u.S.code}, links to its documents and deliveries, nothing of the other`)
        for (const path of ['/', '/suppliers', '/finance/journal', '/inventory', '/purchasing/orders', `/suppliers/${u.S.supplierId}/edit`]) {
            const g = await getWith(ck, path)
            ok(g.status === 200 && g.body.includes('data-access-denied') && g.body.includes('href="/portal"'), `HTTP ${k}: staff route ${path} → ${g.status}, refused with the way back to /portal`)
        }
        const docs = await getWith(ck, '/portal/documents')
        ok(docs.status === 200 && docs.body.includes(`data-portal-documents="${u.S.code}"`) && (docs.body.match(/>None\.</g) || []).length === 3 && !docs.body.includes('data-doc-file'),
           `HTTP ${k}: /portal/documents → ${docs.status}, the empty state for a supplier with no issued document (three "None.", no download link)`)
        const del = await getWith(ck, '/portal/deliveries')
        ok(del.status === 200 && del.body.includes(`data-portal-deliveries="${u.S.code}"`) && del.body.includes('data-as-of') && (del.body.match(/>None\.</g) || []).length === 2,
           `HTTP ${k}: /portal/deliveries → ${del.status}, "as recorded at …", the empty state (no receipt, no ticket)`)
        const rd = await asUser(u.P.token, '/rest/v1/rpc/portal_documents', { method: 'POST', body: '{}' })
        const rv = await asUser(u.P.token, '/rest/v1/rpc/portal_deliveries', { method: 'POST', body: '{}' })
        ok(rd.status === 200 && rd.body?.supplier_code === u.S.code && rd.body.purchase_orders.length === 0 && rd.body.statements.length === 0 && rd.body.cods.length === 0
           && rv.status === 200 && rv.body?.supplier_code === u.S.code && rv.body.receipts.length === 0 && rv.body.tickets.length === 0,
           `HTTP ${k}: PostgREST portal_documents / portal_deliveries → ${rd.status} / ${rv.status}, its own supplier, empty lists`)
        // another supplier's rows: the live, real issued documents (read-only — the function refuses before it writes anything)
        for (const ref of real) {
            const [kind, id] = ref.split('|')
            const q = await asUser(u.P.token, '/rest/v1/rpc/portal_document_open', { method: 'POST', body: JSON.stringify({ p_kind: kind, p_issue_id: id }) })
            ok(q.status !== 200 && JSON.stringify(q.body).includes('PORTAL_DOCUMENT_NOT_FOUND'), `HTTP ${k}: portal_document_open on a real ${kind} issued to another supplier → ${q.status} PORTAL_DOCUMENT_NOT_FOUND`)
            const f = await getWith(ck, `/portal/documents/file?kind=${kind}&id=${id}`)
            ok(f.status === 404, `HTTP ${k}: /portal/documents/file for that ${kind} → ${f.status}`)
        }
        const sd = await fetch(`${E.URL_}/storage/v1/object/authenticated/cod-documents/${realPath}`, { headers: { apikey: E.ANON, Authorization: `Bearer ${u.P.token}` } })
        ok(!sd.ok, `HTTP ${k}: the Storage API with the portal token, a real issued certificate's object → ${sd.status} (refused)`)
        let listed = []
        for (const b of ['po-documents', 'cod-documents', 'supplier-statement-documents']) {
            const l = await fetch(`${E.URL_}/storage/v1/object/list/${b}`, { method: 'POST', headers: { apikey: E.ANON, Authorization: `Bearer ${u.P.token}`, 'Content-Type': 'application/json' },
                body: JSON.stringify({ prefix: '', limit: 100 }) })
            const j = await l.json().catch(() => null)
            if (l.ok && Array.isArray(j) && j.length > 0) listed.push(`${b}:${j.length}`)
        }
        ok(listed.length === 0, `HTTP ${k}: the Storage API with the portal token lists nothing in the three document buckets${listed.length ? ' — LISTED ' + listed.join(', ') : ''}`)
    }
    ok(logCount() === 0, `HTTP: the refusals wrote no download-log row (read back as postgres: ${logCount()})`)

    // ── a staff session on the download route and the documents page ──
    const staff = await mintThrowaway({ prefix: 'mes9bprobe', label: 'lp-staff', stamp, codes: { cloneOf: 'cco' } })
    const realCod = real.find((x) => x.startsWith('cod|'))
    const s1 = await getWith(staff.cookie, `/portal/documents/file?kind=cod&id=${realCod.split('|')[1]}`)
    ok(s1.status === 403, `staff: a cco copy on /portal/documents/file → ${s1.status}`)
    const s2 = await getWith(staff.cookie, '/portal/documents')
    ok(s2.status === 200 && s2.body.includes('data-access-denied') && !s2.body.includes('data-portal-documents'), `staff: a cco copy on /portal/documents → refused`)

    // ── layout: the three portal pages as a portal user, 390 and 1280 px ──
    const pc = process.env.PUPPETEER_CORE
    if (!pc) throw new Error('MES9B_DRIVER|PUPPETEER_CORE is not set')
    const puppeteer = (await import(pc)).default
    browser = await puppeteer.launch({ executablePath: CHROME, headless: true, args: ['--no-sandbox'] })
    for (const path of ['/portal', '/portal/documents', '/portal/deliveries']) {
        for (const w of [390, 1280]) {
            const ctx = await browser.createBrowserContext()
            const page = await ctx.newPage()
            try {
                await page.setViewport({ width: w, height: 900 })
                await page.setCookie({ name: pA.cookieName, value: pA.cookieValue, url: BASE }, { name: 'NEXT_LOCALE', value: 'en', url: BASE })
                await page.goto(BASE + path, { waitUntil: 'networkidle0' })
                const o = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth)
                ok(o <= 1, `layout: ${path} as a portal user at ${w} px — page overflow ${o} px`)
            } finally { await ctx.close() }
        }
    }

    // ── transaction leg (one rolled-back transaction, every trigger on): orders, statements, receipts, certificates, tickets ──
    for (const k of ['A', 'B']) {
        const u = users[k]
        u.st = { id: randomUUID(), code: `ZZ-PROBE-MES9B-${k}-ST1-${stamp}`, issue: randomUUID(), sha: 'a'.repeat(64) }
        u.st.path = `${u.st.id}/${u.st.sha}.pdf`
        u.po = { id: randomUUID(), code: `ZZ-PROBE-MES9B-${k}-PO1-${stamp}`, draft: randomUUID(), issue: randomUUID(), sha: 'b'.repeat(64) }
        u.po.path = `${u.po.id}/v1.pdf`
        u.cod = { id: randomUUID(), code: `ZZ-PROBE-MES9B-${k}-COD1-${stamp}`, issue: randomUUID(), void: randomUUID(), voidCode: `ZZ-PROBE-MES9B-${k}-COD0-${stamp}`,
                  voidIssue: randomUUID(), sha: 'c'.repeat(64) }
        u.cod.path = `${u.cod.id}/c.pdf`
        u.b1 = { id: randomUUID(), code: `ZZ-PROBE-MES9B-${k}-B1-${stamp}` }; u.b2 = { id: randomUUID(), code: `ZZ-PROBE-MES9B-${k}-B2-${stamp}` }
        u.wb = { id: randomUUID(), code: `ZZ-PROBE-MES9B-${k}-WB1-${stamp}` }
    }
    const base = psql(`SELECT code FROM currencies WHERE is_base;`).out.trim()
    const tx = txSql(users, base)
    writeFileSync(join(ROOT, '.ephemeral', `mes9b-tx-${process.pid}.sql`), tx)
    const tr = psql(tx, 'transaction leg')
    for (const l of (tr.out + '\n' + tr.err).split('\n')) {
        const m = l.match(/(PASS\|.*|FAIL\|.*)$/)
        if (m) { console.log(`${m[1].startsWith('PASS') ? 'PASS' : 'FAIL'}|tx ${m[1].replace(/^(PASS|FAIL)\|/, '')}`); if (m[1].startsWith('FAIL')) bad++ }
    }
    ok(tr.code === 0 && /TX_DONE/.test(tr.out + tr.err), `tx: the rolled-back transaction ran to its end (psql exit ${tr.code}${tr.code ? ': ' + (tr.err.split('\n').find((x) => x.includes('ERROR')) || '').slice(0, 300) : ''})`)
    const resid = psql(`SELECT (SELECT count(*) FROM purchase_orders WHERE code LIKE 'ZZ-PROBE-MES9B-%') + (SELECT count(*) FROM inbound_batches WHERE code LIKE 'ZZ-PROBE-MES9B-%')
      + (SELECT count(*) FROM weighbridge_tickets WHERE code LIKE 'ZZ-PROBE-MES9B-%') + (SELECT count(*) FROM certificates_of_destruction WHERE code LIKE 'ZZ-PROBE-MES9B-%')
      + (SELECT count(*) FROM supplier_statements WHERE code LIKE 'ZZ-PROBE-MES9B-%') + (SELECT count(*) FROM portal_document_downloads WHERE portal_user_id IN (${lit(pA.linkId)}, ${lit(pB.linkId)}));`).out.trim()
    ok(resid === '0', `tx: after the ROLLBACK, 0 orders / receipts / tickets / certificates / statements / download-log rows of this run remain (read ${resid})`)

    // ── the seven roles' permissions on A's supplier page: the portal section and the download log (read-only) ──
    console.log('ROLES|role|codes|supplier page|portal accounts section|download log section|download rows shown|PostgREST portal_document_downloads (A)')
    for (const r of ROLE_CLONES) {
        const c = await mintThrowaway({ prefix: 'mes9bprobe', label: `rt-${r}`, stamp, codes: { cloneOf: r } })
        const sp = await getWith(c.cookie, `/suppliers/${A.supplierId}/edit`)
        const section = sp.body.includes('data-section="supplier-portal-accounts"')
        const dlSection = sp.body.includes('data-section="supplier-portal-downloads"')
        const empty = sp.body.includes('data-empty="portal-downloads"')
        const rest = await asUser(c.token, `/rest/v1/portal_document_downloads?supplier_id=eq.${A.supplierId}&select=id`)
        const n = Array.isArray(rest.body) ? `HTTP ${rest.status}, ${rest.body.length} rows` : `HTTP ${rest.status}`
        console.log(`ROLES|${r}|${c.codes.length}|${sp.status}${sp.body.includes('data-access-denied') ? ' refused' : ''}|${section ? 'sees' : 'no'}|${dlSection ? 'sees' : 'no'}|${empty ? '"No downloads yet."' : (sp.body.match(/data-portal-download="/g) || []).length}|${n}`)
    }
    console.log(bad ? `STEP|done with ${bad} FAIL` : 'STEP|done')
    return finish(bad ? 1 : 0)
}

// The rolled-back transaction: seed with replica (no stock movement, no change-log row), assert with origin, ROLLBACK.
function txSql(users, base) {
    const seed = ['A', 'B'].map((k) => { const u = users[k]; return `
UPDATE suppliers SET status = 'pending_review' WHERE id = ${lit(u.S.supplierId)};
UPDATE suppliers SET status = 'approved' WHERE id = ${lit(u.S.supplierId)};
INSERT INTO supplier_statements (id, code, supplier_id, supplier_code, supplier_name, company, period_start, period_end, base_currency,
    opening_base, charges_base, credits_base, payments_base, prepayments_base, closing_base, list_base, on_account_base, residue_base,
    lines, open_items, on_account, unpriced, by_currency)
VALUES (${lit(u.st.id)}, ${lit(u.st.code)}, ${lit(u.S.supplierId)}, ${lit(u.S.code)}, ${lit(u.S.legalName)}, '{"legal_name":"MES-9b live proof"}',
    current_date - 30, current_date - 1, ${lit(base)}, 4242.42, 0, 0, 0, 0, 4242.42, 4242.42, 0, 0, '[]', '[]', '[]', '[]', '[]');
INSERT INTO supplier_statement_issues (id, statement_id, version, file_path, sha256) VALUES (${lit(u.st.issue)}, ${lit(u.st.id)}, 1, ${lit(u.st.path)}, ${lit(u.st.sha)});
INSERT INTO purchase_orders (id, code, supplier_id, order_date, currency, fx_rate, status, approval_status, category, estimated_total_ccy)
VALUES (${lit(u.po.id)}, ${lit(u.po.code)}, ${lit(u.S.supplierId)}, current_date, ${lit(base)}, 1, 'confirmed', 'approved', 'equipment_goods', 987654.32),
       (${lit(u.po.draft)}, ${lit(u.po.code + '-DRAFT')}, ${lit(u.S.supplierId)}, current_date, ${lit(base)}, 1, 'draft', 'approved', 'equipment_goods', 987654.32);
INSERT INTO po_issues (id, purchase_order_id, version, file_path, sha256) VALUES (${lit(u.po.issue)}, ${lit(u.po.id)}, 1, ${lit(u.po.path)}, ${lit(u.po.sha)});
INSERT INTO inbound_batches (id, code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note, unit_price, notes)
VALUES (${lit(u.b1.id)}, ${lit(u.b1.code)}, (SELECT id FROM tx9b_mat), ${lit(u.S.supplierId)}, 777, 777, 'kg', current_date, 'other', 'MES-9b live proof', 999.99, 'ZZ9B-INTERNAL-NOTE'),
       (${lit(u.b2.id)}, ${lit(u.b2.code)}, (SELECT id FROM tx9b_mat), ${lit(u.S.supplierId)}, 55, 55, 'kg', current_date, 'other', 'MES-9b live proof', 999.99, 'ZZ9B-INTERNAL-NOTE');
INSERT INTO certificates_of_destruction (id, inbound_batch_id, completed_on, status, code, verification_token, snapshot, issued_at)
VALUES (${lit(u.cod.id)}, ${lit(u.b1.id)}, current_date, 'issued', ${lit(u.cod.code)}, gen_random_uuid(), '{}', now());
INSERT INTO certificates_of_destruction (id, inbound_batch_id, completed_on, status, code, verification_token, snapshot, issued_at, void_reason, voided_at, replaced_by_cod_id)
VALUES (${lit(u.cod.void)}, ${lit(u.b2.id)}, current_date, 'void', ${lit(u.cod.voidCode)}, gen_random_uuid(), '{}', now(), 'MES-9b live proof', now(), ${lit(u.cod.id)});
INSERT INTO cod_issues (id, cod_id, file_path, sha256) VALUES (${lit(u.cod.issue)}, ${lit(u.cod.id)}, ${lit(u.cod.path)}, ${lit(u.cod.sha)}),
       (${lit(u.cod.voidIssue)}, ${lit(u.cod.void)}, ${lit(u.cod.void + '/void.pdf')}, ${lit('0'.repeat(64))});
INSERT INTO weighbridge_tickets (id, code, direction, vehicle_reg, notes, completed_at) VALUES (${lit(u.wb.id)}, ${lit(u.wb.code)}, 'inbound', 'ZZ9B-VAN', 'ZZ9B-TICKET-NOTE', now());
INSERT INTO weighbridge_ticket_shares (ticket_id, inbound_batch_id, kg) VALUES (${lit(u.wb.id)}, ${lit(u.b1.id)}, 701);` }).join('\n')
    const A = users.A, B = users.B
    return `BEGIN;
SET LOCAL statement_timeout = '120s';
CREATE FUNCTION pg_temp.p9_call(p_claims text, p_role text, p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE v text;
BEGIN
    PERFORM set_config('request.jwt.claims', p_claims, true);
    EXECUTE format('SET LOCAL ROLE %I', p_role);
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);
    RETURN COALESCE(v, '<null>');
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);
    RETURN 'ERR|' || SQLSTATE || '|' || SQLERRM;
END;
$f$;
CREATE TEMP TABLE tx9b_mat AS SELECT gen_random_uuid() AS id;
INSERT INTO materials (id, code, name, kind_code, may_be_processed, form_code, source_code)
SELECT id, 'ZZ-PROBE-MES9B-M-${Date.now()}', 'ZZ-PROBE mes9b black mass', 'battery_material', true, 'black_mass', 'end_of_life' FROM tx9b_mat;
${seed}
INSERT INTO weighbridge_tickets (id, code, direction, vehicle_reg, completed_at) VALUES (gen_random_uuid(), 'ZZ-PROBE-MES9B-WBS-${Date.now()}', 'inbound', 'ZZ9B-VAN', now());
INSERT INTO weighbridge_ticket_shares (ticket_id, inbound_batch_id, kg)
SELECT t.id, b.id, CASE WHEN b.id = ${lit(A.b1.id)} THEN 311 ELSE 422 END FROM weighbridge_tickets t, inbound_batches b
 WHERE t.code LIKE 'ZZ-PROBE-MES9B-WBS-%' AND b.id IN (${lit(A.b1.id)}, ${lit(B.b1.id)});
DO $tx$
DECLARE v text; j jsonb; k text; me jsonb; them jsonb; n int;
BEGIN
    FOR k IN SELECT unnest(ARRAY['A', 'B']) LOOP
        me := CASE k WHEN 'A' THEN ${lit(JSON.stringify(slim(A, 311)))}::jsonb ELSE ${lit(JSON.stringify(slim(B, 422)))}::jsonb END;
        them := CASE k WHEN 'A' THEN ${lit(JSON.stringify(slim(B, 422)))}::jsonb ELSE ${lit(JSON.stringify(slim(A, 311)))}::jsonb END;
        -- documents: its order (issued), statement (committed) and certificates; not the draft; nothing of the other; no amount
        v := pg_temp.p9_call(me ->> 'claims', 'supplier_portal', 'SELECT public.portal_documents()::text');
        IF v LIKE 'ERR|%' OR v NOT LIKE '%' || (me ->> 'po') || '"%' OR v LIKE '%' || (me ->> 'po') || '-DRAFT%' OR v NOT LIKE '%' || (me ->> 'st') || '%'
           OR v NOT LIKE '%' || (me ->> 'cod') || '%' OR v NOT LIKE '%' || (me ->> 'cod_void') || '%'
           OR v LIKE '%' || (them ->> 'po') || '%' OR v LIKE '%' || (them ->> 'st') || '%' OR v LIKE '%' || (them ->> 'cod') || '%'
           OR v ~ '(987654\\.32|4242\\.42|999\\.99|ZZ9B-INTERNAL)' THEN
            RAISE NOTICE 'FAIL|% portal_documents → %', k, left(v, 400);
        ELSE RAISE NOTICE 'PASS|% portal_documents: its issued order (not its draft), its statement, its issued and void certificates; nothing of the other; no amount', k; END IF;
        j := v::jsonb;
        IF (SELECT x -> 'issue' FROM jsonb_array_elements(j -> 'cods') x WHERE x ->> 'code' = me ->> 'cod_void') <> 'null'::jsonb THEN
            RAISE NOTICE 'FAIL|% the void certificate offers a document', k;
        ELSE RAISE NOTICE 'PASS|% the void certificate is listed as void, with no document', k; END IF;
        -- deliveries: its receipts and tickets; only its share of the shared ticket; no price, plate or note
        v := pg_temp.p9_call(me ->> 'claims', 'supplier_portal', 'SELECT public.portal_deliveries()::text');
        IF v LIKE 'ERR|%' OR v NOT LIKE '%' || (me ->> 'b1') || '%' OR v NOT LIKE '%' || (me ->> 'wb') || '%' OR v LIKE '%' || (them ->> 'b1') || '%'
           OR v ~ '(999\\.99|unit_price|ZZ9B-VAN|ZZ9B-INTERNAL|ZZ9B-TICKET)' OR v NOT LIKE '%"kg": ' || (me ->> 'share') || '%' OR v LIKE '%"kg": ' || (them ->> 'share') || '%' THEN
            RAISE NOTICE 'FAIL|% portal_deliveries → %', k, left(v, 400);
        ELSE RAISE NOTICE 'PASS|% portal_deliveries: its receipts and tickets as recorded, only its share (% kg) of the shared ticket; no price, plate or note', k, me ->> 'share'; END IF;
        -- open: its order and certificate (a log row each); the other's order → NOT_FOUND; its void certificate → VOID
        v := pg_temp.p9_call(me ->> 'claims', 'supplier_portal', format('SELECT public.portal_document_open(''purchase_order'', %L)::text', me ->> 'po_issue'));
        IF v LIKE 'ERR|%' OR (v::jsonb ->> 'sha256') <> me ->> 'po_sha' OR (v::jsonb ->> 'file_path') <> me ->> 'po_path' THEN RAISE NOTICE 'FAIL|% open its order → %', k, v;
        ELSE RAISE NOTICE 'PASS|% open its order: path and recorded sha256 handed over, log row %', k, v::jsonb ->> 'log_id'; END IF;
        v := pg_temp.p9_call(me ->> 'claims', 'supplier_portal', format('SELECT public.portal_document_open(''cod'', %L)::text', me ->> 'cod_issue'));
        IF v LIKE 'ERR|%' OR (v::jsonb ->> 'sha256') <> me ->> 'cod_sha' THEN RAISE NOTICE 'FAIL|% open its certificate → %', k, v;
        ELSE RAISE NOTICE 'PASS|% open its certificate', k; END IF;
        v := pg_temp.p9_call(me ->> 'claims', 'supplier_portal', format('SELECT public.portal_document_open(''purchase_order'', %L)::text', them ->> 'po_issue'));
        IF v NOT LIKE 'ERR|%PORTAL_DOCUMENT_NOT_FOUND%' THEN RAISE NOTICE 'FAIL|% open the other''s order → %', k, v;
        ELSE RAISE NOTICE 'PASS|% open the other''s order → PORTAL_DOCUMENT_NOT_FOUND', k; END IF;
        v := pg_temp.p9_call(me ->> 'claims', 'supplier_portal', format('SELECT public.portal_document_open(''cod'', %L)::text', them ->> 'cod_issue'));
        IF v NOT LIKE 'ERR|%PORTAL_DOCUMENT_NOT_FOUND%' THEN RAISE NOTICE 'FAIL|% open the other''s certificate → %', k, v;
        ELSE RAISE NOTICE 'PASS|% open the other''s certificate → PORTAL_DOCUMENT_NOT_FOUND', k; END IF;
        v := pg_temp.p9_call(me ->> 'claims', 'supplier_portal', format('SELECT public.portal_document_open(''cod'', %L)::text', me ->> 'void_issue'));
        IF v NOT LIKE 'ERR|%PORTAL_DOCUMENT_VOID%' THEN RAISE NOTICE 'FAIL|% open its void certificate → %', k, v;
        ELSE RAISE NOTICE 'PASS|% open its void certificate → PORTAL_DOCUMENT_VOID', k; END IF;
        -- the live storage policy on the live objects table, as this portal session: none of the objects already on live is visible —
        --   not even after it has just logged its own order and certificate (those have no object on live: nothing was uploaded)
        v := pg_temp.p9_call(me ->> 'claims', 'supplier_portal',
            'SELECT count(*)::text FROM storage.objects WHERE bucket_id IN (''po-documents'', ''cod-documents'', ''supplier-statement-documents'')');
        IF v IS DISTINCT FROM '0' THEN RAISE NOTICE 'FAIL|% storage.objects through the live portal policy → %', k, v;
        ELSE RAISE NOTICE 'PASS|% storage.objects through the live portal policy: 0 of the document objects on live are visible to it', k; END IF;
        v := pg_temp.p9_call(me ->> 'claims', 'supplier_portal', 'SELECT count(*)::text FROM public.portal_document_downloads');
        IF v NOT LIKE 'ERR|42501%' THEN RAISE NOTICE 'FAIL|% reads the download log table directly → %', k, v;
        ELSE RAISE NOTICE 'PASS|% cannot read the download log table directly (42501)', k; END IF;
        -- nothing else written by the portal session: only its own log rows
        IF EXISTS (SELECT 1 FROM change_log WHERE txid = txid_current() AND db_role = 'supplier_portal') THEN
            RAISE NOTICE 'FAIL|% a change-logged row was written by the portal session', k;
        ELSE RAISE NOTICE 'PASS|% the portal session wrote nothing change-logged (its only writes are its own download-log rows)', k; END IF;
    END LOOP;
    -- staff: a reader of the supplier page sees the download log rows written in this transaction
    SELECT count(*) INTO n FROM portal_document_downloads WHERE portal_user_id = ${lit(A.P.linkId)} AND issue_id IN (${lit(A.po.issue)}, ${lit(A.cod.issue)});
    IF n <> 2 THEN RAISE NOTICE 'FAIL|A''s two transaction-leg log rows: %', n;
    ELSE RAISE NOTICE 'PASS|A''s order and certificate downloads each wrote one log row (kind, code, version, path, sha256)'; END IF;
    RAISE NOTICE 'TX_DONE';
END
$tx$;
ROLLBACK;
`
}
function slim(u, share) {
    return { claims: JSON.stringify(claimsOf(u.P.token)), po: u.po.code, st: u.st.code, cod: u.cod.code, cod_void: u.cod.voidCode, b1: u.b1.code, wb: u.wb.code,
             share, po_issue: u.po.issue, po_sha: u.po.sha, po_path: u.po.path, cod_issue: u.cod.issue,
             cod_sha: u.cod.sha, cod_path: u.cod.path, void_issue: u.cod.voidIssue }
}

main().catch((e) => {
    console.error(String(e?.stack || e))
    return finish(String(e?.message || '').startsWith('MES9B_DRIVER') ? 2 : 1)
})
