#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// MES-7a-1(2026-10-16)· 线上验证 —— 设备记录与可靠性、分析证书的签发人(F9)、销毁证书从快照渲染(F10)、存 PDF(Q24)
//   一笔【回滚】的事务 + 两个私有桶里【事后删干净】的对象
// ════════════════════════════════════════════════════════════════════════════
// 形状照 db/scripts/2026-10-15-mes6b2-live-proof.mjs:一个【常开的 psql 子进程】(一笔事务从头开到尾)。不同在于两条 PDF 路由
//   【原样】跑 —— app/output/[id]/coa/pdf/route.tsx 与 app/inbound/[id]/cod/pdf/route.tsx 经 jiti 装进来,'@/lib/supabase/server'
//   换成一个【绑在这笔事务上】的客户端:.from(…).select(…) 与 .rpc(…) 变成以一次性账号的身份在这笔事务里跑的 SQL(pg_temp.tget_,
//   每一句一个子事务,拒绝不会打断整笔),.storage 是真的 Storage API(以那个账号的 token)。于是路由的每一步都对着线上的函数与桶走,
//   而数据库那一侧的一切随 ROLLBACK 消失;桶里的对象在上传【之前】就登记了删除步(scripts/ephemeral.mjs),最后删掉、读回。
//
// 【身份】每一个动作都以一次性账号跑(前缀 mes7a1probe),七个真账号一个都不用:
//   eq   = 记设备(module.processing.view · module.processing.edit)       view = 只读加工(module.processing.view)
//   rec  = 产出批与化验(module.output.view · module.output.edit · module.inbound.view)
//   bad  = 签发人,名字里有一个纸上的字体画不出来的字(action.issue_coa · module.output.view · module.quality.view)
//   iss  = 签发人,名字干净(同上)                                      cod  = 签发销毁证书(action.issue_cod · module.inbound.view)
//   c_<角色> = 七个真账号持有的八个角色【此刻的码】的克隆(cloneOf,只读)
// 【布景】都是我自己的行(前缀 ZZ-PROBE-MES7A1),在事务里插,随回滚消失。在册的东西一行都不改、不决定、不删。
// 【判决】只从日志里最后那一行 `MES7A1_PROOF_EXIT=` 读。0 = 走完且两个桶读回只剩开跑前那几个对象(字节逐个相同)·
//   1 = 证明红了 · 2 = 驱动自己坏了 · 5 = live-lock 被占 · 6 = 收尾没完成。
// 用法:node db/scripts/2026-10-16-mes7a1-live-proof.mjs > <log> 2>&1
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
const BUCKETS = ['coa-documents', 'cod-documents']
const ROLE_CLONES = ['admin', 'cfo', 'finance', 'warehouse', 'cto', 'operations', 'cco', 'gm']   // 七个真账号持有的八个角色(admin+cfo 一个账号、cto+operations 一个账号)

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
        console.log(`MES7A1_PROOF_EXIT=${code}`)
    },
})

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

// ── 常开的 psql ─────────────────────────────────────────────────────────────
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
    const mark = `@@MES7A1_DONE_${++seq}@@`
    const from = out.length
    psql.stdin.write(`${sqlText}\n\\echo ${mark}\n`)
    const t0 = Date.now()
    while (!out.includes(mark, from)) {
        if (psql.exitCode !== null) {
            throw new Error(`MES7A1_SQL|${label}|psql exited ${psql.exitCode}:\n${err.split('\n').slice(-20).join('\n')}`)
        }
        if (Date.now() - t0 > 360_000) throw new Error(`MES7A1_SQL|${label}|no answer within 360s`)
        await new Promise((r) => setTimeout(r, 30))
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
const sha = (b) => createHash('sha256').update(b).digest('hex')
function must(cond, msg) { if (!cond) throw new Error(`MES7A1_LIVE|${msg}`) }

// ── Storage API ─────────────────────────────────────────────────────────────
async function listAsService(bucket, prefix = '') {
    const { URL, SERVICE } = env()
    const r = await fetch(`${URL}/storage/v1/object/list/${bucket}`, {
        method: 'POST', headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ prefix, limit: 1000 }),
    })
    const j = await r.json().catch(() => null)
    if (!r.ok || !Array.isArray(j)) throw new Error(`MES7A1_BUCKET|list ${bucket} HTTP ${r.status}`)
    const outp = []
    for (const e of j) {
        const p = prefix ? `${prefix}/${e.name}` : e.name
        if (e.id === null) outp.push(...await listAsService(bucket, p)); else outp.push(p)
    }
    return outp
}
async function bytesAsService(bucket, path) {
    const { URL, SERVICE } = env()
    const r = await fetch(`${URL}/storage/v1/object/${bucket}/${path}?t=${randomUUID()}`, { headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}` } })
    return { status: r.status, buf: Buffer.from(await r.arrayBuffer()) }
}
async function bucketFingerprint() {
    const o = {}
    for (const b of BUCKETS) {
        const paths = (await listAsService(b)).sort()
        o[b] = {}
        for (const p of paths) { const x = await bytesAsService(b, p); o[b][p] = x.status === 200 ? sha(x.buf) : `HTTP ${x.status}` }
    }
    return o
}
function planObjectDelete(bucket, path) {
    planDelete(`/storage/v1/object/${bucket}`, `删证明上传的 ${bucket}/${path}`, ORDER.OTHER,
        { method: 'DELETE', body: JSON.stringify({ prefixes: [path] }) })
}
// MES7A1_KEEP_PDF=<dir>:把证明读过的每一份 PDF 也写一份到那个目录(给人眼看版式;那是本机文件,不是桶里的对象)
let keptPdf = 0
function pdfText(buf) {
    const f = join(scratch, `${randomUUID()}.pdf`)
    writeFileSync(f, buf)
    if (process.env.MES7A1_KEEP_PDF) writeFileSync(join(process.env.MES7A1_KEEP_PDF, `proof-${++keptPdf}.pdf`), buf)
    const r = spawnSync('python3', ['-c', 'import pypdf,sys\nr=pypdf.PdfReader(sys.argv[1])\nprint("\\n".join(p.extract_text() for p in r.pages))', f],
        { encoding: 'utf8' })
    if (r.status !== 0) throw new Error(`MES7A1_PDF|pypdf could not read the bytes: ${r.stderr.slice(0, 300)}`)
    return r.stdout
}

// ── 绑在这笔事务上的 Supabase 客户端(给两条路由用)────────────────────────────────
const IDENT = /^[a-z_][a-z0-9_]*$/
let actor = null          // 当前以谁的身份跑路由(who 里的一个键)
let who = {}
let uploads = []          // { bucket, path } —— 路由传上去的每一个对象
function sqlVal(v) {
    if (v === null || v === undefined) return 'NULL'
    if (typeof v === 'boolean' || typeof v === 'number') return String(v)
    if (typeof v === 'object') return `${lit(JSON.stringify(v))}::jsonb`
    return lit(v)
}
async function tget(sql) {
    const v = await run(`SELECT 'OUT|r|' || pg_temp.tget_(${lit(actor)}, ${lit(sql)})::text;`, 'route sql')
    return JSON.parse(v.r)
}
class TxnQuery {
    constructor(table) { this.table = table; this.cols = '*'; this.w = []; this.ord = []; this.lim = null; this.single = false }
    select(cols = '*') { this.cols = cols; return this }
    eq(c, v) { this.w.push(`${this.col(c)} = ${sqlVal(v)}`); return this }
    neq(c, v) { this.w.push(`${this.col(c)} IS DISTINCT FROM ${sqlVal(v)}`); return this }
    is(c, v) { this.w.push(`${this.col(c)} IS ${v === null ? 'NULL' : sqlVal(v)}`); return this }
    order(c, o = {}) { this.ord.push(`${this.col(c)} ${o.ascending === false ? 'DESC' : 'ASC'}${o.nullsFirst ? ' NULLS FIRST' : ''}`); return this }
    limit(n) { this.lim = Number(n); return this }
    maybeSingle() { this.single = true; return this }
    col(c) { if (!IDENT.test(c)) throw new Error(`MES7A1_SHIM|column ${c}`); return c }
    sql() {
        if (!IDENT.test(this.table)) throw new Error(`MES7A1_SHIM|table ${this.table}`)
        const cols = this.cols.trim() === '*' ? '*' : this.cols.split(',').map((x) => this.col(x.trim())).join(', ')
        return `SELECT COALESCE(jsonb_agg(to_jsonb(t)), '[]'::jsonb) FROM (SELECT ${cols} FROM public.${this.table}`
            + (this.w.length ? ` WHERE ${this.w.join(' AND ')}` : '') + (this.ord.length ? ` ORDER BY ${this.ord.join(', ')}` : '')
            + (this.lim !== null ? ` LIMIT ${this.lim}` : '') + ') t'
    }
    then(res, rej) {
        return tget(this.sql()).then((r) => {
            if (r.error) return { data: null, error: { message: r.error } }
            const rows = r.data ?? []
            return this.single ? { data: rows[0] ?? null, error: null } : { data: rows, error: null }
        }).then(res, rej)
    }
}
globalThis.__TXN_CLIENT__ = () => ({
    from: (t) => new TxnQuery(t),
    rpc: async (name, args = {}) => {
        if (!IDENT.test(name)) throw new Error(`MES7A1_SHIM|rpc ${name}`)
        const a = Object.entries(args).filter(([, v]) => v !== undefined).map(([k, v]) => {
            if (!IDENT.test(k)) throw new Error(`MES7A1_SHIM|arg ${k}`)
            return `${k} => ${sqlVal(v)}`
        }).join(', ')
        // 经 text 走:jsonb 的函数回 JSON 文本,void 的回 ''(to_jsonb 不收 void)
        const r = await tget(`SELECT to_jsonb((public.${name}(${a}))::text)`)
        if (r.error) return { data: null, error: { message: r.error } }
        if (r.data === null || r.data === '') return { data: null, error: null }
        try { return { data: JSON.parse(r.data), error: null } } catch { return { data: r.data, error: null } }
    },
    storage: {
        from: (bucket) => ({
            upload: async (path, buf, opts = {}) => {
                const { URL, ANON } = env()
                planObjectDelete(bucket, path)
                uploads.push({ bucket, path })
                const r = await fetch(`${URL}/storage/v1/object/${bucket}/${path}`, {
                    method: 'POST', body: buf,
                    headers: { apikey: ANON, Authorization: `Bearer ${who[actor].token}`, 'Content-Type': opts.contentType ?? 'application/pdf', 'x-upsert': 'false' },
                })
                const text = (await r.text()).slice(0, 300)
                return r.ok ? { data: { path }, error: null } : { data: null, error: { message: `HTTP ${r.status} ${text}` } }
            },
            download: async (path) => {
                const { URL, ANON } = env()
                const r = await fetch(`${URL}/storage/v1/object/authenticated/${bucket}/${path}?nocache=${randomUUID()}`,
                    { headers: { apikey: ANON, Authorization: `Bearer ${who[actor].token}` } })
                if (!r.ok) return { data: null, error: { message: `HTTP ${r.status}` } }
                return { data: new Blob([Buffer.from(await r.arrayBuffer())]), error: null }
            },
            remove: async (paths) => {
                const { URL, SERVICE } = env()
                const r = await fetch(`${URL}/storage/v1/object/${bucket}`, {
                    method: 'DELETE', headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, 'Content-Type': 'application/json' },
                    body: JSON.stringify({ prefixes: paths }),
                })
                return r.ok ? { data: [], error: null } : { data: null, error: { message: `HTTP ${r.status}` } }
            },
        }),
    },
})

let coaRoute = null, codRoute = null
async function loadRoutes() {
    const { createJiti } = await import('jiti')
    const React = (await import('react')).default
    globalThis.React = React
    const jiti = createJiti(import.meta.url, {
        jsx: true, interopDefault: true,
        alias: {
            '@/lib/supabase/server': join(ROOT, 'db/scripts/lib/txn-supabase-server.mjs'),
            '@/lib/i18n/server': join(ROOT, 'scripts/pdf-routes/i18n-server.mjs'),
            'server-only': join(ROOT, 'scripts/pdf-routes/empty.mjs'),
            '@': ROOT,
        },
    })
    coaRoute = await jiti.import(join(ROOT, 'app/output/[id]/coa/pdf/route.tsx'))
    codRoute = await jiti.import(join(ROOT, 'app/inbound/[id]/cod/pdf/route.tsx'))
}
const BASE = 'https://new-era-erp.vercel.app'
const ctx = (id) => ({ params: Promise.resolve({ id }) })
async function asRoute(key, fn) { actor = key; try { return await fn() } finally { actor = null } }

async function main() {
    const other = heldBy()
    if (other) { console.error(`✗ live-lock 被【${other.holder}】(pid ${other.pid})占着`); return exitAfterCleanup(5) }
    acquireOrExit('db/scripts/2026-10-16-mes7a1-live-proof.mjs', { ownExit: false })
    locked = true
    openPlan('db/scripts/2026-10-16-mes7a1-live-proof.mjs')
    await reapStalePlans()
    scratch = mkdtempSync(join(tmpdir(), 'mes7a1-proof-'))
    await loadRoutes()

    const bucketsBefore = await bucketFingerprint()
    console.log(`STEP|buckets before|${JSON.stringify(bucketsBefore)}`)

    const stamp = Date.now()
    const mint = async (key, label, codes) => {
        const a = await mintThrowaway({ prefix: 'mes7a1probe', label, stamp, codes })
        who[key] = a
        console.log(`· ${key}: ${a.email} ← ${a.roleCode} (${a.codes.length} codes${Array.isArray(codes) ? ': ' + a.codes.join(', ') : ''})`)
    }
    await mint('eq', 'eq', ['module.processing.view', 'module.processing.edit'])
    await mint('view', 'view', ['module.processing.view'])
    await mint('rec', 'rec', ['module.output.view', 'module.output.edit', 'module.inbound.view'])
    await mint('bad', 'bad', ['action.issue_coa', 'module.output.view', 'module.quality.view'])
    await mint('iss', 'iss', ['action.issue_coa', 'module.output.view', 'module.quality.view'])
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
CREATE TEMP TABLE p7 (k text PRIMARY KEY, v text) ON COMMIT DROP;
INSERT INTO p7 VALUES ${emails};
CREATE FUNCTION pg_temp.put_(p_k text, p_v text) RETURNS void LANGUAGE sql AS $f$
    INSERT INTO p7 VALUES (p_k, p_v) ON CONFLICT (k) DO UPDATE SET v = EXCLUDED.v $f$;
CREATE FUNCTION pg_temp.val_(p_k text) RETURNS text LANGUAGE sql AS $f$ SELECT v FROM p7 WHERE k = p_k $f$;
CREATE FUNCTION pg_temp.id_(p_k text) RETURNS uuid LANGUAGE sql AS $f$ SELECT v::uuid FROM p7 WHERE k = p_k $f$;
CREATE FUNCTION pg_temp.as_(p_who text) RETURNS void LANGUAGE plpgsql AS $f$
DECLARE v_uid uuid; e text := (SELECT x.v FROM p7 x WHERE x.k = 'email.' || p_who);
BEGIN
    EXECUTE 'RESET ROLE';
    SELECT id INTO v_uid FROM auth.users WHERE email = e;
    IF v_uid IS NULL OR e NOT LIKE 'mes7a1probe-%@test.local' THEN RAISE EXCEPTION 'MES7A1_LIVE|not a throwaway account: % (%)', p_who, e; END IF;
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
-- 以 p_who 的身份试一句,然后【一定】撤掉它做的事(子事务回滚):成 → 'OK',拒 → 那一句原话。逐角色读数表用
CREATE FUNCTION pg_temp.would_(p_who text, p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE r text;
BEGIN
    BEGIN
        PERFORM pg_temp.as_(p_who);
        EXECUTE p_sql;
        RAISE EXCEPTION 'MES7A1_WOULD_OK';
    EXCEPTION WHEN OTHERS THEN
        r := SQLERRM;
    END;
    PERFORM pg_temp.me_();
    RETURN CASE WHEN r = 'MES7A1_WOULD_OK' THEN 'OK' ELSE r END;
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
-- 路由那一侧的每一句:一个子事务;拒绝回成 {"error": …},不打断整笔
CREATE FUNCTION pg_temp.tget_(p_who text, p_sql text) RETURNS jsonb LANGUAGE plpgsql AS $f$
DECLARE v jsonb;
BEGIN
    PERFORM pg_temp.as_(p_who);
    EXECUTE p_sql INTO v;
    PERFORM pg_temp.me_();
    RETURN jsonb_build_object('data', v);
EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.me_();
    RETURN jsonb_build_object('error', SQLERRM);
END $f$;
CREATE FUNCTION pg_temp.uid_(p_who text) RETURNS uuid LANGUAGE sql AS $f$
    SELECT u.id FROM auth.users u WHERE u.email = (SELECT v FROM p7 WHERE k = 'email.' || p_who) $f$;
CREATE FUNCTION pg_temp.agree_(p_step text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE v jsonb; s jsonb; o text := '';
BEGIN
    v := pg_temp.get_('c_cfo', 'SELECT list_ledger_reconciliation()');
    IF jsonb_array_length(v -> 'sides') <> 2 THEN RAISE EXCEPTION 'MES7A1_LIVE|reconciliation after %: expected two sides, got %', p_step, v; END IF;
    FOR s IN SELECT * FROM jsonb_array_elements(v -> 'sides') LOOP
        IF s ->> 'refusal' IS NOT NULL OR (s ->> 'unexplained_base')::numeric IS DISTINCT FROM 0 THEN
            RAISE EXCEPTION 'MES7A1_LIVE|AP/AR list <> ledger after %: %', p_step, s;
        END IF;
        o := o || (s ->> 'side') || ' ' || (s ->> 'list_base') || ' / ' || (s ->> 'ledger_base') || ' / ' || (s ->> 'unexplained_base') || '; ';
    END LOOP;
    RETURN o;
END $f$;
-- 在册的东西的指纹(我的行 created_at = 事务开始时刻 now(),按 < t0 排除;停机表减掉本刀的两列新列之外逐字)
CREATE FUNCTION pg_temp.fp_(t0 timestamptz) RETURNS jsonb LANGUAGE sql AS $f$
-- 每一张表一个名字一个 md5,于是一次不一致说得出是哪一张。证书与字节档案只数【开跑前就在】的那几张(我的那一张在事务里新增)。
SELECT jsonb_build_object(
    'equipment_downtime', (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM equipment_downtime x WHERE x.created_at < t0),
    'equipment_maintenance', (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM equipment_maintenance x WHERE x.created_at < t0),
    'equipment_service_intervals', (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM equipment_service_intervals x WHERE x.created_at < t0),
    'fixed_assets', (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM fixed_assets x WHERE x.created_at < t0),
    'downtime_causes', (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.code)) FROM downtime_causes x),
    'operation_type_equipment', (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY to_jsonb(x)::text)) FROM operation_type_equipment x),
    'certificates_of_destruction', (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM certificates_of_destruction x WHERE x.created_at < t0),
    'cod_issues', (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM cod_issues x
                    WHERE x.cod_id IN (SELECT id FROM certificates_of_destruction WHERE created_at < t0)),
    'certificates_of_analysis', (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM certificates_of_analysis x WHERE x.created_at < t0),
    'coa_issues', (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM coa_issues x
                    WHERE x.coa_id IN (SELECT id FROM certificates_of_analysis WHERE created_at < t0)),
    'inbound_batches', (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM inbound_batches x WHERE x.created_at < t0),
    'output_batches', (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM output_batches x WHERE x.created_at < t0),
    'assay_results', (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM assay_results x WHERE x.created_at < t0),
    'processing_runs', (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM processing_runs x WHERE x.created_at < t0),
    'inventory_movements', (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM inventory_movements x WHERE x.created_at < t0),
    'warehouse_requests', (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM warehouse_requests x WHERE x.created_at < t0),
    'approval_log', (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM approval_log x WHERE x.created_at < t0),
    'suppliers', (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM suppliers x WHERE x.created_at < t0),
    'materials', (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM materials x WHERE x.created_at < t0),
    'employees', (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM employees x WHERE x.created_at < t0),
    'positions', (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM positions x WHERE x.created_at < t0),
    'journal_entries', (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM journal_entries x WHERE x.created_at < t0),
    'journal_lines', (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM journal_lines x WHERE x.created_at < t0),
    'expenses', (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM expenses x WHERE x.created_at < t0),
    'permissions', (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.code)) FROM permissions x),
    'role_permissions', (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.role_id, x.permission_code)) FROM role_permissions x
      WHERE x.role_id IN (SELECT id FROM roles WHERE code NOT LIKE 'probe-%')),
    'company_profile', (SELECT md5(to_jsonb(x)::text) FROM company_profile x),
    'finance_settings', (SELECT md5(to_jsonb(x)::text) FROM finance_settings x),
    'ingest_settings', (SELECT md5(to_jsonb(x)::text) FROM ingest_settings x))
$f$;
GRANT EXECUTE ON FUNCTION pg_temp.as_(text), pg_temp.me_() TO authenticated;
GRANT SELECT ON p7 TO authenticated;
`, 'open')

    // ══ ⓪ 前提与布景 ══
    let v = await run(String.raw`
DO $s$
DECLARE
    v_t0 timestamptz := now(); d date := CURRENT_DATE; v_base text;
    m uuid; m2 uuid; p_qm uuid; p_bad uuid; sup uuid; mat uuid; ib uuid; ob uuid; r_c uuid;
BEGIN
    IF NOT approvals_enabled() THEN RAISE EXCEPTION 'MES7A1_LIVE|approvals are off on live'; END IF;
    IF to_regclass('public.downtime_causes') IS NULL THEN RAISE EXCEPTION 'MES7A1_LIVE|the MES-7a-1 migration is not on live'; END IF;
    IF btrim(COALESCE((SELECT legal_name FROM company_profile LIMIT 1), '')) = '' THEN RAISE EXCEPTION 'MES7A1_LIVE|no company legal name'; END IF;
    IF NOT (cod_governing_licence(d - 2) ->> 'ok')::boolean THEN RAISE EXCEPTION 'MES7A1_LIVE|no licence in force two days ago — a COD would be refused'; END IF;
    SELECT code INTO v_base FROM currencies WHERE is_base;
    PERFORM pg_temp.put_('t0', v_t0::text);
    PERFORM pg_temp.put_('fp', pg_temp.fp_(v_t0)::text);
    PERFORM pg_temp.put_('pending', (SELECT COALESCE(string_agg(subject_type || ':' || code, ',' ORDER BY code), '') FROM approval_pending_documents()));
    PERFORM pg_temp.put_('rec_start', pg_temp.agree_('start'));
    PERFORM pg_temp.put_('nextCoa', next_coa_code());
    PERFORM pg_temp.put_('nCoa', (SELECT count(*) FROM certificates_of_analysis)::text);

    -- 两台我自己的机器(属主直插:资产登记是财务的门,而这里只要一张设备卡)
    INSERT INTO fixed_assets (code, description, category, acquisition_date, cost_ccy, currency, fx_rate, cost_base, useful_life_months, residual_base)
    VALUES ('ZZ-PROBE-MES7A1-M', 'ZZ-PROBE-MES7A1 shredder', 'equipment', d - 30, 0, v_base, 1, 0, 60, 0) RETURNING id INTO m;
    INSERT INTO fixed_assets (code, description, category, acquisition_date, cost_ccy, currency, fx_rate, cost_base, useful_life_months, residual_base)
    VALUES ('ZZ-PROBE-MES7A1-M2', 'ZZ-PROBE-MES7A1 press', 'equipment', d - 30, 0, v_base, 1, 0, 60, 0) RETURNING id INTO m2;
    PERFORM pg_temp.put_('m', m::text); PERFORM pg_temp.put_('m2', m2::text);

    -- 两个签发人:员工档案 + 职位(我的行);一个的名字里有纸上的字体画不出来的「≤」
    INSERT INTO positions (code, title) VALUES ('ZZ-PROBE-MES7A1-QM', 'Quality Manager (probe)') RETURNING id INTO p_qm;
    INSERT INTO employees (code, legal_name, preferred_name, employment_type, work_category, hire_date, user_id, position_id)
    VALUES ('ZZ-PROBE-MES7A1-BAD', 'ZZ Probe Lim', 'Lim ≤ (probe)', 'full_time', 'office', d - 400, pg_temp.uid_('bad'), p_qm),
           ('ZZ-PROBE-MES7A1-ISS', 'ZZ Probe Tan', 'Tan (probe)', 'full_time', 'office', d - 400, pg_temp.uid_('iss'), p_qm);

    -- 一票货:整批被一张活着的加工单吃掉(fixture 195 的形状,属主直插)→ 自动成立一张待签发的销毁证书
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type, default_tax_code)
    VALUES ('ZZ-PROBE-MES7A1-S', 'ZZ-PROBE-MES7A1 Battery Recycle Co', 'SG', 'active', 'goods_supplier', 'OP') RETURNING id INTO sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, unit)
    VALUES ('ZZ-PROBE-MES7A1-BM', 'ZZ-PROBE-MES7A1 black mass', 'battery_material', true, 'black_mass', 'end_of_life', 'kg') RETURNING id INTO mat;
    INSERT INTO inbound_batches (material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note, chemistry_certainty_code)
    VALUES (mat, sup, 100, 100, 'kg', d - 9, 'other', 'ZZ-PROBE-MES7A1 destroyed', 'single_known') RETURNING id INTO ib;
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code) VALUES (ib, 'discharged_verified');
    INSERT INTO processing_runs (code, process_date, total_input, total_output, loss_qty, status, allocation_basis, operation_type_code, started_at, ended_at, shift_code)
    VALUES ('ZZ-PROBE-MES7A1-CODRUN', d - 2, 100, 80, 20, 'committed', 'weight', 'manual_disassembly', (d - 2)::timestamptz, (d - 2)::timestamptz + interval '1 hour', 'day')
    RETURNING id INTO r_c;
    INSERT INTO processing_inputs (run_id, inbound_batch_id, quantity_consumed) VALUES (r_c, ib, 100);
    INSERT INTO inventory_movements (inbound_batch_id, movement_type, qty_delta, run_id, business_date) VALUES (ib, 'processing_consume', -100, r_c, d - 2);
    UPDATE inbound_batches SET remaining_qty = 0 WHERE id = ib;
    PERFORM refresh_cod_for_batch(ib);
    PERFORM pg_temp.put_('ib', ib::text); PERFORM pg_temp.put_('sup', sup::text);

    -- 一张产出批(血缘:那张加工单产出它)+ 一份最终化验(签发分析证书用)
    ob := (pg_temp.get_('rec', format($q$SELECT create_output_batch(%L, 80, 'kg', %L, p_notes => 'ZZ-PROBE-MES7A1 certificate')$q$, mat, d - 2)) ->> 'batch_id')::uuid;
    INSERT INTO processing_outputs (run_id, output_batch_id, quantity_produced) VALUES (r_c, ob, 80);
    PERFORM pg_temp.get_('rec', format($q$SELECT record_assay_result(p_assay_date => %L, p_output_batch_id => %L, p_weight_basis => 'dry', p_moisture_pct => 6.4,
              p_result_party => 'ours', p_is_final => true, p_certificate_ref => 'ZZ-PROBE-MES7A1-A', p_metals => '[{"metal": "ni", "content_pct": 20}]'::jsonb)$q$, d - 2, ob));
    PERFORM pg_temp.put_('ob', ob::text);
    RAISE NOTICE 'STEP|setup|own rows (prefix ZZ-PROBE-MES7A1): machines % / %, two issuers + a position, supplier, material, inbound % (fully processed by %, COD %), output %; reconciliation at start %',
        (SELECT code FROM fixed_assets WHERE id = m), (SELECT code FROM fixed_assets WHERE id = m2), (SELECT code FROM inbound_batches WHERE id = ib),
        (SELECT code FROM processing_runs WHERE id = r_c), (SELECT status FROM certificates_of_destruction WHERE inbound_batch_id = ib AND status <> 'void'),
        (SELECT code FROM output_batches WHERE id = ob), pg_temp.val_('rec_start');
END $s$;
`, 'setup')

    // ══ ① 设备记录:开一段故障停机(带原因)→ 关上 → 带理由更正 → 一次修理点名它;别的机器的、作废的被拒;直连写被拒 ══
    const T = (h) => `(CURRENT_DATE - 3)::timestamptz + interval '${h} hours'`
    v = await run(String.raw`
SELECT 'OUT|open|' || pg_temp.get_('eq', format($q$SELECT open_equipment_downtime(%L, ${T(8)}, 'breakdown', 'ZZ-PROBE-MES7A1 bearing seized')$q$, pg_temp.id_('m')))::text;
`, 'open')
    const dt = JSON.parse(v.open).downtime_id
    v = await run(String.raw`
SELECT 'OUT|close|' || pg_temp.try_('eq', format($q$SELECT close_equipment_downtime(%L, ${T(10)})$q$, ${lit(dt)}));
SELECT 'OUT|correct|' || pg_temp.try_('eq', format($q$SELECT correct_equipment_downtime(%L, ${T(8)}, ${T(10)}, 'breakdown', 'ZZ-PROBE-MES7A1 bearing seized — replaced, outer race cracked')$q$, ${lit(dt)}));
SELECT 'OUT|row|' || (SELECT to_jsonb(x) FROM (SELECT cause_code, source, reason, to_char(ended_at - started_at, 'HH24:MI') AS dur FROM equipment_downtime WHERE id = ${lit(dt)}::uuid) x)::text;
SELECT 'OUT|maint|' || pg_temp.get_('eq', format($q$SELECT record_equipment_maintenance(p_equipment_id => %L, p_performed_on => CURRENT_DATE - 3, p_kind => 'repair',
        p_description => 'ZZ-PROBE-MES7A1 replaced the bearing', p_performed_by_name => 'Probe fitter', p_downtime_id => %L)$q$, pg_temp.id_('m'), ${lit(dt)}))::text;
-- 别的机器上开一段;同一台机器上开一段再作废
SELECT 'OUT|m2open|' || pg_temp.get_('eq', format($q$SELECT open_equipment_downtime(%L, ${T(9)}, 'external', 'ZZ-PROBE-MES7A1 no power on the press')$q$, pg_temp.id_('m2')))::text;
`, 'record')
    must(v.close === 'OK' && v.correct === 'OK', `close / correct: ${v.close} / ${v.correct}`)
    const row = JSON.parse(v.row), maint = JSON.parse(v.maint), dtOther = JSON.parse(v.m2open).downtime_id
    must(row.cause_code === 'breakdown' && row.source === 'manual' && row.dur === '02:00' && row.reason.includes('outer race cracked'), `the downtime row: ${v.row}`)
    v = await run(String.raw`
SELECT 'OUT|v1|' || pg_temp.get_('eq', format($q$SELECT open_equipment_downtime(%L, ${T(16)}, 'breakdown', 'ZZ-PROBE-MES7A1 entered by mistake')$q$, pg_temp.id_('m')))::text;
`, 'v1')
    const dtVoid = JSON.parse(v.v1).downtime_id
    v = await run(String.raw`
SELECT 'OUT|void|' || pg_temp.try_('eq', format($q$SELECT void_equipment_downtime(%L, 'ZZ-PROBE-MES7A1 never happened')$q$, ${lit(dtVoid)}));
SELECT 'OUT|other|' || pg_temp.try_('eq', format($q$SELECT record_equipment_maintenance(p_equipment_id => %L, p_performed_on => CURRENT_DATE - 3, p_kind => 'repair',
        p_description => 'x', p_performed_by_name => 'x', p_downtime_id => %L)$q$, pg_temp.id_('m'), ${lit(dtOther)}));
SELECT 'OUT|voided|' || pg_temp.try_('eq', format($q$SELECT record_equipment_maintenance(p_equipment_id => %L, p_performed_on => CURRENT_DATE - 3, p_kind => 'repair',
        p_description => 'x', p_performed_by_name => 'x', p_downtime_id => %L)$q$, pg_temp.id_('m'), ${lit(dtVoid)}));
SELECT 'OUT|direct|' || pg_temp.try_('eq', format($q$INSERT INTO equipment_downtime (equipment_id, started_at, reason, cause_code) VALUES (%L, ${T(20)}, 'direct', 'breakdown')$q$, pg_temp.id_('m')));
SELECT 'OUT|m2close|' || pg_temp.try_('eq', format($q$SELECT close_equipment_downtime(%L, ${T(11)})$q$, ${lit(dtOther)}));
SELECT 'OUT|directUpd|' || pg_temp.try_('eq', format($q$UPDATE equipment_downtime SET reason = 'direct' WHERE id = %L$q$, ${lit(dt)}));
SELECT 'OUT|nocause|' || pg_temp.try_('eq', format($q$SELECT open_equipment_downtime(%L, ${T(21)}, NULL, 'no cause')$q$, pg_temp.id_('m2')));
SELECT 'OUT|viewer|' || pg_temp.try_('view', format($q$SELECT open_equipment_downtime(%L, ${T(22)}, 'breakdown', 'viewer')$q$, pg_temp.id_('m')));
`, 'refusals')
    must(v.void === 'OK' && v.m2close === 'OK', `void / close on the press: ${v.void} / ${v.m2close}`)
    must(v.other.startsWith('MAINTENANCE_DOWNTIME_OTHER_MACHINE|'), `maintenance citing another machine's downtime: ${v.other}`)
    must(v.voided.startsWith('MAINTENANCE_DOWNTIME_VOIDED|'), `maintenance citing a voided downtime: ${v.voided}`)
    must(v.direct.startsWith('EQUIPMENT_THROUGH_FUNCTION_ONLY|equipment_downtime|insert'), `a direct insert: ${v.direct}`)
    must(v.directUpd.startsWith('EQUIPMENT_THROUGH_FUNCTION_ONLY|equipment_downtime|update'), `a direct update: ${v.directUpd}`)
    must(v.nocause === 'DOWNTIME_CAUSE_REQUIRED', `a downtime with no cause: ${v.nocause}`)
    must(v.viewer.startsWith('PERMISSION_DENIED|module.processing.edit'), `a viewer opening downtime: ${v.viewer}`)
    console.log(`STEP|record|failure downtime opened with cause «breakdown» (source manual) → closed (2 h) → corrected (reason now «…outer race cracked») → repair recorded citing it (${maint.maintenance_id.slice(0, 8)}…) · refused: another machine's downtime «${v.other.slice(0, 60)}» · a voided one «${v.voided.slice(0, 50)}» · a direct insert «${v.direct}» · a direct update «${v.directUpd}» · no cause «${v.nocause}» · a viewer «${v.viewer.slice(0, 45)}»`)

    // ══ ② 可靠性:两张重叠的单 + 一张单独的(都在这台机器上、都有时刻)+ 一张没记机器的 ══
    v = await run(String.raw`
DO $s$
DECLARE d date := CURRENT_DATE - 3;
BEGIN
    INSERT INTO processing_runs (code, process_date, total_input, total_output, loss_qty, status, allocation_basis, operation_type_code, equipment_id, started_at, ended_at, shift_code)
    VALUES ('ZZ-PROBE-MES7A1-R1', d, 10, 10, 0, 'committed', 'weight', 'manual_disassembly', pg_temp.id_('m'), d::timestamptz + interval '1 hour', d::timestamptz + interval '5 hours', 'day'),
           ('ZZ-PROBE-MES7A1-R2', d, 10, 10, 0, 'committed', 'weight', 'manual_disassembly', pg_temp.id_('m'), d::timestamptz + interval '3 hours', d::timestamptz + interval '7 hours', 'day'),
           ('ZZ-PROBE-MES7A1-R3', d, 10, 10, 0, 'committed', 'weight', 'manual_disassembly', pg_temp.id_('m'), d::timestamptz + interval '12 hours', d::timestamptz + interval '14 hours', 'day'),
           ('ZZ-PROBE-MES7A1-R4', d, 10, 10, 0, 'committed', 'weight', 'manual_disassembly', NULL, d::timestamptz + interval '2 hours', d::timestamptz + interval '3 hours', 'day');
END $s$;
SELECT 'OUT|rel|' || pg_temp.get_('view', format($q$SELECT to_jsonb(r) FROM equipment_reliability(%L, (CURRENT_DATE - 3)::timestamptz, (CURRENT_DATE - 2)::timestamptz) r$q$, pg_temp.id_('m')))::text;
SELECT 'OUT|relAll|' || pg_temp.get_('view', $q$SELECT to_jsonb(count(*)) FROM equipment_reliability() r WHERE r.equipment_code LIKE 'ZZ-PROBE-MES7A1-%'$q$)::text;
SELECT 'OUT|relNo|' || pg_temp.try_('rec', $q$SELECT count(*) FROM equipment_reliability()$q$);
-- 独立数一遍:区间 [d-3 00:00, d-2 00:00)(会话时区)按新加坡日期落在哪几天,那几天里已提交、没记机器的单 —— 其中我的是 R4 与销毁证书那一张
SELECT 'OUT|nomach|' || (SELECT count(*) FROM processing_runs WHERE equipment_id IS NULL AND status = 'committed' AND deleted_at IS NULL
    AND process_date BETWEEN (((CURRENT_DATE - 3)::timestamptz) AT TIME ZONE 'Asia/Singapore')::date AND (((CURRENT_DATE - 2)::timestamptz) AT TIME ZONE 'Asia/Singapore')::date);
SELECT 'OUT|nomachMine|' || (SELECT count(*) FROM processing_runs WHERE equipment_id IS NULL AND code LIKE 'ZZ-PROBE-MES7A1-%'
    AND process_date BETWEEN (((CURRENT_DATE - 3)::timestamptz) AT TIME ZONE 'Asia/Singapore')::date AND (((CURRENT_DATE - 2)::timestamptz) AT TIME ZONE 'Asia/Singapore')::date);
`, 'reliability')
    const rel = JSON.parse(v.rel)
    must(Number(rel.operating_hours) === 8 && rel.runs_counted === 3, `operating hours must count the overlap once (union of [1,5) [3,7) [12,14) = 8 h): ${v.rel}`)
    must(rel.failures === 1 && Number(rel.mtbf_hours) === 8 && Number(rel.mttr_hours) === 2 && rel.mtbf_state === 'value', `MTBF / MTTR: ${v.rel}`)
    must(rel.runs_without_machine === Number(v.nomach) && Number(v.nomachMine) >= 1 && rel.unclassified_stops === 0, `runs without a machine: ${v.rel} vs counted ${v.nomach} (mine ${v.nomachMine})`)
    must(v.relAll === '2' && v.relNo.startsWith('PERMISSION_DENIED|module.processing.view'), `reliability lists / refuses: ${v.relAll} / ${v.relNo}`)
    console.log(`STEP|reliability|runs [01:00,05:00) [03:00,07:00) [12:00,14:00) on the machine + one with no machine → operating hours ${rel.operating_hours} (overlap counted once, 3 runs) · failures ${rel.failures} (the voided one not counted) · MTBF ${rel.mtbf_hours} h · MTTR ${rel.mttr_hours} h · runs without a machine ${rel.runs_without_machine} (counted independently ${v.nomach}, ${v.nomachMine} of them mine) · a reader without the processing view: «${v.relNo.slice(0, 45)}»`)

    // ══ ③ 分析证书:签发人的名字画不出来 → 路由在铸号之前就拒;名字干净的签发人照常签(经函数,故意不存字节)══
    let res
    v = await run(`SELECT 'OUT|ob|' || pg_temp.val_('ob');`, 'ob')
    const ob = v.ob
    res = await asRoute('bad', () => coaRoute.POST(new Request(`${BASE}/output/${ob}/coa/pdf`, { method: 'POST', body: '{}' }), ctx(ob)))
    const badText = await res.text()
    v = await run(`SELECT 'OUT|n|' || (SELECT count(*) FROM certificates_of_analysis)::text; SELECT 'OUT|next|' || next_coa_code();`, 'after refusal')
    must(res.status === 400 && /≤|U\+2264/.test(badText), `an issuer named «Lim ≤ (probe)» must be refused with 400 naming the character, got ${res.status}: ${badText.slice(0, 200)}`)
    must(v.n === (await run(`SELECT 'OUT|x|' || pg_temp.val_('nCoa');`, 'n')).x && v.next === (await run(`SELECT 'OUT|x|' || pg_temp.val_('nextCoa');`, 'n')).x,
        `nothing may be minted: certificates ${v.n}, next number ${v.next}`)
    console.log(`STEP|coa issuer|the route refused an issuer named «Lim ≤ (probe)» with 400 before issuing («${badText.split('\n')[0].slice(0, 90)}») · certificates still ${v.n}, next number still ${v.next}`)

    // ══ ④ 存 PDF:一张已签发、没有字节的证书(经 issue_coa 签发、不经路由存 —— 签发时上传失败留下的那一种)══
    v = await run(String.raw`
SELECT 'OUT|issued|' || pg_temp.get_('iss', format($q$SELECT issue_coa(%L)$q$, pg_temp.id_('ob')))::text;
`, 'issue without bytes')
    const coa = JSON.parse(v.issued)
    v = await run(`SELECT 'OUT|bytes|' || (SELECT count(*) FROM coa_issues WHERE coa_id = ${lit(coa.coa_id)}::uuid)::text;`, 'bytes before')
    must(v.bytes === '0' && coa.snapshot?.issuer?.name === 'Tan (probe)', `the issued certificate must start with no bytes: ${v.bytes}, issuer ${JSON.stringify(coa.snapshot?.issuer)}`)
    res = await asRoute('iss', () => coaRoute.POST(new Request(`${BASE}/output/${ob}/coa/pdf`, { method: 'POST', body: JSON.stringify({ storeFor: coa.coa_id }) }), ctx(ob)))
    const saved = await res.json().catch(async () => ({ text: await res.text() }))
    must(res.status === 200 && saved.stored === true, `save PDF: ${res.status} ${JSON.stringify(saved).slice(0, 200)}`)
    v = await run(`SELECT 'OUT|rec|' || (SELECT to_jsonb(i) FROM (SELECT file_path, sha256 FROM coa_issues WHERE coa_id = ${lit(coa.coa_id)}::uuid) i)::text;`, 'bytes after')
    const recd = JSON.parse(v.rec)
    const stored = await bytesAsService('coa-documents', recd.file_path)
    must(stored.status === 200 && sha(stored.buf) === recd.sha256, `the stored bytes match the recorded sha256 (${stored.status})`)
    const coaText = pdfText(stored.buf)
    must(coaText.includes(coa.code) && coaText.includes('Issued by Tan (probe), Quality Manager (probe)'), `the saved PDF says the number and the issuer from the snapshot`)
    // 取存下的那一份:经路由的 ?coa=,重算哈希
    res = await asRoute('iss', () => coaRoute.GET(new Request(`${BASE}/output/${ob}/coa/pdf?coa=${encodeURIComponent(coa.code)}`), ctx(ob)))
    must(res.status === 200 && sha(Buffer.from(await res.arrayBuffer())) === recd.sha256, `?coa= streams the stored bytes (${res.status})`)
    res = await asRoute('iss', () => coaRoute.POST(new Request(`${BASE}/output/${ob}/coa/pdf`, { method: 'POST', body: JSON.stringify({ storeFor: coa.coa_id }) }), ctx(ob)))
    must(res.status === 400, `a second save PDF must refuse (${res.status})`)
    console.log(`STEP|save pdf|${coa.code} issued by «Tan (probe)» with no stored bytes → Save PDF (route POST {storeFor}) rendered the snapshot, uploaded ${recd.file_path.slice(0, 12)}…, recorded sha ${recd.sha256.slice(0, 12)}… · the stored bytes match · ?coa= streams them · a second save refused`)

    // ══ ⑤ 销毁证书:待签发 → 内部存档(活数据);签发 → 照快照渲染;改活数据之后,不带 ?cod= 仍流存下的字节 ══
    v = await run(`SELECT 'OUT|ib|' || pg_temp.val_('ib');`, 'ib')
    const ib = v.ib
    res = await asRoute('cod', () => codRoute.GET(new Request(`${BASE}/inbound/${ib}/cod/pdf`), ctx(ib)))
    must(res.status === 200, `the pending internal preview: ${res.status} ${(await res.clone().text()).slice(0, 200)}`)
    const prevText = pdfText(Buffer.from(await res.arrayBuffer()))
    must(prevText.includes('ZZ-PROBE-MES7A1 Battery Recycle Co') && !/COD-\d{4}-\d{4}/.test(prevText), `the pending preview is rendered from live data and carries no number: ${prevText.slice(0, 300)}`)
    res = await asRoute('cod', () => codRoute.POST(new Request(`${BASE}/inbound/${ib}/cod/pdf`, { method: 'POST' }), ctx(ib)))
    const issuedCod = await res.json().catch(async () => ({ text: await res.text() }))
    must(res.status === 200 && /^COD-\d{4}-\d{4}$/.test(issuedCod.code ?? ''), `issuing the COD through the route: ${res.status} ${JSON.stringify(issuedCod).slice(0, 200)}`)
    v = await run(String.raw`
SELECT 'OUT|ci|' || (SELECT to_jsonb(i) FROM (SELECT i.file_path, i.sha256, c.snapshot -> 'supplier' ->> 'name' AS sup, c.snapshot -> 'company' ->> 'legal_name' AS co
                       FROM cod_issues i JOIN certificates_of_destruction c ON c.id = i.cod_id WHERE c.code = ${lit(issuedCod.code)}) i)::text;
`, 'cod record')
    const ci = JSON.parse(v.ci)
    const codStored = await bytesAsService('cod-documents', ci.file_path)
    must(codStored.status === 200 && sha(codStored.buf) === ci.sha256, 'the stored COD bytes match the recorded sha256')
    const codText = pdfText(codStored.buf)
    must(codText.includes(issuedCod.code) && codText.includes(ci.sup) && codText.includes(ci.co), 'the COD paper carries the snapshot\'s number, supplier and letterhead')
    // 改活数据:供应商改名 —— 快照不动;不带 ?cod= 打开流出的是存下的那一份
    v = await run(`UPDATE suppliers SET legal_name = 'ZZ-PROBE-MES7A1 RENAMED supplier' WHERE id = pg_temp.id_('sup'); SELECT 'OUT|ok|1';`, 'rename')
    res = await asRoute('cod', () => codRoute.GET(new Request(`${BASE}/inbound/${ib}/cod/pdf`), ctx(ib)))
    const bare = Buffer.from(await res.arrayBuffer())
    must(res.status === 200 && sha(bare) === ci.sha256, `a bare GET of the issued COD must stream the stored bytes (${res.status}, sha ${sha(bare).slice(0, 12)} vs ${ci.sha256.slice(0, 12)})`)
    must(!pdfText(bare).includes('RENAMED'), 'the bare GET must not carry the renamed (live) supplier')
    console.log(`STEP|cod|pending → internal preview from live data · issued ${issuedCod.code} through the route → rendered from the snapshot issue_cod returned (supplier «${ci.sup}», letterhead «${ci.co}»), stored, sha recorded · supplier renamed live → a bare GET streams the stored bytes (sha ${ci.sha256.slice(0, 12)}…), not a re-render`)

    // ══ ⑥ 逐角色读数(七个真角色此刻的码的克隆,只读)══
    for (const r of ROLE_CLONES) {
        const key = `c_${r}`
        v = await run(String.raw`
SELECT 'OUT|row|' || jsonb_build_object(
    'codes', (SELECT count(*) FROM role_permissions rp JOIN roles ro ON ro.id = rp.role_id WHERE ro.code = ${lit(r)}),
    'proc_view', pg_temp.get_(${lit(key)}, $q$SELECT to_jsonb(has_permission('module.processing.view'))$q$),
    'proc_edit', pg_temp.get_(${lit(key)}, $q$SELECT to_jsonb(has_permission('module.processing.edit'))$q$),
    'fin_view', pg_temp.get_(${lit(key)}, $q$SELECT to_jsonb(has_permission('module.finance.view'))$q$),
    'fin_edit', pg_temp.get_(${lit(key)}, $q$SELECT to_jsonb(has_permission('module.finance.edit'))$q$),
    'downtime_rows', pg_temp.get_(${lit(key)}, format($q$SELECT to_jsonb(count(*)) FROM equipment_downtime WHERE equipment_id = %L$q$, pg_temp.id_('m'))),
    'causes', pg_temp.get_(${lit(key)}, $q$SELECT to_jsonb(count(*)) FROM downtime_causes$q$),
    'reliability', pg_temp.try_(${lit(key)}, format($q$SELECT count(*) FROM equipment_reliability(%L)$q$, pg_temp.id_('m'))),
    'record', pg_temp.would_(${lit(key)}, format($q$SELECT open_equipment_downtime(%L, (CURRENT_DATE - 1)::timestamptz, 'breakdown', 'role probe')$q$, pg_temp.id_('m2')))
)::text;
`, `role ${r}`)
        const rr = JSON.parse(v.row)
        console.log(`ROLE|${r}|codes ${rr.codes}|processing view ${rr.proc_view}|record equipment ${rr.record === 'OK' ? 'yes' : 'no («' + rr.record.slice(0, 40) + '»)'}|finance view ${rr.fin_view}|capitalise ${rr.fin_edit}|downtime rows seen ${rr.downtime_rows}|causes seen ${rr.causes}|reliability ${rr.reliability === 'OK' ? 'yes' : 'no («' + rr.reliability.slice(0, 40) + '»)'}`)
    }

    // ══ ⑦ 在册的东西一个字都没动;回滚 ══
    v = await run(String.raw`
DO $s$
DECLARE v_rec text; v_diff text;
BEGIN
    SELECT string_agg(k, ', ' ORDER BY k) INTO v_diff
      FROM jsonb_each_text(pg_temp.fp_(pg_temp.val_('t0')::timestamptz)) n(k, v)
     WHERE v IS DISTINCT FROM (pg_temp.val_('fp')::jsonb ->> k);
    IF v_diff IS NOT NULL THEN RAISE EXCEPTION 'MES7A1_LIVE|pre-existing rows changed in: %', v_diff; END IF;
    IF (SELECT COALESCE(string_agg(subject_type || ':' || code, ',' ORDER BY code), '') FROM approval_pending_documents()) <> pg_temp.val_('pending') THEN
        RAISE EXCEPTION 'MES7A1_LIVE|pending documents changed';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN RAISE EXCEPTION 'MES7A1_LIVE|require_calibrated_since set'; END IF;
    IF NOT approvals_enabled() THEN RAISE EXCEPTION 'MES7A1_LIVE|approvals switched off'; END IF;
    v_rec := pg_temp.agree_('end');
    RAISE NOTICE 'STEP|untouched|pre-existing rows identical; pending «%»; approvals on; require_calibrated_since NULL; reconciliation %', pg_temp.val_('pending'), v_rec;
    RAISE NOTICE 'STEP|done|%', clock_timestamp() - pg_temp.val_('t0')::timestamptz;
END $s$;
ROLLBACK;
SELECT 'OUT|afterDb|' || 'downtime=' || (SELECT count(*) FROM equipment_downtime) || ' · maintenance=' || (SELECT count(*) FROM equipment_maintenance)
    || ' · intervals=' || (SELECT count(*) FROM equipment_service_intervals) || ' · causes=' || (SELECT count(*) FROM downtime_causes)
    || ' · CoAs=' || (SELECT count(*) FROM certificates_of_analysis) || ' · coa byte records=' || (SELECT count(*) FROM coa_issues)
    || ' · CODs issued=' || (SELECT count(*) FROM certificates_of_destruction WHERE status = 'issued') || ' · cod byte records=' || (SELECT count(*) FROM cod_issues)
    || ' · probe rows=' || ((SELECT count(*) FROM fixed_assets WHERE code LIKE 'ZZ-PROBE-MES7A1%') + (SELECT count(*) FROM employees WHERE code LIKE 'ZZ-PROBE-MES7A1%')
                            + (SELECT count(*) FROM suppliers WHERE code LIKE 'ZZ-PROBE-MES7A1%') + (SELECT count(*) FROM processing_runs WHERE code LIKE 'ZZ-PROBE-MES7A1%'))
    || ' · require_calibrated_since=' || COALESCE((SELECT require_calibrated_since::text FROM ingest_settings), 'NULL')
    || ' · approvals=' || approvals_enabled()::text;
`, 'close')
    console.log(`AFTER|database (after ROLLBACK): ${v.afterDb}`)
    psql.stdin.end()

    // 桶:删掉路由传上去的每一个对象,再读回 —— 只剩开跑前那几个,字节逐个相同
    const { URL, SERVICE } = env()
    for (const u of uploads) {
        const r = await fetch(`${URL}/storage/v1/object/${u.bucket}`, { method: 'DELETE', headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, 'Content-Type': 'application/json' },
            body: JSON.stringify({ prefixes: [u.path] }) })
        must(r.ok, `removing ${u.bucket}/${u.path}: HTTP ${r.status}`)
    }
    const after = await bucketFingerprint()
    bucketVerdict = `${uploads.length} object(s) uploaded by the proof, all removed; ` + BUCKETS.map((b) => `${b}: ${Object.keys(after[b]).length} object(s)`).join(' · ')
    must(JSON.stringify(after) === JSON.stringify(bucketsBefore), `the buckets do not hold exactly what they held before: ${JSON.stringify(after)}`)
    console.log(`STEP|buckets after|${JSON.stringify(after)} — identical to before (paths and sha256)`)
    console.log('✓ 证明走完(STEP|done),事务已回滚,两个桶只剩开跑前的对象')
    return exitAfterCleanup(0)
}

async function endTransaction() {
    if (!psql || psql.exitCode !== null) return
    const gone = new Promise((r) => psql.once('exit', r))
    psql.kill('SIGTERM')
    await Promise.race([gone, new Promise((r) => setTimeout(r, 10_000))])
}
main().catch(async (e) => {
    console.error('✗ ' + (e?.stack || e))
    await endTransaction()
    // 传上去的对象:计划里登记过删除步,exitAfterCleanup 会跑;这里先读回一次,好让判决看得见
    return exitAfterCleanup(String(e?.message || '').startsWith('MES7A1_') ? 1 : 2)
})
