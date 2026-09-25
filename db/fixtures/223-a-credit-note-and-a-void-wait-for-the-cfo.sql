-- 223 APR-5a:贷项通知与作废发票要 CFO 批准;绕过它的五条直连路关掉(2026-09-25)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】(APR-5 grilling Q9–Q11 · Q13,Tim 2026-09-25 全部接受)
--   A  引擎登记:链的名册只有二级一行,门 = module.finance.view + data.view_prices;operations_now 有
--        invoice_request_pending;五支内层算子 authenticated 调不到;两扇门对任何人都按名拒
--        INVOICE_NEEDS_APPROVED_REQUEST(没有码的人先听见 PERMISSION_DENIED)
--   B  ★★ 提贷项(审批开着):申请 submitted;贷项通知、分录、开放余额【一样都没动】;
--        留痕 submitted、二级、金额 = 试跑出的借方合计;在途清单那一支 blocks_disable、fixed_level = 2、主角 NULL
--   C  同一张发票第二张申请 → INVOICE_REQUEST_OPEN
--   D  谁批不了:提单人 → SELF_APPROVAL_FORBIDDEN|raiser;一级 → APPROVAL_NOT_AUTHORISED|2;
--        驳回不给理由 → INVOICE_REQUEST_REJECT_REASON_REQUIRED
--   E  ★ Q10:一条挂在在等的 unshipped_cancel 贷项申请里的发票行,发货 → INVOICE_CREDIT_REQUESTED
--   F  ★★ CFO 批准:当场过账,日期 = 冻结的凭证日;贷项通知一张、分录一张;1100 的减少 = 申请上的金额;
--        留痕 approved;申请上挂着贷项通知与分录
--   G  ★ Q11 ⑤:挂着贷项通知的发票,作废申请在提交时就按引擎原话拒 INVOICE_HAS_CREDIT_NOTES
--   H  ★ 作废申请在等:发货 → INVOICE_VOID_REQUESTED;收款【照收】(Q10);批准时引擎按名拒
--        INVOICE_HAS_SETTLEMENTS,整笔回滚,申请仍在等
--   I  撤回:既不是提单人、又不持 module.finance.edit → PERMISSION_DENIED;另一个财务撤得了
--   J  ★★ 提单人之外没人批得动:CFO 那个人的另一个账号提 → INVOICE_REQUEST_NO_OTHER_DECIDER,一行不落
--   K  驳回:要理由;驳回之后什么都没过账,留痕 rejected
--   L  ★★ CFO 批准一张作废:发票 void、行释放、冲销分录一张,申请上挂着它;金额 = 发票 total_base
--   M  ★★ Q11 ①–④ 直连路:以 authenticated 直连作废 / 翻 invoice_voided / 插发票 → INVOICE_THROUGH_FUNCTION_ONLY;
--        属主路径翻一张在册发票的 invoice_voided → INVOICE_IMMUTABLE;从 reverse_journal_entry 冲发票分录、
--        冲贷项分录 → JE_REVERSE_USE_SOURCE_PATH
--   N  审批关着:生下来 approved、当场过账、留痕 auto_approved
--   O  ★ 故障注入:摘掉 trg_invoices_direct_write,直连作废就变成【零行、不报错】—— 名字是守卫给的,
--        而拿掉写策略本身才是那道墙(发票仍是 issued)
--
-- 自带数据(README 第 2 条);锁期自己设(README 第 4 条)。全部本位币、汇率 1、不带税 ——
-- 本支钉的是申请这条链,贷项与作废的算术由 fixture 71 / 67 / 213 钉着(它们改调 *_internal)。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '180s';

CREATE FUNCTION pg_temp.f223_try(p_sql text, p_auth boolean DEFAULT false) RETURNS text
LANGUAGE plpgsql AS $f$
BEGIN
    IF p_auth THEN EXECUTE 'SET LOCAL ROLE authenticated'; END IF;
    EXECUTE p_sql;
    EXECUTE 'RESET ROLE';
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    RETURN SQLERRM;
END;
$f$;

CREATE FUNCTION pg_temp.f223_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', p_user), true)
$f$;

-- 这张发票在 1100 上的净借方(本位币):开票分录 + 贷项分录 + 它们的冲销。按发票与它的贷项归集;
-- 冲销分录的 source_id 指的是【原分录】(reverse_journal_entry_internal),所以再跳一跳。
CREATE FUNCTION pg_temp.f223_ar(p_invoice uuid) RETURNS numeric
LANGUAGE sql AS $f$
    WITH own AS (
        SELECT e.id FROM journal_entries e
         WHERE e.source_id = p_invoice
            OR e.source_id IN (SELECT cn.id FROM credit_notes cn WHERE cn.invoice_id = p_invoice))
    SELECT COALESCE(sum(l.debit - l.credit), 0)
      FROM journal_lines l JOIN journal_entries e ON e.id = l.entry_id
      JOIN accounts a ON a.id = l.account_id
     WHERE a.code = '1100'
       AND (e.id IN (SELECT id FROM own) OR e.source_id IN (SELECT id FROM own))
$f$;

DO $$
DECLARE
    u_set   uuid := gen_random_uuid();   -- 布景:全部码(建单、开票、预留)
    u_fin   uuid := gen_random_uuid();   -- 财务:module.finance.edit + 看得见
    u_fin2  uuid := gen_random_uuid();   -- 另一个财务(撤回那一臂)
    u_cfo   uuid := gen_random_uuid();   -- 二级:CFO 的形状 —— 看得见、【没有】finance.edit;在册员工 e_cfo 的主账号
    u_cfo2  uuid := gen_random_uuid();   -- ★ e_cfo 的另一个账号,持财务角色 —— "同一个人提的"那一臂
    u_l1    uuid := gen_random_uuid();   -- 一级
    u_wh    uuid := gen_random_uuid();   -- 不持 finance.edit
    r_all uuid; r_fin uuid; r_l1 uuid; r_l2 uuid; r_wh uuid;
    e_cfo uuid := gen_random_uuid();
    v_base text; v_cust uuid; v_mat uuid; v_ob uuid;
    soA uuid; soB uuid; soC uuid; LA1 uuid; LA2 uuid; LB1 uuid; LC1 uuid;
    invA uuid; invA_code text; invB uuid; invB_code text; invC uuid;
    ilA1 uuid; ilA2 uuid; ilB1 uuid;
    resA uuid; resB uuid;
    q uuid; q2 uuid; v_res jsonb; v_msg text; v_n int; v_je0 int; v_cn0 int; v_ar0 numeric; v_amt numeric;
    v_cn uuid; v_entry uuid;
    d  date := CURRENT_DATE;
    d0 date := CURRENT_DATE - 3;   -- 冻结的凭证日 / 冲销日:与批准那一天不同,才证得出"按冻结的日期"
BEGIN
    SELECT code INTO v_base FROM currencies WHERE is_base;
    UPDATE finance_settings SET locked_before = NULL, system_start_date = NULL;

    -- ══════════════ 布景 ══════════════
    INSERT INTO auth.users (id, email_confirmed_at) VALUES
        (u_set, now()), (u_fin, now()), (u_fin2, now()), (u_cfo, now()), (u_cfo2, now()), (u_l1, now()), (u_wh, now());
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx223-all','f','f',true) RETURNING id INTO r_all;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx223-fin','f','f',true) RETURNING id INTO r_fin;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx223-l1','f','f',true)  RETURNING id INTO r_l1;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx223-l2','f','f',true)  RETURNING id INTO r_l2;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx223-wh','f','f',true)  RETURNING id INTO r_wh;
    -- 布景那个角色持每一个码,但它不是任何一级的审批角色 —— 它批不了任何东西
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO role_permissions (role_id, permission_code) VALUES
        (r_fin, 'module.finance.edit'), (r_fin, 'module.finance.view'), (r_fin, 'data.view_prices'),
        (r_fin, 'module.sales.view'),
        -- 一级:审批开得了(每条分档链的门它都持)—— 批不了贷项申请只能因为【级别】
        (r_l1, 'module.purchasing.view'), (r_l1, 'data.view_prices'), (r_l1, 'data.view_purchase_prices'),
        (r_l1, 'module.finance.view'), (r_l1, 'module.hr.view'), (r_l1, 'data.view_pay'), (r_l1, 'module.inbound.view'),
        -- 二级:CFO 的形状 —— 读得到、看得见,【没有】module.finance.edit
        (r_l2, 'module.purchasing.view'), (r_l2, 'data.view_prices'), (r_l2, 'data.view_purchase_prices'),
        (r_l2, 'module.finance.view'), (r_l2, 'module.hr.view'), (r_l2, 'data.view_pay'), (r_l2, 'module.inbound.view'),
        (r_wh, 'module.inventory.view'), (r_wh, 'module.sales.view');
    INSERT INTO user_roles (user_id, role_id) VALUES
        (u_set, r_all), (u_fin, r_fin), (u_fin2, r_fin), (u_cfo, r_l2), (u_cfo2, r_fin), (u_l1, r_l1), (u_wh, r_wh);
    INSERT INTO employees (id, code, legal_name, employment_type, work_category, hire_date, user_id)
    VALUES (e_cfo, 'FX223-CFO', 'FX223 CFO', 'full_time', 'office', d - 400, u_cfo);
    INSERT INTO employee_accounts (user_id, employee_id) VALUES (u_cfo2, e_cfo);

    INSERT INTO customers (code, legal_name, country, payment_terms_days)
    VALUES ('ZZ223-C1', 'fixture 223 customer', 'SG', 30) RETURNING id INTO v_cust;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, unit)
    VALUES ('ZZFIX223-M', 'f223 material', 'battery_material', true, 'black_mass', 'end_of_life', 'kg') RETURNING id INTO v_mat;

    -- 三张订单、三张发票,全部本位币、汇率 1、不带税
    PERFORM pg_temp.f223_as(u_set);
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES (next_sales_order_code(d0), v_cust, d0, v_base, 1) RETURNING id INTO soA;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (soA, 1, v_mat, 10, 10) RETURNING id INTO LA1;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (soA, 2, v_mat, 20, 10) RETURNING id INTO LA2;
    PERFORM set_sales_order_status(soA, 'confirmed');
    v_res := create_order_invoice(soA, d0, NULL, NULL, NULL, ARRAY[LA1, LA2]);
    invA := (v_res->>'invoice_id')::uuid; invA_code := v_res->>'code';
    SELECT id INTO ilA1 FROM invoice_lines WHERE invoice_id = invA AND sales_order_line_id = LA1;
    SELECT id INTO ilA2 FROM invoice_lines WHERE invoice_id = invA AND sales_order_line_id = LA2;

    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES (next_sales_order_code(d0), v_cust, d0, v_base, 1) RETURNING id INTO soB;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (soB, 1, v_mat, 10, 10) RETURNING id INTO LB1;
    PERFORM set_sales_order_status(soB, 'confirmed');
    v_res := create_order_invoice(soB, d0, NULL, NULL, NULL, ARRAY[LB1]);
    invB := (v_res->>'invoice_id')::uuid; invB_code := v_res->>'code';
    SELECT id INTO ilB1 FROM invoice_lines WHERE invoice_id = invB;

    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES (next_sales_order_code(d0), v_cust, d0, v_base, 1) RETURNING id INTO soC;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (soC, 1, v_mat, 5, 10) RETURNING id INTO LC1;
    PERFORM set_sales_order_status(soC, 'confirmed');
    v_res := create_order_invoice(soC, d0, NULL, NULL, NULL, ARRAY[LC1]);
    invC := (v_res->>'invoice_id')::uuid;

    -- 预留(E、H 两臂发货用)
    v_ob := (create_output_batch(v_mat, 100, 'kg', d0, '库存中', NULL, NULL, NULL, NULL) ->> 'batch_id')::uuid;
    resA := (reserve_stock(LA1, v_ob, 10) ->> 'reservation_id')::uuid;
    resB := (reserve_stock(LB1, v_ob, 10) ->> 'reservation_id')::uuid;

    -- 策略:一级 fx223-l1、二级 fx223-l2;审批打开
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approval_level1_role_code = 'fx223-l1', approval_level2_role_code = 'fx223-l2',
                                approval_threshold_base = 1000;
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = true;

    -- ══════════════ A · 引擎登记与两扇门 ══════════════
    IF (SELECT array_agg(level::int ORDER BY level) FROM approval_chain_gates() WHERE subject_type = 'invoice_request')
         IS DISTINCT FROM ARRAY[2]
       OR (SELECT gate_permissions FROM approval_chain_gates() WHERE subject_type = 'invoice_request')
         IS DISTINCT FROM ARRAY['module.finance.view', 'data.view_prices']::text[] THEN
        RAISE EXCEPTION 'FIXTURE 223A1 失败:链的名册应当只有二级一行,门 = finance.view + view_prices'; END IF;
    IF position('invoice_request_pending' IN pg_get_viewdef('public.operations_now'::regclass)) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 223A2 失败:operations_now 没有 invoice_request_pending 那一支'; END IF;
    IF has_function_privilege('authenticated', 'public.void_invoice_internal(uuid, text, date)', 'EXECUTE')
       OR has_function_privilege('authenticated', 'public.create_credit_note_internal(uuid, date, text, jsonb)', 'EXECUTE')
       OR has_function_privilege('authenticated', 'public.invoice_request_submit_internal(uuid, text, date, text, jsonb)', 'EXECUTE')
       OR has_function_privilege('authenticated', 'public.invoice_request_post_internal(uuid)', 'EXECUTE')
       OR has_function_privilege('authenticated', 'public.invoice_request_dry_run(uuid)', 'EXECUTE') THEN
        RAISE EXCEPTION 'FIXTURE 223A3 失败:一支内层算子对 authenticated 可执行 —— 它们没有门,靠的就是调不到'; END IF;
    PERFORM pg_temp.f223_as(u_fin);
    v_msg := pg_temp.f223_try(format('SELECT void_invoice(%L, %L, %L)', invB, 'x', d), true);
    IF v_msg <> 'INVOICE_NEEDS_APPROVED_REQUEST|' || invB_code THEN
        RAISE EXCEPTION 'FIXTURE 223A4 失败:void_invoice 应当对财务按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f223_try(format('SELECT create_credit_note(%L, %L, %L, %L::jsonb)', invB, d, 'x',
        jsonb_build_array(jsonb_build_object('invoice_line_id', ilB1, 'kind', 'unshipped_cancel', 'amount', 1))), true);
    IF v_msg <> 'INVOICE_NEEDS_APPROVED_REQUEST|' || invB_code THEN
        RAISE EXCEPTION 'FIXTURE 223A5 失败:create_credit_note 应当对财务按名拒,实得 %', v_msg; END IF;
    PERFORM pg_temp.f223_as(u_wh);
    v_msg := pg_temp.f223_try(format('SELECT void_invoice(%L, %L, %L)', invB, 'x', d), true);
    IF v_msg <> 'PERMISSION_DENIED|module.finance.edit' THEN
        RAISE EXCEPTION 'FIXTURE 223A6 失败:没有码的人先听见 PERMISSION_DENIED,实得 %', v_msg; END IF;

    -- ══════════════ B · 提贷项(审批开着)══════════════
    SELECT count(*) INTO v_je0 FROM journal_entries;
    SELECT count(*) INTO v_cn0 FROM credit_notes;
    v_ar0 := pg_temp.f223_ar(invA);
    PERFORM pg_temp.f223_as(u_fin);
    v_res := submit_credit_note_request(invA, d0, 'fixture 223 B:第 1 行少发 4',
        jsonb_build_array(jsonb_build_object('invoice_line_id', ilA1, 'kind', 'unshipped_cancel', 'amount', 40)));
    q := (v_res->>'request_id')::uuid;
    IF v_res->>'status' <> 'submitted' OR (v_res->>'amount_base')::numeric <> 40 THEN
        RAISE EXCEPTION 'FIXTURE 223B1 失败:审批开着时应当提一张 submitted、金额 40 的申请,实得 %', v_res; END IF;
    IF (SELECT count(*) FROM credit_notes) <> v_cn0 OR (SELECT count(*) FROM journal_entries) <> v_je0
       OR pg_temp.f223_ar(invA) <> v_ar0
       OR (SELECT open_ccy FROM order_invoice_balance_all WHERE invoice_id = invA) <> 300 THEN
        RAISE EXCEPTION 'FIXTURE 223B2 失败:一张在等的申请不该动贷项通知、分录、1100 或开放余额'; END IF;
    IF NOT EXISTS (SELECT 1 FROM approval_log WHERE subject_type = 'invoice_request' AND subject_id = q
                    AND decision = 'submitted' AND level = 2 AND amount_base = 40 AND currency = v_base) THEN
        RAISE EXCEPTION 'FIXTURE 223B3 失败:留痕应当是 submitted、二级、40 本位币'; END IF;
    IF NOT EXISTS (SELECT 1 FROM approval_pending_documents() p WHERE p.subject_type = 'invoice_request'
                    AND p.doc_id = q AND p.blocks_disable AND p.fixed_level = 2 AND p.subject_employee_id IS NULL
                    AND p.raiser_user_id = u_fin) THEN
        RAISE EXCEPTION 'FIXTURE 223B4 失败:在途清单那一支应当 blocks_disable、fixed_level = 2、主角 NULL、提单人 u_fin'; END IF;

    -- ══════════════ C · 一张发票同时只挂一张 ══════════════
    v_msg := pg_temp.f223_try(format('SELECT submit_invoice_void_request(%L, %L, %L)', invA, 'fixture 223 C', d0));
    IF v_msg NOT LIKE 'INVOICE_REQUEST_OPEN|' || invA_code || '|%' THEN
        RAISE EXCEPTION 'FIXTURE 223C 失败:第二张申请应当按名拒,实得 %', v_msg; END IF;

    -- ══════════════ D · 谁批不了 ══════════════
    v_msg := pg_temp.f223_try(format('SELECT decide_invoice_request(%L, true)', q));
    IF v_msg <> 'SELF_APPROVAL_FORBIDDEN|raiser' THEN
        RAISE EXCEPTION 'FIXTURE 223D1 失败:提单人批不了自己的申请,实得 %', v_msg; END IF;
    PERFORM pg_temp.f223_as(u_l1);
    v_msg := pg_temp.f223_try(format('SELECT decide_invoice_request(%L, true)', q));
    IF v_msg NOT LIKE 'APPROVAL_NOT_AUTHORISED|2|%' THEN
        RAISE EXCEPTION 'FIXTURE 223D2 失败:一级批不了二级的链,实得 %', v_msg; END IF;
    PERFORM pg_temp.f223_as(u_cfo);
    v_msg := pg_temp.f223_try(format('SELECT decide_invoice_request(%L, false, %L)', q, '  '));
    IF v_msg NOT LIKE 'INVOICE_REQUEST_REJECT_REASON_REQUIRED|%' THEN
        RAISE EXCEPTION 'FIXTURE 223D3 失败:驳回要理由,实得 %', v_msg; END IF;

    -- ══════════════ E · Q10:在等的 unshipped_cancel 贷项按住那一行的发货 ══════════════
    PERFORM pg_temp.f223_as(u_set);
    v_msg := pg_temp.f223_try(format('SELECT ship_order(%L, %L, %L::jsonb)', soA, d,
        jsonb_build_array(jsonb_build_object('reservation_id', resA, 'qty', 10))));
    IF v_msg <> 'INVOICE_CREDIT_REQUESTED|' || invA_code || '|1' THEN
        RAISE EXCEPTION 'FIXTURE 223E 失败:在等的 unshipped_cancel 贷项应当按住第 1 行的发货,实得 %', v_msg; END IF;

    -- ══════════════ F · CFO 批准:当场过账,按冻结的凭证日 ══════════════
    PERFORM pg_temp.f223_as(u_cfo);
    v_res := decide_invoice_request(q, true, 'fixture 223 F');
    IF v_res->>'status' <> 'approved' THEN
        RAISE EXCEPTION 'FIXTURE 223F1 失败:批准应当成功,实得 %', v_res; END IF;
    SELECT result_credit_note_id, result_journal_entry_id, amount_base INTO v_cn, v_entry, v_amt
      FROM invoice_requests WHERE id = q AND status = 'approved' AND decided_by = u_cfo;
    IF v_cn IS NULL OR v_entry IS NULL OR v_amt <> 40 THEN
        RAISE EXCEPTION 'FIXTURE 223F2 失败:申请上应当挂着贷项通知与分录、金额 40'; END IF;
    IF (SELECT note_date FROM credit_notes WHERE id = v_cn) <> d0
       OR (SELECT entry_date FROM journal_entries WHERE id = v_entry) <> d0 THEN
        RAISE EXCEPTION 'FIXTURE 223F3 失败:贷项与分录应当记在冻结的凭证日 %,不是批准那天', d0; END IF;
    IF (SELECT count(*) FROM credit_notes) <> v_cn0 + 1 OR (SELECT count(*) FROM journal_entries) <> v_je0 + 1
       OR pg_temp.f223_ar(invA) <> v_ar0 - 40 THEN
        RAISE EXCEPTION 'FIXTURE 223F4 失败:应当恰好一张贷项、一张分录,1100 减 40(实得 % → %)', v_ar0, pg_temp.f223_ar(invA); END IF;
    IF NOT EXISTS (SELECT 1 FROM approval_log WHERE subject_type = 'invoice_request' AND subject_id = q
                    AND decision = 'approved' AND level = 2 AND amount_base = 40 AND actor_user_id = u_cfo) THEN
        RAISE EXCEPTION 'FIXTURE 223F5 失败:留痕应当是 approved、二级、40、CFO 按的'; END IF;

    -- ══════════════ G · 挂着贷项通知的发票不作废(Q11 ⑤)══════════════
    PERFORM pg_temp.f223_as(u_fin);
    v_msg := pg_temp.f223_try(format('SELECT submit_invoice_void_request(%L, %L, %L)', invA, 'fixture 223 G', d));
    IF v_msg <> format('INVOICE_HAS_CREDIT_NOTES|%s|1', invA_code) THEN
        RAISE EXCEPTION 'FIXTURE 223G 失败:挂着贷项通知的发票,作废申请应当在提交时按名拒,实得 %', v_msg; END IF;
    IF EXISTS (SELECT 1 FROM invoice_requests WHERE invoice_id = invA AND kind = 'void') THEN
        RAISE EXCEPTION 'FIXTURE 223G2 失败:被拒的提交不该留下一行'; END IF;

    -- ══════════════ H · 作废申请在等:发货挡、收款不挡、批准按引擎原话拒 ══════════════
    v_res := submit_invoice_void_request(invB, 'fixture 223 H:开错了', d0);
    q2 := (v_res->>'request_id')::uuid;
    IF v_res->>'status' <> 'submitted' OR (v_res->>'amount_base')::numeric <> 100 THEN
        RAISE EXCEPTION 'FIXTURE 223H1 失败:作废申请应当 submitted、金额 = 发票 total_base 100,实得 %', v_res; END IF;
    PERFORM pg_temp.f223_as(u_set);
    v_msg := pg_temp.f223_try(format('SELECT ship_order(%L, %L, %L::jsonb)', soB, d,
        jsonb_build_array(jsonb_build_object('reservation_id', resB, 'qty', 10))));
    IF v_msg <> 'INVOICE_VOID_REQUESTED|' || invB_code THEN
        RAISE EXCEPTION 'FIXTURE 223H2 失败:在等的作废申请应当按住这张发票的发货,实得 %', v_msg; END IF;
    -- 收款照收(Q10)
    PERFORM record_payment('in', v_cust, 30, v_base, NULL, '1000', d, 'fixture 223 H',
        jsonb_build_array(jsonb_build_object('invoice_id', invB, 'amount_doc', 30)));
    SELECT count(*) INTO v_je0 FROM journal_entries;
    PERFORM pg_temp.f223_as(u_cfo);
    v_msg := pg_temp.f223_try(format('SELECT decide_invoice_request(%L, true)', q2));
    IF v_msg NOT LIKE 'INVOICE_HAS_SETTLEMENTS|' || invB_code || '|%' THEN
        RAISE EXCEPTION 'FIXTURE 223H3 失败:等待期间收了款,批准应当按引擎原话拒,实得 %', v_msg; END IF;
    IF (SELECT status FROM invoice_requests WHERE id = q2) <> 'submitted'
       OR (SELECT status FROM invoices WHERE id = invB) <> 'issued'
       OR (SELECT count(*) FROM journal_entries) <> v_je0 THEN
        RAISE EXCEPTION 'FIXTURE 223H4 失败:被拒的批准应当整笔回滚,申请仍在等'; END IF;

    -- ══════════════ I · 撤回 ══════════════
    PERFORM pg_temp.f223_as(u_wh);
    v_msg := pg_temp.f223_try(format('SELECT withdraw_invoice_request(%L)', q2));
    IF v_msg <> 'PERMISSION_DENIED|module.finance.edit' THEN
        RAISE EXCEPTION 'FIXTURE 223I1 失败:不是提单人、不持 finance.edit 撤不了,实得 %', v_msg; END IF;
    PERFORM pg_temp.f223_as(u_fin2);
    v_res := withdraw_invoice_request(q2, 'fixture 223 I:收了款,改走贷项');
    IF (SELECT status || '|' || withdrawn_by::text FROM invoice_requests WHERE id = q2) <> 'withdrawn|' || u_fin2::text THEN
        RAISE EXCEPTION 'FIXTURE 223I2 失败:另一个财务应当撤得了,撤回记在行上'; END IF;
    IF EXISTS (SELECT 1 FROM approval_log WHERE subject_type = 'invoice_request' AND subject_id = q2
                AND decision NOT IN ('submitted')) THEN
        RAISE EXCEPTION 'FIXTURE 223I3 失败:撤回不是一次决定,不写 approval_log'; END IF;

    -- ══════════════ J · 提单人之外没人批得动 ══════════════
    SELECT count(*) INTO v_n FROM invoice_requests;
    PERFORM pg_temp.f223_as(u_cfo2);
    v_msg := pg_temp.f223_try(format('SELECT submit_credit_note_request(%L, %L, %L, %L::jsonb)', invB, d0, 'fixture 223 J',
        jsonb_build_array(jsonb_build_object('invoice_line_id', ilB1, 'kind', 'unshipped_cancel', 'amount', 10))));
    IF v_msg <> 'INVOICE_REQUEST_NO_OTHER_DECIDER|' || invB_code THEN
        RAISE EXCEPTION 'FIXTURE 223J1 失败:CFO 那个人的另一个账号提,应当按名拒,实得 %', v_msg; END IF;
    IF (SELECT count(*) FROM invoice_requests) <> v_n THEN
        RAISE EXCEPTION 'FIXTURE 223J2 失败:被拒的提交不该留下一行'; END IF;

    -- ══════════════ K · 驳回 ══════════════
    PERFORM pg_temp.f223_as(u_fin);
    v_res := submit_credit_note_request(invB, d0, 'fixture 223 K',
        jsonb_build_array(jsonb_build_object('invoice_line_id', ilB1, 'kind', 'unshipped_cancel', 'amount', 10)));
    q := (v_res->>'request_id')::uuid;
    SELECT count(*) INTO v_je0 FROM journal_entries;
    SELECT count(*) INTO v_cn0 FROM credit_notes;
    PERFORM pg_temp.f223_as(u_cfo);
    v_res := decide_invoice_request(q, false, 'fixture 223 K:不必');
    IF (SELECT status FROM invoice_requests WHERE id = q) <> 'rejected'
       OR (SELECT count(*) FROM journal_entries) <> v_je0 OR (SELECT count(*) FROM credit_notes) <> v_cn0
       OR NOT EXISTS (SELECT 1 FROM approval_log WHERE subject_type = 'invoice_request' AND subject_id = q
                       AND decision = 'rejected' AND note = 'fixture 223 K:不必') THEN
        RAISE EXCEPTION 'FIXTURE 223K 失败:驳回之后什么都不过账,留痕 rejected 带理由'; END IF;

    -- ══════════════ L · CFO 批准一张作废 ══════════════
    PERFORM pg_temp.f223_as(u_fin);
    v_res := submit_invoice_void_request(invC, 'fixture 223 L', d0);
    q := (v_res->>'request_id')::uuid;
    PERFORM pg_temp.f223_as(u_cfo);
    v_res := decide_invoice_request(q, true);
    SELECT result_journal_entry_id, amount_base INTO v_entry, v_amt FROM invoice_requests WHERE id = q AND status = 'approved';
    IF (SELECT status FROM invoices WHERE id = invC) <> 'void'
       OR (SELECT voided_by FROM invoices WHERE id = invC) <> u_cfo
       OR EXISTS (SELECT 1 FROM invoice_lines WHERE invoice_id = invC AND NOT invoice_voided)
       OR v_entry IS NULL OR v_amt <> 50
       OR (SELECT entry_date FROM journal_entries WHERE id = v_entry) <> d0
       OR pg_temp.f223_ar(invC) <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 223L 失败:批准的作废应当让发票 void、行释放、冲销记在冻结的日期、申请上挂着它、金额 50、1100 归零'; END IF;

    -- ══════════════ M · 直连路(Q11 ①–④)══════════════
    PERFORM pg_temp.f223_as(u_fin);
    v_msg := pg_temp.f223_try(format('UPDATE invoices SET status = %L, voided_at = now() WHERE id = %L', 'void', invB), true);
    IF v_msg <> 'INVOICE_THROUGH_FUNCTION_ONLY' THEN
        RAISE EXCEPTION 'FIXTURE 223M1 失败:直连作废应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f223_try(format('UPDATE invoice_lines SET invoice_voided = true WHERE invoice_id = %L', invB), true);
    IF v_msg <> 'INVOICE_THROUGH_FUNCTION_ONLY' THEN
        RAISE EXCEPTION 'FIXTURE 223M2 失败:直连翻 invoice_voided 应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f223_try(format(
        'INSERT INTO invoices (code, customer_id, issue_date, due_date, payment_terms_days, currency) VALUES (%L, %L, %L, %L, 0, %L)',
        'ZZ223-FAKE', v_cust, d, d, v_base), true);
    IF v_msg <> 'INVOICE_THROUGH_FUNCTION_ONLY' THEN
        RAISE EXCEPTION 'FIXTURE 223M3 失败:直连插一张发票应当按名拒,实得 %', v_msg; END IF;
    -- 属主路径:invoice_voided 只许由作废传播写
    v_msg := pg_temp.f223_try(format('UPDATE invoice_lines SET invoice_voided = true WHERE invoice_id = %L', invB));
    IF v_msg <> 'INVOICE_IMMUTABLE' THEN
        RAISE EXCEPTION 'FIXTURE 223M4 失败:一张在册发票的行不许被翻成已作废,实得 %', v_msg; END IF;
    v_msg := pg_temp.f223_try(format('SELECT reverse_journal_entry(%L, %L)', (SELECT entry_id FROM invoices WHERE id = invB), d));
    IF v_msg NOT LIKE 'JE_REVERSE_USE_SOURCE_PATH|%|invoice' THEN
        RAISE EXCEPTION 'FIXTURE 223M5 失败:从 reverse_journal_entry 冲开票分录应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f223_try(format('SELECT reverse_journal_entry(%L, %L)', (SELECT entry_id FROM credit_notes WHERE id = v_cn), d));
    IF v_msg NOT LIKE 'JE_REVERSE_USE_SOURCE_PATH|%|credit_note' THEN
        RAISE EXCEPTION 'FIXTURE 223M6 失败:从 reverse_journal_entry 冲贷项分录应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f223_try(format('SELECT reverse_journal_entry(%L, %L)', v_entry, d));
    IF v_msg NOT LIKE 'JE_REVERSE_USE_SOURCE_PATH|%|invoice' THEN
        RAISE EXCEPTION 'FIXTURE 223M7 失败:冲掉作废留下的那张冲销分录 = 不经批准地复活发票,应当按名拒,实得 %', v_msg; END IF;

    -- ══════════════ N · 审批关着 ══════════════
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = false;
    SELECT count(*) INTO v_cn0 FROM credit_notes;
    PERFORM pg_temp.f223_as(u_fin);
    v_res := submit_credit_note_request(invB, d0, 'fixture 223 N',
        jsonb_build_array(jsonb_build_object('invoice_line_id', ilB1, 'kind', 'unshipped_cancel', 'amount', 10)));
    q := (v_res->>'request_id')::uuid;
    IF v_res->>'status' <> 'approved'
       OR (SELECT status FROM invoice_requests WHERE id = q) <> 'approved'
       OR (SELECT count(*) FROM credit_notes) <> v_cn0 + 1
       OR NOT EXISTS (SELECT 1 FROM approval_log WHERE subject_type = 'invoice_request' AND subject_id = q
                       AND decision = 'auto_approved' AND level IS NULL) THEN
        RAISE EXCEPTION 'FIXTURE 223N 失败:审批关着时申请生下来就是 approved、当场过账、留痕 auto_approved,实得 %', v_res; END IF;

    -- ══════════════ O · 故障注入:摘掉直连守卫 ══════════════
    DROP TRIGGER trg_invoices_direct_write ON public.invoices;
    PERFORM pg_temp.f223_as(u_fin);
    v_msg := pg_temp.f223_try(format('UPDATE invoices SET status = %L, voided_at = now() WHERE id = %L', 'void', invB), true);
    IF v_msg <> 'OK' THEN
        RAISE EXCEPTION 'FIXTURE 223O1 失败:摘掉守卫之后直连作废应当是【零行、不报错】(名字是守卫给的),实得 %', v_msg; END IF;
    IF (SELECT status FROM invoices WHERE id = invB) <> 'issued' THEN
        RAISE EXCEPTION 'FIXTURE 223O2 失败:没有写策略,直连作废不该碰到任何一行'; END IF;

    RAISE NOTICE 'FIXTURE 223 全部通过:A 登记与门 · B 提贷项 · C 一张一张 · D 谁批不了 · E 贷项按住发货 · F 批准过账 · G 有贷项不作废 · H 作废在等 · I 撤回 · J 没有别人 · K 驳回 · L 批准作废 · M 直连路 · N 审批关着 · O 注入';
END;
$$;
ROLLBACK;
