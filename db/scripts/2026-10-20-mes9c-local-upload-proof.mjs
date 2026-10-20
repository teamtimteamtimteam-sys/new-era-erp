#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// MES-9c(2026-10-20)· 门户交证书与员工审核的证明,在一个【本地重建库】上、用自带的数据(委托书:线上不提交任何一份申请)
// ════════════════════════════════════════════════════════════════════════════
// 自己起一个一次性的本地集群(db/verify_rebuild.py --skip-diff,再装 storage 桩与 db/storage/buckets-and-policies.sql —— 与 db/gate.py
//   一样的建法),装两家供应商 A、B,各一个门户账号(会话在 auth.sessions 里),一个持 module.suppliers.edit 的员工、一个只持查看码的员工。
// 然后把【原样的】上传路由 app/portal/certificates/upload/route.ts 与【原样的】审核动作 app/suppliers/[id]/edit/portalSubmissionActions.ts
//   经 jiti 装进来,'@/lib/supabase/server' 换成一个连这个本地库的客户端:
//   · .rpc(...) = 以当前身份(SET ROLE supplier_portal / authenticated + 它的 JWT 声明)调那支函数;
//   · .storage.from(b).upload(p, bytes) = 以【同一身份】往 storage.objects 插那一行(真的 RLS、真的门户策略,与 Storage API 判它的方式一样;
//     插得进才把字节写进本地目录 —— 本地的"桶");.copy(from, to, {destinationBucket}) = 以同一身份读源那一行、插目的那一行、抄字节;
//     .remove = 以同一身份删;.createSignedUrl = 以同一身份读得到那一行才给一个本地链接。
//   '@/lib/portalSession' 换成按当前身份回答的替身;'next/cache' 的 revalidatePath 换成空操作(本地没有 Next 的渲染缓存);
//   '@/lib/permissions' 换成同一个判法(current_user_permissions 里有没有那个码)的替身 —— 那个文件用的 React cache 在 Next 外面不存在。
// 证:HTTP 上传 —— 合格的 PDF → 303 ?submitted=1、一份等审核的申请、桶里那一份字节;10 MB + 1 字节 → ?error=PORTAL_UPLOAD_TOO_LARGE、没有申请、
//   桶里没有多一个字节;GIF → ?error=PORTAL_UPLOAD_TYPE_NOT_ACCEPTED、同上;伪装成 PDF 的 GIF(文件头是 GIF)→ 按文件头拒;员工会话 → 403。
//   审核 —— 只持查看码的员工接受 → 拒;持编辑码的员工接受 → 文件抄进 supplier-attachments、一行证书挂上那一行附件;驳回没有理由 → 拒,有理由 → 驳回;
//   供应商看见 —— portal_certificates(/portal/certificates 读的那一支)回 accepted 与驳回的理由;B 一样都看不见。
// 判决只从最后一行 `MES9C_LOCAL_PROOF_EXIT=` 读:0 = 每一格 PASS · 1 = 有 FAIL · 2 = 驱动坏了。不碰线上。
// 用法:node db/scripts/2026-10-20-mes9c-local-upload-proof.mjs > <log> 2>&1
// ════════════════════════════════════════════════════════════════════════════
import { onlyWhenRunDirectly } from '../../scripts/lib/entrypoint.mjs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawnSync } from 'node:child_process'
import { createHash, randomUUID } from 'node:crypto'
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, existsSync, copyFileSync, unlinkSync } from 'node:fs'

onlyWhenRunDirectly(import.meta.url)

const ROOT = dirname(dirname(dirname(fileURLToPath(import.meta.url))))
const W = mkdtempSync('/tmp/mes9cup.')
const SOCK = join(W, 's'), PORT = '55445', DATA = join(W, 'pg'), STORE = join(W, 'store')
const DSN = `host=${SOCK} port=${PORT} user=postgres dbname=up`
let bad = 0
const ok = (c, what) => { console.log(`${c ? 'PASS' : 'FAIL'}|${what}`); if (!c) bad++; return c }
const sha = (b) => createHash('sha256').update(b).digest('hex')
const lit = (s) => `'${String(s).replace(/'/g, "''")}'`
function sh(cmd, args, input) { return spawnSync(cmd, args, { input, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 }) }
function psql(sql) {
    const r = sh('psql', [DSN, '-X', '-At', '-v', 'ON_ERROR_STOP=1'], sql)
    if (r.status !== 0) throw new Error(`MES9C_LOCAL_DRIVER|psql: ${(r.stderr || '').slice(0, 400)}`)
    return r.stdout.trim()
}
function finish(code) {
    sh('pg_ctl', ['-D', DATA, 'stop', '-m', 'immediate'])
    try { rmSync(W, { recursive: true, force: true }) } catch { /* scratch */ }
    console.log(`MES9C_LOCAL_PROOF_EXIT=${code}`)
    process.exit(code)
}

// ── who the code runs as ──
let actor = null                 // { claims, portal: boolean } or null
function asActor(sql) {
    const role = actor?.portal ? 'supplier_portal' : 'authenticated'
    const r = sh('psql', [DSN, '-X', '-q', '-At', '-v', 'ON_ERROR_STOP=1'],
        `BEGIN;\nSET LOCAL "request.jwt.claims" = ${lit(JSON.stringify(actor?.claims ?? {}))};\nSET LOCAL ROLE ${role};\n${sql};\nCOMMIT;\n`)
    if (r.status !== 0) {
        const m = (r.stderr || '').split('\n').find((l) => l.startsWith('ERROR:')) || r.stderr
        return { error: { message: m.replace(/^ERROR:\s*/, '').trim(), code: /permission denied|row-level security/.test(m) ? '42501' : 'P0001' } }
    }
    const v = r.stdout.replace(/\n$/, '')
    return { data: v === '' ? null : v }
}
const sqlVal = (v) => v === null || v === undefined ? 'NULL' : typeof v === 'number' ? String(v) : lit(v)
globalThis.__TXN_CLIENT__ = () => ({
    rpc: async (name, args = {}) => {
        const a = Object.entries(args).filter(([, v]) => v !== undefined).map(([k, v]) => `${k} => ${sqlVal(v)}`).join(', ')
        const r = asActor(`SELECT to_jsonb(public.${name}(${a}))::text`)
        if (r.error && process.env.LOCAL_DEBUG) console.log(`DEBUG|rpc ${name} → ${r.error.message}`)
        if (r.error) return { data: null, error: r.error }
        return { data: r.data === null ? null : JSON.parse(r.data), error: null }
    },
    from: (table) => {
        // the small read shape the review actions use: .select(cols).eq(col, v).maybeSingle()
        const q = { cols: '*', where: [] }
        const api = {
            select: (c) => { q.cols = c; return api },
            eq: (c, v) => { q.where.push(`${c} = ${lit(v)}`); return api },
            maybeSingle: async () => {
                const r = asActor(`SELECT row_to_json(x)::text FROM (SELECT ${q.cols} FROM public.${table} WHERE ${q.where.join(' AND ') || 'true'} LIMIT 1) x`)
                if (r.error) return { data: null, error: r.error }
                return { data: r.data ? JSON.parse(r.data) : null, error: null }
            },
        }
        return api
    },
    storage: {
        from: (bucket) => ({
            upload: async (path, bytes, opts = {}) => {
                const meta = JSON.stringify({ size: bytes.length, mimetype: opts.contentType ?? 'application/octet-stream' })
                const r = asActor(`INSERT INTO storage.objects (bucket_id, name, owner, metadata) VALUES (${lit(bucket)}, ${lit(path)}, (current_setting('request.jwt.claims')::jsonb ->> 'sub')::uuid, ${lit(meta)}::jsonb) RETURNING name`)
                if (r.error) return { data: null, error: { message: r.error.message } }
                mkdirSync(dirname(join(STORE, bucket, path)), { recursive: true })
                writeFileSync(join(STORE, bucket, path), Buffer.from(bytes))
                return { data: { path }, error: null }
            },
            copy: async (from, to, opts = {}) => {
                const dest = opts.destinationBucket ?? bucket
                const src = asActor(`SELECT metadata::text FROM storage.objects WHERE bucket_id = ${lit(bucket)} AND name = ${lit(from)}`)
                if (src.error || !src.data) return { data: null, error: { message: src.error?.message ?? 'Object not found' } }
                const ins = asActor(`INSERT INTO storage.objects (bucket_id, name, metadata) VALUES (${lit(dest)}, ${lit(to)}, ${lit(src.data)}::jsonb) RETURNING name`)
                if (ins.error) return { data: null, error: { message: ins.error.message } }
                mkdirSync(dirname(join(STORE, dest, to)), { recursive: true })
                copyFileSync(join(STORE, bucket, from), join(STORE, dest, to))
                return { data: { path: to }, error: null }
            },
            remove: async (paths) => {
                const out = []
                for (const p of paths) {
                    const r = asActor(`DELETE FROM storage.objects WHERE bucket_id = ${lit(bucket)} AND name = ${lit(p)} RETURNING name`)
                    if (r.error) return { data: null, error: { message: r.error.message } }
                    if (r.data) { out.push({ name: p }); try { unlinkSync(join(STORE, bucket, p)) } catch { /* no bytes */ } }
                }
                return { data: out, error: null }
            },
            createSignedUrl: async (path) => {
                const r = asActor(`SELECT count(*)::text FROM storage.objects WHERE bucket_id = ${lit(bucket)} AND name = ${lit(path)}`)
                if (r.error || r.data !== '1') return { data: null, error: { message: r.error?.message ?? 'Object not found' } }
                return { data: { signedUrl: `local://${bucket}/${path}` }, error: null }
            },
        }),
    },
    auth: { getSession: async () => ({ data: { session: null } }), getUser: async () => ({ data: { user: actor ? { id: actor.claims.sub } : null } }) },
})
globalThis.__PORTAL_SESSION__ = () => !!actor?.portal

async function main() {
    // ── a throwaway local cluster, rebuilt the way db/gate.py builds it ──
    mkdirSync(SOCK); mkdirSync(STORE)
    if (sh('initdb', ['-D', DATA, '-U', 'postgres', '--no-locale', '--encoding=UTF8']).status !== 0) throw new Error('MES9C_LOCAL_DRIVER|initdb')
    if (sh('pg_ctl', ['-D', DATA, '-o', `-p ${PORT} -k ${SOCK} -c listen_addresses=''`, '-l', join(W, 'pg.log'), 'start', '-w']).status !== 0) throw new Error('MES9C_LOCAL_DRIVER|pg_ctl')
    sh('createdb', ['-h', SOCK, '-p', PORT, '-U', 'postgres', 'up'])
    const vr = sh('python3', [join(ROOT, 'db/verify_rebuild.py'), '--target', DSN, '--skip-diff'])
    if (vr.status !== 0) throw new Error(`MES9C_LOCAL_DRIVER|rebuild exit ${vr.status}: ${(vr.stdout || '').slice(-400)}`)
    const st = sh('psql', [DSN, '-X', '-q', '-v', 'ON_ERROR_STOP=1', '-f', join(ROOT, 'db/storage/platform-storage-stub.sql'), '-f', join(ROOT, 'db/storage/buckets-and-policies.sql')])
    if (st.status !== 0) throw new Error(`MES9C_LOCAL_DRIVER|storage: ${st.stderr.slice(0, 300)}`)
    console.log('· a fresh local rebuild (db/verify_rebuild.py --skip-diff) + storage stub + db/storage/buckets-and-policies.sql')

    // ── data of its own ──
    const U = {}
    let seed = ''
    for (const k of ['A', 'B']) {
        const u = { k, sup: randomUUID(), contact: randomUUID(), user: randomUUID(), sid: randomUUID() }
        seed += `
INSERT INTO suppliers (id, code, legal_name, country, status, counterparty_type) VALUES (${lit(u.sup)}, 'LOCAL9C-S${k}', 'local supplier ${k}', 'SG', 'active', 'goods_supplier');
INSERT INTO counterparty_contacts (id, supplier_id, name, email) VALUES (${lit(u.contact)}, ${lit(u.sup)}, 'local ${k}', '${k.toLowerCase()}@local9c.test');
INSERT INTO auth.users (id, email, email_confirmed_at) VALUES (${lit(u.user)}, '${k.toLowerCase()}@local9c.test', now());
INSERT INTO auth.sessions (id, user_id) VALUES (${lit(u.sid)}, ${lit(u.user)});
INSERT INTO supplier_portal_users (user_id, supplier_id, contact_id) VALUES (${lit(u.user)}, ${lit(u.sup)}, ${lit(u.contact)});`
        u.claims = { sub: u.user, role: 'supplier_portal', session_id: u.sid }
        U[k] = u
    }
    const staff = {}
    for (const [k, codes] of [['edit', ['module.suppliers.view', 'module.suppliers.edit']], ['view', ['module.suppliers.view']]]) {
        const id = randomUUID(), role = randomUUID()
        seed += `
INSERT INTO auth.users (id, email, email_confirmed_at) VALUES (${lit(id)}, 'staff-${k}@local9c.test', now());
INSERT INTO roles (id, code, name_en, name_zh, is_active) VALUES (${lit(role)}, 'local9c-${k}', 'local ${k}', 'local ${k}', true);
INSERT INTO role_permissions (role_id, permission_code) SELECT ${lit(role)}, c FROM unnest(ARRAY[${codes.map(lit).join(', ')}]) c;
INSERT INTO user_roles (user_id, role_id) VALUES (${lit(id)}, ${lit(role)});`
        staff[k] = { claims: { sub: id, role: 'authenticated' }, portal: false }
    }
    psql(seed)
    console.log('· seeded: suppliers A and B, a portal account each with a live session, a staff editor (module.suppliers.edit) and a staff viewer (view only)')

    // ── the route and the review actions, unchanged ──
    const { createJiti } = await import('jiti')
    const stubDir = join(W, 'stubs'); mkdirSync(stubDir)
    writeFileSync(join(stubDir, 'next-cache.mjs'), 'export function revalidatePath() {}\nexport function revalidateTag() {}\n')
    writeFileSync(join(stubDir, 'permissions.mjs'), `import { createClient } from '${join(ROOT, 'db/scripts/lib/txn-supabase-server.mjs')}'
export async function getMyPermissions() { const s = await createClient(); const { data, error } = await s.rpc('current_user_permissions'); if (error) throw new Error(error.message); return data ?? [] }
export async function can(code) { return (await getMyPermissions()).includes(code) }\n`)
    const jiti = createJiti(import.meta.url, {
        interopDefault: true,
        alias: {
            '@/lib/supabase/server': join(ROOT, 'db/scripts/lib/txn-supabase-server.mjs'),
            '@/lib/portalSession': join(ROOT, 'db/scripts/lib/portal-session-stub.mjs'),
            '@/lib/i18n/server': join(ROOT, 'scripts/pdf-routes/i18n-server.mjs'),
            '@/lib/permissions': join(stubDir, 'permissions.mjs'),
            'next/cache': join(stubDir, 'next-cache.mjs'),
            'server-only': join(ROOT, 'scripts/pdf-routes/empty.mjs'),
            '@': ROOT,
        },
    })
    const route = await jiti.import(join(ROOT, 'app/portal/certificates/upload/route.ts'))
    const actions = await jiti.import(join(ROOT, 'app/suppliers/[id]/edit/portalSubmissionActions.ts'))
    const post = async (who, { certType = 'nea_import', certNo = 'LOCAL-1', validUntil = '2027-12-31', name, type, bytes, contentLength }) => {
        actor = who
        try {
            const fd = new FormData()
            fd.set('cert_type', certType); fd.set('cert_no', certNo); fd.set('valid_until', validUntil)
            fd.set('file', new Blob([bytes], { type }), name)
            let req = new Request('http://local/portal/certificates/upload', { method: 'POST', body: fd })
            if (contentLength) {   // the browser's real Content-Length for an oversized body, without building a second buffer
                const h = new Headers(req.headers); h.set('content-length', String(contentLength))
                req = new Request('http://local/portal/certificates/upload', { method: 'POST', headers: h, body: await req.arrayBuffer(), duplex: 'half' })
            }
            const res = await route.POST(req)
            return { status: res.status, location: res.headers.get('location') || '', text: res.status === 403 ? await res.text() : '' }
        } finally { actor = null }
    }
    const allSubs = () => Number(psql('SELECT count(*) FROM portal_certificate_submissions'))
    const objs = (b) => Number(psql(`SELECT count(*) FROM storage.objects WHERE bucket_id = ${lit(b)}`))
    const A = U.A, B = U.B
    const pa = { claims: A.claims, portal: true }, pb = { claims: B.claims, portal: true }
    const pdf = Buffer.from('%PDF-1.4\n% a certificate\n%%EOF\n')
    const png = Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), Buffer.from('local png body')])
    const gif = Buffer.from('GIF89a\x01\x00\x01\x00\x00\x00\x00;', 'binary')

    // ── HTTP upload: refused before any byte ──
    let r = await post(pa, { name: 'big.pdf', type: 'application/pdf', bytes: Buffer.concat([pdf, Buffer.alloc(10485760)]) })
    ok(r.status === 303 && r.location.includes('error=PORTAL_UPLOAD_TOO_LARGE') && r.location.includes('p=10485760') && allSubs() === 0 && objs('portal-uploads') === 0,
       `local HTTP oversize (10 MB + ${pdf.length} bytes): ${r.status} → ${r.location.replace('http://local', '')}; submissions ${allSubs()}, portal-uploads objects ${objs('portal-uploads')}`)
    r = await post(pa, { name: 'scan.gif', type: 'image/gif', bytes: gif })
    ok(r.status === 303 && r.location.includes('error=PORTAL_UPLOAD_TYPE_NOT_ACCEPTED') && allSubs() === 0 && objs('portal-uploads') === 0,
       `local HTTP wrong type (GIF): ${r.status} → ${r.location.replace('http://local', '')}; submissions ${allSubs()}, portal-uploads objects ${objs('portal-uploads')}`)
    r = await post(pa, { name: 'disguised.pdf', type: 'application/pdf', bytes: gif })
    ok(r.status === 303 && r.location.includes('error=PORTAL_UPLOAD_TYPE_NOT_ACCEPTED') && allSubs() === 0 && objs('portal-uploads') === 0,
       `local HTTP a GIF named .pdf and sent as application/pdf: judged by its first bytes → ${r.location.replace('http://local', '')}; nothing stored`)
    r = await post(staff.edit, { name: 'a.pdf', type: 'application/pdf', bytes: pdf })
    ok(r.status === 403 && allSubs() === 0, `local HTTP a staff session posting the upload route: ${r.status} "${r.text.slice(0, 60)}"`)

    // ── HTTP upload: a valid file ──
    r = await post(pa, { name: 'permit.pdf', type: 'application/pdf', bytes: pdf, certNo: 'LOCAL-PERMIT-1' })
    const s1 = psql(`SELECT id || '|' || status || '|' || storage_path || '|' || file_size || '|' || file_type FROM portal_certificate_submissions WHERE supplier_id = ${lit(A.sup)} AND cert_no = 'LOCAL-PERMIT-1'`).split('|')
    ok(r.status === 303 && r.location.endsWith('/portal/certificates?submitted=1') && s1[1] === 'submitted' && s1[3] === String(pdf.length) && s1[4] === 'application/pdf'
       && existsSync(join(STORE, 'portal-uploads', s1[2])) && sha(readFileSync(join(STORE, 'portal-uploads', s1[2]))) === sha(pdf) && objs('portal-uploads') === 1,
       `local HTTP valid PDF: ${r.status} → ${r.location.replace('http://local', '')}; one submission waiting for review (${s1[3]} bytes, ${s1[4]}), its bytes in portal-uploads at ${s1[2]?.slice(0, 20)}…`)
    ok(Number(psql('SELECT count(*) FROM supplier_compliance')) === 0 && Number(psql('SELECT count(*) FROM supplier_attachments')) === 0,
       'local: the upload created no certificate and no attachment (it is a submission waiting for review)')
    r = await post(pa, { name: 'scan.png', type: 'image/png', bytes: png, certType: 'basel', certNo: 'LOCAL-BASEL-1' })
    const s2 = psql(`SELECT id FROM portal_certificate_submissions WHERE supplier_id = ${lit(A.sup)} AND cert_no = 'LOCAL-BASEL-1' AND status = 'submitted'`)
    ok(r.status === 303 && r.location.endsWith('?submitted=1') && !!s2, `local HTTP valid PNG: ${r.status} → waiting for review`)

    // ── review: the staff viewer cannot; the editor accepts and rejects ──
    actor = staff.view
    let a = await actions.acceptPortalSubmission({ supplierId: A.sup, submissionId: s1[0], certNo: '', issuingBody: 'NEA', validFrom: '', validUntil: '' })
    actor = null
    ok(!!a.error && Number(psql('SELECT count(*) FROM supplier_compliance')) === 0 && objs('supplier-attachments') === 0,
       `local review: a viewer (module.suppliers.view only) accepting → refused ("${(a.error ?? '').slice(0, 60)}"), nothing copied`)
    actor = staff.edit
    a = await actions.acceptPortalSubmission({ supplierId: A.sup, submissionId: s1[0], certNo: 'LOCAL-PERMIT-1-CHECKED', issuingBody: 'NEA', validFrom: '2026-01-01', validUntil: '' })
    actor = null
    const acc = psql(`SELECT s.status || '|' || c.cert_type_code || '|' || c.cert_no || '|' || COALESCE(c.valid_until::text, '-') || '|' || a.storage_path || '|' || c.issuing_body
                       FROM portal_certificate_submissions s JOIN supplier_compliance c ON c.id = s.compliance_id JOIN supplier_attachments a ON a.id = s.attachment_id AND a.id = c.document_id
                      WHERE s.id = ${lit(s1[0])}`).split('|')
    ok(a.success === true && acc[0] === 'accepted' && acc[1] === 'nea_import' && acc[2] === 'LOCAL-PERMIT-1-CHECKED' && acc[3] === '2027-12-31' && acc[5] === 'NEA'
       && acc[4]?.startsWith(A.sup + '/') && existsSync(join(STORE, 'supplier-attachments', acc[4])) && sha(readFileSync(join(STORE, 'supplier-attachments', acc[4]))) === sha(pdf),
       `local review: the editor accepts → certificate nea_import ${acc[2]} valid until ${acc[3]}, the file copied into supplier-attachments (${acc[4]?.slice(37, 70)}…, same bytes) and attached`)
    actor = staff.edit
    let j = await actions.rejectPortalSubmission({ supplierId: A.sup, submissionId: s2, reason: '   ' })
    ok(!!j.error && /reason/i.test(j.error), `local review: rejecting without a reason → refused ("${(j.error ?? '').slice(0, 60)}")`)
    j = await actions.rejectPortalSubmission({ supplierId: A.sup, submissionId: s2, reason: 'The scan is unreadable — send a clearer copy' })
    const u = await actions.getSubmissionFileUrl({ submissionId: s2 })
    actor = staff.view
    const uv = await actions.getSubmissionFileUrl({ submissionId: s2 })
    actor = null
    ok(j.success === true && psql(`SELECT status || '|' || reject_reason FROM portal_certificate_submissions WHERE id = ${lit(s2)}`) === 'rejected|The scan is unreadable — send a clearer copy',
       'local review: the editor rejects with a reason')
    ok(!!u.url && !!uv.url, 'local review: the editor and the viewer can both open the submitted file (portal-uploads read policy, module.suppliers.view)')

    // ── the supplier sees the status and the reason; B sees nothing of it ──
    actor = pa
    const ca = await (globalThis.__TXN_CLIENT__()).rpc('portal_certificates')
    actor = pb
    const cb = await (globalThis.__TXN_CLIENT__()).rpc('portal_certificates')
    actor = null
    const states = (ca.data?.submissions ?? []).map((x) => `${x.cert_no}:${x.state}:${x.reject_reason ?? '-'}`).sort().join(', ')
    ok(states === 'LOCAL-BASEL-1:rejected:The scan is unreadable — send a clearer copy, LOCAL-PERMIT-1:accepted:-'
       && (ca.data?.compliance ?? []).some((x) => x.cert_no === 'LOCAL-PERMIT-1-CHECKED'),
       `local supplier view (portal_certificates, what /portal/certificates renders): ${states}; the accepted certificate on file`)
    ok(cb.data?.submissions?.length === 0 && cb.data?.compliance?.length === 0 && !JSON.stringify(cb.data).includes('LOCAL-'), 'local: B sees none of A\'s submissions or certificates')
    console.log(bad ? `STEP|done with ${bad} FAIL` : 'STEP|done')
    finish(bad ? 1 : 0)
}

main().catch((e) => { console.error(String(e?.stack || e)); finish(String(e?.message || '').startsWith('MES9C_LOCAL_DRIVER') ? 2 : 1) })
