-- 227 APR-8:合同条款与定价公式 —— cco 提,CFO 批每一张,批准之前什么都不生效(2026-09-26)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】(APR-8 grilling Q1–Q11,Tim 2026-09-26 全部接受)
--   A  登记:链的名册只有二级一行,门 = pricing.view + view_prices + view_purchase_prices + suppliers.view +
--        customers.view;在途清单一支(blocks_disable、fixed_level 2);operations_now 一支;内层算子 authenticated
--        调不到;公式两张表一条写策略都没有;三组守卫挂上
--   B  ★★ 新公式(审批开着):cco 提 → 公式停用着、申请 submitted、留痕 submitted 二级;批准之前读公式的那一支
--        (pricing_terms_of_formula —— 计价器、建采购单、应用化验都经它)按名拒 FORMULA_INACTIVE;
--        在途时关不了审批;CFO 批 → 启用,留痕 approved 二级
--   C  ★★ 直连写按名拒:cco 直连 INSERT / UPDATE(零行也拒)/ DELETE 公式与比例 → PRICING_FORMULA_THROUGH_REQUEST_ONLY;
--        不持码的人 UPDATE → PERMISSION_DENIED|module.pricing.edit;不持码的人提 → 同一句
--   D  批不了 / 提不了:提单人自己批 → SELF_APPROVAL_FORBIDDEN|raiser;一级 → APPROVAL_NOT_AUTHORISED|2;
--        驳回不给理由 → …REJECT_REASON_REQUIRED;没有理由 → …REASON_REQUIRED;一模一样的条款 → TERMS_REQUEST_NO_CHANGE;
--        ★ CFO 那个人的另一个账号(cco 角色)提 → TERMS_REQUEST_NO_OTHER_DECIDER,一行不落
--   E  ★★ 改在用的公式:等待期间读到的仍是旧条款;第二张 → TERMS_REQUEST_OPEN;停用 / 删除 → TERMS_REQUEST_OPEN;
--        CFO 批 → 就地替换(新比例、删掉的金属不再计价),pricing_formula_history 记下来;snapshot 的 current / proposed /
--        last_approved 是对的
--   F  ★ fingerprint:等待期间属主路径改了公式 → 批准按名拒 TERMS_CHANGED_SINCE_REQUEST,申请仍在等;提单人撤回,
--        撤回不写留痕
--   G  停用一步;重新启用要经 CFO:驳回(带理由)→ 仍停用;再提 → 批 → 启用
--   H  ★★ 合同:直连建一份生效的 → CONTRACT_ACTIVATES_THROUGH_REQUEST;建草稿、写条款照走;直连改成 active → 同一句;
--        提生效 → 等待中条款 CONTRACT_TERMS_FROZEN、表头 TERMS_REQUEST_FREEZES_CONTRACT;CFO 批 → active;
--        生效中条款 CONTRACT_TERMS_FROZEN|…|active、表头 CONTRACT_ACTIVE_IS_FROZEN;暂停一步;改条款;
--        再提生效 → snapshot.last_approved = 上一次批准时那一份,current 带着新条款;批 → active
--   I  读者:cco 看得见自己的申请(raised_by_me);只持 view_prices 而不持采购价码的人读一张采购公式的申请 →
--        snapshot / proposed 为 NULL
--   J  审批关着:新公式生下来就 approved、启用,留痕 auto_approved
--   K  ★ 故障注入:摘掉 trg_pricing_formulas_direct_write,cco 的直连 UPDATE 退回成一次【不报错】的零行空操作 ——
--        守卫是承重的
--
-- 自带数据(README 第 2 条);锁期自己设(第 4 条)。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '180s';

CREATE FUNCTION pg_temp.f227_try(p_sql text) RETURNS text
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

CREATE FUNCTION pg_temp.f227_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', p_user), true)
$f$;

DO $$
DECLARE
    u_cco  uuid := gen_random_uuid();   -- cco 的形状:公式与合同的提单码、看得见;【不】在任何一级审批角色里
    u_cco2 uuid := gen_random_uuid();   -- 另一个 cco(撤回那一臂)
    u_cfo  uuid := gen_random_uuid();   -- 二级:CFO 的形状;在册员工 e_cfo 的主账号
    u_cfo2 uuid := gen_random_uuid();   -- ★ e_cfo 的另一个账号,持 cco 角色 —— "同一个人提的"那一臂
    u_l1   uuid := gen_random_uuid();   -- 一级
    u_view uuid := gen_random_uuid();   -- 读得到公式、看得见销售价,【不】持采购价码、不持任何写码
    r_cco uuid; r_l1 uuid; r_l2 uuid; r_view uuid;
    e_cfo uuid := gen_random_uuid();
    v_sup uuid; v_cust uuid;
    f1 uuid; f2 uuid; f3 uuid; c1 uuid; c1_code text;
    q uuid; q2 uuid; v_res jsonb; v_msg text; v_n int; v_log int; v_hist int; v_t jsonb; v_snap jsonb;
    rep jsonb := '{}'::jsonb;
BEGIN
    UPDATE finance_settings SET locked_before = NULL, system_start_date = NULL;

    -- ══════════════ 布景 ══════════════
    INSERT INTO auth.users (id, email_confirmed_at) VALUES
        (u_cco, now()), (u_cco2, now()), (u_cfo, now()), (u_cfo2, now()), (u_l1, now()), (u_view, now());
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx227-cco','f','f',true)  RETURNING id INTO r_cco;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx227-l1','f','f',true)   RETURNING id INTO r_l1;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx227-l2','f','f',true)   RETURNING id INTO r_l2;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx227-view','f','f',true) RETURNING id INTO r_view;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_cco, c FROM unnest(ARRAY['module.pricing.edit', 'module.pricing.view', 'data.view_prices',
        'data.view_purchase_prices', 'action.contract_terms', 'module.suppliers.view', 'module.customers.view']) c;
    -- 一级与二级:每一条链的门都持(审批开得了);二级多出条款链的三个码
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r.id, c FROM unnest(ARRAY[r_l1, r_l2]) r(id)
     CROSS JOIN unnest(ARRAY['module.purchasing.view', 'data.view_prices', 'data.view_purchase_prices',
        'module.finance.view', 'module.hr.view', 'data.view_pay', 'module.inbound.view', 'module.sales.view']) c;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_l2, c FROM unnest(ARRAY['module.pricing.view', 'module.suppliers.view', 'module.customers.view']) c;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_view, c FROM unnest(ARRAY['module.pricing.view', 'data.view_prices']) c;
    INSERT INTO user_roles (user_id, role_id) VALUES
        (u_cco, r_cco), (u_cco2, r_cco), (u_cfo, r_l2), (u_cfo2, r_cco), (u_l1, r_l1), (u_view, r_view);
    INSERT INTO employees (id, code, legal_name, employment_type, work_category, hire_date, user_id)
    VALUES (e_cfo, 'FX227-CFO', 'FX227 CFO', 'full_time', 'office', CURRENT_DATE - 400, u_cfo);
    INSERT INTO employee_accounts (user_id, employee_id) VALUES (u_cfo2, e_cfo);

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZFIX227-S', 'fixture 227 supplier', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup;

    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approval_level1_role_code = 'fx227-l1', approval_level2_role_code = 'fx227-l2',
                                approval_threshold_base = 1000;
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = true;

    -- ══════════════ A · 登记 ══════════════
    IF (SELECT array_agg(level::int ORDER BY level) FROM approval_chain_gates() WHERE subject_type = 'terms_request')
         IS DISTINCT FROM ARRAY[2]
       OR (SELECT gate_permissions FROM approval_chain_gates() WHERE subject_type = 'terms_request')
         IS DISTINCT FROM ARRAY['module.pricing.view', 'data.view_prices', 'data.view_purchase_prices',
                                'module.suppliers.view', 'module.customers.view']::text[] THEN
        RAISE EXCEPTION 'FIXTURE 227A1 失败:链的名册应当只有二级一行,门是裁定的那五个码'; END IF;
    IF position('terms_request_pending' IN pg_get_viewdef('public.operations_now'::regclass)) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 227A2 失败:operations_now 没有 terms_request_pending 那一支'; END IF;
    SELECT string_agg(s, ', ') INTO v_msg FROM unnest(ARRAY[
        'public.terms_request_submit_internal(text, uuid, jsonb, text)', 'public.terms_request_execute_internal(uuid)',
        'public.terms_request_dry_run(uuid)', 'public.terms_request_snapshot(text, uuid, jsonb)',
        'public.terms_request_fingerprint(text, uuid)', 'public.formula_terms_state(uuid)',
        'public.contract_terms_state(uuid)']) s
     WHERE has_function_privilege('authenticated', s::regprocedure, 'EXECUTE');
    IF v_msg IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 227A3 失败:authenticated 调得到内层算子 %', v_msg; END IF;
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public'
                AND tablename IN ('pricing_formulas', 'pricing_formula_metals', 'terms_requests') AND cmd <> 'SELECT') THEN
        RAISE EXCEPTION 'FIXTURE 227A4 失败:公式两张表或申请表上还有写策略'; END IF;
    SELECT count(*) INTO v_n FROM pg_trigger
     WHERE NOT tgisinternal AND tgname IN ('trg_pricing_formulas_direct_write', 'trg_pricing_formula_metals_direct_write',
        'trg_contracts_guard_write', 'trg_contract_grade_specs_frozen', 'trg_contract_insurance_obligations_frozen',
        'trg_contract_volume_commitments_frozen', 'trg_contract_pricing_terms_frozen', 'trg_contract_settlement_terms_frozen',
        'trg_contract_refining_charges_frozen', 'trg_contract_penalty_elements_frozen');
    IF v_n <> 10 THEN
        RAISE EXCEPTION 'FIXTURE 227A5 失败:应当挂着 10 支守卫,实得 %', v_n; END IF;
    rep := rep || jsonb_build_object('A_registered', true);

    -- ══════════════ B · 新公式,审批开着 ══════════════
    PERFORM pg_temp.f227_as(u_cco);
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_res := submit_formula_create_request(jsonb_build_object(
        'name', 'f227 new', 'direction', 'purchase', 'price_basis', 'spot', 'treatment_charge_usd_per_tonne', 100,
        'supplier_id', v_sup,
        'metals', jsonb_build_array(jsonb_build_object('metal', 'ni', 'payable_pct', 70),
                                    jsonb_build_object('metal', 'co', 'payable_pct', 60))), 'f227 B');
    EXECUTE 'RESET ROLE';
    f1 := (v_res->>'formula_id')::uuid; q := (v_res->>'request_id')::uuid;
    IF v_res->>'status' <> 'submitted' OR (SELECT is_active FROM pricing_formulas WHERE id = f1)
       OR (SELECT count(*) FROM pricing_formula_metals WHERE formula_id = f1) <> 2
       OR (SELECT kind || ':' || status FROM terms_requests WHERE id = q) <> 'formula_create:submitted'
       OR NOT EXISTS (SELECT 1 FROM approval_log WHERE subject_type = 'terms_request' AND subject_id = q
                       AND decision = 'submitted' AND level = 2) THEN
        RAISE EXCEPTION 'FIXTURE 227B1 失败:新公式应当停用着、申请 submitted、留痕 submitted 二级,实得 %', v_res; END IF;
    v_msg := NULL;
    BEGIN PERFORM pricing_terms_of_formula(f1); EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF v_msg IS DISTINCT FROM 'FORMULA_INACTIVE|' || (SELECT code FROM pricing_formulas WHERE id = f1) THEN
        RAISE EXCEPTION 'FIXTURE 227B2 失败:批准之前读公式的那一支应当按名拒 FORMULA_INACTIVE,实得 %', COALESCE(v_msg, '(读到了)'); END IF;
    IF NOT EXISTS (SELECT 1 FROM approval_pending_documents() p
                    WHERE p.subject_type = 'terms_request' AND p.doc_id = q AND p.blocks_disable AND p.fixed_level = 2
                      AND p.amount_base IS NULL) THEN
        RAISE EXCEPTION 'FIXTURE 227B3 失败:在途清单里应当有这一张(blocks_disable、二级、金额 NULL)'; END IF;
    v_msg := NULL;
    BEGIN
        PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
        UPDATE finance_settings SET approvals_enabled = false;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF v_msg IS NULL OR v_msg NOT LIKE 'APPROVALS_CANNOT_DISABLE_WITH_PENDING|%' THEN
        RAISE EXCEPTION 'FIXTURE 227B4 失败:在途时关审批应当按名拒,实得 %', COALESCE(v_msg, '(关掉了)'); END IF;
    rep := rep || jsonb_build_object('B_new_formula_waits', true);

    -- ══════════════ C · 直连写按名拒 ══════════════
    PERFORM pg_temp.f227_as(u_cco);
    v_msg := pg_temp.f227_try(format('UPDATE pricing_formulas SET flat_discount_pct = 5 WHERE id = %L', f1));
    IF v_msg <> 'PRICING_FORMULA_THROUGH_REQUEST_ONLY' THEN
        RAISE EXCEPTION 'FIXTURE 227C1 失败:cco 直连改公式应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f227_try(format('UPDATE pricing_formulas SET notes = notes WHERE id = %L', gen_random_uuid()));
    IF v_msg <> 'PRICING_FORMULA_THROUGH_REQUEST_ONLY' THEN
        RAISE EXCEPTION 'FIXTURE 227C2 失败:零行的直连 UPDATE 也要按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f227_try($s$INSERT INTO pricing_formulas (code, name) VALUES ('', 'f227 direct')$s$);
    IF v_msg <> 'PRICING_FORMULA_THROUGH_REQUEST_ONLY' THEN
        RAISE EXCEPTION 'FIXTURE 227C3 失败:cco 直连建公式应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f227_try(format('UPDATE pricing_formula_metals SET payable_pct = 99 WHERE formula_id = %L', f1));
    IF v_msg <> 'PRICING_FORMULA_THROUGH_REQUEST_ONLY' THEN
        RAISE EXCEPTION 'FIXTURE 227C4 失败:cco 直连改比例应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f227_try(format('DELETE FROM pricing_formula_metals WHERE formula_id = %L', f1));
    IF v_msg <> 'PRICING_FORMULA_THROUGH_REQUEST_ONLY' THEN
        RAISE EXCEPTION 'FIXTURE 227C5 失败:cco 直连删比例应当按名拒,实得 %', v_msg; END IF;
    PERFORM pg_temp.f227_as(u_view);
    v_msg := pg_temp.f227_try(format('UPDATE pricing_formulas SET notes = %L WHERE id = %L', 'x', f1));
    IF v_msg <> 'PERMISSION_DENIED|module.pricing.edit' THEN
        RAISE EXCEPTION 'FIXTURE 227C6 失败:不持码的人直连改公式应当读到缺的那个码,实得 %', v_msg; END IF;
    v_msg := pg_temp.f227_try($s$SELECT submit_formula_create_request('{"name":"x"}'::jsonb, 'x')$s$);
    IF v_msg <> 'PERMISSION_DENIED|module.pricing.edit' THEN
        RAISE EXCEPTION 'FIXTURE 227C7 失败:不持码的人提新公式应当按码拒,实得 %', v_msg; END IF;
    rep := rep || jsonb_build_object('C_no_direct_write', true);

    -- ══════════════ D · 批不了 / 提不了 ══════════════
    -- cco 持这条链的全部五个门码(量过的线上 cco 也持)—— 所以她过得了门,拒她的只能是【四眼】那一条
    PERFORM pg_temp.f227_as(u_cco);
    v_msg := pg_temp.f227_try(format('SELECT decide_terms_request(%L, true)', q));
    IF v_msg <> 'SELF_APPROVAL_FORBIDDEN|raiser' THEN
        RAISE EXCEPTION 'FIXTURE 227D1 失败:提单人自己批应当 SELF_APPROVAL_FORBIDDEN|raiser,实得 %', v_msg; END IF;
    PERFORM pg_temp.f227_as(u_l1);
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_l1, c FROM unnest(ARRAY['module.pricing.view', 'module.suppliers.view', 'module.customers.view']) c;
    v_msg := pg_temp.f227_try(format('SELECT decide_terms_request(%L, true)', q));
    DELETE FROM role_permissions WHERE role_id = r_l1
       AND permission_code IN ('module.pricing.view', 'module.suppliers.view', 'module.customers.view');
    IF v_msg NOT LIKE 'APPROVAL_NOT_AUTHORISED|2|%' THEN
        RAISE EXCEPTION 'FIXTURE 227D3 失败:一级批不了二级的申请,实得 %', v_msg; END IF;
    PERFORM pg_temp.f227_as(u_cfo);
    v_msg := pg_temp.f227_try(format('SELECT decide_terms_request(%L, false, %L)', q, '  '));
    IF v_msg NOT LIKE 'TERMS_REQUEST_REJECT_REASON_REQUIRED|%' THEN
        RAISE EXCEPTION 'FIXTURE 227D4 失败:驳回不给理由应当按名拒,实得 %', v_msg; END IF;
    PERFORM pg_temp.f227_as(u_cco);
    v_msg := pg_temp.f227_try($s$SELECT submit_formula_create_request('{"name":"f227 no reason"}'::jsonb, ' ')$s$);
    IF v_msg NOT LIKE 'TERMS_REQUEST_REASON_REQUIRED|formula_create|%' THEN
        RAISE EXCEPTION 'FIXTURE 227D5 失败:没有理由应当按名拒,实得 %', v_msg; END IF;
    SELECT count(*) INTO v_log FROM approval_log WHERE subject_type = 'terms_request';
    SELECT count(*) INTO v_n FROM pricing_formulas;
    PERFORM pg_temp.f227_as(u_cfo2);
    v_msg := pg_temp.f227_try($s$SELECT submit_formula_create_request('{"name":"f227 by the cfo person"}'::jsonb, 'x')$s$);
    IF v_msg NOT LIKE 'TERMS_REQUEST_NO_OTHER_DECIDER|%'
       OR (SELECT count(*) FROM approval_log WHERE subject_type = 'terms_request') <> v_log
       OR (SELECT count(*) FROM pricing_formulas) <> v_n THEN
        RAISE EXCEPTION 'FIXTURE 227D6 失败:CFO 那个人的另一个账号提的,应当按名拒且一行不落,实得 %', v_msg; END IF;
    rep := rep || jsonb_build_object('D_refusals', true);

    -- B 收尾:CFO 批 → 启用
    PERFORM pg_temp.f227_as(u_cfo);
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_res := decide_terms_request(q, true, 'f227 ok');
    EXECUTE 'RESET ROLE';
    IF NOT (SELECT is_active FROM pricing_formulas WHERE id = f1)
       OR (SELECT status FROM terms_requests WHERE id = q) <> 'approved'
       OR NOT EXISTS (SELECT 1 FROM approval_log WHERE subject_type = 'terms_request' AND subject_id = q
                       AND decision = 'approved' AND level = 2)
       OR (pricing_terms_of_formula(f1)->'payables'->>'ni')::numeric <> 70 THEN
        RAISE EXCEPTION 'FIXTURE 227B5 失败:CFO 批准之后公式应当启用、条款可读,实得 %', v_res; END IF;

    -- ══════════════ E · 改在用的公式 ══════════════
    PERFORM pg_temp.f227_as(u_cco);
    v_msg := pg_temp.f227_try(format('SELECT submit_formula_change_request(%L, %L::jsonb, %L)', f1,
        formula_terms_state(f1)::text, 'same'));
    IF v_msg NOT LIKE 'TERMS_REQUEST_NO_CHANGE|%' THEN
        RAISE EXCEPTION 'FIXTURE 227E0 失败:一模一样的条款应当按名拒,实得 %', v_msg; END IF;
    SELECT count(*) INTO v_hist FROM pricing_formula_history WHERE formula_id = f1;
    v_t := jsonb_build_object('name', 'f227 new v2', 'direction', 'purchase', 'price_basis', 'spot',
        'treatment_charge_usd_per_tonne', 120, 'supplier_id', v_sup,
        'metals', jsonb_build_array(jsonb_build_object('metal', 'ni', 'payable_pct', 75)));
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_res := submit_formula_change_request(f1, v_t, 'f227 E');
    EXECUTE 'RESET ROLE';
    q := (v_res->>'request_id')::uuid;
    SELECT snapshot INTO v_snap FROM terms_requests WHERE id = q;
    IF (pricing_terms_of_formula(f1)->'payables'->>'ni')::numeric <> 70
       OR (pricing_terms_of_formula(f1)->'payables'->>'co') IS NULL
       OR (v_snap->'current'->>'treatment_charge_usd_per_tonne')::numeric <> 100
       OR (v_snap->'proposed'->>'treatment_charge_usd_per_tonne')::numeric <> 120
       OR (v_snap->'last_approved'->>'treatment_charge_usd_per_tonne')::numeric <> 100
       OR v_snap->'usage' IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 227E1 失败:等待期间应当仍读到旧条款,snapshot 要有 current / proposed / last_approved / usage,实得 %', v_snap; END IF;
    v_msg := pg_temp.f227_try(format('SELECT submit_formula_change_request(%L, %L::jsonb, %L)', f1, v_t::text, 'again'));
    IF v_msg NOT LIKE 'TERMS_REQUEST_OPEN|%' THEN
        RAISE EXCEPTION 'FIXTURE 227E2 失败:第二张应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f227_try(format('SELECT deactivate_pricing_formula(%L)', f1));
    IF v_msg NOT LIKE 'TERMS_REQUEST_OPEN|%' THEN
        RAISE EXCEPTION 'FIXTURE 227E3 失败:等待中停用应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f227_try(format('SELECT delete_pricing_formula(%L)', f1));
    IF v_msg NOT LIKE 'TERMS_REQUEST_OPEN|%' THEN
        RAISE EXCEPTION 'FIXTURE 227E4 失败:等待中删除应当按名拒,实得 %', v_msg; END IF;
    PERFORM pg_temp.f227_as(u_cfo);
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM decide_terms_request(q, true, NULL);
    EXECUTE 'RESET ROLE';
    IF (pricing_terms_of_formula(f1)->'payables'->>'ni')::numeric <> 75
       OR (pricing_terms_of_formula(f1)->'payables'->>'co') IS NOT NULL
       OR (pricing_terms_of_formula(f1)->>'treatment_charge_usd_per_tonne')::numeric <> 120
       OR (SELECT name FROM pricing_formulas WHERE id = f1) <> 'f227 new v2'
       OR (SELECT count(*) FROM pricing_formula_history WHERE formula_id = f1) <= v_hist THEN
        RAISE EXCEPTION 'FIXTURE 227E5 失败:批准应当就地替换条款(ni 75、co 不再计价、处理费 120)并记进历史,实得 %',
            pricing_terms_of_formula(f1); END IF;
    rep := rep || jsonb_build_object('E_change_replaces_on_approval', true);

    -- ══════════════ F · fingerprint 与撤回 ══════════════
    PERFORM pg_temp.f227_as(u_cco);
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_res := submit_formula_change_request(f1, v_t || jsonb_build_object('flat_discount_pct', 1), 'f227 F');
    EXECUTE 'RESET ROLE';
    q := (v_res->>'request_id')::uuid;
    UPDATE pricing_formulas SET notes = 'changed by the owner path while waiting' WHERE id = f1;   -- 属主路径
    PERFORM pg_temp.f227_as(u_cfo);
    v_msg := pg_temp.f227_try(format('SELECT decide_terms_request(%L, true)', q));
    IF v_msg NOT LIKE 'TERMS_CHANGED_SINCE_REQUEST|%' OR (SELECT status FROM terms_requests WHERE id = q) <> 'submitted'
       OR (SELECT flat_discount_pct FROM pricing_formulas WHERE id = f1) <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 227F1 失败:主体在等待中变了,批准应当按名拒且什么都不生效,实得 %', v_msg; END IF;
    SELECT count(*) INTO v_log FROM approval_log WHERE subject_type = 'terms_request' AND subject_id = q;
    PERFORM pg_temp.f227_as(u_cco2);
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM withdraw_terms_request(q, 'f227 F withdraw');
    EXECUTE 'RESET ROLE';
    IF (SELECT status FROM terms_requests WHERE id = q) <> 'withdrawn'
       OR (SELECT count(*) FROM approval_log WHERE subject_type = 'terms_request' AND subject_id = q) <> v_log THEN
        RAISE EXCEPTION 'FIXTURE 227F2 失败:另一个 cco 撤得了,撤回不写留痕'; END IF;
    rep := rep || jsonb_build_object('F_fingerprint_and_withdraw', true);

    -- ══════════════ G · 停用一步;重新启用经 CFO ══════════════
    PERFORM pg_temp.f227_as(u_cco);
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM deactivate_pricing_formula(f1);
    v_res := submit_formula_reactivate_request(f1, NULL, 'f227 G');
    EXECUTE 'RESET ROLE';
    q := (v_res->>'request_id')::uuid;
    IF (SELECT is_active FROM pricing_formulas WHERE id = f1) THEN
        RAISE EXCEPTION 'FIXTURE 227G1 失败:停用应当一步生效,重新启用应当等 CFO'; END IF;
    PERFORM pg_temp.f227_as(u_cfo);
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM decide_terms_request(q, false, 'f227 not yet');
    EXECUTE 'RESET ROLE';
    IF (SELECT is_active FROM pricing_formulas WHERE id = f1)
       OR (SELECT status FROM terms_requests WHERE id = q) <> 'rejected' THEN
        RAISE EXCEPTION 'FIXTURE 227G2 失败:驳回之后公式仍停用'; END IF;
    PERFORM pg_temp.f227_as(u_cco);
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_res := submit_formula_reactivate_request(f1, NULL, 'f227 G again');
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f227_as(u_cfo);
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM decide_terms_request((v_res->>'request_id')::uuid, true, NULL);
    EXECUTE 'RESET ROLE';
    IF NOT (SELECT is_active FROM pricing_formulas WHERE id = f1) THEN
        RAISE EXCEPTION 'FIXTURE 227G3 失败:批准重新启用之后公式应当启用'; END IF;
    rep := rep || jsonb_build_object('G_deactivate_one_step_reactivate_approved', true);

    -- ══════════════ H · 合同 ══════════════
    PERFORM pg_temp.f227_as(u_cco);
    v_msg := pg_temp.f227_try(format(
        $s$INSERT INTO contracts (supplier_id, kind, title, effective_from, status) VALUES (%L, 'supply', 'f227 active', CURRENT_DATE, 'active')$s$, v_sup));
    IF v_msg NOT LIKE 'CONTRACT_ACTIVATES_THROUGH_REQUEST|%' THEN
        RAISE EXCEPTION 'FIXTURE 227H1 失败:直连建一份生效的合同应当按名拒,实得 %', v_msg; END IF;
    EXECUTE 'SET LOCAL ROLE authenticated';
    INSERT INTO contracts (supplier_id, kind, title, effective_from, status)
    VALUES (v_sup, 'supply', 'f227 contract', CURRENT_DATE, 'draft') RETURNING id, code INTO c1, c1_code;
    INSERT INTO contract_pricing_terms (contract_id, metal, base_event, qp_months, index_code, payable_pct)
    VALUES (c1, 'ni', 'shipment', 1, 'LME', 90);
    EXECUTE 'RESET ROLE';
    v_msg := pg_temp.f227_try(format($s$UPDATE contracts SET status = 'active' WHERE id = %L$s$, c1));
    IF v_msg <> 'CONTRACT_ACTIVATES_THROUGH_REQUEST|' || c1_code THEN
        RAISE EXCEPTION 'FIXTURE 227H2 失败:直连把草稿改成 active 应当按名拒,实得 %', v_msg; END IF;
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_res := submit_contract_activation_request(c1, 'f227 H');
    EXECUTE 'RESET ROLE';
    q := (v_res->>'request_id')::uuid;
    v_msg := pg_temp.f227_try(format($s$UPDATE contract_pricing_terms SET payable_pct = 91 WHERE contract_id = %L$s$, c1));
    IF v_msg NOT LIKE 'CONTRACT_TERMS_FROZEN|' || c1_code || '|%' THEN
        RAISE EXCEPTION 'FIXTURE 227H3 失败:等待中改条款应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f227_try(format($s$UPDATE contracts SET notes = 'x' WHERE id = %L$s$, c1));
    IF v_msg NOT LIKE 'TERMS_REQUEST_FREEZES_CONTRACT|' || c1_code || '|%' THEN
        RAISE EXCEPTION 'FIXTURE 227H4 失败:等待中改表头应当按名拒,实得 %', v_msg; END IF;
    PERFORM pg_temp.f227_as(u_cfo);
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM decide_terms_request(q, true, NULL);
    EXECUTE 'RESET ROLE';
    IF (SELECT status FROM contracts WHERE id = c1) <> 'active' THEN
        RAISE EXCEPTION 'FIXTURE 227H5 失败:CFO 批准之后合同应当生效'; END IF;
    PERFORM pg_temp.f227_as(u_cco);
    v_msg := pg_temp.f227_try(format($s$UPDATE contract_pricing_terms SET payable_pct = 91 WHERE contract_id = %L$s$, c1));
    IF v_msg <> 'CONTRACT_TERMS_FROZEN|' || c1_code || '|active' THEN
        RAISE EXCEPTION 'FIXTURE 227H6 失败:生效中改条款应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f227_try(format($s$UPDATE contracts SET notes = 'x' WHERE id = %L$s$, c1));
    IF v_msg <> 'CONTRACT_ACTIVE_IS_FROZEN|' || c1_code THEN
        RAISE EXCEPTION 'FIXTURE 227H7 失败:生效中改表头应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f227_try(format($s$UPDATE contracts SET status = 'suspended' WHERE id = %L$s$, c1));
    IF v_msg <> 'OK' OR (SELECT status FROM contracts WHERE id = c1) <> 'suspended' THEN
        RAISE EXCEPTION 'FIXTURE 227H8 失败:暂停应当一步,实得 %', v_msg; END IF;
    v_msg := pg_temp.f227_try(format($s$UPDATE contract_pricing_terms SET payable_pct = 92 WHERE contract_id = %L$s$, c1));
    IF v_msg <> 'OK' THEN
        RAISE EXCEPTION 'FIXTURE 227H9 失败:暂停之后条款改得了,实得 %', v_msg; END IF;
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_res := submit_contract_activation_request(c1, 'f227 H again');
    EXECUTE 'RESET ROLE';
    q := (v_res->>'request_id')::uuid;
    SELECT snapshot INTO v_snap FROM terms_requests WHERE id = q;
    IF (v_snap->'last_approved'->'pricing_terms'->0->>'payable_pct')::numeric <> 90
       OR (v_snap->'current'->'pricing_terms'->0->>'payable_pct')::numeric <> 92
       OR (v_snap->>'linked_documents')::int <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 227H10 失败:重新生效的 snapshot 应当带着上一次批准时那一份(90)与此刻的(92),实得 %', v_snap; END IF;
    PERFORM pg_temp.f227_as(u_cfo);
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM decide_terms_request(q, true, NULL);
    EXECUTE 'RESET ROLE';
    IF (SELECT status FROM contracts WHERE id = c1) <> 'active' THEN
        RAISE EXCEPTION 'FIXTURE 227H11 失败:重新生效之后合同应当 active'; END IF;
    rep := rep || jsonb_build_object('H_contract_activation', true);

    -- ══════════════ I · 读者 ══════════════
    PERFORM pg_temp.f227_as(u_cco);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM terms_requests_visible(50) v WHERE v.raised_by_me AND v.snapshot IS NOT NULL;
    EXECUTE 'RESET ROLE';
    IF v_n < 5 THEN
        RAISE EXCEPTION 'FIXTURE 227I1 失败:cco 应当看得见自己提的申请与它们的 snapshot,实得 % 张', v_n; END IF;
    PERFORM pg_temp.f227_as(u_view);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM terms_requests_visible(50) v WHERE v.formula_id = f1 AND v.snapshot IS NOT NULL;
    SELECT count(*) INTO v_log FROM terms_requests_visible(50) v WHERE v.contract_id IS NOT NULL;
    EXECUTE 'RESET ROLE';
    IF v_n <> 0 OR v_log <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 227I2 失败:不持采购价码的人读不到采购公式的条款、不持供应商码的人读不到合同申请,实得 % / %', v_n, v_log; END IF;
    rep := rep || jsonb_build_object('I_readers', true);

    -- ══════════════ J · 审批关着 ══════════════
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = false;
    PERFORM pg_temp.f227_as(u_cco);
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_res := submit_formula_create_request('{"name":"f227 off","direction":"sale"}'::jsonb, 'f227 J');
    EXECUTE 'RESET ROLE';
    f2 := (v_res->>'formula_id')::uuid; q := (v_res->>'request_id')::uuid;
    IF v_res->>'status' <> 'approved' OR NOT (SELECT is_active FROM pricing_formulas WHERE id = f2)
       OR NOT EXISTS (SELECT 1 FROM approval_log WHERE subject_type = 'terms_request' AND subject_id = q
                       AND decision = 'auto_approved' AND level IS NULL) THEN
        RAISE EXCEPTION 'FIXTURE 227J 失败:审批关着时新公式生下来就 approved 并启用、留痕 auto_approved,实得 %', v_res; END IF;
    rep := rep || jsonb_build_object('J_approvals_off', true);

    -- ══════════════ K · 故障注入 ══════════════
    ALTER TABLE pricing_formulas DISABLE TRIGGER trg_pricing_formulas_direct_write;
    PERFORM pg_temp.f227_as(u_cco);
    v_msg := pg_temp.f227_try(format('UPDATE pricing_formulas SET notes = %L WHERE id = %L', 'k', f2));
    ALTER TABLE pricing_formulas ENABLE TRIGGER trg_pricing_formulas_direct_write;
    IF v_msg <> 'OK' OR (SELECT notes FROM pricing_formulas WHERE id = f2) IS NOT DISTINCT FROM 'k' THEN
        RAISE EXCEPTION 'FIXTURE 227K 失败:摘掉守卫之后直连 UPDATE 应当是一次静默的零行空操作(没有写策略),实得 %', v_msg; END IF;
    rep := rep || jsonb_build_object('K_guard_is_load_bearing', true);

    RAISE NOTICE 'FIXTURE 227 全部通过:A 登记 · B 新公式 · C 直连写 · D 批不了 / 提不了 · E 改在用的公式 · F fingerprint 与撤回 · G 停用与重新启用 · H 合同 · I 读者 · J 审批关着 · K 注入 %', rep::text;
END;
$$;
ROLLBACK;
