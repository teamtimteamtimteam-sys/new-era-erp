#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// MES-9c(2026-10-20)· 线上验证 —— 门户交证书与员工审核,连同变更记录页(F19),对着线上、以一次性账号(前缀 mes9cprobe)
// ════════════════════════════════════════════════════════════════════════════
// PROOF_BASE 上是一台【跑本刀代码、连线上】的 next(页面与上传路由是应用代码,只有 HTTP 看得见它们)。七个真账号一个都不用。
// ★ 委托书:线上【不提交】任何一份申请或单据 —— 会提交的证明一律在回滚的事务里;上传路由收下一份合格文件的那一半在本地重建库上证
//   (db/scripts/2026-10-20-mes9c-local-upload-proof.mjs)。存储的写不随回滚撤销:本脚本在线上【不经 Storage API 写任何字节】
//   (被拒的那一次本来就写不进去),事务腿里对 storage.objects 的插入是 SQL 行、随 ROLLBACK 消失;收尾读回每个桶的对象数。
//   【HTTP 腿】两家一次性供应商 A、B(mintThrowawaySupplier),各一个一次性门户账号(mintThrowaway { portalOf }):
//     /portal 有证书那一条;/portal/certificates 是空状态(在册 0、交过 0)、写着 10 MB · PDF · JPEG · PNG,别家的一个字都没有;PostgREST
//     portal_certificates 只回自己那一家、V39 = 10,485,760 · PDF / JPEG / PNG;上传路由:超大的(Content-Length)与类型不对的(GIF)各回
//     ?error=<码>、申请表 0 行、portal-uploads 0 个对象 —— 一个字节都没存;Storage API 以门户令牌往 portal-uploads 传 → 拒;员工会话 POST
//     上传路由 403、打开 /portal/certificates 被拒;/portal/certificates 在 390 / 1280 px 的整页溢出。
//   【F19】cfo 与 admin 的同码克隆打开 /settings/change-history:200 与耗时;库那一层以 admin 的身份把页面那一读(21 次操作)分页量一遍。
//   【事务腿,不提交,触发器全开】以两个门户账号【真令牌里的声明】在 supplier_portal 角色下:A 交一份(V39 过、字节行插进 storage.objects ——
//     线上的门户策略判、storage.can_insert_object 判)、交完;B 动不了 A 的;cco 克隆(module.suppliers.edit)把文件抄进 supplier-attachments、
//     接受 → 一行证书 + 一行附件;A 再交一份,cco 克隆带理由驳回;A 在门户上看得见 accepted 与理由,B 一样都看不见;gm 克隆(只读)审不动;
//     V39 的超大与 GIF 在 begin 处按名拒。ROLLBACK 之后读回 0 行。
//   另外:七个真角色的同码克隆打开 A 的供应商页 —— 审核那一块看不看得见、审得动审不动,与 /settings/change-history(只读)。
// 判决只从日志里最后那一行 `MES9C_PROOF_EXIT=` 读:0 = 每一格 PASS 且收尾干净 · 1 = 有 FAIL · 2 = 驱动坏了 · 5 = live-lock 被占 · 6 = 收尾没完成。
// 残留由 docs/surveys/MES-9c/live-readings.sql 另外读回(以 postgres)。
// 用法:PROOF_BASE=http://localhost:3196 PUPPETEER_CORE=<path> node db/scripts/2026-10-20-mes9c-live-proof.mjs > <log> 2>&1
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
        console.log('AFTER|nothing but the throwaway suppliers, contacts, links and accounts was committed (removed by the plan); residue is read separately, as postgres, by docs/surveys/MES-9c/live-readings.sql')
        console.log(`MES9C_PROOF_EXIT=${code}`)
    },
})

function env() {
    const txt = readFileSync(join(ROOT, '.env.local'), 'utf8')
    const get = (k) => (txt.match(new RegExp('^' + k + '=(.*)$', 'm'))?.[1] ?? '').trim().replace(/^"|"$/g, '')
    return { URL_: get('NEXT_PUBLIC_SUPABASE_URL'), ANON: get('NEXT_PUBLIC_SUPABASE_ANON_KEY') }
}
let E
const asUser = async (token, path, init = {}) => {
    const r = await fetch(E.URL_ + path, { ...init, headers: { apikey: E.ANON, Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', ...(init.headers || {}) } })
    const t = await r.text(); let b = null; try { b = JSON.parse(t) } catch { b = t }
    return { status: r.status, body: b }
}
const claimsOf = (jwt) => JSON.parse(Buffer.from(jwt.split('.')[1], 'base64url').toString())
async function getWith(cookie, path) {
    const t0 = Date.now()
    const r = await fetch(BASE + path, { headers: { cookie: `${cookie}; NEXT_LOCALE=en` }, redirect: 'manual' })
    const buf = Buffer.from(await r.arrayBuffer())
    return { status: r.status, type: r.headers.get('content-type') || '', location: r.headers.get('location') || '', ms: Date.now() - t0, body: buf.toString('utf8') }
}
async function postUpload(cookie, { certType, fileName, type, bytes, headers = {} }) {
    const fd = new FormData()
    fd.set('cert_type', certType)
    fd.set('cert_no', 'ZZ-PROBE-MES9C-HTTP')
    fd.set('file', new Blob([bytes], { type }), fileName)
    const r = await fetch(BASE + '/portal/certificates/upload', { method: 'POST', body: fd, headers: { cookie: `${cookie}; NEXT_LOCALE=en`, ...headers }, redirect: 'manual' })
    return { status: r.status, location: r.headers.get('location') || '', body: await r.text() }
}
const counts = () => psql(`SELECT (SELECT count(*) FROM portal_certificate_submissions) || '|' || (SELECT count(*) FROM storage.objects WHERE bucket_id = 'portal-uploads')
    || '|' || (SELECT count(*) FROM storage.objects WHERE bucket_id = 'supplier-attachments') || '|' || (SELECT count(*) FROM supplier_compliance) || '|' || (SELECT count(*) FROM supplier_attachments);`).out.trim()

async function main() {
    const other = heldBy()
    if (other) { console.error(`✗ live-lock 被【${other.holder}】(pid ${other.pid})占着`); return exitAfterCleanup(5) }
    acquireOrExit('db/scripts/2026-10-20-mes9c-live-proof.mjs', { ownExit: false })
    locked = true
    openPlan('db/scripts/2026-10-20-mes9c-live-proof.mjs')
    await reapStalePlans()
    E = env()
    try { const r = await fetch(BASE + '/login', { redirect: 'manual' }); if (r.status !== 200) throw new Error(`HTTP ${r.status}`) }
    catch (e) { throw new Error(`MES9C_DRIVER|no next server at ${BASE}: ${e.message}`) }
    const c0 = counts()
    console.log(`BEFORE|submissions|portal-uploads objects|supplier-attachments objects|supplier_compliance|supplier_attachments = ${c0}`)

    const stamp = Date.now()
    const A = await mintThrowawaySupplier({ prefix: 'mes9cprobe', label: 'lp-a' })
    const B = await mintThrowawaySupplier({ prefix: 'mes9cprobe', label: 'lp-b' })
    const pA = await mintThrowaway({ prefix: 'mes9cprobe', label: 'lp-pa', stamp, codes: { portalOf: A.supplierId } })
    const pB = await mintThrowaway({ prefix: 'mes9cprobe', label: 'lp-pb', stamp, codes: { portalOf: B.supplierId } })
    const users = { A: { S: A, P: pA }, B: { S: B, P: pB } }
    ok(claimsOf(pA.token).role === 'supplier_portal' && claimsOf(pB.token).role === 'supplier_portal',
       `sign-in: both throwaway portal accounts signed in over HTTP and hold a supplier_portal token (A ${A.code} · B ${B.code})`)

    // ── HTTP leg ──
    for (const k of ['A', 'B']) {
        const u = users[k], o = k === 'A' ? users.B : users.A
        const ck = u.P.cookie
        const home = await getWith(ck, '/portal')
        ok(home.status === 200 && home.body.includes('href="/portal/certificates"') && home.body.includes(`data-portal-supplier="${u.S.code}"`),
           `HTTP ${k}: /portal → ${home.status}, links to its certificates`)
        const pc = await getWith(ck, '/portal/certificates')
        ok(pc.status === 200 && pc.body.includes(`data-portal-certificates="${u.S.code}"`) && pc.body.includes('data-limits="set"')
           && pc.body.includes('Up to 10 MB per file') && pc.body.includes('PDF · JPEG · PNG') && (pc.body.match(/>None\.</g) || []).length === 1
           && pc.body.includes('You have not sent any certificate yet.') && pc.body.includes('data-form="portal-upload"') && !pc.body.includes(o.S.code),
           `HTTP ${k}: /portal/certificates → ${pc.status}, empty state (none on file, none sent), "Up to 10 MB per file · PDF · JPEG · PNG", the upload form, nothing of the other`)
        const rc = await asUser(u.P.token, '/rest/v1/rpc/portal_certificates', { method: 'POST', body: '{}' })
        ok(rc.status === 200 && rc.body?.supplier_code === u.S.code && rc.body.compliance.length === 0 && rc.body.submissions.length === 0
           && rc.body.limits?.set === true && rc.body.limits.max_bytes === 10485760 && JSON.stringify(rc.body.limits.types) === '["application/pdf","image/jpeg","image/png"]'
           && rc.body.types.length > 0,
           `HTTP ${k}: PostgREST portal_certificates → ${rc.status}, its own supplier, empty lists, V39 = 10485760 · PDF / JPEG / PNG, ${rc.body?.types?.length} certificate types`)
    }
    // V39 over HTTP: refused before any byte is stored (nothing committed either way)
    const big = await postUpload(pA.cookie, { certType: 'nea_import', fileName: 'big.pdf', type: 'application/pdf', bytes: Buffer.concat([Buffer.from('%PDF-1.4\n'), Buffer.alloc(10485760 + 200000)]) })
    ok(big.status === 303 && big.location.includes('error=PORTAL_UPLOAD_TOO_LARGE') && big.location.includes('p=10485760'),
       `HTTP A: upload of 10.2 MB → ${big.status} ${big.location.replace(/^https?:\/\/[^/]+/, '')}`)
    const gif = await postUpload(pA.cookie, { certType: 'nea_import', fileName: 'scan.gif', type: 'image/gif', bytes: Buffer.from('GIF89a\x01\x00\x01\x00\x00\x00\x00;', 'binary') })
    ok(gif.status === 303 && gif.location.includes('error=PORTAL_UPLOAD_TYPE_NOT_ACCEPTED'), `HTTP A: upload of a GIF → ${gif.status} ${gif.location.replace(/^https?:\/\/[^/]+/, '')}`)
    const shown = await getWith(pA.cookie, '/portal/certificates?error=PORTAL_UPLOAD_TOO_LARGE&p=10485760')
    ok(shown.body.includes('data-upload-code="PORTAL_UPLOAD_TOO_LARGE"') && shown.body.includes('That file is too large'), `HTTP A: the page says the refusal by name ("That file is too large…")`)
    // the Storage API with the portal token, no submission → refused
    const sp = await fetch(`${E.URL_}/storage/v1/object/portal-uploads/${A.supplierId}/${randomUUID()}.pdf`, {
        method: 'POST', headers: { apikey: E.ANON, Authorization: `Bearer ${pA.token}`, 'Content-Type': 'application/pdf' }, body: Buffer.from('%PDF-1.4\n%%EOF\n') })
    ok(!sp.ok, `HTTP A: the Storage API with the portal token, a portal-uploads path no submission registered → ${sp.status} (refused)`)
    ok(counts() === c0, `HTTP: after the two refused uploads and the refused Storage write, submissions / objects / certificates / attachments unchanged (${counts()})`)
    // staff on the portal pages and the upload route
    const staff = await mintThrowaway({ prefix: 'mes9cprobe', label: 'lp-staff', stamp, codes: { cloneOf: 'cco' } })
    const s1 = await postUpload(staff.cookie, { certType: 'nea_import', fileName: 'a.pdf', type: 'application/pdf', bytes: Buffer.from('%PDF-1.4\n%%EOF\n') })
    ok(s1.status === 403, `staff: a cco copy POSTs the upload route → ${s1.status}`)
    const s2 = await getWith(staff.cookie, '/portal/certificates')
    ok(s2.status === 200 && s2.body.includes('data-access-denied') && !s2.body.includes('data-portal-certificates'), `staff: a cco copy on /portal/certificates → refused`)

    // ── F19: /settings/change-history for the cfo and admin copies, and the database reading of the page's default request ──
    for (const r of ['cfo', 'admin']) {
        const c = await mintThrowaway({ prefix: 'mes9cprobe', label: `f19-${r}`, stamp, codes: { cloneOf: r } })
        const g = await getWith(c.cookie, '/settings/change-history')
        ok(g.status === 200 && !g.body.includes('data-access-denied') && g.body.includes('data-trail-entry'),
           `F19: /settings/change-history as a ${r} copy → ${g.status} in ${g.ms} ms, entries listed`)
        console.log(`F19|http|${r}|${g.status}|${g.ms} ms`)
    }
    const f19 = psql(`BEGIN READ ONLY;
SELECT set_config('request.jwt.claims', '{"sub":"321f1819-8449-48f7-9ae0-78b2c4b50f35","role":"authenticated"}', true) IS NOT NULL;
SET LOCAL ROLE authenticated;
DO $f$
DECLARE t0 timestamptz; n int; tot int := 0; calls int := 0; mx numeric := 0; ms numeric; v_before bigint; m bigint;
BEGIN
    LOOP
        t0 := clock_timestamp();
        SELECT count(*), min(seq) INTO n, m FROM change_log_rows(p_by_entry => true, p_limit => 21, p_row_before => v_before, p_row_limit => 100);
        ms := extract(epoch FROM clock_timestamp() - t0) * 1000; mx := GREATEST(mx, ms); calls := calls + 1; tot := tot + n;
        RAISE NOTICE 'F19|db|call %|% rows|% ms', calls, n, round(ms);
        EXIT WHEN n < 100;
        v_before := m;
    END LOOP;
    RAISE NOTICE 'F19|db|paged|% rows in % calls|slowest % ms', tot, calls, round(mx);
END $f$;
ROLLBACK;`)
    for (const l of (f19.out + '\n' + f19.err).split('\n')) { const m = l.match(/(F19\|db\|.*)$/); if (m) console.log(m[1]) }
    const slow = Number(((f19.out + f19.err).match(/slowest (\d+) ms/) || [])[1])
    ok(f19.code === 0 && slow > 0 && slow < 4000, `F19: the page's default request, paged at 100 rows a call, as admin: slowest call ${slow} ms (well under 8 s)`)

    // ── layout: /portal/certificates as a portal user, 390 and 1280 px ──
    const pcore = process.env.PUPPETEER_CORE
    if (!pcore) throw new Error('MES9C_DRIVER|PUPPETEER_CORE is not set')
    const puppeteer = (await import(pcore)).default
    browser = await puppeteer.launch({ executablePath: CHROME, headless: true, args: ['--no-sandbox'] })
    for (const path of ['/portal', '/portal/certificates', '/portal/certificates?error=PORTAL_UPLOAD_TOO_LARGE&p=10485760']) {
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

    // ── transaction leg (one rolled-back transaction, every trigger on) ──
    const gm = await mintThrowaway({ prefix: 'mes9cprobe', label: 'lp-gm', stamp, codes: { cloneOf: 'gm' } })
    const tx = txSql({ A: { ...users.A, claims: JSON.stringify(claimsOf(pA.token)) }, B: { ...users.B, claims: JSON.stringify(claimsOf(pB.token)) },
                       staff: JSON.stringify(claimsOf(staff.token)), gm: JSON.stringify(claimsOf(gm.token)) })
    writeFileSync(join(ROOT, '.ephemeral', `mes9c-tx-${process.pid}.sql`), tx)
    const tr = psql(tx, 'transaction leg')
    for (const l of (tr.out + '\n' + tr.err).split('\n')) {
        const m = l.match(/(PASS\|.*|FAIL\|.*)$/)
        if (m) { console.log(`${m[1].startsWith('PASS') ? 'PASS' : 'FAIL'}|tx ${m[1].replace(/^(PASS|FAIL)\|/, '')}`); if (m[1].startsWith('FAIL')) bad++ }
    }
    ok(tr.code === 0 && /TX_DONE/.test(tr.out + tr.err), `tx: the rolled-back transaction ran to its end (psql exit ${tr.code}${tr.code ? ': ' + (tr.err.split('\n').find((x) => x.includes('ERROR')) || '').slice(0, 300) : ''})`)
    ok(counts() === c0, `tx: after the ROLLBACK, submissions / objects / certificates / attachments are back to before (${counts()} = ${c0})`)

    // ── the seven roles' permissions on A's supplier page (review section) and on /settings/change-history (read-only) ──
    console.log('ROLES|role|codes|supplier page|review section|can review (module.suppliers.edit)|/settings/change-history')
    for (const r of ROLE_CLONES) {
        const c = await mintThrowaway({ prefix: 'mes9cprobe', label: `rt-${r}`, stamp, codes: { cloneOf: r } })
        const spg = await getWith(c.cookie, `/suppliers/${A.supplierId}/edit`)
        const section = spg.body.includes('data-section="supplier-portal-submissions"')
        const empty = spg.body.includes('data-empty="portal-submissions"')
        const ch = await getWith(c.cookie, '/settings/change-history')
        const chs = ch.body.includes('data-access-denied') ? 'refused' : ch.body.includes('data-trail-entry') ? `opens (${ch.ms} ms)` : `HTTP ${ch.status}`
        console.log(`ROLES|${r}|${c.codes.length}|${spg.status}${spg.body.includes('data-access-denied') ? ' refused' : ''}|${section ? (empty ? 'sees ("Nothing has been sent through the portal.")' : 'sees') : 'no'}|${c.codes.includes('module.suppliers.edit') ? 'yes' : 'no — shown, unpressable, names the code'}|${chs}`)
    }
    console.log(bad ? `STEP|done with ${bad} FAIL` : 'STEP|done')
    return finish(bad ? 1 : 0)
}

function txSql({ A, B, staff, gm }) {
    const meta = (n, t) => lit(JSON.stringify({ size: n, mimetype: t }))   // a SQL literal, handed to format() as %L's argument
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
DO $tx$
DECLARE v text; j jsonb; s1 uuid; p1 text; s2 uuid; p2 text; att text; n int;
    ca text := ${lit(A.claims)}; cb text := ${lit(B.claims)}; cs text := ${lit(staff)}; cg text := ${lit(gm)};
    b text := 'SELECT public.portal_submission_begin(p_cert_type => %L, p_cert_no => %L, p_valid_from => %L::date, p_valid_until => %L::date, p_file_name => %L, p_file_type => %L, p_file_size => %s)::text';
BEGIN
    -- V39 at begin
    v := pg_temp.p9_call(ca, 'supplier_portal', format(b, 'nea_import', NULL, NULL, NULL, 'big.pdf', 'application/pdf', 10485761));
    IF v NOT LIKE 'ERR|%PORTAL_UPLOAD_TOO_LARGE|10485760%' THEN RAISE NOTICE 'FAIL|V39 size at begin → %', v; ELSE RAISE NOTICE 'PASS|V39: 10 MB + 1 byte refused at begin, by name'; END IF;
    v := pg_temp.p9_call(ca, 'supplier_portal', format(b, 'nea_import', NULL, NULL, NULL, 'a.gif', 'image/gif', 100));
    IF v NOT LIKE 'ERR|%PORTAL_UPLOAD_TYPE_NOT_ACCEPTED|image/gif%' THEN RAISE NOTICE 'FAIL|V39 type at begin → %', v; ELSE RAISE NOTICE 'PASS|V39: a GIF refused at begin, by name'; END IF;
    -- A sends one: begin → the platform's upload pre-check → the bytes' row → finish
    v := pg_temp.p9_call(ca, 'supplier_portal', format(b, 'nea_import', 'ZZ-PROBE-MES9C-1', '2026-01-01', '2027-01-01', 'zz-probe-mes9c-permit.pdf', 'application/pdf', 4242));
    IF v LIKE 'ERR|%' THEN RAISE NOTICE 'FAIL|A begin → %', v; RAISE NOTICE 'TX_DONE'; RETURN; END IF;
    s1 := (v::jsonb ->> 'id')::uuid; p1 := v::jsonb ->> 'path';
    IF p1 NOT LIKE ${lit(A.S.supplierId)} || '/%' THEN RAISE NOTICE 'FAIL|A begin path %', p1; ELSE RAISE NOTICE 'PASS|A begin: one uploading submission for its own supplier (path under its supplier)'; END IF;
    v := pg_temp.p9_call(ca, 'supplier_portal', format('SELECT storage.can_insert_object(''portal-uploads'', %L, %L::uuid, ''{}''::jsonb)::text', p1, ${lit(A.P.userId ?? claimsSub(A.claims))}));
    IF v NOT LIKE 'ERR|PT200|%' THEN RAISE NOTICE 'FAIL|storage.can_insert_object on its own path → %', v; ELSE RAISE NOTICE 'PASS|the platform''s upload pre-check (storage.can_insert_object) admits A''s registered path (PT200 = admitted, then undone by the platform)'; END IF;
    v := pg_temp.p9_call(ca, 'supplier_portal', format('SELECT storage.can_insert_object(''portal-uploads'', %L, %L::uuid, ''{}''::jsonb)::text', ${lit(A.S.supplierId)} || '/other.pdf', ${lit(claimsSub(A.claims))}));
    IF v NOT LIKE 'ERR|42501|%' THEN RAISE NOTICE 'FAIL|storage.can_insert_object on another path → %', v; ELSE RAISE NOTICE 'PASS|the platform''s upload pre-check refuses a path no submission registered (42501)'; END IF;
    v := pg_temp.p9_call(cb, 'supplier_portal', format('SELECT storage.can_insert_object(''portal-uploads'', %L, %L::uuid, ''{}''::jsonb)::text', p1, ${lit(claimsSub(B.claims))}));
    IF v NOT LIKE 'ERR|42501|%' THEN RAISE NOTICE 'FAIL|B pre-check on A''s path → %', v; ELSE RAISE NOTICE 'PASS|the platform''s upload pre-check refuses B on A''s path (42501)'; END IF;
    v := pg_temp.p9_call(ca, 'supplier_portal', format('INSERT INTO storage.objects (bucket_id, name, owner, metadata) VALUES (''portal-uploads'', %L, %L::uuid, %L::jsonb) RETURNING name', p1, ${lit(claimsSub(A.claims))}, ${meta(4242, 'application/pdf')}));
    IF v <> p1 THEN RAISE NOTICE 'FAIL|A stores its row → %', v; ELSE RAISE NOTICE 'PASS|A stores its bytes'' row through the live portal policy (insert + read back)'; END IF;
    v := pg_temp.p9_call(cb, 'supplier_portal', format('SELECT public.portal_submission_finish(%L)::text', s1));
    IF v NOT LIKE 'ERR|%PORTAL_SUBMISSION_NOT_FOUND%' THEN RAISE NOTICE 'FAIL|B finishes A''s → %', v; ELSE RAISE NOTICE 'PASS|B cannot finish A''s submission (PORTAL_SUBMISSION_NOT_FOUND)'; END IF;
    v := pg_temp.p9_call(ca, 'supplier_portal', format('SELECT public.portal_submission_finish(%L)::text', s1));
    IF v LIKE 'ERR|%' THEN RAISE NOTICE 'FAIL|A finish → %', v; ELSE RAISE NOTICE 'PASS|A finish: waiting for review'; END IF;
    IF EXISTS (SELECT 1 FROM change_log WHERE txid = txid_current() AND db_role = 'supplier_portal' AND table_name <> 'portal_certificate_submissions') THEN
        RAISE NOTICE 'FAIL|the portal session wrote outside its submission'; ELSE RAISE NOTICE 'PASS|the upload wrote only its own submission rows (no certificate, stock, price or ledger change)'; END IF;
    -- review: gm (read-only) cannot; the cco copy copies the file and accepts
    v := pg_temp.p9_call(cg, 'authenticated', format('SELECT public.portal_submission_reject(%L, %L)::text', s1, 'no'));
    IF v NOT LIKE 'ERR|%PERMISSION_DENIED%' THEN RAISE NOTICE 'FAIL|gm rejects → %', v; ELSE RAISE NOTICE 'PASS|a gm copy (no module.suppliers.edit) cannot review (PERMISSION_DENIED)'; END IF;
    v := pg_temp.p9_call(ca, 'supplier_portal', format('SELECT public.portal_submission_accept(%L, %L, NULL, NULL, NULL, NULL)::text', s1, 'x'));
    IF v NOT LIKE 'ERR|42501|%' THEN RAISE NOTICE 'FAIL|portal accepts → %', v; ELSE RAISE NOTICE 'PASS|the portal session cannot call the review functions (42501)'; END IF;
    att := ${lit(A.S.supplierId)} || '/' || gen_random_uuid() || '-zz-probe-mes9c-permit.pdf';
    v := pg_temp.p9_call(cs, 'authenticated', format('INSERT INTO storage.objects (bucket_id, name, metadata) VALUES (''supplier-attachments'', %L, %L::jsonb) RETURNING name', att, ${meta(4242, 'application/pdf')}));
    IF v <> att THEN RAISE NOTICE 'FAIL|staff copy row → %', v; ELSE RAISE NOTICE 'PASS|the cco copy stores the copy''s row in supplier-attachments (live upload policy)'; END IF;
    v := pg_temp.p9_call(cs, 'authenticated', format('SELECT public.portal_submission_accept(%L, %L, %L, %L, NULL, NULL)::text', s1, att, 'ZZ-PROBE-MES9C-1-CHECKED', 'NEA'));
    IF v LIKE 'ERR|%' THEN RAISE NOTICE 'FAIL|accept → %', v;
    ELSIF NOT EXISTS (SELECT 1 FROM supplier_compliance c JOIN supplier_attachments a ON a.id = c.document_id
                       WHERE c.id = (v::jsonb ->> 'compliance_id')::uuid AND c.supplier_id = ${lit(A.S.supplierId)} AND c.cert_type_code = 'nea_import'
                         AND c.cert_no = 'ZZ-PROBE-MES9C-1-CHECKED' AND c.valid_until = DATE '2027-01-01' AND a.storage_path = att) THEN
        RAISE NOTICE 'FAIL|accept did not create the certificate with its attachment';
    ELSE RAISE NOTICE 'PASS|accept: one supplier_compliance row (type from the submission, number checked by staff) with the copied file as its attachment'; END IF;
    -- A sends a second; the cco copy rejects it with a reason
    v := pg_temp.p9_call(ca, 'supplier_portal', format(b, 'basel', 'ZZ-PROBE-MES9C-2', NULL, NULL, 'zz-probe-mes9c-basel.png', 'image/png', 99));
    s2 := (v::jsonb ->> 'id')::uuid; p2 := v::jsonb ->> 'path';
    PERFORM pg_temp.p9_call(ca, 'supplier_portal', format('INSERT INTO storage.objects (bucket_id, name, owner, metadata) VALUES (''portal-uploads'', %L, %L::uuid, %L::jsonb) RETURNING name', p2, ${lit(claimsSub(A.claims))}, ${meta(99, 'image/png')}));
    PERFORM pg_temp.p9_call(ca, 'supplier_portal', format('SELECT public.portal_submission_finish(%L)::text', s2));
    v := pg_temp.p9_call(cs, 'authenticated', format('SELECT public.portal_submission_reject(%L, %L)::text', s2, ''));
    IF v NOT LIKE 'ERR|%PORTAL_SUBMISSION_REASON_REQUIRED%' THEN RAISE NOTICE 'FAIL|reject without reason → %', v; ELSE RAISE NOTICE 'PASS|reject without a reason refused (PORTAL_SUBMISSION_REASON_REQUIRED)'; END IF;
    v := pg_temp.p9_call(cs, 'authenticated', format('SELECT public.portal_submission_reject(%L, %L)::text', s2, 'ZZ-PROBE-MES9C the scan is unreadable'));
    IF v LIKE 'ERR|%' THEN RAISE NOTICE 'FAIL|reject → %', v; ELSE RAISE NOTICE 'PASS|reject with a reason'; END IF;
    -- what each supplier sees
    v := pg_temp.p9_call(ca, 'supplier_portal', 'SELECT public.portal_certificates()::text');
    j := v::jsonb;
    IF (SELECT string_agg(x ->> 'state' || ':' || COALESCE(x ->> 'reject_reason', '-'), ',' ORDER BY x ->> 'cert_no') FROM jsonb_array_elements(j -> 'submissions') x)
         IS DISTINCT FROM 'accepted:-,rejected:ZZ-PROBE-MES9C the scan is unreadable'
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(j -> 'compliance') x WHERE x ->> 'cert_no' = 'ZZ-PROBE-MES9C-1-CHECKED') THEN
        RAISE NOTICE 'FAIL|A sees → %', left(v, 400);
    ELSE RAISE NOTICE 'PASS|A sees its two submissions — accepted, and rejected with the reason — and the new certificate on file'; END IF;
    v := pg_temp.p9_call(cb, 'supplier_portal', 'SELECT public.portal_certificates()::text');
    IF v LIKE '%ZZ-PROBE-MES9C%' OR jsonb_array_length(v::jsonb -> 'submissions') <> 0 THEN RAISE NOTICE 'FAIL|B sees → %', left(v, 300);
    ELSE RAISE NOTICE 'PASS|B sees none of A''s submissions or certificates'; END IF;
    v := pg_temp.p9_call(cb, 'supplier_portal', format('SELECT public.portal_submission_abandon(%L)::text', s2));
    IF v NOT LIKE 'ERR|%PORTAL_SUBMISSION_NOT_FOUND%' THEN RAISE NOTICE 'FAIL|B abandons A''s → %', v; ELSE RAISE NOTICE 'PASS|B cannot touch A''s submission (PORTAL_SUBMISSION_NOT_FOUND)'; END IF;
    -- the trail: the portal account's rows read as the portal
    SELECT count(*) INTO n FROM change_log c WHERE c.txid = txid_current() AND c.table_name = 'portal_certificate_submissions'
       AND (trail_actor(c.actor_kind, c.actor_account, c.actor_employee) ->> 'state') = 'portal';
    IF n < 4 THEN RAISE NOTICE 'FAIL|portal rows in the trail as the portal: %', n; ELSE RAISE NOTICE 'PASS|the trail names the portal for the portal account''s % submission rows ("Supplier portal — <supplier>")', n; END IF;
    RAISE NOTICE 'TX_DONE';
END
$tx$;
ROLLBACK;
`
}
function claimsSub(c) { return JSON.parse(c).sub }

main().catch((e) => {
    console.error(String(e?.stack || e))
    return finish(String(e?.message || '').startsWith('MES9C_DRIVER') ? 2 : 1)
})
