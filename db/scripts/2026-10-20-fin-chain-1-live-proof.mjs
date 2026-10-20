#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// FIN-CHAIN-1(2026-10-20)· 线上验证,以一次性账号(前缀 finchain1probe,scripts/ephemeral.mjs 的共用造号器)
// ════════════════════════════════════════════════════════════════════════════
// PROOF_BASE 上是一台【跑本刀代码、连线上】的 next。七个真账号一个都不用。
// ★ 委托书:线上【不提交】任何单据 —— 会写东西的证明一律在一笔 ROLLBACK 的事务里(触发器全开、没有任何旁路);
//   线上提交的只有一次性账号本身,由清理计划收走。
//   【HTTP 腿】同码克隆(cloneOf):
//     A4  finance 克隆打开 /finance/expenses/new —— 十三个新费用科目都在下拉里,2600 不在
//     A5  finance 克隆打开 /finance/trial-balance?all=1 —— 系统科目带「System」标(6800),2600 不带
//     C2  finance 克隆打开 /finance —— 那一块写的是新勾稽的说法,应收 / 应付两条腿都在
//     C7  cfo 克隆(tim@ 的形状:finance.view + view_prices、不持 .edit)打开 /finance/claims —— 线上有一张在等的报销单,
//         决定钮不再说"缺 module.finance.edit"
//     C3  /finance/month-end 打得开
//   【事务腿,不提交】以 admin 克隆与 cco 克隆的声明:
//     C1  六扇出钱的门各撞一次明天 → DOCUMENT_DATE_IN_FUTURE
//     B1  一张自带的订单确认、开票(零税率)→ 作废按名拒 SO_CANCEL_HAS_LIVE_INVOICE
//     B2  线上那一笔订单流的销售 → create_invoice 按名拒 SALE_IS_ORDER_FLOW
//     B4  cco 克隆直连插 / 改一张报价的状态 → QT_STATUS_THROUGH_FUNCTION_ONLY;改备注照旧可以
//     C6  线上一张已过账的运费单不给冲销日 → REVERSAL_DATE_REQUIRED(什么都不写)
//     C3  一笔打进 2000 的手工分录 → list_ledger_reconciliation 的 ap 未解释 −777(close_period 读的那一支);
//         close_period 在线上先撞上它更早的一道闸(8 张未分摊的加工单,AT1C3)—— 照直报出来
//     A1  十四个科目逐字;2600 不在费用单下拉的谓词里
//   ROLLBACK 之后读回:十四个科目仍在、自带的订单 / 报价 / 分录一行不剩。
// 判决只从日志里最后那一行 `FINCHAIN1_PROOF_EXIT=` 读:0 = 每一格 PASS 且收尾干净 · 1 = 有 FAIL · 2 = 驱动坏了 · 5 = live-lock 被占 · 6 = 收尾没完成。
// 用法:PROOF_BASE=http://localhost:3195 node db/scripts/2026-10-20-fin-chain-1-live-proof.mjs > <log> 2>&1
// ════════════════════════════════════════════════════════════════════════════
import { onlyWhenRunDirectly } from '../../scripts/lib/entrypoint.mjs'
import { spawnSync } from 'node:child_process'
import { acquireOrExit, release, heldBy } from '../../scripts/liveLock.mjs'
import { openPlan, mintThrowaway, reapStalePlans, installExitHooks, exitAfterCleanup } from '../../scripts/ephemeral.mjs'

onlyWhenRunDirectly(import.meta.url)

const BASE = process.env.PROOF_BASE || 'http://localhost:3195'
const DSN = process.env.CHECK_MIRRORS_DSN || 'host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 user=postgres.wvywpohbwkiinmipmuku dbname=postgres'
const NEW_EXPENSE = ['6010', '6130', '6140', '6210', '6220', '6230', '6240', '6250', '6310', '6410', '6420', '6510', '6520']

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
    const t0 = Date.now()
    const r = await fetch(BASE + path, { headers: { cookie: `${cookie}; NEXT_LOCALE=${locale}` }, redirect: 'manual' })
    const buf = Buffer.from(await r.arrayBuffer())
    return { status: r.status, ms: Date.now() - t0, body: buf.toString('utf8') }
}

installExitHooks({
    onFinish: (code) => {
        try { if (locked) release() } catch { /* 放锁失败不改判决 */ }
        console.log('AFTER|nothing but the throwaway accounts was committed (removed by the plan)')
        console.log(`FINCHAIN1_PROOF_EXIT=${code}`)
    },
})

async function main() {
    const other = heldBy()
    if (other) { console.error(`✗ live-lock 被【${other.holder}】(pid ${other.pid})占着`); return exitAfterCleanup(5) }
    acquireOrExit('db/scripts/2026-10-20-fin-chain-1-live-proof.mjs', { ownExit: false })
    locked = true
    openPlan('db/scripts/2026-10-20-fin-chain-1-live-proof.mjs')
    await reapStalePlans()
    try { const r = await fetch(BASE + '/login', { redirect: 'manual' }); if (r.status !== 200) throw new Error(`HTTP ${r.status}`) }
    catch (e) { throw new Error(`FINCHAIN1_DRIVER|no next server at ${BASE}: ${e.message}`) }

    const stamp = Date.now()
    const fin = await mintThrowaway({ prefix: 'finchain1probe', label: 'fin', stamp, codes: { cloneOf: 'finance' } })
    const cfo = await mintThrowaway({ prefix: 'finchain1probe', label: 'cfo', stamp, codes: { cloneOf: 'cfo' } })
    const adm = await mintThrowaway({ prefix: 'finchain1probe', label: 'adm', stamp, codes: { cloneOf: 'admin' } })
    const cco = await mintThrowaway({ prefix: 'finchain1probe', label: 'cco', stamp, codes: { cloneOf: 'cco' } })
    console.log(`CLONES|finance ${fin.codes.length} codes · cfo ${cfo.codes.length} (finance.edit ${cfo.codes.includes('module.finance.edit')}, view_prices ${cfo.codes.includes('data.view_prices')}) · admin ${adm.codes.length} · cco ${cco.codes.length} (sales.edit ${cco.codes.includes('module.sales.edit')})`)

    // ── HTTP 腿 ─────────────────────────────────────────────────────────────
    const exp = await getWith(fin.cookie, '/finance/expenses/new')
    const missing = NEW_EXPENSE.filter((c) => !exp.body.includes(`value="${c}"`))
    ok(exp.status === 200 && missing.length === 0 && !exp.body.includes('value="2600"'),
       `A4: /finance/expenses/new (finance copy) HTTP ${exp.status} lists all 13 new expense accounts in the account picker${missing.length ? ' — MISSING ' + missing.join(',') : ''}, and not 2600 Loan Payable`)
    const tb = await getWith(fin.cookie, '/finance/trial-balance?all=1')
    ok(tb.status === 200 && tb.body.includes('data-system-account="6800"') && tb.body.includes('data-system-account="2000"')
       && !tb.body.includes('data-system-account="2600"') && !tb.body.includes('data-system-account="6010"'),
       `A5: /finance/trial-balance?all=1 HTTP ${tb.status} marks system accounts (6800, 2000 carry the System badge; 2600 and 6010 do not)`)
    const tbzh = await getWith(fin.cookie, '/finance/trial-balance?all=1', 'zh')
    ok(tbzh.body.includes('>系统<') || tbzh.body.includes('系统</span>'), `A5: the badge reads 系统 in Chinese`)
    const home = await getWith(fin.cookie, '/finance')
    ok(home.status === 200 && home.body.includes('the same check the Month-end step reads')
       && home.body.includes('data-recon-side="ar"') && home.body.includes('data-recon-side="ap"')
       && !home.body.includes('answered by no page at all'),
       `C2: /finance HTTP ${home.status} — the ledger-vs-list block states the new basis, shows the ar and ap legs, and the out-of-date sentence is gone`)
    const me = await getWith(fin.cookie, '/finance/month-end')
    ok(me.status === 200, `C3: /finance/month-end HTTP ${me.status} (${me.ms} ms)`)
    const claims = await getWith(cfo.cookie, '/finance/claims')
    ok(claims.status === 200 && !claims.body.includes('module.finance.edit') && claims.body.includes('CLM-2026-0004'),
       `C7: /finance/claims (cfo copy — finance.view + view_prices, no .edit) HTTP ${claims.status}: the pending claim is listed and no control names module.finance.edit`)

    // ── 事务腿 ────────────────────────────────────────────────────────────
    const r = psql(txSql({ adm: sessionClaims(adm), cco: sessionClaims(cco), fin: sessionClaims(fin) }))
    for (const line of (r.out + '\n' + r.err).split('\n')) {
        const m = line.match(/NOTICE:\s+(PASS|FAIL)\|(.*)$/)
        if (m) ok(m[1] === 'PASS', m[2])
        else if (/NOTICE:\s+(INFO|TX_DONE)/.test(line)) console.log(line.replace(/^.*NOTICE:\s+/, ''))
    }
    ok(r.code === 0 && /TX_DONE/.test(r.out + r.err), `tx: the transaction leg ran to the end and rolled back (psql exit ${r.code}${r.code ? ' — ' + r.err.slice(-400) : ''})`)
    const after = psql(`SELECT (SELECT count(*) FROM accounts WHERE code IN ('2600',${NEW_EXPENSE.map(lit).join(',')})) || '|' ||
        (SELECT count(*) FROM customers WHERE legal_name LIKE 'ZZ-PROBE-FINCHAIN1%') || '|' ||
        (SELECT count(*) FROM journal_entries WHERE memo LIKE 'ZZ-PROBE-FINCHAIN1%') || '|' ||
        (SELECT count(*) FROM materials WHERE code LIKE 'ZZ-PROBE-FC1%');`).out.trim()
    ok(after === '14|0|0|0', `after ROLLBACK: the 14 accounts are there; probe customers / journals / materials = 0 (read ${after})`)

    console.log(bad ? `STEP|done with ${bad} FAIL` : 'STEP|done')
    return exitAfterCleanup(bad ? 1 : 0)
}

function txSql({ adm, cco, fin }) {
    return `BEGIN;
SET LOCAL statement_timeout = '120s';
CREATE FUNCTION pg_temp.fc_call(p_claims text, p_role text, p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE v text;
BEGIN
    PERFORM set_config('request.jwt.claims', p_claims, true);
    IF p_role IS NOT NULL THEN EXECUTE format('SET LOCAL ROLE %I', p_role); END IF;
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
DECLARE v text; j jsonb; k text; d1 date := CURRENT_DATE + 1;
    ca text := ${lit(adm)}; cc text := ${lit(cco)}; cf text := ${lit(fin)};
    v_cust uuid; v_mat uuid; v_so uuid; v_so_code text; v_line uuid; v_inv text; v_q uuid; v_q_code text; v_sale uuid; v_sale_cust uuid; v_batch text;
    v_frt uuid; v_frt_code text; v_doors text[][] := ARRAY[
        ARRAY['payroll_payment',            'SELECT pay_payroll_lines(gen_random_uuid(), ARRAY[]::uuid[], %L::date)::text'],
        ARRAY['cpf_payment',                'SELECT pay_payroll_cpf(gen_random_uuid(), %L::date)::text'],
        ARRAY['deductions_payment',         'SELECT pay_payroll_deductions(gen_random_uuid(), %L::date)::text'],
        ARRAY['processing_cost_remittance', 'SELECT remit_processing_costs(ARRAY[gen_random_uuid()], %L::date)::text'],
        ARRAY['wht_remittance',             'SELECT remit_wht_internal(date_trunc(''month'', CURRENT_DATE)::date, %L::date)::text'],
        ARRAY['bank_transfer',              'SELECT record_bank_transfer_internal(%L::date, ''1000'', ''1010'', 100, 75)::text']];
    i int;
BEGIN
    -- A1 · 十四个科目
    IF (SELECT count(*) FROM accounts WHERE code IN ('2600','6010','6130','6140','6210','6220','6230','6240','6250','6310','6410','6420','6510','6520') AND NOT is_system AND is_active) = 14
       AND EXISTS (SELECT 1 FROM accounts WHERE code = '2600' AND account_type = 'liability' AND is_monetary AND cash_flow_section = 'financing')
       AND NOT EXISTS (SELECT 1 FROM accounts WHERE code = '2600' AND account_type = 'expense') THEN
        RAISE NOTICE 'PASS|A1/A2: the 14 accounts are on live as ruled (non-system, active; 2600 liability · monetary · financing; it is not in the expense picker''s predicate)';
    ELSE RAISE NOTICE 'FAIL|A1/A2: the 14 accounts are not as ruled'; END IF;

    -- C1 · 六扇门(引擎那两扇以 postgres 跑 —— authenticated 调不到,外门是付款申请)
    FOR i IN 1 .. array_length(v_doors, 1) LOOP
        v := pg_temp.fc_call(ca, CASE WHEN v_doors[i][1] IN ('wht_remittance', 'bank_transfer') THEN NULL ELSE 'authenticated' END, format(v_doors[i][2], d1));
        IF v LIKE 'ERR|DOCUMENT_DATE_IN_FUTURE|' || v_doors[i][1] || '|' || d1 || '|' || CURRENT_DATE THEN
            RAISE NOTICE 'PASS|C1: % refuses tomorrow by name (DOCUMENT_DATE_IN_FUTURE|%)', v_doors[i][1], v_doors[i][1];
        ELSE RAISE NOTICE 'FAIL|C1: % with tomorrow → %', v_doors[i][1], v; END IF;
    END LOOP;
    v := pg_temp.fc_call(cf, 'authenticated', format('SELECT submit_bank_transfer_request(%L::date, ''1000'', ''1010'', 100, 75)::text', d1));
    IF v LIKE 'ERR|DOCUMENT_DATE_IN_FUTURE|bank_transfer|%' THEN RAISE NOTICE 'PASS|C1: a bank-transfer request planned for tomorrow is refused at submit (finance copy)';
    ELSE RAISE NOTICE 'FAIL|C1: transfer request for tomorrow → %', v; END IF;

    -- B1 · 挂着在册发票的订单作废不得(布景的直连插入带着 admin 克隆的声明 —— 行级守卫要看得见调用者,例如可售形态那一条)
    PERFORM set_config('request.jwt.claims', ca, true);
    INSERT INTO customers (code, legal_name, country, payment_terms_days) VALUES ('ZZ-PROBE-FC1-C', 'ZZ-PROBE-FINCHAIN1 customer', 'SG', 30) RETURNING id INTO v_cust;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, unit)
    VALUES ('ZZ-PROBE-FC1-M', 'ZZ-PROBE-FINCHAIN1 material', 'battery_material', true, 'black_mass', 'end_of_life', 'kg') RETURNING id INTO v_mat;
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES (next_sales_order_code(CURRENT_DATE), v_cust, CURRENT_DATE, (SELECT code FROM currencies WHERE is_base), 1) RETURNING id, code INTO v_so, v_so_code;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price) VALUES (v_so, 1, v_mat, 2, 10) RETURNING id INTO v_line;
    PERFORM set_config('request.jwt.claims', '', true);
    v := pg_temp.fc_call(ca, 'authenticated', format('SELECT set_sales_order_status(%L, ''confirmed'')::text', v_so));
    v := pg_temp.fc_call(ca, 'authenticated', format('SELECT create_order_invoice(%L, CURRENT_DATE, NULL, NULL, NULL, ARRAY[%L]::uuid[], ''ZR'')::text', v_so, v_line));
    IF v LIKE 'ERR|%' THEN RAISE NOTICE 'FAIL|B1 setup: order invoice → %', v;
    ELSE
        v_inv := v::jsonb ->> 'code';
        v := pg_temp.fc_call(cc, 'authenticated', format('SELECT set_sales_order_status(%L, ''cancelled'', ''probe'')::text', v_so));
        IF v = 'ERR|SO_CANCEL_HAS_LIVE_INVOICE|' || v_so_code || '|' || v_inv THEN
            RAISE NOTICE 'PASS|B1: cancelling a confirmed order with a live invoice is refused by name (cco copy) — SO_CANCEL_HAS_LIVE_INVOICE|%|%', v_so_code, v_inv;
        ELSE RAISE NOTICE 'FAIL|B1: cancel → %', v; END IF;
    END IF;

    -- B2 · 线上那一笔订单流的销售
    SELECT sr.id, sr.customer_id, ob.code INTO v_sale, v_sale_cust, v_batch
      FROM sales_records sr JOIN output_batches ob ON ob.id = sr.output_batch_id WHERE sr.sales_order_line_id IS NOT NULL LIMIT 1;
    IF v_sale IS NULL THEN RAISE NOTICE 'INFO|B2: no order-flow sale on live to try';
    ELSE
        v := pg_temp.fc_call(ca, 'authenticated', format('SELECT create_invoice(%L, ARRAY[%L]::uuid[], CURRENT_DATE, 30, NULL, NULL, ''SR'')::text', v_sale_cust, v_sale));
        IF v = 'ERR|SALE_IS_ORDER_FLOW|' || v_batch THEN RAISE NOTICE 'PASS|B2: the live order-flow sale (batch %) cannot be billed again on a sale-type invoice (SALE_IS_ORDER_FLOW)', v_batch;
        ELSE RAISE NOTICE 'FAIL|B2: create_invoice on an order-flow sale → %', v; END IF;
    END IF;

    -- B4 · 报价的状态只经函数写(cco 克隆,RLS 在场)
    v := pg_temp.fc_call(cc, 'authenticated', format('INSERT INTO quotes (customer_id, quote_date, valid_until, currency, fx_rate, status) VALUES (%L, CURRENT_DATE, CURRENT_DATE + 30, %L, 1, ''issued'') RETURNING id::text', v_cust, (SELECT code FROM currencies WHERE is_base)));
    IF v = 'ERR|QT_STATUS_THROUGH_FUNCTION_ONLY|status|issued' THEN RAISE NOTICE 'PASS|B4: a direct insert of an issued quotation is refused by name';
    ELSE RAISE NOTICE 'FAIL|B4: direct insert issued → %', v; END IF;
    v := pg_temp.fc_call(cc, 'authenticated', format('INSERT INTO quotes (customer_id, quote_date, valid_until, currency, fx_rate) VALUES (%L, CURRENT_DATE, CURRENT_DATE + 30, %L, 1) RETURNING id::text', v_cust, (SELECT code FROM currencies WHERE is_base)));
    IF v LIKE 'ERR|%' THEN RAISE NOTICE 'FAIL|B4: direct insert of a draft → %', v;
    ELSE
        v_q := v::uuid; SELECT code INTO v_q_code FROM quotes WHERE id = v_q;
        v := pg_temp.fc_call(cc, 'authenticated', format('UPDATE quotes SET status = ''declined'', decline_reason = ''x'' WHERE id = %L RETURNING id::text', v_q));
        IF v = 'ERR|QT_STATUS_THROUGH_FUNCTION_ONLY|status|' || v_q_code THEN RAISE NOTICE 'PASS|B4: a direct status update is refused by name (%)', v_q_code;
        ELSE RAISE NOTICE 'FAIL|B4: direct status update → %', v; END IF;
        v := pg_temp.fc_call(cc, 'authenticated', format('UPDATE quotes SET notes = ''ZZ-PROBE-FINCHAIN1'' WHERE id = %L RETURNING id::text', v_q));
        IF v = v_q::text THEN RAISE NOTICE 'PASS|B4: a direct notes edit still works (that is what a quotation is for)';
        ELSE RAISE NOTICE 'FAIL|B4: notes edit → %', v; END IF;
    END IF;

    -- C6 · 一张运费单,不给冲销日 —— 日期那一句在读单据之前(线上已没有 posted 的运费单;拒绝什么都不写)
    SELECT id, code INTO v_frt, v_frt_code FROM freight_documents WHERE deleted_at IS NULL ORDER BY code LIMIT 1;
    IF v_frt IS NULL THEN RAISE NOTICE 'INFO|C6: no freight document on live';
    ELSE
        v := pg_temp.fc_call(cf, 'authenticated', format('SELECT reverse_freight_document(%L, ''probe'')::text', v_frt));
        IF v = 'ERR|REVERSAL_DATE_REQUIRED' THEN
            RAISE NOTICE 'PASS|C6: reversing % without a reversal date is refused by name (REVERSAL_DATE_REQUIRED), the document untouched', v_frt_code;
        ELSE RAISE NOTICE 'FAIL|C6: reverse without date → %', v; END IF;
        IF to_regprocedure('public.reverse_freight_document(uuid,text)') IS NULL THEN RAISE NOTICE 'PASS|C6: the two-argument signature is gone (no overload)';
        ELSE RAISE NOTICE 'FAIL|C6: the old signature is still there'; END IF;
    END IF;

    -- C3 · 一笔打进 2000 的手工分录 → 关账读的那一支勾稽动了
    v := pg_temp.fc_call(cf, 'authenticated', 'SELECT list_ledger_reconciliation()::text');
    j := v::jsonb;
    RAISE NOTICE 'INFO|C3: before — ap unexplained %, ar unexplained %',
        (SELECT s ->> 'unexplained_base' FROM jsonb_array_elements(j -> 'sides') s WHERE s ->> 'side' = 'ap'),
        (SELECT s ->> 'unexplained_base' FROM jsonb_array_elements(j -> 'sides') s WHERE s ->> 'side' = 'ar');
    BEGIN
        PERFORM set_config('request.jwt.claims', ca, true);
        PERFORM post_journal_entry(CURRENT_DATE, 'ZZ-PROBE-FINCHAIN1 manual into 2000', 'manual', NULL,
            jsonb_build_array(
                jsonb_build_object('account_code', '6900', 'side', 'debit',  'currency', (SELECT code FROM currencies WHERE is_base), 'amount_ccy', 777),
                jsonb_build_object('account_code', '2000', 'side', 'credit', 'currency', (SELECT code FROM currencies WHERE is_base), 'amount_ccy', 777)));
        PERFORM set_config('request.jwt.claims', '', true);
    EXCEPTION WHEN OTHERS THEN
        PERFORM set_config('request.jwt.claims', '', true);
        RAISE NOTICE 'FAIL|C3 setup: the probe manual entry could not be posted → %', SQLERRM;
    END;
    v := pg_temp.fc_call(cf, 'authenticated', 'SELECT list_ledger_reconciliation()::text');
    j := v::jsonb;
    k := (SELECT s ->> 'unexplained_base' FROM jsonb_array_elements(j -> 'sides') s WHERE s ->> 'side' = 'ap');
    IF k::numeric = -777 THEN RAISE NOTICE 'PASS|C3: an unexplained manual entry into 2000 moves the check close_period reads (ap unexplained %)', k;
    ELSE RAISE NOTICE 'FAIL|C3: ap unexplained after injection → %', k; END IF;
    v := pg_temp.fc_call(cf, 'authenticated', format('SELECT close_period(%L::date)::text', (date_trunc('month', CURRENT_DATE) - interval '1 day')::date));
    RAISE NOTICE 'INFO|C3: close_period(last month-end) on live, finance copy → % (an earlier gate may answer first; the refusal itself is pinned by fixture 282)', v;
    IF position('CLOSE_LEDGER_LIST_UNEXPLAINED' IN pg_get_functiondef('public.close_period(date,text)'::regprocedure)) > 0 THEN
        RAISE NOTICE 'PASS|C3: the live close_period carries the ledger-vs-list refusal';
    ELSE RAISE NOTICE 'FAIL|C3: close_period on live has no ledger-vs-list refusal'; END IF;
    RAISE NOTICE 'TX_DONE';
END
$tx$;
ROLLBACK;
`
}

main().catch((e) => {
    console.error(String(e?.stack || e))
    return exitAfterCleanup(String(e?.message || '').startsWith('FINCHAIN1_DRIVER') ? 2 : 1)
})
