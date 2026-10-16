#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// MES-7a-2(2026-10-16)· 线上验证 —— 备件出给保养(借 6800 / 贷 1200)、带理由退回、改价时出给保养那一份进 6800、质量暂扣挡出库不挡退回
//   一笔【回滚】的事务;不碰任何桶
// ════════════════════════════════════════════════════════════════════════════
// 【形状】一支 psql,一笔事务从 BEGIN 开到 ROLLBACK(ON_ERROR_STOP:任何一步红,事务中止、连接关掉,等于回滚)。每一步以一次性账号的
//   身份跑:先 set_config('request.jwt.claims') 再 SET LOCAL ROLE authenticated —— 与员工在应用里按按钮走同一扇门(RLS 与 require_permission)。
//   拒绝在子事务里试(BEGIN … EXCEPTION),不打断整笔。
// 【身份】每一个动作都以一次性账号跑(前缀 mes7a2probe),七个真账号一个都不用:
//   inv  = 收货、记保养、出 / 退备件、开不合格报告(库存 · 加工 · 进料 · 质量的码,看得见价格)
//   c_<角色> = 七个真账号此刻持有的七个角色的码的克隆(cloneOf,只读;c_cfo 读两条勾稽 —— 那两支函数按读者的码过滤)
// 【定价走引擎,不走那扇门】审批开着时,定价(收货带价 · 定价面板)提一张 CFO 申请,不当场过账;而本证明要证的是【过账】那一侧
//   (改价时出给保养那一份进 6800)。所以给这一批定价、改价都直接调 reprice_inbound_batch —— 每一扇定价的门最后都落进这一支引擎
//   (那扇门本身本刀一个字没改)。它的 EXECUTE 不给 authenticated,所以这一句以属主身份调,JWT 仍是 inv 的(引擎自己问 data.view_purchase_prices)。
//   与 MES-7a-1 的"已提交的加工单以属主身份插"是同一种处置(它不是被证的那条路)。
// 【布景】都是我自己的行(前缀 ZZ-PROBE-MES7A2),在事务里插,随回滚消失。在册的东西一行都不改、不决定、不删。
// 【判决】只从日志里最后那一行 `MES7A2_PROOF_EXIT=` 读。0 = 走完、回滚、一次性账号收干净 · 1 = 证明红了 · 2 = 驱动自己坏了 ·
//   5 = live-lock 被占 · 6 = 收尾没完成。
// 用法:node db/scripts/2026-10-16-mes7a2-live-proof.mjs > <log> 2>&1
// ════════════════════════════════════════════════════════════════════════════
import { onlyWhenRunDirectly } from '../../scripts/lib/entrypoint.mjs'
import { spawnSync } from 'node:child_process'
import { acquireOrExit, release, heldBy } from '../../scripts/liveLock.mjs'
import { openPlan, mintThrowaway, reapStalePlans, installExitHooks, exitAfterCleanup } from '../../scripts/ephemeral.mjs'

onlyWhenRunDirectly(import.meta.url)

const DSN = process.env.CHECK_MIRRORS_DSN || 'host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 user=postgres.wvywpohbwkiinmipmuku dbname=postgres'
const ROLES = ['admin', 'cfo', 'finance', 'warehouse', 'cto', 'cco', 'gm']   // 七个真账号此刻各持一个角色(开场读数)

let locked = false
installExitHooks({
    onFinish: (code) => {
        try { if (locked) release() } catch { /* 放锁失败不改判决 */ }
        console.log(`MES7A2_PROOF_EXIT=${code}`)
    },
})

const lit = (s) => `'${String(s).replace(/'/g, "''")}'`

function proofSql(u) {
    const roleArms = ROLES.map((r) => `
    -- ── 角色 ${r}(克隆 ${u['c_' + r]})──
    v_rows := pg_temp.p_count(${lit(u['c_' + r])}, format('SELECT count(*) FROM maintenance_part_issues WHERE maintenance_id = %L', m_ok));
    v_roll := pg_temp.p_count(${lit(u['c_' + r])}, $q$SELECT count(*) FROM stock_rollforward_monthly WHERE unit = 'pcs'$q$);
    v_acct := pg_temp.p_count(${lit(u['c_' + r])}, $q$SELECT count(*) FROM accounts WHERE code = '6800'$q$);
    v_v21  := pg_temp.p_count(${lit(u['c_' + r])}, format('SELECT count(*) FROM pending_values WHERE value_code = %L AND item_id = %L', 'V21', mat));
    v_stock := pg_temp.p_count(${lit(u['c_' + r])}, format('SELECT count(*) FROM spare_part_stock WHERE inbound_batch_id = %L', ib_p));
    v_msg  := pg_temp.p_try(${lit(u['c_' + r])}, format($q$SELECT issue_spare_parts(%L, %L, '[{"inbound_batch_id": "%s", "quantity": 1}]'::jsonb)$q$, m_ok, d, ib_p));
    RAISE NOTICE 'ROLE|${r}|codes=%|parts rows seen=%|roll-forward rows=%|6800 seen=%|V21 rows=%|spare stock rows=%|issue=%',
        (SELECT count(*) FROM role_permissions rp JOIN user_roles ur ON ur.role_id = rp.role_id WHERE ur.user_id = ${lit(u['c_' + r])} AND ur.revoked_at IS NULL),
        v_rows, v_roll, v_acct, v_v21, v_stock, left(v_msg, 70);`).join('\n')

    return `\\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL statement_timeout = '300s';

CREATE FUNCTION pg_temp.p_as(p_user uuid) RETURNS void LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims', CASE WHEN p_user IS NULL THEN '' ELSE format('{"sub":"%s","role":"authenticated"}', p_user) END, true)
$f$;
-- 以某人的身份(authenticated + 那人的 JWT)跑一句,返回 jsonb;错误照抛
CREATE FUNCTION pg_temp.p_get(p_user uuid, p_sql text) RETURNS jsonb LANGUAGE plpgsql AS $f$
DECLARE v jsonb;
BEGIN
    PERFORM pg_temp.p_as(p_user); EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE'; PERFORM pg_temp.p_as(NULL);
    RETURN v;
EXCEPTION WHEN OTHERS THEN EXECUTE 'RESET ROLE'; PERFORM pg_temp.p_as(NULL); RAISE;
END $f$;
CREATE FUNCTION pg_temp.p_count(p_user uuid, p_sql text) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE v bigint;
BEGIN
    PERFORM pg_temp.p_as(p_user); EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE'; PERFORM pg_temp.p_as(NULL);
    RETURN v;
EXCEPTION WHEN OTHERS THEN EXECUTE 'RESET ROLE'; PERFORM pg_temp.p_as(NULL); RETURN -1;
END $f$;
-- 在一个子事务里试一句;返回 'OK' 或那一句的错误。成了也撤回(子事务以 RAISE 结束)—— 角色表那一段只问"按不按得下去"
CREATE FUNCTION pg_temp.p_try(p_user uuid, p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
BEGIN
    BEGIN
        PERFORM pg_temp.p_as(p_user); EXECUTE 'SET LOCAL ROLE authenticated';
        EXECUTE p_sql;
        RAISE EXCEPTION 'P_TRY_OK';
    EXCEPTION WHEN OTHERS THEN
        EXECUTE 'RESET ROLE'; PERFORM pg_temp.p_as(NULL);
        RETURN CASE WHEN SQLERRM = 'P_TRY_OK' THEN 'OK' ELSE SQLERRM END;
    END;
END $f$;
-- 一张分录的行,写成 "科目:借:贷,…"
CREATE FUNCTION pg_temp.p_lines(p_je uuid) RETURNS text LANGUAGE sql AS $f$
    SELECT string_agg(a.code || ':' || l.debit::numeric(14,2) || ':' || l.credit::numeric(14,2), ',' ORDER BY a.code)
      FROM journal_lines l JOIN accounts a ON a.id = l.account_id WHERE l.entry_id = p_je
$f$;
-- 两条勾稽(以 cfo 的克隆读 —— 两支函数按读者的码过滤):应付 / 应收清单 = 总账,未解释 0.00;存货控制科目对得上
CREATE FUNCTION pg_temp.p_recon(p_step text) RETURNS void LANGUAGE plpgsql AS $f$
DECLARE v jsonb; s jsonb; txt text := '';
BEGIN
    v := pg_temp.p_get(${lit(u.c_cfo)}, 'SELECT list_ledger_reconciliation()');
    FOR s IN SELECT * FROM jsonb_array_elements(v -> 'sides') LOOP
        txt := txt || (s ->> 'side') || ' ' || (s ->> 'list_base') || ' / ' || (s ->> 'ledger_base') || ' / ' || (s ->> 'unexplained_base') || ' · ';
        IF (s ->> 'unexplained_base')::numeric <> 0 THEN RAISE EXCEPTION 'MES7A2_LIVE|RECON % % list ≠ ledger %', p_step, s ->> 'side', s; END IF;
    END LOOP;
    v := pg_temp.p_get(${lit(u.c_cfo)}, 'SELECT gl_control_reconciliation(CURRENT_DATE)');
    FOR s IN SELECT x FROM jsonb_array_elements(v -> 'sides') x WHERE x ->> 'side' LIKE 'inventory%' LOOP
        txt := txt || (s ->> 'side') || ' ' || (s ->> 'ledger_base') || ' / ' || (s ->> 'subledger_base') || ' / ' || (s ->> 'unexplained_base') || ' · ';
        IF (s ->> 'unexplained_base')::numeric <> 0 OR NOT (s ->> 'reconciled')::boolean THEN
            RAISE EXCEPTION 'MES7A2_LIVE|RECON % inventory control % not reconciled %', p_step, s ->> 'side', s; END IF;
    END LOOP;
    RAISE NOTICE 'STEP|recon %|%', p_step, txt;
END $f$;

DO $proof$
DECLARE
    inv uuid := ${lit(u.inv)};
    v_base text; d date := (now() AT TIME ZONE 'Asia/Singapore')::date - 2;
    sup uuid; mat uuid; fa uuid; m_ok uuid; m_cap uuid; ib_p uuid; ib_u uuid; iss uuid; ret uuid; je uuid;
    v_j jsonb; v_msg text; v_x numeric; v_rows bigint; v_roll bigint; v_acct bigint; v_v21 bigint; v_stock bigint;
BEGIN
    RAISE NOTICE 'STEP|who|%|bypassrls=%', current_user, (SELECT rolbypassrls FROM pg_roles WHERE rolname = current_user);
    SELECT code INTO v_base FROM currencies WHERE is_base;
    IF EXISTS (SELECT 1 FROM materials WHERE code LIKE 'ZZ-PROBE-MES7A2%') THEN RAISE EXCEPTION 'MES7A2_LIVE|probe rows already exist'; END IF;
    PERFORM pg_temp.p_recon('before anything');

    -- ── 布景(属主插,我自己的行):供应商 · 一种备件物料 · 一台机器 ──
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ-PROBE-MES7A2-S', 'ZZ probe spares vendor', 'SG', 'active', 'goods_supplier') RETURNING id INTO sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, unit)
    VALUES ('ZZ-PROBE-MES7A2-SP', 'ZZ probe shredder blade', 'spare_part', false, 'pcs') RETURNING id INTO mat;
    INSERT INTO fixed_assets (code, description, category, acquisition_date, cost_ccy, currency, fx_rate, cost_base, useful_life_months, residual_base)
    VALUES ('ZZ-PROBE-MES7A2-M', 'ZZ probe shredder', 'equipment', d - 60, 0, v_base, 1, 0, 60, 0) RETURNING id INTO fa;

    -- ── 两批备件:一批定了价(暂定价),一批没定价 —— 收货经 create_inbound_batch(inv 的身份),定价经引擎(见抬头)──
    ib_p := (pg_temp.p_get(inv, format($q$SELECT create_inbound_batch(%L, %L, 10, 'pcs', %L, '待加工', p_source_reason_code => 'other', p_source_reason_note => 'ZZ probe priced')$q$, mat, sup, d)) ->> 'batch_id')::uuid;
    ib_u := (pg_temp.p_get(inv, format($q$SELECT create_inbound_batch(%L, %L, 5, 'pcs', %L, '待加工', p_source_reason_code => 'other', p_source_reason_note => 'ZZ probe unpriced')$q$, mat, sup, d)) ->> 'batch_id')::uuid;
    PERFORM pg_temp.p_as(inv);
    PERFORM reprice_inbound_batch(ib_p, 5, v_base, NULL, 'ZZ probe first price');
    PERFORM pg_temp.p_as(NULL);
    RAISE NOTICE 'STEP|receipts|priced % pricing_status=% landed=% · unpriced % unit_price=%', (SELECT code FROM inbound_batches WHERE id = ib_p),
        (SELECT pricing_status FROM inbound_batches WHERE id = ib_p), inbound_batch_landed_unit_cost_all(ib_p),
        (SELECT code FROM inbound_batches WHERE id = ib_u), COALESCE((SELECT unit_price::text FROM inbound_batches WHERE id = ib_u), 'NULL');
    PERFORM pg_temp.p_recon('after the receipts and the first price');

    -- ── 两条保养记录:一条普通的修理,一条资本化的大修 ──
    m_ok := (pg_temp.p_get(inv, format($q$SELECT record_equipment_maintenance(p_equipment_id => %L, p_performed_on => %L, p_kind => 'repair', p_description => 'ZZ probe replace the blade', p_performed_by_name => 'Probe')$q$, fa, d)) ->> 'maintenance_id')::uuid;
    m_cap := (pg_temp.p_get(inv, format($q$SELECT record_equipment_maintenance(p_equipment_id => %L, p_performed_on => %L, p_kind => 'repair', p_description => 'ZZ probe overhaul', p_performed_by_name => 'Probe', p_capitalised => true, p_capitalisation_reason => 'ZZ probe extends life')$q$, fa, d)) ->> 'maintenance_id')::uuid;

    -- ── 出 4 件:借 6800 / 贷 1200 = 4 × 落地单价 ──
    v_x := inbound_batch_landed_unit_cost_all(ib_p);
    v_j := pg_temp.p_get(inv, format($q$SELECT issue_spare_parts(%L, %L, '[{"inbound_batch_id": "%s", "quantity": 4}]'::jsonb)$q$, m_ok, d, ib_p));
    iss := (v_j -> 'lines' -> 0 ->> 'issue_id')::uuid;
    SELECT journal_entry_id INTO je FROM maintenance_part_issues WHERE id = iss;
    IF pg_temp.p_lines(je) IS DISTINCT FROM ('1200:0.00:' || round(4 * v_x, 2) || ',6800:' || round(4 * v_x, 2) || ':0.00')
       OR (SELECT source_type FROM journal_entries WHERE id = je) <> 'maintenance_part' THEN
        RAISE EXCEPTION 'MES7A2_LIVE|issue posting %', pg_temp.p_lines(je); END IF;
    RAISE NOTICE 'STEP|issue 4|% · entry % · %|remaining %', v_j -> 'lines' -> 0 ->> 'batch_code', v_j -> 'lines' -> 0 ->> 'journal_code', pg_temp.p_lines(je),
        (SELECT remaining_qty FROM inbound_batches WHERE id = ib_p);
    PERFORM pg_temp.p_recon('after the issue');

    -- ── 退 1 件,带理由:借 1200 / 贷 6800 ──
    v_j := pg_temp.p_get(inv, format($q$SELECT return_spare_parts(%L, 1, %L, 'ZZ probe: one blade was not needed')$q$, iss, d));
    ret := (v_j ->> 'return_id')::uuid;
    SELECT journal_entry_id INTO je FROM maintenance_part_issues WHERE id = ret;
    IF pg_temp.p_lines(je) IS DISTINCT FROM ('1200:' || round(v_x, 2) || ':0.00,6800:0.00:' || round(v_x, 2))
       OR (SELECT returns_issue_id FROM maintenance_part_issues WHERE id = ret) IS DISTINCT FROM iss THEN
        RAISE EXCEPTION 'MES7A2_LIVE|return posting %', pg_temp.p_lines(je); END IF;
    RAISE NOTICE 'STEP|return 1|entry % · %|cites the issue|reason "%"', v_j ->> 'journal_code', pg_temp.p_lines(je),
        (SELECT reason FROM maintenance_part_issues WHERE id = ret);
    PERFORM pg_temp.p_recon('after the return');

    -- ── 拒:没定价的批 · 资本化了的记录 · 把出过件的记录资本化 · 一次没有理由的退回 ──
    v_msg := pg_temp.p_try(inv, format($q$SELECT issue_spare_parts(%L, %L, '[{"inbound_batch_id": "%s", "quantity": 1}]'::jsonb)$q$, m_ok, d, ib_u));
    IF v_msg NOT LIKE 'SPARE_PART_UNPRICED|%' THEN RAISE EXCEPTION 'MES7A2_LIVE|unpriced got %', v_msg; END IF;
    RAISE NOTICE 'STEP|refused|unpriced batch|%', v_msg;
    v_msg := pg_temp.p_try(inv, format($q$SELECT issue_spare_parts(%L, %L, '[{"inbound_batch_id": "%s", "quantity": 1}]'::jsonb)$q$, m_cap, d, ib_p));
    IF v_msg NOT LIKE 'PART_ISSUE_CAPITALISED|%' THEN RAISE EXCEPTION 'MES7A2_LIVE|capitalised got %', v_msg; END IF;
    RAISE NOTICE 'STEP|refused|capitalised record|%', v_msg;
    BEGIN
        UPDATE equipment_maintenance SET capitalised = true, capitalisation_reason = 'ZZ probe late judgement' WHERE id = m_ok;
        RAISE EXCEPTION 'MES7A2_LIVE|a record with parts was capitalised';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'MAINTENANCE_HAS_PARTS|%' THEN RAISE EXCEPTION 'MES7A2_LIVE|capitalise got %', SQLERRM; END IF;
        RAISE NOTICE 'STEP|refused|capitalising the record with parts|%', SQLERRM;
    END;
    v_msg := pg_temp.p_try(inv, format($q$SELECT return_spare_parts(%L, 1, %L, '  ')$q$, iss, d));
    IF v_msg NOT LIKE 'PART_RETURN_REASON_REQUIRED%' THEN RAISE EXCEPTION 'MES7A2_LIVE|reasonless return got %', v_msg; END IF;
    RAISE NOTICE 'STEP|refused|return without a reason|%', v_msg;

    -- ── 改价 5 → 6:在库 7 → 1200,出给保养净 3 → 6800,5000 一分都没有 ──
    PERFORM pg_temp.p_as(inv);
    v_j := reprice_inbound_batch(ib_p, 6, v_base, NULL, 'ZZ probe reprice');
    PERFORM pg_temp.p_as(NULL);
    SELECT id INTO je FROM journal_entries WHERE code = v_j ->> 'journal_code';
    IF pg_temp.p_lines(je) IS DISTINCT FROM '1200:7.00:0.00,2000:0.00:10.00,6800:3.00:0.00' THEN
        RAISE EXCEPTION 'MES7A2_LIVE|reprice posting %', pg_temp.p_lines(je); END IF;
    RAISE NOTICE 'STEP|reprice 5 → 6|entry % · %|maintenance share %', v_j ->> 'journal_code', pg_temp.p_lines(je), v_j ->> 'maintenance_share_usd';
    PERFORM pg_temp.p_recon('after the reprice');

    -- ── 七个角色:读得到什么、按得下去什么(只读;出库那一下在子事务里试,成了也撤回)──
${roleArms}

    -- ── 不合格报告:挡出库,不挡退回 ──
    PERFORM pg_temp.p_get(inv, format($q$SELECT open_ncr('manual', 'ZZ probe chipped blades', p_inbound_batch_id => %L)$q$, ib_p));
    v_msg := pg_temp.p_try(inv, format($q$SELECT issue_spare_parts(%L, %L, '[{"inbound_batch_id": "%s", "quantity": 1}]'::jsonb)$q$, m_ok, d, ib_p));
    IF v_msg NOT LIKE 'QUALITY_HOLD_OPEN|%' THEN RAISE EXCEPTION 'MES7A2_LIVE|hold did not block the issue: %', v_msg; END IF;
    RAISE NOTICE 'STEP|hold|issue refused|%', v_msg;
    PERFORM pg_temp.p_get(inv, format($q$SELECT return_spare_parts(%L, 1, %L, 'ZZ probe: returned while on hold')$q$, iss, d));
    RAISE NOTICE 'STEP|hold|return allowed|remaining %', (SELECT remaining_qty FROM inbound_batches WHERE id = ib_p);
    PERFORM pg_temp.p_recon('after the hold');

    -- ── 库存月度滚动:出给保养那一列 = −净出库;期末 = 这个单位所有批次的剩余量 ──
    v_j := pg_temp.p_get(inv, $q$SELECT jsonb_build_object('issued', sum(issued_to_maintenance),
             'closing', (SELECT closing FROM stock_rollforward_monthly r2 WHERE r2.unit = 'pcs' AND r2.month IS NOT NULL ORDER BY r2.month DESC LIMIT 1))
             FROM stock_rollforward_monthly r WHERE r.unit = 'pcs'$q$);
    IF (v_j ->> 'issued')::numeric <> -2
       OR (v_j ->> 'closing')::numeric IS DISTINCT FROM (SELECT sum(remaining_qty) FROM inbound_batches WHERE unit = 'pcs' AND deleted_at IS NULL)
                                                         + COALESCE((SELECT sum(remaining_qty) FROM output_batches WHERE unit = 'pcs' AND deleted_at IS NULL), 0) THEN
        RAISE EXCEPTION 'MES7A2_LIVE|roll-forward % vs stock %', v_j, (SELECT sum(remaining_qty) FROM inbound_batches WHERE unit = 'pcs' AND deleted_at IS NULL);
    END IF;
    RAISE NOTICE 'STEP|roll-forward|pcs issued to maintenance % · closing % = stock in pcs', v_j ->> 'issued', v_j ->> 'closing';

    RAISE NOTICE 'STEP|done|probe rows in this transaction: materials %, batches %, issues %',
        (SELECT count(*) FROM materials WHERE code LIKE 'ZZ-PROBE-MES7A2%'),
        (SELECT count(*) FROM inbound_batches WHERE material_id = mat), (SELECT count(*) FROM maintenance_part_issues);
END
$proof$;
ROLLBACK;
SELECT 'AFTER|probe materials=' || (SELECT count(*) FROM materials WHERE code LIKE 'ZZ-PROBE-MES7A2%')
    || '|issues=' || (SELECT count(*) FROM maintenance_part_issues)
    || '|maintenance movements=' || (SELECT count(*) FROM inventory_movements WHERE movement_type IN ('maintenance_issue', 'maintenance_return'))
    || '|maintenance_part entries=' || (SELECT count(*) FROM journal_entries WHERE source_type = 'maintenance_part');
`
}

async function main() {
    const other = heldBy(); if (other) { console.error(`live-lock held by ${other.holder}`); return exitAfterCleanup(5) }
    acquireOrExit('2026-10-16-mes7a2-live-proof.mjs', { ownExit: false }); locked = true
    openPlan('db/scripts/2026-10-16-mes7a2-live-proof.mjs'); await reapStalePlans()
    const stamp = Date.now()
    const u = {}
    u.inv = (await mintThrowaway({ prefix: 'mes7a2probe', label: 'inv', stamp, signIn: false,
        codes: ['module.inventory.view', 'module.inventory.edit', 'module.processing.view', 'module.processing.edit', 'module.inbound.view',
                'module.inbound.edit', 'action.receive_goods', 'data.view_purchase_prices', 'data.view_prices', 'module.quality.view',
                'module.quality.edit', 'module.materials.view'] })).userId
    for (const r of ROLES) u['c_' + r] = (await mintThrowaway({ prefix: 'mes7a2probe', label: `cof-${r}`, stamp, signIn: false, codes: { cloneOf: r } })).userId
    console.log(`ACCOUNTS|inv ${u.inv}|${ROLES.map((r) => `${r} ${u['c_' + r]}`).join('|')}`)
    const t0 = Date.now()
    const p = spawnSync('psql', ['-X', '-q', DSN], { input: proofSql(u), encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 })
    for (const line of (p.stderr + p.stdout).split('\n')) {
        const m = line.match(/(STEP\|.*|ROLE\|.*|AFTER\|.*|ERROR:.*|MES7A2_LIVE\|.*)$/)
        if (m) console.log(m[1])
    }
    console.log(`TXN|psql exit ${p.status}|${((Date.now() - t0) / 1000).toFixed(1)} s in the transaction`)
    return exitAfterCleanup(p.status === 0 && !/ERROR:/.test(p.stderr) ? 0 : 1)
}
main().catch((e) => { console.error('✗', e?.stack || e); exitAfterCleanup(2) })
