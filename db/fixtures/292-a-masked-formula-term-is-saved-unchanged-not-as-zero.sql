-- 292 TABLE-EXPORT-2b-1:看不见公式条款的人保存公式,被遮的加工费 · 折扣 · 计价比例【不改】,不存成 0(Tim 2026-10-23,TABLE-EXPORT-2b Q5)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】
--   A  ★★ 看不见采购条款的人(持 module.pricing.edit + data.view_prices,不持 data.view_purchase_prices)改一张【采购】公式:
--        只改名字、条款送 0 / 0 / 空比例(从前的编辑页就是这么送的)→ 名字变了,加工费 · 折扣 · 比例逐字是原值
--   B  看不见销售条款的人(持采购价码、不持 data.view_prices)改一张【销售】公式 → 同上(判据两侧都走 pricing_formula_terms_visible)
--   C  ★ 对照臂:看得见的人送同样的 0 → 加工费与折扣真的变成 0(两臂分得开 —— A 不是因为"什么都改不动"才绿)
--   D  重新启用那扇门:停用之后,看不见的人带着 0 / 0 / 空比例重新启用 → 启用了,条款仍是原值
--   E  ★ 故障注入:把修改门换回本刀之前的函数体,A 那一步加工费变成 0 —— 那几行是承重的
--
-- 审批关着(J 臂的形状):申请当场生效,于是条款直接读公式表。自带数据(README 第 2 条);锁期自己设(第 4 条)。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '120s';

CREATE FUNCTION pg_temp.f292_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', p_user), true)
$f$;

DO $$
DECLARE
    u_full  uuid := gen_random_uuid();   -- 两侧条款都看得见、持写码
    u_nopur uuid := gen_random_uuid();   -- 持写码、看得见销售价,【不】持采购价码
    u_nosal uuid := gen_random_uuid();   -- 持写码、看得见采购价,【不】持销售价码
    r_full uuid; r_nopur uuid; r_nosal uuid;
    f_pur uuid; f_sal uuid; v_res jsonb; v_t jsonb;
    v_old_body text;
    rep jsonb := '{}'::jsonb;
BEGIN
    UPDATE finance_settings SET locked_before = NULL, system_start_date = NULL;
    INSERT INTO auth.users (id, email_confirmed_at) VALUES (u_full, now()), (u_nopur, now()), (u_nosal, now());
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx292-full','f','f',true)  RETURNING id INTO r_full;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx292-nopur','f','f',true) RETURNING id INTO r_nopur;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx292-nosal','f','f',true) RETURNING id INTO r_nosal;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_full, c FROM unnest(ARRAY['module.pricing.view', 'module.pricing.edit', 'data.view_prices', 'data.view_purchase_prices']) c;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_nopur, c FROM unnest(ARRAY['module.pricing.view', 'module.pricing.edit', 'data.view_prices']) c;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_nosal, c FROM unnest(ARRAY['module.pricing.view', 'module.pricing.edit', 'data.view_purchase_prices']) c;
    INSERT INTO user_roles (user_id, role_id) VALUES (u_full, r_full), (u_nopur, r_nopur), (u_nosal, r_nosal);

    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = false;

    -- 两张公式,由看得见的人建(审批关着 → 当场启用)
    PERFORM pg_temp.f292_as(u_full);
    v_res := submit_formula_create_request(jsonb_build_object(
        'name', 'f292 purchase', 'direction', 'purchase', 'price_basis', 'spot',
        'treatment_charge_usd_per_tonne', 350, 'flat_discount_pct', 4.5,
        'metals', jsonb_build_array(jsonb_build_object('metal', 'ni', 'payable_pct', 70),
                                    jsonb_build_object('metal', 'co', 'payable_pct', 60))), 'f292 setup');
    f_pur := (v_res->>'formula_id')::uuid;
    v_res := submit_formula_create_request(jsonb_build_object(
        'name', 'f292 sale', 'direction', 'sale', 'price_basis', 'spot',
        'treatment_charge_usd_per_tonne', 210, 'flat_discount_pct', 2,
        'metals', jsonb_build_array(jsonb_build_object('metal', 'ni', 'payable_pct', 80))), 'f292 setup');
    f_sal := (v_res->>'formula_id')::uuid;
    IF NOT (SELECT is_active FROM pricing_formulas WHERE id = f_pur) OR NOT (SELECT is_active FROM pricing_formulas WHERE id = f_sal) THEN
        RAISE EXCEPTION 'FIXTURE 292 布景失败:审批关着时两张公式应当当场启用'; END IF;

    -- ══════════════ A · 看不见采购条款的人改采购公式 ══════════════
    PERFORM pg_temp.f292_as(u_nopur);
    PERFORM submit_formula_change_request(f_pur, jsonb_build_object(
        'name', 'f292 purchase renamed', 'direction', 'purchase', 'price_basis', 'spot',
        'treatment_charge_usd_per_tonne', 0, 'flat_discount_pct', 0, 'metals', '[]'::jsonb), 'f292 A');
    v_t := formula_terms_state(f_pur);
    IF v_t->>'name' <> 'f292 purchase renamed'
       OR (v_t->>'treatment_charge_usd_per_tonne')::numeric <> 350 OR (v_t->>'flat_discount_pct')::numeric <> 4.5
       OR jsonb_array_length(v_t->'metals') <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 292A 失败:看不见采购条款的人只改名字,加工费 350 · 折扣 4.5 · 两条比例应当原样,实得 %', v_t; END IF;
    rep := rep || jsonb_build_object('A_purchase_masked_unchanged', true);

    -- ══════════════ B · 看不见销售条款的人改销售公式 ══════════════
    PERFORM pg_temp.f292_as(u_nosal);
    PERFORM submit_formula_change_request(f_sal, jsonb_build_object(
        'name', 'f292 sale renamed', 'direction', 'sale', 'price_basis', 'spot',
        'treatment_charge_usd_per_tonne', 0, 'flat_discount_pct', 0, 'metals', '[]'::jsonb), 'f292 B');
    v_t := formula_terms_state(f_sal);
    IF v_t->>'name' <> 'f292 sale renamed'
       OR (v_t->>'treatment_charge_usd_per_tonne')::numeric <> 210 OR (v_t->>'flat_discount_pct')::numeric <> 2
       OR jsonb_array_length(v_t->'metals') <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 292B 失败:看不见销售条款的人只改名字,加工费 210 · 折扣 2 · 一条比例应当原样,实得 %', v_t; END IF;
    rep := rep || jsonb_build_object('B_sale_masked_unchanged', true);

    -- ══════════════ C · 对照臂:看得见的人送 0 → 真的是 0 ══════════════
    PERFORM pg_temp.f292_as(u_full);
    PERFORM submit_formula_change_request(f_sal, jsonb_build_object(
        'name', 'f292 sale renamed', 'direction', 'sale', 'price_basis', 'spot',
        'treatment_charge_usd_per_tonne', 0, 'flat_discount_pct', 0,
        'metals', jsonb_build_array(jsonb_build_object('metal', 'ni', 'payable_pct', 80))), 'f292 C');
    v_t := formula_terms_state(f_sal);
    IF (v_t->>'treatment_charge_usd_per_tonne')::numeric <> 0 OR (v_t->>'flat_discount_pct')::numeric <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 292C 失败:看得见条款的人送 0 应当真的改成 0(否则 A / B 证不了什么),实得 %', v_t; END IF;
    rep := rep || jsonb_build_object('C_visible_reader_can_set_zero', true);

    -- ══════════════ D · 重新启用那扇门 ══════════════
    PERFORM pg_temp.f292_as(u_full);
    PERFORM deactivate_pricing_formula(f_pur);
    PERFORM pg_temp.f292_as(u_nopur);
    PERFORM submit_formula_reactivate_request(f_pur, jsonb_build_object(
        'name', 'f292 purchase back', 'direction', 'purchase', 'price_basis', 'spot',
        'treatment_charge_usd_per_tonne', 0, 'flat_discount_pct', 0, 'metals', '[]'::jsonb), 'f292 D');
    v_t := formula_terms_state(f_pur);
    IF NOT (SELECT is_active FROM pricing_formulas WHERE id = f_pur) OR v_t->>'name' <> 'f292 purchase back'
       OR (v_t->>'treatment_charge_usd_per_tonne')::numeric <> 350 OR (v_t->>'flat_discount_pct')::numeric <> 4.5
       OR jsonb_array_length(v_t->'metals') <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 292D 失败:看不见的人重新启用,公式应当启用而条款原样,实得 %', v_t; END IF;
    rep := rep || jsonb_build_object('D_reactivate_masked_unchanged', true);

    -- ══════════════ E · 故障注入:换回本刀之前的修改门 ══════════════
    PERFORM set_config('request.jwt.claims', '', true);
    v_old_body := $b$
CREATE OR REPLACE FUNCTION public.submit_formula_change_request(p_formula_id uuid, p_terms jsonb, p_reason text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.pricing.edit');
    IF p_terms IS NULL THEN RAISE EXCEPTION 'TERMS_FORMULA_INVALID|terms'; END IF;
    RETURN terms_request_submit_internal('formula_change', p_formula_id, p_terms, p_reason);
END;
$function$;
$b$;
    EXECUTE v_old_body;
    PERFORM pg_temp.f292_as(u_nopur);
    PERFORM submit_formula_change_request(f_pur, jsonb_build_object(
        'name', 'f292 purchase injected', 'direction', 'purchase', 'price_basis', 'spot',
        'treatment_charge_usd_per_tonne', 0, 'flat_discount_pct', 0, 'metals', '[]'::jsonb), 'f292 E');
    v_t := formula_terms_state(f_pur);
    IF (v_t->>'treatment_charge_usd_per_tonne')::numeric <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 292E 失败:换回旧的修改门之后,A 那一步应当把加工费改成 0(否则那几行不是承重的),实得 %', v_t; END IF;
    rep := rep || jsonb_build_object('E_old_body_writes_zero', true);

    RAISE NOTICE 'FIXTURE 292 全部通过:A 采购侧原样 · B 销售侧原样 · C 对照臂 · D 重新启用原样 · E 注入 %', rep::text;
END;
$$;
ROLLBACK;
