-- ═══════════════════════════════════════════════════════════════════════════
-- fixture 260 —— 一份样品说得出:是哪一批的、为谁取的、在谁手上、在哪儿、留到哪一天、处置了没有
--   (MES-6a-1,2026-10-09;MES-0 Q53 · Q61 · Q90;MES-6a Step 0 Q7–Q15 · Q39–Q42,Tim 照推荐裁定)
-- ═══════════════════════════════════════════════════════════════════════════
-- 臂:
--   SMP    SMP- 按年无洞(同一年 0001 · 0002;上一年从 0001 起);登记表里 sample / SMP / samples / gapless,读码 module.quality.view
--   CUST   第一行保管记录 taken 由取样写下(库位可带);送实验室(实验室必填、要启用)→ at_lab;在实验室时不能再送、不能挪;拿回来 → held;
--          挪库位要库位;时刻不许倒退、不许在将来;处置要理由 → disposed,之后什么都不能记;保管记录只追加(改 / 删按名拒);
--          一个持质量编辑码的人直插样品表 → 被 RLS 拒(写只经函数)
--   RET    留样日在建的那一刻抄下:V16 空且没有合同 → not_set(没有日子);V16 = 30 → internal(取样日 + 30);指了一张合同要求留样 60 天的
--          销售单 → contract(+ 60,V16 让开);合同要求留样却没写天数 → 回到 V16;V16 改成 90 → 已有的样品【一个都不改】;
--          进料批的样品指销售单 → SAMPLE_SALES_ORDER_NEEDS_OUTPUT_BATCH;取样日空 / 在将来 → 按名拒;交叉污染抽检只对 contamination、
--          只对同一批产出批上取过样的那一条
--   ASSAY  化验指一份样品:别的批的样品 → SAMPLE_NOT_FOR_BATCH(记录函数一道、表上的守卫一道 —— 直插也拒);同一批的 → 记下 sample_id;
--          不指样品照旧记得下(sample_ref 那段自由文本照旧)
--   EARLY  留样日之前处置:照收,理由必填,disposed_early 为真;留样日过了还没处置 → 提醒 sample_retention_due(质量查看码的人看得见,
--          只持进料查看码的人看不见那一支);处置之后它消失;留样日 Not yet set 的样品不进提醒
--   CODES  module.quality.view / .edit 在目录里;action.apply_assay 声明的查看码多了 module.quality.view;引导的 admin 两个都持,
--          财务与仓库只持查看(Q90 · Q12);没有编辑码 → 取样、记保管、设 V16 全部 PERMISSION_DENIED|module.quality.edit;
--          只给编辑不给查看 → EDIT_REQUIRES_VIEW;只持 module.quality.view 的角色持 action.apply_assay 存得下(动作码蕴含查看码)
--   READ   样品与保管记录:质量查看码看得见两种批的;只持进料查看码的只看得见进料批的,只持产出查看码的只看得见产出批的;一个都不持的
--          一行都读不到(基表经 RLS、sample_rows 经它自己的谓词,两条路都测);质量的设定只给质量查看码
--   LOG    四张新表进变更记录(覆盖零缺口、豁免仍是 8);审计主语 sample(成员 sample_events)· assay_dispute · quality_settings 登记了,
--          门是 module.quality.view;进料 / 产出两个批次主语多了样品、保管记录与争议;样品自己的记录读得出它的保管记录;V16 的修改在变更记录里
--   PV     V16 空、而有一份没处置的 Not yet set 样品 → /settings/pending-values 有 V16 一行(质量查看码);只持进料查看码的人看不见;
--          V16 设了 → 那一行消失
--
-- 自带数据(README 第 2 条)。以 postgres 跑(绕过 RLS);员工的调用真的切成 authenticated + 那个人的 JWT。
-- 【数怎么来的】取样日用今天往回数的天数 —— 留样日 = 取样日 + 天数,逐条在断言旁边写着。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '300s';

CREATE FUNCTION pg_temp.f260_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims',
                      CASE WHEN p_user IS NULL THEN '' ELSE format('{"sub":"%s","role":"authenticated"}', p_user) END, true)
$f$;

-- 以某人跑一句;返回 'OK' 或错误原文。之后身份回到调用之前的那一个。
CREATE FUNCTION pg_temp.f260_do(p_user uuid, p_sql text) RETURNS text
LANGUAGE plpgsql AS $f$
DECLARE v_prev text := NULLIF(current_setting('request.jwt.claims', true), '');
BEGIN
    PERFORM pg_temp.f260_as(p_user);
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

-- 以某人读一个值(读不到就抛 —— 读的失败不许被读成一个答案)
CREATE FUNCTION pg_temp.f260_get(p_user uuid, p_sql text) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v jsonb; v_prev text := NULLIF(current_setting('request.jwt.claims', true), '');
BEGIN
    PERFORM pg_temp.f260_as(p_user);
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

-- 一个角色带一组码,授给一个新账号
CREATE FUNCTION pg_temp.f260_user(p_label text, p_codes text[]) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE u uuid := gen_random_uuid(); r uuid;
BEGIN
    INSERT INTO auth.users (id, email, email_confirmed_at, created_at) VALUES (u, 'fx260-' || p_label || '@test.local', now(), now());
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx260-' || p_label, 'f', 'f', true) RETURNING id INTO r;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r, c FROM unnest(p_codes) c;
    INSERT INTO user_roles (user_id, role_id) VALUES (u, r);
    RETURN u;
END;
$f$;

DO $$
DECLARE
    u_all uuid; u_qe uuid; u_qv uuid; u_iv uuid; u_ov uuid; u_none uuid;
    v_year int := EXTRACT(YEAR FROM CURRENT_DATE)::int;
    v_today date := CURRENT_DATE;
    v_sup uuid; v_mat uuid; v_cust uuid; ib1 uuid; ib2 uuid; ob1 uuid; loc1 uuid; loc2 uuid;
    c_ret uuid; c_nodays uuid; so_ret uuid; so_nodays uuid; v_run uuid; v_chk bigint; v_chk2 bigint;
    s1 uuid; s2 uuid; s3 uuid; s4 uuid; s5 uuid; s6 uuid; s7 uuid; s_old uuid; s_due uuid; s_early uuid;
    v_j jsonb; v_msg text; v_n bigint; v_txt text; v_a uuid; r_q uuid;
BEGIN
    u_all  := pg_temp.f260_user('all', (SELECT array_agg(code) FROM permissions));
    u_qe   := pg_temp.f260_user('qe', ARRAY['module.quality.view', 'module.quality.edit']);
    u_qv   := pg_temp.f260_user('qv', ARRAY['module.quality.view']);
    u_iv   := pg_temp.f260_user('iv', ARRAY['module.inbound.view']);
    u_ov   := pg_temp.f260_user('ov', ARRAY['module.output.view']);
    u_none := pg_temp.f260_user('none', ARRAY['module.tasks.view']);

    -- ══════════════ 布景 ══════════════
    PERFORM pg_temp.f260_as(NULL);
    UPDATE finance_settings SET locked_before = NULL;
    UPDATE quality_settings SET internal_retention_days = NULL WHERE id;
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ260-S', 'f260 supplier', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZ260-BM', 'f260 black mass', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO v_mat;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note)
    VALUES ('ZZ260-IB1', v_mat, v_sup, 1000, 1000, 'kg', v_today - 60, 'other', 'fixture 260 自带数据') RETURNING id INTO ib1;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note)
    VALUES ('ZZ260-IB2', v_mat, v_sup, 1000, 1000, 'kg', v_today - 60, 'other', 'fixture 260 自带数据') RETURNING id INTO ib2;
    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, output_date)
    VALUES ('ZZ260-OB1', v_mat, 500, 500, v_today - 50) RETURNING id INTO ob1;
    INSERT INTO storage_locations (code, name) VALUES ('ZZ260-L1', 'f260 sample shelf') RETURNING id INTO loc1;
    INSERT INTO storage_locations (code, name) VALUES ('ZZ260-L2', 'f260 sample fridge') RETURNING id INTO loc2;
    INSERT INTO laboratories (code, name_en, name_zh, is_active, sort_order) VALUES
        ('ZZ260-LAB', 'f260 lab', 'f260 实验室', true, 990), ('ZZ260-OLD', 'f260 old lab', 'f260 旧实验室', false, 991);
    -- 两份卖方合同:一份要求留样 60 天,一份要求留样却没写天数;各挂一张销售单(挂接那一刻抄下副本)
    INSERT INTO customers (code, legal_name, country, payment_terms_days)
    VALUES ('ZZ260-C', 'f260 customer', 'SG', 30) RETURNING id INTO v_cust;
    INSERT INTO contracts (customer_id, kind, title, effective_from, status)
    VALUES (v_cust, 'offtake', 'f260 retention 60', DATE '2026-01-01', 'active') RETURNING id INTO c_ret;
    INSERT INTO contracts (customer_id, kind, title, effective_from, status)
    VALUES (v_cust, 'offtake', 'f260 retention no days', DATE '2026-01-01', 'active') RETURNING id INTO c_nodays;
    INSERT INTO contract_settlement_terms (contract_id, sale_weight_basis, settling_party, sample_retention_required, sample_retention_days,
                                           refining_charge_basis, penalty_basis)
    VALUES (c_ret, 'dry', 'ours', true, 60, 'none_agreed', 'none_agreed'),
           (c_nodays, 'dry', 'ours', true, NULL, 'none_agreed', 'none_agreed');
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES ('ZZ260-SO-R', v_cust, v_today - 20, (SELECT code FROM currencies WHERE is_base), 1) RETURNING id INTO so_ret;
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES ('ZZ260-SO-N', v_cust, v_today - 20, (SELECT code FROM currencies WHERE is_base), 1) RETURNING id INTO so_nodays;
    PERFORM pg_temp.f260_as(u_all);
    PERFORM link_document_to_contract('sales_order', so_ret, c_ret);
    PERFORM link_document_to_contract('sales_order', so_nodays, c_nodays);
    PERFORM pg_temp.f260_as(NULL);

    -- ══════════════ SMP ══════════════
    RAISE NOTICE 'fixture 260 · SMP';
    IF NOT EXISTS (SELECT 1 FROM document_types WHERE key = 'sample' AND prefix = 'SMP' AND table_name = 'samples' AND numbering = 'gapless'
                     AND route = '/quality/samples' AND view_permission = ARRAY['module.quality.view'])
       OR document_type_prefix('sample') <> 'SMP' THEN
        RAISE EXCEPTION 'FIXTURE 260 SMP: the registry row sample / SMP / samples / gapless, read code module.quality.view'; END IF;
    v_j := pg_temp.f260_get(u_qe, format($q$SELECT record_sample('ours', %L::date, p_inbound_batch_id => %L, p_storage_location_id => %L, p_mass_g => 250, p_notes => 'top of the drum')$q$, v_today, ib1, loc1));
    s1 := (v_j ->> 'sample_id')::uuid;
    IF v_j ->> 'code' <> format('SMP-%s-0001', v_year) THEN RAISE EXCEPTION 'FIXTURE 260 SMP: the first sample of the year is SMP-%-0001, got %', v_year, v_j; END IF;
    v_j := pg_temp.f260_get(u_qe, format($q$SELECT record_sample('counterparty', %L::date, p_inbound_batch_id => %L)$q$, v_today, ib1));
    s2 := (v_j ->> 'sample_id')::uuid;
    IF v_j ->> 'code' <> format('SMP-%s-0002', v_year) THEN RAISE EXCEPTION 'FIXTURE 260 SMP: the second sample is SMP-%-0002 (gapless), got %', v_year, v_j; END IF;
    v_j := pg_temp.f260_get(u_qe, format($q$SELECT record_sample('retained', %L::date, p_output_batch_id => %L)$q$, make_date(v_year - 1, 12, 31), ob1));
    s_old := (v_j ->> 'sample_id')::uuid;
    IF v_j ->> 'code' <> format('SMP-%s-0001', v_year - 1) THEN RAISE EXCEPTION 'FIXTURE 260 SMP: a sample taken last year starts that year at 0001, got %', v_j; END IF;
    IF next_sample_code(v_today) <> format('SMP-%s-0003', v_year) THEN RAISE EXCEPTION 'FIXTURE 260 SMP: the next code this year is 0003'; END IF;

    -- ══════════════ CUST ══════════════
    RAISE NOTICE 'fixture 260 · CUST';
    IF (SELECT array_agg(event_kind || ':' || COALESCE(storage_location_id::text, '-') ORDER BY id) FROM sample_events WHERE sample_id = s1)
         IS DISTINCT FROM ARRAY['taken:' || loc1::text]
       OR (SELECT occurred_at FROM sample_events WHERE sample_id = s1) <> (v_today::timestamp AT TIME ZONE 'Asia/Singapore') THEN
        RAISE EXCEPTION 'FIXTURE 260 CUST: taking a sample writes one "taken" event at that day''s Singapore midnight, with the shelf'; END IF;
    v_j := pg_temp.f260_get(u_all, format($q$SELECT to_jsonb(r) FROM sample_rows r WHERE r.id = %L$q$, s1));
    IF (v_j ->> 'state') <> 'held' OR (v_j ->> 'storage_location_code') <> 'ZZ260-L1' OR (v_j ->> 'batch_code') <> 'ZZ260-IB1'
       OR (v_j ->> 'kind') <> 'ours' OR (v_j ->> 'mass_g')::numeric <> 250 THEN
        RAISE EXCEPTION 'FIXTURE 260 CUST: a fresh sample is held on its shelf, got %', v_j; END IF;
    v_msg := pg_temp.f260_do(u_qe, format($q$SELECT record_sample_event(%L, 'moved', now())$q$, s1));
    IF v_msg NOT LIKE 'SAMPLE_LOCATION_REQUIRED|%' THEN RAISE EXCEPTION 'FIXTURE 260 CUST: a move needs a location, got %', v_msg; END IF;
    v_msg := pg_temp.f260_do(u_qe, format($q$SELECT record_sample_event(%L, 'sent_to_lab', now())$q$, s1));
    IF v_msg NOT LIKE 'SAMPLE_LAB_REQUIRED|%' THEN RAISE EXCEPTION 'FIXTURE 260 CUST: sending needs a laboratory, got %', v_msg; END IF;
    v_msg := pg_temp.f260_do(u_qe, format($q$SELECT record_sample_event(%L, 'sent_to_lab', now(), 'ZZ260-OLD')$q$, s1));
    IF v_msg NOT LIKE 'LAB_NOT_FOUND|ZZ260-OLD%' THEN RAISE EXCEPTION 'FIXTURE 260 CUST: an inactive laboratory is refused, got %', v_msg; END IF;
    v_msg := pg_temp.f260_do(u_qe, format($q$SELECT record_sample_event(%L, 'sent_to_lab', %L::timestamptz, 'ZZ260-LAB')$q$, s1, (v_today - 1)::timestamp AT TIME ZONE 'Asia/Singapore'));
    IF v_msg NOT LIKE 'SAMPLE_EVENT_OUT_OF_ORDER|%' THEN RAISE EXCEPTION 'FIXTURE 260 CUST: an event before the last one is refused, got %', v_msg; END IF;
    v_msg := pg_temp.f260_do(u_qe, format($q$SELECT record_sample_event(%L, 'sent_to_lab', now() + interval '1 day', 'ZZ260-LAB')$q$, s1));
    IF v_msg NOT LIKE 'SAMPLE_EVENT_IN_FUTURE|%' THEN RAISE EXCEPTION 'FIXTURE 260 CUST: an event in the future is refused, got %', v_msg; END IF;
    v_msg := pg_temp.f260_do(u_qe, format($q$SELECT record_sample_event(%L, 'taken', now())$q$, s1));
    IF v_msg NOT LIKE 'SAMPLE_EVENT_KIND_INVALID|taken%' THEN RAISE EXCEPTION 'FIXTURE 260 CUST: "taken" is written only by taking the sample, got %', v_msg; END IF;
    v_msg := pg_temp.f260_do(u_qe, format($q$SELECT record_sample_event(%L, 'sent_to_lab', now(), 'ZZ260-LAB', 'LAB-REF-77')$q$, s1));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 260 CUST: sending to an active lab, got %', v_msg; END IF;
    v_j := pg_temp.f260_get(u_all, format($q$SELECT to_jsonb(r) FROM sample_rows r WHERE r.id = %L$q$, s1));
    IF (v_j ->> 'state') <> 'at_lab' OR (v_j ->> 'laboratory_code') <> 'ZZ260-LAB' OR (v_j ->> 'lab_reference') <> 'LAB-REF-77'
       OR (v_j ->> 'storage_location_id') IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 260 CUST: the latest event says it is at the lab, with the lab''s reference and no shelf, got %', v_j; END IF;
    v_msg := pg_temp.f260_do(u_qe, format($q$SELECT record_sample_event(%L, 'sent_to_lab', now(), 'ZZ260-LAB')$q$, s1))
          || ' / ' || pg_temp.f260_do(u_qe, format($q$SELECT record_sample_event(%L, 'moved', now(), p_storage_location_id => %L)$q$, s1, loc2));
    IF v_msg NOT LIKE 'SAMPLE_EVENT_NOT_ALLOWED|%|at_lab|sent_to_lab / SAMPLE_EVENT_NOT_ALLOWED|%|at_lab|moved' THEN
        RAISE EXCEPTION 'FIXTURE 260 CUST: at the lab it can only come back or be disposed of, got %', v_msg; END IF;
    v_msg := pg_temp.f260_do(u_qe, format($q$SELECT record_sample_event(%L, 'received_back', now(), p_storage_location_id => %L)$q$, s1, loc2));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 260 CUST: received back onto the fridge, got %', v_msg; END IF;
    v_j := pg_temp.f260_get(u_all, format($q$SELECT to_jsonb(r) FROM sample_rows r WHERE r.id = %L$q$, s1));
    IF (v_j ->> 'state') <> 'held' OR (v_j ->> 'storage_location_code') <> 'ZZ260-L2' OR (v_j ->> 'laboratory_code') IS NOT NULL
       OR (v_j ->> 'event_count')::int <> 3 THEN
        RAISE EXCEPTION 'FIXTURE 260 CUST: back from the lab it is held where the latest event put it, got %', v_j; END IF;
    v_msg := pg_temp.f260_do(u_qe, format($q$SELECT record_sample_event(%L, 'received_back', now())$q$, s1));
    IF v_msg NOT LIKE 'SAMPLE_EVENT_NOT_ALLOWED|%|held|received_back' THEN RAISE EXCEPTION 'FIXTURE 260 CUST: a held sample cannot be received back, got %', v_msg; END IF;
    v_msg := pg_temp.f260_do(u_qe, format($q$SELECT record_sample_event(%L, 'moved', now(), p_storage_location_id => %L, p_reason => 'why')$q$, s1, loc1));
    IF v_msg NOT LIKE 'SAMPLE_REASON_ONLY_WHEN_DISPOSED|%' THEN RAISE EXCEPTION 'FIXTURE 260 CUST: a reason belongs to a disposal only, got %', v_msg; END IF;
    v_msg := pg_temp.f260_do(u_qe, format($q$SELECT record_sample_event(%L, 'moved', now(), p_storage_location_id => %L)$q$, s1, loc1));
    IF v_msg <> 'OK' OR (pg_temp.f260_get(u_all, format($q$SELECT to_jsonb(storage_location_code) FROM sample_rows WHERE id = %L$q$, s1)) #>> '{}') <> 'ZZ260-L1' THEN
        RAISE EXCEPTION 'FIXTURE 260 CUST: moved back to the shelf, got %', v_msg; END IF;
    -- 只追加:改 / 删按名拒(连属主也一样 —— 语句级守卫)
    BEGIN UPDATE sample_events SET notes = 'x' WHERE sample_id = s1; RAISE EXCEPTION 'F260_PROBE';
    EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'APPEND_ONLY|sample_events|update%' THEN RAISE EXCEPTION 'FIXTURE 260 CUST: custody events are append-only (update), got %', SQLERRM; END IF; END;
    BEGIN DELETE FROM sample_events WHERE sample_id = s1; RAISE EXCEPTION 'F260_PROBE';
    EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'APPEND_ONLY|sample_events|delete%' THEN RAISE EXCEPTION 'FIXTURE 260 CUST: custody events are append-only (delete), got %', SQLERRM; END IF; END;
    -- 写只经函数:持编辑码的人直插样品表 → RLS 拒
    v_msg := pg_temp.f260_do(u_qe, format($q$INSERT INTO samples (code, inbound_batch_id, kind, taken_on, retain_until_source) VALUES ('ZZ260-X', %L, 'ours', CURRENT_DATE, 'not_set')$q$, ib1));
    IF v_msg NOT LIKE '%row-level security%' AND v_msg NOT LIKE '%permission denied%' THEN
        RAISE EXCEPTION 'FIXTURE 260 CUST: a direct insert into samples is refused (functions only), got %', v_msg; END IF;
    -- 处置:理由必填;之后什么都不能记
    v_msg := pg_temp.f260_do(u_qe, format($q$SELECT record_sample_event(%L, 'disposed', now(), p_reason => '   ')$q$, s2));
    IF v_msg NOT LIKE 'SAMPLE_DISPOSAL_REASON_REQUIRED|%' THEN RAISE EXCEPTION 'FIXTURE 260 CUST: disposal needs a reason, got %', v_msg; END IF;
    v_msg := pg_temp.f260_do(u_qe, format($q$SELECT record_sample_event(%L, 'disposed', now(), p_reason => 'Counterparty confirmed the result')$q$, s2));
    IF v_msg <> 'OK' OR (pg_temp.f260_get(u_all, format($q$SELECT to_jsonb(state) FROM sample_rows WHERE id = %L$q$, s2)) #>> '{}') <> 'disposed' THEN
        RAISE EXCEPTION 'FIXTURE 260 CUST: disposed, got %', v_msg; END IF;
    v_msg := pg_temp.f260_do(u_qe, format($q$SELECT record_sample_event(%L, 'moved', now(), p_storage_location_id => %L)$q$, s2, loc1));
    IF v_msg NOT LIKE 'SAMPLE_DISPOSED|%' THEN RAISE EXCEPTION 'FIXTURE 260 CUST: nothing is recorded after disposal, got %', v_msg; END IF;

    -- ══════════════ RET ══════════════
    RAISE NOTICE 'fixture 260 · RET';
    -- V16 空、没有合同 → not_set
    IF (SELECT (retain_until IS NULL, retain_until_source, retention_days_at IS NULL) FROM samples WHERE id = s1)
         IS DISTINCT FROM (true, 'not_set'::text, true) THEN
        RAISE EXCEPTION 'FIXTURE 260 RET: with V16 empty and no contract the sample has no retain-until (Not yet set)'; END IF;
    -- V16 = 30 → internal,取样日 + 30
    v_msg := pg_temp.f260_do(u_qe, 'SELECT set_quality_settings(30)');
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 260 RET: setting V16, got %', v_msg; END IF;
    v_j := pg_temp.f260_get(u_qe, format($q$SELECT record_sample('retained', %L::date, p_output_batch_id => %L)$q$, v_today - 5, ob1));
    s3 := (v_j ->> 'sample_id')::uuid;
    IF (SELECT (retain_until, retain_until_source, retention_days_at) FROM samples WHERE id = s3)
         IS DISTINCT FROM (v_today - 5 + 30, 'internal'::text, 30) THEN
        RAISE EXCEPTION 'FIXTURE 260 RET: V16 30 → taken on (today − 5) + 30, internal'; END IF;
    -- 合同要求留样 60 天 → contract,取样日 + 60(V16 让开)
    v_j := pg_temp.f260_get(u_qe, format($q$SELECT record_sample('retained', %L::date, p_output_batch_id => %L, p_sales_order_id => %L)$q$, v_today - 5, ob1, so_ret));
    s4 := (v_j ->> 'sample_id')::uuid;
    IF (SELECT (retain_until, retain_until_source, retention_days_at, sales_order_id) FROM samples WHERE id = s4)
         IS DISTINCT FROM (v_today - 5 + 60, 'contract'::text, 60, so_ret) THEN
        RAISE EXCEPTION 'FIXTURE 260 RET: the contract''s 60 days win over V16 → taken on + 60, contract'; END IF;
    -- 合同要求留样却没写天数 → 回到 V16
    v_j := pg_temp.f260_get(u_qe, format($q$SELECT record_sample('retained', %L::date, p_output_batch_id => %L, p_sales_order_id => %L)$q$, v_today - 5, ob1, so_nodays));
    s5 := (v_j ->> 'sample_id')::uuid;
    IF (SELECT (retain_until, retain_until_source) FROM samples WHERE id = s5) IS DISTINCT FROM (v_today - 5 + 30, 'internal'::text) THEN
        RAISE EXCEPTION 'FIXTURE 260 RET: a contract that requires retention without days falls back to V16'; END IF;
    -- V16 改成 90 → 已有的样品一个都不改
    v_msg := pg_temp.f260_do(u_qe, 'SELECT set_quality_settings(90)');
    IF (SELECT array_agg(COALESCE(retain_until::text, '-') ORDER BY code) FROM samples WHERE id IN (s1, s3, s4, s5))
         IS DISTINCT FROM ARRAY['-', (v_today - 5 + 30)::text, (v_today - 5 + 60)::text, (v_today - 5 + 30)::text] THEN
        RAISE EXCEPTION 'FIXTURE 260 RET: changing V16 never re-dates an existing sample'; END IF;
    v_msg := pg_temp.f260_do(u_qe, 'SELECT set_quality_settings(0)');
    IF v_msg NOT LIKE 'QUALITY_RETENTION_DAYS_INVALID|%' THEN RAISE EXCEPTION 'FIXTURE 260 RET: V16 must be > 0, got %', v_msg; END IF;
    v_msg := pg_temp.f260_do(u_qe, format($q$SELECT record_sample('retained', %L::date, p_inbound_batch_id => %L, p_sales_order_id => %L)$q$, v_today, ib1, so_ret));
    IF v_msg NOT LIKE 'SAMPLE_SALES_ORDER_NEEDS_OUTPUT_BATCH%' THEN RAISE EXCEPTION 'FIXTURE 260 RET: an inbound sample names no sales order, got %', v_msg; END IF;
    v_msg := pg_temp.f260_do(u_qe, format($q$SELECT record_sample('ours', NULL::date, p_inbound_batch_id => %L)$q$, ib1));
    IF v_msg NOT LIKE 'SAMPLE_DATE_REQUIRED%' THEN RAISE EXCEPTION 'FIXTURE 260 RET: the sampling date is required (no default), got %', v_msg; END IF;
    v_msg := pg_temp.f260_do(u_qe, format($q$SELECT record_sample('ours', %L::date, p_inbound_batch_id => %L)$q$, v_today + 2, ib1));
    IF v_msg NOT LIKE 'SAMPLE_DATE_IN_FUTURE|%' THEN RAISE EXCEPTION 'FIXTURE 260 RET: a sampling date in the future is refused, got %', v_msg; END IF;
    v_msg := pg_temp.f260_do(u_qe, format($q$SELECT record_sample('ours', %L::date, p_inbound_batch_id => %L, p_output_batch_id => %L)$q$, v_today, ib1, ob1));
    IF v_msg NOT LIKE 'SAMPLE_ONE_PARENT%' THEN RAISE EXCEPTION 'FIXTURE 260 RET: exactly one batch, got %', v_msg; END IF;
    v_msg := pg_temp.f260_do(u_qe, format($q$SELECT record_sample('spare', %L::date, p_inbound_batch_id => %L)$q$, v_today, ib1));
    IF v_msg NOT LIKE 'SAMPLE_KIND_INVALID|spare%' THEN RAISE EXCEPTION 'FIXTURE 260 RET: five kinds only, got %', v_msg; END IF;
    -- 交叉污染抽检:只对 contamination,只对同一批产出批上取过样的那一条
    INSERT INTO processing_runs (code, process_date, total_input, status, allocation_basis, operation_type_code, started_at, ended_at, shift_code)
    VALUES ('ZZ260-RUN', v_today - 50, 0, 'committed', 'weight', 'electrode_separation', (v_today - 50)::timestamptz,
            (v_today - 50)::timestamptz + interval '1 hour', 'day') RETURNING id INTO v_run;
    INSERT INTO contamination_checks (run_id, stream_code, kind, output_batch_id, sample_mass_g, foreign_mass_g, sampled_at)
    VALUES (v_run, (SELECT code FROM contamination_streams ORDER BY code LIMIT 1), 'sampled', ob1, 100, 2, now()) RETURNING id INTO v_chk;
    INSERT INTO contamination_checks (run_id, stream_code, kind, not_sampled_reason)
    VALUES (v_run, (SELECT code FROM contamination_streams ORDER BY code LIMIT 1 OFFSET 1), 'not_sampled', 'line stopped') RETURNING id INTO v_chk2;
    v_msg := pg_temp.f260_do(u_qe, format($q$SELECT record_sample('retained', %L::date, p_output_batch_id => %L, p_contamination_check_id => %s)$q$, v_today, ob1, v_chk));
    IF v_msg NOT LIKE 'SAMPLE_CHECK_ONLY_FOR_CONTAMINATION|retained%' THEN RAISE EXCEPTION 'FIXTURE 260 RET: only a contamination sample names a check, got %', v_msg; END IF;
    v_msg := pg_temp.f260_do(u_qe, format($q$SELECT record_sample('contamination', %L::date, p_output_batch_id => %L, p_contamination_check_id => %s)$q$, v_today, ob1, v_chk2));
    IF v_msg NOT LIKE 'SAMPLE_CHECK_NOT_FOR_BATCH|%' THEN RAISE EXCEPTION 'FIXTURE 260 RET: a not-sampled check cannot carry a sample, got %', v_msg; END IF;
    v_j := pg_temp.f260_get(u_qe, format($q$SELECT record_sample('contamination', %L::date, p_output_batch_id => %L, p_contamination_check_id => %s)$q$, v_today, ob1, v_chk));
    s6 := (v_j ->> 'sample_id')::uuid;
    IF (SELECT contamination_check_id FROM samples WHERE id = s6) IS DISTINCT FROM v_chk THEN
        RAISE EXCEPTION 'FIXTURE 260 RET: the contamination sample points at its check'; END IF;

    -- ══════════════ ASSAY ══════════════
    RAISE NOTICE 'fixture 260 · ASSAY';
    v_j := pg_temp.f260_get(u_qe, format($q$SELECT record_sample('ours', %L::date, p_inbound_batch_id => %L)$q$, v_today, ib2));
    s7 := (v_j ->> 'sample_id')::uuid;
    v_msg := pg_temp.f260_do(u_all, format($q$SELECT record_assay_result(p_assay_date => CURRENT_DATE, p_metals => '[{"metal":"ni","content_pct":12}]'::jsonb, p_inbound_batch_id => %L, p_weight_basis => 'dry', p_result_party => 'ours', p_sample_id => %L)$q$, ib1, s7));
    IF v_msg NOT LIKE format('SAMPLE_NOT_FOR_BATCH|SMP-%s-%%', v_year) THEN
        RAISE EXCEPTION 'FIXTURE 260 ASSAY: a sample of another batch is refused by name (the function), got %', v_msg; END IF;
    BEGIN
        INSERT INTO assay_results (code, inbound_batch_id, assay_date, weight_basis, result_party, sample_id)
        VALUES ('ZZ260-AR-X', ib1, v_today, 'dry', 'ours', s7);
        RAISE EXCEPTION 'F260_PROBE';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'SAMPLE_NOT_FOR_BATCH|%' THEN RAISE EXCEPTION 'FIXTURE 260 ASSAY: the table guard refuses a direct write too, got %', SQLERRM; END IF;
    END;
    v_j := pg_temp.f260_get(u_all, format($q$SELECT record_assay_result(p_assay_date => CURRENT_DATE, p_metals => '[{"metal":"ni","content_pct":12}]'::jsonb, p_inbound_batch_id => %L, p_weight_basis => 'dry', p_result_party => 'ours', p_sample_id => %L, p_sample_ref => 'jar 4')$q$, ib1, s1));
    v_a := (v_j ->> 'assay_result_id')::uuid;
    IF (SELECT (sample_id, sample_ref) FROM assay_results WHERE id = v_a) IS DISTINCT FROM (s1, 'jar 4'::text) THEN
        RAISE EXCEPTION 'FIXTURE 260 ASSAY: the assay keeps its sample beside the free-text reference'; END IF;
    v_msg := pg_temp.f260_do(u_all, format($q$SELECT record_assay_result(p_assay_date => CURRENT_DATE, p_metals => '[{"metal":"co","content_pct":3}]'::jsonb, p_inbound_batch_id => %L, p_weight_basis => 'dry', p_result_party => 'counterparty')$q$, ib1));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 260 ASSAY: without a sample it records as before, got %', v_msg; END IF;
    -- 换成同一批的样品(直连改)守卫照判
    BEGIN
        UPDATE assay_results SET sample_id = s7 WHERE id = v_a;
        RAISE EXCEPTION 'F260_PROBE';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'SAMPLE_NOT_FOR_BATCH|%' THEN RAISE EXCEPTION 'FIXTURE 260 ASSAY: re-pointing to another batch''s sample is refused, got %', SQLERRM; END IF;
    END;

    -- ══════════════ EARLY ══════════════
    RAISE NOTICE 'fixture 260 · EARLY';
    PERFORM pg_temp.f260_do(u_qe, 'SELECT set_quality_settings(30)');
    -- 40 天前取的、V16 30 → 留样日是 10 天前,还没处置 → 提醒;取样日在将来的样品不存在,所以"今天取、30 天后"那一份不提醒
    v_j := pg_temp.f260_get(u_qe, format($q$SELECT record_sample('retained', %L::date, p_inbound_batch_id => %L)$q$, v_today - 40, ib2));
    s_due := (v_j ->> 'sample_id')::uuid;
    v_j := pg_temp.f260_get(u_qe, format($q$SELECT record_sample('retained', %L::date, p_inbound_batch_id => %L)$q$, v_today, ib2));
    s_early := (v_j ->> 'sample_id')::uuid;
    v_txt := pg_temp.f260_get(u_qv, $q$SELECT to_jsonb(string_agg(item_code, ',' ORDER BY item_code)) FROM operations_now WHERE item_type = 'sample_retention_due'$q$) #>> '{}';
    IF v_txt IS DISTINCT FROM (SELECT code FROM samples WHERE id = s_due) THEN
        RAISE EXCEPTION 'FIXTURE 260 EARLY: exactly the sample past its retain-until is due (s1 has no date, s_early is not due yet), got %', v_txt; END IF;
    IF (pg_temp.f260_get(u_iv, $q$SELECT to_jsonb(count(*)) FROM operations_now WHERE item_type = 'sample_retention_due'$q$))::text::int <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 260 EARLY: the reminder is for quality-view holders only'; END IF;
    IF NOT (pg_temp.f260_get(u_all, format($q$SELECT to_jsonb(retention_due) FROM sample_rows WHERE id = %L$q$, s_due)))::text::boolean THEN
        RAISE EXCEPTION 'FIXTURE 260 EARLY: sample_rows flags it as due'; END IF;
    -- 留样日之前处置:照收,标出来
    v_msg := pg_temp.f260_do(u_qe, format($q$SELECT record_sample_event(%L, 'disposed', now(), p_reason => 'Jar cracked on the shelf')$q$, s_early));
    IF v_msg <> 'OK' OR NOT (pg_temp.f260_get(u_all, format($q$SELECT to_jsonb(disposed_early) FROM sample_rows WHERE id = %L$q$, s_early)))::text::boolean
       OR (pg_temp.f260_get(u_all, format($q$SELECT to_jsonb(disposal_reason) FROM sample_rows WHERE id = %L$q$, s_early)) #>> '{}') <> 'Jar cracked on the shelf' THEN
        RAISE EXCEPTION 'FIXTURE 260 EARLY: disposal before retain-until is accepted with its reason and flagged early, got %', v_msg; END IF;
    -- 过了留样日的处置不算早;处置之后提醒消失
    v_msg := pg_temp.f260_do(u_qe, format($q$SELECT record_sample_event(%L, 'disposed', now(), p_reason => 'Retention period over')$q$, s_due));
    IF (pg_temp.f260_get(u_all, format($q$SELECT to_jsonb(disposed_early) FROM sample_rows WHERE id = %L$q$, s_due)))::text::boolean
       OR (pg_temp.f260_get(u_qv, $q$SELECT to_jsonb(count(*)) FROM operations_now WHERE item_type = 'sample_retention_due'$q$))::text::int <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 260 EARLY: disposed after retain-until is not early, and the reminder is gone'; END IF;

    -- ══════════════ CODES ══════════════
    RAISE NOTICE 'fixture 260 · CODES';
    IF (SELECT count(*) FROM permissions WHERE code IN ('module.quality.view', 'module.quality.edit') AND category = 'module') <> 2
       OR NOT (SELECT 'module.quality.view' = ANY (requires_view_any) FROM permissions WHERE code = 'action.apply_assay') THEN
        RAISE EXCEPTION 'FIXTURE 260 CODES: two module codes; action.apply_assay declares module.quality.view among its pages'' views'; END IF;
    IF (SELECT array_agg(r.code || ':' || rp.permission_code ORDER BY r.code, rp.permission_code) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         WHERE rp.permission_code LIKE 'module.quality.%' AND r.code NOT LIKE 'fx260-%')
         IS DISTINCT FROM ARRAY['admin:module.quality.edit', 'admin:module.quality.view', 'finance:module.quality.view', 'warehouse:module.quality.view'] THEN
        RAISE EXCEPTION 'FIXTURE 260 CODES: the bootstrap gives admin both, finance and warehouse view only (Q90 · Q12), got %',
            (SELECT array_agg(r.code || ':' || rp.permission_code ORDER BY r.code, rp.permission_code) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
              WHERE rp.permission_code LIKE 'module.quality.%' AND r.code NOT LIKE 'fx260-%'); END IF;
    v_msg := pg_temp.f260_do(u_qv, format($q$SELECT record_sample('ours', CURRENT_DATE, p_inbound_batch_id => %L)$q$, ib1))
          || ' / ' || pg_temp.f260_do(u_qv, format($q$SELECT record_sample_event(%L, 'moved', now(), p_storage_location_id => %L)$q$, s1, loc2))
          || ' / ' || pg_temp.f260_do(u_qv, 'SELECT set_quality_settings(10)');
    IF v_msg NOT LIKE 'PERMISSION_DENIED|module.quality.edit% / PERMISSION_DENIED|module.quality.edit% / PERMISSION_DENIED|module.quality.edit%' THEN
        RAISE EXCEPTION 'FIXTURE 260 CODES: without module.quality.edit nothing is recorded, got %', v_msg; END IF;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx260-codes', 'f', 'f', true) RETURNING id INTO r_q;
    v_msg := pg_temp.f260_do(u_all, format($q$SELECT set_role_permissions(%L::uuid, ARRAY['module.quality.edit'])$q$, r_q));
    IF v_msg NOT LIKE 'EDIT_REQUIRES_VIEW%' THEN RAISE EXCEPTION 'FIXTURE 260 CODES: quality edit needs quality view, got %', v_msg; END IF;
    v_msg := pg_temp.f260_do(u_all, format($q$SELECT set_role_permissions(%L::uuid, ARRAY['action.apply_assay', 'module.quality.view'])$q$, r_q));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 260 CODES: resolving disputes from the quality page — apply_assay with quality view saves (action implies view), got %', v_msg; END IF;
    v_msg := pg_temp.f260_do(u_all, format($q$SELECT set_role_permissions(%L::uuid, ARRAY['action.apply_assay', 'module.tasks.view'])$q$, r_q));
    IF v_msg NOT LIKE 'ACTION_REQUIRES_VIEW|action.apply_assay|%module.quality.view%' THEN
        RAISE EXCEPTION 'FIXTURE 260 CODES: apply_assay without any of its pages'' views is refused and names quality view among them, got %', v_msg; END IF;
    -- 引导里的每一个角色都满足"动作码蕴含查看码"(新码进来之后)
    IF EXISTS (SELECT 1 FROM role_permissions rp JOIN permissions p ON p.code = rp.permission_code
                WHERE p.requires_view_any IS NOT NULL AND cardinality(p.requires_view_any) > 0
                  AND NOT EXISTS (SELECT 1 FROM role_permissions v WHERE v.role_id = rp.role_id AND v.permission_code = ANY (p.requires_view_any))) THEN
        RAISE EXCEPTION 'FIXTURE 260 CODES: every role satisfies action-implies-view'; END IF;

    -- ══════════════ READ ══════════════
    RAISE NOTICE 'fixture 260 · READ';
    v_j := jsonb_build_object(
        'qv', pg_temp.f260_get(u_qv, $q$SELECT jsonb_build_object('rows', count(*), 'in', count(*) FILTER (WHERE inbound_batch_id IS NOT NULL), 'out', count(*) FILTER (WHERE output_batch_id IS NOT NULL)) FROM samples WHERE code LIKE 'SMP-%'$q$),
        'iv', pg_temp.f260_get(u_iv, $q$SELECT jsonb_build_object('rows', count(*), 'out', count(*) FILTER (WHERE output_batch_id IS NOT NULL)) FROM samples$q$),
        'ov', pg_temp.f260_get(u_ov, $q$SELECT jsonb_build_object('rows', count(*), 'in', count(*) FILTER (WHERE inbound_batch_id IS NOT NULL)) FROM samples$q$),
        'none', pg_temp.f260_get(u_none, $q$SELECT jsonb_build_object('rows', count(*)) FROM samples$q$),
        'none_rows_view', pg_temp.f260_get(u_none, $q$SELECT to_jsonb(count(*)) FROM sample_rows$q$),
        -- 不经 samples 去连(那张表自己的 RLS 会先把产出批的样品藏起来,于是这一格对保管记录自己的读策略是瞎的 —— 注入抓到过):
        -- 按 postgres 先数出产出批样品的 id,再以读者的身份只读保管记录
        'iv_events_out', pg_temp.f260_get(u_iv, format($q$SELECT to_jsonb(count(*)) FROM sample_events e WHERE e.sample_id = ANY (%L::uuid[])$q$,
                                                       (SELECT array_agg(id) FROM samples WHERE output_batch_id IS NOT NULL))),
        'qv_events', pg_temp.f260_get(u_qv, $q$SELECT to_jsonb(count(*)) FROM sample_events$q$),
        'iv_settings', pg_temp.f260_get(u_iv, $q$SELECT to_jsonb(count(*)) FROM quality_settings$q$),
        'qv_settings', pg_temp.f260_get(u_qv, $q$SELECT to_jsonb(count(*)) FROM quality_settings$q$));
    SELECT count(*) INTO v_n FROM samples;
    IF (v_j #>> '{qv,rows}')::int <> v_n OR (v_j #>> '{qv,in}')::int = 0 OR (v_j #>> '{qv,out}')::int = 0
       OR (v_j #>> '{iv,rows}')::int <> (SELECT count(*) FROM samples WHERE inbound_batch_id IS NOT NULL) OR (v_j #>> '{iv,out}')::int <> 0
       OR (v_j #>> '{ov,rows}')::int <> (SELECT count(*) FROM samples WHERE output_batch_id IS NOT NULL) OR (v_j #>> '{ov,in}')::int <> 0
       OR (v_j #>> '{none,rows}')::int <> 0 OR (v_j ->> 'none_rows_view')::int <> 0 OR (v_j ->> 'iv_events_out')::int <> 0
       OR (v_j ->> 'qv_events')::int <> (SELECT count(*) FROM sample_events)
       OR (v_j ->> 'iv_settings')::int <> 0 OR (v_j ->> 'qv_settings')::int <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 260 READ: quality view sees all, a batch view sees its own kind, nobody else sees any (samples %), got %', v_n, v_j; END IF;
    IF (pg_temp.f260_get(u_iv, $q$SELECT to_jsonb(count(*)) FROM sample_rows WHERE output_batch_id IS NOT NULL$q$))::text::int <> 0
       OR (pg_temp.f260_get(u_iv, $q$SELECT to_jsonb(count(*)) FROM sample_rows$q$))::text::int <> (SELECT count(*) FROM samples WHERE inbound_batch_id IS NOT NULL) THEN
        RAISE EXCEPTION 'FIXTURE 260 READ: sample_rows applies the same predicate as the table'; END IF;

    -- ══════════════ LOG ══════════════
    RAISE NOTICE 'fixture 260 · LOG';
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 8 THEN
        RAISE EXCEPTION 'FIXTURE 260 LOG: change-log coverage (no gaps, 8 excluded), got %', v_j; END IF;
    IF NOT EXISTS (SELECT 1 FROM change_log WHERE table_name = 'samples' AND op = 'INSERT' AND row_key ->> 'id' = s1::text)
       OR NOT EXISTS (SELECT 1 FROM change_log WHERE table_name = 'sample_events' AND op = 'INSERT' AND new ->> 'sample_id' = s1::text)
       OR NOT EXISTS (SELECT 1 FROM change_log WHERE table_name = 'quality_settings' AND op = 'UPDATE' AND new ->> 'internal_retention_days' = '30') THEN
        RAISE EXCEPTION 'FIXTURE 260 LOG: samples, their custody and the V16 change are in the change log'; END IF;
    IF (SELECT count(*) FROM trail_subjects() s WHERE s.subject IN ('sample', 'assay_dispute', 'quality_settings') AND s.view_codes = ARRAY['module.quality.view']) <> 3
       OR NOT EXISTS (SELECT 1 FROM trail_subject_members() m WHERE m.subject = 'sample' AND m.table_name = 'sample_events' AND m.home)
       OR (SELECT count(*) FROM trail_subject_members() m WHERE m.subject IN ('inbound_batch', 'output_batch')
             AND m.table_name IN ('samples', 'sample_events', 'assay_disputes') AND NOT m.home) <> 6 THEN
        RAISE EXCEPTION 'FIXTURE 260 LOG: subjects sample / assay_dispute / quality_settings at the quality view code; custody lives on the sample; batches show samples, custody and disputes'; END IF;
    v_j := pg_temp.f260_get(u_qv, format($q$SELECT jsonb_object_agg(t.table_name, t.n) FROM (SELECT table_name, count(*) AS n FROM record_trail('sample', %L, 500) WHERE table_name IS NOT NULL GROUP BY table_name) t$q$, s1));
    IF (v_j ->> 'samples')::int < 1 OR (v_j ->> 'sample_events')::int < 4 THEN
        RAISE EXCEPTION 'FIXTURE 260 LOG: the sample''s own trail carries the sample and its four custody events, got %', v_j; END IF;
    v_j := pg_temp.f260_get(u_iv, format($q$SELECT jsonb_object_agg(t.table_name, t.n) FROM (SELECT table_name, count(*) AS n FROM record_trail('inbound_batch', %L, 500) WHERE table_name IS NOT NULL GROUP BY table_name) t$q$, ib1));
    IF (v_j ->> 'samples')::int < 2 OR (v_j ->> 'sample_events')::int < 4 THEN
        RAISE EXCEPTION 'FIXTURE 260 LOG: the inbound batch''s trail shows its samples and their custody to a batch viewer, got %', v_j; END IF;

    -- ══════════════ PV ══════════════
    RAISE NOTICE 'fixture 260 · PV';
    PERFORM pg_temp.f260_do(u_qe, 'SELECT set_quality_settings(NULL)');
    -- s1 仍是一份没处置、Not yet set 的样品
    IF (pg_temp.f260_get(u_qv, $q$SELECT to_jsonb(count(*)) FROM pending_values WHERE value_code = 'V16' AND href = '/quality/samples'$q$))::text::int <> 1
       OR (pg_temp.f260_get(u_iv, $q$SELECT to_jsonb(count(*)) FROM pending_values WHERE value_code = 'V16'$q$))::text::int <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 260 PV: V16 is one row for quality view while it is empty and an undated sample is held; not for others'; END IF;
    PERFORM pg_temp.f260_do(u_qe, 'SELECT set_quality_settings(45)');
    IF (pg_temp.f260_get(u_qv, $q$SELECT to_jsonb(count(*)) FROM pending_values WHERE value_code = 'V16'$q$))::text::int <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 260 PV: once V16 is set the row disappears'; END IF;
    PERFORM pg_temp.f260_do(u_qe, 'SELECT set_quality_settings(NULL)');
    -- 两份 Not yet set 的样品(s1 与上一年那一份 s_old)都处置掉
    PERFORM pg_temp.f260_do(u_qe, format($q$SELECT record_sample_event(%L, 'disposed', now(), p_reason => 'done')$q$, s1));
    IF (pg_temp.f260_get(u_qv, $q$SELECT to_jsonb(count(*)) FROM pending_values WHERE value_code = 'V16'$q$))::text::int <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 260 PV: one undated sample (last year''s) is still held — V16 still listed'; END IF;
    PERFORM pg_temp.f260_do(u_qe, format($q$SELECT record_sample_event(%L, 'disposed', now(), p_reason => 'done')$q$, s_old));
    IF (pg_temp.f260_get(u_qv, $q$SELECT to_jsonb(count(*)) FROM pending_values WHERE value_code = 'V16'$q$))::text::int <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 260 PV: with no undated sample still held there is nothing to act on — no row (the V9 precedent)'; END IF;

    RAISE NOTICE 'FIXTURE 260 全部通过: SMP · CUST · RET · ASSAY · EARLY · CODES · READ · LOG · PV';
END $$;

ROLLBACK;
