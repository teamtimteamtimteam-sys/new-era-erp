#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// MES-8b-1(2026-10-17)· 线上验证 —— 进料毛利、库存敞口与月度合规包:一笔【回滚】的事务 + 私有桶 compliance-documents 里【事后删干净】的对象
// ════════════════════════════════════════════════════════════════════════════
// 形状照 db/scripts/2026-10-16-mes8a-live-proof.mjs(供应商对账单那一支):合规包的字节在【桶】里,而桶的写入不随事务回滚。
//   所以这一支是一个【常开的 psql 子进程】(一笔事务从头开到尾),中间由本进程:
//     · 照 freeze_compliance_pack 在事务里写下的【那一行】渲染 PDF(app/compliance/packs/[id]/pdf/renderPack.ts,与路由同一支 —— 入参只有那一行);
//     · 以存档人的一次性账号经 Storage API 上传(桶的 INSERT 策略:action.compliance_pack —— 一次性角色的授权是已提交的);
//     · 回到事务里 record_compliance_pack_issue 记哈希(大写送、小写存);再以只读账号经 Storage API 下载、重算 sha256、用 pypdf 读纸上的字;
//     · 以 service role 覆盖那份字节(模拟被改过的档案)→ 再下载 → 哈希对不上 = 路由的 409 那一支(route.ts:sha !== issue.sha256);
//     · 收尾:每一个上传过的对象都在上传【之前】登记了删除步(scripts/ephemeral.mjs 的计划),最后删掉,再读回桶里 0 个对象、
//       销毁证书的桶 cod-documents 与开场逐字相同(本证明不碰它)。
//   为什么桶的断言不是 fixture:AGENTS.md「存储桶与它的策略不在镜像里」。
//
// 【身份】每一个动作都以一次性账号跑(前缀 mes8b1probe),七个真账号一个都不用:
//   inv = 布景(收货、加工、分摊、销售、事故、监测、巡检)—— 持 permissions 表里每一个码的一次性角色('all';不是 admin,也不是任何真角色)
//   cfo = 真的 cfo 角色本身(realRole)—— 只为【决定】收货定价申请(审批开着:定价要 CFO 批,批了才进总账)
//   fin = 读毛利与敞口(module.finance.view · data.view_prices —— 常设决定 2 的一支)
//   cp  = 冻包、重出、存档(module.compliance.view · action.compliance_pack)
//   cv  = 只读合规(module.compliance.view)—— 下载 PDF
//   c_<角色> = 七个真账号此刻持有的七个角色的码的克隆(cloneOf,只读;c_cfo 读两条勾稽)
// 【布景】都是我自己的行(前缀 ZZ-PROBE-MES8B1 / zzp8b1),在事务里插,随回滚消失。在册的东西一行都不改、不决定、不删;唯一碰到的在册的一行是
//   finance_settings.locked_before —— 在这一笔一定回滚的事务里锁到 2026-10-01(委托书:月份只在回滚的事务里锁),回滚之后读回原值。
// 【判决】只从日志里最后那一行 `MES8B1_PROOF_EXIT=` 读(exitAfterCleanup 的 onFinish 打的)。
//   0 = 证明走完(STEP|done)且收尾读回桶空 · 1 = 证明红了 · 2 = 驱动自己坏了 · 5 = live-lock 被占 · 6 = 收尾没完成。
// 用法:node db/scripts/2026-10-17-mes8b1-live-proof.mjs > <log> 2>&1
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
const BUCKET = 'compliance-documents'
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
        console.log(`MES8B1_PROOF_EXIT=${code}`)
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
    const mark = `@@MES8B1_DONE_${++seq}@@`
    const from = out.length
    psql.stdin.write(`${sqlText}\n\\echo ${mark}\n`)
    const t0 = Date.now()
    while (!out.includes(mark, from)) {
        if (psql.exitCode !== null) {
            throw new Error(`MES8B1_SQL|${label}|psql exited ${psql.exitCode}:\n${err.split('\n').slice(-20).join('\n')}`)
        }
        if (Date.now() - t0 > 360_000) throw new Error(`MES8B1_SQL|${label}|no answer within 360s`)
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
    if (!r.ok || !Array.isArray(j)) throw new Error(`MES8B1_BUCKET|list ${bucket} HTTP ${r.status} ${JSON.stringify(j).slice(0, 200)}`)
    return j
}
// 一个桶此刻的样子(SQL 一侧,名字 · 大小 · eTag)—— 开场与收尾各读一次,逐字比
function bucketFingerprint(bucket) {
    const r = spawnSync('psql', ['-X', '-At', '-c',
        `SELECT count(*) || ':' || COALESCE(md5(string_agg(name || '|' || COALESCE(metadata ->> 'size', '') || '|' || COALESCE(metadata ->> 'eTag', ''), ',' ORDER BY name)), '-') FROM storage.objects WHERE bucket_id = ${lit(bucket)}`,
        DSN], { encoding: 'utf8' })
    if (r.status !== 0) throw new Error(`MES8B1_BUCKET|fingerprint ${bucket}: ${r.stderr.slice(0, 200)}`)
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
    if (r.status !== 0) throw new Error(`MES8B1_PDF|pypdf could not read the bytes: ${r.stderr.slice(0, 300)}`)
    const [pages, ...rest] = r.stdout.split('\n')
    // 窄列里的字会折行 —— 空白归一再比(比的是字,不是排版;check-pdf-routes 的同一个办法)
    return { pages: Number(pages), text: rest.join('\n').replace(/\s+/g, ' ') }
}
function must(cond, msg) { if (!cond) throw new Error(`MES8B1_LIVE|${msg}`) }

// ── 渲染:与路由同一支(renderPack.ts),入参只有冻下来的那一行 ───────────────────────
let packDocFrom = null
let renderCompliancePackPdf = null
async function loadRenderer() {
    const { createJiti } = await import('jiti')
    const React = (await import('react')).default
    globalThis.React = React // jiti 的 JSX 走经典运行时
    const jiti = createJiti(import.meta.url, { alias: { '@': ROOT }, jsx: true, interopDefault: true })
    const mod = await jiti.import(join(ROOT, 'app/compliance/packs/[id]/pdf/renderPack.ts'))
    packDocFrom = mod.packDocFrom
    renderCompliancePackPdf = mod.renderCompliancePackPdf
}


async function main() {
    const other = heldBy()
    if (other) {
        console.error(`✗ live-lock 被【${other.holder}】(pid ${other.pid})占着 —— 等它跑完再来。`)
        return exitAfterCleanup(5)
    }
    acquireOrExit('db/scripts/2026-10-17-mes8b1-live-proof.mjs', { ownExit: false })
    locked = true
    openPlan('db/scripts/2026-10-17-mes8b1-live-proof.mjs')
    await reapStalePlans()
    scratch = mkdtempSync(join(tmpdir(), 'mes8b1-proof-'))
    await loadRenderer()

    // 桶开跑前:合规包的桶是空的(本刀之前它不存在);销毁证书的桶记下样子,收尾逐字比
    const before = await listAsService(BUCKET)
    must(before.length === 0, `bucket ${BUCKET} already holds ${before.length} object(s) before the proof — not mine, stopping`)
    const codBefore = bucketFingerprint(COD_BUCKET)
    const cpkBefore = bucketFingerprint(BUCKET)
    console.log(`STEP|buckets before|${BUCKET}: Storage API 0 objects, SQL ${cpkBefore} · ${COD_BUCKET}: SQL ${codBefore}`)

    const stamp = Date.now()
    const who = {}
    const mint = async (key, label, codes) => {
        const a = await mintThrowaway({ prefix: 'mes8b1probe', label, stamp, codes })
        who[key] = a
        console.log(`· ${key}: ${a.email} ← ${a.roleCode} (${a.codes.length} codes${Array.isArray(codes) ? ': ' + a.codes.join(', ') : ''})`)
    }
    await mint('inv', 'inv', 'all')
    await mint('cfo', 'cfo', { realRole: 'cfo' })
    await mint('fin', 'fin', ['module.finance.view', 'data.view_prices'])
    await mint('cp', 'cp', ['module.compliance.view', 'action.compliance_pack'])
    await mint('cv', 'cv', ['module.compliance.view'])
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
    IF v_uid IS NULL OR e NOT LIKE 'mes8b1probe-%@test.local' THEN RAISE EXCEPTION 'MES8B1_LIVE|not a throwaway account: % (%)', p_who, e; END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_uid), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
END $f$;
-- 以 p_who 的身份但【不】切到 authenticated(布景里那几支写入函数:它们按调用者判码,而属主身份读得到自己的临时表)
CREATE FUNCTION pg_temp.claims_(p_who text) RETURNS void LANGUAGE plpgsql AS $f$
DECLARE e text := (SELECT x.v FROM p8 x WHERE x.k = 'email.' || p_who);
BEGIN
    EXECUTE 'RESET ROLE';
    IF e NOT LIKE 'mes8b1probe-%@test.local' THEN RAISE EXCEPTION 'MES8B1_LIVE|not a throwaway account: %', p_who; END IF;
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
        RAISE EXCEPTION 'MES8B1_WOULD_OK';
    EXCEPTION WHEN OTHERS THEN
        r := SQLERRM;
    END;
    PERFORM pg_temp.me_();
    RETURN CASE WHEN r = 'MES8B1_WOULD_OK' THEN 'OK' ELSE r END;
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
    IF jsonb_array_length(v -> 'sides') <> 2 THEN RAISE EXCEPTION 'MES8B1_LIVE|reconciliation after %: expected two sides, got %', p_step, v; END IF;
    FOR s IN SELECT * FROM jsonb_array_elements(v -> 'sides') LOOP
        IF s ->> 'refusal' IS NOT NULL OR (s ->> 'unexplained_base')::numeric IS DISTINCT FROM 0 THEN
            RAISE EXCEPTION 'MES8B1_LIVE|AP/AR list <> ledger after %: %', p_step, s;
        END IF;
        o := o || (s ->> 'side') || ' ' || (s ->> 'list_base') || ' / ' || (s ->> 'ledger_base') || ' / ' || (s ->> 'unexplained_base') || '; ';
    END LOOP;
    RAISE NOTICE 'STEP|recon %|%', p_step, o;
    RETURN o;
END $f$;
-- 在册的东西的指纹:我的行 created_at = 事务开始时刻(now()),按 < t0 排除;finance_settings 不在这里 —— 本证明在事务里锁了一个月,回滚之后读回
CREATE FUNCTION pg_temp.fp_(t0 timestamptz) RETURNS text LANGUAGE sql AS $f$
SELECT concat_ws('#',
    'inbound_batches:' || COALESCE((SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM inbound_batches x WHERE x.created_at < t0), '-'),
    'output_batches:' || COALESCE((SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM output_batches x WHERE x.created_at < t0), '-'),
    'inventory_movements:' || COALESCE((SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM inventory_movements x WHERE x.created_at < t0), '-'),
    'processing_runs:' || COALESCE((SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM processing_runs x WHERE x.created_at < t0), '-'),
    'processing_outputs:' || COALESCE((SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM processing_outputs x WHERE x.run_id IN (SELECT id FROM processing_runs WHERE created_at < t0)), '-'),
    'sales_records:' || COALESCE((SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM sales_records x WHERE x.created_at < t0), '-'),
    'metal_prices:' || COALESCE((SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM metal_prices x WHERE x.created_at < t0), '-'),
    'inbound_batch_metals:' || COALESCE((SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.inbound_batch_id, x.metal)) FROM inbound_batch_metals x WHERE x.inbound_batch_id IN (SELECT id FROM inbound_batches WHERE created_at < t0)), '-'),
    'output_batch_metals:' || COALESCE((SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.output_batch_id, x.metal)) FROM output_batch_metals x WHERE x.output_batch_id IN (SELECT id FROM output_batches WHERE created_at < t0)), '-'),
    'substances:' || COALESCE((SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.code)) FROM substances x WHERE x.code NOT LIKE 'zzp8b1%'), '-'),
    'incidents:' || COALESCE((SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM incidents x WHERE x.recorded_at < t0), '-'),
    'environmental_results:' || COALESCE((SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM environmental_results x WHERE x.recorded_at < t0), '-'),
    'inspection_runs:' || COALESCE((SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM inspection_runs x WHERE x.recorded_at < t0), '-'),
    'company_compliance:' || COALESCE((SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM company_compliance x), '-'),
    'company_profile:' || COALESCE((SELECT md5(to_jsonb(x)::text) FROM company_profile x), '-'),
    'approval_log:' || COALESCE((SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM approval_log x WHERE x.created_at < t0), '-'),
    'journal_entries:' || COALESCE((SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM journal_entries x WHERE x.created_at < t0), '-'),
    'journal_lines:' || COALESCE((SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM journal_lines x WHERE x.created_at < t0), '-'),
    'payments:' || COALESCE((SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM payments x WHERE x.created_at < t0), '-'),
    'expenses:' || COALESCE((SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM expenses x WHERE x.created_at < t0), '-'),
    'cod_issues:' || COALESCE((SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.cod_id)) FROM cod_issues x), '-'),
    'permissions:' || COALESCE((SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.code)) FROM permissions x), '-'),
    'role_permissions:' || COALESCE((SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.role_id, x.permission_code)) FROM role_permissions x
      WHERE x.role_id IN (SELECT id FROM roles WHERE code NOT LIKE 'probe-%')), '-'),
    'compliance_settings:' || COALESCE((SELECT md5(to_jsonb(x)::text) FROM compliance_settings x), '-'),
    'ingest_settings:' || COALESCE((SELECT md5(to_jsonb(x)::text) FROM ingest_settings x), '-'))
$f$;
GRANT EXECUTE ON FUNCTION pg_temp.as_(text), pg_temp.me_() TO authenticated;
GRANT SELECT ON p8 TO authenticated;
CREATE TEMP TABLE p8_roles (who text, role text, codes integer, prices boolean, finance_view boolean, processing_view boolean, compliance_view boolean,
    compliance_pack boolean, margin text, exposure text, packs_seen bigint, pack_row bigint, preview text, pending_v26 bigint, pending_v27 bigint,
    freeze_try text) ON COMMIT DROP;
GRANT INSERT ON p8_roles TO authenticated;
`, 'open')

    // ══ ⓪ 前提与布景(属主直写的只有:物料、供应商、客户、一个我自己的可计价物质、实验室、监测参数与一个巡检员 —— 字典与主数据,不是单据)══
    let v = await run(String.raw`
DO $s$
DECLARE
    v_t0 timestamptz := now(); v_base text; d date := CURRENT_DATE - 6; v_j jsonb;
    sup uuid; cust uuid; m_p1 uuid; m_p2 uuid; m_bm uuid; m_dust uuid; ba uuid; bb uuid; bc uuid; e1 uuid;
BEGIN
    SELECT code INTO v_base FROM currencies WHERE is_base;
    IF NOT approvals_enabled() THEN RAISE EXCEPTION 'MES8B1_LIVE|approvals are off on live'; END IF;
    IF EXISTS (SELECT 1 FROM compliance_packs) OR EXISTS (SELECT 1 FROM compliance_pack_issues) THEN
        RAISE EXCEPTION 'MES8B1_LIVE|live already has a compliance pack — this proof expects none';
    END IF;
    IF EXISTS (SELECT 1 FROM compliance_settings WHERE nea_return_format IS NOT NULL OR nea_return_frequency IS NOT NULL
               OR eu_efficiency_method IS NOT NULL OR eu_efficiency_targets IS NOT NULL) THEN
        RAISE EXCEPTION 'MES8B1_LIVE|V26 / V27 are expected unset on live';
    END IF;
    IF (SELECT locked_before FROM finance_settings) >= DATE '2026-10-01' THEN
        RAISE EXCEPTION 'MES8B1_LIVE|September is already locked on live — this proof locks it itself (inside the rolled-back transaction)';
    END IF;
    IF date_trunc('month', d) <> date_trunc('month', CURRENT_DATE) OR d < DATE '2026-10-01' THEN
        RAISE EXCEPTION 'MES8B1_LIVE|the margin chain is dated % — it must sit in the open month after the September lock', d;
    END IF;
    PERFORM pg_temp.put_('t0', v_t0::text);
    PERFORM pg_temp.put_('fp', pg_temp.fp_(v_t0));
    PERFORM pg_temp.put_('locked0', (SELECT locked_before::text FROM finance_settings));
    PERFORM pg_temp.put_('pending', (SELECT COALESCE(string_agg(subject_type || ':' || code, ',' ORDER BY code), '') FROM approval_pending_documents()));
    PERFORM pg_temp.put_('rec_start', pg_temp.agree_('start'));
    PERFORM pg_temp.put_('d', d::text);

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ-PROBE-MES8B1-S', 'ZZ-PROBE-MES8B1 supplier', 'SG', 'active', 'goods_supplier') RETURNING id INTO sup;
    INSERT INTO customers (code, legal_name, country) VALUES ('ZZ-PROBE-MES8B1-C', 'ZZ-PROBE-MES8B1 customer', 'SG') RETURNING id INTO cust;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, size_format_code, chemistry)
    VALUES ('ZZ-PROBE-MES8B1-P1', 'ZZ-PROBE-MES8B1 packs NMC', 'battery_material', true, 'whole_pack', 'end_of_life', 'ev_traction', 'NMC') RETURNING id INTO m_p1;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, size_format_code)
    VALUES ('ZZ-PROBE-MES8B1-P2', 'ZZ-PROBE-MES8B1 packs', 'battery_material', true, 'whole_pack', 'end_of_life', 'ev_traction') RETURNING id INTO m_p2;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZ-PROBE-MES8B1-BM', 'ZZ-PROBE-MES8B1 black mass', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO m_bm;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZ-PROBE-MES8B1-DUST', 'ZZ-PROBE-MES8B1 dust', 'battery_material', true, 'collected_dust', 'end_of_life') RETURNING id INTO m_dust;
    -- 一个我自己的可计价物质,一条价都没有 —— "no price" 那一支(线上七种可计价金属都有价,而在册的价一条都不许动)
    INSERT INTO substances (code, name_en, name_zh, symbol, is_active, sort_order, role) VALUES ('zzp8b1', 'ZZ-PROBE-MES8B1 metal', 'f', 'Zz', true, 999, 'payable_metal');
    INSERT INTO laboratories (code, name_en, name_zh) VALUES ('ZZP8B1LAB', 'ZZ-PROBE-MES8B1 laboratory', 'f');
    INSERT INTO environmental_parameters (code, name_en, name_zh, unit, limit_value, limit_basis, is_active)
    VALUES ('zzp8b1_pm', 'ZZ-PROBE-MES8B1 particulates', 'f', 'mg/m3', 10, 'max', true);
    e1 := gen_random_uuid();
    INSERT INTO employees (id, code, legal_name, preferred_name, employment_type, work_category, hire_date)
    VALUES (e1, 'ZZ-PROBE-MES8B1-E', 'ZZ-PROBE-MES8B1 Inspector Legal', 'ZZ-PROBE-MES8B1 Inspector', 'full_time', 'office', DATE '2020-01-01');
    PERFORM pg_temp.put_('sup', sup::text); PERFORM pg_temp.put_('cust', cust::text); PERFORM pg_temp.put_('m_bm', m_bm::text);
    PERFORM pg_temp.put_('m_dust', m_dust::text); PERFORM pg_temp.put_('e1', e1::text);

    -- ── ① 收货(一次性的全码账号):A 300 · B 150 带价(审批开着 → 各一张定价申请),C 100 不带价 ──
    PERFORM pg_temp.claims_('inv');
    ba := (create_inbound_batch(p_material_id => m_p1, p_supplier_id => sup, p_quantity => 300, p_arrival_date => d - 1, p_unit_price => 2,
                                p_currency => v_base, p_safety_states => ARRAY['charged_not_discharged'],
                                p_source_reason_code => 'other', p_source_reason_note => 'ZZ-PROBE-MES8B1') ->> 'batch_id')::uuid;
    bb := (create_inbound_batch(p_material_id => m_p2, p_supplier_id => sup, p_quantity => 150, p_arrival_date => d - 1, p_unit_price => 1,
                                p_currency => v_base, p_safety_states => ARRAY['charged_not_discharged'],
                                p_source_reason_code => 'other', p_source_reason_note => 'ZZ-PROBE-MES8B1') ->> 'batch_id')::uuid;
    bc := (create_inbound_batch(p_material_id => m_p1, p_supplier_id => sup, p_quantity => 100, p_arrival_date => d - 1,
                                p_safety_states => ARRAY['charged_not_discharged'],
                                p_source_reason_code => 'other', p_source_reason_note => 'ZZ-PROBE-MES8B1') ->> 'batch_id')::uuid;
    PERFORM pg_temp.me_();
    PERFORM pg_temp.put_('ba', ba::text); PERFORM pg_temp.put_('bb', bb::text); PERFORM pg_temp.put_('bc', bc::text);
    PERFORM pg_temp.agree_('receipts');
    RAISE NOTICE 'STEP|setup|own rows (prefix ZZ-PROBE-MES8B1): supplier, customer, four materials, substance zzp8b1 (payable, no price), a laboratory, a parameter, an inspector · receipts A % (300 kg @ 2) · B % (150 kg @ 1) · C % (100 kg, no price)',
        (SELECT code FROM inbound_batches WHERE id = ba), (SELECT code FROM inbound_batches WHERE id = bb), (SELECT code FROM inbound_batches WHERE id = bc);
END $s$;
SELECT 'OUT|reqs|' || COALESCE((SELECT jsonb_agg(jsonb_build_object('id', r.id, 'batch', b.code, 'status', r.status) ORDER BY b.code)
                         FROM receipt_price_requests r JOIN inbound_batches b ON b.id = r.inbound_batch_id
                        WHERE b.id IN (pg_temp.id_('ba'), pg_temp.id_('bb'))), '[]'::jsonb)::text;
`, 'setup')
    const reqs = JSON.parse(v.reqs)
    console.log(`STEP|pricing|price requests on the two priced receipts: ${reqs.map((r) => `${r.batch} ${r.status}`).join(' · ') || 'none'}`)

    // ══ ① 定价经 CFO 批 → 落地成本;含量;两段加工;分摊;卖出一部分 ══
    v = await run(String.raw`
DO $s$
DECLARE r record; v_base text; d date := pg_temp.val_('d')::date; v_j jsonb; r1 uuid; r2 uuid; r3 uuid; o1 uuid; o2 uuid; od uuid; o3 uuid;
        t9 timestamptz; t11 timestamptz; v_sale jsonb;
BEGIN
    SELECT code INTO v_base FROM currencies WHERE is_base;
    FOR r IN SELECT rq.id FROM receipt_price_requests rq WHERE rq.inbound_batch_id IN (pg_temp.id_('ba'), pg_temp.id_('bb')) AND rq.status = 'submitted' LOOP
        v_j := pg_temp.get_('cfo', format($q$SELECT decide_receipt_price_request(%L, true, 'ZZ-PROBE-MES8B1')$q$, r.id));
    END LOOP;
    PERFORM pg_temp.agree_('receipts priced through the CFO');
    -- 含量与价:A Ni 10% · Co 5% · zzp8b1 1%;B 一种都没有(not measured);C Ni 10%;Ni 与 Co 今天一条价(我自己的行 —— 成了最新的那一条)
    INSERT INTO inbound_batch_metals (inbound_batch_id, metal, content_pct, content_source) VALUES
        (pg_temp.id_('ba'), 'ni', 10, 'manual'), (pg_temp.id_('ba'), 'co', 5, 'manual'), (pg_temp.id_('ba'), 'zzp8b1', 1, 'manual'), (pg_temp.id_('bc'), 'ni', 10, 'manual');
    INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date, source, notes) VALUES
        ('ni', 16000, d - 2, 'broker_quote', 'ZZ-PROBE-MES8B1'), ('co', 31000, d - 2, 'broker_quote', 'ZZ-PROBE-MES8B1');
    t9 := (d::timestamp + interval '9 hours') AT TIME ZONE 'Asia/Singapore';
    t11 := (d::timestamp + interval '11 hours') AT TIME ZONE 'Asia/Singapore';
    PERFORM pg_temp.claims_('inv');
    -- 第一炉:A 200 + B 100 → 黑粉 170 + 粉尘 80(sweepings 20,余 30 结平)
    r1 := commit_processing_run(d, 'ZZ-PROBE-MES8B1 R1', NULL,
            jsonb_build_array(jsonb_build_object('inbound_batch_id', pg_temp.id_('ba'), 'quantity_consumed', 200),
                              jsonb_build_object('inbound_batch_id', pg_temp.id_('bb'), 'quantity_consumed', 100)),
            jsonb_build_array(jsonb_build_object('material_id', pg_temp.id_('m_bm'), 'weight_kg', 170),
                              jsonb_build_object('material_id', pg_temp.id_('m_dust'), 'weight_kg', 80)),
            'weight', NULL, NULL, 'battery_powder_line', p_started_at => t9, p_ended_at => t11, p_shift_code => 'day');
    PERFORM record_run_loss(r1, 'sweepings', 20);
    PERFORM close_run_balance(r1, 'ZZ-PROBE-MES8B1: 30 kg not yet accounted for (test run)');
    SELECT po.output_batch_id INTO o1 FROM processing_outputs po JOIN output_batches ob ON ob.id = po.output_batch_id WHERE po.run_id = r1 AND ob.material_id = pg_temp.id_('m_bm');
    SELECT po.output_batch_id INTO od FROM processing_outputs po JOIN output_batches ob ON ob.id = po.output_batch_id WHERE po.run_id = r1 AND ob.material_id = pg_temp.id_('m_dust');
    PERFORM set_output_safety_states(o1, ARRAY['discharged_verified']);
    v_j := allocate_processing_costs(r1);
    PERFORM pg_temp.me_();
    PERFORM pg_temp.agree_('first stage allocated');
    PERFORM pg_temp.claims_('inv');
    -- 第二炉:O1 100 → 黑粉 90(moisture 4,余 6 结平)
    r2 := commit_processing_run(d, 'ZZ-PROBE-MES8B1 R2', NULL,
            jsonb_build_array(jsonb_build_object('output_batch_id', o1, 'quantity_consumed', 100)),
            jsonb_build_array(jsonb_build_object('material_id', pg_temp.id_('m_bm'), 'weight_kg', 90)),
            'weight', NULL, NULL, 'battery_powder_line', p_started_at => t9 + interval '3 hours', p_ended_at => t11 + interval '3 hours', p_shift_code => 'day');
    PERFORM record_run_loss(r2, 'moisture', 4);
    PERFORM close_run_balance(r2, 'ZZ-PROBE-MES8B1: 6 kg not yet accounted for (test run)');
    SELECT po.output_batch_id INTO o2 FROM processing_outputs po WHERE po.run_id = r2;
    PERFORM set_output_safety_states(o2, ARRAY['discharged_verified']);
    v_j := allocate_processing_costs(r2);
    PERFORM pg_temp.me_();
    PERFORM pg_temp.agree_('second stage allocated');
    PERFORM pg_temp.claims_('inv');
    -- 卖出 O2 的 50 kg,单价 9(过账:收入、应收、销售成本)
    v_sale := record_output_sale(o2, 50, 9, v_base, NULL, pg_temp.id_('cust'), d + 1, 'ZZ-PROBE-MES8B1 part of the second-stage output');
    PERFORM pg_temp.me_();
    PERFORM pg_temp.agree_('sale posted');
    -- 没价的那一条腿:C(没定价)100 → 黑粉 85;分摊照跑(投入没价 → 成本不完整),卖 10 kg
    PERFORM pg_temp.claims_('inv');
    r3 := commit_processing_run(d, 'ZZ-PROBE-MES8B1 R3', NULL,
            jsonb_build_array(jsonb_build_object('inbound_batch_id', pg_temp.id_('bc'), 'quantity_consumed', 100)),
            jsonb_build_array(jsonb_build_object('material_id', pg_temp.id_('m_bm'), 'weight_kg', 85)),
            'weight', NULL, NULL, 'battery_powder_line', p_started_at => t9 + interval '6 hours', p_ended_at => t11 + interval '6 hours', p_shift_code => 'day');
    PERFORM record_run_loss(r3, 'sweepings', 15);
    SELECT po.output_batch_id INTO o3 FROM processing_outputs po WHERE po.run_id = r3;
    PERFORM set_output_safety_states(o3, ARRAY['discharged_verified']);
    v_j := allocate_processing_costs(r3);
    PERFORM record_output_sale(o3, 10, 9, v_base, NULL, pg_temp.id_('cust'), d + 1, 'ZZ-PROBE-MES8B1 from the unpriced leg');
    PERFORM pg_temp.me_();
    PERFORM pg_temp.agree_('unpriced leg sold');
    PERFORM pg_temp.put_('o1', o1::text); PERFORM pg_temp.put_('od', od::text); PERFORM pg_temp.put_('o2', o2::text); PERFORM pg_temp.put_('o3', o3::text);
    RAISE NOTICE 'STEP|chain|A % and B % priced (% / %) · R1 % (A 200 + B 100 → % 170 + % 80) · R2 % (% 100 → % 90) · % sells 50 kg of % at 9 · R3 % (C 100 → % 85, cost incomplete %) sells 10',
        (SELECT code FROM inbound_batches WHERE id = pg_temp.id_('ba')), (SELECT code FROM inbound_batches WHERE id = pg_temp.id_('bb')),
        (SELECT pricing_status FROM inbound_batches WHERE id = pg_temp.id_('ba')), (SELECT pricing_status FROM inbound_batches WHERE id = pg_temp.id_('bb')),
        (SELECT code FROM processing_runs WHERE id = r1), (SELECT code FROM output_batches WHERE id = o1), (SELECT code FROM output_batches WHERE id = od),
        (SELECT code FROM processing_runs WHERE id = r2), (SELECT code FROM output_batches WHERE id = o1), (SELECT code FROM output_batches WHERE id = o2),
        v_sale ->> 'code', (SELECT code FROM output_batches WHERE id = o2),
        (SELECT code FROM processing_runs WHERE id = r3), (SELECT code FROM output_batches WHERE id = o3),
        (SELECT cost_incomplete FROM processing_outputs WHERE output_batch_id = o3);
END $s$;
-- 独立地算一遍 A 的毛利与在库成本(不经 inbound_batch_margin):A 在第一炉的份额 200 / 300,第二炉全是 O1 → 份额不变
SELECT 'OUT|indep|' || jsonb_build_object(
    'u1', (SELECT unit_cost_base FROM processing_outputs WHERE output_batch_id = pg_temp.id_('o1')),
    'ud', (SELECT unit_cost_base FROM processing_outputs WHERE output_batch_id = pg_temp.id_('od')),
    'u2', (SELECT unit_cost_base FROM processing_outputs WHERE output_batch_id = pg_temp.id_('o2')),
    'rev2', (SELECT sum(amount_base) FROM sales_records WHERE output_batch_id = pg_temp.id_('o2')),
    'qty2', (SELECT sum(quantity) FROM sales_records WHERE output_batch_id = pg_temp.id_('o2')),
    'inc3', (SELECT cost_incomplete FROM processing_outputs WHERE output_batch_id = pg_temp.id_('o3')),
    'u3', (SELECT unit_cost_base FROM processing_outputs WHERE output_batch_id = pg_temp.id_('o3')))::text;
SELECT 'OUT|mA|' || pg_temp.get_('fin', format($q$SELECT inbound_batch_margin(%L)$q$, pg_temp.id_('ba')))::text;
SELECT 'OUT|mC|' || pg_temp.get_('fin', format($q$SELECT inbound_batch_margin(%L)$q$, pg_temp.id_('bc')))::text;
`, 'margin chain')
    const ind = JSON.parse(v.indep), mA = JSON.parse(v.mA), mC = JSON.parse(v.mC)
    const sh = 200 / 300
    const r2 = (x) => Math.round(x * 100) / 100
    const expMargin = r2(sh * (Number(ind.rev2) - Number(ind.u2) * Number(ind.qty2)))
    const expRev = r2(sh * Number(ind.rev2))
    // 落地单价的读者只给 DEFINER(刻意没授给 authenticated)—— 它的值取函数自己报的那一个,并断言它就是收货价 2(这一批没有运费)
    ind.landed = mA.landed_unit_cost
    const expOnHand = r2(sh * (70 * Number(ind.u1) + 80 * Number(ind.ud) + 40 * Number(ind.u2)) + 100 * Number(ind.landed))
    must(ind.u1 !== null && ind.u2 !== null && ind.ud !== null && Number(ind.landed) === 2, `the priced path must carry unit costs and A's landed cost 2: ${v.indep} / landed ${mA.landed_unit_cost}`)
    must(mA.margin_state === 'computed' && mA.computable === true && Math.abs(Number(mA.margin_base) - expMargin) <= 0.01
        && Math.abs(Number(mA.revenue_base) - expRev) <= 0.01 && Number(mA.qty_sold) === Math.round(sh * 50 * 1000) / 1000,
        `A's margin: expected ${expMargin} (revenue ${expRev}) from an independent sum, got ${JSON.stringify({ ...mA, lines: undefined })}`)
    must(Math.abs(Number(mA.on_hand_at_cost_base) - expOnHand) <= 0.02 && Number(mA.on_hand_own) === 100,
        `A's unsold share at cost: expected ${expOnHand} (own 100 kg × ${ind.landed} + 2/3 of O1 70 · dust 80 · O2 40 at their unit costs), got ${mA.on_hand_at_cost_base}`)
    must(mA.lines.length === 3 && mA.lines.every((l) => Number(l.share).toFixed(6) === sh.toFixed(6)), `A reaches three outputs at a 2/3 share: ${JSON.stringify(mA.lines)}`)
    must(mC.margin_state === 'not_computable' && mC.margin_base === null && mC.on_hand_at_cost_base === null
        && mC.reasons.some((x) => x.code === 'inbound_unpriced') && mC.reasons.some((x) => x.code === 'output_cost_incomplete' || x.code === 'output_no_unit_cost'),
        `C's margin must be not computable (NULL, never 0) with its unpriced leg named: ${JSON.stringify({ ...mC, lines: undefined })}`)
    console.log(`STEP|margin|${mA.code}: unit costs O1 ${ind.u1} · dust ${ind.ud} · O2 ${ind.u2}, landed ${ind.landed} · sold ${mA.qty_sold} (2/3 of 50) · revenue ${mA.revenue_base} · cost of sold ${mA.cost_of_sold_base} · margin ${mA.margin_base} (independent ${expMargin}) · unsold at cost ${mA.on_hand_at_cost_base} (independent ${expOnHand}; own ${mA.on_hand_own} kg + downstream ${mA.on_hand_downstream} kg) · revenue source ${mA.revenue_source}`)
    console.log(`STEP|not computable|${mC.code}: margin_state ${mC.margin_state}, margin ${mC.margin_base}, on hand at cost ${mC.on_hand_at_cost_base} · reasons ${mC.reasons.map((x) => `${x.code}:${x.batch_code}`).join(', ')}`)

    // ══ ② 敞口:两种可计价金属带今天的价、我自己的那一种没有价、B 没有含量 ══
    v = await run(String.raw`
SELECT 'OUT|exp|' || pg_temp.get_('fin', $q$SELECT inventory_metal_exposure()$q$)::text;
SELECT 'OUT|codes|' || jsonb_build_object('A', (SELECT code FROM inbound_batches WHERE id = pg_temp.id_('ba')), 'B', (SELECT code FROM inbound_batches WHERE id = pg_temp.id_('bb')),
                                         'C', (SELECT code FROM inbound_batches WHERE id = pg_temp.id_('bc')), 'd', pg_temp.val_('d'))::text;
`, 'exposure')
    const ex = JSON.parse(v.exp), cd = JSON.parse(v.codes)
    const metal = (m) => ex.metals.find((x) => x.metal === m)
    const priceDate = new Date(Date.parse(cd.d) - 2 * 86400000).toISOString().slice(0, 10)
    const ni = metal('ni'), co = metal('co'), zz = metal('zzp8b1')
    const lineOf = (m, code) => (m?.batch_lines || []).find((l) => l.code === code)
    must(ni && ni.state === 'priced' && ni.price_date === priceDate && Number(ni.price_usd_per_tonne) === 16000 && Number(lineOf(ni, cd.A)?.metal_kg) === 10,
        `Ni: priced at my 16,000 dated ${priceDate}, A's 100 kg × 10% = 10 kg: ${JSON.stringify({ ...ni, batch_lines: lineOf(ni, cd.A) })}`)
    must(co && co.state === 'priced' && co.price_date === priceDate && Number(lineOf(co, cd.A)?.metal_kg) === 5, `Co: priced, dated ${priceDate}, A's 5 kg: ${JSON.stringify({ ...co, batch_lines: lineOf(co, cd.A) })}`)
    must(zz && zz.state === 'no_price' && zz.value_usd === null && Number(zz.metal_kg) === 1, `zzp8b1: no price, not valued, its 1 kg listed: ${JSON.stringify(zz)}`)
    must(ex.not_measured.some((x) => x.code === cd.B && Number(x.kg) === 50) && !ex.not_measured.some((x) => x.code === cd.A),
        `B (no content, 50 kg left) is not measured; A is measured: ${JSON.stringify(ex.not_measured.filter((x) => [cd.A, cd.B].includes(x.code)))}`)
    must(ex.complete === false, 'with a metal unpriced and batches unmeasured the total must say it is incomplete')
    console.log(`STEP|exposure|as of ${ex.as_of}: Ni priced ${ni.price_usd_per_tonne}/t dated ${ni.price_date} (${ni.metal_kg} kg in ${ni.batches} batches, ${ni.value_usd} USD; ${cd.A} contributes ${lineOf(ni, cd.A).metal_kg} kg) · Co ${co.price_usd_per_tonne}/t dated ${co.price_date} (${co.metal_kg} kg, ${co.value_usd} USD) · zzp8b1 «${zz.state}», ${zz.metal_kg} kg, value ${zz.value_usd} · not measured ${ex.not_measured.length} batches / ${ex.not_measured_kg} kg incl. ${cd.B} 50 kg · total priced ${ex.value_usd_priced} USD · complete ${ex.complete}`)

    // ══ ③ 九月:我自己的一件工伤、一条监测结果、一次巡检(带发现)→ 锁九月 → 冻 ══
    v = await run(String.raw`
DO $s$
DECLARE v_j jsonb; tpl uuid; rn uuid; M date := DATE '2026-09-01';
BEGIN
    PERFORM pg_temp.claims_('inv');
    v_j := record_incident('injury', (M + 9)::timestamptz + interval '2 hours', 'ZZ-PROBE-MES8B1-WHAT a cell vented', 'ZZ-PROBE-MES8B1-ACTION first aid', true,
                           p_responsible_name => 'ZZ-PROBE-MES8B1-RESPONSIBLE Lead', p_injured_person_name => 'ZZ-PROBE-MES8B1-INJURED Visitor',
                           p_injury_nature => 'ZZ-PROBE-MES8B1-NATURE burn', p_injury_treatment => 'ZZ-PROBE-MES8B1-TREATMENT clinic', p_days_lost => 2);
    PERFORM pg_temp.put_('inc', v_j ->> 'code');
    PERFORM record_incident_update((v_j ->> 'incident_id')::uuid, 'nea_notified', (M + 9)::timestamptz + interval '4 hours', 'ZZ-PROBE-MES8B1-NEA-REF');
    v_j := record_environmental_result('zzp8b1_pm', 'ZZ-PROBE-MES8B1 stack', M + 4, 'ZZP8B1LAB', 'ZZ-PROBE-MES8B1-R1', 4.5);
    tpl := (save_inspection_template(NULL, 'ZZ-PROBE-MES8B1-T', 'ZZ-PROBE-MES8B1 checklist', 'Warehouse', '["extinguisher", "spill kit", "signage"]'::jsonb) ->> 'template_id')::uuid;
    rn := (record_inspection_run(tpl, (M + 2)::timestamptz + interval '2 hours', pg_temp.id_('e1'),
           '[{"position": 1, "result": "pass"}, {"position": 2, "result": "fail", "note": "ZZ-PROBE-MES8B1-NOTE"}, {"position": 3, "result": "na"}]'::jsonb) ->> 'run_id')::uuid;
    PERFORM record_inspection_finding(rn, 2, 'ZZ-PROBE-MES8B1-CORRECTIVE restock the spill kit', pg_temp.id_('e1'), DATE '2026-10-31');
    PERFORM pg_temp.put_('ins', (SELECT code FROM inspection_runs WHERE id = rn));
    PERFORM pg_temp.me_();
END $s$;
SELECT 'OUT|open|' || pg_temp.try_('cp', $q$SELECT freeze_compliance_pack(DATE '2026-09-01')$q$);
SELECT 'OUT|monthOpen|' || pg_temp.get_('c_cfo', $q$SELECT compliance_pack_month_status(DATE '2026-09-01')$q$)::text;
-- 锁到 2026-10-01(属主,一定回滚的事务里 —— 线上没有一个月被锁或被开)
UPDATE finance_settings SET locked_before = DATE '2026-10-01' WHERE id;
SELECT 'OUT|arm|' || COALESCE(pg_temp.get_('cp', $q$SELECT jsonb_agg(item_code ORDER BY item_code) FROM operations_now WHERE item_type = 'compliance_pack_not_frozen'$q$), '[]'::jsonb)::text;
SELECT 'OUT|armViewer|' || pg_temp.get_('cv', $q$SELECT to_jsonb(count(*)) FROM operations_now WHERE item_type = 'compliance_pack_not_frozen'$q$)::text;
SELECT 'OUT|monthLocked|' || pg_temp.get_('c_cfo', $q$SELECT compliance_pack_month_status(DATE '2026-09-01')$q$)::text;
SELECT 'OUT|october|' || pg_temp.try_('cp', $q$SELECT freeze_compliance_pack(DATE '2026-10-01')$q$);
SELECT 'OUT|viewerFreeze|' || pg_temp.try_('cv', $q$SELECT freeze_compliance_pack(DATE '2026-09-01')$q$);
SELECT 'OUT|preview|' || pg_temp.get_('cv', $q$SELECT compliance_pack_data(DATE '2026-09-01')$q$)::text;
SELECT 'OUT|pk1|' || pg_temp.get_('cp', $q$SELECT freeze_compliance_pack(DATE '2026-09-01', 'ZZ-PROBE-MES8B1 first freeze')$q$)::text;
SELECT 'OUT|stored1|' || (SELECT payload FROM compliance_packs WHERE code = 'CPK-2026-09')::text;
SELECT 'OUT|armAfter|' || COALESCE(pg_temp.get_('cp', $q$SELECT jsonb_agg(item_code ORDER BY item_code) FROM operations_now WHERE item_type = 'compliance_pack_not_frozen'$q$), '[]'::jsonb)::text;
SELECT 'OUT|monthFrozen|' || pg_temp.get_('c_cfo', $q$SELECT compliance_pack_month_status(DATE '2026-09-01')$q$)::text;
SELECT 'OUT|pending|' || pg_temp.get_('c_cto', $q$SELECT jsonb_agg(value_code ORDER BY value_code) FROM pending_values WHERE value_code IN ('V26', 'V27')$q$)::text;
`, 'freeze')
    must(v.open === 'COMPLIANCE_PACK_MONTH_NOT_LOCKED|2026-09|2026-08-01', `freezing September while it is open: «${v.open}»`)
    const mOpen = JSON.parse(v.monthOpen), mLocked = JSON.parse(v.monthLocked), mFrozen = JSON.parse(v.monthFrozen)
    must(mOpen.locked === false && mOpen.pack_code === null, `month-end status while open: ${v.monthOpen}`)
    must(JSON.stringify(JSON.parse(v.arm)) === '["2026-08","2026-09"]' && v.armViewer === '0', `the reminder: each locked month since 2026-08 without a pack, for the freezer only: ${v.arm} / viewer ${v.armViewer}`)
    must(mLocked.locked === true && mLocked.pack_code === null, `month-end status once locked, before the freeze (the warning line): ${v.monthLocked}`)
    must(v.october === 'COMPLIANCE_PACK_MONTH_NOT_LOCKED|2026-10|2026-10-01', `freezing the still-open October: «${v.october}»`)
    must(v.viewerFreeze === 'PERMISSION_DENIED|action.compliance_pack', `a compliance viewer freezing: «${v.viewerFreeze}»`)
    const pk1 = JSON.parse(v.pk1), stored1 = JSON.parse(v.stored1), preview = JSON.parse(v.preview)
    must(pk1.code === 'CPK-2026-09' && JSON.stringify(stored1) === JSON.stringify(preview), `the frozen payload is the preview of that moment, numbered CPK-2026-09: ${pk1.code}`)
    const incCode = (await run(`SELECT 'OUT|x|' || pg_temp.val_('inc') || '#' || pg_temp.val_('ins');`, 'codes')).x.split('#')
    const inc = stored1.incidents.find((i) => i.code === incCode[0])
    must(inc && inc.kind_code === 'injury' && inc.nea_reportable === true && inc.notified_on === '2026-09-10', `section 4 carries my incident with its NEA dates: ${JSON.stringify(stored1.incidents)}`)
    must(stored1.environmental.some((e) => e.parameter_code === 'zzp8b1_pm' && e.judgement === 'within' && Number(e.limit_value) === 10), `section 5 carries my result with its limit: ${JSON.stringify(stored1.environmental)}`)
    const run_ = stored1.inspections.done.find((r) => r.code === incCode[1])
    must(run_ && run_.passed === 1 && run_.failed === 1 && run_.not_applicable === 1
        && stored1.inspections.findings_open_at_month_end.some((f) => f.run_code === incCode[1]), `section 6 carries my inspection and its open finding: ${JSON.stringify(stored1.inspections)}`)
    must(stored1.licence.in_force && stored1.licence.in_force.cert_no === 'WDL-21-2-5380', `section 3: the licence in force at month end: ${JSON.stringify(stored1.licence.in_force)}`)
    must(Array.isArray(stored1.processing_balance) && Array.isArray(stored1.stock_rollforward), 'sections 1 and 2 are present')
    must(stored1.nea_return.state === 'not_set' && stored1.nea_return.value_code === 'V26' && stored1.eu_efficiency.state === 'not_set' && stored1.eu_efficiency.value_code === 'V27',
        `sections 7 and 8: ${JSON.stringify(stored1.nea_return)} / ${JSON.stringify({ ...stored1.eu_efficiency, masses: undefined })}`)
    const txt1 = JSON.stringify(stored1)
    for (const needle of ['INJURED', 'NATURE', 'TREATMENT', 'WHAT', '-ACTION', 'RESPONSIBLE', 'Inspector', '-NOTE', 'days_lost'])
        must(!txt1.includes(needle), `the frozen pack carries «${needle}» — no injury detail, no narrative, no names`)
    must(JSON.stringify(JSON.parse(v.armAfter)) === '["2026-08"]' && mFrozen.locked === true && mFrozen.pack_code === 'CPK-2026-09',
        `after the freeze: arm ${v.armAfter}, month-end ${v.monthFrozen}`)
    must(JSON.stringify(JSON.parse(v.pending)) === '["V26","V27"]', `pending values V26 / V27 one row each: ${v.pending}`)
    console.log(`STEP|lock|September open → «${v.open}» · month-end reads locked ${mOpen.locked} · lock to 2026-10-01 (rolled back) → reminder ${v.arm} for the freezer, ${v.armViewer} rows for a viewer · month-end locked ${mLocked.locked}, pack ${mLocked.pack_code} (the warning) · October «${v.october}» · a viewer «${v.viewerFreeze}»`)
    console.log(`STEP|pack|${pk1.code} frozen = the preview of that moment · §1 ${stored1.processing_balance.length} balance lines · §2 ${stored1.stock_rollforward.length} roll-forward row(s) · §3 licence ${stored1.licence.in_force.cert_no}, ${stored1.licence.on_hand_by_category.length} categories, uncategorised ${stored1.licence.uncategorised_tonnes} t, ${stored1.licence.ceiling_checks.length} check groups · §4 ${stored1.incidents.length} incident(s) incl. ${inc.code} (injury, NEA-reportable, notified ${inc.notified_on}) · §5 ${stored1.environmental.length} result(s) · §6 ${stored1.inspections.done.length} inspection(s), ${stored1.inspections.findings_open_at_month_end.length} open finding(s) · §7 ${stored1.nea_return.state} (V26) · §8 ${stored1.eu_efficiency.state} (V27) · no injury detail, narrative or name in the payload · after: reminder ${v.armAfter}, month-end ${mFrozen.pack_code} · pending ${v.pending}`)

    // ══ ④ 重出 -2:没理由按名拒;带理由 → -2,旧的那一份一个字不动 ══
    v = await run(String.raw`
SELECT 'OUT|noReason|' || pg_temp.try_('cp', $q$SELECT freeze_compliance_pack(DATE '2026-09-01')$q$);
DO $s$ BEGIN
    PERFORM pg_temp.claims_('inv');
    PERFORM pg_temp.put_('late', record_incident('near_miss', DATE '2026-09-20'::timestamptz + interval '3 hours', 'ZZ-PROBE-MES8B1 late', 'ZZ-PROBE-MES8B1 late', false,
                                                 p_responsible_name => 'ZZ-PROBE-MES8B1 Lead') ->> 'code');
    PERFORM pg_temp.me_();
END $s$;
SELECT 'OUT|same1|' || ((SELECT payload FROM compliance_packs WHERE code = 'CPK-2026-09')::text = ${lit(v.stored1)})::text;
SELECT 'OUT|pk2|' || pg_temp.get_('cp', $q$SELECT freeze_compliance_pack(DATE '2026-09-01', NULL, 'ZZ-PROBE-MES8B1 a near miss was recorded after the freeze')$q$)::text;
SELECT 'OUT|rows|' || (SELECT jsonb_agg(jsonb_build_object('code', code, 'superseded_by', (SELECT p2.code FROM compliance_packs p2 WHERE p2.id = p.superseded_by),
        'reason', superseded_reason, 'incidents', jsonb_array_length(payload -> 'incidents')) ORDER BY code) FROM compliance_packs p)::text;
SELECT 'OUT|same2|' || ((SELECT payload FROM compliance_packs WHERE code = 'CPK-2026-09')::text = ${lit(v.stored1)})::text;
SELECT 'OUT|late|' || pg_temp.val_('late');
`, 'reissue')
    const pk2 = JSON.parse(v.pk2), rows = JSON.parse(v.rows)
    must(v.noReason === 'COMPLIANCE_PACK_SUPERSEDE_REASON_REQUIRED|CPK-2026-09', `a second freeze without a reason: «${v.noReason}»`)
    must(v.same1 === 'true' && v.same2 === 'true', 'the first pack keeps its payload through a later incident and through the re-issue')
    must(pk2.code === 'CPK-2026-09-2' && pk2.superseded === 'CPK-2026-09' && rows.length === 2 && rows[0].superseded_by === 'CPK-2026-09-2'
        && rows[0].reason.startsWith('ZZ-PROBE-MES8B1 a near miss') && rows[1].incidents === rows[0].incidents + 1, `re-issue: ${v.rows}`)
    console.log(`STEP|reissue|without a reason «${v.noReason}» · ${v.late} recorded late → CPK-2026-09 unchanged · with a reason → ${pk2.code}; CPK-2026-09 superseded by it, reason kept, payload identical, ${rows[0].incidents} incidents vs ${rows[1].incidents} in the new one`)

    // ══ ⑤ PDF:从冻下来的那一行渲染 → 存档人上传 → 记哈希 → 只读者下载、重算、读纸 → 改坏字节 = 409 那一支 ══
    v = await run(`SELECT 'OUT|row2|' || (SELECT to_jsonb(p) FROM compliance_packs p WHERE p.code = 'CPK-2026-09-2')::text;
SELECT 'OUT|row1id|' || (SELECT id FROM compliance_packs WHERE code = 'CPK-2026-09');`, 'frozen row')
    const row2 = JSON.parse(v.row2), row1id = v.row1id
    const buf = await renderCompliancePackPdf(packDocFrom(row2))
    const digest = sha(buf)
    const path = `${row2.id}/${digest}.pdf`
    planObjectDelete(path)
    const upView = await upload(who.cv.token, `${row2.id}/${randomUUID()}.pdf`, buf)
    must(upView.status >= 400, `a compliance viewer must not upload: HTTP ${upView.status} ${upView.text}`)
    const up = await upload(who.cp.token, path, buf)
    must(up.status === 200, `the freezer could not upload (HTTP ${up.status} ${up.text})`)
    v = await run(String.raw`
SELECT 'OUT|rec|' || pg_temp.get_('cp', format($q$SELECT record_compliance_pack_issue(%L, %L, %L)$q$, ${lit(row2.id)}, ${lit(path)}, ${lit(digest.toUpperCase())}))::text;
SELECT 'OUT|recAgain|' || pg_temp.try_('cp', format($q$SELECT record_compliance_pack_issue(%L, %L, %L)$q$, ${lit(row2.id)}, ${lit(row2.id + '/again.pdf')}, ${lit(digest)}));
SELECT 'OUT|recOld|' || pg_temp.try_('cp', format($q$SELECT record_compliance_pack_issue(%L, %L, %L)$q$, ${lit(row1id)}, ${lit(row1id + '/x.pdf')}, repeat('a', 64)));
SELECT 'OUT|recPath|' || pg_temp.try_('cp', format($q$SELECT record_compliance_pack_issue(%L, 'elsewhere/x.pdf', %L)$q$, ${lit(row2.id)}, repeat('b', 64)));
SELECT 'OUT|recView|' || pg_temp.try_('cv', format($q$SELECT record_compliance_pack_issue(%L, %L, %L)$q$, ${lit(row2.id)}, ${lit(row2.id + '/v.pdf')}, repeat('c', 64)));
`, 'record')
    const rec = JSON.parse(v.rec)
    must(rec.sha256 === digest && rec.version === 1, `record_compliance_pack_issue stored ${rec.sha256} v${rec.version}, expected the lower-case ${digest} v1`)
    must(v.recAgain === `COMPLIANCE_PACK_BYTES_ALREADY_RECORDED|CPK-2026-09-2|1`, `the same bytes again: «${v.recAgain}»`)
    must(v.recOld.startsWith('COMPLIANCE_PACK_SUPERSEDED|CPK-2026-09|'), `the superseded pack: «${v.recOld}»`)
    must(v.recPath === 'COMPLIANCE_PACK_ISSUE_PATH_INVALID|CPK-2026-09-2', `a path outside the pack's folder: «${v.recPath}»`)
    must(v.recView === 'PERMISSION_DENIED|action.compliance_pack', `a viewer recording bytes: «${v.recView}»`)
    const dl = await download(who.cv.token, path)
    must(dl.status === 200 && sha(dl.buf) === digest, `the viewer's download: HTTP ${dl.status}, sha ${sha(dl.buf)} vs recorded ${digest}`)
    const t = pdfText(dl.buf)
    const lateCode = (await run(`SELECT 'OUT|x|' || pg_temp.val_('late');`, 'late')).x
    const expectPaper = ['CPK-2026-09-2', '2026-09', incCode[0], lateCode, incCode[1], 'WDL-21-2-5380', 'V26', 'V27']
    for (const needle of expectPaper) must(t.text.includes(needle), `the stored PDF does not say «${needle}»`)
    for (const needle of ['INJURED', 'NATURE', 'TREATMENT', 'ZZ-PROBE-MES8B1 Inspector'])
        must(!t.text.includes(needle), `the stored PDF carries «${needle}»`)
    must(!/[一-鿿]/.test(t.text), 'the compliance pack must be English')
    console.log(`STEP|pdf|CPK-2026-09-2: rendered from the frozen row (${buf.length} bytes, ${t.pages} page${t.pages === 1 ? '' : 's'}) · the viewer's upload refused (HTTP ${upView.status}) · the freezer uploaded ${BUCKET}/${path.slice(0, 44)}… · sha recorded (sent upper-case, stored ${digest.slice(0, 12)}…, version 1) · the same bytes again «${v.recAgain}» · on the superseded CPK-2026-09 «${v.recOld.split('|').slice(0, 2).join('|')}» · a path elsewhere «${v.recPath}» · a viewer recording «${v.recView}» · the viewer downloaded, sha matches · the paper says ${expectPaper.map((x) => `«${x}»`).join(' ')}, no injury detail, no inspector's name, no Chinese`)

    // 冻住:冻下来之后再记一件事 —— 那一行与那份字节都不动
    v = await run(String.raw`
DO $s$ BEGIN
    PERFORM pg_temp.claims_('inv');
    PERFORM record_incident('near_miss', DATE '2026-09-25'::timestamptz + interval '3 hours', 'ZZ-PROBE-MES8B1 later still', 'x', false, p_responsible_name => 'ZZ-PROBE-MES8B1 Lead');
    PERFORM pg_temp.me_();
END $s$;
SELECT 'OUT|rowSame|' || ((SELECT to_jsonb(p) FROM compliance_packs p WHERE p.code = 'CPK-2026-09-2') = ${lit(JSON.stringify(row2))}::jsonb)::text;
SELECT 'OUT|previewNow|' || jsonb_array_length(pg_temp.get_('cv', $q$SELECT compliance_pack_data(DATE '2026-09-01')$q$) -> 'incidents');
`, 'frozen')
    const again = await download(who.cv.token, path)
    must(v.rowSame === 'true' && sha(again.buf) === digest && Number(v.previewNow) === row2.payload.incidents.length + 1,
        `frozen: row same ${v.rowSame}, bytes same ${sha(again.buf) === digest}, live preview incidents ${v.previewNow} vs frozen ${row2.payload.incidents.length}`)
    const reRender = await renderCompliancePackPdf(packDocFrom(row2))
    must(!pdfText(reRender).text.includes('later still'), 'a re-render from the frozen row must not pick up the later incident')
    console.log(`STEP|frozen|an incident recorded after the freeze → CPK-2026-09-2's row identical, stored bytes identical, a re-render from the row still lists ${row2.payload.incidents.length} incidents · the live preview now lists ${v.previewNow}`)

    // 改坏字节 → 下载的哈希对不上记下的 = 路由的 409
    const tampered = Buffer.concat([buf, Buffer.from('\n% tampered\n')])
    const put = await upload(null, path, tampered, { asService: true, upsert: true })
    must(put.status === 200, `service-role overwrite for the tamper test: HTTP ${put.status} ${put.text}`)
    const bad = await download(who.cv.token, path)
    must(bad.status === 200 && sha(bad.buf) !== digest && bad.buf.length === tampered.length, `the altered bytes should no longer match (download ${bad.status}, ${bad.buf.length} bytes)`)
    console.log(`STEP|tampered|CPK-2026-09-2: bytes overwritten with the service role (+12 bytes) → downloaded sha ${sha(bad.buf).slice(0, 12)}… ≠ recorded ${digest.slice(0, 12)}… → the route answers 409 (route.ts: sha !== issue.sha256; check-pdf-routes CPK-409 proves that branch)`)

    // 桶的删除策略:记下了的删不掉;没记下的孤儿存档人删得掉;只读者一个都删不掉
    const orphan = `${row2.id}/${randomUUID()}.pdf`
    planObjectDelete(orphan)
    const upO = await upload(who.cp.token, orphan, Buffer.from('%PDF-1.4\n% orphan probe\n'))
    must(upO.status === 200, `uploading an orphan as the freezer: HTTP ${upO.status} ${upO.text}`)
    v = await run(String.raw`
SELECT set_config('storage.allow_delete_query', 'true', true) \g /dev/null
CREATE FUNCTION pg_temp.del_(p_who text, p_name text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE n bigint; r text;
BEGIN
    BEGIN
        PERFORM pg_temp.as_(p_who);
        DELETE FROM storage.objects WHERE bucket_id = 'compliance-documents' AND name = p_name;
        GET DIAGNOSTICS n = ROW_COUNT;
        RAISE EXCEPTION 'MES8B1_DELETED|%', n;
    EXCEPTION WHEN OTHERS THEN
        r := SQLERRM;
    END;
    PERFORM pg_temp.me_();
    RETURN CASE WHEN r LIKE 'MES8B1_DELETED|%' THEN split_part(r, '|', 2) ELSE r END;
END $f$;
SELECT 'OUT|delRecorded|' || pg_temp.del_('cp', ${lit(path)});
SELECT 'OUT|delView|' || pg_temp.del_('cv', ${lit(orphan)});
SELECT 'OUT|delOrphan|' || pg_temp.del_('cp', ${lit(orphan)});
SELECT set_config('storage.allow_delete_query', '', true) \g /dev/null
`, 'delete policy')
    must(v.delRecorded === '0', `a recorded object must not be deletable: deleted ${v.delRecorded}`)
    must(v.delView === '0', `a compliance viewer must not delete an orphan: ${v.delView}`)
    must(v.delOrphan === '1', `the freezer should be able to delete an unrecorded orphan: ${v.delOrphan}`)
    const rmO = await removeAs(who.cp.token, [orphan])
    must(rmO.status === 200 && rmO.removed === 1, `removing the orphan through the Storage API as the freezer: HTTP ${rmO.status}, removed ${rmO.removed}`)
    console.log(`STEP|bucket policy|as the freezer, a DELETE of the recorded object touches 0 rows · a viewer deletes 0 · an unrecorded orphan: the freezer deletes 1 in SQL (rolled back) and removes it through the Storage API (HTTP ${rmO.status}, 1 removed)`)

    // ══ ⑥ 逐角色读数表(七个真角色【此刻的码】的克隆,只读)══
    for (const r of ROLE_CLONES) {
        const key = `c_${r}`
        v = await run(String.raw`
DO $s$
DECLARE v_pk bigint; v_pr bigint; v_26 bigint; v_27 bigint; v_p boolean; v_fv boolean; v_prv boolean; v_cv boolean; v_cp boolean;
BEGIN
    PERFORM pg_temp.as_(${lit(key)});
    v_p := has_permission('data.view_prices'); v_fv := has_permission('module.finance.view'); v_prv := has_permission('module.processing.view');
    v_cv := has_permission('module.compliance.view'); v_cp := has_permission('action.compliance_pack');
    SELECT count(*) INTO v_pk FROM compliance_packs;
    SELECT count(*) INTO v_pr FROM compliance_packs WHERE code = 'CPK-2026-09-2';
    SELECT count(*) INTO v_26 FROM pending_values WHERE value_code = 'V26';
    SELECT count(*) INTO v_27 FROM pending_values WHERE value_code = 'V27';
    PERFORM pg_temp.me_();
    INSERT INTO p8_roles VALUES (${lit(key)}, ${lit(r)}, (SELECT count(*) FROM role_permissions rp JOIN roles ro ON ro.id = rp.role_id WHERE ro.code = ${lit(r)}),
        v_p, v_fv, v_prv, v_cv, v_cp,
        pg_temp.would_(${lit(key)}, format($q$SELECT inbound_batch_margin(%L)$q$, pg_temp.id_('ba'))),
        pg_temp.would_(${lit(key)}, $q$SELECT inventory_metal_exposure()$q$),
        v_pk, v_pr,
        pg_temp.would_(${lit(key)}, $q$SELECT compliance_pack_data(DATE '2026-09-01')$q$),
        v_26, v_27,
        pg_temp.would_(${lit(key)}, $q$SELECT freeze_compliance_pack(DATE '2026-09-01', NULL, 'ZZ-PROBE-MES8B1 role probe')$q$));
END $s$;
SELECT 'OUT|row|' || (SELECT to_jsonb(x) FROM p8_roles x WHERE who = ${lit(key)})::text;
`, `role ${r}`)
        const row = JSON.parse(v.row)
        const dlr = await download(who[key].token, path)
        const short = (s) => (s === 'OK' ? 'yes' : `no (${s.split('|')[0]}${s.includes('|') ? '|' + s.split('|')[1] : ''})`)
        console.log(`ROLE|${r}|codes ${row.codes}|view_prices ${row.prices ? 'yes' : 'no'}|finance.view ${row.finance_view ? 'yes' : 'no'}|processing.view ${row.processing_view ? 'yes' : 'no'}|inbound margin section ${short(row.margin)}|/finance/price-exposure (page: finance.view ${row.finance_view ? 'yes' : 'no'}) inventory section ${short(row.exposure)}|compliance.view ${row.compliance_view ? 'yes' : 'no'}|pack list rows ${row.packs_seen}|the pack ${row.pack_row}|live preview ${short(row.preview)}|PDF download ${dlr.status === 200 ? 'yes' : `no (HTTP ${dlr.status})`}|freeze / re-issue ${short(row.freeze_try)}|pending V26 ${row.pending_v26} · V27 ${row.pending_v27}`)
    }

    // ══ ⑦ 在册的东西一个字都没动;收尾 ══
    v = await run(String.raw`
DO $s$
DECLARE v_rec text;
BEGIN
    IF pg_temp.fp_(pg_temp.val_('t0')::timestamptz) IS DISTINCT FROM pg_temp.val_('fp') THEN
        RAISE EXCEPTION 'MES8B1_LIVE|pre-existing rows changed in: %', (SELECT string_agg(split_part(a.x, ':', 1), ', ')
            FROM unnest(string_to_array(pg_temp.fp_(pg_temp.val_('t0')::timestamptz), '#')) WITH ORDINALITY a(x, i)
            JOIN unnest(string_to_array(pg_temp.val_('fp'), '#')) WITH ORDINALITY b(y, j) ON i = j WHERE a.x IS DISTINCT FROM b.y);
    END IF;
    -- 我自己的两张定价申请都已决定 —— 收尾时在途单据必须与开场逐字相同(没有一张是我的)
    IF (SELECT COALESCE(string_agg(subject_type || ':' || code, ',' ORDER BY code), '') FROM approval_pending_documents()) <> pg_temp.val_('pending') THEN
        RAISE EXCEPTION 'MES8B1_LIVE|the pending documents are not exactly the ones at the start (none of mine may be left): %',
            (SELECT string_agg(subject_type || ':' || code, ',' ORDER BY code) FROM approval_pending_documents());
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN RAISE EXCEPTION 'MES8B1_LIVE|require_calibrated_since set'; END IF;
    IF NOT approvals_enabled() THEN RAISE EXCEPTION 'MES8B1_LIVE|approvals switched off'; END IF;
    v_rec := pg_temp.agree_('end');
    RAISE NOTICE 'STEP|untouched|pre-existing rows identical; pending (others) «%»; approvals on; require_calibrated_since NULL; reconciliation %', pg_temp.val_('pending'), v_rec;
    RAISE NOTICE 'STEP|done|%', clock_timestamp() - pg_temp.val_('t0')::timestamptz;
END $s$;
ROLLBACK;
SELECT 'OUT|afterDb|' || 'packs=' || (SELECT count(*) FROM compliance_packs) || ' · pack issues=' || (SELECT count(*) FROM compliance_pack_issues)
    || ' · settings set=' || (SELECT count(*) FROM compliance_settings WHERE nea_return_format IS NOT NULL OR nea_return_frequency IS NOT NULL OR eu_efficiency_method IS NOT NULL OR eu_efficiency_targets IS NOT NULL)
    || ' · locked_before=' || (SELECT locked_before::text FROM finance_settings)
    || ' · cod_issues=' || (SELECT count(*) FROM cod_issues)
    || ' · probe rows=' || ((SELECT count(*) FROM suppliers WHERE code LIKE 'ZZ-PROBE-MES8B1%') + (SELECT count(*) FROM materials WHERE code LIKE 'ZZ-PROBE-MES8B1%')
                            + (SELECT count(*) FROM customers WHERE code LIKE 'ZZ-PROBE-MES8B1%') + (SELECT count(*) FROM substances WHERE code LIKE 'zzp8b1%')
                            + (SELECT count(*) FROM metal_prices WHERE notes LIKE 'ZZ-PROBE-MES8B1%') + (SELECT count(*) FROM incidents WHERE what_happened LIKE 'ZZ-PROBE-MES8B1%')
                            + (SELECT count(*) FROM employees WHERE code LIKE 'ZZ-PROBE-MES8B1%'))
    || ' · require_calibrated_since=' || COALESCE((SELECT require_calibrated_since::text FROM ingest_settings), 'NULL')
    || ' · approvals=' || approvals_enabled()::text;
`, 'close')
    console.log(`AFTER|database (after ROLLBACK): ${v.afterDb}`)
    psql.stdin.end()

    // 桶:删掉上传过的对象,再读回 —— 合规包的桶 0 个对象;销毁证书的桶与开场逐字相同
    const { URL, SERVICE } = env()
    const rr = await fetch(`${URL}/storage/v1/object/${BUCKET}`, {
        method: 'DELETE', headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ prefixes: [path, orphan] }),
    })
    must(rr.ok, `removing the proof's objects: HTTP ${rr.status}`)
    const left = await listAsService(BUCKET)
    const cpkAfter = bucketFingerprint(BUCKET), codAfter = bucketFingerprint(COD_BUCKET)
    bucketVerdict = `${BUCKET}: ${left.length} top-level entries (Storage API) · SQL ${cpkAfter} (before ${cpkBefore}) · ${COD_BUCKET}: SQL ${codAfter} (before ${codBefore})`
    must(left.length === 0 && cpkAfter === cpkBefore && codAfter === codBefore, `a bucket is not as it was: ${bucketVerdict}`)
    console.log('✓ 证明走完(STEP|done),事务已回滚,合规包的桶里 0 个对象,销毁证书的桶逐字未变')
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
    return exitAfterCleanup(String(e?.message || '').startsWith('MES8B1_') ? 1 : 2)
})
