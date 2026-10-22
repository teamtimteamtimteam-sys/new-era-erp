#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// PAYROLL-PAY-REVERSAL-1(2026-10-22)· 线上验证,以一次性账号(前缀 ppr1probe,scripts/ephemeral.mjs 的共用造号器)
// ════════════════════════════════════════════════════════════════════════════
// PROOF_BASE 上是一台【跑本刀代码、连线上】的 next。七个真账号一个都不用。
// ★ 委托书:线上【不提交】任何单据 —— 会写东西的证明一律在一笔 ROLLBACK 的事务里(触发器全开、没有任何旁路);线上提交的只有一次性账号本身
//   (与它们的授权、员工档案),由清理计划收走。线上那一期 PAY-2026-0001 的三张付款(JE-2026-0018 / 0019 / 0020)只在事务里被冲,回滚之后原样。
//   【HTTP 腿】
//     H1  finance 克隆打开 /finance/payroll-payments —— 200;「Payments」表画出 JE-2026-0018 / 0019 / 0020,各带「Request reversal」
//     H2  finance 克隆打开 JE-2026-0018 的凭证页 —— 200;冲销钮按不动,说出它在付薪页上冲(Q8)
//     H3  员工(一次性,带员工档案,入职 2026-09-01,只持 module.tasks.view)打开 /me —— 200;「Every leave type」那张表画出(Q12)
//     H4  PostgREST:员工调 leave_balances(自己)→ 12 项,年假在第一位,病假 available = 0(不满 3 个完整月,B1);
//         另一名员工调它 → PERMISSION_DENIED|module.hr.view
//   【事务腿,不提交;以真的会话 claims(SET LOCAL ROLE authenticated)】
//     T1  finance 克隆:通用口冲 JE-2026-0018 → JE_REVERSE_USE_PAYROLL_PAYMENT_REVERSAL;提付款冲销申请 → submitted,总账不动
//     T2  CFO 形状的审批人(真 cfo 角色的一次性持有人):批 → approved
//     T3  finance 克隆执行:早于原付款 / 晚于今天按名拒;今天 → 冲掉;那一行的戳清掉、期间仍 posted;冲销分录路由仍是 payroll_payment
//     T4  Q6:CPF 那张付款配上一张对账单行 → 提冲销申请按名拒 REVERSAL_BANK_MATCHED
//     T5  员工:病假余额 0,提一天病假按名拒 INSUFFICIENT_BALANCE(B1)
//   ROLLBACK 之后读回:三张付款 posted、戳与链接原样、payroll_requests / journal_entries / bank_statements 行数不变。
// 判决只从日志里最后那一行 `PPR1_PROOF_EXIT=` 读:0 = 每一格 PASS 且收尾干净 · 1 = 有 FAIL · 2 = 驱动坏了 · 5 = live-lock 被占 · 6 = 收尾没完成。
// 用法:PROOF_BASE=http://localhost:3197 node db/scripts/2026-10-22-payroll-pay-reversal-1-live-proof.mjs > <log> 2>&1
// ════════════════════════════════════════════════════════════════════════════
import { onlyWhenRunDirectly } from '../../scripts/lib/entrypoint.mjs'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawnSync } from 'node:child_process'
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
// 线上那一期三张付款此刻的样子(postgres 读基表,rolbypassrls)—— 回滚前后各读一次,必须逐字相同
const snapshot = () => psql(`SELECT string_agg(je.code || ':' || je.status, ',' ORDER BY je.code)
    || '|' || (SELECT string_agg(COALESCE(pl.paid_at::text, '-') || '/' || COALESCE(pl.paid_journal_entry_id::text, '-'), ',' ORDER BY pl.id) FROM payroll_lines pl)
    || '|' || (SELECT string_agg(COALESCE(cpf_paid_at::text, '-') || '/' || COALESCE(deductions_paid_at::text, '-') || '/' || status, ',' ORDER BY code) FROM payroll_periods)
    || '|' || (SELECT count(*) FROM payroll_requests) || '|' || (SELECT count(*) FROM journal_entries) || '|' || (SELECT count(*) FROM bank_statements)
    || '|' || (SELECT count(*) FROM leave_requests)
  FROM journal_entries je WHERE je.source_type = 'payroll';`).out.trim()

installExitHooks({
    onFinish: (code) => {
        try { if (locked) release() } catch { /* 放锁失败不改判决 */ }
        console.log('AFTER|nothing but the throwaway accounts, their grants and employee profiles was committed (removed by the plan)')
        console.log(`PPR1_PROOF_EXIT=${code}`)
    },
})

async function main() {
    const other = heldBy()
    if (other) { console.error(`✗ live-lock 被【${other.holder}】(pid ${other.pid})占着`); return exitAfterCleanup(5) }
    acquireOrExit('db/scripts/2026-10-22-payroll-pay-reversal-1-live-proof.mjs', { ownExit: false })
    locked = true
    openPlan('db/scripts/2026-10-22-payroll-pay-reversal-1-live-proof.mjs')
    await reapStalePlans()
    E = env()
    try { const r = await fetch(BASE + '/login', { redirect: 'manual' }); if (r.status !== 200) throw new Error(`HTTP ${r.status}`) }
    catch (e) { throw new Error(`PPR1_DRIVER|no next server at ${BASE}: ${e.message}`) }
    const s0 = snapshot()
    console.log(`BEFORE(postgres)|payroll entries|line stamps|period stamps|payroll requests|journal entries|bank statements|leave requests = ${s0}`)

    const stamp = Date.now()
    const fin = await mintThrowaway({ prefix: 'ppr1probe', label: 'fin', stamp, codes: { cloneOf: 'finance' } })
    // CFO 形状:真 cfo 角色的一次性持有人(审批开着,decide_payroll_request 认二级角色)—— 授权由清理计划收走
    const cfo = await mintThrowaway({ prefix: 'ppr1probe', label: 'cfo', stamp, codes: { realRole: 'cfo' } })
    const emp = await mintThrowaway({ prefix: 'ppr1probe', label: 'emp', stamp, codes: ['module.tasks.view'],
        employee: { code: `ZZ-PROBE-PPR1-E-${stamp}`, legal_name: 'ZZ Probe PPR1 new starter', employment_type: 'full_time', work_category: 'office', hire_date: '2026-09-01' } })
    const oth = await mintThrowaway({ prefix: 'ppr1probe', label: 'oth', stamp, codes: ['module.tasks.view'],
        employee: { code: `ZZ-PROBE-PPR1-O-${stamp}`, legal_name: 'ZZ Probe PPR1 other', employment_type: 'full_time', work_category: 'office', hire_date: '2020-01-01' } })
    console.log(`MINTED|finance copy ${fin.codes.length} codes · real cfo role ${cfo.codes.length} codes · employee ${emp.employeeId ? 'with profile' : 'NO PROFILE'} · other employee`)

    // ── HTTP 腿 ─────────────────────────────────────────────────────────────
    const pp = await getWith(fin.cookie, '/finance/payroll-payments')
    ok(pp.status === 200 && pp.body.includes('>Payments<') && ['JE-2026-0018', 'JE-2026-0019', 'JE-2026-0020'].every((c) => pp.body.includes(c))
       && pp.body.includes('Request reversal'),
       `H1: /finance/payroll-payments (finance copy) HTTP ${pp.status}: the "Payments" table lists JE-2026-0018 / 0019 / 0020, each with "Request reversal"`)
    const j18 = psql(`SELECT id FROM journal_entries WHERE code = 'JE-2026-0018';`).out.trim()
    const jp = await getWith(fin.cookie, `/finance/journal/${j18}`)
    ok(jp.status === 200 && jp.body.includes('This is a payroll payment') && jp.body.includes('href="/finance/payroll-payments"'),
       `H2: /finance/journal/JE-2026-0018 HTTP ${jp.status}: the reverse button points to the payroll payments page (Q8)`)
    const me = await getWith(emp.cookie, '/me')
    ok(me.status === 200 && me.body.includes('Every leave type') && me.body.includes('Hospitalisation Leave') && me.body.includes('Depends on eligibility'),
       `H3: /me (throwaway employee hired 2026-09-01) HTTP ${me.status}: the "Every leave type" table is drawn, maternity / paternity marked "Depends on eligibility" (Q12)`)
    const lb = await asUser(emp.token, '/rest/v1/rpc/leave_balances', { method: 'POST', body: JSON.stringify({ p_employee_id: emp.employeeId }) })
    const sick = Array.isArray(lb.body) ? lb.body.find((x) => x.leave_type_code === 'sick') : null
    ok(lb.status === 200 && Array.isArray(lb.body) && lb.body.length === 12 && lb.body[0].leave_type_code === 'annual' && Number(sick?.available) === 0,
       `H4: PostgREST leave_balances(own) → ${lb.status}, ${Array.isArray(lb.body) ? lb.body.length : '?'} items, first ${lb.body?.[0]?.leave_type_code}, sick available ${sick?.available} (B1: under 3 full months)`)
    const lo = await asUser(oth.token, '/rest/v1/rpc/leave_balances', { method: 'POST', body: JSON.stringify({ p_employee_id: emp.employeeId }) })
    ok(lo.status >= 400 && JSON.stringify(lo.body).includes('PERMISSION_DENIED|module.hr.view'),
       `H4: another employee asks for that employee's balances → ${lo.status} ${JSON.stringify(lo.body).slice(0, 120)}`)

    // ── 事务腿 ────────────────────────────────────────────────────────────
    const r = psql(txSql({ fin: sessionClaims(fin), cfo: sessionClaims(cfo), emp: sessionClaims(emp), empId: emp.employeeId }))
    for (const line of (r.out + '\n' + r.err).split('\n')) {
        const m = line.match(/NOTICE:\s+(PASS|FAIL)\|(.*)$/)
        if (m) ok(m[1] === 'PASS', m[2])
        else if (/NOTICE:\s+(INFO|TX_DONE)/.test(line)) console.log(line.replace(/^.*NOTICE:\s+/, ''))
    }
    ok(r.code === 0 && /TX_DONE/.test(r.out + r.err), `tx: the transaction leg ran to the end and rolled back (psql exit ${r.code}${r.code ? ' — ' + r.err.slice(-400) : ''})`)
    const s1 = snapshot()
    ok(s1 === s0, `after ROLLBACK: the three payroll payments, every stamp, payroll requests, journal entries, bank statements and leave requests ${s1 === s0 ? 'unchanged' : s0 + ' → ' + s1}`)

    console.log(bad ? `STEP|done with ${bad} FAIL` : 'STEP|done')
    return exitAfterCleanup(bad ? 1 : 0)
}

function txSql({ fin, cfo, emp, empId }) {
    return `BEGIN;
SET LOCAL statement_timeout = '120s';
CREATE FUNCTION pg_temp.pp_call(p_claims text, p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
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
DECLARE v text; j jsonb; cf text := ${lit(fin)}; cc text := ${lit(cfo)}; ce text := ${lit(emp)};
    e18 uuid; e19 uuid; q uuid; v_je int; v_rev uuid; v_stmt uuid; v_bl uuid; v_jl uuid; d18 date;
BEGIN
    SELECT id, entry_date INTO e18, d18 FROM journal_entries WHERE code = 'JE-2026-0018';
    SELECT id INTO e19 FROM journal_entries WHERE code = 'JE-2026-0019';
    -- T1 · 通用口按名拒;提付款冲销申请
    v := pg_temp.pp_call(cf, format('SELECT public.reverse_journal_entry(%L::uuid, CURRENT_DATE, %L)::text', e18, 'probe'));
    IF v NOT LIKE 'ERR|%JE_REVERSE_USE_PAYROLL_PAYMENT_REVERSAL|JE-2026-0018%' THEN RAISE NOTICE 'FAIL|T1: generic reversal of JE-2026-0018 → %', v;
    ELSE RAISE NOTICE 'PASS|T1: the generic journal reversal refuses JE-2026-0018 by name (JE_REVERSE_USE_PAYROLL_PAYMENT_REVERSAL, Q8)'; END IF;
    SELECT count(*) INTO v_je FROM journal_entries;
    v := pg_temp.pp_call(cf, format('SELECT public.submit_payroll_payment_reversal_request(%L::uuid, %L)::text', e18, 'ZZ-PROBE-PPR1 wrong amount'));
    IF v LIKE 'ERR|%' THEN RAISE NOTICE 'FAIL|T1: submit → %', v; RAISE NOTICE 'TX_DONE'; RETURN; END IF;
    j := v::jsonb; q := (j ->> 'request_id')::uuid;
    IF j ->> 'status' = 'submitted' AND (SELECT count(*) FROM journal_entries) = v_je THEN
        RAISE NOTICE 'PASS|T1: the finance copy raises a payment reversal on JE-2026-0018 → % submitted, no journal entry written', j ->> 'label';
    ELSE RAISE NOTICE 'FAIL|T1: submit → %', v; END IF;
    -- T2 · CFO 批
    v := pg_temp.pp_call(cc, format('SELECT public.decide_payroll_request(%L::uuid, true, %L)::text', q, 'probe ok'));
    IF v LIKE 'ERR|%' OR v::jsonb ->> 'status' <> 'approved' THEN RAISE NOTICE 'FAIL|T2: approve → %', v;
    ELSE RAISE NOTICE 'PASS|T2: a holder of the real cfo role approves it (level 2, the payroll gate)'; END IF;
    -- T3 · 执行
    v := pg_temp.pp_call(cf, format('SELECT public.reverse_payroll_payment(%L::uuid, %L::date)::text', q, d18 - 1));
    IF v NOT LIKE 'ERR|%REVERSAL_BEFORE_ORIGINAL|%' THEN RAISE NOTICE 'FAIL|T3: before the payment → %', v; ELSE RAISE NOTICE 'PASS|T3: a reversal date before the payment is refused (REVERSAL_BEFORE_ORIGINAL, Q4)'; END IF;
    v := pg_temp.pp_call(cf, format('SELECT public.reverse_payroll_payment(%L::uuid, CURRENT_DATE + 1)::text', q));
    IF v NOT LIKE 'ERR|%DOCUMENT_DATE_IN_FUTURE|payroll_payment_reversal|%' THEN RAISE NOTICE 'FAIL|T3: tomorrow → %', v; ELSE RAISE NOTICE 'PASS|T3: tomorrow is refused (DOCUMENT_DATE_IN_FUTURE, Q4)'; END IF;
    v := pg_temp.pp_call(cf, format('SELECT public.reverse_payroll_payment(%L::uuid, CURRENT_DATE)::text', q));
    IF v LIKE 'ERR|%' THEN RAISE NOTICE 'FAIL|T3: execute → %', v; RAISE NOTICE 'TX_DONE'; RETURN; END IF;
    v_rev := (v::jsonb ->> 'reversal_id')::uuid;
    IF (SELECT status FROM journal_entries WHERE id = e18) = 'reversed'
       AND NOT EXISTS (SELECT 1 FROM payroll_lines WHERE paid_journal_entry_id = e18 OR (paid_at IS NOT NULL AND paid_journal_entry_id IS NULL))
       AND (SELECT count(*) FROM payroll_lines WHERE paid_at IS NULL) = (v::jsonb ->> 'cleared')::int
       AND (SELECT status FROM payroll_periods WHERE code = 'PAY-2026-0001') = 'posted'
       AND (SELECT cpf_journal_entry_id FROM payroll_periods WHERE code = 'PAY-2026-0001') = e19
       AND journal_entry_reversal_route(v_rev) = 'payroll_payment' THEN
        RAISE NOTICE 'PASS|T3: executed today → JE-2026-0018 reversed, the line it paid is unpaid again (% cleared), PAY-2026-0001 still posted, CPF untouched, the reversal still routes to payroll_payment', v::jsonb ->> 'cleared';
    ELSE RAISE NOTICE 'FAIL|T3: after execute → %', v; END IF;
    -- T4 · Q6:CPF 付款配上对账单行 → 提交按名拒
    v := pg_temp.pp_call(cf, $q$SELECT public.import_bank_statement('1000', DATE '2026-08-01', DATE '2026-08-31', 0, -(SELECT round(sum(jl.credit), 2) FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id JOIN journal_entries je ON je.id = jl.entry_id WHERE je.code = 'JE-2026-0019' AND a.code = '1000'), 'zz-probe-ppr1.csv',
            jsonb_build_array(jsonb_build_object('line_date', DATE '2026-08-04', 'description', 'probe CPF', 'reference', 'ZZ-PROBE', 'amount',
              -(SELECT round(sum(jl.credit), 2) FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id JOIN journal_entries je ON je.id = jl.entry_id WHERE je.code = 'JE-2026-0019' AND a.code = '1000')))) ->> 'statement_id'$q$);
    IF v LIKE 'ERR|%' THEN RAISE NOTICE 'FAIL|T4: import statement → %', v;
    ELSE
        v_stmt := v::uuid;
        SELECT id INTO v_bl FROM bank_statement_lines WHERE statement_id = v_stmt AND line_no = 1;
        SELECT jl.id INTO v_jl FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id WHERE jl.entry_id = e19 AND a.code = '1000';
        v := pg_temp.pp_call(cf, format('SELECT public.match_bank_line(%L::uuid, ARRAY[%L::uuid])::text', v_bl, v_jl));
        IF v LIKE 'ERR|%' THEN RAISE NOTICE 'FAIL|T4: match → %', v; END IF;
        v := pg_temp.pp_call(cf, format('SELECT public.submit_payroll_payment_reversal_request(%L::uuid, %L)::text', e19, 'ZZ-PROBE-PPR1 cpf'));
        IF v NOT LIKE 'ERR|%REVERSAL_BANK_MATCHED|JE-2026-0019|%|open%' THEN RAISE NOTICE 'FAIL|T4: matched CPF → %', v;
        ELSE RAISE NOTICE 'PASS|T4: the CPF payment matched to a bank statement line → the reversal request is refused by name (REVERSAL_BANK_MATCHED, Q6)'; END IF;
    END IF;
    -- T5 · B1
    v := pg_temp.pp_call(ce, format('SELECT (public.leave_balance(%L::uuid, %L, CURRENT_DATE) ->> %L)', ${lit(empId)}, 'sick', 'available'));
    IF v <> '0' THEN RAISE NOTICE 'FAIL|T5: sick available → %', v; ELSE RAISE NOTICE 'PASS|T5: the new starter (hired 2026-09-01) has 0 days of sick leave (B1)'; END IF;
    v := pg_temp.pp_call(ce, format('SELECT public.submit_leave_request(%L::uuid, %L, CURRENT_DATE, CURRENT_DATE, false, false, NULL, NULL, false, NULL, NULL)::text', ${lit(empId)}, 'sick'));
    IF v NOT LIKE 'ERR|%INSUFFICIENT_BALANCE|%' THEN RAISE NOTICE 'FAIL|T5: sick leave request → %', v; ELSE RAISE NOTICE 'PASS|T5: a day of sick leave is refused by name (INSUFFICIENT_BALANCE)'; END IF;
    RAISE NOTICE 'TX_DONE';
END
$tx$;
ROLLBACK;
`
}

main().catch((e) => {
    console.error(String(e?.stack || e))
    return exitAfterCleanup(String(e?.message || '').startsWith('PPR1_DRIVER') ? 2 : 1)
})
