-- ═══════════════════════════════════════════════════════════════════════════
-- fixture 263 —— 一张开着的不合格报告就是那一批的质量暂扣,由另一个人决定;卖方合同的质量验收限越限时自己开一张
--   (MES-6b-1,2026-10-15;MES-0 Q53 · Q65 · Q66;MES-6b Step 0 Q2–Q9 · Q15 · Q16 · Q21–Q27 · Q33 · Q36–Q39,Tim 照推荐裁定)
-- ═══════════════════════════════════════════════════════════════════════════
-- 臂:
--   REG    码 action.ncr_decide 在、声明 module.quality.view;单据登记 ncr → NCR;三张新表进变更记录、豁免仍是 8 —— MES-9b 起是 9;审计主语 ncr 在、
--          报告挂在两个批次主语下、判定挂在产出批下、质量验收限挂在合同下
--   NCR    开:module.quality.edit(没有 → PERMISSION_DENIED);恰好一批;来源 manual / customer_complaint 收,quality_limit 只由系统开
--          (NCR_SOURCE_SYSTEM_ONLY)、别的 NCR_SOURCE_INVALID;★ MES-7b-2(Q15):inspection 不再保留 —— 引用一条巡检发现时收、那一批进质量暂扣
--          (接受那一臂),不引用时按名拒 NCR_INSPECTION_FINDING_REQUIRED、给了发现却换个来源拒 NCR_INSPECTION_FINDING_ONLY_WITH_SOURCE(拒绝那一臂);描述必填;指向必须同一批
--          (化验 · 争议 · 销售单 · 判定),销售单只给产出批;编号 NCR-<年>-NNNN 按年无洞(next_ncr_code 与公式一致);一批可以同时几张开着;
--          只经函数:直连插被拒(RLS)、改非决定列 / 删 → NCR_IMMUTABLE
--   DECIDE action.ncr_decide(没有 → PERMISSION_DENIED);开单人按【人】认永远不能决定自己那一张(同一个人的另一个账号也不行 →
--          SELF_APPROVAL_FORBIDDEN|raiser);说明必填;处置按名核对;带罚接受要指一张对的钱的单据(产出 → 贷项通知申请;进料 → 这一批的
--          收货定价申请),别的处置不许带;决定过的不能再决定(NCR_NOT_OPEN);除开单人之外没人持码 → 开不出来(NCR_NO_OTHER_DECIDER,
--          开单人自己持码也不算);系统开的那一张任何持码人都能决定
--   DISP   五种处置的效果:accept / accept_with_penalty / rework / downgrade 放行;reject 不放行;几张开着时最后一张决定了才放行;
--          拒收的那一批走 CFO 注销申请出去 → 货没了,暂扣结束
--   HOLD   流水上逐种(直连插,每一格自己的子事务):投料 · 销售 · 进 committed 的状态腿 · 不在申请里的注销 → QUALITY_HOLD_OPEN|批号|报告;
--          收货 · 产出 · 冲销两腿 · 盘点 · available ↔ on_hold · committed → available · 两种转移(含 committed 桶的)· 申请里的注销 → 放行;
--          函数那一层:预留按名拒且什么都不落、直接销售按名拒、转移 / 暂扣 / 释放照常、已有的预留留着且释放得了、发货按名拒、
--          加工投料按名拒;报告决定放行之后发货照走
--   SETTLE 结算(预览与落库同一支算术)按名拒 QUALITY_HOLD_OPEN;放行之后算得出
--   BLEND  配料计划:建 / 改不收被暂扣的一行;草稿之后一行进了暂扣 → 放行按名拒;放行它之后照常放行
--   V17    生效清单:口径没声明 → quality_limit_basis;per_parameter 没有行 → quality_limits,申请生效按名拒 QUALITY_LIMITS_NOT_FILED;
--          同一种物质既计价又罚:两张条款表各自按名拒 SUBSTANCE_PRICED_AND_PENALISED,条款表之外写进去的申请生效时按名拒;
--          质量验收限随合同冻结(CONTRACT_TERMS_FROZEN)、进 CFO 的条款状态、挂接时抄进副本(口径 + 几行限)
--   JUDGE  记化验时:预留给有限的单的那一批 → 一个参数一行(指名物料的限优先、没报的 not_measured),越限当场开一张系统的报告
--          (没有开单人、指回化验 / 单 / 判定);只判合同约定那一方的结果;同一份化验同一张单只判一次(再预留、合同改了都不重判);
--          新的一份化验照判。预留时:一批已有化验的预留给有限的单 → 预留留着、同一笔事务里开报告;结案的争议点名的那一份说了算
--   F5     进料:一份只测了氟、氯的化验是补充 —— 只换掉氟、氯,镍不动,不计价,不取代也不被取代;试算说"补充、只换这几种";
--          撤销只删它自己那几行;之后一份完整的化验照旧整份换
--   ARMS   ncr_open · quality_hold_reserved(销售查看 + 产出查看看得见;只有销售查看的看不见)· quality_prompt_ncr(品位违反 ·
--          交叉污染过线 · 放电失败;开了报告就消失)· 待补的值 V17(挂了单、口径没声明的卖方合同;声明了就消失)
--   AGREE  每一步动钱之后(定价申请、贷项通知、发货、注销)应付 / 应收清单 = 总账,未解释 0.00
--
-- 自带数据(README 第 2 条);锁期、审批开关、行情与日历自己设(第 4、5 条)。审批【关着】:放行、生效申请、贷项与注销申请当场生效 ——
--   那几条链本身各有 fixture;这里要证的是暂扣在它们执行的那一刻咬不咬人。以 postgres 跑;员工的调用切成 authenticated + JWT。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '300s';

CREATE FUNCTION pg_temp.f263_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims',
                      CASE WHEN p_user IS NULL THEN '' ELSE format('{"sub":"%s","role":"authenticated"}', p_user) END, true)
$f$;

-- GOLIVE-2(Tim 2026-10-30 Q5):sale_settlement_compute 的 authenticated EXECUTE 收回,它从此只在 record_sale_settlement(SECURITY DEFINER)
--   的函数体里以属主身份跑。这一支要证的是它的【按名拒绝】(与读者是谁无关的那几条),所以读者那一侧的调用走这个属主身份的小壳 ——
--   与 record_sale_settlement 给它的是同一个上下文(属主 + 读者的 claims)。直接调被拒那一件由 fixture 304 的 F / G 证。
CREATE FUNCTION pg_temp.f263_compute(p_so uuid, p_ob uuid, p_as uuid) RETURNS jsonb LANGUAGE sql SECURITY DEFINER
    AS $c$ SELECT public.sale_settlement_compute(p_so, p_ob, p_as) $c$;

CREATE FUNCTION pg_temp.f263_do(p_user uuid, p_sql text) RETURNS text
LANGUAGE plpgsql AS $f$
DECLARE v_prev text := NULLIF(current_setting('request.jwt.claims', true), '');
BEGIN
    PERFORM pg_temp.f263_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_prev, ''), true);
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_prev, ''), true);
    RETURN SQLERRM;
END;
$f$;

CREATE FUNCTION pg_temp.f263_get(p_user uuid, p_sql text) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v jsonb; v_prev text := NULLIF(current_setting('request.jwt.claims', true), '');
BEGIN
    PERFORM pg_temp.f263_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_prev, ''), true);
    RETURN v;
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_prev, ''), true);
    RAISE;
END;
$f$;

CREATE FUNCTION pg_temp.f263_user(p_label text, p_codes text[]) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE u uuid := gen_random_uuid(); r uuid;
BEGIN
    INSERT INTO auth.users (id, email, email_confirmed_at, created_at) VALUES (u, 'fx263-' || p_label || '@test.local', now(), now());
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx263-' || p_label, 'f', 'f', true) RETURNING id INTO r;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r, c FROM unnest(p_codes) c;
    INSERT INTO user_roles (user_id, role_id) VALUES (u, r);
    RETURN u;
END;
$f$;

-- 应付 / 应收清单 = 总账,两边 unexplained 0.00(以全码那个人的会话读)
CREATE FUNCTION pg_temp.f263_agree(p_user uuid, p_step text) RETURNS void
LANGUAGE plpgsql AS $f$
DECLARE v jsonb; s jsonb;
BEGIN
    v := pg_temp.f263_get(p_user, $q$SELECT list_ledger_reconciliation()$q$);
    IF jsonb_array_length(v -> 'sides') <> 2 THEN RAISE EXCEPTION 'FIXTURE 263 AGREE %: expected two sides, got %', p_step, v; END IF;
    FOR s IN SELECT * FROM jsonb_array_elements(v -> 'sides') LOOP
        IF s ->> 'refusal' IS NOT NULL OR (s ->> 'unexplained_base')::numeric IS DISTINCT FROM 0 THEN
            RAISE EXCEPTION 'FIXTURE 263 AGREE %: % side list % / ledger % / unexplained % (refusal %)', p_step, s ->> 'side',
                s ->> 'list_base', s ->> 'ledger_base', s ->> 'unexplained_base', s ->> 'refusal';
        END IF;
    END LOOP;
END;
$f$;

-- 流水上的一格:直连插一行(属主路径 —— 守卫不认是谁写的),在自己的子事务里;放行的那一格用一个哨兵异常把它收回去,
--   于是没有一行留下来去碰 remaining_qty 的不变式。返回 'ALLOWED' 或那一句拒绝。
CREATE FUNCTION pg_temp.f263_leg(p_in uuid, p_out uuid, p_type text, p_qty numeric, p_status text, p_ctx text) RETURNS text
LANGUAGE plpgsql AS $f$
BEGIN
    PERFORM set_config('evoltrya.warehouse_request_ctx', COALESCE(p_ctx, ''), true);
    -- MES-7a-2:两种保养流水只经 issue_spare_parts / return_spare_parts 写(它们设这个上下文)—— 这里替它们设,好让问题只剩"暂扣挡不挡"
    PERFORM set_config('evoltrya.part_issue_ctx', CASE WHEN p_type LIKE 'maintenance%' THEN 'fixture' ELSE '' END, true);
    INSERT INTO inventory_movements (inbound_batch_id, output_batch_id, movement_type, qty_delta, stock_status, pair_id, business_date, notes)
    VALUES (p_in, p_out, p_type, p_qty, p_status,
            CASE WHEN p_type IN ('status_change_out', 'status_change_in', 'transfer_out', 'transfer_in') THEN gen_random_uuid() END,
            CURRENT_DATE, 'fixture 263 HOLD');
    RAISE EXCEPTION 'F263_LEG_ALLOWED';
EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('evoltrya.warehouse_request_ctx', '', true);
    PERFORM set_config('evoltrya.part_issue_ctx', '', true);
    IF SQLERRM = 'F263_LEG_ALLOWED' THEN RETURN 'ALLOWED'; END IF;
    RETURN SQLERRM;
END;
$f$;

CREATE FUNCTION pg_temp.f263_held(p_in uuid, p_out uuid) RETURNS text
LANGUAGE sql AS $f$
    SELECT (SELECT h.ncr_code FROM batch_quality_hold(p_in, p_out) h)
$f$;

DO $$
DECLARE
    u_all uuid; u_qe uuid; u_qe2 uuid; u_qv uuid; u_d1 uuid; u_d2 uuid; u_alt uuid; u_rec uuid; u_apl uuid; u_sal uuid; u_salonly uuid;
    u_wh uuid; u_wo uuid; u_rel uuid; u_cco uuid; u_ds uuid; u_sf uuid; v_tpl uuid; v_find uuid;
    e_qe uuid := gen_random_uuid();
    v_today date := CURRENT_DATE; v_year int := EXTRACT(YEAR FROM CURRENT_DATE)::int; v_base text;
    v_sup uuid; v_mat uuid; v_mat2 uuid; v_cust uuid; v_loc uuid;
    ib_h uuid; ob_h uuid; ib_m uuid; ob_m uuid; ib_c uuid; ib_s uuid; ib_g uuid; ob_c uuid; ob_d uuid;
    ob1 uuid; ob2 uuid; ob3 uuid; ob4 uuid; ob5 uuid; ob6 uuid; ob_r uuid;
    conQ uuid; conV uuid; conP uuid; conB uuid; so1 uuid; so2 uuid; soV uuid; l1 uuid; l2 uuid; l3 uuid; lv uuid;
    po uuid; v_inv uuid; v_il uuid; v_rel uuid;
    n1 uuid; n2 uuid; n3 uuid; n4 uuid; n5 uuid; n6 uuid; n7 uuid; n8 uuid; ns uuid;
    a1 uuid; a2 uuid; a3 uuid; ac uuid; ao uuid; a_s uuid; a_f uuid; d_g uuid;
    r1 uuid; r2 uuid; r3 uuid; r4 uuid; run_c uuid; plan uuid;
    v_j jsonb; v_j2 jsonb; v_msg text; v_msg2 text; v_n bigint; v_n2 bigint; v_code text; v_code2 text; v_txt text;
    v_cn_req uuid; v_pr_req uuid;
BEGIN
    SELECT code INTO v_base FROM currencies WHERE is_base;
    PERFORM pg_temp.f263_as(NULL);
    UPDATE finance_settings SET locked_before = NULL, system_start_date = NULL;
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = false;
    PERFORM set_config('evoltrya.approvals_policy_ctx', '', true);

    u_all  := pg_temp.f263_user('all', (SELECT array_agg(code) FROM permissions));
    u_qe   := pg_temp.f263_user('qe', ARRAY['module.quality.view', 'module.quality.edit', 'module.inbound.view', 'module.output.view']);
    u_qe2  := pg_temp.f263_user('qe2', ARRAY['module.quality.view', 'module.quality.edit', 'module.inbound.view', 'module.output.view']);
    u_qv   := pg_temp.f263_user('qv', ARRAY['module.quality.view', 'module.suppliers.view']);
    u_d1   := pg_temp.f263_user('d1', ARRAY['action.ncr_decide', 'module.quality.view', 'module.finance.view']);
    u_d2   := pg_temp.f263_user('d2', ARRAY['action.ncr_decide', 'module.quality.view']);
    -- 开单人这个人的另一个账号,持决定码 —— "按人认"那一格
    u_alt  := pg_temp.f263_user('alt', ARRAY['action.ncr_decide', 'module.quality.view']);
    INSERT INTO employees (id, code, legal_name, employment_type, work_category, hire_date, user_id)
    VALUES (e_qe, 'FX263-QE', 'FX263 quality engineer', 'full_time', 'office', v_today - 400, u_qe);
    INSERT INTO employee_accounts (user_id, employee_id) VALUES (u_alt, e_qe);
    u_rec  := pg_temp.f263_user('rec', ARRAY['module.inbound.view', 'module.inbound.edit', 'module.output.view', 'module.output.edit']);
    u_apl  := pg_temp.f263_user('apl', ARRAY['action.apply_assay', 'module.inbound.view', 'module.output.view', 'data.view_purchase_prices']);
    u_sal  := pg_temp.f263_user('sal', ARRAY['module.sales.view', 'module.sales.edit', 'module.output.view']);
    u_salonly := pg_temp.f263_user('salonly', ARRAY['module.sales.view']);
    u_wh   := pg_temp.f263_user('wh', ARRAY['module.inventory.view', 'module.inventory.edit', 'module.output.view', 'module.inbound.view', 'action.ship_goods']);
    u_wo   := pg_temp.f263_user('wo', ARRAY['action.wo_create', 'module.processing.view', 'module.inbound.view', 'module.output.view']);
    u_rel  := pg_temp.f263_user('rel', ARRAY['action.wo_release', 'module.processing.view']);
    u_cco  := pg_temp.f263_user('cco', ARRAY['action.contract_terms', 'module.customers.view', 'module.customers.edit', 'module.suppliers.view', 'module.suppliers.edit']);
    u_ds   := pg_temp.f263_user('ds', ARRAY['action.direct_sale', 'module.output.view', 'module.customers.view']);
    -- MES-7b-2(Q15):一个安全编辑 —— 记一次巡检与它的发现,供来源 inspection 的那一臂引用
    u_sf   := pg_temp.f263_user('sf', ARRAY['module.safety.view', 'module.safety.edit']);

    -- ══════════════ 布景 ══════════════
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ263-S', 'f263 supplier', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, unit)
    VALUES ('ZZ263-BM', 'f263 black mass', 'battery_material', true, 'black_mass', 'end_of_life', 'kg') RETURNING id INTO v_mat;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, unit)
    VALUES ('ZZ263-BM2', 'f263 other black mass', 'battery_material', true, 'black_mass', 'end_of_life', 'kg') RETURNING id INTO v_mat2;
    INSERT INTO customers (code, legal_name, country, payment_terms_days) VALUES ('ZZ263-C', 'f263 customer', 'SG', 30) RETURNING id INTO v_cust;
    INSERT INTO storage_locations (code, name) VALUES ('ZZ263-L1', 'f263 shelf') RETURNING id INTO v_loc;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note) VALUES
        ('ZZ263-IBH', v_mat, v_sup, 100, 100, 'kg', v_today - 5, 'other', 'fixture 263'),
        ('ZZ263-IBM', v_mat, v_sup, 100, 100, 'kg', v_today - 5, 'other', 'fixture 263'),
        ('ZZ263-IBC', v_mat, v_sup, 100, 100, 'kg', v_today - 5, 'other', 'fixture 263'),
        ('ZZ263-IBS', v_mat, v_sup, 100, 100, 'kg', v_today - 5, 'other', 'fixture 263');
    SELECT id INTO ib_h FROM inbound_batches WHERE code = 'ZZ263-IBH';
    SELECT id INTO ib_m FROM inbound_batches WHERE code = 'ZZ263-IBM';
    SELECT id INTO ib_c FROM inbound_batches WHERE code = 'ZZ263-IBC';
    SELECT id INTO ib_s FROM inbound_batches WHERE code = 'ZZ263-IBS';
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    SELECT id, 'discharged_verified' FROM inbound_batches WHERE code LIKE 'ZZ263-IB%';
    PERFORM pg_temp.f263_as(u_all);
    ob_h := (create_output_batch(v_mat, 100, 'kg', v_today - 3) ->> 'batch_id')::uuid;
    ob_m := (create_output_batch(v_mat, 100, 'kg', v_today - 3) ->> 'batch_id')::uuid;
    ob1  := (create_output_batch(v_mat, 100, 'kg', v_today - 3) ->> 'batch_id')::uuid;
    ob2  := (create_output_batch(v_mat, 100, 'kg', v_today - 3) ->> 'batch_id')::uuid;
    ob3  := (create_output_batch(v_mat, 100, 'kg', v_today - 3) ->> 'batch_id')::uuid;
    ob4  := (create_output_batch(v_mat2, 100, 'kg', v_today - 3) ->> 'batch_id')::uuid;
    ob5  := (create_output_batch(v_mat, 100, 'kg', v_today - 3) ->> 'batch_id')::uuid;
    ob6  := (create_output_batch(v_mat, 100, 'kg', v_today - 3) ->> 'batch_id')::uuid;
    ob_r := (create_output_batch(v_mat, 100, 'kg', v_today - 3) ->> 'batch_id')::uuid;
    ob_c := (create_output_batch(v_mat, 100, 'kg', v_today - 3) ->> 'batch_id')::uuid;
    ob_d := (create_output_batch(v_mat, 100, 'kg', v_today - 3) ->> 'batch_id')::uuid;
    PERFORM pg_temp.f263_as(NULL);
    PERFORM pg_temp.f263_agree(u_all, 'start');

    -- ══════════════ REG ══════════════
    RAISE NOTICE 'fixture 263 · REG';
    IF NOT EXISTS (SELECT 1 FROM permissions WHERE code = 'action.ncr_decide' AND category = 'action'
                     AND requires_view_any = ARRAY['module.quality.view']) THEN
        RAISE EXCEPTION 'FIXTURE 263 REG: action.ncr_decide must exist and declare module.quality.view'; END IF;
    IF document_type_prefix('ncr') <> 'NCR' OR NOT EXISTS (SELECT 1 FROM document_types WHERE key = 'ncr'
         AND table_name = 'nonconformance_reports' AND numbering = 'gapless' AND route = '/quality/ncr') THEN
        RAISE EXCEPTION 'FIXTURE 263 REG: the document registry carries ncr → NCR, gapless, /quality/ncr'; END IF;
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 10 THEN
        RAISE EXCEPTION 'FIXTURE 263 REG: change-log coverage has no gap and exactly 8 exclusions, got %', v_j; END IF;
    SELECT count(*) INTO v_n FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
     WHERE t.tgname = 'zzz_change_log' AND c.relname IN ('nonconformance_reports', 'contract_quality_limits', 'quality_limit_judgements');
    IF v_n <> 3 THEN RAISE EXCEPTION 'FIXTURE 263 REG: the three new tables are change-logged, got %', v_n; END IF;
    IF NOT EXISTS (SELECT 1 FROM trail_subjects() s WHERE s.subject = 'ncr' AND s.root_table = 'nonconformance_reports'
                     AND s.view_codes = ARRAY['module.quality.view']) THEN
        RAISE EXCEPTION 'FIXTURE 263 REG: trail subject ncr (root nonconformance_reports, module.quality.view)'; END IF;
    SELECT count(*) INTO v_n FROM trail_subject_members() m
     WHERE (m.subject, m.table_name, m.home) IN (('inbound_batch', 'nonconformance_reports', false), ('output_batch', 'nonconformance_reports', false),
                                                ('output_batch', 'quality_limit_judgements', true), ('contract', 'contract_quality_limits', true));
    IF v_n <> 4 THEN RAISE EXCEPTION 'FIXTURE 263 REG: NCRs under both batch subjects, judgements under the output batch, limits under the contract, got %', v_n; END IF;

    -- ══════════════ NCR ══════════════
    RAISE NOTICE 'fixture 263 · NCR';
    v_msg := pg_temp.f263_do(u_qv, format($q$SELECT open_ncr('manual', 'x', p_inbound_batch_id => %L)$q$, ib_h));
    IF v_msg NOT LIKE 'PERMISSION_DENIED|module.quality.edit%' THEN RAISE EXCEPTION 'FIXTURE 263 NCR: opening needs module.quality.edit, got %', v_msg; END IF;
    v_msg := pg_temp.f263_do(u_qe, format($q$SELECT open_ncr('manual', 'x', p_inbound_batch_id => %L, p_output_batch_id => %L)$q$, ib_h, ob_h));
    IF v_msg <> 'NCR_ONE_BATCH' THEN RAISE EXCEPTION 'FIXTURE 263 NCR: exactly one batch, got %', v_msg; END IF;
    v_msg := pg_temp.f263_do(u_qe, format($q$SELECT open_ncr('quality_limit', 'x', p_inbound_batch_id => %L)$q$, ib_h));
    IF v_msg <> 'NCR_SOURCE_SYSTEM_ONLY' THEN RAISE EXCEPTION 'FIXTURE 263 NCR: quality_limit is opened by the system only, got %', v_msg; END IF;
    -- ★ MES-7b-2(2026-10-16,MES-7b Step 0 Q15):来源 inspection —— 原来这里断言"留着"(NCR_SOURCE_RESERVED|inspection);现在两臂:
    --   拒绝那一臂:不引用一条发现 → NCR_INSPECTION_FINDING_REQUIRED;引用了发现而来源不是 inspection → NCR_INSPECTION_FINDING_ONLY_WITH_SOURCE;
    --   发现不存在 → INSPECTION_FINDING_NOT_FOUND。接受那一臂:引用一条巡检发现 → 开得出来,来源 inspection、指着那条发现,那一批进质量暂扣
    --   (batch_quality_hold)—— 包在一个回滚的子块里,于是后面每一臂看见的仍是"这一批没有报告"(每一臂自己的数据,README 第 2 条)。
    v_msg := pg_temp.f263_do(u_qe, format($q$SELECT open_ncr('inspection', 'x', p_inbound_batch_id => %L)$q$, ib_h));
    IF v_msg NOT LIKE 'NCR_INSPECTION_FINDING_REQUIRED%' THEN RAISE EXCEPTION 'FIXTURE 263 NCR: an inspection-source NCR must cite a finding, got %', v_msg; END IF;
    v_j := pg_temp.f263_get(u_sf, $q$SELECT save_inspection_template(NULL, 'ZZ263-T', 'f263 checklist', 'f263 bay', '["Cells stored dry"]'::jsonb)$q$);
    v_tpl := (v_j ->> 'template_id')::uuid;
    v_j := pg_temp.f263_get(u_sf, format($q$SELECT record_inspection_run(%L, now() - interval '1 hour', %L,
               '[{"position": 1, "result": "fail", "note": "f263 water under the pallet"}]'::jsonb,
               p_findings => jsonb_build_array(jsonb_build_object('position', 1, 'corrective_action', 'f263 dry the batch and recheck', 'owner_employee_id', %L)))$q$,
               v_tpl, e_qe, e_qe));
    SELECT id INTO v_find FROM inspection_findings WHERE run_id = (v_j ->> 'run_id')::uuid;
    IF v_find IS NULL THEN RAISE EXCEPTION 'FIXTURE 263 NCR: the inspection finding for the inspection-source arm was not recorded'; END IF;
    v_msg := pg_temp.f263_do(u_qe, format($q$SELECT open_ncr('manual', 'x', p_inbound_batch_id => %L, p_inspection_finding_id => %L)$q$, ib_h, v_find));
    IF v_msg NOT LIKE 'NCR_INSPECTION_FINDING_ONLY_WITH_SOURCE%' THEN RAISE EXCEPTION 'FIXTURE 263 NCR: a finding only goes with the inspection source, got %', v_msg; END IF;
    v_msg := pg_temp.f263_do(u_qe, format($q$SELECT open_ncr('inspection', 'x', p_inbound_batch_id => %L, p_inspection_finding_id => gen_random_uuid())$q$, ib_h));
    IF v_msg NOT LIKE 'INSPECTION_FINDING_NOT_FOUND|%' THEN RAISE EXCEPTION 'FIXTURE 263 NCR: an unknown finding is refused by name, got %', v_msg; END IF;
    BEGIN
        v_j := pg_temp.f263_get(u_qe, format($q$SELECT open_ncr('inspection', 'f263 wet cells found on inspection', p_inbound_batch_id => %L, p_inspection_finding_id => %L)$q$, ib_h, v_find));
        IF (SELECT source FROM nonconformance_reports WHERE id = (v_j ->> 'ncr_id')::uuid) IS DISTINCT FROM 'inspection'
           OR (SELECT inspection_finding_id FROM nonconformance_reports WHERE id = (v_j ->> 'ncr_id')::uuid) IS DISTINCT FROM v_find
           OR NOT EXISTS (SELECT 1 FROM batch_quality_hold(ib_h, NULL) hq WHERE hq.ncr_id = (v_j ->> 'ncr_id')::uuid) THEN
            RAISE EXCEPTION 'FIXTURE 263 NCR: an inspection-source NCR citing a finding opens and holds its batch: %', v_j;
        END IF;
        v_j2 := pg_temp.f263_get(u_qe, format($q$SELECT to_jsonb(n) FROM ncr_rows n WHERE n.id = %L$q$, (v_j ->> 'ncr_id')::uuid));
        IF v_j2 ->> 'inspection_run_code' IS NULL OR (v_j2 ->> 'inspection_item_position')::int <> 1 OR NOT (v_j2 ->> 'holding')::boolean THEN
            RAISE EXCEPTION 'FIXTURE 263 NCR: ncr_rows names the inspection run and item and says the batch is held: %', v_j2;
        END IF;
        RAISE EXCEPTION 'f263-rollback-inspection-arm';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM <> 'f263-rollback-inspection-arm' THEN RAISE; END IF;
    END;
    IF EXISTS (SELECT 1 FROM nonconformance_reports WHERE inbound_batch_id = ib_h) THEN
        RAISE EXCEPTION 'FIXTURE 263 NCR: the inspection-source arm must leave no NCR behind for the later arms'; END IF;
    v_msg := pg_temp.f263_do(u_qe, format($q$SELECT open_ncr('rumour', 'x', p_inbound_batch_id => %L)$q$, ib_h));
    IF v_msg <> 'NCR_SOURCE_INVALID|rumour' THEN RAISE EXCEPTION 'FIXTURE 263 NCR: an unknown source is refused by name, got %', v_msg; END IF;
    v_msg := pg_temp.f263_do(u_qe, format($q$SELECT open_ncr('manual', '   ', p_inbound_batch_id => %L)$q$, ib_h));
    IF v_msg <> 'NCR_DESCRIPTION_REQUIRED' THEN RAISE EXCEPTION 'FIXTURE 263 NCR: a description is required, got %', v_msg; END IF;
    v_msg := pg_temp.f263_do(u_qe, format($q$SELECT open_ncr('manual', 'x', p_inbound_batch_id => %L, p_sales_order_id => gen_random_uuid())$q$, ib_h));
    IF v_msg <> 'NCR_SALES_ORDER_OUTPUT_ONLY' THEN RAISE EXCEPTION 'FIXTURE 263 NCR: a sales order is only for an output batch, got %', v_msg; END IF;
    -- 一份别的批的化验
    PERFORM pg_temp.f263_as(u_rec);
    a_f := (record_assay_result(p_assay_date => v_today, p_metals => '[{"metal":"ni","content_pct":20}]'::jsonb, p_inbound_batch_id => ib_m,
                                p_weight_basis => 'dry', p_result_party => 'ours') ->> 'assay_result_id')::uuid;
    PERFORM pg_temp.f263_as(NULL);
    v_msg := pg_temp.f263_do(u_qe, format($q$SELECT open_ncr('manual', 'x', p_inbound_batch_id => %L, p_assay_result_id => %L)$q$, ib_h, a_f));
    IF v_msg NOT LIKE 'NCR_LINK_NOT_FOR_BATCH|assay|%' THEN RAISE EXCEPTION 'FIXTURE 263 NCR: a linked assay must be this batch''s, got %', v_msg; END IF;
    -- 两张,同一批,都开着(Q7)—— 编号按年无洞,与公式一致
    v_code := next_ncr_code(v_today);
    v_j := pg_temp.f263_get(u_qe, format($q$SELECT open_ncr('manual', 'Foil fragments seen in the drum', p_inbound_batch_id => %L)$q$, ib_h));
    n1 := (v_j ->> 'ncr_id')::uuid;
    v_j2 := pg_temp.f263_get(u_qe, format($q$SELECT open_ncr('customer_complaint', 'Second look: smell of electrolyte', p_inbound_batch_id => %L)$q$, ib_h));
    n2 := (v_j2 ->> 'ncr_id')::uuid;
    IF (v_j ->> 'code') <> v_code OR v_code <> 'NCR-' || v_year || '-' || lpad((COALESCE((SELECT max(split_part(code, '-', 3)::int) FROM nonconformance_reports
           WHERE code LIKE 'NCR-' || v_year || '-%' AND id NOT IN (n1, n2)), 0) + 1)::text, 4, '0')
       OR split_part(v_j2 ->> 'code', '-', 3)::int <> split_part(v_j ->> 'code', '-', 3)::int + 1 THEN
        RAISE EXCEPTION 'FIXTURE 263 NCR: NCR-<year>-NNNN, gapless, the next one is +1 (got % then %, predicted %)', v_j ->> 'code', v_j2 ->> 'code', v_code; END IF;
    IF (SELECT count(*) FROM nonconformance_reports WHERE inbound_batch_id = ib_h AND status = 'open') <> 2
       OR (SELECT opened_by FROM nonconformance_reports WHERE id = n1) <> u_qe
       OR (SELECT description FROM nonconformance_reports WHERE id = n1) <> 'Foil fragments seen in the drum' THEN
        RAISE EXCEPTION 'FIXTURE 263 NCR: two open NCRs on one batch, opener recorded, description as written'; END IF;
    IF pg_temp.f263_held(ib_h, NULL) <> (v_j ->> 'code') THEN
        RAISE EXCEPTION 'FIXTURE 263 NCR: the batch is held by the earliest open NCR, got %', pg_temp.f263_held(ib_h, NULL); END IF;
    -- 只经函数
    v_msg := pg_temp.f263_do(u_all, format($q$INSERT INTO nonconformance_reports (code, inbound_batch_id, source, description, opened_by) VALUES ('NCR-X', %L, 'manual', 'x', %L)$q$, ib_h, u_all));
    IF v_msg = 'OK' THEN RAISE EXCEPTION 'FIXTURE 263 NCR: a direct insert must be refused (no write policy)'; END IF;
    BEGIN
        UPDATE nonconformance_reports SET description = 'rewritten' WHERE id = n1;
        RAISE EXCEPTION 'FIXTURE 263 NCR: rewriting the description must be refused';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM NOT LIKE 'NCR_IMMUTABLE|%|update' THEN RAISE; END IF;
    END;
    BEGIN
        DELETE FROM nonconformance_reports WHERE id = n1;
        RAISE EXCEPTION 'FIXTURE 263 NCR: deleting must be refused';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM NOT LIKE 'NCR_IMMUTABLE|%|delete' THEN RAISE; END IF;
    END;

    -- ══════════════ DECIDE ══════════════
    RAISE NOTICE 'fixture 263 · DECIDE';
    v_msg := pg_temp.f263_do(u_qv, format($q$SELECT decide_ncr(%L, 'accept', 'fine')$q$, n1));
    IF v_msg NOT LIKE 'PERMISSION_DENIED|action.ncr_decide%' THEN RAISE EXCEPTION 'FIXTURE 263 DECIDE: deciding needs action.ncr_decide, got %', v_msg; END IF;
    v_msg := pg_temp.f263_do(u_alt, format($q$SELECT decide_ncr(%L, 'accept', 'fine')$q$, n1));
    IF v_msg <> 'SELF_APPROVAL_FORBIDDEN|raiser' THEN
        RAISE EXCEPTION 'FIXTURE 263 DECIDE: the opener never decides their own NCR, judged per person (another account of the same person), got %', v_msg; END IF;
    v_msg := pg_temp.f263_do(u_d1, format($q$SELECT decide_ncr(%L, 'accept', '  ')$q$, n1));
    IF v_msg NOT LIKE 'NCR_DECISION_NOTE_REQUIRED|%' THEN RAISE EXCEPTION 'FIXTURE 263 DECIDE: a note is required, got %', v_msg; END IF;
    v_msg := pg_temp.f263_do(u_d1, format($q$SELECT decide_ncr(%L, 'shrug', 'x')$q$, n1));
    IF v_msg <> 'NCR_DISPOSITION_INVALID|shrug' THEN RAISE EXCEPTION 'FIXTURE 263 DECIDE: an unknown disposition is refused by name, got %', v_msg; END IF;
    v_msg := pg_temp.f263_do(u_d1, format($q$SELECT decide_ncr(%L, 'accept', 'x', p_penalty_price_request_id => gen_random_uuid())$q$, n1));
    IF v_msg NOT LIKE 'NCR_PENALTY_DOCUMENT_ONLY_WITH_PENALTY|%' THEN RAISE EXCEPTION 'FIXTURE 263 DECIDE: only accept_with_penalty names a money document, got %', v_msg; END IF;
    v_msg := pg_temp.f263_do(u_d1, format($q$SELECT decide_ncr(%L, 'accept_with_penalty', 'x')$q$, n1));
    IF v_msg NOT LIKE 'NCR_PENALTY_DOCUMENT_REQUIRED|%|price_request' THEN RAISE EXCEPTION 'FIXTURE 263 DECIDE: an inbound penalty names the receipt price request, got %', v_msg; END IF;
    v_msg := pg_temp.f263_do(u_d1, format($q$SELECT decide_ncr(%L, 'accept_with_penalty', 'x', p_penalty_price_request_id => gen_random_uuid())$q$, n1));
    IF v_msg NOT LIKE 'NCR_PENALTY_DOCUMENT_INVALID|%|price_request' THEN RAISE EXCEPTION 'FIXTURE 263 DECIDE: the price request must be this batch''s and alive, got %', v_msg; END IF;
    -- 带罚接受(进料):这一批的一张收货定价申请(审批关着 → 当场批准、过账)
    v_msg := pg_temp.f263_do(u_all, format($q$SELECT set_inbound_unit_price(%L, 2, %L)$q$, ib_h, v_base));
    SELECT id INTO v_pr_req FROM receipt_price_requests WHERE inbound_batch_id = ib_h ORDER BY created_at DESC LIMIT 1;
    IF v_msg <> 'OK' OR v_pr_req IS NULL THEN RAISE EXCEPTION 'FIXTURE 263 DECIDE: setup — a receipt price request on the held batch (pricing is not a movement), got %', v_msg; END IF;
    PERFORM pg_temp.f263_agree(u_all, 'price request on a held batch');
    v_j := pg_temp.f263_get(u_d1, format($q$SELECT decide_ncr(%L, 'accept_with_penalty', 'Supplier credits 2 SGD/kg', p_penalty_price_request_id => %L)$q$, n1, v_pr_req));
    IF (v_j ->> 'disposition') <> 'accept_with_penalty' OR (v_j ->> 'batch_still_held')::boolean IS NOT TRUE OR (v_j ->> 'held_by') <> (v_j2 ->> 'code')
       OR (SELECT penalty_price_request_id FROM nonconformance_reports WHERE id = n1) <> v_pr_req
       OR (SELECT decided_by FROM nonconformance_reports WHERE id = n1) <> u_d1 THEN
        RAISE EXCEPTION 'FIXTURE 263 DECIDE: accept_with_penalty records the money document; the batch stays held by the other open NCR, got %', v_j; END IF;
    v_msg := pg_temp.f263_do(u_d2, format($q$SELECT decide_ncr(%L, 'accept', 'again')$q$, n1));
    IF v_msg NOT LIKE 'NCR_NOT_OPEN|%|decided' THEN RAISE EXCEPTION 'FIXTURE 263 DECIDE: a decided NCR is not decided twice, got %', v_msg; END IF;
    BEGIN
        UPDATE nonconformance_reports SET disposition = 'reject' WHERE id = n1;
        RAISE EXCEPTION 'FIXTURE 263 DECIDE: a decision cannot be rewritten';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM NOT LIKE 'NCR_IMMUTABLE|%|update' THEN RAISE; END IF;
    END;
    -- 除开单人之外没人持决定码 → 开不出来;开单人自己持码也不算(子事务里拿掉别的持有人)
    BEGIN
        DELETE FROM role_permissions WHERE permission_code = 'action.ncr_decide';
        v_msg := pg_temp.f263_do(u_qe2, format($q$SELECT open_ncr('manual', 'x', p_inbound_batch_id => %L)$q$, ib_h));
        IF v_msg <> 'NCR_NO_OTHER_DECIDER' THEN RAISE EXCEPTION 'FIXTURE 263 DECIDE: nobody can decide → refused NCR_NO_OTHER_DECIDER, got %', v_msg; END IF;
        INSERT INTO role_permissions (role_id, permission_code) SELECT r.id, 'action.ncr_decide' FROM roles r WHERE r.code = 'fx263-qe2';
        v_msg := pg_temp.f263_do(u_qe2, format($q$SELECT open_ncr('manual', 'x', p_inbound_batch_id => %L)$q$, ib_h));
        IF v_msg <> 'NCR_NO_OTHER_DECIDER' THEN RAISE EXCEPTION 'FIXTURE 263 DECIDE: the opener''s own code does not count, got %', v_msg; END IF;
        RAISE EXCEPTION 'F263_ROLLBACK';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM <> 'F263_ROLLBACK' THEN RAISE; END IF;
    END;
    IF NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE r.code = 'fx263-d1' AND rp.permission_code = 'action.ncr_decide') THEN
        RAISE EXCEPTION 'FIXTURE 263 DECIDE: the sub-block must have rolled the grants back'; END IF;
    -- 第二张决定放行 → 这一批放行
    v_j := pg_temp.f263_get(u_d2, format($q$SELECT decide_ncr(%L, 'rework', 'Re-screen before processing')$q$, n2));
    IF (v_j ->> 'batch_still_held')::boolean OR pg_temp.f263_held(ib_h, NULL) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 263 DECIDE: once the last open NCR is decided (rework), the batch is released, got %', v_j; END IF;

    -- ══════════════ HOLD · 流水逐种 ══════════════
    RAISE NOTICE 'fixture 263 · HOLD';
    n3 := (pg_temp.f263_get(u_qe, format($q$SELECT open_ncr('manual', 'Matrix hold (inbound)', p_inbound_batch_id => %L)$q$, ib_m)) ->> 'ncr_id')::uuid;
    n4 := (pg_temp.f263_get(u_qe, format($q$SELECT open_ncr('manual', 'Matrix hold (output)', p_output_batch_id => %L)$q$, ob_m)) ->> 'ncr_id')::uuid;
    SELECT code INTO v_code FROM nonconformance_reports WHERE id = n3;
    SELECT code INTO v_code2 FROM nonconformance_reports WHERE id = n4;
    -- 拒的四种(进料 / 产出两侧,能落在哪一侧就在哪一侧试)
    IF pg_temp.f263_leg(ib_m, NULL, 'processing_consume', -1, 'available', NULL) <> 'QUALITY_HOLD_OPEN|ZZ263-IBM|' || v_code
       OR pg_temp.f263_leg(NULL, ob_m, 'processing_consume', -1, 'available', NULL) <> 'QUALITY_HOLD_OPEN|' || (SELECT code FROM output_batches WHERE id = ob_m) || '|' || v_code2
       OR pg_temp.f263_leg(NULL, ob_m, 'sale', -1, 'available', NULL) NOT LIKE 'QUALITY_HOLD_OPEN|%'
       OR pg_temp.f263_leg(NULL, ob_m, 'sale', -1, 'committed', NULL) NOT LIKE 'QUALITY_HOLD_OPEN|%'
       OR pg_temp.f263_leg(NULL, ob_m, 'status_change_in', 1, 'committed', NULL) NOT LIKE 'QUALITY_HOLD_OPEN|%'
       OR pg_temp.f263_leg(ib_m, NULL, 'writeoff', -1, 'available', NULL) NOT LIKE 'QUALITY_HOLD_OPEN|%'
       OR pg_temp.f263_leg(NULL, ob_m, 'writeoff', -1, 'available', NULL) NOT LIKE 'QUALITY_HOLD_OPEN|%'
       -- MES-7a-2(Step 0 Q15):一件开着报告的备件不装上机器
       OR pg_temp.f263_leg(ib_m, NULL, 'maintenance_issue', -1, 'available', NULL) <> 'QUALITY_HOLD_OPEN|ZZ263-IBM|' || v_code THEN
        RAISE EXCEPTION 'FIXTURE 263 HOLD: consume, sale (both buckets), a status leg into committed, a write-off outside a request and an issue to maintenance are refused by name'; END IF;
    -- 放的那几种
    IF pg_temp.f263_leg(ib_m, NULL, 'receipt', 1, 'available', NULL) <> 'ALLOWED'
       OR pg_temp.f263_leg(NULL, ob_m, 'processing_produce', 1, 'available', NULL) <> 'ALLOWED'
       OR pg_temp.f263_leg(ib_m, NULL, 'reversal_restore', 1, 'available', NULL) <> 'ALLOWED'
       OR pg_temp.f263_leg(NULL, ob_m, 'reversal_void', -1, 'available', NULL) <> 'ALLOWED'
       OR pg_temp.f263_leg(ib_m, NULL, 'adjustment', -1, 'available', NULL) <> 'ALLOWED'
       OR pg_temp.f263_leg(NULL, ob_m, 'status_change_out', -1, 'available', NULL) <> 'ALLOWED'
       OR pg_temp.f263_leg(NULL, ob_m, 'status_change_in', 1, 'on_hold', NULL) <> 'ALLOWED'
       OR pg_temp.f263_leg(NULL, ob_m, 'status_change_out', -1, 'on_hold', NULL) <> 'ALLOWED'
       OR pg_temp.f263_leg(NULL, ob_m, 'status_change_in', 1, 'available', NULL) <> 'ALLOWED'
       OR pg_temp.f263_leg(NULL, ob_m, 'status_change_out', -1, 'committed', NULL) <> 'ALLOWED'
       OR pg_temp.f263_leg(ib_m, NULL, 'transfer_out', -1, 'available', NULL) <> 'ALLOWED'
       OR pg_temp.f263_leg(ib_m, NULL, 'transfer_in', 1, 'available', NULL) <> 'ALLOWED'
       OR pg_temp.f263_leg(NULL, ob_m, 'transfer_in', 1, 'committed', NULL) <> 'ALLOWED'
       OR pg_temp.f263_leg(ib_m, NULL, 'writeoff', -1, 'available', gen_random_uuid()::text) <> 'ALLOWED'
       OR pg_temp.f263_leg(NULL, ob_m, 'writeoff', -1, 'available', gen_random_uuid()::text) <> 'ALLOWED'
       -- MES-7a-2(Step 0 Q15):退回不挡
       OR pg_temp.f263_leg(ib_m, NULL, 'maintenance_return', 1, 'available', NULL) <> 'ALLOWED' THEN
        RAISE EXCEPTION 'FIXTURE 263 HOLD: receipts, production, reversals, adjustments, available ↔ on_hold, committed → available, transfers, a write-off inside a request and a return from maintenance are allowed'; END IF;
    -- 不在暂扣里的一批:同样的投料腿放行(那四种拒绝是暂扣的,不是流水的)
    IF pg_temp.f263_leg(ib_c, NULL, 'processing_consume', -1, 'available', NULL) <> 'ALLOWED'
       OR pg_temp.f263_leg(NULL, ob1, 'status_change_in', 1, 'committed', NULL) <> 'ALLOWED' THEN
        RAISE EXCEPTION 'FIXTURE 263 HOLD: an unheld batch takes the same legs'; END IF;

    -- ══════════════ HOLD · 函数那一层 ══════════════
    -- 一张单,两行;OB_H 先预留(暂扣之前),再开报告(订单行的守卫问的是【调用者】看不看得见物料的形态 —— 以全码那个人建)
    PERFORM pg_temp.f263_as(u_all);
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES (next_sales_order_code(v_today - 4), v_cust, v_today - 4, v_base, 1) RETURNING id INTO so1;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price) VALUES (so1, 1, v_mat, 100, 10) RETURNING id INTO l1;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price) VALUES (so1, 2, v_mat, 100, 10) RETURNING id INTO l2;
    PERFORM set_sales_order_status(so1, 'confirmed');
    v_inv := (create_order_invoice(so1, v_today - 4, NULL, NULL, NULL, ARRAY[l1]) ->> 'invoice_id')::uuid;
    PERFORM pg_temp.f263_as(NULL);
    PERFORM pg_temp.f263_agree(u_all, 'invoice');
    r1 := (pg_temp.f263_get(u_sal, format($q$SELECT reserve_stock(%L, %L, 30)$q$, l1, ob_h)) ->> 'reservation_id')::uuid;
    n5 := (pg_temp.f263_get(u_qe, format($q$SELECT open_ncr('customer_complaint', 'Buyer reports moisture on arrival of an earlier lot', p_output_batch_id => %L, p_sales_order_id => %L)$q$, ob_h, so1)) ->> 'ncr_id')::uuid;
    SELECT code INTO v_code FROM nonconformance_reports WHERE id = n5;
    v_n := (SELECT count(*) FROM sales_order_reservations WHERE output_batch_id = ob_h);
    v_msg := pg_temp.f263_do(u_sal, format($q$SELECT reserve_stock(%L, %L, 10)$q$, l2, ob_h));
    IF v_msg <> 'QUALITY_HOLD_OPEN|' || (SELECT code FROM output_batches WHERE id = ob_h) || '|' || v_code
       OR (SELECT count(*) FROM sales_order_reservations WHERE output_batch_id = ob_h) <> v_n THEN
        RAISE EXCEPTION 'FIXTURE 263 HOLD: a held batch cannot be reserved, and nothing is left behind, got %', v_msg; END IF;
    v_msg := pg_temp.f263_do(u_ds, format($q$SELECT record_output_sale(%L, 5, 10, %L, p_sale_date => CURRENT_DATE)$q$, ob_h, v_base));
    IF v_msg NOT LIKE 'QUALITY_HOLD_OPEN|%' THEN RAISE EXCEPTION 'FIXTURE 263 HOLD: a held batch cannot be sold directly, got %', v_msg; END IF;
    v_msg := pg_temp.f263_do(u_wh, format($q$SELECT create_stock_transfer(10, %L, p_output_batch_id => %L)$q$, v_loc, ob_h));
    v_msg2 := pg_temp.f263_do(u_wh, format($q$SELECT hold_stock(5, 'set aside', p_output_batch_id => %L)$q$, ob_h));
    IF v_msg <> 'OK' OR v_msg2 <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 263 HOLD: transfer and hold_stock stay allowed under a quality hold, got % / %', v_msg, v_msg2; END IF;
    v_msg := pg_temp.f263_do(u_wh, format($q$SELECT release_stock(5, p_output_batch_id => %L)$q$, ob_h));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 263 HOLD: release_stock stays allowed, got %', v_msg; END IF;
    IF (SELECT released_at FROM sales_order_reservations WHERE id = r1) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 263 HOLD: an existing reservation is kept when the hold lands (Q23)'; END IF;
    -- 发货:放行(审批关着 → 生下来就批准)之后,那一笔预留发不出去
    PERFORM pg_temp.f263_as(u_all);
    v_rel := (submit_shipping_release(so1) ->> 'release_id')::uuid;
    PERFORM pg_temp.f263_as(NULL);
    v_msg := pg_temp.f263_do(u_wh, format($q$SELECT ship_order(%L, %L, %L::jsonb)$q$, so1, v_today, jsonb_build_array(jsonb_build_object('reservation_id', r1, 'qty', 5))));
    IF v_msg NOT LIKE 'QUALITY_HOLD_OPEN|%' THEN RAISE EXCEPTION 'FIXTURE 263 HOLD: a reserved but held batch cannot be shipped, got %', v_msg; END IF;
    -- 加工投料:被暂扣的进料一批投不进去(IB_C 上开一张)
    n6 := (pg_temp.f263_get(u_qe, format($q$SELECT open_ncr('manual', 'Hold before the line', p_inbound_batch_id => %L)$q$, ib_c)) ->> 'ncr_id')::uuid;
    v_msg := pg_temp.f263_do(u_all, format($q$SELECT commit_processing_run(CURRENT_DATE - 1, 'f263 run', NULL,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', %L, 'quantity_consumed', 50)),
        jsonb_build_array(jsonb_build_object('material_id', %L, 'weight_kg', 40)),
        'weight', NULL, NULL, 'manual_disassembly', p_started_at => (CURRENT_DATE - 1)::timestamptz,
        p_ended_at => (CURRENT_DATE - 1)::timestamptz + interval '1 hour', p_shift_code => 'day')$q$, ib_c, v_mat));
    IF v_msg NOT LIKE 'QUALITY_HOLD_OPEN|ZZ263-IBC|%' THEN RAISE EXCEPTION 'FIXTURE 263 HOLD: a held inbound batch cannot be consumed by a processing run, got %', v_msg; END IF;
    -- 释放预留照常(committed → available)
    r2 := (pg_temp.f263_get(u_sal, format($q$SELECT reserve_stock(%L, %L, 20)$q$, l2, ob1)) ->> 'reservation_id')::uuid;

    -- ══════════════ SETTLE ══════════════
    RAISE NOTICE 'fixture 263 · SETTLE';
    INSERT INTO index_market_calendar (index_code, calendar_date, is_trading_day, note)
    SELECT 'LME', d::date, EXTRACT(ISODOW FROM d) < 6, 'fixture 263'
      FROM generate_series(DATE '2026-09-01', DATE '2026-09-30', interval '1 day') d
    ON CONFLICT DO NOTHING;
    INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date, source, price_index)
    SELECT 'ni', 10000, c.calendar_date, 'published_index', 'LME'
      FROM index_market_calendar c WHERE c.index_code = 'LME' AND c.is_trading_day AND c.calendar_date BETWEEN DATE '2026-09-01' AND DATE '2026-09-30'
    ON CONFLICT DO NOTHING;
    INSERT INTO contracts (customer_id, kind, title, effective_from, status)
    VALUES (v_cust, 'offtake', 'f263 settlement', DATE '2026-01-01', 'active') RETURNING id INTO conB;
    INSERT INTO contract_pricing_terms (contract_id, metal, base_event, qp_months, index_code, payable_pct) VALUES (conB, 'ni', 'assay_complete', 0, 'LME', 70);
    INSERT INTO contract_settlement_terms (contract_id, sale_weight_basis, settling_party, sample_retention_required, refining_charge_basis, penalty_basis, quality_limit_basis)
    VALUES (conB, 'dry', 'ours', false, 'none_agreed', 'none_agreed', 'none_agreed');
    PERFORM pg_temp.f263_as(u_all);
    PERFORM link_document_to_contract('sales_order', so1, conB);
    PERFORM pg_temp.f263_as(NULL);
    INSERT INTO assay_results (code, output_batch_id, assay_date, is_final, weight_basis, moisture_pct, result_party)
    VALUES ('ZZ263-OBH-OURS', ob_h, DATE '2026-09-15', true, 'dry', 10, 'ours') RETURNING id INTO a_s;
    INSERT INTO assay_result_metals (assay_result_id, metal, content_pct) VALUES (a_s, 'ni', 20);
    v_msg := pg_temp.f263_do(u_all, format($q$SELECT pg_temp.f263_compute(%L, %L, %L)$q$, so1, ob_h, a_s));
    v_msg2 := pg_temp.f263_do(u_all, format($q$SELECT record_sale_settlement(%L, %L, %L)$q$, so1, ob_h, a_s));
    IF v_msg <> 'QUALITY_HOLD_OPEN|' || (SELECT code FROM output_batches WHERE id = ob_h) || '|' || v_code OR v_msg2 <> v_msg
       OR EXISTS (SELECT 1 FROM sales_settlements WHERE output_batch_id = ob_h) THEN
        RAISE EXCEPTION 'FIXTURE 263 SETTLE: preview and record refuse with the same named code while the batch is held, got % / %', v_msg, v_msg2; END IF;

    -- ══════════════ DISP ══════════════
    RAISE NOTICE 'fixture 263 · DISP';
    -- accept_with_penalty(产出):一张贷项通知申请(审批关着 → 当场批准、过账)
    PERFORM pg_temp.f263_as(u_all);
    SELECT id INTO v_il FROM invoice_lines WHERE invoice_id = v_inv LIMIT 1;
    v_cn_req := (submit_credit_note_request(v_inv, v_today, 'f263 moisture penalty',
                 jsonb_build_array(jsonb_build_object('invoice_line_id', v_il, 'kind', 'unshipped_cancel', 'amount', 50, 'qty', 5))) ->> 'request_id')::uuid;
    PERFORM pg_temp.f263_as(NULL);
    PERFORM pg_temp.f263_agree(u_all, 'credit note');
    v_msg := pg_temp.f263_do(u_d1, format($q$SELECT decide_ncr(%L, 'accept_with_penalty', 'x', p_penalty_price_request_id => %L)$q$, n5, v_pr_req));
    IF v_msg NOT LIKE 'NCR_PENALTY_DOCUMENT_REQUIRED|%|credit_note' THEN RAISE EXCEPTION 'FIXTURE 263 DISP: an output penalty names a credit note request, got %', v_msg; END IF;
    v_j := pg_temp.f263_get(u_d1, format($q$SELECT decide_ncr(%L, 'accept_with_penalty', 'Buyer takes it with a credit', p_penalty_invoice_request_id => %L)$q$, n5, v_cn_req));
    IF (v_j ->> 'batch_still_held')::boolean OR (SELECT penalty_invoice_request_id FROM nonconformance_reports WHERE id = n5) <> v_cn_req THEN
        RAISE EXCEPTION 'FIXTURE 263 DISP: accept_with_penalty releases and records the credit note request, got %', v_j; END IF;
    -- 放行之后:发货照走,结算算得出
    v_msg := pg_temp.f263_do(u_wh, format($q$SELECT ship_order(%L, %L, %L::jsonb)$q$, so1, v_today, jsonb_build_array(jsonb_build_object('reservation_id', r1, 'qty', 5))));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 263 DISP: once released the reservation ships, got %', v_msg; END IF;
    PERFORM pg_temp.f263_agree(u_all, 'shipped after release');
    v_msg := pg_temp.f263_do(u_all, format($q$SELECT pg_temp.f263_compute(%L, %L, %L)$q$, so1, ob_h, a_s));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 263 DISP: once released the batch settles, got %', v_msg; END IF;
    -- accept / downgrade 放行;reject 不放行,出路是注销申请
    n7 := (pg_temp.f263_get(u_qe, format($q$SELECT open_ncr('manual', 'Odd colour', p_output_batch_id => %L)$q$, ob5)) ->> 'ncr_id')::uuid;
    v_j := pg_temp.f263_get(u_d1, format($q$SELECT decide_ncr(%L, 'accept', 'Within normal variation')$q$, n7));
    IF (v_j ->> 'batch_still_held')::boolean THEN RAISE EXCEPTION 'FIXTURE 263 DISP: accept releases'; END IF;
    n7 := (pg_temp.f263_get(u_qe, format($q$SELECT open_ncr('manual', 'Particle size coarse', p_output_batch_id => %L)$q$, ob5)) ->> 'ncr_id')::uuid;
    v_j := pg_temp.f263_get(u_d2, format($q$SELECT decide_ncr(%L, 'downgrade', 'Sell as a lower grade')$q$, n7));
    IF (v_j ->> 'batch_still_held')::boolean OR pg_temp.f263_held(NULL, ob5) IS NOT NULL THEN RAISE EXCEPTION 'FIXTURE 263 DISP: downgrade releases (recorded only)'; END IF;
    n8 := (pg_temp.f263_get(u_qe, format($q$SELECT open_ncr('manual', 'Contaminated with plastic', p_output_batch_id => %L)$q$, ob_r)) ->> 'ncr_id')::uuid;
    v_j := pg_temp.f263_get(u_d1, format($q$SELECT decide_ncr(%L, 'reject', 'Not saleable')$q$, n8));
    IF NOT (v_j ->> 'batch_still_held')::boolean OR pg_temp.f263_held(NULL, ob_r) IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 263 DISP: reject keeps the hold while stock remains, got %', v_j; END IF;
    v_msg := pg_temp.f263_do(u_sal, format($q$SELECT reserve_stock(%L, %L, 1)$q$, l2, ob_r));
    IF v_msg NOT LIKE 'QUALITY_HOLD_OPEN|%' THEN RAISE EXCEPTION 'FIXTURE 263 DISP: a rejected batch with stock stays held, got %', v_msg; END IF;
    v_msg := pg_temp.f263_do(u_all, format($q$SELECT submit_output_write_off_request(%L, 'Rejected under %s')$q$, ob_r, (SELECT code FROM nonconformance_reports WHERE id = n8)));
    IF v_msg <> 'OK' OR (SELECT deleted_at FROM output_batches WHERE id = ob_r) IS NULL OR pg_temp.f263_held(NULL, ob_r) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 263 DISP: the CFO write-off request takes the rejected batch out and the hold ends, got %', v_msg; END IF;
    PERFORM pg_temp.f263_agree(u_all, 'write-off of a rejected batch');
    -- 释放预留(committed → available)在暂扣下照常
    n7 := (pg_temp.f263_get(u_qe, format($q$SELECT open_ncr('manual', 'Hold a reserved lot', p_output_batch_id => %L)$q$, ob1)) ->> 'ncr_id')::uuid;
    v_msg := pg_temp.f263_do(u_sal, format($q$SELECT release_reservation(%L, NULL, 'held')$q$, r2));
    IF v_msg <> 'OK' OR (SELECT released_at FROM sales_order_reservations WHERE id = r2) IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 263 DISP: releasing a reservation stays allowed under a hold, got %', v_msg; END IF;
    PERFORM pg_temp.f263_get(u_d2, format($q$SELECT decide_ncr(%L, 'accept', 'ok')$q$, n7));

    -- ══════════════ BLEND ══════════════
    RAISE NOTICE 'fixture 263 · BLEND';
    v_msg := pg_temp.f263_do(u_wo, format($q$SELECT create_blending_plan(%L, %L::jsonb, '[{"metal":"ni","min_pct":10}]'::jsonb)$q$,
             v_mat, jsonb_build_array(jsonb_build_object('inbound_batch_id', ib_c, 'planned_kg', 10))));
    IF v_msg NOT LIKE 'QUALITY_HOLD_OPEN|ZZ263-IBC|%' THEN RAISE EXCEPTION 'FIXTURE 263 BLEND: a held batch cannot be a plan line, got %', v_msg; END IF;
    v_j := pg_temp.f263_get(u_wo, format($q$SELECT create_blending_plan(%L, %L::jsonb, '[{"metal":"ni","min_pct":10}]'::jsonb)$q$,
             v_mat, jsonb_build_array(jsonb_build_object('inbound_batch_id', ib_s, 'planned_kg', 10))));
    plan := (v_j ->> 'plan_id')::uuid;
    v_msg := pg_temp.f263_do(u_wo, format($q$SELECT amend_blending_plan(%L, %L, %L::jsonb, '[{"metal":"ni","min_pct":10}]'::jsonb)$q$,
             plan, v_mat, jsonb_build_array(jsonb_build_object('inbound_batch_id', ib_s, 'planned_kg', 10), jsonb_build_object('inbound_batch_id', ib_c, 'planned_kg', 5))));
    IF v_msg NOT LIKE 'QUALITY_HOLD_OPEN|ZZ263-IBC|%' THEN RAISE EXCEPTION 'FIXTURE 263 BLEND: amending in a held line is refused too, got %', v_msg; END IF;
    ns := (pg_temp.f263_get(u_qe, format($q$SELECT open_ncr('manual', 'Held after planning', p_inbound_batch_id => %L)$q$, ib_s)) ->> 'ncr_id')::uuid;
    v_msg := pg_temp.f263_do(u_rel, format($q$SELECT release_blending_plan(%L)$q$, plan));
    IF v_msg NOT LIKE 'QUALITY_HOLD_OPEN|ZZ263-IBS|%' THEN RAISE EXCEPTION 'FIXTURE 263 BLEND: a plan with a held line is not released, got %', v_msg; END IF;
    PERFORM pg_temp.f263_get(u_d1, format($q$SELECT decide_ncr(%L, 'accept', 'ok')$q$, ns));
    v_msg := pg_temp.f263_do(u_rel, format($q$SELECT release_blending_plan(%L)$q$, plan));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 263 BLEND: once the line is released the plan releases, got %', v_msg; END IF;

    -- ══════════════ V17 · 生效清单、条款、冻结、副本 ══════════════
    RAISE NOTICE 'fixture 263 · V17';
    PERFORM pg_temp.f263_as(u_cco);
    EXECUTE 'SET LOCAL ROLE authenticated';
    INSERT INTO contracts (customer_id, kind, title, effective_from, status) VALUES (v_cust, 'offtake', 'f263 limits', DATE '2026-01-01', 'draft') RETURNING id INTO conQ;
    INSERT INTO contract_pricing_terms (contract_id, metal, base_event, qp_months, index_code, payable_pct) VALUES (conQ, 'ni', 'assay_complete', 0, 'LME', 70);
    INSERT INTO contract_settlement_terms (contract_id, sale_weight_basis, settling_party, sample_retention_required, refining_charge_basis, penalty_basis)
    VALUES (conQ, 'dry', 'ours', false, 'none_agreed', 'none_agreed');
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f263_as(NULL);
    IF array_to_string(contract_activation_missing(conQ), ',') <> 'quality_limit_basis' THEN
        RAISE EXCEPTION 'FIXTURE 263 V17: an unset basis is on the checklist, got %', contract_activation_missing(conQ); END IF;
    v_msg := pg_temp.f263_do(u_cco, format($q$SELECT submit_contract_activation_request(%L, 'go')$q$, conQ));
    IF v_msg <> 'CONTRACT_TERMS_INCOMPLETE|' || (SELECT code FROM contracts WHERE id = conQ) || '|quality_limit_basis' THEN
        RAISE EXCEPTION 'FIXTURE 263 V17: activation is refused while the basis is unset, got %', v_msg; END IF;
    v_msg := pg_temp.f263_do(u_cco, format($q$UPDATE contract_settlement_terms SET quality_limit_basis = 'per_parameter' WHERE contract_id = %L$q$, conQ));
    IF array_to_string(contract_activation_missing(conQ), ',') <> 'quality_limits' THEN
        RAISE EXCEPTION 'FIXTURE 263 V17: per_parameter with no rows is on the checklist, got %', contract_activation_missing(conQ); END IF;
    v_msg := pg_temp.f263_do(u_cco, format($q$SELECT submit_contract_activation_request(%L, 'go')$q$, conQ));
    IF v_msg <> 'QUALITY_LIMITS_NOT_FILED|' || (SELECT code FROM contracts WHERE id = conQ) THEN
        RAISE EXCEPTION 'FIXTURE 263 V17: per_parameter with no rows is refused by name at activation, got %', v_msg; END IF;
    -- 限:水分(每一种物料 8;这一种物料 12 —— 指名物料的优先)· D50 5–20 · 残粉 ≤ 1
    v_msg := pg_temp.f263_do(u_cco, format($q$INSERT INTO contract_quality_limits (contract_id, material_id, parameter, min_value, max_value) VALUES
        (%L, NULL, 'moisture_pct', NULL, 8), (%L, %L, 'moisture_pct', NULL, 12), (%L, NULL, 'd50_um', 5, 20), (%L, NULL, 'residual_powder_pct', NULL, 1)$q$,
        conQ, conQ, v_mat, conQ, conQ));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 263 V17: cco writes quality limits on a draft, got %', v_msg; END IF;
    v_msg := pg_temp.f263_do(u_qv, format($q$INSERT INTO contract_quality_limits (contract_id, parameter, max_value) VALUES (%L, 'd90_um', 50)$q$, conQ));
    IF v_msg = 'OK' THEN RAISE EXCEPTION 'FIXTURE 263 V17: writing limits needs action.contract_terms'; END IF;
    v_msg := pg_temp.f263_do(u_cco, format($q$INSERT INTO contract_quality_limits (contract_id, parameter, max_value) VALUES (%L, 'colour', 50)$q$, conQ));
    IF v_msg NOT LIKE '%contract_quality_limits_indicator_fkey%' THEN RAISE EXCEPTION 'FIXTURE 263 V17: a parameter must be moisture or an indicator code, got %', v_msg; END IF;
    v_msg := pg_temp.f263_do(u_cco, format($q$INSERT INTO contract_quality_limits (contract_id, parameter, min_value, max_value) VALUES (%L, 'd90_um', 50, 10)$q$, conQ));
    IF v_msg NOT LIKE '%contract_quality_limits_bounds_order%' THEN RAISE EXCEPTION 'FIXTURE 263 V17: min above max is refused, got %', v_msg; END IF;
    -- 同一种物质既计价又罚:两张条款表各自按名拒(F4,Q33)
    v_msg := pg_temp.f263_do(u_cco, format($q$INSERT INTO contract_penalty_elements (contract_id, substance, threshold_pct, usd_per_tonne_per_pct_over) VALUES (%L, 'ni', 0.5, 5)$q$, conQ));
    IF v_msg <> 'SUBSTANCE_PRICED_AND_PENALISED|ni' THEN RAISE EXCEPTION 'FIXTURE 263 V17: penalising a priced metal is refused by name, got %', v_msg; END IF;
    v_msg := pg_temp.f263_do(u_cco, format($q$INSERT INTO contract_penalty_elements (contract_id, substance, threshold_pct, usd_per_tonne_per_pct_over) VALUES (%L, 'cu', 0.5, 5)$q$, conQ));
    v_msg2 := pg_temp.f263_do(u_cco, format($q$INSERT INTO contract_pricing_terms (contract_id, metal, base_event, qp_months, index_code, payable_pct) VALUES (%L, 'cu', 'assay_complete', 0, 'LME', 50)$q$, conQ));
    IF v_msg <> 'OK' OR v_msg2 <> 'SUBSTANCE_PRICED_AND_PENALISED|cu' THEN
        RAISE EXCEPTION 'FIXTURE 263 V17: copper is a penalty element (F4); pricing it as well is refused by name, got % / %', v_msg, v_msg2; END IF;
    UPDATE contract_settlement_terms SET penalty_basis = 'per_element' WHERE contract_id = conQ;
    -- 条款表之外写进去的(守卫关掉一格):申请生效时第二道按名拒
    BEGIN
        ALTER TABLE contract_pricing_terms DISABLE TRIGGER trg_contract_pricing_terms_unpenalised;
        INSERT INTO contract_pricing_terms (contract_id, metal, base_event, qp_months, index_code, payable_pct) VALUES (conQ, 'cu', 'assay_complete', 0, 'LME', 50);
        ALTER TABLE contract_pricing_terms ENABLE TRIGGER trg_contract_pricing_terms_unpenalised;
        IF array_to_string(contract_activation_missing(conQ), ',') <> 'priced_and_penalised:cu' THEN
            RAISE EXCEPTION 'FIXTURE 263 V17: the checklist names a priced-and-penalised substance, got %', contract_activation_missing(conQ); END IF;
        v_msg := pg_temp.f263_do(u_cco, format($q$SELECT submit_contract_activation_request(%L, 'go')$q$, conQ));
        IF v_msg <> 'SUBSTANCE_PRICED_AND_PENALISED|cu' THEN RAISE EXCEPTION 'FIXTURE 263 V17: activation refuses it by name, got %', v_msg; END IF;
        RAISE EXCEPTION 'F263_ROLLBACK';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM <> 'F263_ROLLBACK' THEN RAISE; END IF;
    END;
    IF EXISTS (SELECT 1 FROM contract_pricing_terms WHERE contract_id = conQ AND metal = 'cu') THEN RAISE EXCEPTION 'FIXTURE 263 V17: sub-block rolled back'; END IF;
    -- 生效(审批关着 → 当场),之后冻结
    v_msg := pg_temp.f263_do(u_cco, format($q$SELECT submit_contract_activation_request(%L, 'go')$q$, conQ));
    IF v_msg <> 'OK' OR (SELECT status FROM contracts WHERE id = conQ) <> 'active' THEN RAISE EXCEPTION 'FIXTURE 263 V17: a complete contract activates, got %', v_msg; END IF;
    v_msg := pg_temp.f263_do(u_cco, format($q$UPDATE contract_quality_limits SET max_value = 30 WHERE contract_id = %L AND parameter = 'd50_um'$q$, conQ));
    IF v_msg NOT LIKE 'CONTRACT_TERMS_FROZEN|%|active' THEN RAISE EXCEPTION 'FIXTURE 263 V17: quality limits freeze with the contract, got %', v_msg; END IF;
    -- (COALESCE:一个缺掉的键读成 NULL,而 NULL <> 4 不是真 —— 那会让这一句对一个丢了限的状态沉默;注入表里那一格咬出来过)
    IF COALESCE(jsonb_array_length(contract_terms_state(conQ) -> 'quality_limits'), -1) <> 4
       OR (contract_terms_state(conQ) -> 'quality_limits') @> '[{"indicator": "d50_um"}]'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 263 V17: the CFO''s terms state carries the four limits (without the derived indicator column)'; END IF;
    -- 销售单挂上来 → 副本里有口径与几行限
    PERFORM pg_temp.f263_as(u_all);
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES (next_sales_order_code(v_today - 4), v_cust, v_today - 4, v_base, 1) RETURNING id INTO so2;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price) VALUES (so2, 1, v_mat, 400, 10) RETURNING id INTO l3;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price) VALUES (so2, 2, v_mat2, 100, 10);
    PERFORM set_sales_order_status(so2, 'confirmed');
    PERFORM link_document_to_contract('sales_order', so2, conQ);
    PERFORM pg_temp.f263_as(NULL);
    SELECT settlement_terms INTO v_j FROM contract_document_terms WHERE sales_order_id = so2;
    IF (v_j ->> 'quality_limit_basis') IS DISTINCT FROM 'per_parameter' OR COALESCE(jsonb_array_length(v_j -> 'quality_limits'), -1) <> 4 THEN
        RAISE EXCEPTION 'FIXTURE 263 V17: the link copies the basis and the four limits into the snapshot, got %', v_j; END IF;

    -- ══════════════ JUDGE · 记化验时 ══════════════
    RAISE NOTICE 'fixture 263 · JUDGE';
    r3 := (pg_temp.f263_get(u_sal, format($q$SELECT reserve_stock(%L, %L, 50)$q$, l3, ob2)) ->> 'reservation_id')::uuid;
    IF EXISTS (SELECT 1 FROM quality_limit_judgements WHERE output_batch_id = ob2) THEN
        RAISE EXCEPTION 'FIXTURE 263 JUDGE: no assay yet → nothing is judged at reservation'; END IF;
    v_j := pg_temp.f263_get(u_rec, format($q$SELECT record_assay_result(p_assay_date => CURRENT_DATE - 1, p_metals => '[{"metal":"ni","content_pct":20}]'::jsonb,
            p_output_batch_id => %L, p_weight_basis => 'dry', p_moisture_pct => 11, p_result_party => 'ours',
            p_indicators => '[{"indicator":"d50_um","value":25}]'::jsonb)$q$, ob2));
    a1 := (v_j ->> 'assay_result_id')::uuid;
    IF (v_j ->> 'quality_judged')::int <> 3 OR jsonb_array_length(v_j -> 'ncrs_opened') <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 263 JUDGE: three parameters judged, one breach, one NCR opened, got %', v_j; END IF;
    IF (SELECT result || ':' || COALESCE(limit_min_at::text, '-') || ':' || limit_max_at FROM quality_limit_judgements WHERE assay_result_id = a1 AND parameter = 'moisture_pct') <> 'within:-:12'
       OR (SELECT result || ':' || value || ':' || limit_min_at || ':' || limit_max_at FROM quality_limit_judgements WHERE assay_result_id = a1 AND parameter = 'd50_um') <> 'above_max:25:5:20'
       OR (SELECT result || ':' || COALESCE(value::text, 'null') FROM quality_limit_judgements WHERE assay_result_id = a1 AND parameter = 'residual_powder_pct') <> 'not_measured:null'
       OR (SELECT trigger_event FROM quality_limit_judgements WHERE assay_result_id = a1 LIMIT 1) <> 'assay_recorded'
       OR (SELECT count(DISTINCT contract_id) FROM quality_limit_judgements WHERE assay_result_id = a1) <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 263 JUDGE: moisture 11 within the material''s own 12 (not the general 8); D50 25 above 20 with the limit copied; residual powder not measured'; END IF;
    SELECT id INTO n7 FROM nonconformance_reports WHERE code = v_j -> 'ncrs_opened' ->> 0;
    IF (SELECT source FROM nonconformance_reports WHERE id = n7) <> 'quality_limit' OR (SELECT opened_by FROM nonconformance_reports WHERE id = n7) IS NOT NULL
       OR (SELECT assay_result_id FROM nonconformance_reports WHERE id = n7) <> a1 OR (SELECT sales_order_id FROM nonconformance_reports WHERE id = n7) <> so2
       OR (SELECT judgement_id FROM nonconformance_reports WHERE id = n7) <> (SELECT id FROM quality_limit_judgements WHERE assay_result_id = a1 AND parameter = 'd50_um')
       OR pg_temp.f263_held(NULL, ob2) IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 263 JUDGE: the breach opens a system NCR (no opener) citing the assay, the sales order and the judgement; the batch is held'; END IF;
    IF (SELECT released_at FROM sales_order_reservations WHERE id = r3) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 263 JUDGE: the reservation is kept'; END IF;
    -- 只判约定那一方:对手方的一份不新判
    v_j := pg_temp.f263_get(u_rec, format($q$SELECT record_assay_result(p_assay_date => CURRENT_DATE - 1, p_metals => '[{"metal":"ni","content_pct":20}]'::jsonb,
            p_output_batch_id => %L, p_weight_basis => 'dry', p_moisture_pct => 30, p_result_party => 'counterparty')$q$, ob2));
    IF (v_j ->> 'quality_judged')::int <> 0 OR (SELECT count(*) FROM quality_limit_judgements WHERE output_batch_id = ob2) <> 3 THEN
        RAISE EXCEPTION 'FIXTURE 263 JUDGE: only the settling party''s result is judged, got %', v_j; END IF;
    -- 系统开的那一张任何持码人都能决定 —— 包括记化验的人(若他持码)
    v_j := pg_temp.f263_get(u_d2, format($q$SELECT decide_ncr(%L, 'accept', 'Buyer accepts coarse D50 for this lot')$q$, n7));
    IF (v_j ->> 'batch_still_held')::boolean THEN RAISE EXCEPTION 'FIXTURE 263 JUDGE: a system NCR is decided by any holder, got %', v_j; END IF;
    -- 再预留同一张单:同一份化验不再判
    r4 := (pg_temp.f263_get(u_sal, format($q$SELECT reserve_stock(%L, %L, 10)$q$, l3, ob2)) ->> 'reservation_id')::uuid;
    IF (SELECT count(*) FROM quality_limit_judgements WHERE output_batch_id = ob2) <> 3 THEN
        RAISE EXCEPTION 'FIXTURE 263 JUDGE: the same assay is never judged twice for the same order'; END IF;
    -- 合同改了(暂停、改限、再生效)也不回头判:旧判定逐字未变,副本未变,再预留不新判
    UPDATE contracts SET status = 'suspended' WHERE id = conQ;
    UPDATE contract_quality_limits SET max_value = 30 WHERE contract_id = conQ AND parameter = 'd50_um';
    UPDATE contracts SET status = 'active' WHERE id = conQ;
    IF (SELECT limit_max_at FROM quality_limit_judgements WHERE assay_result_id = a1 AND parameter = 'd50_um') <> 20
       OR ((SELECT settlement_terms FROM contract_document_terms WHERE sales_order_id = so2) -> 'quality_limits') @> '[{"parameter":"d50_um","max_value":30}]'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 263 JUDGE: a contract change re-judges nothing (the judgement and the snapshot keep 20)'; END IF;
    PERFORM pg_temp.f263_get(u_sal, format($q$SELECT release_reservation(%L, NULL, 'again')$q$, r4));
    PERFORM pg_temp.f263_get(u_sal, format($q$SELECT reserve_stock(%L, %L, 10)$q$, l3, ob2));
    IF (SELECT count(*) FROM quality_limit_judgements WHERE output_batch_id = ob2) <> 3 THEN RAISE EXCEPTION 'FIXTURE 263 JUDGE: no re-judgement after the change'; END IF;
    -- 一份新的(约定那一方):照判 —— 水分 13 越过 12
    v_j := pg_temp.f263_get(u_rec, format($q$SELECT record_assay_result(p_assay_date => CURRENT_DATE, p_metals => '[{"metal":"ni","content_pct":20}]'::jsonb,
            p_output_batch_id => %L, p_weight_basis => 'dry', p_moisture_pct => 13, p_result_party => 'ours',
            p_indicators => '[{"indicator":"d50_um","value":10},{"indicator":"residual_powder_pct","value":0.5}]'::jsonb)$q$, ob2));
    a2 := (v_j ->> 'assay_result_id')::uuid;
    IF (v_j ->> 'quality_judged')::int <> 3 OR jsonb_array_length(v_j -> 'ncrs_opened') <> 1
       OR (SELECT result FROM quality_limit_judgements WHERE assay_result_id = a2 AND parameter = 'moisture_pct') <> 'above_max'
       OR (SELECT result FROM quality_limit_judgements WHERE assay_result_id = a2 AND parameter = 'residual_powder_pct') <> 'within' THEN
        RAISE EXCEPTION 'FIXTURE 263 JUDGE: a new assay of the settling party is judged (moisture 13 above 12), got %', v_j; END IF;
    -- 判定只追加
    BEGIN
        UPDATE quality_limit_judgements SET result = 'within' WHERE assay_result_id = a2;
        RAISE EXCEPTION 'FIXTURE 263 JUDGE: a judgement cannot be rewritten';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM NOT LIKE 'APPEND_ONLY|quality_limit_judgements|update' THEN RAISE; END IF;
    END;
    -- 别的物料(OB4:没有指名物料的那一行)→ 读每一种物料的 8
    -- ══════════════ JUDGE · 预留时 ══════════════
    INSERT INTO assay_results (code, output_batch_id, assay_date, is_final, weight_basis, moisture_pct, result_party)
    VALUES ('ZZ263-OB4-OURS', ob4, v_today - 1, true, 'dry', 9, 'ours') RETURNING id INTO a3;
    INSERT INTO assay_result_metals (assay_result_id, metal, content_pct) VALUES (a3, 'ni', 20);
    v_j := pg_temp.f263_get(u_sal, format($q$SELECT reserve_stock((SELECT id FROM sales_order_lines WHERE sales_order_id = %L AND line_no = 2), %L, 20)$q$, so2, ob4));
    IF (v_j ->> 'quality_judged')::int <> 3 OR jsonb_array_length(v_j -> 'ncrs_opened') <> 1
       OR (SELECT result || ':' || limit_max_at FROM quality_limit_judgements WHERE assay_result_id = a3 AND parameter = 'moisture_pct') <> 'above_max:8'
       OR (SELECT trigger_event FROM quality_limit_judgements WHERE assay_result_id = a3 AND parameter = 'moisture_pct') <> 'reserved'
       OR NOT EXISTS (SELECT 1 FROM sales_order_reservations WHERE output_batch_id = ob4 AND released_at IS NULL)
       OR pg_temp.f263_held(NULL, ob4) IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 263 JUDGE: reserving a batch with an assay judges it (another material → the general 8); the breach opens an NCR in the same transaction and the reservation is kept, got %', v_j; END IF;
    -- 结案的争议点名的那一份说了算(对手方的 14,而我们的是 9)
    INSERT INTO assay_results (code, output_batch_id, assay_date, is_final, weight_basis, moisture_pct, result_party)
    VALUES ('ZZ263-OB3-OURS', ob3, v_today - 2, true, 'dry', 9, 'ours') RETURNING id INTO ao;
    INSERT INTO assay_results (code, output_batch_id, assay_date, is_final, weight_basis, moisture_pct, result_party)
    VALUES ('ZZ263-OB3-CP', ob3, v_today - 2, true, 'dry', 14, 'counterparty') RETURNING id INTO ac;
    INSERT INTO assay_result_metals (assay_result_id, metal, content_pct) VALUES (ao, 'ni', 20), (ac, 'ni', 20);
    d_g := (pg_temp.f263_get(u_qe, format($q$SELECT open_assay_dispute(%L, %L, 'moisture differs', %L)$q$, ao, ac, so2)) ->> 'dispute_id')::uuid;
    PERFORM pg_temp.f263_get(u_apl, format($q$SELECT resolve_assay_dispute(%L, %L, 'Their reading stands')$q$, d_g, ac));
    v_j := pg_temp.f263_get(u_sal, format($q$SELECT reserve_stock(%L, %L, 10)$q$, l3, ob3));
    IF (SELECT assay_result_id FROM quality_limit_judgements WHERE output_batch_id = ob3 AND parameter = 'moisture_pct') <> ac
       OR (SELECT result FROM quality_limit_judgements WHERE output_batch_id = ob3 AND parameter = 'moisture_pct') <> 'above_max' THEN
        RAISE EXCEPTION 'FIXTURE 263 JUDGE: after a resolved dispute the governing assay is judged, got %', v_j; END IF;

    -- ══════════════ F5 · 进料的补充 ══════════════
    RAISE NOTICE 'fixture 263 · F5';
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note)
    VALUES ('ZZ263-IBG', v_mat, v_sup, 100, 100, 'kg', v_today - 5, 'other', 'fixture 263') RETURNING id INTO ib_g;
    INSERT INTO inbound_batch_metals (inbound_batch_id, metal, content_pct, content_source) VALUES (ib_g, 'ni', 30, 'manual'), (ib_g, 'f', 0.02, 'manual');
    PERFORM pg_temp.f263_as(u_rec);
    a_s := (record_assay_result(p_assay_date => v_today, p_metals => '[{"metal":"f","content_pct":0.0123},{"metal":"cl","content_pct":0.004}]'::jsonb,
                                p_inbound_batch_id => ib_g, p_weight_basis => 'dry', p_result_party => 'ours') ->> 'assay_result_id')::uuid;
    PERFORM pg_temp.f263_as(NULL);
    v_j := pg_temp.f263_get(u_apl, format($q$SELECT preview_assay_price(%L, '[{"metal":"f","content_pct":0.0123},{"metal":"cl","content_pct":0.004}]'::jsonb, CURRENT_DATE)$q$, ib_g));
    IF (v_j ->> 'supplement')::boolean IS NOT TRUE OR v_j -> 'replaces' <> '["cl", "f"]'::jsonb OR v_j -> 'calc' <> 'null'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 263 F5: the preview says supplement, replaces cl and f, prices nothing, got %', v_j; END IF;
    v_j := pg_temp.f263_get(u_apl, format($q$SELECT apply_assay_result(%L)$q$, a_s));
    IF (v_j ->> 'supplement')::boolean IS NOT TRUE OR (v_j ->> 'price_requested')::boolean
       OR (SELECT string_agg(metal || ':' || content_pct || ':' || content_source || ':' || COALESCE(source_assay_id::text, '-'), ',' ORDER BY metal)
             FROM inbound_batch_metals WHERE inbound_batch_id = ib_g)
          <> 'cl:0.004:assay:' || a_s || ',f:0.0123:assay:' || a_s || ',ni:30:manual:-'
       OR EXISTS (SELECT 1 FROM receipt_price_requests WHERE inbound_batch_id = ib_g) THEN
        RAISE EXCEPTION 'FIXTURE 263 F5: applying the F / Cl assay replaces only F and Cl, keeps ni, prices nothing, got %', v_j; END IF;
    v_msg := pg_temp.f263_do(u_apl, format($q$SELECT unapply_assay_result(%L, 'wrong sample')$q$, a_s));
    IF v_msg <> 'OK' OR (SELECT string_agg(metal, ',' ORDER BY metal) FROM inbound_batch_metals WHERE inbound_batch_id = ib_g) <> 'ni' THEN
        RAISE EXCEPTION 'FIXTURE 263 F5: unapplying a supplement removes only its own rows, got % / %', v_msg,
            (SELECT string_agg(metal, ',' ORDER BY metal) FROM inbound_batch_metals WHERE inbound_batch_id = ib_g); END IF;
    PERFORM pg_temp.f263_get(u_apl, format($q$SELECT apply_assay_result(%L)$q$, a_s));
    PERFORM pg_temp.f263_as(u_rec);
    a_f := (record_assay_result(p_assay_date => v_today, p_metals => '[{"metal":"ni","content_pct":31}]'::jsonb,
                                p_inbound_batch_id => ib_g, p_weight_basis => 'dry', p_result_party => 'ours') ->> 'assay_result_id')::uuid;
    PERFORM pg_temp.f263_as(NULL);
    PERFORM pg_temp.f263_get(u_apl, format($q$SELECT apply_assay_result(%L)$q$, a_f));
    IF (SELECT string_agg(metal || ':' || content_pct, ',' ORDER BY metal) FROM inbound_batch_metals WHERE inbound_batch_id = ib_g) <> 'ni:31'
       OR (SELECT superseded_by FROM assay_results WHERE id = a_s) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 263 F5: a full assay still replaces everything (54E), and a supplement is superseded by nothing'; END IF;

    -- ══════════════ ARMS ══════════════
    RAISE NOTICE 'fixture 263 · ARMS';
    -- ncr_open:开着的报告(质量查看码读得到)
    v_n := (pg_temp.f263_get(u_qv, $q$SELECT to_jsonb(count(*)) FROM operations_now WHERE item_type = 'ncr_open'$q$))::text::bigint;
    IF v_n <> (SELECT count(*) FROM nonconformance_reports WHERE status = 'open') OR v_n = 0 THEN
        RAISE EXCEPTION 'FIXTURE 263 ARMS: ncr_open lists every open NCR, got % vs %', v_n, (SELECT count(*) FROM nonconformance_reports WHERE status = 'open'); END IF;
    -- quality_hold_reserved:OB4 被暂扣、挂着预留 —— 销售查看 + 产出查看看得见;只有销售查看的看不见(收窄)
    v_n := (pg_temp.f263_get(u_sal, $q$SELECT to_jsonb(count(*)) FROM operations_now WHERE item_type = 'quality_hold_reserved'$q$))::text::bigint;
    v_n2 := (pg_temp.f263_get(u_salonly, $q$SELECT to_jsonb(count(*)) FROM operations_now WHERE item_type = 'quality_hold_reserved'$q$))::text::bigint;
    IF v_n < 1 OR v_n2 <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 263 ARMS: quality_hold_reserved shows to sales + output viewers (% rows) and not to a sales-only reader (% rows)', v_n, v_n2; END IF;
    -- 质量查看码、没有产出查看码的读者:暂扣的判据以读者身份读产出批 —— 那一支收窄到产出查看码,所以他【一行都不读】,而不是读到没有批号的行
    v_n2 := (pg_temp.f263_get(u_qv, $q$SELECT to_jsonb(count(*)) FROM operations_now WHERE item_type = 'quality_hold_reserved'$q$))::text::bigint;
    IF v_n2 <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 263 ARMS: quality_hold_reserved is narrowed to output viewers (a quality viewer without it would read rows with no batch), got % rows', v_n2; END IF;
    -- quality_prompt_ncr:品位违反(买方合同、采购单、进料的化验)· 交叉污染过线 · 放电失败 —— 开了报告就消失
    INSERT INTO contracts (supplier_id, kind, title, effective_from, status) VALUES (v_sup, 'supply', 'f263 buy', DATE '2026-01-01', 'active') RETURNING id INTO conP;
    INSERT INTO contract_grade_specs (contract_id, metal, min_pct) VALUES (conP, 'ni', 18);
    PERFORM pg_temp.f263_as(u_all);
    po := (create_purchase_order(v_sup, v_today - 10, v_today, v_base, NULL, 'CIF', NULL, NULL,
           jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 100, 'unit', 'kg')), p_category => 'equipment_goods') ->> 'purchase_order_id')::uuid;
    PERFORM link_document_to_contract('purchase_order', po, conP);
    PERFORM pg_temp.f263_as(NULL);
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, purchase_order_id, purchase_order_line_id, source_reason_code, source_reason_note)
    VALUES ('ZZ263-IBP', v_mat, v_sup, 100, 100, 'kg', v_today - 5, po, (SELECT id FROM purchase_order_lines WHERE purchase_order_id = po LIMIT 1), 'other', 'fixture 263')
    RETURNING id INTO ib_s;
    INSERT INTO assay_results (code, inbound_batch_id, assay_date, is_final, weight_basis, result_party)
    VALUES ('ZZ263-IBP-OURS', ib_s, v_today - 1, true, 'dry', 'ours') RETURNING id INTO a3;
    INSERT INTO assay_result_metals (assay_result_id, metal, content_pct) VALUES (a3, 'ni', 12);
    INSERT INTO processing_runs (code, status, allocation_basis, operation_type_code, started_at, ended_at, shift_code, process_date)
    -- ★ MES-7a-1(2026-10-16 量到):加工日原来写的是 v_today,而开始是 now() − 3 小时 —— 新加坡 00:00–03:00 之间开始落在昨天,
    --   表头守卫按名拒 RUN_DATE_OUTSIDE_RUN_TIME,这一支 fixture 每晚红三个小时。加工日改成开始那一刻的新加坡日子(与表头守卫同一个判据);
    --   断言一条没动。
    VALUES ('ZZ263-RUN', 'committed', 'weight', 'manual_disassembly', now() - interval '3 hours', now() - interval '2 hours', 'day',
            ((now() - interval '3 hours') AT TIME ZONE 'Asia/Singapore')::date) RETURNING id INTO run_c;
    INSERT INTO contamination_checks (run_id, stream_code, kind, output_batch_id, sample_mass_g, foreign_mass_g, warning_pct_at, sampled_at)
    VALUES (run_c, 'cathode', 'sampled', ob_c, 100, 5, 1, now() - interval '1 hour');
    INSERT INTO discharge_module_results (run_id, output_batch_id, module_ref, outlet_voltage_v, verdict, verdict_at, disposition, source)
    VALUES (run_c, ob_d, 'M-01', 3.9, 'fail', now() - interval '1 hour', 're_discharge', 'manual');
    SELECT string_agg(item_code || '/' || doc_kind || '/' || subject, ',' ORDER BY item_code) INTO v_txt FROM (
        SELECT * FROM jsonb_to_recordset(pg_temp.f263_get(u_qv, $q$SELECT COALESCE(jsonb_agg(to_jsonb(o)), '[]'::jsonb) FROM operations_now o WHERE item_type = 'quality_prompt_ncr'$q$))
          AS x(item_code text, doc_kind text, subject text)) y;
    IF v_txt IS DISTINCT FROM (SELECT string_agg(c, ',' ORDER BY c) FROM unnest(ARRAY[
            'ZZ263-IBP/inbound/ZZ263-IBP-OURS',
            (SELECT code FROM output_batches WHERE id = ob_c) || '/output/cathode',
            (SELECT code FROM output_batches WHERE id = ob_d) || '/output/M-01']) c) THEN
        RAISE EXCEPTION 'FIXTURE 263 ARMS: quality_prompt_ncr prompts the grade breach, the contamination above V11 and the failed module, got %', v_txt; END IF;
    PERFORM pg_temp.f263_get(u_qe, format($q$SELECT open_ncr('manual', 'From the prompt', p_inbound_batch_id => %L)$q$, ib_s));
    PERFORM pg_temp.f263_get(u_qe, format($q$SELECT open_ncr('manual', 'From the prompt', p_output_batch_id => %L)$q$, ob_c));
    PERFORM pg_temp.f263_get(u_qe, format($q$SELECT open_ncr('manual', 'From the prompt', p_output_batch_id => %L)$q$, ob_d));
    IF (pg_temp.f263_get(u_qv, $q$SELECT to_jsonb(count(*)) FROM operations_now WHERE item_type = 'quality_prompt_ncr'$q$))::text::int <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 263 ARMS: an NCR opened after the finding clears the prompt'; END IF;
    -- V17:挂了销售单、口径没声明的卖方合同一行(客户查看码);声明了就消失
    INSERT INTO contracts (customer_id, kind, title, effective_from, status) VALUES (v_cust, 'offtake', 'f263 V17 not set', DATE '2026-01-01', 'active') RETURNING id INTO conV;
    INSERT INTO contract_settlement_terms (contract_id, sale_weight_basis, settling_party, sample_retention_required, refining_charge_basis, penalty_basis)
    VALUES (conV, 'dry', 'ours', false, 'none_agreed', 'none_agreed');
    PERFORM pg_temp.f263_as(u_all);
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES (next_sales_order_code(v_today - 4), v_cust, v_today - 4, v_base, 1) RETURNING id INTO soV;
    PERFORM link_document_to_contract('sales_order', soV, conV);
    PERFORM pg_temp.f263_as(NULL);
    IF (pg_temp.f263_get(u_cco, format($q$SELECT to_jsonb(count(*)) FROM pending_values WHERE value_code = 'V17' AND item_id = %L$q$, conV)))::text::int <> 1
       OR (pg_temp.f263_get(u_cco, format($q$SELECT to_jsonb(count(*)) FROM pending_values WHERE value_code = 'V17' AND item_id IN (%L, %L, %L)$q$, conQ, conB, conP)))::text::int <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 263 ARMS: V17 lists a sell contract with a linked order and no basis (not the declared or the buy ones)'; END IF;
    UPDATE contract_settlement_terms SET quality_limit_basis = 'none_agreed' WHERE contract_id = conV;
    IF (pg_temp.f263_get(u_cco, format($q$SELECT to_jsonb(count(*)) FROM pending_values WHERE value_code = 'V17' AND item_id = %L$q$, conV)))::text::int <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 263 ARMS: declaring the basis clears V17'; END IF;

    -- ══════════════ 变更记录:报告的开与决定都在 ══════════════
    RAISE NOTICE 'fixture 263 · LOG';
    IF NOT EXISTS (SELECT 1 FROM change_log WHERE table_name = 'nonconformance_reports' AND op = 'INSERT' AND row_key ->> 'id' = n5::text)
       OR NOT EXISTS (SELECT 1 FROM change_log WHERE table_name = 'nonconformance_reports' AND op = 'UPDATE' AND row_key ->> 'id' = n5::text) THEN
        RAISE EXCEPTION 'FIXTURE 263 LOG: opening and deciding an NCR are both in the change log'; END IF;
    PERFORM pg_temp.f263_agree(u_all, 'end');

    RAISE NOTICE 'FIXTURE 263 全部通过: REG · NCR · DECIDE · HOLD · SETTLE · DISP · BLEND · V17 · JUDGE · F5 · ARMS · LOG';
END $$;
ROLLBACK;
