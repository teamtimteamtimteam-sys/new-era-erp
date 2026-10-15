#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// MES-6b-2(2026-10-15)· 线上验证 —— 分析证书:一笔【回滚】的事务 + 私有桶 coa-documents 里【事后删干净】的对象
// ════════════════════════════════════════════════════════════════════════════
// 与 db/scripts/2026-10-15-mes6b1-live-proof.mjs 同一族,但多了一样东西:证书的字节在【桶】里,而桶的写入不随事务回滚。
//   所以这一支不是"psql -f 一个文件",而是一个【常开的 psql 子进程】(一笔事务从头开到尾),中间由本进程:
//     · 照 issue_coa 在事务里返回的【那一份快照】渲染 PDF(app/output/coa/renderCoa.tsx,与路由同一支 —— 不回读);
//     · 以签发人的一次性账号经 Storage API 上传(桶的 INSERT 策略:action.issue_coa —— 一次性角色的授权是已提交的);
//     · 回到事务里 record_coa_issue 记哈希;再以 Storage API 下载、重算 sha256、用 pypdf 抽出纸上的字,与快照逐项比对;
//     · 以 service role 覆盖那份字节(模拟被改过的档案)→ 再下载 → 哈希对不上 = 路由的 409 那一支;
//     · 收尾:每一个上传过的对象都在上传【之前】登记了删除步(scripts/ephemeral.mjs 的计划),最后按计划删掉,再读回桶里 0 个对象。
//   为什么桶的断言不是 fixture:AGENTS.md「存储桶与它的策略不在镜像里」。
//
// 【身份】每一个动作都以一次性账号跑(前缀 mes6b2probe),七个真账号一个都不用:
//   iss  = 签发人(action.issue_coa · module.output.view · module.quality.view · module.inventory.view);员工档案与职位【在事务里】插
//   cfo  = 真的 cfo 角色本身(realRole)—— 只为【决定】二级审批的作废申请(二级审批人认的是角色)
//   cco  = 合同条款(写合同、条款、验收限、提生效申请)          sal = 销售单、挂合同、预留
//   rec  = 产出批、化验表单                                    qe  = 开不合格报告、立化验争议
//   view = 只有 module.output.view 的读者                       c_<角色> = 七个真角色【此刻的码】的克隆(cloneOf,只读)
// 【布景】都是我自己的行(前缀 ZZ-PROBE-MES6B2),在事务里插,随回滚消失。在册的东西一行都不改、不决定、不删。
//
// 【判决】只从日志里最后那一行 `MES6B2_PROOF_EXIT=` 读(exitAfterCleanup 的 onFinish 打的)。
//   0 = 证明走完(STEP|done)且收尾读回桶空 · 1 = 证明红了 · 2 = 驱动自己坏了 · 5 = live-lock 被占 · 6 = 收尾没完成。
// 用法:node db/scripts/2026-10-15-mes6b2-live-proof.mjs > <log> 2>&1
// ════════════════════════════════════════════════════════════════════════════
import { onlyWhenRunDirectly } from '../../scripts/lib/entrypoint.mjs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawn, spawnSync } from 'node:child_process'
import { createHash, randomUUID } from 'node:crypto'
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { acquireOrExit, release, heldBy } from '../../scripts/liveLock.mjs'
import { openPlan, mintThrowaway, reapStalePlans, installExitHooks, exitAfterCleanup, planDelete, ORDER } from '../../scripts/ephemeral.mjs'

onlyWhenRunDirectly(import.meta.url)

const ROOT = dirname(dirname(dirname(fileURLToPath(import.meta.url))))
const DSN = process.env.CHECK_MIRRORS_DSN || 'host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 user=postgres.wvywpohbwkiinmipmuku dbname=postgres'
const BUCKET = 'coa-documents'
const ROLE_CLONES = ['admin', 'finance', 'warehouse', 'cto', 'cco', 'cfo', 'gm']

let locked = false
let psql = null
let scratch = null
let bucketVerdict = 'not read'
installExitHooks({
    beforeFinish: async () => {
        try { if (psql && psql.exitCode === null) psql.kill('SIGTERM') } catch { /* 子进程已经没了 */ }
    },
    onFinish: (code) => {
        try { if (locked) release() } catch { /* 放锁失败不改判决 */ }
        try { if (scratch) rmSync(scratch, { recursive: true, force: true }) } catch { /* 临时目录 */ }
        console.log(`AFTER|bucket ${BUCKET}: ${bucketVerdict}`)
        console.log(`MES6B2_PROOF_EXIT=${code}`)
    },
})

// ── .env.local:第一次用到时才读(HOTFIX-6A2 —— 不在 import 时读)──────────────
let env_ = null
function env() {
    if (!env_) {
        const t = readFileSync(join(ROOT, '.env.local'), 'utf8')
        env_ = {
            URL: t.match(/NEXT_PUBLIC_SUPABASE_URL=(\S+)/)[1],
            SERVICE: t.match(/SUPABASE_SERVICE_ROLE_KEY=(\S+)/)[1],
            ANON: t.match(/NEXT_PUBLIC_SUPABASE_ANON_KEY=(\S+)/)[1],
        }
    }
    return env_
}

// ── 常开的 psql:一笔事务;每一段以 \echo 一个记号收尾,读到记号算这一段跑完 ─────
let out = ''
let err = ''
function startPsql() {
    psql = spawn('psql', ['-X', '-q', '-v', 'ON_ERROR_STOP=1', DSN], { stdio: ['pipe', 'pipe', 'pipe'] })
    psql.stdout.on('data', (d) => { out += d })
    psql.stderr.on('data', (d) => {
        err += d
        for (const line of String(d).split('\n')) {
            const m = line.match(/(STEP\|.*|ROLE\|.*)$/)
            if (m) console.log(m[1])
        }
    })
}
let seq = 0
async function run(sqlText, label) {
    const mark = `@@MES6B2_DONE_${++seq}@@`
    const from = out.length
    psql.stdin.write(`${sqlText}\n\\echo ${mark}\n`)
    const t0 = Date.now()
    while (!out.includes(mark, from)) {
        if (psql.exitCode !== null) {
            throw new Error(`MES6B2_SQL|${label}|psql exited ${psql.exitCode}:\n${err.split('\n').slice(-20).join('\n')}`)
        }
        if (Date.now() - t0 > 360_000) throw new Error(`MES6B2_SQL|${label}|no answer within 360s`)
        await new Promise((r) => setTimeout(r, 50))
    }
    const chunk = out.slice(from, out.indexOf(mark, from))
    const vals = {}
    for (const line of chunk.split('\n')) {
        const m = line.match(/^OUT\|([^|]+)\|(.*)$/)
        if (m) vals[m[1]] = m[2]
    }
    return vals
}
const lit = (s) => `'${String(s).replace(/'/g, "''")}'`

// ── Storage API(以一次性账号的 token;service role 只用来"改坏字节"与收尾)──────
async function upload(token, path, bytes, { asService = false, upsert = false } = {}) {
    const { URL, ANON, SERVICE } = env()
    const r = await fetch(`${URL}/storage/v1/object/${BUCKET}/${path}`, {
        method: asService ? 'PUT' : 'POST',
        headers: { apikey: asService ? SERVICE : ANON, Authorization: `Bearer ${asService ? SERVICE : token}`,
                   'Content-Type': 'application/pdf', 'x-upsert': upsert ? 'true' : 'false' },
        body: bytes,
    })
    return { status: r.status, text: (await r.text()).slice(0, 300) }
}
async function download(token, path) {
    const { URL, ANON } = env()
    // 带一个一次性的查询串:同一路径的已认证下载会被存储那一侧的缓存接住(实测:覆盖之后立刻下载,读回的仍是旧字节)
    const r = await fetch(`${URL}/storage/v1/object/authenticated/${BUCKET}/${path}?nocache=${randomUUID()}`, {
        headers: { apikey: ANON, Authorization: `Bearer ${token}` },
    })
    const buf = Buffer.from(await r.arrayBuffer())
    return { status: r.status, buf }
}
async function removeAs(token, paths) {
    const { URL, ANON } = env()
    const r = await fetch(`${URL}/storage/v1/object/${BUCKET}`, {
        method: 'DELETE', headers: { apikey: ANON, Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ prefixes: paths }),
    })
    const j = await r.json().catch(() => null)
    return { status: r.status, removed: Array.isArray(j) ? j.length : -1 }
}
async function listBucketAsService() {
    const { URL, SERVICE } = env()
    const r = await fetch(`${URL}/storage/v1/object/list/${BUCKET}`, {
        method: 'POST', headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ prefix: '', limit: 1000 }),
    })
    const j = await r.json().catch(() => null)
    if (!r.ok || !Array.isArray(j)) throw new Error(`MES6B2_BUCKET|list HTTP ${r.status} ${JSON.stringify(j).slice(0, 200)}`)
    return j
}
const sha = (b) => createHash('sha256').update(b).digest('hex')
// 删对象的那一步先落盘。走批量删除那一个端点(DELETE /object/<桶>,body 里点名):对象已经没了它也回 200 ——
//   单个对象的 DELETE 对"已经没了"回的是 400 NoSuchKey,收割会把一次已经完成的删除记成失败(第一次补删实测)
function planObjectDelete(path) {
    planDelete(`/storage/v1/object/${BUCKET}`, `删证明上传的 ${BUCKET}/${path}`, ORDER.OTHER,
        { method: 'DELETE', body: JSON.stringify({ prefixes: [path] }) })
}
function pdfText(buf) {
    const f = join(scratch, `${randomUUID()}.pdf`)
    writeFileSync(f, buf)
    const r = spawnSync('python3', ['-c', 'import pypdf,sys\nr=pypdf.PdfReader(sys.argv[1])\nprint(len(r.pages))\nprint("\\n".join(p.extract_text() for p in r.pages))', f],
        { encoding: 'utf8' })
    if (r.status !== 0) throw new Error(`MES6B2_PDF|pypdf could not read the bytes: ${r.stderr.slice(0, 300)}`)
    const [pages, ...rest] = r.stdout.split('\n')
    return { pages: Number(pages), text: rest.join('\n') }
}
function must(cond, msg) { if (!cond) throw new Error(`MES6B2_LIVE|${msg}`) }

// ── 渲染:与路由同一支 renderCoaPdf,入参只有快照与模式 ───────────────────────
let renderCoaPdf = null
let coaUnrenderable = null
async function loadRenderer() {
    const { createJiti } = await import('jiti')
    const React = (await import('react')).default
    globalThis.React = React // jiti 的 JSX 走经典运行时
    const jiti = createJiti(import.meta.url, { alias: { '@': ROOT }, jsx: true, interopDefault: true })
    const mod = await jiti.import(join(ROOT, 'app/output/coa/renderCoa.tsx'))
    renderCoaPdf = mod.renderCoaPdf
    coaUnrenderable = mod.coaUnrenderable
}

// 签发之后的那一段 Node 活:渲染 → 上传(删除步先落盘)→ 事务里记哈希 → 下载、重算、读纸
async function storeAndCheck(who, issued, expect) {
    const snap = issued.snapshot
    const buf = await renderCoaPdf(snap, 'issued')
    const digest = sha(buf)
    const path = `${issued.coa_id}/${randomUUID()}.pdf`
    planObjectDelete(path)
    const up = await upload(who.token, path, buf)
    must(up.status === 200, `${issued.code}: the issuer could not upload (HTTP ${up.status} ${up.text})`)
    const rec = await run(`SELECT 'OUT|rec|' || pg_temp.get_('iss', format($q$SELECT record_coa_issue(%L, %L, %L)$q$, ${lit(issued.coa_id)}, ${lit(path)}, ${lit(digest.toUpperCase())}))::text;`, 'record')
    const recJ = JSON.parse(rec.rec)
    must(recJ.sha256 === digest, `${issued.code}: record_coa_issue stored ${recJ.sha256}, expected the lower-case ${digest}`)
    const dl = await download(who.token, path)
    must(dl.status === 200 && sha(dl.buf) === digest, `${issued.code}: download HTTP ${dl.status}, sha ${sha(dl.buf)} vs recorded ${digest}`)
    const t = pdfText(dl.buf)
    for (const needle of expect) must(t.text.includes(needle), `${issued.code}: the stored PDF does not say «${needle}»`)
    console.log(`STEP|stored|${issued.code}: rendered from the snapshot issue_coa returned (${buf.length} bytes, ${t.pages} page${t.pages === 1 ? '' : 's'}) → uploaded by the issuer to ${BUCKET}/${path} → sha256 recorded (sent upper-case, stored ${digest.slice(0, 12)}…) → downloaded, sha matches → the paper says ${expect.map((x) => `«${x}»`).join(' ')}`)
    return { path, digest, text: t.text }
}

async function main() {
    const other = heldBy()
    if (other) {
        console.error(`✗ live-lock 被【${other.holder}】(pid ${other.pid})占着 —— 等它跑完再来。`)
        return exitAfterCleanup(5)
    }
    acquireOrExit('db/scripts/2026-10-15-mes6b2-live-proof.mjs', { ownExit: false })
    locked = true
    openPlan('db/scripts/2026-10-15-mes6b2-live-proof.mjs')
    await reapStalePlans()
    scratch = mkdtempSync(join(tmpdir(), 'mes6b2-proof-'))
    await loadRenderer()

    // 桶开跑前是空的(本刀之前它根本不存在;在我之前不该有人放过东西)
    const before = await listBucketAsService()
    must(before.length === 0, `bucket ${BUCKET} already holds ${before.length} object(s) before the proof — not mine, stopping`)
    console.log(`STEP|bucket before|${BUCKET} exists and is empty (service-role listing: 0 objects)`)

    const stamp = Date.now()
    const who = {}
    const mint = async (key, label, codes) => {
        const a = await mintThrowaway({ prefix: 'mes6b2probe', label, stamp, codes })
        who[key] = a
        console.log(`· ${key}: ${a.email} ← ${a.roleCode} (${a.codes.length} codes${Array.isArray(codes) ? ': ' + a.codes.join(', ') : ''})`)
    }
    await mint('iss', 'iss', ['action.issue_coa', 'module.output.view', 'module.quality.view', 'module.inventory.view'])
    await mint('cfo', 'cfo', { realRole: 'cfo' })
    await mint('cco', 'cco', ['action.contract_terms', 'module.customers.view', 'module.customers.edit', 'module.suppliers.view',
                              'module.pricing.view', 'module.pricing.edit', 'data.view_prices', 'data.view_purchase_prices'])
    await mint('sal', 'sal', ['module.sales.view', 'module.sales.edit', 'module.output.view', 'module.customers.view', 'module.customers.edit',
                              'module.pricing.view', 'data.view_prices'])
    await mint('rec', 'rec', ['module.inbound.view', 'module.inbound.edit', 'module.output.view', 'module.output.edit'])
    await mint('qe', 'qe', ['module.quality.view', 'module.quality.edit', 'module.inbound.view', 'module.output.view'])
    await mint('view', 'view', ['module.output.view'])
    for (const r of ROLE_CLONES) await mint(`c_${r}`, `c-${r}`, { cloneOf: r })

    startPsql()
    const emails = Object.entries(who).map(([k, a]) => `(${lit('email.' + k)}, ${lit(a.email)})`).join(', ')
    await run(String.raw`
\pset pager off
\pset format unaligned
\pset tuples_only on
BEGIN;
SET LOCAL statement_timeout = '300s';
SET LOCAL lock_timeout = '10s';
CREATE TEMP TABLE p6 (k text PRIMARY KEY, v text) ON COMMIT DROP;
INSERT INTO p6 VALUES ${emails};
CREATE FUNCTION pg_temp.put_(p_k text, p_v text) RETURNS void LANGUAGE sql AS $f$
    INSERT INTO p6 VALUES (p_k, p_v) ON CONFLICT (k) DO UPDATE SET v = EXCLUDED.v $f$;
CREATE FUNCTION pg_temp.val_(p_k text) RETURNS text LANGUAGE sql AS $f$ SELECT v FROM p6 WHERE k = p_k $f$;
CREATE FUNCTION pg_temp.id_(p_k text) RETURNS uuid LANGUAGE sql AS $f$ SELECT v::uuid FROM p6 WHERE k = p_k $f$;
CREATE FUNCTION pg_temp.as_(p_who text) RETURNS void LANGUAGE plpgsql AS $f$
DECLARE v_uid uuid; e text := (SELECT x.v FROM p6 x WHERE x.k = 'email.' || p_who);
BEGIN
    EXECUTE 'RESET ROLE';
    SELECT id INTO v_uid FROM auth.users WHERE email = e;
    IF v_uid IS NULL OR e NOT LIKE 'mes6b2probe-%@test.local' THEN RAISE EXCEPTION 'MES6B2_LIVE|not a throwaway account: % (%)', p_who, e; END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_uid), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
END $f$;
CREATE FUNCTION pg_temp.me_() RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);
END $f$;
CREATE FUNCTION pg_temp.try_(p_who text, p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
BEGIN
    PERFORM pg_temp.as_(p_who);
    EXECUTE p_sql;
    PERFORM pg_temp.me_();
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.me_();
    RETURN SQLERRM;
END $f$;
-- 以 p_who 的身份试一句,然后【一定】撤掉它做的事(子事务回滚):成 → 'OK',拒 → 那一句原话。逐角色读数表用 —— 一张在等的申请不许留下
CREATE FUNCTION pg_temp.would_(p_who text, p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE r text;
BEGIN
    BEGIN
        PERFORM pg_temp.as_(p_who);
        EXECUTE p_sql;
        RAISE EXCEPTION 'MES6B2_WOULD_OK';
    EXCEPTION WHEN OTHERS THEN
        r := SQLERRM;
    END;
    PERFORM pg_temp.me_();
    RETURN CASE WHEN r = 'MES6B2_WOULD_OK' THEN 'OK' ELSE r END;
END $f$;
CREATE FUNCTION pg_temp.get_(p_who text, p_sql text) RETURNS jsonb LANGUAGE plpgsql AS $f$
DECLARE v jsonb;
BEGIN
    PERFORM pg_temp.as_(p_who);
    EXECUTE p_sql INTO v;
    PERFORM pg_temp.me_();
    RETURN v;
EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.me_();
    RAISE;
END $f$;
CREATE FUNCTION pg_temp.uid_(p_who text) RETURNS uuid LANGUAGE sql AS $f$
    SELECT u.id FROM auth.users u WHERE u.email = (SELECT v FROM p6 WHERE k = 'email.' || p_who) $f$;
CREATE FUNCTION pg_temp.agree_(p_step text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE v jsonb; s jsonb; o text := '';
BEGIN
    v := pg_temp.get_('c_cfo', 'SELECT list_ledger_reconciliation()');
    IF jsonb_array_length(v -> 'sides') <> 2 THEN RAISE EXCEPTION 'MES6B2_LIVE|reconciliation after %: expected two sides, got %', p_step, v; END IF;
    FOR s IN SELECT * FROM jsonb_array_elements(v -> 'sides') LOOP
        IF s ->> 'refusal' IS NOT NULL OR (s ->> 'unexplained_base')::numeric IS DISTINCT FROM 0 THEN
            RAISE EXCEPTION 'MES6B2_LIVE|AP/AR list <> ledger after %: %', p_step, s;
        END IF;
        o := o || (s ->> 'side') || ' ' || (s ->> 'list_base') || ' / ' || (s ->> 'ledger_base') || ' / ' || (s ->> 'unexplained_base') || '; ';
    END LOOP;
    RETURN o;
END $f$;
-- 在册的东西的指纹:我的行 created_at = 事务开始时刻(now()),按 < t0 排除
CREATE FUNCTION pg_temp.fp_(t0 timestamptz) RETURNS text LANGUAGE sql AS $f$
SELECT md5(concat_ws('#',
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM inbound_batches x WHERE x.created_at < t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM output_batches x WHERE x.created_at < t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.output_batch_id, x.metal)) FROM output_batch_metals x WHERE x.created_at < t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM assay_results x WHERE x.created_at < t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.assay_result_id, x.metal)) FROM assay_result_metals x WHERE x.created_at < t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM assay_disputes x WHERE x.created_at < t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM nonconformance_reports x WHERE x.opened_at < t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM quality_limit_judgements x WHERE x.judged_at < t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM certificates_of_destruction x),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM warehouse_requests x WHERE x.created_at < t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM approval_log x WHERE x.created_at < t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM processing_runs x WHERE x.created_at < t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM inventory_movements x WHERE x.created_at < t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM sales_orders x WHERE x.created_at < t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM sales_order_lines x WHERE x.created_at < t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM sales_order_reservations x WHERE x.created_at < t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM contracts x WHERE x.created_at < t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM contract_settlement_terms x WHERE x.created_at < t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM contract_quality_limits x WHERE x.created_at < t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM terms_requests x WHERE x.created_at < t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM customers x WHERE x.created_at < t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM suppliers x WHERE x.created_at < t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM materials x WHERE x.created_at < t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM employees x WHERE x.created_at < t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM positions x WHERE x.created_at < t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM journal_entries x WHERE x.created_at < t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM journal_lines x WHERE x.created_at < t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM payments x WHERE x.created_at < t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM expenses x WHERE x.created_at < t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.code)) FROM permissions x),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.role_id, x.permission_code)) FROM role_permissions x
      WHERE x.role_id IN (SELECT id FROM roles WHERE code NOT LIKE 'probe-%')),
    (SELECT md5(to_jsonb(x)::text) FROM company_profile x),
    (SELECT md5(to_jsonb(x)::text) FROM finance_settings x),
    (SELECT md5(to_jsonb(x)::text) FROM ingest_settings x)))
$f$;
GRANT EXECUTE ON FUNCTION pg_temp.as_(text), pg_temp.me_() TO authenticated;
GRANT SELECT ON p6 TO authenticated;
CREATE TEMP TABLE p6_roles (who text, role text, codes integer, coa_rows bigint, cert_row bigint, bytes_row bigint, issue boolean,
    request_listed bigint, raise_void boolean) ON COMMIT DROP;
GRANT INSERT ON p6_roles TO authenticated;
`, 'open')

    // ══ ⓪ 前提与布景 ══
    let v = await run(String.raw`
DO $s$
DECLARE
    v_t0 timestamptz := now(); d date := CURRENT_DATE;
    sup uuid; mat uuid; cust uuid; p_qm uuid; e_iss uuid := gen_random_uuid();
    ib1 uuid; ib2 uuid; ib3 uuid; obA uuid; obB uuid; obC uuid; obD uuid; obE uuid;
BEGIN
    IF NOT approvals_enabled() THEN RAISE EXCEPTION 'MES6B2_LIVE|approvals are off on live'; END IF;
    IF EXISTS (SELECT 1 FROM certificates_of_analysis) OR EXISTS (SELECT 1 FROM coa_issues)
       OR EXISTS (SELECT 1 FROM warehouse_requests WHERE kind = 'coa_void') THEN
        RAISE EXCEPTION 'MES6B2_LIVE|live already has a certificate of analysis, a byte record or a coa_void request — this proof expects none';
    END IF;
    IF (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         WHERE rp.permission_code = 'action.issue_coa' AND r.code NOT LIKE 'probe-%') IS DISTINCT FROM 'admin,cco' THEN
        RAISE EXCEPTION 'MES6B2_LIVE|action.issue_coa should be held by exactly admin and cco';
    END IF;
    IF (SELECT approval_level2_role_code FROM finance_settings) IS DISTINCT FROM 'cfo' THEN
        RAISE EXCEPTION 'MES6B2_LIVE|the level-2 approver role is expected to be cfo';
    END IF;
    IF btrim(COALESCE((SELECT legal_name FROM company_profile LIMIT 1), '')) = '' THEN
        RAISE EXCEPTION 'MES6B2_LIVE|live has no company legal name — a certificate would be refused, and this proof does not edit the company profile';
    END IF;
    PERFORM pg_temp.put_('t0', v_t0::text);
    PERFORM pg_temp.put_('fp', pg_temp.fp_(v_t0));
    PERFORM pg_temp.put_('pending', (SELECT COALESCE(string_agg(subject_type || ':' || code, ',' ORDER BY code), '') FROM approval_pending_documents()));
    PERFORM pg_temp.put_('rec_start', pg_temp.agree_('start'));

    -- 签发人:员工档案 + 职位(我自己的两行,随回滚消失)
    INSERT INTO positions (code, title) VALUES ('ZZ-PROBE-MES6B2-QM', 'Quality Manager (probe)') RETURNING id INTO p_qm;
    INSERT INTO employees (id, code, legal_name, preferred_name, employment_type, work_category, hire_date, user_id, position_id)
    VALUES (e_iss, 'ZZ-PROBE-MES6B2-ISS', 'ZZ Probe Issuer Lim', 'Lim (probe)', 'full_time', 'office', d - 400, pg_temp.uid_('iss'), p_qm);

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type, default_tax_code)
    VALUES ('ZZ-PROBE-MES6B2-S', 'ZZ-PROBE-MES6B2 goods supplier', 'SG', 'active', 'goods_supplier', 'OP') RETURNING id INTO sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, unit)
    VALUES ('ZZ-PROBE-MES6B2-BM', 'ZZ-PROBE-MES6B2 black mass', 'battery_material', true, 'black_mass', 'end_of_life', 'kg') RETURNING id INTO mat;
    INSERT INTO customers (code, legal_name, country, payment_terms_days, default_tax_code)
    VALUES ('ZZ-PROBE-MES6B2-C', 'ZZ-PROBE-MES6B2 Buyer Pte Ltd', 'SG', 30, 'SR') RETURNING id INTO cust;
    INSERT INTO inbound_batches (material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note, chemistry_certainty_code)
    VALUES (mat, sup, 100, 100, 'kg', d - 9, 'other', 'ZZ-PROBE-MES6B2 single', 'single_known') RETURNING id INTO ib1;
    INSERT INTO inbound_batches (material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note, chemistry_certainty_code)
    VALUES (mat, sup, 100, 100, 'kg', d - 9, 'other', 'ZZ-PROBE-MES6B2 mixed', 'mixed') RETURNING id INTO ib2;
    INSERT INTO inbound_batches (material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note, chemistry_certainty_code)
    VALUES (mat, sup, 100, 100, 'kg', d - 9, 'other', 'ZZ-PROBE-MES6B2 not recorded', NULL) RETURNING id INTO ib3;
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code) VALUES (ib1, 'discharged_verified'), (ib2, 'discharged_verified'), (ib3, 'discharged_verified');
    obA := (pg_temp.get_('rec', format($q$SELECT create_output_batch(%L, 1000, 'kg', %L, p_notes => 'ZZ-PROBE-MES6B2 certificate')$q$, mat, d - 3)) ->> 'batch_id')::uuid;
    obB := (pg_temp.get_('rec', format($q$SELECT create_output_batch(%L, 100, 'kg', %L, p_notes => 'ZZ-PROBE-MES6B2 three feeds')$q$, mat, d - 3)) ->> 'batch_id')::uuid;
    obC := (pg_temp.get_('rec', format($q$SELECT create_output_batch(%L, 100, 'kg', %L, p_notes => 'ZZ-PROBE-MES6B2 no assay')$q$, mat, d - 3)) ->> 'batch_id')::uuid;
    obD := (pg_temp.get_('rec', format($q$SELECT create_output_batch(%L, 100, 'kg', %L, p_notes => 'ZZ-PROBE-MES6B2 open NCR')$q$, mat, d - 3)) ->> 'batch_id')::uuid;
    obE := (pg_temp.get_('rec', format($q$SELECT create_output_batch(%L, 100, 'kg', %L, p_notes => 'ZZ-PROBE-MES6B2 open dispute')$q$, mat, d - 3)) ->> 'batch_id')::uuid;
    PERFORM pg_temp.put_('mat', mat::text); PERFORM pg_temp.put_('cust', cust::text);
    PERFORM pg_temp.put_('obA', obA::text); PERFORM pg_temp.put_('obB', obB::text); PERFORM pg_temp.put_('obC', obC::text);
    PERFORM pg_temp.put_('obD', obD::text); PERFORM pg_temp.put_('obE', obE::text);
    RAISE NOTICE 'STEP|setup|own rows (prefix ZZ-PROBE-MES6B2): issuer employee + position, supplier, material, customer, inbound % (single_known) / % (mixed) / % (not recorded), output % / % / % / % / %; reconciliation at start %',
        (SELECT code FROM inbound_batches WHERE id = ib1), (SELECT code FROM inbound_batches WHERE id = ib2), (SELECT code FROM inbound_batches WHERE id = ib3),
        (SELECT code FROM output_batches WHERE id = obA), (SELECT code FROM output_batches WHERE id = obB), (SELECT code FROM output_batches WHERE id = obC),
        (SELECT code FROM output_batches WHERE id = obD), (SELECT code FROM output_batches WHERE id = obE), pg_temp.val_('rec_start');

    -- ══ ① N38:血缘(属主直插加工单 —— 证书只读血缘)══
    FOR i IN 1..2 LOOP
        DECLARE v_run uuid; v_ob uuid := CASE i WHEN 1 THEN obA ELSE obB END;
        BEGIN
            INSERT INTO processing_runs (code, status, allocation_basis, process_date, operation_type_code, started_at, ended_at, shift_code)
            VALUES ('ZZ-PROBE-MES6B2-RUN-' || i, 'committed', 'weight', d - 3, 'manual_disassembly', (d - 3)::timestamptz, (d - 3)::timestamptz + interval '1 hour', 'day')
            RETURNING id INTO v_run;
            PERFORM set_config('evoltrya.movement_ctx', 'processing:' || v_run, true);
            INSERT INTO processing_inputs (run_id, inbound_batch_id, quantity_consumed) VALUES (v_run, ib1, 10), (v_run, ib2, 10);
            IF i = 2 THEN INSERT INTO processing_inputs (run_id, inbound_batch_id, quantity_consumed) VALUES (v_run, ib3, 10); END IF;
            PERFORM set_config('evoltrya.movement_ctx', '', true);
            INSERT INTO processing_outputs (run_id, output_batch_id, quantity_produced) VALUES (v_run, v_ob, 10);
        END;
    END LOOP;
END $s$;
SELECT 'OUT|n38A|' || pg_temp.get_('view', format($q$SELECT to_jsonb(c) FROM output_batch_chemistry_certainty c WHERE output_batch_id = %L$q$, pg_temp.id_('obA')))::text;
SELECT 'OUT|n38B|' || pg_temp.get_('view', format($q$SELECT to_jsonb(c) FROM output_batch_chemistry_certainty c WHERE output_batch_id = %L$q$, pg_temp.id_('obB')))::text;
SELECT 'OUT|n38gate|' || pg_temp.get_('cco', format($q$SELECT to_jsonb(count(*)) FROM output_batch_chemistry_certainty c WHERE output_batch_id = %L$q$, pg_temp.id_('obA')))::text;
SELECT 'OUT|n38base|' || pg_temp.try_('view', 'SELECT 1 FROM output_batch_chemistry_certainty_all LIMIT 1');
`, 'setup')
    const nA = JSON.parse(v.n38A), nB = JSON.parse(v.n38B)
    must(nA.certainty === 'mixed' && nA.inbound_leaves === 2 && nA.leaves_single_known === 1 && nA.leaves_mixed === 1,
        `N38: single_known + mixed should read mixed over two leaves, got ${v.n38A}`)
    must(nB.certainty === 'not_recorded' && nB.inbound_leaves === 3 && nB.leaves_not_recorded === 1,
        `N38: single_known + mixed + not recorded should read not_recorded over three leaves, got ${v.n38B}`)
    must(v.n38gate === '0', `N38: a reader without module.output.view should see 0 rows, saw ${v.n38gate}`)
    must(/permission denied/.test(v.n38base), `N38: the ungated base view must refuse a reader, got «${v.n38base}»`)
    console.log(`STEP|N38|feeds single_known + mixed → «mixed» (2 leaves) · + one not recorded → «not_recorded» (3 leaves) · a reader without module.output.view: 0 rows · the base view refuses staff («${v.n38base.slice(0, 60)}»)`)

    // ══ ② 拒绝:没有最终化验 · 开着的报告 · 开着的争议 ══
    v = await run(String.raw`
DO $s$
DECLARE a1 uuid; a2 uuid; d date := CURRENT_DATE;
BEGIN
    -- obD:一份最终化验 + 一张开着的报告;obE:我们与对方各一份 + 一件开着的争议
    PERFORM pg_temp.get_('rec', format($q$SELECT record_assay_result(p_assay_date => %L, p_output_batch_id => %L, p_weight_basis => 'dry', p_moisture_pct => 6.4,
              p_result_party => 'ours', p_certificate_ref => 'ZZ-PROBE-MES6B2-D', p_metals => '[{"metal": "ni", "content_pct": 20}]'::jsonb)$q$, d - 2, pg_temp.id_('obD')));
    PERFORM pg_temp.put_('ncrD', pg_temp.get_('qe', format($q$SELECT open_ncr('manual', 'ZZ-PROBE-MES6B2 caking found on the floor', p_output_batch_id => %L)$q$, pg_temp.id_('obD'))) ->> 'code');
    a1 := (pg_temp.get_('rec', format($q$SELECT record_assay_result(p_assay_date => %L, p_output_batch_id => %L, p_weight_basis => 'dry', p_moisture_pct => 6.4,
              p_result_party => 'ours', p_metals => '[{"metal": "ni", "content_pct": 20}]'::jsonb)$q$, d - 2, pg_temp.id_('obE'))) ->> 'assay_result_id')::uuid;
    a2 := (pg_temp.get_('rec', format($q$SELECT record_assay_result(p_assay_date => %L, p_output_batch_id => %L, p_weight_basis => 'dry', p_moisture_pct => 6.4,
              p_result_party => 'counterparty', p_metals => '[{"metal": "ni", "content_pct": 18}]'::jsonb)$q$, d - 2, pg_temp.id_('obE'))) ->> 'assay_result_id')::uuid;
    PERFORM pg_temp.get_('qe', format($q$SELECT open_assay_dispute(%L, %L, 'ZZ-PROBE-MES6B2 nickel differs')$q$, a1, a2));
END $s$;
SELECT 'OUT|refC|' || pg_temp.try_('iss', format($q$SELECT issue_coa(%L)$q$, pg_temp.id_('obC')));
SELECT 'OUT|refD|' || pg_temp.try_('iss', format($q$SELECT issue_coa(%L)$q$, pg_temp.id_('obD')));
SELECT 'OUT|refE|' || pg_temp.try_('iss', format($q$SELECT issue_coa(%L)$q$, pg_temp.id_('obE')));
SELECT 'OUT|codes|' || (SELECT string_agg(code, ',' ORDER BY code) FROM output_batches WHERE id IN (pg_temp.id_('obC'), pg_temp.id_('obD'), pg_temp.id_('obE')));
SELECT 'OUT|ncrD|' || pg_temp.val_('ncrD');
SELECT 'OUT|leftover|' || (SELECT count(*) FROM certificates_of_analysis);
`, 'refusals')
    must(/^COA_NO_FINAL_ASSAY\|.+\|-$/.test(v.refC), `no final assay: «${v.refC}»`)
    must(v.refD.startsWith('QUALITY_HOLD_OPEN|') && v.refD.endsWith('|' + v.ncrD), `open NCR: «${v.refD}»`)
    must(v.refE.startsWith('ASSAY_DISPUTE_OPEN|'), `open dispute: «${v.refE}»`)
    must(v.leftover === '0', `a refused issue left ${v.leftover} certificate(s)`)
    console.log(`STEP|refusals|iss issuing on three batches: «${v.refC}» · «${v.refD}» · «${v.refE.slice(0, 60)}…» · no certificate left behind`)

    // ══ ③ 签发,不点名销售单 ══
    await run(String.raw`
DO $s$
BEGIN
    PERFORM pg_temp.put_('aA', pg_temp.get_('rec', format($q$SELECT record_assay_result(p_assay_date => %L, p_output_batch_id => %L, p_weight_basis => 'dry', p_moisture_pct => 6.4,
              p_result_party => 'ours', p_certificate_ref => 'ZZ-PROBE-MES6B2-LAB-1', p_metals => '[{"metal": "ni", "content_pct": 21.5}, {"metal": "co", "content_pct": 5.2}, {"metal": "f", "content_pct": 0.0123}]'::jsonb)$q$,
              CURRENT_DATE - 2, pg_temp.id_('obA'))) ->> 'assay_result_id');
END $s$;
`, 'assay A')
    v = await run(`SELECT 'OUT|issue1|' || pg_temp.get_('iss', format($q$SELECT issue_coa(%L)$q$, pg_temp.id_('obA')))::text;
SELECT 'OUT|batchA|' || (SELECT code FROM output_batches WHERE id = pg_temp.id_('obA'));
SELECT 'OUT|assayA|' || (SELECT code FROM assay_results WHERE id = pg_temp.id_('aA'));
SELECT 'OUT|company|' || (SELECT legal_name FROM company_profile LIMIT 1);`, 'issue 1')
    const c1 = JSON.parse(v.issue1)
    const batchA = v.batchA, assayA = v.assayA, company = v.company
    must(/^COA-\d{4}-\d{4,}$/.test(c1.code) && c1.snapshot.sales_order === null && c1.snapshot.issuer.name === 'Lim (probe)'
        && c1.snapshot.issuer.position === 'Quality Manager (probe)' && c1.snapshot.assay.code === assayA && c1.snapshot.chemistry.certainty === 'mixed'
        && c1.snapshot.composition.length === 3, `the first certificate's snapshot: ${v.issue1.slice(0, 400)}`)
    console.log(`STEP|issued|${c1.code} on ${batchA} with no order: governing assay ${assayA} (${c1.snapshot.assay.basis}), feed chemistry ${c1.snapshot.chemistry.certainty_name}, issuer «${c1.snapshot.issuer.name}, ${c1.snapshot.issuer.position}»`)
    const s1 = await storeAndCheck(who.iss, c1, ['CERTIFICATE OF ANALYSIS', c1.code, batchA, assayA, `Issued by Lim (probe), Quality Manager (probe)`, company, 'Mixed'])

    // ══ ④ 签发,点名一张挂着带验收限合同的销售单 ══
    v = await run(String.raw`
DO $s$
DECLARE con uuid; so uuid; l1 uuid; tr uuid; v_j jsonb; v_msg text; d date := CURRENT_DATE;
BEGIN
    PERFORM pg_temp.as_('cco');
    INSERT INTO contracts (customer_id, kind, title, effective_from, status)
    VALUES (pg_temp.id_('cust'), 'offtake', 'ZZ-PROBE-MES6B2 offtake (moisture max 8)', DATE '2026-01-01', 'draft') RETURNING id INTO con;
    INSERT INTO contract_pricing_terms (contract_id, metal, base_event, qp_months, index_code, payable_pct) VALUES (con, 'ni', 'assay_complete', 0, 'LME', 70);
    INSERT INTO contract_settlement_terms (contract_id, sale_weight_basis, settling_party, sample_retention_required, refining_charge_basis, penalty_basis, quality_limit_basis)
    VALUES (con, 'dry', 'ours', false, 'none_agreed', 'none_agreed', 'per_parameter');
    INSERT INTO contract_quality_limits (contract_id, parameter, max_value, notes) VALUES (con, 'moisture_pct', 8, 'ZZ-PROBE-MES6B2');
    PERFORM pg_temp.me_();
    v_j := pg_temp.get_('cco', format($q$SELECT submit_contract_activation_request(%L, 'ZZ-PROBE-MES6B2')$q$, con));
    tr := (v_j ->> 'request_id')::uuid;
    v_msg := pg_temp.try_('cfo', format($q$SELECT decide_terms_request(%L, true)$q$, tr));
    IF v_msg <> 'OK' OR (SELECT status FROM contracts WHERE id = con) <> 'active' THEN RAISE EXCEPTION 'MES6B2_LIVE|activating the probe contract: % / %', v_j, v_msg; END IF;
    PERFORM pg_temp.as_('sal');
    so := (create_sales_order(pg_temp.id_('cust'), d - 4, (SELECT code FROM currencies WHERE is_base), 1,
                              jsonb_build_array(jsonb_build_object('material_id', pg_temp.id_('mat'), 'quantity', 500, 'unit_price', 1)), 'ZZ-PROBE-MES6B2') ->> 'id')::uuid;
    SELECT id INTO l1 FROM sales_order_lines WHERE sales_order_id = so;
    PERFORM set_sales_order_status(so, 'confirmed');
    PERFORM link_document_to_contract('sales_order', so, con);
    PERFORM pg_temp.me_();
    v_j := pg_temp.get_('sal', format($q$SELECT reserve_stock(%L, %L, 500)$q$, l1, pg_temp.id_('obA')));
    IF (SELECT result FROM quality_limit_judgements WHERE output_batch_id = pg_temp.id_('obA') AND sales_order_id = so) IS DISTINCT FROM 'within' THEN
        RAISE EXCEPTION 'MES6B2_LIVE|reserving should judge moisture 6.4 within ≤ 8, got %', v_j;
    END IF;
    PERFORM pg_temp.put_('so', so::text); PERFORM pg_temp.put_('con', con::text);
    RAISE NOTICE 'STEP|order|% activated through the CFO (moisture ≤ 8) · % linked and confirmed · sal reserved 500 kg of % → judged within (6.4 ≤ 8)',
        (SELECT code FROM contracts WHERE id = con), (SELECT code FROM sales_orders WHERE id = so), (SELECT code FROM output_batches WHERE id = pg_temp.id_('obA'));
END $s$;
SELECT 'OUT|soCode0|' || (SELECT code FROM sales_orders WHERE id = pg_temp.id_('so'));
`, 'order')
    // 签发之前的字体一问(路由 POST 的第 ⓪ 步):客户名里一个纸上画不出来的「≤」→ 拒,什么都没签
    v = await run(String.raw`
UPDATE customers SET legal_name = 'ZZ-PROBE-MES6B2 Buyer ≤ Pte Ltd' WHERE id = pg_temp.id_('cust');
SELECT 'OUT|pre|' || pg_temp.get_('iss', format($q$SELECT coa_certificate_data(%L, %L)$q$, pg_temp.id_('obA'), pg_temp.id_('so')))::text;
UPDATE customers SET legal_name = 'ZZ-PROBE-MES6B2 Buyer Pte Ltd' WHERE id = pg_temp.id_('cust');
SELECT 'OUT|coasBefore|' || (SELECT count(*) FROM certificates_of_analysis);
`, 'font pre-check')
    const why = coaUnrenderable(JSON.parse(v.pre))
    must(why && why.includes('≤') && v.coasBefore === '1', `the pre-issue font check should refuse «≤» before anything is issued: ${why} / ${v.coasBefore}`)
    console.log(`STEP|font|a customer name with «≤» → the route's pre-issue check refuses before issue_coa («${why.split('\n').find((l) => l.includes('≤'))?.trim()}»); certificates still ${v.coasBefore}; name restored`)
    v = await run(String.raw`
SELECT 'OUT|issue2|' || pg_temp.get_('iss', format($q$SELECT issue_coa(%L, %L)$q$, pg_temp.id_('obA'), pg_temp.id_('so')))::text;
SELECT 'OUT|dup|' || pg_temp.try_('iss', format($q$SELECT issue_coa(%L, %L)$q$, pg_temp.id_('obA'), pg_temp.id_('so')));
SELECT 'OUT|soCode|' || (SELECT code FROM sales_orders WHERE id = pg_temp.id_('so'));
SELECT 'OUT|conCode|' || (SELECT code FROM contracts WHERE id = pg_temp.id_('con'));
`, 'issue 2')
    const c2 = JSON.parse(v.issue2)
    const so2 = c2.snapshot.sales_order
    must(so2 && so2.customer_name === 'ZZ-PROBE-MES6B2 Buyer Pte Ltd' && so2.code === v.soCode && so2.contract_code === v.conCode
        && so2.quality_limit_basis === 'per_parameter' && so2.limits.length === 1 && so2.limits[0].parameter === 'moisture_pct'
        && Number(so2.limits[0].max_value) === 8 && so2.judgements.length === 1 && so2.judgements[0].result === 'within',
        `the order section of ${c2.code}: ${JSON.stringify(so2).slice(0, 400)}`)
    must(v.dup === `COA_ALREADY_ISSUED|${c2.code}`, `one live certificate per batch × order: «${v.dup}»`)
    console.log(`STEP|issued|${c2.code} on ${batchA} for ${v.soCode}: customer «${so2.customer_name}», contract ${so2.contract_code}, limit moisture ≤ 8 %, judgement within · a second one for the same batch × order refused «${v.dup}»`)
    const s2 = await storeAndCheck(who.iss, c2, [c2.code, 'ZZ-PROBE-MES6B2 Buyer Pte Ltd', v.soCode, v.conCode, 'Moisture', 'Within limits'])

    // ══ ⑤ 冻住:改活数据(客户改名、再记一份化验)—— 快照与字节都不动;预览读活数据 ══
    v = await run(String.raw`
UPDATE customers SET legal_name = 'ZZ-PROBE-MES6B2 Renamed Buyer' WHERE id = pg_temp.id_('cust');
SELECT 'OUT|snapSame|' || ((SELECT snapshot FROM certificates_of_analysis WHERE code = ${lit(c2.code)}) = ${lit(JSON.stringify(c2.snapshot))}::jsonb)::text;
SELECT 'OUT|preview|' || (pg_temp.get_('view', format($q$SELECT coa_certificate_data(%L, %L)$q$, pg_temp.id_('obA'), pg_temp.id_('so'))) -> 'sales_order' ->> 'customer_name');
SELECT 'OUT|recSha|' || (SELECT sha256 FROM coa_issues i JOIN certificates_of_analysis c ON c.id = i.coa_id WHERE c.code = ${lit(c2.code)});
`, 'frozen')
    must(v.snapSame === 'true', 'the stored snapshot changed after a live rename')
    must(v.preview === 'ZZ-PROBE-MES6B2 Renamed Buyer', `the preview should read live data, got «${v.preview}»`)
    const again = await download(who.iss.token, s2.path)
    const againText = pdfText(again.buf).text
    must(sha(again.buf) === s2.digest && v.recSha === s2.digest && againText.includes('ZZ-PROBE-MES6B2 Buyer Pte Ltd') && !againText.includes('Renamed'),
        'the stored PDF changed after a live rename')
    console.log(`STEP|frozen|customer renamed live → ${c2.code}: snapshot identical, stored bytes identical (sha ${s2.digest.slice(0, 12)}…), the paper still says «ZZ-PROBE-MES6B2 Buyer Pte Ltd» · the preview (live data) now says «${v.preview}»`)

    // ══ ⑥ 改坏字节 → 哈希对不上(路由的 409 那一支)══
    const orig1 = await download(who.iss.token, s1.path)
    const tampered = Buffer.concat([orig1.buf, Buffer.from('\n% tampered\n')])
    const put = await upload(null, s1.path, tampered, { asService: true, upsert: true })
    must(put.status === 200, `service-role overwrite for the tamper test: HTTP ${put.status} ${put.text}`)
    const bad = await download(who.iss.token, s1.path)
    v = await run(`SELECT 'OUT|rec1|' || (SELECT sha256 FROM coa_issues i JOIN certificates_of_analysis c ON c.id = i.coa_id WHERE c.code = ${lit(c1.code)});
SELECT 'OUT|size1|' || (SELECT metadata ->> 'size' FROM storage.objects WHERE bucket_id = 'coa-documents' AND name = ${lit(s1.path)});`, 'tamper')
    must(Number(v.size1) === tampered.length, `the overwrite should have changed the stored object: size ${v.size1}, sent ${tampered.length}`)
    must(bad.status === 200 && sha(bad.buf) !== v.rec1 && v.rec1 === s1.digest, `the altered bytes should no longer match the recorded digest (download ${bad.status}, ${bad.buf.length} bytes)`)
    console.log(`STEP|tampered|${c1.code}: bytes overwritten with the service role (+12 bytes) → downloaded sha ${sha(bad.buf).slice(0, 12)}… ≠ recorded ${v.rec1.slice(0, 12)}… → the route answers 409 (app/output/[id]/coa/pdf/route.tsx: sha !== issue.sha256)`)

    // ══ ⑦ 桶的删除策略:记下了的删不掉;没记下的(签发时记哈希失败的孤儿)签发人删得掉 ══
    const orphan = `${c1.coa_id}/${randomUUID()}.pdf`
    planObjectDelete(orphan)
    const upO = await upload(who.iss.token, orphan, Buffer.from('%PDF-1.4\n% orphan probe\n'))
    must(upO.status === 200, `uploading an orphan as the issuer: HTTP ${upO.status} ${upO.text}`)
    v = await run(String.raw`
SELECT set_config('storage.allow_delete_query', 'true', true) \g /dev/null
-- 在一个【一定回滚】的子事务里删:读出删了几行,然后连同那几行的行锁一起撤掉(否则下面 Storage API 那一次删孤儿会排在我的行锁后面)
CREATE FUNCTION pg_temp.del_(p_who text, p_name text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE n bigint; r text;
BEGIN
    BEGIN
        PERFORM pg_temp.as_(p_who);
        DELETE FROM storage.objects WHERE bucket_id = 'coa-documents' AND name = p_name;
        GET DIAGNOSTICS n = ROW_COUNT;
        RAISE EXCEPTION 'MES6B2_DELETED|%', n;
    EXCEPTION WHEN OTHERS THEN
        r := SQLERRM;
    END;
    PERFORM pg_temp.me_();
    RETURN CASE WHEN r LIKE 'MES6B2_DELETED|%' THEN split_part(r, '|', 2) ELSE r END;
END $f$;
SELECT 'OUT|delRecorded|' || pg_temp.del_('iss', ${lit(s2.path)});
SELECT 'OUT|delView|' || pg_temp.del_('view', ${lit(orphan)});
SELECT 'OUT|delOrphan|' || pg_temp.del_('iss', ${lit(orphan)});
SELECT 'OUT|stillThere|' || (SELECT count(*) FROM storage.objects WHERE bucket_id = 'coa-documents' AND name = ${lit(s2.path)});
SELECT set_config('storage.allow_delete_query', '', true) \g /dev/null
`, 'delete policy')
    must(v.delRecorded === '0' && v.stillThere === '1', `a recorded object must not be deletable by the issuer: deleted ${v.delRecorded}, still there ${v.stillThere}`)
    must(v.delView === '0', `a reader without action.issue_coa must not delete an orphan: ${v.delView}`)
    must(v.delOrphan === '1', `the issuer should be able to delete an unrecorded orphan: ${v.delOrphan}`)
    const rmO = await removeAs(who.iss.token, [orphan])
    must(rmO.status === 200 && rmO.removed === 1, `removing the orphan through the Storage API as the issuer: HTTP ${rmO.status}, removed ${rmO.removed}`)
    console.log(`STEP|bucket policy|as the issuer, a DELETE of ${c2.code}'s recorded object touches 0 rows (it stays) · a reader without the code deletes 0 · an unrecorded orphan: the issuer deletes 1 in SQL (rolled back) and removes it through the Storage API (HTTP ${rmO.status}, 1 removed)`)

    // ══ ⑧ 作废:只经 CFO 申请;快照与字节都留着;重开一张,旧的指向它 ══
    v = await run(String.raw`
SELECT 'OUT|direct|' || pg_temp.try_('iss', format($q$SELECT void_coa_internal(%L, 'x')$q$, (SELECT id FROM certificates_of_analysis WHERE code = ${lit(c2.code)})));
SELECT 'OUT|wr|' || pg_temp.get_('iss', format($q$SELECT submit_coa_void_request(%L, 'ZZ-PROBE-MES6B2 a newer final assay was received')$q$, (SELECT id FROM certificates_of_analysis WHERE code = ${lit(c2.code)})))::text;
SELECT 'OUT|self|' || pg_temp.try_('iss', format($q$SELECT decide_warehouse_request(%L, true)$q$, (SELECT id FROM warehouse_requests WHERE kind = 'coa_void' AND status = 'submitted')));
SELECT 'OUT|stillIssued|' || (SELECT status FROM certificates_of_analysis WHERE code = ${lit(c2.code)});
SELECT 'OUT|decide|' || pg_temp.get_('cfo', format($q$SELECT decide_warehouse_request(%L, true, 'ZZ-PROBE-MES6B2')$q$, (SELECT id FROM warehouse_requests WHERE kind = 'coa_void' AND status = 'submitted')))::text;
SELECT 'OUT|after|' || (SELECT to_jsonb(x) FROM (SELECT c.status, c.void_reason, c.voided_by = pg_temp.uid_('iss') AS voided_by_raiser,
        c.snapshot = ${lit(JSON.stringify(c2.snapshot))}::jsonb AS snapshot_kept,
        (SELECT sha256 FROM coa_issues i WHERE i.coa_id = c.id) AS sha FROM certificates_of_analysis c WHERE c.code = ${lit(c2.code)}) x)::text;
SELECT 'OUT|reissue|' || pg_temp.get_('iss', format($q$SELECT issue_coa(%L, %L)$q$, pg_temp.id_('obA'), pg_temp.id_('so')))::text;
SELECT 'OUT|link|' || (SELECT r.code FROM certificates_of_analysis c JOIN certificates_of_analysis r ON r.id = c.replaced_by_coa_id WHERE c.code = ${lit(c2.code)});
`, 'void')
    const wr = JSON.parse(v.wr), dec = JSON.parse(v.decide), aft = JSON.parse(v.after), c3 = JSON.parse(v.reissue)
    must(/permission denied/.test(v.direct), `a one-step void must be refused: «${v.direct}»`)
    must(wr.status === 'submitted' && v.stillIssued === 'issued', `the void request should wait and the certificate stay issued: ${v.wr} / ${v.stillIssued}`)
    must(v.self !== 'OK', `the raiser must not approve: «${v.self}»`)
    must(dec.status === 'approved' && aft.status === 'void' && aft.voided_by_raiser === true && aft.snapshot_kept === true && aft.sha === s2.digest,
        `the CFO approval voids it, keeps snapshot and bytes: ${v.decide} / ${v.after}`)
    const keep = await download(who.iss.token, s2.path)
    must(keep.status === 200 && sha(keep.buf) === s2.digest, 'the voided certificate\'s bytes should still be there, unchanged')
    must(c3.replaces === c2.code && v.link === c3.code && c3.code !== c2.code, `the replacement: ${v.reissue.slice(0, 200)} / link ${v.link}`)
    console.log(`STEP|void|a direct void_coa_internal as the issuer: «${v.direct.slice(0, 60)}» · iss raised ${wr.label ?? 'a coa_void request'} → submitted, ${c2.code} still issued · iss approving it: «${v.self.slice(0, 50)}» · the cfo throwaway approved → ${c2.code} void, voided_by = the raiser, snapshot kept, bytes kept (sha ${s2.digest.slice(0, 12)}…, still downloadable) · reissued → ${c3.code}, ${c2.code}.replaced_by → ${v.link}`)

    // ══ ⑨ 提醒:签发之后多一份化验 → coa_facts_changed;只给持 action.issue_coa 的人 ══
    v = await run(String.raw`
-- 这一份由属主直插、created_at = clock_timestamp():整个证明是一笔事务,record_assay_result 落下的 created_at = now() 是事务开始时刻,
--   早于两张证书的签发时刻 —— 而这一支问的正是"签发【之后】多了一份"(与 fixture 264 的 f264_assay 同一个理由)
INSERT INTO assay_results (code, output_batch_id, assay_date, is_final, weight_basis, moisture_pct, result_party, certificate_ref, created_at)
VALUES ('ZZ-PROBE-MES6B2-LATER', pg_temp.id_('obA'), CURRENT_DATE, true, 'dry', 6.6, 'ours', 'ZZ-PROBE-MES6B2-LATER', clock_timestamp());
SELECT 'OUT|armIss|' || pg_temp.get_('iss', format($q$SELECT to_jsonb(array_agg(o.item_code ORDER BY o.item_code)) FROM operations_now o WHERE o.item_type = 'coa_facts_changed' AND o.subject LIKE %L$q$, ${lit(batchA + ' · %')}))::text;
SELECT 'OUT|armView|' || pg_temp.get_('view', $q$SELECT to_jsonb(count(*)) FROM operations_now o WHERE o.item_type = 'coa_facts_changed'$q$)::text;
`, 'arm')
    const arm = JSON.parse(v.armIss)
    must(Array.isArray(arm) && arm.includes(c1.code) && arm.includes(c3.code) && !arm.includes(c2.code), `coa_facts_changed for the issuer: ${v.armIss}`)
    must(v.armView === '0', `a reader without action.issue_coa sees ${v.armView} coa_facts_changed rows`)
    console.log(`STEP|reminder|a newer assay on ${batchA} → coa_facts_changed lists ${arm.join(', ')} for the issuer (the void ${c2.code} is not listed) · a reader without action.issue_coa: 0`)

    // ══ ⑩ 逐角色读数表(七个真角色【此刻的码】的克隆,只读)══
    for (const r of ROLE_CLONES) {
        const key = `c_${r}`
        v = await run(String.raw`
DO $s$
DECLARE v_cert bigint; v_bytes bigint; v_rows bigint; v_listed bigint; v_issue boolean; v_raise boolean;
BEGIN
    PERFORM pg_temp.as_(${lit(key)});
    SELECT count(*) INTO v_rows FROM coa_rows WHERE output_batch_id = pg_temp.id_('obA');
    SELECT count(*) INTO v_cert FROM certificates_of_analysis WHERE code = ${lit(c1.code)};
    SELECT count(*) INTO v_bytes FROM coa_issues i JOIN certificates_of_analysis c ON c.id = i.coa_id WHERE c.code = ${lit(c1.code)};
    v_issue := has_permission('action.issue_coa');
    PERFORM pg_temp.me_();
    v_listed := (pg_temp.get_(${lit(key)}, $q$SELECT to_jsonb(count(*)) FROM warehouse_requests_visible(10) w WHERE w.kind = 'coa_void'$q$))::text::bigint;
    v_raise := pg_temp.would_(${lit(key)}, format($q$SELECT submit_coa_void_request(%L, 'ZZ-PROBE-MES6B2 role probe')$q$,
                (SELECT id FROM certificates_of_analysis WHERE code = ${lit(c3.code)}))) = 'OK';
    INSERT INTO p6_roles VALUES (${lit(key)}, ${lit(r)}, (SELECT count(*) FROM role_permissions rp JOIN roles ro ON ro.id = rp.role_id WHERE ro.code = ${lit(r)}),
                                 v_rows, v_cert, v_bytes, v_issue, v_listed, v_raise);
END $s$;
SELECT 'OUT|row|' || (SELECT to_jsonb(x) FROM p6_roles x WHERE who = ${lit(key)})::text;
`, `role ${r}`)
        const row = JSON.parse(v.row)
        const dl = await download(who[key].token, s2.path)
        row.download = dl.status === 200 && sha(dl.buf) === s2.digest
        console.log(`ROLE|${r}|codes ${row.codes}|batch-page certificates ${row.coa_rows}|certificate row ${row.cert_row}|byte record ${row.bytes_row}|storage download ${row.download ? 'yes' : `no (HTTP ${dl.status})`}|issue ${row.issue ? 'yes' : 'no'}|coa_void requests in the CFO list ${row.request_listed}|may raise a void ${row.raise_void ? 'yes' : 'no'}`)
    }

    // ══ ⑪ 在册的东西一个字都没动;收尾 ══
    v = await run(String.raw`
DO $s$
DECLARE v_rec text;
BEGIN
    IF pg_temp.fp_(pg_temp.val_('t0')::timestamptz) IS DISTINCT FROM pg_temp.val_('fp') THEN
        RAISE EXCEPTION 'MES6B2_LIVE|a pre-existing batch, assay, dispute, report, judgement, certificate of destruction, request, approval, run, movement, order, reservation, contract, term, customer, supplier, material, employee, position, journal, payment, expense, permission, grant or setting changed';
    END IF;
    IF (SELECT COALESCE(string_agg(subject_type || ':' || code, ',' ORDER BY code), '') FROM approval_pending_documents()) <> pg_temp.val_('pending') THEN
        RAISE EXCEPTION 'MES6B2_LIVE|pending documents changed';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN RAISE EXCEPTION 'MES6B2_LIVE|require_calibrated_since set'; END IF;
    IF NOT approvals_enabled() THEN RAISE EXCEPTION 'MES6B2_LIVE|approvals switched off'; END IF;
    v_rec := pg_temp.agree_('end');
    RAISE NOTICE 'STEP|untouched|pre-existing rows identical; pending «%»; approvals on; require_calibrated_since NULL; reconciliation %', pg_temp.val_('pending'), v_rec;
    RAISE NOTICE 'STEP|done|%', clock_timestamp() - pg_temp.val_('t0')::timestamptz;
END $s$;
ROLLBACK;
SELECT 'OUT|afterDb|' || 'certificates=' || (SELECT count(*) FROM certificates_of_analysis) || ' · byte records=' || (SELECT count(*) FROM coa_issues)
    || ' · coa_void requests=' || (SELECT count(*) FROM warehouse_requests WHERE kind = 'coa_void')
    || ' · probe rows=' || ((SELECT count(*) FROM customers WHERE code LIKE 'ZZ-PROBE-MES6B2%') + (SELECT count(*) FROM materials WHERE code LIKE 'ZZ-PROBE-MES6B2%')
                            + (SELECT count(*) FROM employees WHERE code LIKE 'ZZ-PROBE-MES6B2%') + (SELECT count(*) FROM positions WHERE code LIKE 'ZZ-PROBE-MES6B2%')
                            + (SELECT count(*) FROM output_batches WHERE notes LIKE 'ZZ-PROBE-MES6B2%') + (SELECT count(*) FROM contracts WHERE title LIKE 'ZZ-PROBE-MES6B2%'))
    || ' · require_calibrated_since=' || COALESCE((SELECT require_calibrated_since::text FROM ingest_settings), 'NULL')
    || ' · approvals=' || approvals_enabled()::text;
`, 'close')
    console.log(`AFTER|database (after ROLLBACK): ${v.afterDb}`)
    psql.stdin.end()

    // 桶:按计划删掉每一个上传过的对象,再读回
    // 计划由 exitAfterCleanup 统一再跑一遍(404 = 已经没了);这里先自己删一遍,好在判决之前读回桶空
    const { URL, SERVICE } = env()
    for (const p of [s1.path, s2.path]) {
        const r = await fetch(`${URL}/storage/v1/object/${BUCKET}/${p}`, { method: 'DELETE', headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}` } })
        must(r.ok || r.status === 404, `removing ${p}: HTTP ${r.status}`)
    }
    const left = await listBucketAsService()
    const leftSql = spawnSync('psql', ['-X', '-At', '-c', `SELECT count(*) FROM storage.objects WHERE bucket_id = '${BUCKET}'`, DSN], { encoding: 'utf8' })
    bucketVerdict = `${left.length} top-level entries (Storage API listing) · ${leftSql.stdout.trim()} rows in storage.objects`
    must(left.length === 0 && leftSql.stdout.trim() === '0', `the bucket is not empty after the proof: ${bucketVerdict}`)
    console.log('✓ 证明走完(STEP|done),事务已回滚,桶里 0 个对象')
    return exitAfterCleanup(0)
}

// 失败时先结束那笔事务(杀掉 psql、等它退出 —— 服务端随之回滚、放锁),再收账号:事务里那条员工行持着账号那一行的锁,
//   不先放,删账号会排在锁后面直到超时(第一次实跑撞上过,退 6)
async function endTransaction() {
    if (!psql || psql.exitCode !== null) return
    const gone = new Promise((r) => psql.once('exit', r))
    psql.kill('SIGTERM')
    await Promise.race([gone, new Promise((r) => setTimeout(r, 10_000))])
}
main().catch(async (e) => {
    console.error('✗ ' + (e?.stack || e))
    await endTransaction()
    return exitAfterCleanup(String(e?.message || '').startsWith('MES6B2_') ? 1 : 2)
})
