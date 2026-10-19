#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// MES-9b(2026-10-19)· 门户取档的证明,在一个【本地重建库】上、用自带的数据(Tim 的裁定 4:线上不提交任何一次性的签发档)
// ════════════════════════════════════════════════════════════════════════════
// 自己起一个一次性的本地集群(db/verify_rebuild.py --skip-diff,再装 storage 桩与 db/storage/buckets-and-policies.sql —— 与 db/gate.py
//   一样的建法),装两家供应商 A、B 的全套:采购单(签发两版)· 对账单(签发)· 销毁证书(签发一张、作废一张),每一份签发档的 PDF 字节
//   写在一个本地目录里(本地的"桶"),storage.objects 里各有一行。
// 然后把【原样的】路由 app/portal/documents/file/route.ts 经 jiti 装进来,'@/lib/supabase/server' 换成一个连这个本地库的客户端:
//   · .rpc(...) = 以那个门户账号的身份(SET ROLE supplier_portal + 它的 JWT 声明,会话在 auth.sessions 里)调那支函数;
//   · .storage.from(b).download(p) = 先以【同一身份】问 storage.objects 那一行读不读得到(真的 RLS、真的门户策略,与 Storage API 判它的
//     方式一样),读得到才从本地目录读字节 —— 于是"存储只放行刚记过的那一个对象"在这里是真的被策略判的,不是这个替身判的。
//   '@/lib/portalSession' 换成一个按当前身份回答的替身(门户账号 → 是;员工 → 否)。
// 证:三种签发档各取一份 → 200、字节的 sha256 = 记下的、每次一行下载记录;别家的 → 404 且不写记录;作废的证书 → 410;种类不认识 → 400;
//   员工会话 → 403;把一份存下的字节改掉 → 409;一份从没取过的对象,存储策略读不到;门户会话直接读下载记录表 → 拒。
// 判决只从最后一行 `MES9B_LOCAL_PROOF_EXIT=` 读:0 = 每一格 PASS · 1 = 有 FAIL · 2 = 驱动坏了。不碰线上。
// 用法:node db/scripts/2026-10-19-mes9b-local-download-proof.mjs > <log> 2>&1
// ════════════════════════════════════════════════════════════════════════════
import { onlyWhenRunDirectly } from '../../scripts/lib/entrypoint.mjs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawnSync } from 'node:child_process'
import { createHash, randomUUID } from 'node:crypto'
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, existsSync } from 'node:fs'

onlyWhenRunDirectly(import.meta.url)

const ROOT = dirname(dirname(dirname(fileURLToPath(import.meta.url))))
const W = mkdtempSync('/tmp/mes9bdl.')
const SOCK = join(W, 's'), PORT = '55442', DATA = join(W, 'pg'), STORE = join(W, 'store')
const DSN = `host=${SOCK} port=${PORT} user=postgres dbname=dl`
let bad = 0
const ok = (c, what) => { console.log(`${c ? 'PASS' : 'FAIL'}|${what}`); if (!c) bad++; return c }
const sha = (b) => createHash('sha256').update(b).digest('hex')
const lit = (s) => `'${String(s).replace(/'/g, "''")}'`
function sh(cmd, args, input) { return spawnSync(cmd, args, { input, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 }) }
function psql(sql) {
    const r = sh('psql', [DSN, '-X', '-At', '-v', 'ON_ERROR_STOP=1'], sql)
    if (r.status !== 0) throw new Error(`MES9B_LOCAL_DRIVER|psql: ${(r.stderr || '').slice(0, 400)}`)
    return r.stdout.trim()
}
function finish(code) {
    sh('pg_ctl', ['-D', DATA, 'stop', '-m', 'immediate'])
    try { rmSync(W, { recursive: true, force: true }) } catch { /* scratch */ }
    console.log(`MES9B_LOCAL_PROOF_EXIT=${code}`)
    process.exit(code)
}

// ── who the route runs as ──
let actor = null                 // { claims, portal: boolean } or null
// run one statement as the actor: SET ROLE + claims, inside one psql session; returns {data} or {error}
function asActor(sql) {
    const role = actor?.portal ? 'supplier_portal' : 'authenticated'
    const r = sh('psql', [DSN, '-X', '-q', '-At', '-v', 'ON_ERROR_STOP=1'],
        `BEGIN;\nSET LOCAL "request.jwt.claims" = ${lit(JSON.stringify(actor?.claims ?? {}))};\nSET LOCAL ROLE ${role};\n${sql};\nCOMMIT;\n`)
    if (r.status !== 0) {
        const m = (r.stderr || '').split('\n').find((l) => l.startsWith('ERROR:')) || r.stderr
        return { error: { message: m.replace(/^ERROR:\s*/, '').trim(), code: /permission denied/.test(m) ? '42501' : 'P0001' } }
    }
    const v = r.stdout.replace(/\n$/, '')
    return { data: v === '' ? null : v }
}
globalThis.__TXN_CLIENT__ = () => ({
    rpc: async (name, args = {}) => {
        const a = Object.entries(args).map(([k, v]) => `${k} => ${v === null ? 'NULL' : lit(v)}`).join(', ')
        const r = asActor(`SELECT (public.${name}(${a}))::text`)
        if (r.error) return { data: null, error: r.error }
        try { return { data: JSON.parse(r.data), error: null } } catch { return { data: r.data, error: null } }
    },
    storage: {
        from: (bucket) => ({
            download: async (path) => {
                // the Storage API's own question, asked the same way: can this role, with these claims, select that row?
                const r = asActor(`SELECT count(*)::text FROM storage.objects WHERE bucket_id = ${lit(bucket)} AND name = ${lit(path)}`)
                if (r.error || r.data !== '1') return { data: null, error: { message: r.error?.message ?? 'Object not found' } }
                const f = join(STORE, bucket, path)
                if (!existsSync(f)) return { data: null, error: { message: 'no bytes' } }
                return { data: new Blob([readFileSync(f)]), error: null }
            },
        }),
    },
    auth: { getSession: async () => ({ data: { session: null } }) },
})
globalThis.__PORTAL_SESSION__ = () => !!actor?.portal

async function main() {
    // ── a throwaway local cluster, rebuilt the way db/gate.py builds it ──
    mkdirSync(SOCK); mkdirSync(STORE)
    if (sh('initdb', ['-D', DATA, '-U', 'postgres', '--no-locale', '--encoding=UTF8']).status !== 0) throw new Error('MES9B_LOCAL_DRIVER|initdb')
    if (sh('pg_ctl', ['-D', DATA, '-o', `-p ${PORT} -k ${SOCK} -c listen_addresses=''`, '-l', join(W, 'pg.log'), 'start', '-w']).status !== 0) throw new Error('MES9B_LOCAL_DRIVER|pg_ctl')
    sh('createdb', ['-h', SOCK, '-p', PORT, '-U', 'postgres', 'dl'])
    const vr = sh('python3', [join(ROOT, 'db/verify_rebuild.py'), '--target', DSN, '--skip-diff'])
    if (vr.status !== 0) throw new Error(`MES9B_LOCAL_DRIVER|rebuild exit ${vr.status}: ${(vr.stdout || '').slice(-400)}`)
    const st = sh('psql', [DSN, '-X', '-q', '-v', 'ON_ERROR_STOP=1', '-f', join(ROOT, 'db/storage/platform-storage-stub.sql'), '-f', join(ROOT, 'db/storage/buckets-and-policies.sql')])
    if (st.status !== 0) throw new Error(`MES9B_LOCAL_DRIVER|storage: ${st.stderr.slice(0, 300)}`)
    console.log('· a fresh local rebuild (db/verify_rebuild.py --skip-diff) + storage stub + db/storage/buckets-and-policies.sql')

    // ── data of its own: two suppliers, two portal accounts with live sessions, every kind of issued document, bytes on disk ──
    const U = {}
    for (const k of ['A', 'B']) {
        const u = { k, sup: randomUUID(), contact: randomUUID(), user: randomUUID(), sid: randomUUID() }
        u.po = { id: randomUUID(), code: `LOCAL-${k}-PO1`, i1: randomUUID(), i2: randomUUID() }
        u.st = { id: randomUUID(), code: `LOCAL-${k}-ST1`, i: randomUUID() }
        u.b = randomUUID(); u.b2 = randomUUID()
        u.cod = { id: randomUUID(), code: `LOCAL-${k}-COD1`, i: randomUUID(), void: randomUUID(), voidCode: `LOCAL-${k}-COD0`, vi: randomUUID() }
        u.files = {}
        const put = (bucket, path, text) => {
            const bytes = Buffer.from(`%PDF-1.4\n% ${text}\n%%EOF\n`)
            mkdirSync(dirname(join(STORE, bucket, path)), { recursive: true })
            writeFileSync(join(STORE, bucket, path), bytes)
            return { bucket, path, sha: sha(bytes) }
        }
        u.files.po1 = put('po-documents', `${u.po.id}/v1.pdf`, `order ${k} v1`)
        u.files.po2 = put('po-documents', `${u.po.id}/v2.pdf`, `order ${k} v2`)
        u.files.st = put('supplier-statement-documents', `${u.st.id}/s.pdf`, `statement ${k}`)
        u.files.cod = put('cod-documents', `${u.cod.id}/c.pdf`, `certificate ${k}`)
        u.files.never = put('po-documents', `${u.po.id}/never-opened.pdf`, `an object ${k} never logged`)
        U[k] = u
    }
    const base = psql('SELECT code FROM currencies WHERE is_base')
    const mat = randomUUID()
    let seed = `INSERT INTO materials (id, code, name, kind_code, may_be_processed, form_code, source_code) VALUES (${lit(mat)}, 'LOCAL-M', 'local black mass', 'battery_material', true, 'black_mass', 'end_of_life');\n`
    for (const u of Object.values(U)) {
        seed += `
INSERT INTO suppliers (id, code, legal_name, country, status, counterparty_type) VALUES (${lit(u.sup)}, 'LOCAL-S${u.k}', 'local supplier ${u.k}', 'SG', 'active', 'goods_supplier');
INSERT INTO counterparty_contacts (id, supplier_id, name, email) VALUES (${lit(u.contact)}, ${lit(u.sup)}, 'local ${u.k}', '${u.k.toLowerCase()}@local.test');
INSERT INTO auth.users (id, email, email_confirmed_at) VALUES (${lit(u.user)}, '${u.k.toLowerCase()}@local.test', now());
INSERT INTO auth.sessions (id, user_id) VALUES (${lit(u.sid)}, ${lit(u.user)});
INSERT INTO supplier_portal_users (user_id, supplier_id, contact_id) VALUES (${lit(u.user)}, ${lit(u.sup)}, ${lit(u.contact)});
INSERT INTO purchase_orders (id, code, supplier_id, order_date, currency, fx_rate, status, approval_status, category) VALUES (${lit(u.po.id)}, ${lit(u.po.code)}, ${lit(u.sup)}, current_date, ${lit(base)}, 1, 'confirmed', 'approved', 'equipment_goods');
INSERT INTO po_issues (id, purchase_order_id, version, file_path, sha256) VALUES (${lit(u.po.i1)}, ${lit(u.po.id)}, 1, ${lit(u.files.po1.path)}, ${lit(u.files.po1.sha)}), (${lit(u.po.i2)}, ${lit(u.po.id)}, 2, ${lit(u.files.po2.path)}, ${lit(u.files.po2.sha)});
INSERT INTO supplier_statements (id, code, supplier_id, supplier_code, supplier_name, company, period_start, period_end, base_currency, opening_base, charges_base, credits_base, payments_base, prepayments_base, closing_base, list_base, on_account_base, residue_base, lines, open_items, on_account, unpriced, by_currency)
VALUES (${lit(u.st.id)}, ${lit(u.st.code)}, ${lit(u.sup)}, 'LOCAL-S${u.k}', 'local supplier ${u.k}', '{"legal_name":"local"}', current_date - 30, current_date - 1, ${lit(base)}, 1, 0, 0, 0, 0, 1, 1, 0, 0, '[]', '[]', '[]', '[]', '[]');
INSERT INTO supplier_statement_issues (id, statement_id, version, file_path, sha256) VALUES (${lit(u.st.i)}, ${lit(u.st.id)}, 1, ${lit(u.files.st.path)}, ${lit(u.files.st.sha)});
INSERT INTO inbound_batches (id, code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note) VALUES
  (${lit(u.b)}, 'LOCAL-${u.k}-B1', ${lit(mat)}, ${lit(u.sup)}, 10, 10, 'kg', current_date, 'other', 'local proof'), (${lit(u.b2)}, 'LOCAL-${u.k}-B2', ${lit(mat)}, ${lit(u.sup)}, 10, 10, 'kg', current_date, 'other', 'local proof');
INSERT INTO certificates_of_destruction (id, inbound_batch_id, completed_on, status, code, verification_token, snapshot, issued_at) VALUES (${lit(u.cod.id)}, ${lit(u.b)}, current_date, 'issued', ${lit(u.cod.code)}, gen_random_uuid(), '{}', now());
INSERT INTO certificates_of_destruction (id, inbound_batch_id, completed_on, status, code, verification_token, snapshot, issued_at, void_reason, voided_at) VALUES (${lit(u.cod.void)}, ${lit(u.b2)}, current_date, 'void', ${lit(u.cod.voidCode)}, gen_random_uuid(), '{}', now(), 'local', now());
INSERT INTO cod_issues (id, cod_id, file_path, sha256) VALUES (${lit(u.cod.i)}, ${lit(u.cod.id)}, ${lit(u.files.cod.path)}, ${lit(u.files.cod.sha)}), (${lit(u.cod.vi)}, ${lit(u.cod.void)}, ${lit(u.cod.void + '/v.pdf')}, ${lit('0'.repeat(64))});
INSERT INTO storage.objects (bucket_id, name) VALUES ('po-documents', ${lit(u.files.po1.path)}), ('po-documents', ${lit(u.files.po2.path)}), ('po-documents', ${lit(u.files.never.path)}),
  ('supplier-statement-documents', ${lit(u.files.st.path)}), ('cod-documents', ${lit(u.files.cod.path)});`
        u.claims = { sub: u.user, role: 'supplier_portal', session_id: u.sid }
    }
    psql(seed)
    console.log('· seeded: suppliers A and B, a portal account each with a live session, orders (v1, v2), statements, certificates (issued, void), bytes on disk')

    // ── the route, unchanged ──
    const { createJiti } = await import('jiti')
    const jiti = createJiti(import.meta.url, {
        interopDefault: true,
        alias: {
            '@/lib/supabase/server': join(ROOT, 'db/scripts/lib/txn-supabase-server.mjs'),
            '@/lib/portalSession': join(ROOT, 'db/scripts/lib/portal-session-stub.mjs'),
            '@/lib/i18n/server': join(ROOT, 'scripts/pdf-routes/i18n-server.mjs'),
            'server-only': join(ROOT, 'scripts/pdf-routes/empty.mjs'),
            '@': ROOT,
        },
    })
    const route = await jiti.import(join(ROOT, 'app/portal/documents/file/route.ts'))
    const get = async (who, kind, id) => {
        actor = who
        try {
            const res = await route.GET(new Request(`http://local/portal/documents/file?kind=${kind}&id=${id}`))
            const buf = Buffer.from(await res.arrayBuffer())
            return { status: res.status, type: res.headers.get('content-type') || '', buf, text: buf.toString('utf8') }
        } finally { actor = null }
    }
    const logs = (u, issue) => Number(psql(`SELECT count(*) FROM portal_document_downloads WHERE user_id = ${lit(u.user)}${issue ? ` AND issue_id = ${lit(issue)}` : ''}`))
    const A = U.A, B = U.B
    const pa = { claims: A.claims, portal: true }, pb = { claims: B.claims, portal: true }

    for (const [label, u, who, kind, issue, file] of [
        ['A · order v2', A, pa, 'purchase_order', A.po.i2, A.files.po2], ['A · order v1 (superseded)', A, pa, 'purchase_order', A.po.i1, A.files.po1],
        ['A · statement', A, pa, 'supplier_statement', A.st.i, A.files.st], ['A · certificate', A, pa, 'cod', A.cod.i, A.files.cod],
        ['B · order v2', B, pb, 'purchase_order', B.po.i2, B.files.po2], ['B · statement', B, pb, 'supplier_statement', B.st.i, B.files.st],
        ['B · certificate', B, pb, 'cod', B.cod.i, B.files.cod]]) {
        const before = logs(u)
        const r = await get(who, kind, issue)
        ok(r.status === 200 && r.type.startsWith('application/pdf') && sha(r.buf) === file.sha && logs(u, issue) >= 1 && logs(u) === before + 1,
           `local HTTP ${label}: ${r.status} ${r.type.split(';')[0]}, the stored bytes (sha256 ${file.sha.slice(0, 12)}… re-checked), one download-log row`)
    }
    for (const [label, who, kind, issue, me] of [['A asks for B\'s order', pa, 'purchase_order', B.po.i2, A], ['A asks for B\'s statement', pa, 'supplier_statement', B.st.i, A],
                                                 ['A asks for B\'s certificate', pa, 'cod', B.cod.i, A], ['B asks for A\'s order', pb, 'purchase_order', A.po.i1, B]]) {
        const before = logs(me)
        const r = await get(who, kind, issue)
        ok(r.status === 404 && logs(me) === before, `local HTTP ${label}: ${r.status} "${r.text.slice(0, 50)}", no log row written`)
    }
    let r = await get(pa, 'cod', A.cod.vi)
    ok(r.status === 410 && /PORTAL_DOCUMENT_VOID/.test(r.text), `local HTTP A asks for its void certificate: ${r.status} "${r.text.slice(0, 60)}"`)
    r = await get(pa, 'invoice', A.po.i1)
    ok(r.status === 400, `local HTTP an unknown kind: ${r.status}`)
    r = await get({ claims: { sub: randomUUID(), role: 'authenticated' }, portal: false }, 'purchase_order', A.po.i1)
    ok(r.status === 403, `local HTTP a staff session: ${r.status} "${r.text.slice(0, 50)}"`)
    // 409: alter A's stored order v2 bytes and download again
    writeFileSync(join(STORE, 'po-documents', A.files.po2.path), Buffer.from('%PDF-1.4\n% altered\n%%EOF\n'))
    r = await get(pa, 'purchase_order', A.po.i2)
    ok(r.status === 409 && /does not match/.test(r.text), `local HTTP A downloads its altered order: ${r.status} "${r.text.slice(0, 60)}"`)
    // the storage policy itself: an object A never logged is unreadable to it; B never reads A's object even though A logged it
    actor = pa
    const never = asActor(`SELECT count(*)::text FROM storage.objects WHERE bucket_id = 'po-documents' AND name = ${lit(A.files.never.path)}`)
    actor = pb
    const cross = asActor(`SELECT count(*)::text FROM storage.objects WHERE bucket_id = 'po-documents' AND name = ${lit(A.files.po1.path)}`)
    const direct = asActor('SELECT count(*)::text FROM public.portal_document_downloads')
    actor = null
    ok(never.data === '0', `local storage policy: an object A never logged → ${never.data} row(s) visible`)
    ok(cross.data === '0', `local storage policy: A's just-logged object, asked by B → ${cross.data} row(s) visible`)
    ok(!!direct.error && /permission denied/.test(direct.error.message), `local: a portal session reading the download log directly → refused (${(direct.error?.message ?? '').slice(0, 60)})`)
    const rows = psql(`SELECT string_agg(document_kind || ':' || document_code || ':' || COALESCE(version::text, '-'), ',' ORDER BY downloaded_at) FROM portal_document_downloads WHERE user_id = ${lit(A.user)}`)
    console.log(`LOG|A's download-log rows (kind:code:version, in order): ${rows}`)
    ok(rows.split(',').length === 5, `local: A has exactly 5 download-log rows (4 served + the 409 attempt; the refusals wrote none)`)
    console.log(bad ? `STEP|done with ${bad} FAIL` : 'STEP|done')
    finish(bad ? 1 : 0)
}

main().catch((e) => { console.error(String(e?.stack || e)); finish(String(e?.message || '').startsWith('MES9B_LOCAL_DRIVER') ? 2 : 1) })
