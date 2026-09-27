-- 230 TERMS-EDIT-1:合同条款编辑器 —— 条款先填齐,才向 CFO 申请生效;结束了的合同条款不再动(2026-09-27)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】(TERMS-EDIT-1 grilling Q1–Q11,Tim 2026-09-27 全部接受)
--   A  登记:contract_activation_missing 在、是 INVOKER、authenticated 调得到;提交那一支读它
--   B  ★★ 卖方空合同:清单 = {settlement_terms, pricing_terms};申请生效按名拒
--        CONTRACT_TERMS_INCOMPLETE|编号|settlement_terms,pricing_terms,一张申请都不落
--   C  ★★ 逐条填:结算口径(per_metal · per_element)+ 两个计价金属 → 清单 = 两个金属的精炼费 + 惩罚元素;
--        补一个金属的精炼费 → 少一条;补齐 → 空;申请生效 → submitted
--   D  买方合同什么都不要求:空合同清单为空,申请生效照走
--   E  ★ 编辑器的每一种写(七张表 × 增 / 改 / 删 + 表头)cco 在草稿上都写得进;不持 action.contract_terms 的人
--        写不进(RLS / PERMISSION_DENIED),一行不落
--   F  ★★ Q4:到期 / 终止的合同,七张条款表按名拒 CONTRACT_TERMS_FROZEN|编号|expired / terminated;
--        表头的规矩不变(guard_contract_write 只读 'request:')—— 钉住它,免得有人以为这一刀改了它
--   G  清单受 RLS:看不见客户的人读一份卖方合同的清单 → 空(它不替任何人打开任何一行)
--   H  ★ 故障注入:把 contract_activation_missing 换成恒空,缺条款的卖方合同就提得出去 —— 那道拒绝是承重的
--
-- 自带数据(README 第 2 条);锁期自己设(第 4 条)。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '180s';

CREATE FUNCTION pg_temp.f230_try(p_sql text) RETURNS text
LANGUAGE plpgsql AS $f$
BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql;
    EXECUTE 'RESET ROLE';
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    RETURN SQLERRM;
END;
$f$;

CREATE FUNCTION pg_temp.f230_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', p_user), true)
$f$;

-- 以某人的身份读清单
CREATE FUNCTION pg_temp.f230_missing(p_user uuid, p_contract uuid) RETURNS text
LANGUAGE plpgsql AS $f$
DECLARE v text;
BEGIN
    PERFORM pg_temp.f230_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    v := array_to_string(contract_activation_missing(p_contract), ',');
    EXECUTE 'RESET ROLE';
    RETURN v;
END;
$f$;

DO $$
DECLARE
    u_cco  uuid := gen_random_uuid();   -- cco 的形状:action.contract_terms,两侧都看得见
    u_cfo  uuid := gen_random_uuid();   -- 二级
    u_l1   uuid := gen_random_uuid();   -- 一级
    u_ro   uuid := gen_random_uuid();   -- 两侧都看得见、【不】持 action.contract_terms(gm / finance 的形状)
    u_sup  uuid := gen_random_uuid();   -- 只看得见供应商那一侧(仓库的形状)
    r_cco uuid; r_l1 uuid; r_l2 uuid; r_ro uuid; r_sup uuid;
    e_cfo uuid := gen_random_uuid();
    v_sup uuid; v_cust uuid;
    c_sell uuid; c_sell_code text; c_buy uuid; c_end uuid; c_end_code text; c_inj uuid; c_inj_code text;
    v_res jsonb; v_msg text; v_n int; v_id uuid;
    rep jsonb := '{}'::jsonb;
BEGIN
    UPDATE finance_settings SET locked_before = NULL, system_start_date = NULL;

    -- ══════════════ 布景 ══════════════
    INSERT INTO auth.users (id, email_confirmed_at) VALUES
        (u_cco, now()), (u_cfo, now()), (u_l1, now()), (u_ro, now()), (u_sup, now());
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx230-cco','f','f',true) RETURNING id INTO r_cco;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx230-l1','f','f',true)  RETURNING id INTO r_l1;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx230-l2','f','f',true)  RETURNING id INTO r_l2;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx230-ro','f','f',true)  RETURNING id INTO r_ro;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx230-sup','f','f',true) RETURNING id INTO r_sup;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_cco, c FROM unnest(ARRAY['module.pricing.view', 'data.view_prices', 'data.view_purchase_prices',
        'action.contract_terms', 'module.suppliers.view', 'module.customers.view']) c;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r.id, c FROM unnest(ARRAY[r_l1, r_l2]) r(id)
     CROSS JOIN unnest(ARRAY['module.purchasing.view', 'data.view_prices', 'data.view_purchase_prices',
        'module.finance.view', 'module.hr.view', 'data.view_pay', 'module.inbound.view', 'module.sales.view']) c;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_l2, c FROM unnest(ARRAY['module.pricing.view', 'module.suppliers.view', 'module.customers.view']) c;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_ro, c FROM unnest(ARRAY['module.suppliers.view', 'module.customers.view', 'module.suppliers.edit',
        'data.view_prices']) c;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_sup, c FROM unnest(ARRAY['module.suppliers.view', 'data.view_purchase_prices']) c;
    INSERT INTO user_roles (user_id, role_id) VALUES
        (u_cco, r_cco), (u_cfo, r_l2), (u_l1, r_l1), (u_ro, r_ro), (u_sup, r_sup);
    INSERT INTO employees (id, code, legal_name, employment_type, work_category, hire_date, user_id)
    VALUES (e_cfo, 'FX230-CFO', 'FX230 CFO', 'full_time', 'office', CURRENT_DATE - 400, u_cfo);

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZFIX230-S', 'fixture 230 supplier', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO customers (code, legal_name, country)
    VALUES ('ZZFIX230-C', 'fixture 230 customer', 'SG') RETURNING id INTO v_cust;

    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approval_level1_role_code = 'fx230-l1', approval_level2_role_code = 'fx230-l2',
                                approval_threshold_base = 1000;
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = true;

    -- ══════════════ A · 登记 ══════════════
    IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                    WHERE n.nspname = 'public' AND p.proname = 'contract_activation_missing' AND NOT p.prosecdef) THEN
        RAISE EXCEPTION 'FIXTURE 230A1 失败:contract_activation_missing 应当存在且是 SECURITY INVOKER'; END IF;
    IF NOT has_function_privilege('authenticated', 'public.contract_activation_missing(uuid)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'FIXTURE 230A2 失败:详情页以调用者身份读清单,authenticated 必须调得到'; END IF;
    IF position('contract_activation_missing(' IN
               (SELECT prosrc FROM pg_proc WHERE proname = 'terms_request_submit_internal')) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 230A3 失败:提交那一支没有读清单'; END IF;
    rep := rep || jsonb_build_object('A_registered', true);

    -- ══════════════ B · 卖方空合同 ══════════════
    PERFORM pg_temp.f230_as(u_cco);
    EXECUTE 'SET LOCAL ROLE authenticated';
    INSERT INTO contracts (customer_id, kind, title, effective_from, status)
    VALUES (v_cust, 'offtake', 'f230 sell', CURRENT_DATE, 'draft') RETURNING id, code INTO c_sell, c_sell_code;
    EXECUTE 'RESET ROLE';
    v_msg := pg_temp.f230_missing(u_cco, c_sell);
    IF v_msg <> 'settlement_terms,pricing_terms' THEN
        RAISE EXCEPTION 'FIXTURE 230B1 失败:空的卖方合同缺结算口径与计价条款,实得 %', v_msg; END IF;
    PERFORM pg_temp.f230_as(u_cco);
    v_msg := pg_temp.f230_try(format($s$SELECT submit_contract_activation_request(%L, 'f230 B')$s$, c_sell));
    IF v_msg <> 'CONTRACT_TERMS_INCOMPLETE|' || c_sell_code || '|settlement_terms,pricing_terms' THEN
        RAISE EXCEPTION 'FIXTURE 230B2 失败:缺条款的卖方合同申请生效应当按名拒,实得 %', v_msg; END IF;
    IF EXISTS (SELECT 1 FROM terms_requests WHERE contract_id = c_sell) THEN
        RAISE EXCEPTION 'FIXTURE 230B3 失败:被拒的申请不应当落下一行'; END IF;
    rep := rep || jsonb_build_object('B_incomplete_refused', true);

    -- ══════════════ C · 逐条填齐 ══════════════
    PERFORM pg_temp.f230_as(u_cco);
    EXECUTE 'SET LOCAL ROLE authenticated';
    INSERT INTO contract_settlement_terms (contract_id, sale_weight_basis, settling_party, splitting_limit_pct,
        sample_retention_required, sample_retention_days, refining_charge_basis, penalty_basis)
    VALUES (c_sell, 'dry', 'ours', 0.5, true, 90, 'per_metal', 'per_element');
    INSERT INTO contract_pricing_terms (contract_id, metal, base_event, qp_months, index_code, payable_pct)
    VALUES (c_sell, 'ni', 'shipment', 1, 'LME', 90), (c_sell, 'co', 'arrival', 2, 'SMM', 85);
    EXECUTE 'RESET ROLE';
    v_msg := pg_temp.f230_missing(u_cco, c_sell);
    IF v_msg <> 'refining_charge:co,refining_charge:ni,penalty_elements' THEN
        RAISE EXCEPTION 'FIXTURE 230C1 失败:声明了 per_metal / per_element 却没填,清单应当逐个金属说出来,实得 %', v_msg; END IF;
    PERFORM pg_temp.f230_as(u_cco);
    EXECUTE 'SET LOCAL ROLE authenticated';
    INSERT INTO contract_refining_charges (contract_id, metal, usd_per_tonne_of_metal) VALUES (c_sell, 'ni', 1500);
    EXECUTE 'RESET ROLE';
    v_msg := pg_temp.f230_missing(u_cco, c_sell);
    IF v_msg <> 'refining_charge:co,penalty_elements' THEN
        RAISE EXCEPTION 'FIXTURE 230C2 失败:补了镍的精炼费之后应当只剩钴与惩罚,实得 %', v_msg; END IF;
    PERFORM pg_temp.f230_as(u_cco);
    EXECUTE 'SET LOCAL ROLE authenticated';
    INSERT INTO contract_refining_charges (contract_id, metal, usd_per_tonne_of_metal) VALUES (c_sell, 'co', 1200);
    INSERT INTO contract_penalty_elements (contract_id, substance, threshold_pct, usd_per_tonne_per_pct_over)
    VALUES (c_sell, 'cu', 0.5, 3);
    EXECUTE 'RESET ROLE';
    v_msg := pg_temp.f230_missing(u_cco, c_sell);
    IF v_msg <> '' THEN
        RAISE EXCEPTION 'FIXTURE 230C3 失败:填齐之后清单应当为空,实得 %', v_msg; END IF;
    PERFORM pg_temp.f230_as(u_cco);
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_res := submit_contract_activation_request(c_sell, 'f230 C');
    EXECUTE 'RESET ROLE';
    IF v_res->>'status' <> 'submitted' THEN
        RAISE EXCEPTION 'FIXTURE 230C4 失败:填齐的卖方合同申请生效应当 submitted,实得 %', v_res; END IF;
    PERFORM pg_temp.f230_as(u_cco);
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM withdraw_terms_request((v_res->>'request_id')::uuid);
    EXECUTE 'RESET ROLE';
    rep := rep || jsonb_build_object('C_filled_then_submitted', true);

    -- ══════════════ D · 买方合同什么都不要求 ══════════════
    PERFORM pg_temp.f230_as(u_cco);
    EXECUTE 'SET LOCAL ROLE authenticated';
    INSERT INTO contracts (supplier_id, kind, title, effective_from, status)
    VALUES (v_sup, 'supply', 'f230 buy', CURRENT_DATE, 'draft') RETURNING id INTO c_buy;
    EXECUTE 'RESET ROLE';
    v_msg := pg_temp.f230_missing(u_cco, c_buy);
    IF v_msg <> '' THEN
        RAISE EXCEPTION 'FIXTURE 230D1 失败:买方合同的清单应当为空,实得 %', v_msg; END IF;
    PERFORM pg_temp.f230_as(u_cco);
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_res := submit_contract_activation_request(c_buy, 'f230 D');
    PERFORM withdraw_terms_request((v_res->>'request_id')::uuid);
    EXECUTE 'RESET ROLE';
    IF v_res->>'status' <> 'submitted' THEN
        RAISE EXCEPTION 'FIXTURE 230D2 失败:买方空合同申请生效应当照走,实得 %', v_res; END IF;
    rep := rep || jsonb_build_object('D_buy_side_requires_nothing', true);

    -- ══════════════ E · 编辑器的每一种写 ══════════════
    -- cco 在草稿上:七张表各 增 → 改 → 删,表头改一格
    PERFORM pg_temp.f230_as(u_cco);
    FOR v_msg IN SELECT unnest(ARRAY[
        format($s$INSERT INTO contract_grade_specs (contract_id, metal, min_pct) VALUES (%L, 'ni', 18)$s$, c_buy),
        format($s$UPDATE contract_grade_specs SET max_pct = 25 WHERE contract_id = %L$s$, c_buy),
        format($s$DELETE FROM contract_grade_specs WHERE contract_id = %L$s$, c_buy),
        format($s$INSERT INTO contract_insurance_obligations (contract_id, insured_by, cover_type, min_amount, currency) VALUES (%L, 'counterparty', 'cargo', 100000, 'USD')$s$, c_buy),
        format($s$UPDATE contract_insurance_obligations SET min_amount = 200000 WHERE contract_id = %L$s$, c_buy),
        format($s$DELETE FROM contract_insurance_obligations WHERE contract_id = %L$s$, c_buy),
        format($s$INSERT INTO contract_volume_commitments (contract_id, committed_by_party, quantity, unit, period) VALUES (%L, 'counterparty', 200, 't', 'month')$s$, c_buy),
        format($s$UPDATE contract_volume_commitments SET quantity = 250 WHERE contract_id = %L$s$, c_buy),
        format($s$DELETE FROM contract_volume_commitments WHERE contract_id = %L$s$, c_buy),
        format($s$UPDATE contract_pricing_terms SET payable_pct = 91 WHERE contract_id = %L AND metal = 'ni'$s$, c_sell),
        format($s$UPDATE contract_settlement_terms SET splitting_limit_pct = 0.6 WHERE contract_id = %L$s$, c_sell),
        format($s$UPDATE contract_refining_charges SET usd_per_tonne_of_metal = 1600 WHERE contract_id = %L AND metal = 'ni'$s$, c_sell),
        format($s$UPDATE contract_penalty_elements SET threshold_pct = 0.4 WHERE contract_id = %L$s$, c_sell),
        format($s$UPDATE contracts SET title = 'f230 sell (edited)', incoterm = 'CIF' WHERE id = %L$s$, c_sell)]) LOOP
        v_res := to_jsonb(pg_temp.f230_try(v_msg));
        IF v_res #>> '{}' <> 'OK' THEN
            RAISE EXCEPTION 'FIXTURE 230E1 失败:cco 在草稿上的这一次写应当成功:% → %', v_msg, v_res #>> '{}'; END IF;
    END LOOP;
    -- 删掉再加回(删那一支单独跑一次,读回行数)
    PERFORM pg_temp.f230_as(u_cco);
    v_msg := pg_temp.f230_try(format($s$DELETE FROM contract_penalty_elements WHERE contract_id = %L$s$, c_sell));
    IF v_msg <> 'OK' OR EXISTS (SELECT 1 FROM contract_penalty_elements WHERE contract_id = c_sell) THEN
        RAISE EXCEPTION 'FIXTURE 230E2 失败:cco 删一行惩罚元素应当删得掉,实得 %', v_msg; END IF;
    IF pg_temp.f230_missing(u_cco, c_sell) <> 'penalty_elements' THEN
        RAISE EXCEPTION 'FIXTURE 230E3 失败:删掉惩罚元素之后清单应当重新说出它'; END IF;
    -- 不持 action.contract_terms 的人:加一行、改一行、改表头 —— 都写不进,一行不落
    PERFORM pg_temp.f230_as(u_ro);
    v_msg := pg_temp.f230_try(format($s$INSERT INTO contract_penalty_elements (contract_id, substance, threshold_pct, usd_per_tonne_per_pct_over) VALUES (%L, 'fe', 1, 1)$s$, c_sell));
    IF v_msg = 'OK' OR EXISTS (SELECT 1 FROM contract_penalty_elements WHERE contract_id = c_sell) THEN
        RAISE EXCEPTION 'FIXTURE 230E4 失败:不持码的人加条款应当被拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f230_try(format($s$UPDATE contract_pricing_terms SET payable_pct = 50 WHERE contract_id = %L$s$, c_sell));
    IF v_msg = 'OK' AND EXISTS (SELECT 1 FROM contract_pricing_terms WHERE contract_id = c_sell AND payable_pct = 50) THEN
        RAISE EXCEPTION 'FIXTURE 230E5 失败:不持码的人改条款改进去了'; END IF;
    IF v_msg <> 'PERMISSION_DENIED|action.contract_terms' THEN
        RAISE EXCEPTION 'FIXTURE 230E6 失败:不持码的人改条款应当按码拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f230_try(format($s$UPDATE contracts SET title = 'x' WHERE id = %L$s$, c_sell));
    IF v_msg <> 'PERMISSION_DENIED|action.contract_terms' THEN
        RAISE EXCEPTION 'FIXTURE 230E7 失败:不持码的人改表头应当按码拒,实得 %', v_msg; END IF;
    rep := rep || jsonb_build_object('E_every_editor_write', true);

    -- ══════════════ F · Q4:结束了的合同 ══════════════
    PERFORM pg_temp.f230_as(u_cco);
    EXECUTE 'SET LOCAL ROLE authenticated';
    INSERT INTO contracts (supplier_id, kind, title, effective_from, status)
    VALUES (v_sup, 'supply', 'f230 ended', CURRENT_DATE, 'draft') RETURNING id, code INTO c_end, c_end_code;
    INSERT INTO contract_grade_specs (contract_id, metal, min_pct) VALUES (c_end, 'ni', 18);
    UPDATE contracts SET status = 'expired' WHERE id = c_end;
    EXECUTE 'RESET ROLE';
    v_msg := pg_temp.f230_try(format($s$INSERT INTO contract_volume_commitments (contract_id, committed_by_party, quantity, unit, period) VALUES (%L, 'counterparty', 1, 't', 'total')$s$, c_end));
    IF v_msg <> 'CONTRACT_TERMS_FROZEN|' || c_end_code || '|expired' THEN
        RAISE EXCEPTION 'FIXTURE 230F1 失败:到期合同加条款应当按名拒 expired,实得 %', v_msg; END IF;
    v_msg := pg_temp.f230_try(format($s$UPDATE contract_grade_specs SET min_pct = 19 WHERE contract_id = %L$s$, c_end));
    IF v_msg <> 'CONTRACT_TERMS_FROZEN|' || c_end_code || '|expired' THEN
        RAISE EXCEPTION 'FIXTURE 230F2 失败:到期合同改条款应当按名拒 expired,实得 %', v_msg; END IF;
    v_msg := pg_temp.f230_try(format($s$UPDATE contracts SET status = 'terminated' WHERE id = %L$s$, c_end));
    IF v_msg <> 'OK' THEN
        RAISE EXCEPTION 'FIXTURE 230F3 失败:表头的规矩这一刀没动 —— 到期改终止应当照走,实得 %', v_msg; END IF;
    v_msg := pg_temp.f230_try(format($s$DELETE FROM contract_grade_specs WHERE contract_id = %L$s$, c_end));
    IF v_msg <> 'CONTRACT_TERMS_FROZEN|' || c_end_code || '|terminated'
       OR NOT EXISTS (SELECT 1 FROM contract_grade_specs WHERE contract_id = c_end) THEN
        RAISE EXCEPTION 'FIXTURE 230F4 失败:终止合同删条款应当按名拒 terminated,实得 %', v_msg; END IF;
    IF contract_terms_lock_reason(c_buy) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 230F5 失败:草稿不该被锁'; END IF;
    rep := rep || jsonb_build_object('F_ended_contracts_frozen', true);

    -- ══════════════ G · 清单受 RLS ══════════════
    IF pg_temp.f230_missing(u_sup, c_sell) <> '' THEN
        RAISE EXCEPTION 'FIXTURE 230G 失败:看不见客户那一侧的人读卖方合同的清单应当读到空'; END IF;
    rep := rep || jsonb_build_object('G_checklist_reads_as_the_caller', true);

    -- ══════════════ H · 故障注入 ══════════════
    PERFORM pg_temp.f230_as(u_cco);
    EXECUTE 'SET LOCAL ROLE authenticated';
    INSERT INTO contracts (customer_id, kind, title, effective_from, status)
    VALUES (v_cust, 'offtake', 'f230 inject', CURRENT_DATE, 'draft') RETURNING id, code INTO c_inj, c_inj_code;
    EXECUTE 'RESET ROLE';
    CREATE OR REPLACE FUNCTION public.contract_activation_missing(p_contract_id uuid)
     RETURNS text[] LANGUAGE sql STABLE SET search_path TO 'public', 'pg_temp'
    AS $inj$ SELECT ARRAY[]::text[] $inj$;
    PERFORM pg_temp.f230_as(u_cco);
    v_msg := pg_temp.f230_try(format($s$SELECT submit_contract_activation_request(%L, 'f230 H')$s$, c_inj));
    IF v_msg <> 'OK' OR NOT EXISTS (SELECT 1 FROM terms_requests WHERE contract_id = c_inj AND status = 'submitted') THEN
        RAISE EXCEPTION 'FIXTURE 230H 失败:清单恒空时缺条款的卖方合同应当提得出去(证明那道拒绝读的就是它),实得 %', v_msg; END IF;
    rep := rep || jsonb_build_object('H_checklist_is_load_bearing', true);

    RAISE NOTICE 'FIXTURE 230 全部通过:A 登记 · B 缺条款按名拒 · C 逐条填齐 · D 买方不要求 · E 编辑器的每一种写 · F 结束了的合同冻结 · G 清单受 RLS · H 注入 %', rep::text;
END;
$$;
ROLLBACK;
