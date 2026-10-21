#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// CLAIM-RECEIPTS-1(2026-10-21)· 收据上传的证明,在一个【本地重建库】上、用自带的数据(委托书:线上不提交任何一张报销单)
// ════════════════════════════════════════════════════════════════════════════
// MES-9c 本地证明(db/scripts/2026-10-20-mes9c-local-upload-proof.mjs)的形状:自己起一个一次性的本地集群(db/verify_rebuild.py --skip-diff,
//   再装 storage 桩与 db/storage/buckets-and-policies.sql —— 与 db/gate.py 一样的建法),装一名员工(有员工档案、不持任何码)、另一名员工、
//   一个只持 module.finance.view 的读者、一个全权限的财务(决定的人)。然后把【原样的】这几样经 jiti 装进来:
//     app/finance/claims/actions.ts(submitClaim · decideClaim)· app/me/claimReceiptActions.ts(begin · finish · abandon · remove · link)·
//     app/me/uploadClaimReceipt.ts 的 uploadReceipt(浏览器那一半:begin → 直传 → finish)。
//   '@/lib/supabase/server' 与 '@/lib/supabase/client' 都换成一个连这个本地库的客户端:
//   · .rpc / .from(...).select().eq().maybeSingle() = 以当前身份(SET ROLE authenticated + 它的 JWT 声明)跑;
//   · .storage.from(b).upload(p, bytes) = 以【同一身份】往 storage.objects 插那一行(真的 RLS、真的 claim-receipts 策略),插得进才把字节写进本地目录;
//   · .createSignedUrl = 以同一身份读得到那一行(真的读策略)才给一个 data: 链接,内容就是本地目录里那份字节 —— 于是 finish 里那一步
//     "按文件头认类型"读的是【真的传上去的那份字节】。'next/cache' 换成空操作。
//   ☞ 文案:本地的 '@/lib/i18n/server' 是 scripts/pdf-routes 那个替身,它回【键 + 参数】,不回句子 —— 所以这里断言的是【拒绝落到哪一个消息键】;
//     句子本身两种语言都在(check-i18n 逐键查)。
//   ☞ 浏览器那一半里【缩图】那一步(prepareReceipt:canvas / createImageBitmap)在 Node 里没有,不在这里证 —— 它是 Tim 的 iPhone 手走(§34)。
// 证:提交两笔(回每一笔的 id)· 一份 PDF 传上去 → attached、字节在本地桶里 · 一份伪装成 JPEG 的 GIF → 按文件头拒、那一行 abandoned、字节留着(Q5)·
//   另一名员工给这张单传 → 拒(说成人话)· 一份 PNG → attached · 员工拿掉一份 → 它自己读不到那一份的链接、财务读得到 ·
//   批准:第 1 笔的收据被拿掉了、又没有理由 → 逐笔拒(第 1 笔)· 再附上 → 批得过 · 批准之后再传 → 拒 · 员工批准之后照样打得开、字节逐字相同。
// 判决只从最后一行 `CR1_LOCAL_PROOF_EXIT=` 读:0 = 每一格 PASS · 1 = 有 FAIL · 2 = 驱动坏了。不碰线上。
// 用法:node db/scripts/2026-10-21-claim-receipts-1-local-upload-proof.mjs > <log> 2>&1
// ════════════════════════════════════════════════════════════════════════════
import { onlyWhenRunDirectly } from '../../scripts/lib/entrypoint.mjs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawnSync } from 'node:child_process'
import { createHash, randomUUID } from 'node:crypto'
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, existsSync } from 'node:fs'

onlyWhenRunDirectly(import.meta.url)

const ROOT = dirname(dirname(dirname(fileURLToPath(import.meta.url))))
const W = mkdtempSync('/tmp/cr1up.')
const SOCK = join(W, 's'), PORT = '55446', DATA = join(W, 'pg'), STORE = join(W, 'store')
const DSN = `host=${SOCK} port=${PORT} user=postgres dbname=up`
let bad = 0
const ok = (c, what) => { console.log(`${c ? 'PASS' : 'FAIL'}|${what}`); if (!c) bad++; return c }
const sha = (b) => createHash('sha256').update(b).digest('hex')
const lit = (s) => `'${String(s).replace(/'/g, "''")}'`
function sh(cmd, args, input) { return spawnSync(cmd, args, { input, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 }) }
function psql(sql) {
    const r = sh('psql', [DSN, '-X', '-At', '-v', 'ON_ERROR_STOP=1'], sql)
    if (r.status !== 0) throw new Error(`CR1_LOCAL_DRIVER|psql: ${(r.stderr || '').slice(0, 400)}`)
    return r.stdout.trim()
}
function finish(code) {
    sh('pg_ctl', ['-D', DATA, 'stop', '-m', 'immediate'])
    try { rmSync(W, { recursive: true, force: true }) } catch { /* scratch */ }
    console.log(`CR1_LOCAL_PROOF_EXIT=${code}`)
    process.exit(code)
}

// ── who the code runs as ──
let actor = null                 // { claims } or null
function asActor(sql) {
    const r = sh('psql', [DSN, '-X', '-q', '-At', '-v', 'ON_ERROR_STOP=1'],
        `BEGIN;\nSET LOCAL "request.jwt.claims" = ${lit(JSON.stringify(actor?.claims ?? {}))};\nSET LOCAL ROLE authenticated;\n${sql};\nCOMMIT;\n`)
    if (r.status !== 0) {
        const m = (r.stderr || '').split('\n').find((l) => l.startsWith('ERROR:')) || r.stderr
        return { error: { message: m.replace(/^ERROR:\s*/, '').trim(), code: /permission denied|row-level security/.test(m) ? '42501' : 'P0001' } }
    }
    const v = r.stdout.replace(/\n$/, '')
    return { data: v === '' ? null : v }
}
const sqlVal = (v) => v === null || v === undefined ? 'NULL' : typeof v === 'number' ? String(v)
    : typeof v === 'object' ? `${lit(JSON.stringify(v))}::jsonb` : lit(v)
globalThis.__TXN_CLIENT__ = () => ({
    rpc: async (name, args = {}) => {
        const a = Object.entries(args).filter(([, v]) => v !== undefined).map(([k, v]) => `${k} => ${sqlVal(v)}`).join(', ')
        const r = asActor(`SELECT to_jsonb(public.${name}(${a}))::text`)
        if (r.error && process.env.LOCAL_DEBUG) console.log(`DEBUG|rpc ${name} → ${r.error.message}`)
        if (r.error) return { data: null, error: r.error }
        return { data: r.data === null ? null : JSON.parse(r.data), error: null }
    },
    from: (table) => {
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
            upload: async (path, body, opts = {}) => {
                const bytes = Buffer.from(body instanceof Blob ? await body.arrayBuffer() : body)
                const meta = JSON.stringify({ size: bytes.length, mimetype: opts.contentType ?? 'application/octet-stream' })
                const r = asActor(`INSERT INTO storage.objects (bucket_id, name, owner, metadata) VALUES (${lit(bucket)}, ${lit(path)}, (current_setting('request.jwt.claims')::jsonb ->> 'sub')::uuid, ${lit(meta)}::jsonb) RETURNING name`)
                if (r.error) return { data: null, error: { message: r.error.message } }
                mkdirSync(dirname(join(STORE, bucket, path)), { recursive: true })
                writeFileSync(join(STORE, bucket, path), bytes)
                return { data: { path }, error: null }
            },
            createSignedUrl: async (path) => {
                const r = asActor(`SELECT count(*)::text FROM storage.objects WHERE bucket_id = ${lit(bucket)} AND name = ${lit(path)}`)
                if (r.error || r.data !== '1') return { data: null, error: { message: r.error?.message ?? 'Object not found' } }
                const f = join(STORE, bucket, path)
                if (!existsSync(f)) return { data: null, error: { message: 'Object not found' } }
                return { data: { signedUrl: `data:application/octet-stream;base64,${readFileSync(f).toString('base64')}` }, error: null }
            },
        }),
    },
    auth: { getSession: async () => ({ data: { session: null } }), getUser: async () => ({ data: { user: actor ? { id: actor.claims.sub } : null } }) },
})

async function main() {
    mkdirSync(SOCK); mkdirSync(STORE)
    if (sh('initdb', ['-D', DATA, '-U', 'postgres', '--no-locale', '--encoding=UTF8']).status !== 0) throw new Error('CR1_LOCAL_DRIVER|initdb')
    if (sh('pg_ctl', ['-D', DATA, '-o', `-p ${PORT} -k ${SOCK} -c listen_addresses=''`, '-l', join(W, 'pg.log'), 'start', '-w']).status !== 0) throw new Error('CR1_LOCAL_DRIVER|pg_ctl')
    sh('createdb', ['-h', SOCK, '-p', PORT, '-U', 'postgres', 'up'])
    const vr = sh('python3', [join(ROOT, 'db/verify_rebuild.py'), '--target', DSN, '--skip-diff'])
    if (vr.status !== 0) throw new Error(`CR1_LOCAL_DRIVER|rebuild exit ${vr.status}: ${(vr.stdout || '').slice(-400)}`)
    const st = sh('psql', [DSN, '-X', '-q', '-v', 'ON_ERROR_STOP=1', '-f', join(ROOT, 'db/storage/platform-storage-stub.sql'), '-f', join(ROOT, 'db/storage/buckets-and-policies.sql')])
    if (st.status !== 0) throw new Error(`CR1_LOCAL_DRIVER|storage: ${st.stderr.slice(0, 300)}`)
    console.log('· a fresh local rebuild (db/verify_rebuild.py --skip-diff) + storage stub + db/storage/buckets-and-policies.sql')

    // ── data of its own ──
    const emp = randomUUID(), oth = randomUUID(), view = randomUUID(), fin = randomUUID(), rAll = randomUUID(), rView = randomUUID()
    const eEmp = randomUUID(), eOth = randomUUID()
    psql(`
INSERT INTO auth.users (id, email, email_confirmed_at) VALUES (${lit(emp)}, 'emp@localcr1.test', now()), (${lit(oth)}, 'oth@localcr1.test', now()),
    (${lit(view)}, 'view@localcr1.test', now()), (${lit(fin)}, 'fin@localcr1.test', now());
INSERT INTO roles (id, code, name_en, name_zh, is_active) VALUES (${lit(rAll)}, 'localcr1-all', 'all', 'all', true), (${lit(rView)}, 'localcr1-view', 'view', 'view', true);
INSERT INTO role_permissions (role_id, permission_code) SELECT ${lit(rAll)}, code FROM permissions;
INSERT INTO role_permissions (role_id, permission_code) VALUES (${lit(rView)}, 'module.finance.view');
INSERT INTO user_roles (user_id, role_id) VALUES (${lit(fin)}, ${lit(rAll)}), (${lit(view)}, ${lit(rView)});
INSERT INTO employees (id, code, legal_name, employment_type, work_category, hire_date, user_id) VALUES
    (${lit(eEmp)}, 'LOCALCR1-E', 'local claimant', 'full_time', 'office', CURRENT_DATE - 400, ${lit(emp)}),
    (${lit(eOth)}, 'LOCALCR1-O', 'local other', 'full_time', 'office', CURRENT_DATE - 400, ${lit(oth)});
UPDATE finance_settings SET locked_before = NULL, gst_registered = true, approvals_enabled = false, gst_registration_no = COALESCE(gst_registration_no, 'ZZ-LOCALCR1');`)
    console.log('· seeded: a claimant (employee profile, no codes), another employee, a module.finance.view reader, a full-permission finance decider')
    const E = { claims: { sub: emp, role: 'authenticated' } }, O = { claims: { sub: oth, role: 'authenticated' } }
    const V = { claims: { sub: view, role: 'authenticated' } }, F = { claims: { sub: fin, role: 'authenticated' } }

    // ── the unchanged app code ──
    const { createJiti } = await import('jiti')
    const stubDir = join(W, 'stubs'); mkdirSync(stubDir)
    writeFileSync(join(stubDir, 'next-cache.mjs'), 'export function revalidatePath() {}\nexport function revalidateTag() {}\n')
    writeFileSync(join(stubDir, 'supabase-client.mjs'), `export function createClient() { return globalThis.__TXN_CLIENT__() }\n`)
    const jiti = createJiti(import.meta.url, {
        interopDefault: true,
        alias: {
            '@/lib/supabase/server': join(ROOT, 'db/scripts/lib/txn-supabase-server.mjs'),
            '@/lib/supabase/client': join(stubDir, 'supabase-client.mjs'),
            '@/lib/i18n/server': join(ROOT, 'scripts/pdf-routes/i18n-server.mjs'),
            'next/cache': join(stubDir, 'next-cache.mjs'),
            'server-only': join(ROOT, 'scripts/pdf-routes/empty.mjs'),
            '@': ROOT,
        },
    })
    const claims = await jiti.import(join(ROOT, 'app/finance/claims/actions.ts'))
    const rcpt = await jiti.import(join(ROOT, 'app/me/claimReceiptActions.ts'))
    const up = await jiti.import(join(ROOT, 'app/me/uploadClaimReceipt.ts'))
    const as = async (who, fn) => { actor = who; try { return await fn() } finally { actor = null } }
    const pdf = Buffer.from('%PDF-1.4\n% a receipt\n%%EOF\n')
    const png = Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), Buffer.from('local png body')])
    const gif = Buffer.from('GIF89a\x01\x00\x01\x00\x00\x00\x00;', 'binary')
    const blob = (b, type) => new Blob([b], { type })
    const base = psql('SELECT code FROM currencies WHERE is_base')
    const d = psql(`SELECT (date_trunc('month', CURRENT_DATE - 40)::date + 2)::text`)
    const objs = () => Number(psql(`SELECT count(*) FROM storage.objects WHERE bucket_id = 'claim-receipts'`))
    const row = (id) => psql(`SELECT status || '|' || storage_path || '|' || file_type FROM expense_claim_receipts WHERE id = ${lit(id)}`).split('|')
    const latest = (item) => psql(`SELECT id FROM expense_claim_receipts WHERE item_id = ${lit(item)} ORDER BY created_at DESC, id LIMIT 1`)

    // L1 · 提交两笔,不写理由
    const s = await as(E, () => claims.submitClaim({ employeeId: eEmp, currency: base, purpose: 'local trip',
        items: [{ spendDate: d, amount: '21.80', description: 'taxi' }, { spendDate: d, amount: '10.90', description: 'parking' }] }))
    const i1 = s.items?.find((x) => x.line_no === 1)?.item_id, i2 = s.items?.find((x) => x.line_no === 2)?.item_id
    ok(s.success && s.code && i1 && i2, `L1: submitClaim (unchanged action) as the claimant → ${s.code}, the reply carries both items' ids (Q12)`)

    // L2 · 一份 PDF
    let e = await as(E, () => up.uploadReceipt(i1, { blob: blob(pdf, 'application/pdf'), name: 'taxi.pdf', type: 'application/pdf' }))
    const r1 = latest(i1), x1 = row(r1)
    ok(e === null && x1[0] === 'attached' && sha(readFileSync(join(STORE, 'claim-receipts', x1[1]))) === sha(pdf) && objs() === 1,
       `L2: uploadReceipt (begin → direct upload → finish, unchanged code) a PDF on item 1 → ${e ?? 'no error'}; row ${x1[0]}; its bytes in the local claim-receipts at ${x1[1]?.slice(0, 18)}…`)

    // L3 · 伪装成 JPEG 的 GIF —— 按文件头拒
    e = await as(E, () => up.uploadReceipt(i2, { blob: blob(gif, 'image/jpeg'), name: 'parking.jpg', type: 'image/jpeg' }))
    const x3 = row(latest(i2))
    ok(typeof e === 'string' && /expenseClaims\.errors\.CLAIM_RECEIPT_TYPE_NOT_ACCEPTED/.test(e) && x3[0] === 'abandoned' && objs() === 2,
       `L3: a GIF sent as image/jpeg → refused by its first bytes ("${(e ?? '').slice(0, 70)}…"); the row is abandoned; its bytes stay in the bucket (Q5 · d2 #3): objects ${objs()}`)

    // L4 · 另一名员工
    e = await as(O, () => up.uploadReceipt(i2, { blob: blob(pdf, 'application/pdf'), name: 'x.pdf', type: 'application/pdf' }))
    ok(typeof e === 'string' && /expenseClaims\.errors\.CLAIM_RECEIPT_NOT_YOURS/.test(e) && objs() === 2,
       `L4: another employee attaching to this claim → "${(e ?? '').slice(0, 80)}…"; nothing stored`)

    // L5 · 一份 PNG
    e = await as(E, () => up.uploadReceipt(i2, { blob: blob(png, 'image/png'), name: 'parking.png', type: 'image/png' }))
    const r2 = latest(i2)
    ok(e === null && row(r2)[0] === 'attached', `L5: a PNG on item 2 → attached (${e ?? 'no error'})`)

    // L6 · 拿掉一份;链接
    const rm = await as(E, () => rcpt.removeReceipt(r1))
    const linkE = await as(E, () => rcpt.receiptLink(r1)), linkV = await as(V, () => rcpt.receiptLink(r1)), linkO = await as(O, () => rcpt.receiptLink(r2))
    ok(rm.success && row(r1)[0] === 'removed' && !linkE.url && linkV.url && !linkO.url && existsSync(join(STORE, 'claim-receipts', x1[1])),
       `L6: the claimant removes item 1's PDF → removed (bytes stay); its own link to it now fails, the finance reader's link opens, another employee gets no link to item 2's`)

    // L7 · 批准:第 1 笔没有收据(被拿掉)也没有理由 → 逐笔拒;再附上 → 批得过
    const dec = (items) => as(F, () => claims.decideClaim({ claimId: s.claimId, approve: true, items }))
    const items = [{ lineNo: 1, accountCode: '6120', taxCode: 'TX' }, { lineNo: 2, accountCode: '6120', taxCode: 'TX' }]
    let dr = await dec(items)
    ok(typeof dr.error === 'string' && /expenseClaims\.itemError \{"n":"1"\} expenseClaims\.errors\.EXPENSE_CLAIM_NO_EVIDENCE/.test(dr.error), `L7: approving with item 1's receipt removed and no reason → "${(dr.error ?? '').slice(0, 90)}…"`)
    e = await as(E, () => up.uploadReceipt(i1, { blob: blob(pdf, 'application/pdf'), name: 'taxi-again.pdf', type: 'application/pdf' }))
    dr = await dec(items)
    ok(e === null && dr.success && psql(`SELECT status FROM expense_claims WHERE id = ${lit(s.claimId)}`) === 'approved',
       `L7: item 1 attached again → approved (${dr.error ?? 'ok'})`)

    // L8 · 批准之后
    e = await as(E, () => up.uploadReceipt(i2, { blob: blob(pdf, 'application/pdf'), name: 'late.pdf', type: 'application/pdf' }))
    ok(typeof e === 'string' && /expenseClaims\.errors\.CLAIM_RECEIPT_CLAIM_NOT_SUBMITTED/.test(e), `L8: attaching after approval → "${(e ?? '').slice(0, 80)}…"`)
    const after = await as(E, () => rcpt.receiptLink(r2))
    const bytes = after.url ? Buffer.from(after.url.split(',')[1], 'base64') : Buffer.alloc(0)
    ok(after.url && sha(bytes) === sha(png), 'L8: after approval the claimant still opens item 2\'s receipt, byte for byte the PNG it sent (Q6)')

    finish(bad ? 1 : 0)
}

main().catch((err) => {
    console.error(String(err?.stack || err))
    finish(String(err?.message || '').startsWith('CR1_LOCAL_DRIVER') ? 2 : 1)
})
