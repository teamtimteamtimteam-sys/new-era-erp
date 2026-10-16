#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// MES-8a(2026-10-16)· 线上验证 —— 供应商评分卡与供应商对账单:一笔【回滚】的事务 + 私有桶 supplier-statement-documents 里【事后删干净】的对象
// ════════════════════════════════════════════════════════════════════════════
// 形状照 db/scripts/2026-10-15-mes6b2-live-proof.mjs(分析证书那一支):对账单的字节在【桶】里,而桶的写入不随事务回滚。
//   所以这一支是一个【常开的 psql 子进程】(一笔事务从头开到尾),中间由本进程:
//     · 照 issue_supplier_statement 在事务里写下的【那一行】渲染 PDF(app/finance/supplier-statements/[id]/pdf/renderStatement.ts,
//       与路由同一支 —— 入参只有那一行);
//     · 以签发人的一次性账号经 Storage API 上传(桶的 INSERT 策略:module.finance.edit —— 一次性角色的授权是已提交的);
//     · 回到事务里 record_supplier_statement_issue 记哈希(大写送、小写存);再以只读账号经 Storage API 下载、重算 sha256、用 pypdf 读纸上的字;
//     · 以 service role 覆盖那份字节(模拟被改过的档案)→ 再下载 → 哈希对不上 = 路由的 409 那一支(route.ts:sha !== issue.sha256);
//     · 收尾:每一个上传过的对象都在上传【之前】登记了删除步(scripts/ephemeral.mjs 的计划),最后删掉,再读回桶里 0 个对象、
//       销毁证书的桶 cod-documents 与开场逐字相同(本证明不碰它;F17 那一段只走库)。
//   为什么桶的断言不是 fixture:AGENTS.md「存储桶与它的策略不在镜像里」。
//
// 【身份】每一个动作都以一次性账号跑(前缀 mes8aprobe),七个真账号一个都不用:
//   inv = 布景(收货、采购单、费用、不合格报告、化验与争议)—— 持 permissions 表里每一个码的一次性角色('all';不是 admin,也不是任何真角色)
//   rev = 评审人(module.suppliers.view · action.supplier_review)—— 设 V23 / V24、记评审、更正
//   cfo = 真的 cfo 角色本身(realRole)—— 只为【决定】收货定价申请(审批开着:定价要 CFO 批,批了才进总账)
//   fe  = 签发对账单、记 PDF(module.finance.view · .edit · data.view_purchase_prices · module.inbound.view)
//   fv  = 只读财务(module.finance.view · data.view_purchase_prices · module.inbound.view)—— 下载 PDF
//   cod = 销毁证书签发人(action.issue_cod · module.inbound.view)—— F17
//   c_<角色> = 七个真账号此刻持有的七个角色的码的克隆(cloneOf,只读;c_cfo 读两条勾稽)
// 【布景】都是我自己的行(前缀 ZZ-PROBE-MES8A),在事务里插,随回滚消失。在册的东西一行都不改、不决定、不删;收货的阈值、公司资料、
//   财务设定一样都不碰(收货差异的阈值读线上的,数量按它挑)。
// 【判决】只从日志里最后那一行 `MES8A_PROOF_EXIT=` 读(exitAfterCleanup 的 onFinish 打的)。
//   0 = 证明走完(STEP|done)且收尾读回桶空 · 1 = 证明红了 · 2 = 驱动自己坏了 · 5 = live-lock 被占 · 6 = 收尾没完成。
// 用法:node db/scripts/2026-10-16-mes8a-live-proof.mjs > <log> 2>&1
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
const BUCKET = 'supplier-statement-documents'
const COD_BUCKET = 'cod-documents'
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
        console.log(`AFTER|buckets: ${bucketVerdict}`)
        console.log(`MES8A_PROOF_EXIT=${code}`)
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
    const mark = `@@MES8A_DONE_${++seq}@@`
    const from = out.length
    psql.stdin.write(`${sqlText}\n\\echo ${mark}\n`)
    const t0 = Date.now()
    while (!out.includes(mark, from)) {
        if (psql.exitCode !== null) {
            throw new Error(`MES8A_SQL|${label}|psql exited ${psql.exitCode}:\n${err.split('\n').slice(-20).join('\n')}`)
        }
        if (Date.now() - t0 > 360_000) throw new Error(`MES8A_SQL|${label}|no answer within 360s`)
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

// ── Storage API(以一次性账号的 token;service role 只用来列桶、"改坏字节"与收尾)──────
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
    // 一次性的查询串:同一路径的已认证下载会被存储那一侧的缓存接住(MES-6b-2 实测)
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
async function listAsService(bucket, prefix = '') {
    const { URL, SERVICE } = env()
    const r = await fetch(`${URL}/storage/v1/object/list/${bucket}`, {
        method: 'POST', headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ prefix, limit: 1000 }),
    })
    const j = await r.json().catch(() => null)
    if (!r.ok || !Array.isArray(j)) throw new Error(`MES8A_BUCKET|list ${bucket} HTTP ${r.status} ${JSON.stringify(j).slice(0, 200)}`)
    return j
}
// 一个桶此刻的样子(SQL 一侧,名字 · 大小 · eTag)—— 开场与收尾各读一次,逐字比
function bucketFingerprint(bucket) {
    const r = spawnSync('psql', ['-X', '-At', '-c',
        `SELECT count(*) || ':' || COALESCE(md5(string_agg(name || '|' || COALESCE(metadata ->> 'size', '') || '|' || COALESCE(metadata ->> 'eTag', ''), ',' ORDER BY name)), '-') FROM storage.objects WHERE bucket_id = ${lit(bucket)}`,
        DSN], { encoding: 'utf8' })
    if (r.status !== 0) throw new Error(`MES8A_BUCKET|fingerprint ${bucket}: ${r.stderr.slice(0, 200)}`)
    return r.stdout.trim()
}
const sha = (b) => createHash('sha256').update(b).digest('hex')
// 删对象的那一步先落盘(批量删除端点:对象已经没了它也回 200 —— MES-6b-2 的第一次补删实测)
function planObjectDelete(path) {
    planDelete(`/storage/v1/object/${BUCKET}`, `删证明上传的 ${BUCKET}/${path}`, ORDER.OTHER,
        { method: 'DELETE', body: JSON.stringify({ prefixes: [path] }) })
}
function pdfText(buf) {
    const f = join(scratch, `${randomUUID()}.pdf`)
    writeFileSync(f, buf)
    const r = spawnSync('python3', ['-c', 'import pypdf,sys\nr=pypdf.PdfReader(sys.argv[1])\nprint(len(r.pages))\nprint("\\n".join(p.extract_text() for p in r.pages))', f],
        { encoding: 'utf8' })
    if (r.status !== 0) throw new Error(`MES8A_PDF|pypdf could not read the bytes: ${r.stderr.slice(0, 300)}`)
    const [pages, ...rest] = r.stdout.split('\n')
    // 窄列里的字会折行 —— 空白归一再比(比的是字,不是排版;check-pdf-routes 的同一个办法)
    return { pages: Number(pages), text: rest.join('\n').replace(/\s+/g, ' ') }
}
function must(cond, msg) { if (!cond) throw new Error(`MES8A_LIVE|${msg}`) }

// ── 渲染:与路由同一支(renderStatement.ts),入参只有那一行 ───────────────────────
let statementDocFrom = null
let renderSupplierStatementPdf = null
async function loadRenderer() {
    const { createJiti } = await import('jiti')
    const React = (await import('react')).default
    globalThis.React = React // jiti 的 JSX 走经典运行时
    const jiti = createJiti(import.meta.url, { alias: { '@': ROOT }, jsx: true, interopDefault: true })
    const mod = await jiti.import(join(ROOT, 'app/finance/supplier-statements/[id]/pdf/renderStatement.ts'))
    statementDocFrom = mod.statementDocFrom
    renderSupplierStatementPdf = mod.renderSupplierStatementPdf
}

async function main() {
    const other = heldBy()
    if (other) {
        console.error(`✗ live-lock 被【${other.holder}】(pid ${other.pid})占着 —— 等它跑完再来。`)
        return exitAfterCleanup(5)
    }
    acquireOrExit('db/scripts/2026-10-16-mes8a-live-proof.mjs', { ownExit: false })
    locked = true
    openPlan('db/scripts/2026-10-16-mes8a-live-proof.mjs')
    await reapStalePlans()
    scratch = mkdtempSync(join(tmpdir(), 'mes8a-proof-'))
    await loadRenderer()

    // 桶开跑前:对账单的桶是空的(本刀之前它不存在);销毁证书的桶记下样子,收尾逐字比
    const before = await listAsService(BUCKET)
    must(before.length === 0, `bucket ${BUCKET} already holds ${before.length} object(s) before the proof — not mine, stopping`)
    const codBefore = bucketFingerprint(COD_BUCKET)
    const sstBefore = bucketFingerprint(BUCKET)
    console.log(`STEP|buckets before|${BUCKET}: Storage API 0 objects, SQL ${sstBefore} · ${COD_BUCKET}: SQL ${codBefore}`)

    const stamp = Date.now()
    const who = {}
    const mint = async (key, label, codes) => {
        const a = await mintThrowaway({ prefix: 'mes8aprobe', label, stamp, codes })
        who[key] = a
        console.log(`· ${key}: ${a.email} ← ${a.roleCode} (${a.codes.length} codes${Array.isArray(codes) ? ': ' + a.codes.join(', ') : ''})`)
    }
    await mint('inv', 'inv', 'all')
    await mint('rev', 'rev', ['module.suppliers.view', 'action.supplier_review'])
    await mint('cfo', 'cfo', { realRole: 'cfo' })
    await mint('fe', 'fe', ['module.finance.view', 'module.finance.edit', 'data.view_purchase_prices', 'module.inbound.view'])
    await mint('fv', 'fv', ['module.finance.view', 'data.view_purchase_prices', 'module.inbound.view'])
    await mint('cod', 'cod', ['action.issue_cod', 'module.inbound.view'])
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
CREATE TEMP TABLE p8 (k text PRIMARY KEY, v text) ON COMMIT DROP;
INSERT INTO p8 VALUES ${emails};
CREATE FUNCTION pg_temp.put_(p_k text, p_v text) RETURNS void LANGUAGE sql AS $f$
    INSERT INTO p8 VALUES (p_k, p_v) ON CONFLICT (k) DO UPDATE SET v = EXCLUDED.v $f$;
CREATE FUNCTION pg_temp.val_(p_k text) RETURNS text LANGUAGE sql AS $f$ SELECT v FROM p8 WHERE k = p_k $f$;
CREATE FUNCTION pg_temp.id_(p_k text) RETURNS uuid LANGUAGE sql AS $f$ SELECT v::uuid FROM p8 WHERE k = p_k $f$;
CREATE FUNCTION pg_temp.uid_(p_who text) RETURNS uuid LANGUAGE sql AS $f$
    SELECT u.id FROM auth.users u WHERE u.email = (SELECT v FROM p8 WHERE k = 'email.' || p_who) $f$;
CREATE FUNCTION pg_temp.as_(p_who text) RETURNS void LANGUAGE plpgsql AS $f$
DECLARE v_uid uuid; e text := (SELECT x.v FROM p8 x WHERE x.k = 'email.' || p_who);
BEGIN
    EXECUTE 'RESET ROLE';
    SELECT id INTO v_uid FROM auth.users WHERE email = e;
    IF v_uid IS NULL OR e NOT LIKE 'mes8aprobe-%@test.local' THEN RAISE EXCEPTION 'MES8A_LIVE|not a throwaway account: % (%)', p_who, e; END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_uid), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
END $f$;
-- 以 p_who 的身份但【不】切到 authenticated(内层引擎:批准过的付款申请执行时走的那一支 —— MES-5b-2 的先例)
CREATE FUNCTION pg_temp.claims_(p_who text) RETURNS void LANGUAGE plpgsql AS $f$
DECLARE e text := (SELECT x.v FROM p8 x WHERE x.k = 'email.' || p_who);
BEGIN
    EXECUTE 'RESET ROLE';
    IF e NOT LIKE 'mes8aprobe-%@test.local' THEN RAISE EXCEPTION 'MES8A_LIVE|not a throwaway account: %', p_who; END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', pg_temp.uid_(p_who)), true);
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
-- 以 p_who 的身份试一句,然后【一定】撤掉它做的事(子事务回滚):成 → 'OK',拒 → 那一句原话
CREATE FUNCTION pg_temp.would_(p_who text, p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE r text;
BEGIN
    BEGIN
        PERFORM pg_temp.as_(p_who);
        EXECUTE p_sql;
        RAISE EXCEPTION 'MES8A_WOULD_OK';
    EXCEPTION WHEN OTHERS THEN
        r := SQLERRM;
    END;
    PERFORM pg_temp.me_();
    RETURN CASE WHEN r = 'MES8A_WOULD_OK' THEN 'OK' ELSE r END;
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
-- 两条勾稽(以 cfo 的克隆读):应付 / 应收清单 = 总账,未解释 0.00
CREATE FUNCTION pg_temp.agree_(p_step text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE v jsonb; s jsonb; o text := '';
BEGIN
    v := pg_temp.get_('c_cfo', 'SELECT list_ledger_reconciliation()');
    IF jsonb_array_length(v -> 'sides') <> 2 THEN RAISE EXCEPTION 'MES8A_LIVE|reconciliation after %: expected two sides, got %', p_step, v; END IF;
    FOR s IN SELECT * FROM jsonb_array_elements(v -> 'sides') LOOP
        IF s ->> 'refusal' IS NOT NULL OR (s ->> 'unexplained_base')::numeric IS DISTINCT FROM 0 THEN
            RAISE EXCEPTION 'MES8A_LIVE|AP/AR list <> ledger after %: %', p_step, s;
        END IF;
        o := o || (s ->> 'side') || ' ' || (s ->> 'list_base') || ' / ' || (s ->> 'ledger_base') || ' / ' || (s ->> 'unexplained_base') || '; ';
    END LOOP;
    RAISE NOTICE 'STEP|recon %|%', p_step, o;
    RETURN o;
END $f$;
-- 在册的东西的指纹:我的行 created_at = 事务开始时刻(now()),按 < t0 排除
CREATE FUNCTION pg_temp.fp_(t0 timestamptz) RETURNS text LANGUAGE sql AS $f$
-- 每一段带名字(对不上时点名是哪一张表);我自己的行一律排除(created_at = 事务开始时刻 now(),按 < t0 排除;我自己的销毁证书与它的字节记录同样排除);supplier_score_settings 不在这里 —— 本证明在事务里设了它,回滚之后读回
SELECT concat_ws('#',
    'suppliers:' || COALESCE((SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM suppliers x WHERE x.created_at < t0), '-'),
    'supplier_compliance:' || COALESCE((SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM supplier_compliance x WHERE x.created_at < t0), '-'),
    'purchase_orders:' || COALESCE((SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM purchase_orders x WHERE x.created_at < t0), '-'),
    'purchase_order_lines:' || COALESCE((SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM purchase_order_lines x WHERE x.created_at < t0), '-'),
    'purchase_order_payment_terms:' || COALESCE((SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM purchase_order_payment_terms x WHERE x.created_at < t0), '-'),
    'inbound_batches:' || COALESCE((SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM inbound_batches x WHERE x.created_at < t0), '-'),
    'receipt_price_requests:' || COALESCE((SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM receipt_price_requests x WHERE x.created_at < t0), '-'),
    'assay_results:' || COALESCE((SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM assay_results x WHERE x.created_at < t0), '-'),
    'assay_disputes:' || COALESCE((SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM assay_disputes x WHERE x.created_at < t0), '-'),
    'nonconformance_reports:' || COALESCE((SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM nonconformance_reports x WHERE x.opened_at < t0), '-'),
    'certificates_of_destruction:' || COALESCE((SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM certificates_of_destruction x WHERE x.created_at < t0), '-'),
    'cod_issues:' || COALESCE((SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.cod_id)) FROM cod_issues x WHERE x.cod_id IN (SELECT id FROM certificates_of_destruction WHERE created_at < t0)), '-'),
    'approval_log:' || COALESCE((SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM approval_log x WHERE x.created_at < t0), '-'),
    'journal_entries:' || COALESCE((SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM journal_entries x WHERE x.created_at < t0), '-'),
    'journal_lines:' || COALESCE((SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM journal_lines x WHERE x.created_at < t0), '-'),
    'payments:' || COALESCE((SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM payments x WHERE x.created_at < t0), '-'),
    'payment_allocations:' || COALESCE((SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM payment_allocations x WHERE x.payment_id IN (SELECT id FROM payments WHERE created_at < t0)), '-'),
    'prepayment_applications:' || COALESCE((SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM prepayment_applications x WHERE x.created_at < t0), '-'),
    'expenses:' || COALESCE((SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM expenses x WHERE x.created_at < t0), '-'),
    'material_required_metals:' || COALESCE((SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.material_id, x.metal)) FROM material_required_metals x), '-'),
    'materials:' || COALESCE((SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM materials x WHERE x.created_at < t0), '-'),
    'employees:' || COALESCE((SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM employees x WHERE x.created_at < t0), '-'),
    'permissions:' || COALESCE((SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.code)) FROM permissions x), '-'),
    'role_permissions:' || COALESCE((SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.role_id, x.permission_code)) FROM role_permissions x
      WHERE x.role_id IN (SELECT id FROM roles WHERE code NOT LIKE 'probe-%')), '-'),
    'receiving_settings:' || COALESCE((SELECT md5(to_jsonb(x)::text) FROM receiving_settings x), '-'),
    'company_profile:' || COALESCE((SELECT md5(to_jsonb(x)::text) FROM company_profile x), '-'),
    'finance_settings:' || COALESCE((SELECT md5(to_jsonb(x)::text) FROM finance_settings x), '-'),
    'ingest_settings:' || COALESCE((SELECT md5(to_jsonb(x)::text) FROM ingest_settings x), '-'))
$f$;
GRANT EXECUTE ON FUNCTION pg_temp.as_(text), pg_temp.me_() TO authenticated;
GRANT SELECT ON p8 TO authenticated;
CREATE TEMP TABLE p8_roles (who text, role text, codes integer, suppliers_view boolean, supplier_review boolean, inbound_view boolean,
    finance_view boolean, finance_edit boolean, scorecard_rows bigint, reviews_seen bigint, preview text, advice text,
    statement_list bigint, statement_row bigint, issue_rows bigint, pending_v23 bigint, pending_v24 bigint, record_review text) ON COMMIT DROP;
GRANT INSERT ON p8_roles TO authenticated;
`, 'open')

    // ══ ⓪ 前提与布景 ══
    let v = await run(String.raw`
DO $s$
DECLARE
    v_t0 timestamptz := now(); PS date := CURRENT_DATE - 30; PE date := CURRENT_DATE; v_base text;
    sup uuid; mat uuid; po_a uuid; po_b uuid; l_a uuid; l_b uuid; ra uuid; rb uuid; rc uuid; x0 uuid; p1 uuid; p2 uuid;
    a1 uuid; a2 uuid; v_j jsonb; v_req uuid; v_short numeric;
BEGIN
    SELECT code INTO v_base FROM currencies WHERE is_base;
    IF NOT approvals_enabled() THEN RAISE EXCEPTION 'MES8A_LIVE|approvals are off on live'; END IF;
    IF EXISTS (SELECT 1 FROM supplier_scorecard_reviews) OR EXISTS (SELECT 1 FROM supplier_statements) OR EXISTS (SELECT 1 FROM supplier_statement_issues) THEN
        RAISE EXCEPTION 'MES8A_LIVE|live already has a review, a statement or a statement issue — this proof expects none';
    END IF;
    IF (SELECT count(*) FROM supplier_score_settings) <> 1 OR EXISTS (SELECT 1 FROM supplier_score_settings
            WHERE weights IS NOT NULL OR grade_lines IS NOT NULL OR review_window_days IS NOT NULL OR grade_caps IS NOT NULL) THEN
        RAISE EXCEPTION 'MES8A_LIVE|V23 / V24 are expected unset on live';
    END IF;
    IF (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         WHERE rp.permission_code = 'action.supplier_review' AND r.code NOT LIKE 'probe-%') IS DISTINCT FROM 'admin,cco' THEN
        RAISE EXCEPTION 'MES8A_LIVE|action.supplier_review should be held by exactly admin and cco';
    END IF;
    IF btrim(COALESCE((SELECT legal_name FROM company_profile LIMIT 1), '')) = '' THEN
        RAISE EXCEPTION 'MES8A_LIVE|live has no company legal name — a statement would be refused, and this proof does not edit the company profile';
    END IF;
    PERFORM pg_temp.put_('t0', v_t0::text);
    PERFORM pg_temp.put_('fp', pg_temp.fp_(v_t0));
    PERFORM pg_temp.put_('pending', (SELECT COALESCE(string_agg(subject_type || ':' || code, ',' ORDER BY code), '') FROM approval_pending_documents()));
    PERFORM pg_temp.put_('rec_start', pg_temp.agree_('start'));
    PERFORM pg_temp.put_('PS', PS::text); PERFORM pg_temp.put_('PE', PE::text);
    -- 短交要过线上的阈值:收一半(50%)总比线上的 grn_short_pct 大(读出来写进报告,不改它)
    SELECT grn_short_pct INTO v_short FROM receiving_settings LIMIT 1;
    IF v_short IS NOT NULL AND v_short >= 50 THEN RAISE EXCEPTION 'MES8A_LIVE|grn_short_pct on live is % — a half delivery would not read short', v_short; END IF;

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type, default_tax_code)
    VALUES ('ZZ-PROBE-MES8A-S', 'ZZ-PROBE-MES8A Cells Supplier Pte Ltd', 'SG', 'active', 'goods_supplier', 'OP') RETURNING id INTO sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, unit)
    VALUES ('ZZ-PROBE-MES8A-BM', 'ZZ-PROBE-MES8A black mass', 'battery_material', true, 'black_mass', 'end_of_life', 'kg') RETURNING id INTO mat;
    -- 两张已批的单(属主直插 —— 审批开着时 create_purchase_order 生成待批的单,收不了货;下面那张"超上限"的单走 create_purchase_order 本身)
    INSERT INTO purchase_orders (code, supplier_id, order_date, currency, fx_rate, estimated_total_ccy, status, approval_status, category)
    VALUES ('ZZ-PROBE-MES8A-POA', sup, PS, v_base, 1, 1000, 'confirmed', 'approved', 'equipment_goods') RETURNING id INTO po_a;
    INSERT INTO purchase_orders (code, supplier_id, order_date, currency, fx_rate, estimated_total_ccy, status, approval_status, category)
    VALUES ('ZZ-PROBE-MES8A-POB', sup, PS, v_base, 1, 1000, 'confirmed', 'approved', 'equipment_goods') RETURNING id INTO po_b;
    INSERT INTO purchase_order_lines (purchase_order_id, line_no, material_id, quantity, unit, estimated_unit_price, deep_discharge_judgement_code)
    VALUES (po_a, 1, mat, 100, 'kg', 10, 'can') RETURNING id INTO l_a;
    INSERT INTO purchase_order_lines (purchase_order_id, line_no, material_id, quantity, unit, estimated_unit_price)
    VALUES (po_b, 1, mat, 40, 'kg', 25) RETURNING id INTO l_b;
    PERFORM pg_temp.put_('sup', sup::text); PERFORM pg_temp.put_('mat', mat::text);
    PERFORM pg_temp.put_('po_a', po_a::text); PERFORM pg_temp.put_('po_b', po_b::text);

    PERFORM pg_temp.claims_('inv');
    -- 期初:期间之前一张挂账的费用单 400
    x0 := (record_expense(p_expense_date := PS - 5, p_account_code := '6400', p_amount := 400, p_currency := v_base,
                          p_payment_status := 'unpaid', p_supplier_id := sup, p_notes := 'ZZ-PROBE-MES8A opening bill') ->> 'expense_id')::uuid;
    PERFORM pg_temp.agree_('opening bill');
    PERFORM pg_temp.claims_('inv');   -- agree_ 以 cfo 的克隆读完会清掉身份(me_)—— 接着做布景之前把它设回来
    -- A 单收一半、不计价(短交 + 已收到尚未计价);到货的放电判断与采购时矛盾(我自己的那一行)
    ra := (create_inbound_batch(mat, sup, 50, 'kg', PS + 2, '待加工', NULL, 'ZZ-PROBE-MES8A half delivery', po_a, l_a,
                                p_source_reason_code => 'other', p_source_reason_note => 'ZZ-PROBE-MES8A', p_currency => v_base) ->> 'batch_id')::uuid;
    UPDATE inbound_batches SET deep_discharge_actual_code = 'cannot' WHERE id = ra;
    PERFORM close_purchase_order(po_a, 'ZZ-PROBE-MES8A short delivery accepted');
    -- 一张不挂单、带价的收货(20 × 30 = 600):审批开着 → 一张定价申请,CFO 批了才进总账
    rb := (create_inbound_batch(mat, sup, 20, 'kg', PS + 3, '待加工', 30, 'ZZ-PROBE-MES8A priced receipt',
                                p_source_reason_code => 'other', p_source_reason_note => 'ZZ-PROBE-MES8A', p_currency => v_base) ->> 'batch_id')::uuid;
    -- B 单:定金 300(预付)→ 收 40 × 25 = 1,000 → 定金冲抵
    PERFORM record_payment_internal('out', sup, 300, v_base, NULL, NULL, PS + 1, 'ZZ-PROBE-MES8A deposit',
        jsonb_build_array(jsonb_build_object('purchase_order_id', po_b, 'amount_doc', 300)), 'supplier');
    PERFORM pg_temp.agree_('deposit');
    PERFORM pg_temp.claims_('inv');   -- agree_ 以 cfo 的克隆读完会清掉身份(me_)—— 接着做布景之前把它设回来
    rc := (create_inbound_batch(mat, sup, 40, 'kg', PS + 4, '待加工', 25, 'ZZ-PROBE-MES8A PO receipt', po_b, l_b,
                                p_source_reason_code => 'other', p_source_reason_note => 'ZZ-PROBE-MES8A', p_currency => v_base) ->> 'batch_id')::uuid;
    PERFORM pg_temp.me_();
    PERFORM pg_temp.put_('ra', ra::text); PERFORM pg_temp.put_('rb', rb::text); PERFORM pg_temp.put_('rc', rc::text); PERFORM pg_temp.put_('x0', x0::text);
    RAISE NOTICE 'STEP|setup|own rows (prefix ZZ-PROBE-MES8A): supplier %, material, POs % / %, opening bill %, receipts % (half of A, unpriced) · % (priced, no order) · % (B); grn_short_pct on live %',
        (SELECT code FROM suppliers WHERE id = sup), (SELECT code FROM purchase_orders WHERE id = po_a), (SELECT code FROM purchase_orders WHERE id = po_b),
        (SELECT code FROM expenses WHERE id = x0), (SELECT code FROM inbound_batches WHERE id = ra), (SELECT code FROM inbound_batches WHERE id = rb),
        (SELECT code FROM inbound_batches WHERE id = rc), v_short;
END $s$;
SELECT 'OUT|reqs|' || (SELECT jsonb_agg(jsonb_build_object('id', r.id, 'batch', b.code, 'status', r.status) ORDER BY b.code)
                         FROM receipt_price_requests r JOIN inbound_batches b ON b.id = r.inbound_batch_id
                        WHERE b.id IN (pg_temp.id_('rb'), pg_temp.id_('rc')))::text;
`, 'setup')
    const reqs = JSON.parse(v.reqs)
    must(Array.isArray(reqs) && reqs.length === 2 && reqs.every((r) => r.status === 'submitted'),
        `with approvals on, the two priced receipts should each wait as a submitted price request: ${v.reqs}`)
    console.log(`STEP|pricing|approvals are on: ${reqs.map((r) => r.batch).join(' and ')} each wait as a submitted receipt price request`)

    // ══ ① 定价经 CFO 批 → 进总账(暂定价);冲抵定金;两笔付款 ══
    v = await run(String.raw`
DO $s$
DECLARE r record; v_base text; PS date := pg_temp.val_('PS')::date; v_j jsonb;
BEGIN
    SELECT code INTO v_base FROM currencies WHERE is_base;
    FOR r IN SELECT rq.id FROM receipt_price_requests rq WHERE rq.inbound_batch_id IN (pg_temp.id_('rb'), pg_temp.id_('rc')) AND rq.status = 'submitted' LOOP
        v_j := pg_temp.get_('cfo', format($q$SELECT decide_receipt_price_request(%L, true, 'ZZ-PROBE-MES8A')$q$, r.id));
    END LOOP;
    PERFORM pg_temp.agree_('receipts priced through the CFO');
    PERFORM pg_temp.claims_('inv');
    PERFORM apply_prepayment(pg_temp.id_('po_b'), pg_temp.id_('rc'), 300, 'ZZ-PROBE-MES8A', NULL, CURRENT_DATE);
    PERFORM pg_temp.me_();
    PERFORM pg_temp.agree_('prepayment applied');
    PERFORM pg_temp.claims_('inv');
    PERFORM pg_temp.put_('p1', (record_payment_internal('out', pg_temp.id_('sup'), 250, v_base, NULL, NULL, PS + 7, 'ZZ-PROBE-MES8A pay the priced receipt',
        jsonb_build_array(jsonb_build_object('inbound_batch_id', pg_temp.id_('rb'), 'amount_doc', 250))) ->> 'payment_id'));
    PERFORM pg_temp.me_();
    PERFORM pg_temp.agree_('payment applied');
    PERFORM pg_temp.claims_('inv');
    PERFORM pg_temp.put_('p2', (record_payment_internal('out', pg_temp.id_('sup'), 100, v_base, NULL, NULL, PS + 8, 'ZZ-PROBE-MES8A on account',
        '[]'::jsonb, 'supplier') ->> 'payment_id'));
    PERFORM pg_temp.me_();
    PERFORM pg_temp.agree_('payment on account');
    RAISE NOTICE 'STEP|ap|% and % priced by the cfo throwaway (provisional %/%) · deposit 300 applied to % · % pays 250 on % · % 100 on account',
        (SELECT code FROM inbound_batches WHERE id = pg_temp.id_('rb')), (SELECT code FROM inbound_batches WHERE id = pg_temp.id_('rc')),
        (SELECT pricing_status FROM inbound_batches WHERE id = pg_temp.id_('rb')), (SELECT pricing_status FROM inbound_batches WHERE id = pg_temp.id_('rc')),
        (SELECT code FROM inbound_batches WHERE id = pg_temp.id_('rc')), (SELECT code FROM payments WHERE id = pg_temp.val_('p1')::uuid),
        (SELECT code FROM inbound_batches WHERE id = pg_temp.id_('rb')), (SELECT code FROM payments WHERE id = pg_temp.val_('p2')::uuid);
END $s$;
`, 'ap activity')

    // ══ ② 不合格报告 · 化验争议(挂在没计价的那一张上)· 一张过期的证书(warn 类 —— 不挡后面的收货与下单)══
    v = await run(String.raw`
DO $s$
DECLARE a1 uuid; a2 uuid; PS date := pg_temp.val_('PS')::date;
BEGIN
    PERFORM pg_temp.put_('ncr', pg_temp.get_('inv', format($q$SELECT open_ncr('manual', 'ZZ-PROBE-MES8A wet cells in the half delivery', p_inbound_batch_id => %L)$q$, pg_temp.id_('ra'))) ->> 'code');
    a1 := (pg_temp.get_('inv', format($q$SELECT record_assay_result(p_assay_date => %L, p_metals => '[{"metal": "ni", "content_pct": 20}]'::jsonb, p_inbound_batch_id => %L,
              p_weight_basis => 'dry', p_result_party => 'ours')$q$, PS + 5, pg_temp.id_('ra'))) ->> 'assay_result_id')::uuid;
    a2 := (pg_temp.get_('inv', format($q$SELECT record_assay_result(p_assay_date => %L, p_metals => '[{"metal": "ni", "content_pct": 17}]'::jsonb, p_inbound_batch_id => %L,
              p_weight_basis => 'dry', p_result_party => 'counterparty')$q$, PS + 5, pg_temp.id_('ra'))) ->> 'assay_result_id')::uuid;
    PERFORM pg_temp.get_('inv', format($q$SELECT open_assay_dispute(%L, %L, 'ZZ-PROBE-MES8A nickel differs')$q$, a1, a2));
    INSERT INTO supplier_compliance (supplier_id, cert_type_code, cert_no, valid_from, valid_until)
    VALUES (pg_temp.id_('sup'), 'iso', 'ZZ-PROBE-MES8A-ISO', PS - 60, PS + 9);
    RAISE NOTICE 'STEP|quality|% open on the half delivery · a dispute between our 20%% Ni and their 17%% · ISO certificate valid until % (lapsed inside the window)',
        pg_temp.val_('ncr'), PS + 9;
END $s$;
`, 'quality')

    // ══ ③ 评分卡现算 · V23 没给 → 记一次评审 = "Not graded — V23 not set" ══
    v = await run(String.raw`
SELECT 'OUT|meas|' || pg_temp.get_('rev', format($q$SELECT supplier_scorecard_measures(%L, %L, %L)$q$, pg_temp.id_('sup'), pg_temp.val_('PS'), pg_temp.val_('PE')))::text;
SELECT 'OUT|v23|' || pg_temp.get_('c_admin', $q$SELECT to_jsonb(count(*)) FROM pending_values WHERE value_code = 'V23'$q$)::text;
SELECT 'OUT|rev0|' || pg_temp.get_('rev', format($q$SELECT record_supplier_review(%L, %L, %L, 'ZZ-PROBE-MES8A first look')$q$, pg_temp.id_('sup'), pg_temp.val_('PS'), pg_temp.val_('PE')))::text;
SELECT 'OUT|adv0|' || pg_temp.get_('rev', format($q$SELECT supplier_grade_advice(%L, '[{"trigger_event":"on_order","percentage":90}]', 1000)$q$, pg_temp.id_('sup')))::text;
SELECT 'OUT|vwReview|' || pg_temp.try_('c_gm', format($q$SELECT record_supplier_review(%L, %L, %L)$q$, pg_temp.id_('sup'), pg_temp.val_('PS'), pg_temp.val_('PE')));
`, 'measures')
    const m = JSON.parse(v.meas)
    const sc = m.scored
    must(m.receipts === 3 && m.receipts_without_po_line === 1, `three receipts in the window, one without an order line: ${v.meas.slice(0, 300)}`)
    must(sc.short_lines.count === 1 && sc.discharge_mismatches.count === 1 && sc.ncr_open.count === 1 && sc.disputes.count === 1
        && sc.certificate_lapse_days.count === 21 && sc.over_lines.count === 0,
        `measures: short 1, discharge 1, NCR open 1, dispute 1, lapse 21 days, over 0 — got ${JSON.stringify(sc)}`)
    must(m.shown.grade_breaches.scored === false && m.shown.grade_breaches.caveat === 'CONTRACT-1', `grade breaches shown, not scored: ${JSON.stringify(m.shown)}`)
    must(v.v23 === '1', `V23 is one pending row while unset, got ${v.v23}`)
    const r0 = JSON.parse(v.rev0), adv0 = JSON.parse(v.adv0)
    must(r0.not_graded_reason === 'V23_NOT_SET' && r0.grade === null, `with V23 unset the review is not graded: ${v.rev0}`)
    must(adv0.reviewed === true && adv0.graded === false && adv0.warnings.length === 0, `an ungraded review has no effect: ${v.adv0}`)
    must(v.vwReview === 'PERMISSION_DENIED|action.supplier_review', `the gm clone (view only) records a review: «${v.vwReview}»`)
    console.log(`STEP|measures|${m.supplier_code} ${m.window_from}…${m.window_to}: receipts ${m.receipts} (1 without a line) · short ${sc.short_lines.count}/${sc.short_lines.compared} compared · over 0 · discharge mismatch 1 · NCR open 1 · dispute 1 · certificate lapse 21 days · grade breaches shown ${m.shown.grade_breaches.count} (not scored, CONTRACT-1)`)
    console.log(`STEP|not graded|V23 pending rows 1 · the review reads «${r0.not_graded_reason}» with no grade · grade advice reviewed, not graded, 0 warnings · the gm clone: «${v.vwReview}»`)

    // ══ ④ 设 V23 / V24 → 评审 → 更正(带理由)══
    v = await run(String.raw`
SELECT 'OUT|w|' || (SELECT jsonb_object_agg(k, CASE k WHEN 'short_lines' THEN 3 WHEN 'over_lines' THEN 1 WHEN 'ncr_open' THEN 2 WHEN 'ncr_reject' THEN 5
        WHEN 'disputes' THEN 2 WHEN 'discharge_mismatches' THEN 1 WHEN 'certificate_lapse_days' THEN 0.1 ELSE 0 END) FROM unnest(supplier_scorecard_measure_keys()) k)::text;
SELECT 'OUT|set1|' || pg_temp.try_('rev', format($q$SELECT set_supplier_score_settings(%L, '[{"grade":"A","max_score":5},{"grade":"B","max_score":20},{"grade":"C","max_score":null}]', 90,
        '{"A":{"prepayment_cap_pct":50,"sampling_level":"Every 10th bag"},"B":{"prepayment_cap_pct":30,"sampling_level":"Every 5th bag"}}')$q$,
        (SELECT jsonb_object_agg(k, CASE k WHEN 'short_lines' THEN 3 WHEN 'over_lines' THEN 1 WHEN 'ncr_open' THEN 2 WHEN 'ncr_reject' THEN 5
        WHEN 'disputes' THEN 2 WHEN 'discharge_mismatches' THEN 1 WHEN 'certificate_lapse_days' THEN 0.1 ELSE 0 END) FROM unnest(supplier_scorecard_measure_keys()) k)));
SELECT 'OUT|v24|' || pg_temp.get_('c_admin', $q$SELECT jsonb_agg(value_code || ':' || item_code ORDER BY value_code, item_code) FROM pending_values WHERE value_code IN ('V23', 'V24')$q$)::text;
SELECT 'OUT|rev1|' || pg_temp.get_('rev', format($q$SELECT record_supplier_review(%L, %L, %L)$q$, pg_temp.id_('sup'), pg_temp.val_('PS'), pg_temp.val_('PE')))::text;
SELECT 'OUT|noReason|' || pg_temp.try_('rev', format($q$SELECT record_supplier_review(%L, %L, %L, NULL, %L)$q$, pg_temp.id_('sup'), pg_temp.val_('PS'), pg_temp.val_('PE'),
        (SELECT id FROM supplier_scorecard_reviews WHERE grade IS NOT NULL ORDER BY seq DESC LIMIT 1)));
SELECT 'OUT|set2|' || pg_temp.try_('rev', format($q$SELECT set_supplier_score_settings(%L, '[{"grade":"A","max_score":15},{"grade":"B","max_score":30},{"grade":"C","max_score":null}]', 90,
        '{"A":{"prepayment_cap_pct":30,"sampling_level":"Every 10th bag"},"B":{"prepayment_cap_pct":20,"sampling_level":"Every 5th bag"},"C":{"prepayment_cap_pct":0,"sampling_level":"Every bag"}}')$q$,
        (SELECT weights FROM supplier_score_settings)));
SELECT 'OUT|rev2|' || pg_temp.get_('rev', format($q$SELECT record_supplier_review(%L, %L, %L, NULL, %L, 'ZZ-PROBE-MES8A grade lines widened after the first graded review')$q$,
        pg_temp.id_('sup'), pg_temp.val_('PS'), pg_temp.val_('PE'), (SELECT id FROM supplier_scorecard_reviews WHERE grade IS NOT NULL ORDER BY seq DESC LIMIT 1)))::text;
SELECT 'OUT|old|' || (SELECT jsonb_build_object('grade', grade, 'score', score, 'lines', grade_lines -> 0 ->> 'max_score') FROM supplier_scorecard_reviews WHERE id = (
        SELECT corrects_review_id FROM supplier_scorecard_reviews WHERE corrects_review_id IS NOT NULL))::text;
SELECT 'OUT|latest|' || pg_temp.get_('c_cco', format($q$SELECT to_jsonb(l.id) FROM supplier_latest_reviews l WHERE l.supplier_id = %L$q$, pg_temp.id_('sup')))::text;
SELECT 'OUT|v2324|' || pg_temp.get_('c_admin', $q$SELECT to_jsonb(count(*)) FROM pending_values WHERE value_code IN ('V23', 'V24')$q$)::text;
`, 'grade')
    must(v.set1 === 'OK', `setting V23 / V24 as the reviewer: «${v.set1}»`)
    must(v.v24 === '["V24:C"]', `V23 gone, V24 one row for grade C (no cap, no sampling level): ${v.v24}`)
    const r1 = JSON.parse(v.rev1), r2 = JSON.parse(v.rev2), old = JSON.parse(v.old)
    // 分 = 3×1 + 1×0 + 2×1 + 2×1 + 1×1 + 0.1×21 = 10.1 → B(A ≤ 5,B ≤ 20)
    must(Number(r1.score) === 10.1 && r1.grade === 'B', `score 10.1 → grade B under the first lines: ${v.rev1}`)
    must(v.noReason === 'SUPPLIER_REVIEW_CORRECTION_REASON_REQUIRED', `a correction without a reason: «${v.noReason}»`)
    must(v.set2 === 'OK' && r2.grade === 'A' && r2.corrects_review_id === r1.review_id, `the correction is graded under the widened lines and cites the first: ${v.rev2}`)
    must(old.grade === 'B' && Number(old.score) === 10.1 && old.lines === '5', `the corrected review keeps what it graded: ${v.old}`)
    must(JSON.parse(v.latest) === r2.review_id && v.v2324 === '0', `latest = the correction; V23/V24 all given → no pending row: ${v.latest} / ${v.v2324}`)
    console.log(`STEP|graded|V23 + V24 set by the reviewer → pending ${v.v24} (C has neither) · review: score ${r1.score} → ${r1.grade} · a correction without a reason «${v.noReason}» · lines widened, corrected with a reason → ${r2.grade}, citing the first; the first still reads ${old.grade} / ${old.score} / A ≤ ${old.lines} · latest = the correction · V23/V24 rows 0`)

    // ══ ⑤ 采购单超过本等级的预付上限 → 警告,不拒;表单的预览说同一句 · 收货页的抽样建议 —— 不加化验 ══
    v = await run(String.raw`
SELECT 'OUT|req0|' || (SELECT count(*) FROM material_required_metals);
SELECT 'OUT|po|' || pg_temp.get_('inv', format($q$SELECT create_purchase_order(%L, CURRENT_DATE, CURRENT_DATE + 30, %L, NULL, NULL, NULL, 'ZZ-PROBE-MES8A 50 pct deposit',
        jsonb_build_array(jsonb_build_object('material_id', %L::uuid, 'quantity', 10, 'unit', 'kg', 'estimated_unit_price', 50)),
        '[{"seq":1,"label":"Deposit","percentage":50,"trigger_event":"on_order"},{"seq":2,"label":"Balance","percentage":50,"trigger_event":"on_arrival"}]'::jsonb,
        p_category => 'equipment_goods')$q$, pg_temp.id_('sup'), (SELECT code FROM currencies WHERE is_base), pg_temp.id_('mat')))::text;
SELECT 'OUT|form|' || pg_temp.get_('c_finance', format($q$SELECT supplier_grade_advice(%L, '[{"seq":1,"label":"Deposit","percentage":50,"trigger_event":"on_order"}]', 500)$q$, pg_temp.id_('sup')))::text;
SELECT 'OUT|sample|' || pg_temp.get_('c_warehouse', format($q$SELECT supplier_grade_advice(%L)$q$, pg_temp.id_('sup')))::text;
SELECT 'OUT|req1|' || (SELECT count(*) FROM material_required_metals);
SELECT 'OUT|reqMat|' || (SELECT count(*) FROM material_required_metals WHERE material_id = pg_temp.id_('mat'));
`, 'po and sampling')
    const po = JSON.parse(v.po), form = JSON.parse(v.form), sample = JSON.parse(v.sample)
    must(po.purchase_order_id && Array.isArray(po.warnings) && po.warnings.length === 1 && po.warnings[0].code === 'PREPAYMENT_ABOVE_GRADE_CAP'
        && po.warnings[0].grade === 'A' && Number(po.warnings[0].cap_pct) === 30 && Number(po.warnings[0].on_order_pct) === 50,
        `50% on order against grade A's 30% cap → one warning and the order exists: ${v.po.slice(0, 400)}`)
    must(JSON.stringify(form.warnings) === JSON.stringify(po.warnings), `the form preview says what creating the order said: ${v.form} vs ${JSON.stringify(po.warnings)}`)
    must(sample.sampling_level === 'Every 10th bag' && sample.grade === 'A', `sampling advice on the receipt page: ${v.sample}`)
    must(v.req0 === v.req1 && v.reqMat === '0', `a sampling level adds no required assay: ${v.req0} → ${v.req1}, on the probe material ${v.reqMat}`)
    console.log(`STEP|po warning|${po.code} created (not refused) with «${po.warnings[0].code}» grade ${po.warnings[0].grade} cap ${po.warnings[0].cap_pct}% vs ${po.warnings[0].on_order_pct}% on order · the finance clone's form preview: the same warning · the warehouse clone's receipt advice: «${sample.sampling_level}» (grade ${sample.grade}) · required assays ${v.req0} → ${v.req1}`)

    // ══ ⑥ 对账单:对得上才签;对不上按名拒;同一段期间再签要理由,旧的标掉 ══
    v = await run(String.raw`
SELECT 'OUT|data|' || (pg_temp.get_('fv', format($q$SELECT supplier_statement_data(%L, %L, %L)$q$, pg_temp.id_('sup'), pg_temp.val_('PS'), pg_temp.val_('PE'))) - 'lines' - 'open_items')::text;
SELECT 'OUT|lines|' || (SELECT string_agg((x ->> 'kind') || ':' || (x ->> 'amount_base') || ':' || (x ->> 'provisional'), ' | ' ORDER BY x ->> 'date', x ->> 'kind', x ->> 'amount_base')
        FROM jsonb_array_elements(pg_temp.get_('fv', format($q$SELECT supplier_statement_data(%L, %L, %L)$q$, pg_temp.id_('sup'), pg_temp.val_('PS'), pg_temp.val_('PE'))) -> 'lines') x);
SELECT 'OUT|viewIssue|' || pg_temp.try_('fv', format($q$SELECT issue_supplier_statement(%L, %L, %L)$q$, pg_temp.id_('sup'), pg_temp.val_('PS'), pg_temp.val_('PE')));
-- 对不上:往这一家的总账多记一分(一张不经单据、挂在我自己那张收货上的 purchase 分录),在一个一定回滚的子事务里签
CREATE FUNCTION pg_temp.notie_() RETURNS text LANGUAGE plpgsql AS $f$
DECLARE r text;
BEGIN
    BEGIN
        PERFORM pg_temp.claims_('inv');
        PERFORM post_journal_entry(CURRENT_DATE, 'ZZ-PROBE-MES8A stray cent', 'purchase', pg_temp.id_('rb'),
            jsonb_build_array(jsonb_build_object('account_code', '5000', 'side', 'debit', 'currency', (SELECT code FROM currencies WHERE is_base), 'amount_ccy', 0.01, 'fx_rate', 1),
                              jsonb_build_object('account_code', '2000', 'side', 'credit', 'currency', (SELECT code FROM currencies WHERE is_base), 'amount_ccy', 0.01, 'fx_rate', 1)));
        r := pg_temp.try_('fe', format($q$SELECT issue_supplier_statement(%L, %L, %L)$q$, pg_temp.id_('sup'), pg_temp.val_('PS'), pg_temp.val_('PE')));
        r := r || '#' || (SELECT count(*) FROM supplier_statements);
        RAISE EXCEPTION 'MES8A_NOTIE|%', r;
    EXCEPTION WHEN OTHERS THEN
        r := SQLERRM;
    END;
    PERFORM pg_temp.me_();
    RETURN replace(r, 'MES8A_NOTIE|', '');
END $f$;
SELECT 'OUT|notie|' || pg_temp.notie_();
SELECT 'OUT|st1|' || pg_temp.get_('fe', format($q$SELECT issue_supplier_statement(%L, %L, %L)$q$, pg_temp.id_('sup'), pg_temp.val_('PS'), pg_temp.val_('PE')))::text;
SELECT 'OUT|again|' || pg_temp.try_('fe', format($q$SELECT issue_supplier_statement(%L, %L, %L)$q$, pg_temp.id_('sup'), pg_temp.val_('PS'), pg_temp.val_('PE')));
SELECT 'OUT|st2|' || pg_temp.get_('fe', format($q$SELECT issue_supplier_statement(%L, %L, %L, 'ZZ-PROBE-MES8A reissued after the supplier queried the deposit line')$q$,
        pg_temp.id_('sup'), pg_temp.val_('PS'), pg_temp.val_('PE')))::text;
-- 会话里改一份签发了的对账单:没有 UPDATE 策略 → RLS 让它碰不到任何一行(一次成功的空操作,AGENTS.md「被 RLS 挡下的 UPDATE」)—— 判据是【那一行没变】;
--   属主(绕过 RLS)去改,撞上只许被取代的守卫,按名拒(子事务里试,拒不拒都撤回)
SELECT 'OUT|editSession|' || pg_temp.try_('fe', $q$UPDATE supplier_statements SET closing_base = 0$q$);
SELECT 'OUT|editRows|' || (SELECT string_agg(closing_base::text, ',' ORDER BY code) FROM supplier_statements);
CREATE FUNCTION pg_temp.owner_try_(p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE r text;
BEGIN
    BEGIN
        PERFORM pg_temp.me_();
        EXECUTE p_sql;
        RAISE EXCEPTION 'MES8A_OWNER_OK';
    EXCEPTION WHEN OTHERS THEN
        r := SQLERRM;
    END;
    RETURN CASE WHEN r = 'MES8A_OWNER_OK' THEN 'OK' ELSE r END;
END $f$;
SELECT 'OUT|edit|' || pg_temp.owner_try_($q$UPDATE supplier_statements SET closing_base = 0$q$);
SELECT 'OUT|editIssue|' || pg_temp.owner_try_($q$DELETE FROM supplier_statements$q$);
SELECT 'OUT|rows|' || (SELECT jsonb_agg(jsonb_build_object('code', code, 'closing', closing_base, 'superseded_by', (SELECT s2.code FROM supplier_statements s2 WHERE s2.id = s.superseded_by),
        'reason', superseded_reason) ORDER BY code) FROM supplier_statements s)::text;
SELECT 'OUT|recon|' || pg_temp.agree_('statements issued');
`, 'statement')
    const d = JSON.parse(v.data), st1 = JSON.parse(v.st1), st2 = JSON.parse(v.st2), rows = JSON.parse(v.rows)
    // 期初 400;发生 600 + 1,000 = 1,600;付款 250 + 100 = 350;预付冲抵 300;期末 1,350 · 未结 400 + 350 + 700 = 1,450 − 挂账 100 − 残留 0 = 1,350
    must(Number(d.opening_base) === 400 && Number(d.charges_base) === 1600 && Number(d.payments_base) === 350 && Number(d.prepayments_base) === 300
        && Number(d.closing_base) === 1350 && Number(d.list_base) === 1450 && Number(d.on_account_base) === 100 && Number(d.residue_base) === 0
        && Number(d.tie_difference) === 0 && d.ties === true, `the statement figures: ${v.data.slice(0, 500)}`)
    must(Array.isArray(d.unpriced) && d.unpriced.length === 1 && Number(d.unpriced[0].quantity) === 50, `the half delivery is listed unpriced with its quantity: ${JSON.stringify(d.unpriced)}`)
    must(d.on_account.length === 1 && Number(d.on_account[0].amount_base) === 100, `the payment on account: ${JSON.stringify(d.on_account)}`)
    must(v.viewIssue === 'PERMISSION_DENIED|module.finance.edit', `a finance viewer issues: «${v.viewIssue}»`)
    must(/^SUPPLIER_STATEMENT_DOES_NOT_TIE\|ZZ-PROBE-MES8A-S\|-0\.01\|1350\.01\|1350\.00#0$/.test(v.notie), `a non-tying statement must be refused by name and write nothing: «${v.notie}»`)
    must(/^SST-\d{4}-\d{4,}$/.test(st1.code) && Number(st1.closing_base) === 1350, `the first statement: ${v.st1}`)
    must(v.again === `SUPPLIER_STATEMENT_SUPERSEDE_REASON_REQUIRED|${st1.code}|ZZ-PROBE-MES8A-S`, `the same period again without a reason: «${v.again}»`)
    must(st2.superseded === st1.code && rows.length === 2 && rows[0].superseded_by === st2.code && rows[0].reason.startsWith('ZZ-PROBE-MES8A reissued')
        && Number(rows[0].closing) === 1350, `supersede: ${v.rows}`)
    must(v.editSession === 'OK' && v.editRows === '1350.00,1350.00', `a finance editor's UPDATE must touch no row (RLS has no update policy): «${v.editSession}» rows ${v.editRows}`)
    must(v.edit === 'SUPPLIER_STATEMENT_IMMUTABLE|update' && v.editIssue === 'SUPPLIER_STATEMENT_IMMUTABLE|delete', `the owner editing / deleting an issued statement: «${v.edit}» / «${v.editIssue}»`)
    console.log(`STEP|statement|preview: opening ${d.opening_base} + charges ${d.charges_base} − payments ${d.payments_base} − prepayments ${d.prepayments_base} = closing ${d.closing_base}; open items ${d.list_base} − on account ${d.on_account_base} − residue ${d.residue_base} → difference ${d.tie_difference}, ties · lines ${v.lines} · unpriced ${d.unpriced[0].doc_code} ${d.unpriced[0].quantity} ${d.unpriced[0].unit}`)
    console.log(`STEP|issue|the viewer «${v.viewIssue}» · one cent too many on the ledger → «${v.notie.split('#')[0]}», statements written ${v.notie.split('#')[1]} · ${st1.code} issued · the same period without a reason «${v.again}» · with a reason → ${st2.code}; ${st1.code} superseded by it, reason kept, figures kept · the finance editor's UPDATE touches no row (no update policy; both still ${v.editRows}) · the owner's edit «${v.edit}» and delete «${v.editIssue}» · recon ${v.recon}`)

    // ══ ⑦ PDF:从冻下来的那一行渲染 → 签发人上传 → 记哈希 → 只读者下载、重算、读纸 → 改坏字节 = 409 那一支 ══
    v = await run(`SELECT 'OUT|row2|' || (SELECT to_jsonb(s) FROM supplier_statements s WHERE s.code = ${lit(st2.code)})::text;
SELECT 'OUT|company|' || (SELECT legal_name FROM company_profile LIMIT 1);`, 'frozen row')
    const row2 = JSON.parse(v.row2), company = v.company
    const buf = await renderSupplierStatementPdf(statementDocFrom(row2))
    const digest = sha(buf)
    const path = `${row2.id}/${digest}.pdf`
    planObjectDelete(path)
    const upView = await upload(who.fv.token, `${row2.id}/${randomUUID()}.pdf`, buf)
    must(upView.status >= 400, `a finance viewer must not upload: HTTP ${upView.status} ${upView.text}`)
    const up = await upload(who.fe.token, path, buf)
    must(up.status === 200, `the issuer could not upload (HTTP ${up.status} ${up.text})`)
    v = await run(String.raw`
SELECT 'OUT|rec|' || pg_temp.get_('fe', format($q$SELECT record_supplier_statement_issue(%L, %L, %L)$q$, ${lit(row2.id)}, ${lit(path)}, ${lit(digest.toUpperCase())}))::text;
SELECT 'OUT|recAgain|' || pg_temp.try_('fe', format($q$SELECT record_supplier_statement_issue(%L, %L, %L)$q$, ${lit(row2.id)}, ${lit(row2.id + '/again.pdf')}, ${lit(digest)}));
SELECT 'OUT|recOld|' || pg_temp.try_('fe', format($q$SELECT record_supplier_statement_issue(%L, %L, %L)$q$, (SELECT id FROM supplier_statements WHERE code = ${lit(st1.code)}),
        (SELECT id FROM supplier_statements WHERE code = ${lit(st1.code)})::text || '/x.pdf', repeat('a', 64)));
SELECT 'OUT|recPath|' || pg_temp.try_('fe', format($q$SELECT record_supplier_statement_issue(%L, 'elsewhere/x.pdf', %L)$q$, ${lit(row2.id)}, repeat('b', 64)));
`, 'record')
    const rec = JSON.parse(v.rec)
    must(rec.sha256 === digest && rec.version === 1, `record_supplier_statement_issue stored ${rec.sha256} v${rec.version}, expected the lower-case ${digest} v1`)
    must(v.recAgain === `SUPPLIER_STATEMENT_BYTES_ALREADY_RECORDED|${st2.code}|1`, `the same bytes again: «${v.recAgain}»`)
    must(v.recOld.startsWith(`SUPPLIER_STATEMENT_SUPERSEDED|${st1.code}|`), `the superseded statement: «${v.recOld}»`)
    must(v.recPath === `SUPPLIER_STATEMENT_ISSUE_PATH_INVALID|${st2.code}`, `a path outside the statement's folder: «${v.recPath}»`)
    const dl = await download(who.fv.token, path)
    must(dl.status === 200 && sha(dl.buf) === digest, `the viewer's download: HTTP ${dl.status}, sha ${sha(dl.buf)} vs recorded ${digest}`)
    const t = pdfText(dl.buf)
    const expectPaper = [st2.code, 'ZZ-PROBE-MES8A Cells Supplier Pte Ltd', company, 'Provisional price', d.unpriced[0].doc_code, '50 kg']
    for (const needle of expectPaper) must(t.text.includes(needle), `the stored PDF does not say «${needle}»`)
    must(!/[一-鿿]/.test(t.text), 'the supplier statement must be English')
    console.log(`STEP|pdf|${st2.code}: rendered from the frozen row (${buf.length} bytes, ${t.pages} page${t.pages === 1 ? '' : 's'}) · the viewer's upload refused (HTTP ${upView.status}) · the issuer uploaded ${BUCKET}/${path.slice(0, 44)}… · sha recorded (sent upper-case, stored ${digest.slice(0, 12)}…, version 1) · the same bytes again «${v.recAgain}» · on the superseded ${st1.code} «${v.recOld.split('|').slice(0, 2).join('|')}» · a path elsewhere «${v.recPath}» · the viewer downloaded, sha matches · the paper says ${expectPaper.map((x) => `«${x}»`).join(' ')}, no Chinese`)

    // 冻住:供应商改名(活数据)—— 那一行与那份字节都不动;预览读活数据
    v = await run(String.raw`
UPDATE suppliers SET legal_name = 'ZZ-PROBE-MES8A Renamed Supplier' WHERE id = pg_temp.id_('sup');
SELECT 'OUT|rowSame|' || ((SELECT to_jsonb(s) FROM supplier_statements s WHERE s.code = ${lit(st2.code)}) = ${lit(JSON.stringify(row2))}::jsonb)::text;
SELECT 'OUT|preview|' || (pg_temp.get_('fv', format($q$SELECT supplier_statement_data(%L, %L, %L)$q$, pg_temp.id_('sup'), pg_temp.val_('PS'), pg_temp.val_('PE'))) ->> 'supplier_name');
`, 'frozen')
    const again = await download(who.fv.token, path)
    must(v.rowSame === 'true' && v.preview === 'ZZ-PROBE-MES8A Renamed Supplier' && sha(again.buf) === digest && !pdfText(again.buf).text.includes('Renamed'),
        `frozen: row same ${v.rowSame}, preview «${v.preview}», bytes ${sha(again.buf) === digest}`)
    console.log(`STEP|frozen|supplier renamed live → ${st2.code}: the row is identical, the stored bytes identical, the paper still says the old name · the preview (live data) says «${v.preview}»`)

    // 改坏字节 → 下载的哈希对不上记下的 = 路由的 409
    const tampered = Buffer.concat([buf, Buffer.from('\n% tampered\n')])
    const put = await upload(null, path, tampered, { asService: true, upsert: true })
    must(put.status === 200, `service-role overwrite for the tamper test: HTTP ${put.status} ${put.text}`)
    const bad = await download(who.fv.token, path)
    must(bad.status === 200 && sha(bad.buf) !== digest && bad.buf.length === tampered.length, `the altered bytes should no longer match (download ${bad.status}, ${bad.buf.length} bytes)`)
    console.log(`STEP|tampered|${st2.code}: bytes overwritten with the service role (+12 bytes) → downloaded sha ${sha(bad.buf).slice(0, 12)}… ≠ recorded ${digest.slice(0, 12)}… → the route answers 409 (route.ts: sha !== issue.sha256; check-pdf-routes SST-409 proves that branch)`)

    // 桶的删除策略:记下了的删不掉;没记下的孤儿签发人删得掉;只读者一个都删不掉
    const orphan = `${row2.id}/${randomUUID()}.pdf`
    planObjectDelete(orphan)
    const upO = await upload(who.fe.token, orphan, Buffer.from('%PDF-1.4\n% orphan probe\n'))
    must(upO.status === 200, `uploading an orphan as the issuer: HTTP ${upO.status} ${upO.text}`)
    v = await run(String.raw`
SELECT set_config('storage.allow_delete_query', 'true', true) \g /dev/null
CREATE FUNCTION pg_temp.del_(p_who text, p_name text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE n bigint; r text;
BEGIN
    BEGIN
        PERFORM pg_temp.as_(p_who);
        DELETE FROM storage.objects WHERE bucket_id = 'supplier-statement-documents' AND name = p_name;
        GET DIAGNOSTICS n = ROW_COUNT;
        RAISE EXCEPTION 'MES8A_DELETED|%', n;
    EXCEPTION WHEN OTHERS THEN
        r := SQLERRM;
    END;
    PERFORM pg_temp.me_();
    RETURN CASE WHEN r LIKE 'MES8A_DELETED|%' THEN split_part(r, '|', 2) ELSE r END;
END $f$;
SELECT 'OUT|delRecorded|' || pg_temp.del_('fe', ${lit(path)});
SELECT 'OUT|delView|' || pg_temp.del_('fv', ${lit(orphan)});
SELECT 'OUT|delOrphan|' || pg_temp.del_('fe', ${lit(orphan)});
SELECT set_config('storage.allow_delete_query', '', true) \g /dev/null
`, 'delete policy')
    must(v.delRecorded === '0', `a recorded object must not be deletable: deleted ${v.delRecorded}`)
    must(v.delView === '0', `a finance viewer must not delete an orphan: ${v.delView}`)
    must(v.delOrphan === '1', `the issuer should be able to delete an unrecorded orphan: ${v.delOrphan}`)
    const rmO = await removeAs(who.fe.token, [orphan])
    must(rmO.status === 200 && rmO.removed === 1, `removing the orphan through the Storage API as the issuer: HTTP ${rmO.status}, removed ${rmO.removed}`)
    console.log(`STEP|bucket policy|as the issuer, a DELETE of the recorded object touches 0 rows · a viewer deletes 0 · an unrecorded orphan: the issuer deletes 1 in SQL (rolled back) and removes it through the Storage API (HTTP ${rmO.status}, 1 removed)`)

    // ══ ⑧ F17:我自己的一张销毁证书 —— 路径在它自己的目录下、一张一份字节、哈希小写存 ══
    v = await run(String.raw`
DO $s$
DECLARE ib uuid; c uuid;
BEGIN
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note)
    VALUES ('ZZ-PROBE-MES8A-BCOD', pg_temp.id_('mat'), pg_temp.id_('sup'), 10, 0, 'kg', CURRENT_DATE - 2, 'other', 'ZZ-PROBE-MES8A destroyed lot') RETURNING id INTO ib;
    INSERT INTO certificates_of_destruction (inbound_batch_id, completed_on, status, code, verification_token, snapshot, issued_at)
    VALUES (ib, CURRENT_DATE - 1, 'issued', 'ZZ-PROBE-MES8A-COD', gen_random_uuid(), '{}'::jsonb, now()) RETURNING id INTO c;
    PERFORM pg_temp.put_('cod', c::text);
END $s$;
SELECT 'OUT|codPath|' || pg_temp.try_('cod', format($q$SELECT record_cod_issue(%L, 'cod/%s/x.pdf', %L)$q$, pg_temp.id_('cod'), pg_temp.id_('cod'), repeat('A', 64)));
SELECT 'OUT|codOk|' || pg_temp.get_('cod', format($q$SELECT record_cod_issue(%L, '%s/x.pdf', %L)$q$, pg_temp.id_('cod'), pg_temp.id_('cod'), repeat('AB', 32)))::text;
SELECT 'OUT|codStored|' || (SELECT sha256 FROM cod_issues WHERE cod_id = pg_temp.id_('cod'));
SELECT 'OUT|codAgain|' || pg_temp.try_('cod', format($q$SELECT record_cod_issue(%L, '%s/y.pdf', %L)$q$, pg_temp.id_('cod'), pg_temp.id_('cod'), repeat('c', 64)));
SELECT 'OUT|codRows|' || (SELECT count(*) FROM cod_issues WHERE cod_id = pg_temp.id_('cod'));
`, 'F17')
    must(v.codPath === 'COD_ISSUE_PATH_INVALID|ZZ-PROBE-MES8A-COD', `F17 path: «${v.codPath}»`)
    must(v.codStored === 'ab'.repeat(32), `F17 lower-case: ${v.codStored}`)
    must(v.codAgain === 'COD_BYTES_ALREADY_RECORDED|ZZ-PROBE-MES8A-COD' && v.codRows === '1', `F17 one set of bytes: «${v.codAgain}» rows ${v.codRows}`)
    console.log(`STEP|F17|my own issued certificate ZZ-PROBE-MES8A-COD: a path outside its folder «${v.codPath}» · upper-case digest stored ${v.codStored.slice(0, 8)}… (lower-case) · a second set of bytes «${v.codAgain}» · rows 1`)

    // ══ ⑨ 逐角色读数表(七个真角色【此刻的码】的克隆,只读)══
    for (const r of ROLE_CLONES) {
        const key = `c_${r}`
        v = await run(String.raw`
DO $s$
DECLARE v_sc bigint; v_rv bigint; v_sl bigint; v_sr bigint; v_ir bigint; v_23 bigint; v_24 bigint;
        v_sv boolean; v_srv boolean; v_iv boolean; v_fv boolean; v_fe boolean;
BEGIN
    PERFORM pg_temp.as_(${lit(key)});
    v_sv := has_permission('module.suppliers.view'); v_srv := has_permission('action.supplier_review'); v_iv := has_permission('module.inbound.view');
    v_fv := has_permission('module.finance.view'); v_fe := has_permission('module.finance.edit');
    SELECT count(*) INTO v_sc FROM supplier_scorecard_rows WHERE supplier_id = pg_temp.id_('sup');
    SELECT count(*) INTO v_rv FROM supplier_scorecard_reviews WHERE supplier_id = pg_temp.id_('sup');
    SELECT count(*) INTO v_sl FROM supplier_statement_rows WHERE supplier_id = pg_temp.id_('sup');
    SELECT count(*) INTO v_sr FROM supplier_statements WHERE code = ${lit(st2.code)};
    SELECT count(*) INTO v_ir FROM supplier_statement_issues WHERE statement_id = ${lit(row2.id)};
    SELECT count(*) INTO v_23 FROM pending_values WHERE value_code = 'V23';
    SELECT count(*) INTO v_24 FROM pending_values WHERE value_code = 'V24';
    PERFORM pg_temp.me_();
    INSERT INTO p8_roles VALUES (${lit(key)}, ${lit(r)}, (SELECT count(*) FROM role_permissions rp JOIN roles ro ON ro.id = rp.role_id WHERE ro.code = ${lit(r)}),
        v_sv, v_srv, v_iv, v_fv, v_fe, v_sc, v_rv,
        pg_temp.would_(${lit(key)}, format($q$SELECT supplier_scorecard_preview(%L, %L, %L)$q$, pg_temp.id_('sup'), pg_temp.val_('PS'), pg_temp.val_('PE'))),
        pg_temp.would_(${lit(key)}, format($q$SELECT supplier_grade_advice(%L, '[{"trigger_event":"on_order","percentage":50}]', 500)$q$, pg_temp.id_('sup'))),
        v_sl, v_sr, v_ir, v_23, v_24,
        pg_temp.would_(${lit(key)}, format($q$SELECT record_supplier_review(%L, %L, %L, 'ZZ-PROBE-MES8A role probe')$q$, pg_temp.id_('sup'), pg_temp.val_('PS'), pg_temp.val_('PE'))));
END $s$;
SELECT 'OUT|row|' || (SELECT to_jsonb(x) FROM p8_roles x WHERE who = ${lit(key)})::text;
`, `role ${r}`)
        const row = JSON.parse(v.row)
        const dlr = await download(who[key].token, path)
        const short = (s) => (s === 'OK' ? 'yes' : `no (${s.split('|')[0]}${s.includes('|') ? '|' + s.split('|')[1] : ''})`)
        console.log(`ROLE|${r}|codes ${row.codes}|suppliers.view ${row.suppliers_view ? 'yes' : 'no'}|supplier_review ${row.supplier_review ? 'yes' : 'no'}|scorecard row ${row.scorecard_rows}|reviews seen ${row.reviews_seen}|scorecard preview ${short(row.preview)}|PO form advice ${short(row.advice)}|receipt page (inbound.view ${row.inbound_view ? 'yes' : 'no'}) sampling advice ${short(row.advice)}|statement list rows ${row.statement_list}|the statement ${row.statement_row}|its PDF record ${row.issue_rows}|PDF download ${dlr.status === 200 ? 'yes' : `no (HTTP ${dlr.status})`}|issue (finance.edit) ${row.finance_edit ? 'yes' : 'no'}|pending V23 ${row.pending_v23} · V24 ${row.pending_v24}|record a review ${short(row.record_review)}`)
    }

    // ══ ⑩ 在册的东西一个字都没动;收尾 ══
    v = await run(String.raw`
DO $s$
DECLARE v_rec text;
BEGIN
    IF pg_temp.fp_(pg_temp.val_('t0')::timestamptz) IS DISTINCT FROM pg_temp.val_('fp') THEN
        RAISE EXCEPTION 'MES8A_LIVE|pre-existing rows changed in: %', (SELECT string_agg(split_part(a.x, ':', 1), ', ')
            FROM unnest(string_to_array(pg_temp.fp_(pg_temp.val_('t0')::timestamptz), '#')) WITH ORDINALITY a(x, i)
            JOIN unnest(string_to_array(pg_temp.val_('fp'), '#')) WITH ORDINALITY b(y, j) ON i = j WHERE a.x IS DISTINCT FROM b.y);
    END IF;
    IF (SELECT COALESCE(string_agg(subject_type || ':' || code, ',' ORDER BY code), '') FROM approval_pending_documents() WHERE code NOT LIKE 'ZZ-PROBE-MES8A%'
            AND code NOT IN (SELECT po.code FROM purchase_orders po WHERE po.supplier_id = pg_temp.id_('sup'))) <> pg_temp.val_('pending') THEN
        RAISE EXCEPTION 'MES8A_LIVE|pending documents other than my own changed';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN RAISE EXCEPTION 'MES8A_LIVE|require_calibrated_since set'; END IF;
    IF NOT approvals_enabled() THEN RAISE EXCEPTION 'MES8A_LIVE|approvals switched off'; END IF;
    v_rec := pg_temp.agree_('end');
    RAISE NOTICE 'STEP|untouched|pre-existing rows identical; pending (others) «%»; approvals on; require_calibrated_since NULL; reconciliation %', pg_temp.val_('pending'), v_rec;
    RAISE NOTICE 'STEP|done|%', clock_timestamp() - pg_temp.val_('t0')::timestamptz;
END $s$;
ROLLBACK;
SELECT 'OUT|afterDb|' || 'reviews=' || (SELECT count(*) FROM supplier_scorecard_reviews) || ' · statements=' || (SELECT count(*) FROM supplier_statements)
    || ' · statement issues=' || (SELECT count(*) FROM supplier_statement_issues) || ' · settings set=' || (SELECT count(*) FROM supplier_score_settings WHERE weights IS NOT NULL OR grade_lines IS NOT NULL OR review_window_days IS NOT NULL OR grade_caps IS NOT NULL)
    || ' · cod_issues=' || (SELECT count(*) FROM cod_issues)
    || ' · probe rows=' || ((SELECT count(*) FROM suppliers WHERE code LIKE 'ZZ-PROBE-MES8A%') + (SELECT count(*) FROM materials WHERE code LIKE 'ZZ-PROBE-MES8A%')
                            + (SELECT count(*) FROM purchase_orders WHERE notes LIKE 'ZZ-PROBE-MES8A%' OR code LIKE 'ZZ-PROBE-MES8A%'))
    || ' · require_calibrated_since=' || COALESCE((SELECT require_calibrated_since::text FROM ingest_settings), 'NULL')
    || ' · approvals=' || approvals_enabled()::text;
`, 'close')
    console.log(`AFTER|database (after ROLLBACK): ${v.afterDb}`)
    psql.stdin.end()

    // 桶:删掉上传过的对象,再读回 —— 对账单的桶 0 个对象;销毁证书的桶与开场逐字相同
    const { URL, SERVICE } = env()
    const r = await fetch(`${URL}/storage/v1/object/${BUCKET}`, {
        method: 'DELETE', headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ prefixes: [path, orphan] }),
    })
    must(r.ok, `removing the proof's objects: HTTP ${r.status}`)
    const left = await listAsService(BUCKET)
    const sstAfter = bucketFingerprint(BUCKET), codAfter = bucketFingerprint(COD_BUCKET)
    bucketVerdict = `${BUCKET}: ${left.length} top-level entries (Storage API) · SQL ${sstAfter} (before ${sstBefore}) · ${COD_BUCKET}: SQL ${codAfter} (before ${codBefore})`
    must(left.length === 0 && sstAfter === sstBefore && codAfter === codBefore, `a bucket is not as it was: ${bucketVerdict}`)
    console.log('✓ 证明走完(STEP|done),事务已回滚,对账单的桶里 0 个对象,销毁证书的桶逐字未变')
    return exitAfterCleanup(0)
}

// 失败时先结束那笔事务(杀掉 psql、等它退出 —— 服务端随之回滚、放锁),再收账号(MES-6b-2 的同一条)
async function endTransaction() {
    if (!psql || psql.exitCode !== null) return
    const gone = new Promise((r) => psql.once('exit', r))
    psql.kill('SIGTERM')
    await Promise.race([gone, new Promise((r) => setTimeout(r, 10_000))])
}
main().catch(async (e) => {
    console.error('✗ ' + (e?.stack || e))
    await endTransaction()
    return exitAfterCleanup(String(e?.message || '').startsWith('MES8A_') ? 1 : 2)
})
