#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// EXPENSE-MULTILINE-1(2026-10-20)· 线上验证,以一次性账号(前缀 em1probe,scripts/ephemeral.mjs 的共用造号器)
// ════════════════════════════════════════════════════════════════════════════
// PROOF_BASE 上是一台【跑本刀代码、连线上】的 next。七个真账号一个都不用。
// ★ 委托书:线上【不提交】任何单据 —— 会写东西的证明一律在一笔 ROLLBACK 的事务里(触发器全开、没有任何旁路);
//   线上提交的只有一次性账号本身(与它们的授权),由清理计划收走。
//   【HTTP 腿】
//     H1  finance 克隆打开 /finance/expenses/new —— 行网格在(隐藏的 lines_json 格子、「加一行」),不再有单个的金额格
//     H2  finance 克隆打开 /finance/expenses —— 200;线上那 10 张单都转成了一行,科目栏印的是科目(没有一张是「N 个科目」)
//     H3  finance 克隆打开 EXP-2026-0007 —— 行表在,那一行是 6120 / TX
//     H4  cfo 克隆打开 /finance/claims —— 在途的 CLM-2026-0004 按笔画出(「Item 1」),每一笔有自己的科目与税码选择
//   【事务腿,不提交】
//     T1  admin 克隆记一张两行的费用单(TX + BL)给线上一家供应商 → 表头 = 两行之和、一张分录借贷平衡、1400 只收可抵的那一笔税
//     T2  资本单混普通行 → EXPENSE_CAPITAL_SOLE_LINE
//     T3  admin 克隆替线上一名员工提一张三笔的报销单(同月、本位币,每笔都有无收据理由)→ 表头 = 三笔之和、日期 = 最晚那一笔
//     T4  旧的 decide_expense_claim 碰到它 → EXPENSE_CLAIM_HAS_ITEMS
//     T5  一个持【真 finance 角色】的一次性账号(一级审批人)按笔批准 → 一张费用单、三行、欠那名员工、等于三张收据之和
//     T6  合计守卫在回滚之前强制跑一次(SET CONSTRAINTS ALL IMMEDIATE)
//   ROLLBACK 之后读回:这一次造的单据一行不剩;线上那 10 张费用单仍各一行、4 张报销单仍各一笔。
// 判决只从日志里最后那一行 `EM1_PROOF_EXIT=` 读:0 = 每一格 PASS 且收尾干净 · 1 = 有 FAIL · 2 = 驱动坏了 · 5 = live-lock 被占 · 6 = 收尾没完成。
// 用法:PROOF_BASE=http://localhost:3195 node db/scripts/2026-10-20-expense-multiline-1-live-proof.mjs > <log> 2>&1
// ════════════════════════════════════════════════════════════════════════════
import { onlyWhenRunDirectly } from '../../scripts/lib/entrypoint.mjs'
import { spawnSync } from 'node:child_process'
import { acquireOrExit, release, heldBy } from '../../scripts/liveLock.mjs'
import { openPlan, mintThrowaway, reapStalePlans, installExitHooks, exitAfterCleanup } from '../../scripts/ephemeral.mjs'

onlyWhenRunDirectly(import.meta.url)

const BASE = process.env.PROOF_BASE || 'http://localhost:3195'
const DSN = process.env.CHECK_MIRRORS_DSN || 'host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 user=postgres.wvywpohbwkiinmipmuku dbname=postgres'

let locked = false, bad = 0
const ok = (cond, what) => { console.log(`${cond ? 'PASS' : 'FAIL'}|${what}`); if (!cond) bad++; return cond }
const lit = (s) => `'${String(s).replace(/'/g, "''")}'`
function psql(sql) {
    const r = spawnSync('psql', [DSN, '-X', '-At', '-v', 'ON_ERROR_STOP=1'], { input: sql, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 })
    return { code: r.status, out: (r.stdout || ''), err: (r.stderr || '') }
}
const claimsOf = (jwt) => JSON.parse(Buffer.from(jwt.split('.')[1], 'base64url').toString())
const sessionClaims = (c) => JSON.stringify({ sub: claimsOf(c.token).sub, role: 'authenticated' })
async function getWith(cookie, path, locale = 'en') {
    const r = await fetch(BASE + path, { headers: { cookie: `${cookie}; NEXT_LOCALE=${locale}` }, redirect: 'manual' })
    const buf = Buffer.from(await r.arrayBuffer())
    return { status: r.status, body: buf.toString('utf8') }
}

installExitHooks({
    onFinish: (code) => {
        try { if (locked) release() } catch { /* 放锁失败不改判决 */ }
        console.log('AFTER|nothing but the throwaway accounts and their grants was committed (removed by the plan)')
        console.log(`EM1_PROOF_EXIT=${code}`)
    },
})

async function main() {
    const other = heldBy()
    if (other) { console.error(`✗ live-lock 被【${other.holder}】(pid ${other.pid})占着`); return exitAfterCleanup(5) }
    acquireOrExit('db/scripts/2026-10-20-expense-multiline-1-live-proof.mjs', { ownExit: false })
    locked = true
    openPlan('db/scripts/2026-10-20-expense-multiline-1-live-proof.mjs')
    await reapStalePlans()
    try { const r = await fetch(BASE + '/login', { redirect: 'manual' }); if (r.status !== 200) throw new Error(`HTTP ${r.status}`) }
    catch (e) { throw new Error(`EM1_DRIVER|no next server at ${BASE}: ${e.message}`) }

    const stamp = Date.now()
    const fin = await mintThrowaway({ prefix: 'em1probe', label: 'fin', stamp, codes: { cloneOf: 'finance' } })
    const cfo = await mintThrowaway({ prefix: 'em1probe', label: 'cfo', stamp, codes: { cloneOf: 'cfo' } })
    const adm = await mintThrowaway({ prefix: 'em1probe', label: 'adm', stamp, codes: { cloneOf: 'admin' } })
    // 一级审批人:审批开着时 require_approver_for(1) 认的是【真 finance 角色】(approval_level_eligible),一个克隆角色认不出 ——
    //   所以这一个授的是真角色(造号器对 is_system 的角色拒授;finance 不是 is_system)。授权由清理计划收走。
    const lv1 = await mintThrowaway({ prefix: 'em1probe', label: 'lv1', stamp, codes: { realRole: 'finance' } })
    console.log(`CLONES|finance ${fin.codes.length} · cfo ${cfo.codes.length} · admin ${adm.codes.length} · real finance role ${lv1.codes.length} (view_prices ${lv1.codes.includes('data.view_prices')})`)

    // ── HTTP 腿 ─────────────────────────────────────────────────────────────
    const nw = await getWith(fin.cookie, '/finance/expenses/new')
    ok(nw.status === 200 && nw.body.includes('name="lines_json"') && nw.body.includes('data-expense-lines')
       && nw.body.includes('+ Add a line') && !nw.body.includes('name="amount"'),
       `H1: /finance/expenses/new (finance copy) HTTP ${nw.status} draws the line grid (hidden lines_json, "+ Add a line") and no single amount field`)
    const list = await getWith(fin.cookie, '/finance/expenses')
    ok(list.status === 200 && list.body.includes('EXP-2026-0007') && !/\b\d+ accounts\b/.test(list.body),
       `H2: /finance/expenses HTTP ${list.status} lists the converted one-line expenses with their account (no "N accounts" on any of them)`)
    const e7 = psql(`SELECT id FROM expenses WHERE code = 'EXP-2026-0007';`).out.trim()
    const d7 = await getWith(fin.cookie, `/finance/expenses/${e7}`)
    ok(d7.status === 200 && d7.body.includes('6120') && d7.body.includes('>Lines<'),
       `H3: /finance/expenses/EXP-2026-0007 HTTP ${d7.status} shows the lines table with its one line on 6120`)
    const cl = await getWith(cfo.cookie, '/finance/claims')
    ok(cl.status === 200 && cl.body.includes('CLM-2026-0004') && cl.body.includes('Item 1'),
       `H4: /finance/claims (cfo copy) HTTP ${cl.status}: the pending CLM-2026-0004 is drawn item by item ("Item 1")`)

    // ── 事务腿 ────────────────────────────────────────────────────────────
    const r = psql(txSql({ adm: sessionClaims(adm), lv1: sessionClaims(lv1) }))
    for (const line of (r.out + '\n' + r.err).split('\n')) {
        const m = line.match(/NOTICE:\s+(PASS|FAIL)\|(.*)$/)
        if (m) ok(m[1] === 'PASS', m[2])
        else if (/NOTICE:\s+(INFO|TX_DONE)/.test(line)) console.log(line.replace(/^.*NOTICE:\s+/, ''))
    }
    ok(r.code === 0 && /TX_DONE/.test(r.out + r.err), `tx: the transaction leg ran to the end and rolled back (psql exit ${r.code}${r.code ? ' — ' + r.err.slice(-400) : ''})`)
    const after = psql(`SELECT (SELECT count(*) FROM expenses WHERE notes LIKE 'ZZ-PROBE-EM1%') || '|' ||
        (SELECT count(*) FROM expense_claims WHERE description LIKE 'ZZ-PROBE-EM1%') || '|' ||
        (SELECT count(*) FROM expense_lines) || '|' || (SELECT count(*) FROM expense_claim_items) || '|' ||
        (SELECT count(*) FROM expenses) || '|' || (SELECT count(*) FROM expense_claims);`).out.trim()
    ok(after === '0|0|10|4|10|4', `after ROLLBACK: probe expenses / claims 0; the 10 live expenses still one line each, the 4 claims one item each (read ${after})`)

    console.log(bad ? `STEP|done with ${bad} FAIL` : 'STEP|done')
    return exitAfterCleanup(bad ? 1 : 0)
}

function txSql({ adm, lv1 }) {
    return `BEGIN;
SET LOCAL statement_timeout = '120s';
CREATE FUNCTION pg_temp.em_call(p_claims text, p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
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
    RETURN 'ERR|' || SQLERRM;
END;
$f$;
DO $tx$
DECLARE v text; j jsonb; ca text := ${lit(adm)}; cl text := ${lit(lv1)};
    v_sup uuid; v_emp uuid; v_exp uuid; v_je uuid; v_claim uuid; v_code text; d date;
    v_n int; v_x numeric; v_y numeric;
BEGIN
    SELECT id INTO v_sup FROM suppliers WHERE deleted_at IS NULL AND status IN ('approved', 'active')
       AND (tax_residence IS DISTINCT FROM 'non_resident') ORDER BY code LIMIT 1;
    SELECT id INTO v_emp FROM employees WHERE deleted_at IS NULL ORDER BY code LIMIT 1;
    d := (date_trunc('month', CURRENT_DATE) + interval '1 day')::date;
    IF d > CURRENT_DATE THEN d := CURRENT_DATE; END IF;

    -- T1 · 两行一张分录
    v := pg_temp.em_call(ca, format($q$SELECT record_expense_document(p_expense_date := %L::date, p_currency := (SELECT code FROM currencies WHERE is_base),
            p_supplier_id := %L::uuid, p_notes := 'ZZ-PROBE-EM1 two lines',
            p_lines := '[{"account_code":"6100","amount":200,"tax_code":"TX","notes":"probe line one"},{"account_code":"6120","amount":100,"tax_code":"BL"}]'::jsonb)::text$q$, d, v_sup));
    IF v LIKE 'ERR|%' THEN RAISE NOTICE 'FAIL|T1: two-line expense → %', v;
    ELSE
        j := v::jsonb; v_exp := (j ->> 'expense_id')::uuid;
        SELECT journal_entry_id INTO v_je FROM expenses WHERE id = v_exp;
        SELECT count(*) INTO v_n FROM expense_lines WHERE expense_id = v_exp;
        SELECT sum(debit), sum(credit) INTO v_x, v_y FROM journal_lines WHERE entry_id = v_je;
        IF v_n = 2 AND (j ->> 'amount_ccy')::numeric = 300 AND (j ->> 'tax_ccy')::numeric = 27
           AND (SELECT amount_ccy + tax_ccy FROM expenses WHERE id = v_exp) = (SELECT sum(amount_ccy + tax_ccy) FROM expense_lines WHERE expense_id = v_exp)
           AND v_x = v_y AND v_x = 327
           AND (SELECT sum(jl.debit) FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id WHERE jl.entry_id = v_je AND a.code = '1400') = 18
           AND (SELECT count(*) FROM journal_entries WHERE source_type = 'expense' AND source_id = v_exp) = 1 THEN
            RAISE NOTICE 'PASS|T1: % — two lines (6100 TX, 6120 BL), header = sum of lines (300 net + 27 GST), one journal entry 327/327, only the claimable 18 to 1400', j ->> 'code';
        ELSE RAISE NOTICE 'FAIL|T1: lines % · journal %/% · %', v_n, v_x, v_y, v; END IF;
    END IF;

    -- T2 · 资本单混普通行
    v := pg_temp.em_call(ca, format($q$SELECT record_expense_document(p_expense_date := %L::date, p_currency := (SELECT code FROM currencies WHERE is_base),
            p_supplier_id := %L::uuid, p_notes := 'ZZ-PROBE-EM1 capital mix',
            p_lines := '[{"account_code":"6100","amount":10,"tax_code":"TX"},{"account_code":"1500","amount":10,"tax_code":"TX"}]'::jsonb)::text$q$, d, v_sup));
    IF v LIKE 'ERR|EXPENSE_CAPITAL_SOLE_LINE|2%' THEN RAISE NOTICE 'PASS|T2: a capital line mixed with an ordinary line is refused by name (EXPENSE_CAPITAL_SOLE_LINE)';
    ELSE RAISE NOTICE 'FAIL|T2: capital mix → %', v; END IF;

    -- T3 · 三笔的报销单
    v := pg_temp.em_call(ca, format($q$SELECT submit_expense_claim_items(%L::uuid, (SELECT code FROM currencies WHERE is_base), 'ZZ-PROBE-EM1 claim',
            jsonb_build_array(
              jsonb_build_object('spend_date', %L::date, 'amount', 109, 'description', 'probe taxi', 'no_receipt_reason', 'probe'),
              jsonb_build_object('spend_date', %L::date, 'amount', 54.5, 'description', 'probe lunch', 'no_receipt_reason', 'probe'),
              jsonb_build_object('spend_date', %L::date, 'amount', 20, 'description', 'probe parking', 'no_receipt_reason', 'probe')))::text$q$,
            v_emp, date_trunc('month', d)::date, d, date_trunc('month', d)::date));
    IF v LIKE 'ERR|%' THEN RAISE NOTICE 'FAIL|T3: three-item claim → %', v;
    ELSE
        j := v::jsonb; v_claim := (j ->> 'claim_id')::uuid; v_code := j ->> 'code';
        IF (j ->> 'item_count')::int = 3 AND EXISTS (SELECT 1 FROM expense_claims WHERE id = v_claim AND amount_ccy = 183.5 AND spend_date = d) THEN
            RAISE NOTICE 'PASS|T3: % — three items on one claim, header 183.50 = sum of items, date = the latest item (%)', v_code, d;
        ELSE RAISE NOTICE 'FAIL|T3: header not as expected → %', v; END IF;

        -- T4 · 旧决定碰到多笔
        v := pg_temp.em_call(cl, format('SELECT decide_expense_claim(%L::uuid, true, ''6120'', ''TX'', NULL, NULL)::text', v_claim));
        IF v = 'ERR|EXPENSE_CLAIM_HAS_ITEMS|' || v_code || '|3' THEN RAISE NOTICE 'PASS|T4: the old one-account decide refuses a three-item claim by name (EXPENSE_CLAIM_HAS_ITEMS)';
        ELSE RAISE NOTICE 'FAIL|T4: old decide on three items → %', v; END IF;

        -- T5 · 一级审批人按笔批准
        v := pg_temp.em_call(cl, format($q$SELECT decide_expense_claim_items(%L::uuid, true, '[{"line_no":1,"account_code":"6120","tax_code":"TX"},{"line_no":2,"account_code":"6120","tax_code":"BL"},{"line_no":3,"account_code":"6300","tax_code":"TX"}]'::jsonb, NULL, NULL)::text$q$, v_claim));
        IF v LIKE 'ERR|%' THEN RAISE NOTICE 'FAIL|T5: item-by-item approval → %', v;
        ELSE
            j := v::jsonb; v_exp := (j ->> 'expense_id')::uuid;
            IF (SELECT count(*) FROM expense_lines WHERE expense_id = v_exp) = 3
               AND EXISTS (SELECT 1 FROM expenses WHERE id = v_exp AND employee_id = v_emp AND supplier_id IS NULL AND payment_status = 'unpaid' AND amount_ccy + tax_ccy = 183.5)
               AND (SELECT count(*) FROM expense_claim_items WHERE claim_id = v_claim AND account_code IS NOT NULL) = 3 THEN
                RAISE NOTICE 'PASS|T5: a level-1 approver (real finance role) approves item by item → one expense, three lines, owed to the employee, = the three receipts (183.50)';
            ELSE RAISE NOTICE 'FAIL|T5: approval result → %', v; END IF;
        END IF;
    END IF;

    -- T6 · 合计守卫在回滚之前跑一次
    BEGIN
        SET CONSTRAINTS ALL IMMEDIATE;
        SET CONSTRAINTS ALL DEFERRED;
        RAISE NOTICE 'PASS|T6: the deferred totals guards (expenses / expense_lines / expense_claims / expense_claim_items) pass for every document this transaction wrote';
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'FAIL|T6: a deferred totals guard refused → %', SQLERRM; END;
    RAISE NOTICE 'TX_DONE';
END
$tx$;
ROLLBACK;
`
}

main().catch((e) => {
    console.error(String(e?.stack || e))
    return exitAfterCleanup(String(e?.message || '').startsWith('EM1_DRIVER') ? 2 : 1)
})
