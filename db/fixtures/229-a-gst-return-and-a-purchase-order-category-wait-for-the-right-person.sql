-- 229 APR-10:GST 申报等 CFO 批数字;采购单按品类开、按开单人或这一类的码改(2026-09-27)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】(APR-10 grilling Q1–Q9,Tim 2026-09-27:Q1–Q6、Q8、Q9 照建议,Q7 另裁)
--   A  登记:名册里 GST 申报只有二级一行(finance.view + view_prices);在途清单一支(blocks_disable、fixed_level 2、
--        金额 NULL);operations_now 一支;两支内层算子 authenticated 调不到;申请表与采购单四张表没有写策略;
--        锁守卫、四支直连写守卫、行品类守卫挂上
--   G  ★★ GST 一整圈(审批开着):没关账提不了(GST_PERIOD_NOT_LOCKED);财务提 → submitted、期间仍 open、没有快照、
--        留痕 submitted 二级;旧门 → GST_FILING_NEEDS_APPROVED_REQUEST;同一期第二张 → GST_FILING_OPEN;在途时关不了审批;
--        提单人批 → SELF_APPROVAL_FORBIDDEN|raiser;CFO 的另一个账号提 → GST_FILING_NO_OTHER_DECIDER;
--        在等时把锁挪回这一季 → GST_FILING_WAITING_BLOCKS_REOPEN(直连挪锁与 reopen_period 两条路);
--        冻结的数与现算的数不一样 → 批准按名拒 GST_RETURN_CHANGED_SINCE_REQUEST、申请仍在等;
--        CFO 批 → 期间 approved、快照逐格等于冻结的那一组、留痕 approved;没批准记不了申报;记下申报日与参考号 → filed
--   H  更正(F7):开一份更正件仍是一步;对它提申请,visible 给出原件编号与原件的快照;提单人撤回 → withdrawn、
--        不写留痕;驳回要理由
--   J  审批关着:申请生下来就是 approved(auto_approved),快照当场写
--   P  ★★ 采购单按品类:不给品类 → PO_CATEGORY_REQUIRED;不认识的 → PO_CATEGORY_INVALID;仓库开耗材、cco 开设备与货物、
--        财务开办公用品;各自开别的类 → PERMISSION_DENIED|<那一类的码>;只持 module.purchasing.edit 的人一类都开不了;
--        耗材单带资产行 / 电池料行 → PO_CATEGORY_LINE_MISMATCH;品类改不了(PO_FIELD_IMMUTABLE|category)
--   Q  ★★ Q7:开单人本人改得了;持这一类码的另一个人取消 / 关闭得了;只持 purchasing.edit 的人按名拒
--        PO_NOT_RAISER_OR_CATEGORY_HOLDER;po_may_manage 对每个人的答案;批准照旧按档(一级批小单)
--   R  提单人之外没人批得动:CFO 的另一个账号开 ≥ 1,000 的单 → PO_NO_OTHER_DECIDER,一张不落;< 1,000 照开
--   S  采购单四张表以 authenticated 直连写 → PO_THROUGH_FUNCTION_ONLY
--   K  ★ 故障注入一:摘掉 trg_purchase_orders_direct_write,持 purchasing.edit 的人直连插得进一张单 —— 守卫是承重的
--   L  ★ 故障注入二:摘掉 trg_gst_filing_lock,在等时锁挪得回去 —— 守卫是承重的
--
-- 自带数据(README 第 2 条);锁期自己设(第 4 条)。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '180s';

CREATE FUNCTION pg_temp.f229_try(p_sql text) RETURNS text
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

CREATE FUNCTION pg_temp.f229_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', p_user), true)
$f$;

-- po_may_manage 以某一个人的身份问一次(屏幕读的就是它)
CREATE FUNCTION pg_temp.f229_may(p_user uuid, p_po uuid) RETURNS boolean
LANGUAGE plpgsql AS $f$
BEGIN
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', p_user), true);
    RETURN po_may_manage(p_po);
END;
$f$;

DO $$
DECLARE
    u_fin  uuid := gen_random_uuid();   -- 财务:GST 提单(finance.edit)、办公用品单
    u_fin2 uuid := gen_random_uuid();   -- 另一个财务(撤回的旁人)
    u_cfo  uuid := gen_random_uuid();   -- 二级:CFO 的形状;e_cfo 的主账号
    u_cfo2 uuid := gen_random_uuid();   -- ★ e_cfo 的另一个账号,持财务角色 + 三个开单码 —— admin@ 的形状
    u_l1   uuid := gen_random_uuid();   -- 一级
    u_wh   uuid := gen_random_uuid();   -- 仓库:耗材开单码
    u_wh2  uuid := gen_random_uuid();   -- 另一个仓库:同一类的码,不是开单人
    u_cco  uuid := gen_random_uuid();   -- cco:设备与货物开单码
    u_cto  uuid := gen_random_uuid();   -- 只持 module.purchasing.edit + view(cto 的形状)
    r_fin uuid; r_wh uuid; r_cco uuid; r_cto uuid; r_l1 uuid; r_l2 uuid;
    e_cfo uuid := gen_random_uuid();
    v_base text; v_maxyc date; v_q_start date; v_q_end date; v_q2_start date; v_q2_end date;
    p1 uuid; p2 uuid; pf7 uuid;
    v_sup uuid; m_cons uuid; m_batt uuid; a_eq uuid;
    po_c uuid; po_e uuid; po_o uuid; po_big uuid;
    q uuid; q2 uuid; qf7 uuid; v_boxes jsonb; v_res jsonb; v_msg text; v_n int; v_log int; v_row record;
    rep jsonb := '{}'::jsonb;
BEGIN
    UPDATE finance_settings SET locked_before = NULL, system_start_date = NULL;
    SELECT code INTO v_base FROM currencies WHERE is_base;

    -- ══════════════ 布景 ══════════════
    INSERT INTO auth.users (id, email_confirmed_at) VALUES
        (u_fin, now()), (u_fin2, now()), (u_cfo, now()), (u_cfo2, now()), (u_l1, now()),
        (u_wh, now()), (u_wh2, now()), (u_cco, now()), (u_cto, now());
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx229-fin','f','f',true) RETURNING id INTO r_fin;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx229-wh','f','f',true)  RETURNING id INTO r_wh;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx229-cco','f','f',true) RETURNING id INTO r_cco;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx229-cto','f','f',true) RETURNING id INTO r_cto;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx229-l1','f','f',true)  RETURNING id INTO r_l1;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx229-l2','f','f',true)  RETURNING id INTO r_l2;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_fin, c FROM unnest(ARRAY['module.finance.edit', 'module.finance.view', 'data.view_prices',
        'module.purchasing.view', 'data.view_purchase_prices', 'action.raise_po_office']) c;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_wh, c FROM unnest(ARRAY['module.purchasing.view', 'data.view_purchase_prices', 'action.raise_po_consumables']) c;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_cco, c FROM unnest(ARRAY['module.purchasing.view', 'data.view_purchase_prices', 'action.raise_po_equipment']) c;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_cto, c FROM unnest(ARRAY['module.purchasing.view', 'module.purchasing.edit', 'data.view_purchase_prices']) c;
    -- 一级与二级:每一条链的门都持(审批开得了);二级多出条款链的三个码、批评估那个码与重开月份的码
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r.id, c FROM unnest(ARRAY[r_l1, r_l2]) r(id)
     CROSS JOIN unnest(ARRAY['module.purchasing.view', 'data.view_prices', 'data.view_purchase_prices',
        'module.finance.view', 'module.hr.view', 'data.view_pay', 'module.inbound.view', 'module.sales.view']) c;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_l2, c FROM unnest(ARRAY['module.pricing.view', 'module.suppliers.view', 'module.customers.view',
        'action.approve_review', 'action.finance_reopen']) c;
    INSERT INTO user_roles (user_id, role_id) VALUES
        (u_fin, r_fin), (u_fin2, r_fin), (u_cfo, r_l2), (u_cfo2, r_fin), (u_cfo2, r_wh), (u_cfo2, r_cco),
        (u_l1, r_l1), (u_wh, r_wh), (u_wh2, r_wh), (u_cco, r_cco), (u_cto, r_cto);
    INSERT INTO employees (id, code, legal_name, employment_type, work_category, hire_date, user_id, employment_status)
    VALUES (e_cfo, 'FX229-CFO', 'FX229 CFO', 'full_time', 'office', CURRENT_DATE - 400, u_cfo, 'active');
    INSERT INTO employee_accounts (user_id, employee_id) VALUES (u_cfo2, e_cfo);

    -- 两个整季,落在既有年结之后;第二季在第一季之前(一个给 NO_OTHER_DECIDER 用)
    SELECT COALESCE(MAX(year_end), DATE '2000-12-31') INTO v_maxyc FROM year_closes WHERE reopened_at IS NULL;
    v_q2_start := date_trunc('quarter', GREATEST(DATE '2025-01-01', v_maxyc + 400))::date;
    v_q2_end   := (v_q2_start + interval '3 months - 1 day')::date;
    v_q_start  := (v_q2_start + interval '3 months')::date;
    v_q_end    := (v_q_start + interval '3 months - 1 day')::date;

    -- 采购单的料、设备与供应商
    INSERT INTO suppliers (status, code, legal_name, country, counterparty_type)
    VALUES ('active', 'FX229-S', 'fixture 229 supplier', 'SG', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed)
    VALUES ('FX229-CONS', 'fixture 229 gloves', 'consumable', false) RETURNING id INTO m_cons;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('FX229-BATT', 'fixture 229 black mass', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO m_batt;
    INSERT INTO fixed_assets (id, code, description, category, acquisition_date, cost_ccy, currency,
                              fx_rate, cost_base, useful_life_months, residual_base)
    VALUES (gen_random_uuid(), 'FX229-A1', 'fixture 229 press', 'equipment', CURRENT_DATE,
            0, v_base, 1, 0, 60, 0) RETURNING id INTO a_eq;

    -- 审批开起来:一级 fx229-l1、二级 fx229-l2、门槛 1,000
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approval_level1_role_code = 'fx229-l1', approval_level2_role_code = 'fx229-l2',
                                approval_threshold_base = 1000;
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = true;

    -- ══════════════ A · 登记 ══════════════
    IF (SELECT array_agg(level::int ORDER BY level) FROM approval_chain_gates() WHERE subject_type = 'gst_filing_request')
         IS DISTINCT FROM ARRAY[2]
       OR (SELECT gate_permissions FROM approval_chain_gates() WHERE subject_type = 'gst_filing_request')
         IS DISTINCT FROM ARRAY['module.finance.view', 'data.view_prices']::text[] THEN
        RAISE EXCEPTION 'FIXTURE 229A1 失败:GST 申报在名册里应当只有二级一行,门是 finance.view + view_prices'; END IF;
    IF position('gst_filing_pending' IN pg_get_viewdef('public.operations_now'::regclass)) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 229A2 失败:operations_now 少了 gst_filing_pending 那一支'; END IF;
    SELECT string_agg(s, ', ') INTO v_msg FROM unnest(ARRAY[
        'public.gst_filing_execute_internal(uuid)', 'public.assert_po_manager(uuid)']) s
     WHERE has_function_privilege('authenticated', s::regprocedure, 'EXECUTE');
    IF v_msg IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 229A3 失败:authenticated 调得到内层算子 %', v_msg; END IF;
    SELECT string_agg(tablename || ':' || cmd, ', ') INTO v_msg FROM pg_policies
     WHERE schemaname = 'public' AND cmd <> 'SELECT'
       AND tablename IN ('gst_filing_requests', 'purchase_orders', 'purchase_order_lines',
                         'purchase_order_payment_terms', 'purchase_order_line_retentions');
    IF v_msg IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 229A4 失败:还有写策略 %', v_msg; END IF;
    SELECT count(*) INTO v_n FROM pg_trigger
     WHERE NOT tgisinternal AND tgname IN ('trg_gst_filing_lock', 'trg_purchase_orders_direct_write',
        'trg_purchase_order_lines_direct_write', 'trg_purchase_order_payment_terms_direct_write',
        'trg_purchase_order_line_retentions_direct_write', 'trg_purchase_order_lines_category');
    IF v_n <> 6 THEN
        RAISE EXCEPTION 'FIXTURE 229A5 失败:应当挂着 6 支守卫,实得 %', v_n; END IF;
    IF po_category_raise_code('consumables') <> 'action.raise_po_consumables'
       OR po_category_raise_code('equipment_goods') <> 'action.raise_po_equipment'
       OR po_category_raise_code('office') <> 'action.raise_po_office'
       OR po_category_raise_code('other') IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 229A6 失败:品类 → 开单码那一份定义不对'; END IF;
    rep := rep || jsonb_build_object('A_registered', true);

    -- ══════════════ G · GST 一整圈 ══════════════
    PERFORM pg_temp.f229_as(u_fin);
    p1 := (open_gst_period(v_q_start, v_q_end)->>'gst_period_id')::uuid;
    p2 := (open_gst_period(v_q2_start, v_q2_end)->>'gst_period_id')::uuid;

    -- G1 没关账,提不了
    PERFORM pg_temp.f229_as(u_fin);
    v_msg := pg_temp.f229_try(format('SELECT submit_gst_filing_request(%L)', p1));
    IF position('GST_PERIOD_NOT_LOCKED|' IN v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 229G1 失败:没关账的一季应当提不了申请,实得 %', v_msg; END IF;

    -- 关账(布景,没有主语)
    PERFORM set_config('request.jwt.claims', '', true);
    UPDATE finance_settings SET locked_before = v_q_end + 1;

    -- G2 财务提 → submitted;期间仍 open;没有快照;留痕 submitted 二级
    SELECT count(*) INTO v_log FROM approval_log;
    PERFORM pg_temp.f229_as(u_fin);
    v_res := submit_gst_filing_request(p1, 'fixture 229 Q');
    q := (v_res->>'request_id')::uuid;
    IF v_res->>'status' <> 'submitted' OR (SELECT status FROM gst_periods WHERE id = p1) <> 'open'
       OR EXISTS (SELECT 1 FROM gst_return_boxes WHERE period_id = p1)
       OR jsonb_array_length((SELECT boxes FROM gst_filing_requests WHERE id = q)) < 8 THEN
        RAISE EXCEPTION 'FIXTURE 229G2 失败:提交应当只冻结数字,期间仍 open、没有快照,实得 % / %',
            v_res->>'status', (SELECT status FROM gst_periods WHERE id = p1); END IF;
    SELECT * INTO v_row FROM approval_log WHERE subject_type = 'gst_filing_request' AND subject_id = q;
    IF v_row.decision <> 'submitted' OR v_row.level <> 2 OR v_row.amount_base IS NOT NULL
       OR v_row.subject_code <> (SELECT code FROM gst_periods WHERE id = p1) || ' · filing #1' THEN
        RAISE EXCEPTION 'FIXTURE 229G2 失败:留痕应当是 submitted、二级、没有金额、编号 = label,实得 %', row_to_json(v_row); END IF;
    SELECT * INTO v_row FROM approval_pending_documents() WHERE subject_type = 'gst_filing_request' AND doc_id = q;
    IF NOT FOUND OR NOT v_row.blocks_disable OR v_row.fixed_level <> 2 OR v_row.amount_base IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 229G2 失败:在途清单那一行应当 blocks_disable、二级、金额 NULL'; END IF;
    IF NOT EXISTS (SELECT 1 FROM operations_now WHERE item_type = 'gst_filing_pending' AND item_id = p1) THEN
        RAISE EXCEPTION 'FIXTURE 229G2 失败:仪表盘应当有 gst_filing_pending,item_id = 期间'; END IF;

    -- G3 旧门只会按名拒;同一期第二张拒
    v_msg := pg_temp.f229_try(format('SELECT file_gst_return(%L, %L, ''X'')', p1, v_q_end + 20));
    IF position('GST_FILING_NEEDS_APPROVED_REQUEST|' IN v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 229G3 失败:旧门应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f229_try(format('SELECT submit_gst_filing_request(%L)', p1));
    IF position('GST_FILING_OPEN|' IN v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 229G3 失败:同一期第二张应当按名拒,实得 %', v_msg; END IF;

    -- G4 在途时关不了审批
    PERFORM set_config('request.jwt.claims', '', true);
    BEGIN
        PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
        UPDATE finance_settings SET approvals_enabled = false;
        v_msg := 'OK';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF position('APPROVALS_CANNOT_DISABLE_WITH_PENDING' IN v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 229G4 失败:在途的 GST 申请应当挡住关审批,实得 %', v_msg; END IF;

    -- G5 提单人批 → 拒;CFO 的另一个账号提 → 没有别人批得动
    PERFORM pg_temp.f229_as(u_fin);
    v_msg := pg_temp.f229_try(format('SELECT decide_gst_filing_request(%L, true)', q));
    IF position('SELF_APPROVAL_FORBIDDEN|raiser' IN v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 229G5 失败:提单人批自己的应当按名拒,实得 %', v_msg; END IF;
    PERFORM pg_temp.f229_as(u_cfo2);
    v_msg := pg_temp.f229_try(format('SELECT submit_gst_filing_request(%L)', p2));
    IF position('GST_FILING_NO_OTHER_DECIDER|' IN v_msg) = 0
       OR EXISTS (SELECT 1 FROM gst_filing_requests WHERE period_id = p2) THEN
        RAISE EXCEPTION 'FIXTURE 229G5 失败:CFO 的另一个账号提的申请没人批得动,应当按名拒且一行不落,实得 %', v_msg; END IF;

    -- G6 在等时把锁挪回这一季:直连挪锁、reopen_period 两条路都拒
    PERFORM set_config('request.jwt.claims', '', true);
    BEGIN
        UPDATE finance_settings SET locked_before = v_q_start + 40;
        v_msg := 'OK';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF position('GST_FILING_WAITING_BLOCKS_REOPEN|' IN v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 229G6 失败:在等时把锁挪回这一季应当按名拒,实得 %', v_msg; END IF;
    -- reopen_period 那条路:三个月的关账记录只在这个子块里存在(否则后面的挪锁会撞上 REOPEN_THROUGH_CLOSE_ONLY)
    BEGIN
        INSERT INTO period_closes (period_end, entries_count, total_debits, total_credits) VALUES
            ((v_q_start + interval '1 month - 1 day')::date, 0, 0, 0),
            ((v_q_start + interval '2 months - 1 day')::date, 0, 0, 0),
            (v_q_end, 0, 0, 0);
        PERFORM pg_temp.f229_as(u_cfo);
        v_msg := pg_temp.f229_try(format('SELECT reopen_period(%L, ''fixture 229'')', v_q_end));
        RAISE EXCEPTION 'F229G6|%', v_msg;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE 'F229G6|%' THEN v_msg := substr(SQLERRM, 8); ELSE RAISE; END IF;
    END;
    IF position('GST_FILING_WAITING_BLOCKS_REOPEN|' IN v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 229G6 失败:在等时 reopen_period 重开这一季的一个月应当按名拒,实得 %', v_msg; END IF;
    IF (SELECT locked_before FROM finance_settings) <> v_q_end + 1 THEN
        RAISE EXCEPTION 'FIXTURE 229G6 失败:锁不该动'; END IF;
    -- 往前挪照样行(这一季之后的月份)
    PERFORM set_config('request.jwt.claims', '', true);
    UPDATE finance_settings SET locked_before = v_q_end + 32;
    UPDATE finance_settings SET locked_before = v_q_end + 1;

    -- G7 冻结的数与现算的数不一样 → 批准按名拒,申请仍在等(属主改冻结那一组,模拟锁里仍许可的路动了数字)
    SELECT boxes INTO v_boxes FROM gst_filing_requests WHERE id = q;
    UPDATE gst_filing_requests
       SET boxes = jsonb_set(boxes, '{0,value}', to_jsonb(((boxes->0->>'value')::numeric + 1)))
     WHERE id = q;
    PERFORM pg_temp.f229_as(u_cfo);
    v_msg := pg_temp.f229_try(format('SELECT decide_gst_filing_request(%L, true)', q));
    IF position('GST_RETURN_CHANGED_SINCE_REQUEST|' IN v_msg) = 0
       OR (SELECT status FROM gst_filing_requests WHERE id = q) <> 'submitted'
       OR EXISTS (SELECT 1 FROM gst_return_boxes WHERE period_id = p1) THEN
        RAISE EXCEPTION 'FIXTURE 229G7 失败:数字变了,批准应当按名拒、申请仍在等、没有快照,实得 %', v_msg; END IF;
    IF (SELECT current_matches FROM gst_filing_requests_visible(p1) WHERE id = q) IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'FIXTURE 229G7 失败:visible 应当先说出"数字变了"'; END IF;
    UPDATE gst_filing_requests SET boxes = v_boxes WHERE id = q;

    -- G8 CFO 批 → 期间 approved、快照逐格等于冻结的那一组、留痕 approved 二级
    PERFORM pg_temp.f229_as(u_cfo);
    IF (SELECT current_matches FROM gst_filing_requests_visible(p1) WHERE id = q) IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'FIXTURE 229G8 前提失败:冻结的那一组应当已复原'; END IF;
    v_res := decide_gst_filing_request(q, true, 'ok');
    IF (SELECT status FROM gst_filing_requests WHERE id = q) <> 'approved'
       OR (SELECT status FROM gst_periods WHERE id = p1) <> 'approved' THEN
        RAISE EXCEPTION 'FIXTURE 229G8 失败:批准之后申请与期间都应当是 approved'; END IF;
    SELECT count(*) INTO v_n
      FROM jsonb_array_elements((SELECT boxes FROM gst_filing_requests WHERE id = q)) b
      JOIN gst_return_boxes rb ON rb.period_id = p1 AND rb.box = b->>'box' AND rb.value_base = (b->>'value')::numeric;
    IF v_n <> jsonb_array_length((SELECT boxes FROM gst_filing_requests WHERE id = q))
       OR v_n <> (SELECT count(*) FROM gst_return_boxes WHERE period_id = p1) THEN
        RAISE EXCEPTION 'FIXTURE 229G8 失败:快照应当逐格等于冻结的那一组'; END IF;
    IF (SELECT array_agg(decision || '/' || level::text ORDER BY seq) FROM approval_log
         WHERE subject_type = 'gst_filing_request' AND subject_id = q) IS DISTINCT FROM ARRAY['submitted/2', 'approved/2'] THEN
        RAISE EXCEPTION 'FIXTURE 229G8 失败:留痕应当是 submitted/2 · approved/2'; END IF;
    IF (SELECT filed_at FROM gst_periods WHERE id = p1) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 229G8 失败:批准的是数字,不是一次申报 —— 不该有申报痕迹'; END IF;

    -- G9 记下申报日与参考号 → filed;再记一次拒;没批准的记不了
    PERFORM pg_temp.f229_as(u_fin);
    v_msg := pg_temp.f229_try(format('SELECT record_gst_filing(%L)', p1));
    IF position('GST_FILED_DATE_REQUIRED|' IN v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 229G9 失败:不填申报日应当按名拒,实得 %', v_msg; END IF;
    PERFORM record_gst_filing(p1, v_q_end + 20, 'IRAS-229');
    IF (SELECT status || '|' || filed_on::text || '|' || filed_reference FROM gst_periods WHERE id = p1)
         <> 'filed|' || (v_q_end + 20)::text || '|IRAS-229' THEN
        RAISE EXCEPTION 'FIXTURE 229G9 失败:记下之后期间应当 filed、带申报日与参考号'; END IF;
    v_msg := pg_temp.f229_try(format('SELECT record_gst_filing(%L, %L, ''again'')', p1, v_q_end + 21));
    IF position('GST_PERIOD_ALREADY_FILED|' IN v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 229G9 失败:再记一次应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f229_try(format('SELECT record_gst_filing(%L, %L, ''x'')', p2, v_q_end + 21));
    IF position('GST_FILING_NOT_APPROVED|' IN v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 229G9 失败:没批准的期间应当记不了,实得 %', v_msg; END IF;
    rep := rep || jsonb_build_object('G_gst_lifecycle', true);

    -- ══════════════ H · 更正件 ══════════════
    pf7 := (correct_gst_return(p1, 'fixture 229 少报一格')->>'gst_period_id')::uuid;
    qf7 := (submit_gst_filing_request(pf7)->>'request_id')::uuid;
    SELECT * INTO v_row FROM gst_filing_requests_visible(pf7) WHERE id = qf7;
    IF v_row.original_code IS DISTINCT FROM (SELECT code FROM gst_periods WHERE id = p1)
       OR jsonb_array_length(v_row.original_boxes) <> (SELECT count(*) FROM gst_return_boxes WHERE period_id = p1)
       OR NOT v_row.raised_by_me THEN
        RAISE EXCEPTION 'FIXTURE 229H1 失败:更正件的申请应当给出原件编号与原件快照,实得 %', row_to_json(v_row); END IF;
    PERFORM pg_temp.f229_as(u_cfo);
    v_msg := pg_temp.f229_try(format('SELECT decide_gst_filing_request(%L, false, ''  '')', qf7));
    IF position('GST_FILING_REJECT_REASON_REQUIRED|' IN v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 229H2 失败:驳回不给理由应当按名拒,实得 %', v_msg; END IF;
    SELECT count(*) INTO v_log FROM approval_log WHERE subject_id = qf7;
    PERFORM pg_temp.f229_as(u_fin);
    PERFORM withdraw_gst_filing_request(qf7, 'fixture 229');
    IF (SELECT status FROM gst_filing_requests WHERE id = qf7) <> 'withdrawn'
       OR (SELECT count(*) FROM approval_log WHERE subject_id = qf7) <> v_log THEN
        RAISE EXCEPTION 'FIXTURE 229H3 失败:撤回应当 withdrawn、不写留痕'; END IF;
    -- 撤回之后冻结解开:它不再在途,锁挪回这一季照样行(没有别的在等)
    IF EXISTS (SELECT 1 FROM approval_pending_documents() WHERE doc_id = qf7) THEN
        RAISE EXCEPTION 'FIXTURE 229H3 失败:撤回之后不该还在途'; END IF;
    PERFORM set_config('request.jwt.claims', '', true);
    UPDATE finance_settings SET locked_before = v_q_start + 40;
    UPDATE finance_settings SET locked_before = v_q_end + 1;
    -- 驳回带理由
    PERFORM pg_temp.f229_as(u_fin);
    qf7 := (submit_gst_filing_request(pf7)->>'request_id')::uuid;
    PERFORM pg_temp.f229_as(u_cfo);
    PERFORM decide_gst_filing_request(qf7, false, 'fixture 229 reject');
    IF (SELECT status FROM gst_filing_requests WHERE id = qf7) <> 'rejected'
       OR (SELECT status FROM gst_periods WHERE id = pf7) <> 'open' THEN
        RAISE EXCEPTION 'FIXTURE 229H4 失败:驳回之后申请 rejected、期间仍 open'; END IF;
    rep := rep || jsonb_build_object('H_correction', true);

    -- ══════════════ J · 审批关着 ══════════════
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = false;
    PERFORM pg_temp.f229_as(u_fin);
    v_res := submit_gst_filing_request(pf7);
    IF v_res->>'status' <> 'approved' OR (SELECT status FROM gst_periods WHERE id = pf7) <> 'approved'
       OR NOT EXISTS (SELECT 1 FROM gst_return_boxes WHERE period_id = pf7)
       OR (SELECT decision FROM approval_log WHERE subject_id = (v_res->>'request_id')::uuid) <> 'auto_approved' THEN
        RAISE EXCEPTION 'FIXTURE 229J 失败:审批关着时申请应当生下来就是 approved、快照当场写、留痕 auto_approved'; END IF;
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = true;
    rep := rep || jsonb_build_object('J_approvals_off', true);

    -- ══════════════ P · 采购单按品类 ══════════════
    PERFORM pg_temp.f229_as(u_wh);
    v_msg := pg_temp.f229_try(format(
        'SELECT create_purchase_order(%L, CURRENT_DATE, NULL, %L, NULL, NULL, NULL, NULL, %L::jsonb)',
        v_sup, v_base, jsonb_build_array(jsonb_build_object('material_id', m_cons, 'quantity', 5, 'unit', 'box',
                                                            'estimated_unit_price', 10))));
    IF v_msg <> 'PO_CATEGORY_REQUIRED' THEN
        RAISE EXCEPTION 'FIXTURE 229P1 失败:不给品类应当按名拒 PO_CATEGORY_REQUIRED,实得 %', v_msg; END IF;
    v_msg := pg_temp.f229_try(format(
        'SELECT create_purchase_order(%L, CURRENT_DATE, NULL, %L, NULL, NULL, NULL, NULL, %L::jsonb, p_category => ''misc'')',
        v_sup, v_base, jsonb_build_array(jsonb_build_object('material_id', m_cons, 'quantity', 5, 'unit', 'box',
                                                            'estimated_unit_price', 10))));
    IF position('PO_CATEGORY_INVALID|misc' IN v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 229P1 失败:不认识的品类应当按名拒,实得 %', v_msg; END IF;
    -- P2 仓库开耗材;开设备与货物 / 办公用品 → 缺那一类的码
    po_c := (create_purchase_order(v_sup, CURRENT_DATE, NULL, v_base, NULL, NULL, NULL, NULL,
        jsonb_build_array(jsonb_build_object('material_id', m_cons, 'quantity', 5, 'unit', 'box', 'estimated_unit_price', 10)),
        p_category => 'consumables')->>'purchase_order_id')::uuid;
    IF (SELECT category FROM purchase_orders WHERE id = po_c) <> 'consumables' THEN
        RAISE EXCEPTION 'FIXTURE 229P2 失败:耗材单的品类没写上'; END IF;
    FOR v_row IN SELECT * FROM (VALUES ('equipment_goods', 'action.raise_po_equipment'),
                                       ('office', 'action.raise_po_office')) t(cat, code) LOOP
        v_msg := pg_temp.f229_try(format(
            'SELECT create_purchase_order(%L, CURRENT_DATE, NULL, %L, NULL, NULL, NULL, NULL, %L::jsonb, p_category => %L)',
            v_sup, v_base, jsonb_build_array(jsonb_build_object('material_id', m_cons, 'quantity', 5, 'unit', 'box',
                                                                'estimated_unit_price', 10)), v_row.cat));
        IF position('PERMISSION_DENIED|' || v_row.code IN v_msg) = 0 THEN
            RAISE EXCEPTION 'FIXTURE 229P2 失败:仓库开 % 应当缺 %,实得 %', v_row.cat, v_row.code, v_msg; END IF;
    END LOOP;
    -- P3 只持 purchasing.edit 的人一类都开不了
    PERFORM pg_temp.f229_as(u_cto);
    v_msg := pg_temp.f229_try(format(
        'SELECT create_purchase_order(%L, CURRENT_DATE, NULL, %L, NULL, NULL, NULL, NULL, %L::jsonb, p_category => ''consumables'')',
        v_sup, v_base, jsonb_build_array(jsonb_build_object('material_id', m_cons, 'quantity', 5, 'unit', 'box',
                                                            'estimated_unit_price', 10))));
    IF position('PERMISSION_DENIED|action.raise_po_consumables' IN v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 229P3 失败:module.purchasing.edit 不该再开得了单,实得 %', v_msg; END IF;
    -- P4 耗材单带资产行 / 电池料行 → 按名拒
    PERFORM pg_temp.f229_as(u_cfo2);
    v_msg := pg_temp.f229_try(format(
        'SELECT create_purchase_order(%L, CURRENT_DATE, NULL, %L, NULL, NULL, NULL, NULL, %L::jsonb, p_category => ''consumables'')',
        v_sup, v_base, jsonb_build_array(jsonb_build_object('asset_id', a_eq, 'quantity', 1, 'unit', 'unit',
                                                            'estimated_unit_price', 10))));
    IF position('PO_CATEGORY_LINE_MISMATCH|' IN v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 229P4 失败:耗材单带资产行应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f229_try(format(
        'SELECT create_purchase_order(%L, CURRENT_DATE, NULL, %L, NULL, NULL, NULL, NULL, %L::jsonb, p_category => ''office'')',
        v_sup, v_base, jsonb_build_array(jsonb_build_object('material_id', m_batt, 'quantity', 5, 'unit', 'kg',
                                                            'estimated_unit_price', 10))));
    IF position('PO_CATEGORY_LINE_MISMATCH|' IN v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 229P4 失败:办公用品单带电池料行应当按名拒,实得 %', v_msg; END IF;
    -- P5 cco 开设备与货物(电池料);财务开办公用品
    PERFORM pg_temp.f229_as(u_cco);
    po_e := (create_purchase_order(v_sup, CURRENT_DATE, NULL, v_base, NULL, NULL, NULL, NULL,
        jsonb_build_array(jsonb_build_object('material_id', m_batt, 'quantity', 5, 'unit', 'kg', 'estimated_unit_price', 10)),
        p_category => 'equipment_goods')->>'purchase_order_id')::uuid;
    PERFORM pg_temp.f229_as(u_fin);
    po_o := (create_purchase_order(v_sup, CURRENT_DATE, NULL, v_base, NULL, NULL, NULL, NULL,
        jsonb_build_array(jsonb_build_object('material_id', m_cons, 'quantity', 2, 'unit', 'box', 'estimated_unit_price', 10)),
        p_category => 'office')->>'purchase_order_id')::uuid;
    -- P6 品类改不了(属主路径直写也拒)
    PERFORM set_config('request.jwt.claims', '', true);
    BEGIN
        UPDATE purchase_orders SET category = 'office' WHERE id = po_c;
        v_msg := 'OK';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF position('PO_FIELD_IMMUTABLE|category|' IN v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 229P6 失败:品类应当改不了,实得 %', v_msg; END IF;
    rep := rep || jsonb_build_object('P_categories', true);

    -- ══════════════ Q · 谁能改 / 取消 / 关闭(Q7) ══════════════
    IF (SELECT array_agg(pg_temp.f229_may(u, po_c) ORDER BY o)
          FROM unnest(ARRAY[u_wh, u_wh2, u_cto, u_cco, u_fin]) WITH ORDINALITY x(u, o)) IS DISTINCT FROM
       ARRAY[true, true, false, false, false] THEN
        RAISE EXCEPTION 'FIXTURE 229Q1 失败:po_may_manage 对耗材单应当是 开单人 / 同类码 真,其余假'; END IF;
    PERFORM pg_temp.f229_as(u_cto);
    v_msg := pg_temp.f229_try(format('SELECT cancel_purchase_order(%L, ''x'')', po_c));
    IF position('PO_NOT_RAISER_OR_CATEGORY_HOLDER|' IN v_msg) = 0 OR position('action.raise_po_consumables' IN v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 229Q2 失败:只持 purchasing.edit 的人取消应当按名拒并说出那一类的码,实得 %', v_msg; END IF;
    PERFORM pg_temp.f229_as(u_cco);
    v_msg := pg_temp.f229_try(format('SELECT amend_purchase_order(%L, ''x'', %L::jsonb)', po_c,
                                     jsonb_build_object('notes', 'cco')));
    IF position('PO_NOT_RAISER_OR_CATEGORY_HOLDER|' IN v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 229Q2 失败:别的一类的开单人改耗材单应当按名拒,实得 %', v_msg; END IF;
    -- 开单人本人改得了;持同一类码的另一个人取消得了
    PERFORM pg_temp.f229_as(u_wh);
    PERFORM amend_purchase_order(po_c, 'fixture 229 raiser amends', jsonb_build_object('notes', 'raiser'));
    PERFORM pg_temp.f229_as(u_wh2);
    PERFORM cancel_purchase_order(po_c, 'fixture 229 category holder cancels');
    IF (SELECT status FROM purchase_orders WHERE id = po_c) <> 'cancelled' THEN
        RAISE EXCEPTION 'FIXTURE 229Q3 失败:持这一类码的人应当取消得了'; END IF;
    -- 批准照旧按档:一级批财务的小单
    PERFORM pg_temp.f229_as(u_l1);
    PERFORM approve_purchase_order(po_o, NULL);
    IF (SELECT approval_status FROM purchase_orders WHERE id = po_o) <> 'approved' THEN
        RAISE EXCEPTION 'FIXTURE 229Q4 失败:一级应当批得了 < 1,000 的办公用品单'; END IF;
    rep := rep || jsonb_build_object('Q_manage', true);

    -- ══════════════ R · 提单人之外没人批得动 ══════════════
    PERFORM pg_temp.f229_as(u_cfo2);
    SELECT count(*) INTO v_n FROM purchase_orders;
    v_msg := pg_temp.f229_try(format(
        'SELECT create_purchase_order(%L, CURRENT_DATE, NULL, %L, NULL, NULL, NULL, NULL, %L::jsonb, p_category => ''equipment_goods'')',
        v_sup, v_base, jsonb_build_array(jsonb_build_object('material_id', m_batt, 'quantity', 100, 'unit', 'kg',
                                                            'estimated_unit_price', 50))));
    IF position('PO_NO_OTHER_DECIDER|' IN v_msg) = 0 OR (SELECT count(*) FROM purchase_orders) <> v_n THEN
        RAISE EXCEPTION 'FIXTURE 229R1 失败:CFO 的另一个账号开 ≥ 1,000 的单应当按名拒且一张不落,实得 %', v_msg; END IF;
    po_big := (create_purchase_order(v_sup, CURRENT_DATE, NULL, v_base, NULL, NULL, NULL, NULL,
        jsonb_build_array(jsonb_build_object('material_id', m_batt, 'quantity', 1, 'unit', 'kg', 'estimated_unit_price', 50)),
        p_category => 'equipment_goods')->>'purchase_order_id')::uuid;
    IF po_big IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 229R2 失败:< 1,000 的单一级有人批,应当开得出'; END IF;
    rep := rep || jsonb_build_object('R_no_other_decider', true);

    -- ══════════════ S · 没有直连写 ══════════════
    PERFORM pg_temp.f229_as(u_cto);
    FOR v_row IN SELECT * FROM (VALUES
        (format('INSERT INTO purchase_orders (code, supplier_id, order_date, currency, fx_rate, category) VALUES (''FX229-RAW'', %L, CURRENT_DATE, %L, 1, ''consumables'')', v_sup, v_base)),
        (format('UPDATE purchase_orders SET notes = ''x'' WHERE id = %L', po_e)),
        (format('UPDATE purchase_order_lines SET notes = ''x'' WHERE purchase_order_id = %L', po_e)),
        (format('DELETE FROM purchase_order_payment_terms WHERE purchase_order_id = %L', po_e)),
        (format('DELETE FROM purchase_order_line_retentions WHERE purchase_order_line_id IN (SELECT id FROM purchase_order_lines WHERE purchase_order_id = %L)', po_e))
        ) t(sql) LOOP
        v_msg := pg_temp.f229_try(v_row.sql);
        IF position('PO_THROUGH_FUNCTION_ONLY' IN v_msg) = 0 THEN
            RAISE EXCEPTION 'FIXTURE 229S 失败:直连写应当按名拒 PO_THROUGH_FUNCTION_ONLY,实得 % (%)', v_msg, v_row.sql; END IF;
    END LOOP;
    rep := rep || jsonb_build_object('S_no_direct_writes', true);

    -- ══════════════ K · 故障注入一:直连写守卫是承重的 ══════════════
    PERFORM set_config('request.jwt.claims', '', true);
    BEGIN
        DROP TRIGGER trg_purchase_orders_direct_write ON public.purchase_orders;
        PERFORM pg_temp.f229_as(u_cto);
        v_msg := pg_temp.f229_try(format(
            'INSERT INTO purchase_orders (code, supplier_id, order_date, currency, fx_rate, category) VALUES (''FX229-RAW'', %L, CURRENT_DATE, %L, 1, ''consumables'')',
            v_sup, v_base));
        RAISE EXCEPTION 'F229K|%', v_msg;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE 'F229K|%' THEN v_msg := substr(SQLERRM, 7); ELSE RAISE; END IF;
    END;
    -- 摘掉守卫之后,那句按名拒不在了(写策略已经没了,所以落到 RLS 的原文 —— 关键是守卫那一句消失了)
    IF position('PO_THROUGH_FUNCTION_ONLY' IN v_msg) > 0 THEN
        RAISE EXCEPTION 'FIXTURE 229K 失败:摘掉守卫之后仍是守卫的那一句 —— 那句话不是它说的'; END IF;
    rep := rep || jsonb_build_object('K_direct_write_guard_load_bearing', v_msg);

    -- ══════════════ L · 故障注入二:锁守卫是承重的 ══════════════
    PERFORM pg_temp.f229_as(u_fin);
    q2 := (submit_gst_filing_request(p2)->>'request_id')::uuid;   -- p2 那一季(更早)在等
    PERFORM set_config('request.jwt.claims', '', true);
    BEGIN
        DROP TRIGGER trg_gst_filing_lock ON public.finance_settings;
        UPDATE finance_settings SET locked_before = v_q2_start + 10;
        RAISE EXCEPTION 'F229L|%', (SELECT locked_before FROM finance_settings);
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE 'F229L|%' THEN v_msg := substr(SQLERRM, 7); ELSE RAISE; END IF;
    END;
    IF v_msg <> (v_q2_start + 10)::text THEN
        RAISE EXCEPTION 'FIXTURE 229L 失败:摘掉锁守卫之后锁应当挪得回去(证明是它在拦),实得 %', v_msg; END IF;
    BEGIN
        UPDATE finance_settings SET locked_before = v_q2_start + 10;
        v_msg := 'OK';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF position('GST_FILING_WAITING_BLOCKS_REOPEN|' IN v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 229L 失败:守卫复原之后应当又拒,实得 %', v_msg; END IF;
    rep := rep || jsonb_build_object('L_lock_guard_load_bearing', true);

    RAISE NOTICE 'FIXTURE 229 全部通过: %', rep::text;
END;
$$;

ROLLBACK;
