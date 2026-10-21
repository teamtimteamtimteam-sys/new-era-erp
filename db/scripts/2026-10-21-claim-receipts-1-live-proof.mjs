#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// CLAIM-RECEIPTS-1(2026-10-21)· 线上验证,以一次性账号(前缀 cr1probe,scripts/ephemeral.mjs 的共用造号器)
// ════════════════════════════════════════════════════════════════════════════
// PROOF_BASE 上是一台【跑本刀代码、连线上】的 next。七个真账号一个都不用。
// ★ 委托书:线上【不提交】任何单据 —— 会写东西的证明一律在一笔 ROLLBACK 的事务里(触发器全开、没有任何旁路);线上提交的只有一次性账号本身
//   (与它们的授权、员工档案),由清理计划收走。本支【不上传任何字节】:Storage API 那几次写都是对着没登记的路径、必然被拒的;
//   claim-receipts 里的对象数前后各数一次(postgres),必须都是 0。真的从手机传一份收据,是 Tim 自己的那一项手走(docs/manual-walk-list.md §34)。
//   【HTTP 腿】
//     H1  员工(一次性,带员工档案,只持一个与报销无关的码 module.tasks.view)打开 /me —— 200,报销那一块画出来
//     H2  finance 克隆打开 /finance/claims —— 200;在途的 CLM-2026-0004 那一笔说「No receipt」;已决的登记簿多一列「Receipts」
//     H3  finance 克隆打开 EXP-2026-0007(出自 CLM-2026-0002)—— 「Receipts from claim CLM-2026-0002」那一块在
//     H4  PostgREST:员工调 claim_receipt_limits → 10485760 · PDF / JPEG / PNG(与门户同一个数,Q1)
//     H5  Storage API:员工与 finance 克隆各往 claim-receipts 的一条【没登记的】路径写 → 被拒;对象数 0 → 0
//   【事务腿,不提交;以真的会话 claims(SET LOCAL ROLE authenticated)】
//     T1  员工提一张两笔的单(本位币、同月,不写理由)→ 回每一笔的 id(Q12)
//     T2  begin:HEIC / Word / 10 MB + 1 → 按名拒;另一名员工 → NOT_YOURS;员工本人 → 登记一行
//     T3  平台自己的上传预检 storage.can_insert_object:员工登记的路径放行(PT200),别的路径 / 另一名员工 42501
//     T4  对象行经线上策略插入;finish → attached;财务克隆读得到对象,另一名员工读不到
//     T5  一级审批人(真 finance 角色)逐笔批:第 2 笔没有收据也没有理由 → EXPENSE_CLAIM_NO_EVIDENCE|单号|2;第 2 笔附上之后 → 批得过,一张费用单两行
//     T6  批准之后:拿掉 → CLAIM_NOT_SUBMITTED;begin → CLAIM_NOT_SUBMITTED;员工照样读得到自己的那一份(Q6)
//   ROLLBACK 之后读回:收据 0 行、claim-receipts 对象 0、这一次造的单据一行不剩。
// 判决只从日志里最后那一行 `CR1_PROOF_EXIT=` 读:0 = 每一格 PASS 且收尾干净 · 1 = 有 FAIL · 2 = 驱动坏了 · 5 = live-lock 被占 · 6 = 收尾没完成。
// 用法:PROOF_BASE=http://localhost:3197 node db/scripts/2026-10-21-claim-receipts-1-live-proof.mjs > <log> 2>&1
// ════════════════════════════════════════════════════════════════════════════
import { onlyWhenRunDirectly } from '../../scripts/lib/entrypoint.mjs'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawnSync } from 'node:child_process'
import { randomUUID } from 'node:crypto'
import { acquireOrExit, release, heldBy } from '../../scripts/liveLock.mjs'
import { openPlan, mintThrowaway, reapStalePlans, installExitHooks, exitAfterCleanup } from '../../scripts/ephemeral.mjs'

onlyWhenRunDirectly(import.meta.url)

const ROOT = dirname(dirname(dirname(fileURLToPath(import.meta.url))))
const BASE = process.env.PROOF_BASE || 'http://localhost:3197'
const DSN = process.env.CHECK_MIRRORS_DSN || 'host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 user=postgres.wvywpohbwkiinmipmuku dbname=postgres'

let locked = false, bad = 0
const ok = (cond, what) => { console.log(`${cond ? 'PASS' : 'FAIL'}|${what}`); if (!cond) bad++; return cond }
const lit = (s) => `'${String(s).replace(/'/g, "''")}'`
function psql(sql) {
    const r = spawnSync('psql', [DSN, '-X', '-At', '-v', 'ON_ERROR_STOP=1'], { input: sql, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 })
    return { code: r.status, out: (r.stdout || ''), err: (r.stderr || '') }
}
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
const sessionClaims = (c) => JSON.stringify({ sub: claimsOf(c.token).sub, role: 'authenticated' })
async function getWith(cookie, path) {
    const r = await fetch(BASE + path, { headers: { cookie: `${cookie}; NEXT_LOCALE=en` }, redirect: 'manual' })
    return { status: r.status, body: Buffer.from(await r.arrayBuffer()).toString('utf8') }
}
const counts = () => psql(`SELECT (SELECT count(*) FROM expense_claim_receipts) || '|' || (SELECT count(*) FROM storage.objects WHERE bucket_id = 'claim-receipts')
    || '|' || (SELECT count(*) FROM expense_claims) || '|' || (SELECT count(*) FROM expenses) || '|' || (SELECT count(*) FROM storage.objects);`).out.trim()

installExitHooks({
    onFinish: (code) => {
        try { if (locked) release() } catch { /* 放锁失败不改判决 */ }
        console.log('AFTER|nothing but the throwaway accounts, their grants and employee profiles was committed (removed by the plan); no byte was uploaded')
        console.log(`CR1_PROOF_EXIT=${code}`)
    },
})

async function main() {
    const other = heldBy()
    if (other) { console.error(`✗ live-lock 被【${other.holder}】(pid ${other.pid})占着`); return exitAfterCleanup(5) }
    acquireOrExit('db/scripts/2026-10-21-claim-receipts-1-live-proof.mjs', { ownExit: false })
    locked = true
    openPlan('db/scripts/2026-10-21-claim-receipts-1-live-proof.mjs')
    await reapStalePlans()
    E = env()
    try { const r = await fetch(BASE + '/login', { redirect: 'manual' }); if (r.status !== 200) throw new Error(`HTTP ${r.status}`) }
    catch (e) { throw new Error(`CR1_DRIVER|no next server at ${BASE}: ${e.message}`) }
    const c0 = counts()
    console.log(`BEFORE(postgres)|receipt rows|claim-receipts objects|claims|expenses|all stored objects = ${c0}`)

    const stamp = Date.now()
    // 造号器要至少一个码:给一个与报销无关的(module.tasks.view)—— 员工那一侧的判据只认员工档案,不认任何码
    const emp = await mintThrowaway({ prefix: 'cr1probe', label: 'emp', stamp, codes: ['module.tasks.view'],
        employee: { code: `ZZ-PROBE-CR1-E-${stamp}`, legal_name: 'ZZ Probe CR1 claimant', employment_type: 'full_time', work_category: 'office', hire_date: '2026-01-01' } })
    const oth = await mintThrowaway({ prefix: 'cr1probe', label: 'oth', stamp, codes: ['module.tasks.view'],
        employee: { code: `ZZ-PROBE-CR1-O-${stamp}`, legal_name: 'ZZ Probe CR1 other', employment_type: 'full_time', work_category: 'office', hire_date: '2026-01-01' } })
    const fin = await mintThrowaway({ prefix: 'cr1probe', label: 'fin', stamp, codes: { cloneOf: 'finance' } })
    // 一级审批人:审批开着时 require_approver_for(1) 认的是【真 finance 角色】—— 与 EM1 的证明同一个做法,授权由清理计划收走
    const lv1 = await mintThrowaway({ prefix: 'cr1probe', label: 'lv1', stamp, codes: { realRole: 'finance' } })
    console.log(`MINTED|employee ${emp.employeeId ? 'with profile' : 'NO PROFILE'} (${emp.codes.length} codes) · other employee · finance copy ${fin.codes.length} codes · real finance role ${lv1.codes.length} codes`)

    // ── HTTP 腿 ─────────────────────────────────────────────────────────────
    const me = await getWith(emp.cookie, '/me')
    ok(me.status === 200 && me.body.includes('My expense claims'), `H1: /me (throwaway employee, only module.tasks.view) HTTP ${me.status}, the expense-claims block is drawn`)
    const cl = await getWith(fin.cookie, '/finance/claims')
    ok(cl.status === 200 && cl.body.includes('CLM-2026-0004') && cl.body.includes('No receipt') && cl.body.includes('>Receipts<'),
       `H2: /finance/claims (finance copy) HTTP ${cl.status}: CLM-2026-0004's item says "No receipt"; the decided register has a "Receipts" column`)
    const e7 = psql(`SELECT id FROM expenses WHERE code = 'EXP-2026-0007';`).out.trim()
    const d7 = await getWith(fin.cookie, `/finance/expenses/${e7}`)
    ok(d7.status === 200 && d7.body.includes('Receipts from claim CLM-2026-0002'),
       `H3: /finance/expenses/EXP-2026-0007 HTTP ${d7.status}: "Receipts from claim CLM-2026-0002" is on the page (Q8, read in place)`)
    const lim = await asUser(emp.token, '/rest/v1/rpc/claim_receipt_limits', { method: 'POST', body: '{}' })
    ok(lim.status === 200 && lim.body?.set === true && lim.body.max_bytes === 10485760 && JSON.stringify(lim.body.types) === '["application/pdf","image/jpeg","image/png"]',
       `H4: PostgREST claim_receipt_limits as the employee → ${lim.status} ${JSON.stringify(lim.body)}`)
    for (const [who, u] of [['employee', emp], ['finance copy', fin]]) {
        const sp = await fetch(`${E.URL_}/storage/v1/object/claim-receipts/${randomUUID()}/${randomUUID()}/${randomUUID()}.pdf`, {
            method: 'POST', headers: { apikey: E.ANON, Authorization: `Bearer ${u.token}`, 'Content-Type': 'application/pdf' }, body: Buffer.from('%PDF-1.4\n%%EOF\n') })
        ok(!sp.ok, `H5: the Storage API with the ${who}'s token, a claim-receipts path nobody registered → HTTP ${sp.status} (refused)`)
    }
    ok(counts() === c0, `H5: after the refused Storage writes, receipts / objects / claims / expenses unchanged (${counts()})`)

    // ── 事务腿 ────────────────────────────────────────────────────────────
    const r = psql(txSql({ emp: sessionClaims(emp), oth: sessionClaims(oth), fin: sessionClaims(fin), lv1: sessionClaims(lv1),
                           empId: emp.employeeId, empUid: claimsOf(emp.token).sub, othUid: claimsOf(oth.token).sub }))
    for (const line of (r.out + '\n' + r.err).split('\n')) {
        const m = line.match(/NOTICE:\s+(PASS|FAIL)\|(.*)$/)
        if (m) ok(m[1] === 'PASS', m[2])
        else if (/NOTICE:\s+(INFO|TX_DONE)/.test(line)) console.log(line.replace(/^.*NOTICE:\s+/, ''))
    }
    ok(r.code === 0 && /TX_DONE/.test(r.out + r.err), `tx: the transaction leg ran to the end and rolled back (psql exit ${r.code}${r.code ? ' — ' + r.err.slice(-400) : ''})`)
    const c1 = counts()
    ok(c1 === c0, `after ROLLBACK: receipt rows · claim-receipts objects · claims · expenses · all stored objects ${c0} → ${c1}`)

    console.log(bad ? `STEP|done with ${bad} FAIL` : 'STEP|done')
    return exitAfterCleanup(bad ? 1 : 0)
}

function txSql({ emp, oth, fin, lv1, empId, empUid, othUid }) {
    const meta = (n, t) => lit(JSON.stringify({ size: n, mimetype: t }))
    return `BEGIN;
SET LOCAL statement_timeout = '120s';
CREATE FUNCTION pg_temp.cr_call(p_claims text, p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE v text;
BEGIN
    PERFORM set_config('request.jwt.claims', p_claims, true);
    EXECUTE 'SET LOCAL ROLE authenticated';
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
DECLARE v text; j jsonb; ce text := ${lit(emp)}; co text := ${lit(oth)}; cf text := ${lit(fin)}; cl text := ${lit(lv1)};
    v_claim uuid; v_code text; i1 uuid; i2 uuid; r1 uuid; p1 text; r2 uuid; p2 text; d date; v_exp uuid;
    b text := 'SELECT public.claim_receipt_begin(%L::uuid, %L, %L, %s)::text';
BEGIN
    d := (date_trunc('month', CURRENT_DATE))::date;
    -- T1 · 两笔的单,不写理由
    v := pg_temp.cr_call(ce, format($q$SELECT public.submit_expense_claim_items(%L::uuid, (SELECT code FROM currencies WHERE is_base), 'ZZ-PROBE-CR1 claim',
            jsonb_build_array(jsonb_build_object('spend_date', %L::date, 'amount', 21.8, 'description', 'probe taxi'),
                              jsonb_build_object('spend_date', %L::date, 'amount', 10.9, 'description', 'probe parking')))::text$q$, ${lit(empId)}, d, d));
    IF v LIKE 'ERR|%' THEN RAISE NOTICE 'FAIL|T1: submit → %', v; RAISE NOTICE 'TX_DONE'; RETURN; END IF;
    j := v::jsonb; v_claim := (j ->> 'claim_id')::uuid; v_code := j ->> 'code';
    i1 := (SELECT (x ->> 'item_id')::uuid FROM jsonb_array_elements(j -> 'items') x WHERE (x ->> 'line_no')::int = 1);
    i2 := (SELECT (x ->> 'item_id')::uuid FROM jsonb_array_elements(j -> 'items') x WHERE (x ->> 'line_no')::int = 2);
    IF i1 IS NULL OR i2 IS NULL THEN RAISE NOTICE 'FAIL|T1: the submit did not return the items'' ids → %', v;
    ELSE RAISE NOTICE 'PASS|T1: % submitted by the throwaway employee (two items, no reasons) — the reply carries each item''s id (Q12)', v_code; END IF;

    -- T2 · begin 的拒绝与登记
    v := pg_temp.cr_call(ce, format(b, i1, 'IMG_0001.HEIC', 'image/heic', 2000000));
    IF v NOT LIKE 'ERR|%CLAIM_RECEIPT_TYPE_NOT_ACCEPTED|image/heic%' THEN RAISE NOTICE 'FAIL|T2: HEIC → %', v; ELSE RAISE NOTICE 'PASS|T2: a HEIC file refused at begin, by name'; END IF;
    v := pg_temp.cr_call(ce, format(b, i1, 'receipt.docx', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document', 20000));
    IF v NOT LIKE 'ERR|%CLAIM_RECEIPT_TYPE_NOT_ACCEPTED|%' THEN RAISE NOTICE 'FAIL|T2: Word → %', v; ELSE RAISE NOTICE 'PASS|T2: a Word file refused at begin, by name'; END IF;
    v := pg_temp.cr_call(ce, format(b, i1, 'big.pdf', 'application/pdf', 10485761));
    IF v NOT LIKE 'ERR|%CLAIM_RECEIPT_TOO_LARGE|10485760%' THEN RAISE NOTICE 'FAIL|T2: 10 MB + 1 → %', v; ELSE RAISE NOTICE 'PASS|T2: 10 MB + 1 byte refused at begin (the portal''s number, Q1)'; END IF;
    v := pg_temp.cr_call(co, format(b, i1, 'r.pdf', 'application/pdf', 100));
    IF v NOT LIKE 'ERR|%CLAIM_RECEIPT_NOT_YOURS|' || v_code || '%' THEN RAISE NOTICE 'FAIL|T2: another employee → %', v; ELSE RAISE NOTICE 'PASS|T2: another employee cannot begin on this claim (CLAIM_RECEIPT_NOT_YOURS, Q4)'; END IF;
    v := pg_temp.cr_call(ce, format(b, i1, 'taxi.jpg', 'image/jpeg', 480000));
    IF v LIKE 'ERR|%' THEN RAISE NOTICE 'FAIL|T2: the employee''s begin → %', v; RAISE NOTICE 'TX_DONE'; RETURN; END IF;
    r1 := (v::jsonb ->> 'id')::uuid; p1 := v::jsonb ->> 'path';
    IF p1 <> v_claim::text || '/' || i1::text || '/' || r1::text || '.jpg' THEN RAISE NOTICE 'FAIL|T2: path %', p1; ELSE RAISE NOTICE 'PASS|T2: the employee registers one uploading receipt under its claim and item'; END IF;

    -- T3 · 平台自己的上传预检
    v := pg_temp.cr_call(ce, format('SELECT storage.can_insert_object(''claim-receipts'', %L, %L::uuid, ''{}''::jsonb)::text', p1, ${lit(empUid)}));
    IF v NOT LIKE 'ERR|PT200|%' THEN RAISE NOTICE 'FAIL|T3: pre-check on its own path → %', v; ELSE RAISE NOTICE 'PASS|T3: the platform''s upload pre-check (storage.can_insert_object) admits the employee''s registered path (PT200 = admitted, then undone by the platform)'; END IF;
    v := pg_temp.cr_call(ce, format('SELECT storage.can_insert_object(''claim-receipts'', %L, %L::uuid, ''{}''::jsonb)::text', v_claim::text || '/other.pdf', ${lit(empUid)}));
    IF v NOT LIKE 'ERR|42501|%' THEN RAISE NOTICE 'FAIL|T3: pre-check on another path → %', v; ELSE RAISE NOTICE 'PASS|T3: the pre-check refuses a path nothing registered (42501)'; END IF;
    v := pg_temp.cr_call(co, format('SELECT storage.can_insert_object(''claim-receipts'', %L, %L::uuid, ''{}''::jsonb)::text', p1, ${lit(othUid)}));
    IF v NOT LIKE 'ERR|42501|%' THEN RAISE NOTICE 'FAIL|T3: another employee on that path → %', v; ELSE RAISE NOTICE 'PASS|T3: the pre-check refuses another employee on the employee''s registered path (42501)'; END IF;

    -- T4 · 对象行经线上策略;finish;读
    v := pg_temp.cr_call(ce, format('INSERT INTO storage.objects (bucket_id, name, owner, metadata) VALUES (''claim-receipts'', %L, %L::uuid, %L::jsonb) RETURNING name', p1, ${lit(empUid)}, ${meta(480000, 'image/jpeg')}));
    IF v <> p1 THEN RAISE NOTICE 'FAIL|T4: object row → %', v; ELSE RAISE NOTICE 'PASS|T4: the employee stores the bytes'' row through the live upload policy (insert + read back)'; END IF;
    v := pg_temp.cr_call(co, format('SELECT public.claim_receipt_finish(%L::uuid)::text', r1));
    IF v NOT LIKE 'ERR|%CLAIM_RECEIPT_NOT_FOUND%' THEN RAISE NOTICE 'FAIL|T4: another employee finishes → %', v; ELSE RAISE NOTICE 'PASS|T4: another employee cannot finish it'; END IF;
    v := pg_temp.cr_call(ce, format('SELECT public.claim_receipt_finish(%L::uuid)::text', r1));
    IF v LIKE 'ERR|%' THEN RAISE NOTICE 'FAIL|T4: finish → %', v; ELSE RAISE NOTICE 'PASS|T4: finish → attached (size and type match)'; END IF;
    v := pg_temp.cr_call(cf, format('SELECT count(*)::text FROM storage.objects WHERE bucket_id = ''claim-receipts'' AND name = %L', p1));
    IF v <> '1' THEN RAISE NOTICE 'FAIL|T4: finance reads the object → %', v; ELSE RAISE NOTICE 'PASS|T4: the finance copy reads the receipt object (live read policy, Q7)'; END IF;
    v := pg_temp.cr_call(co, format('SELECT count(*)::text FROM storage.objects WHERE bucket_id = ''claim-receipts'' AND name = %L', p1));
    IF v <> '0' THEN RAISE NOTICE 'FAIL|T4: another employee reads it → %', v; ELSE RAISE NOTICE 'PASS|T4: another employee does not see it (0 rows)'; END IF;
    v := pg_temp.cr_call(co, format('SELECT count(*)::text FROM public.expense_claim_receipts WHERE claim_id = %L', v_claim));
    IF v <> '0' THEN RAISE NOTICE 'FAIL|T4: another employee reads the receipt rows → %', v; ELSE RAISE NOTICE 'PASS|T4: another employee reads none of its receipt rows'; END IF;

    -- T5 · 逐笔批
    v := pg_temp.cr_call(cl, format($q$SELECT public.decide_expense_claim_items(%L::uuid, true, '[{"line_no":1,"account_code":"6120","tax_code":"TX"},{"line_no":2,"account_code":"6120","tax_code":"TX"}]'::jsonb, NULL, NULL)::text$q$, v_claim));
    IF v NOT LIKE 'ERR|%EXPENSE_CLAIM_NO_EVIDENCE|' || v_code || '|2%' THEN RAISE NOTICE 'FAIL|T5: item 2 without evidence → %', v; ELSE RAISE NOTICE 'PASS|T5: item 1 has its receipt, item 2 has neither — refused item by item (EXPENSE_CLAIM_NO_EVIDENCE|%|2)', v_code; END IF;
    v := pg_temp.cr_call(ce, format(b, i2, 'parking.pdf', 'application/pdf', 52000));
    r2 := (v::jsonb ->> 'id')::uuid; p2 := v::jsonb ->> 'path';
    PERFORM pg_temp.cr_call(ce, format('INSERT INTO storage.objects (bucket_id, name, owner, metadata) VALUES (''claim-receipts'', %L, %L::uuid, %L::jsonb) RETURNING name', p2, ${lit(empUid)}, ${meta(52000, 'application/pdf')}));
    v := pg_temp.cr_call(ce, format('SELECT public.claim_receipt_finish(%L::uuid)::text', r2));
    IF v LIKE 'ERR|%' THEN RAISE NOTICE 'FAIL|T5: item 2 finish → %', v; END IF;
    v := pg_temp.cr_call(cl, format($q$SELECT public.decide_expense_claim_items(%L::uuid, true, '[{"line_no":1,"account_code":"6120","tax_code":"TX"},{"line_no":2,"account_code":"6120","tax_code":"TX"}]'::jsonb, NULL, NULL)::text$q$, v_claim));
    IF v LIKE 'ERR|%' THEN RAISE NOTICE 'FAIL|T5: approval with both receipts → %', v;
    ELSE
        v_exp := (v::jsonb ->> 'expense_id')::uuid;
        IF (SELECT count(*) FROM expense_lines WHERE expense_id = v_exp) = 2 THEN
            RAISE NOTICE 'PASS|T5: with a receipt on each item a level-1 approver (real finance role) approves → one expense, two lines';
        ELSE RAISE NOTICE 'FAIL|T5: expense lines → %', (SELECT count(*) FROM expense_lines WHERE expense_id = v_exp); END IF;
    END IF;

    -- T6 · 批准之后
    v := pg_temp.cr_call(ce, format('SELECT public.claim_receipt_remove(%L::uuid)::text', r1));
    IF v NOT LIKE 'ERR|%CLAIM_RECEIPT_CLAIM_NOT_SUBMITTED|' || v_code || '|approved%' THEN RAISE NOTICE 'FAIL|T6: remove after approval → %', v; ELSE RAISE NOTICE 'PASS|T6: after approval a receipt cannot be removed (Q6)'; END IF;
    v := pg_temp.cr_call(ce, format(b, i1, 'late.pdf', 'application/pdf', 100));
    IF v NOT LIKE 'ERR|%CLAIM_RECEIPT_CLAIM_NOT_SUBMITTED|%' THEN RAISE NOTICE 'FAIL|T6: begin after approval → %', v; ELSE RAISE NOTICE 'PASS|T6: after approval nothing more can be attached'; END IF;
    v := pg_temp.cr_call(ce, format('SELECT count(*)::text FROM storage.objects WHERE bucket_id = ''claim-receipts'' AND name IN (%L, %L)', p1, p2));
    IF v <> '2' THEN RAISE NOTICE 'FAIL|T6: the employee reads its receipts after approval → %', v; ELSE RAISE NOTICE 'PASS|T6: the employee still reads both of its receipts after approval (Q6)'; END IF;
    RAISE NOTICE 'TX_DONE';
END
$tx$;
ROLLBACK;
`
}

main().catch((e) => {
    console.error(String(e?.stack || e))
    return exitAfterCleanup(String(e?.message || '').startsWith('CR1_DRIVER') ? 2 : 1)
})
