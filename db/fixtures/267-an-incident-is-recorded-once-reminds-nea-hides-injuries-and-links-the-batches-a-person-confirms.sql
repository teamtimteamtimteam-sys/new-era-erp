-- ═══════════════════════════════════════════════════════════════════════════
-- fixture 267 —— 一件事故记下就不改、向 NEA 提醒、把受伤的细节藏起来,而它碰过的批次由一个人确认
--   (MES-7b-1,2026-10-16;MES-0 Q73 · Q74 · Q76 · Q90 · Q91;MES-7b Step 0 Q2–Q12 · Q17–Q24 · Q27 · Q28,Tim —— Q6 · Q11 · Q12 · Q25 是他自己的话)
-- ═══════════════════════════════════════════════════════════════════════════
-- 臂:
--   REG      两个安全码是 module 码;七种事故种类、没有 other(插一行 other 被 CHECK 拒);单据登记 INC;审计主语与成员;遮蔽规则恰好五条、
--            受伤的五列不在列授权里;六张新表进变更记录,豁免仍是 8 —— MES-9b 起是 9,遮蔽零缺口;V19 = 2、未确认、带出处;F12 备件说明(重建侧)是新说法;
--            不合格报告的来源认得 incident;新视图对 authenticated 只读(属主视图写不穿)
--   GRANT    引导的每一个持 module.processing.view 的角色都持 module.safety.view;持编辑码的都持查看码;data.view_health 不在仓库手里;
--            set_role_permissions 拒只给编辑码不给查看码(EDIT_REQUIRES_VIEW)
--   NUM      INC-年-NNNN,按年无洞(两件连号)
--   REFUSE   没有编辑码拒(PERMISSION_DENIED|module.safety.edit)· 六样必填各自按名拒 · 时刻在未来拒 · 来源 device 拒 · 种类不在清单 / 停用拒 ·
--            受伤的人两个都给拒 · 伤情没有人拒 · 误工天数为负拒 · 时长为负拒;拒了什么都没写
--   DIRECT   会话里直连插入事故 / 更新 / 链接按名拒;改与删事故对谁(连属主)都按名拒;更新只可追加;链接不许删
--   UPDATE   不用通报的事故不收通报;通报要时刻、不在未来、不早于事故、只记一次;关闭要总结;更正:字段只认七个、要理由、新值按字段判、
--            与现在相同拒;更正过的值在 incident_rows 里说了算;关闭之后不收更正
--   KIND     一种被用过之后代号改不了、删不掉(INCIDENT_KIND_CODE_LOCKED);只被一次更正用过也锁;名字照改;没用过的代号照改
--   MASK     一个没有 data.view_health 的编辑记下受伤的细节 → 他读回来是空(injury_visible = false),基表那几列直接读 42501;
--            持 data.view_health 的人读得到;受伤的那名员工本人(没有安全码、没有健康码)读得到自己那一件与它的细节,别人的读不到;
--            审计记录里那几列对编辑是 {"$restricted": true},对持健康码的人是原文
--   LINK     那一刻在事故库位上有货的批被建议(location),那一刻之后才到的不建议;那一刻在那台机器上跑的加工单的投入与产出被建议
--            (machine_run),没跑在那一刻的不建议;确认一条建议;不在建议里的按 location 链拒;按批号挑任何一批(picked);重复链拒;
--            解链接要理由,只解一次;链与解都不碰安全状态与库存流水
--   NCR      持 module.quality.edit 的人对一批链在事故上的货开来源 incident 的报告 → 那一批进质量暂扣;没链上的批拒;来源 incident 不给事故拒;
--            给了事故而来源是 manual 拒
--   CITE     引用另一台机器的停机拒;引用停机而没给机器拒;引用同一台机器的停机照收,而那台机器的可靠性(MTBF)一个数都不变;引用撤回的异常事件拒
--   NEA      要通报的事故:两条提醒都在(只给持安全查看码的人);期限 = 事故日之后第 V19 个工作日(与一份独立数出来的结果相等),标未确认;
--            日历缺一年 → 期限算不出来(cannot_compute),不猜日子;business_days_after 跨周末与公共假期、缺日历返回空;
--            记下通报 → 第一条提醒消失、第二条还在;交了书面报告 → 第二条也消失;更正成不用通报 → 两条都没有
--   V19      待补的值那一行在(未确认);只有查看码的人改不了;确认 → 那一行消失、期限标已确认;改成别的数不确认 → 又回到未确认;
--            空 → not_set;没有数不能确认
--   HANDOVER 交接班引用一件事故 → 引用表一行,交接班页的读者(加工查看码)与事故页的读者(安全查看码)都读得到;引用不存在的事故拒
--   TRAIL    事故的审计记录里有它自己、之后的事实与批次链接;批次的审计记录里看得见链接
--
-- 自带数据(README 第 2 条):公共假期按年自己种、自己停用(README 第 4 条);以 postgres 跑;员工的调用切成 authenticated + JWT(AGENTS.md:RLS 断言必须切角色)。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '300s';

CREATE FUNCTION pg_temp.f267_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims',
                      CASE WHEN p_user IS NULL THEN '' ELSE format('{"sub":"%s","role":"authenticated"}', p_user) END, true)
$f$;

-- 以某人的身份跑一句;返回 'OK' 或那一句的错误(SQLERRM)
CREATE FUNCTION pg_temp.f267_do(p_user uuid, p_sql text) RETURNS text
LANGUAGE plpgsql AS $f$
BEGIN
    PERFORM pg_temp.f267_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql;
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f267_as(NULL);
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f267_as(NULL);
    RETURN SQLERRM;
END;
$f$;

CREATE FUNCTION pg_temp.f267_get(p_user uuid, p_sql text) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v jsonb;
BEGIN
    PERFORM pg_temp.f267_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f267_as(NULL);
    RETURN v;
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f267_as(NULL);
    RAISE;
END;
$f$;

CREATE FUNCTION pg_temp.f267_user(p_label text, p_codes text[]) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE u uuid := gen_random_uuid(); r uuid;
BEGIN
    INSERT INTO auth.users (id, email, email_confirmed_at, created_at) VALUES (u, 'fx267-' || p_label || '@test.local', now(), now());
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx267-' || p_label, 'f', 'f', true) RETURNING id INTO r;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r, c FROM unnest(p_codes) c;
    INSERT INTO user_roles (user_id, role_id) VALUES (u, r);
    RETURN u;
END;
$f$;

CREATE FUNCTION pg_temp.f267_expect(p_arm text, p_got text, p_like text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
    IF p_got IS NULL OR p_got NOT LIKE p_like THEN
        RAISE EXCEPTION 'FIXTURE 267 % expected % got %', p_arm, p_like, COALESCE(p_got, '<null>');
    END IF;
END;
$f$;

-- 动钱之后:应付 / 应收清单 = 总账,存货控制科目对得上(以持 module.finance.view 的人读)
CREATE FUNCTION pg_temp.f267_recon(p_user uuid, p_step text) RETURNS void
LANGUAGE plpgsql AS $f$
DECLARE v jsonb; s jsonb;
BEGIN
    v := pg_temp.f267_get(p_user, 'SELECT list_ledger_reconciliation()');
    FOR s IN SELECT * FROM jsonb_array_elements(v -> 'sides') LOOP
        IF (s ->> 'unexplained_base')::numeric <> 0 THEN
            RAISE EXCEPTION 'FIXTURE 267 RECON % % list ≠ ledger: %', p_step, s ->> 'side', s;
        END IF;
    END LOOP;
    v := pg_temp.f267_get(p_user, 'SELECT gl_control_reconciliation(CURRENT_DATE)');
    SELECT x INTO s FROM jsonb_array_elements(v -> 'sides') x WHERE x ->> 'side' = 'inventory_raw';
    IF s IS NULL OR (s ->> 'unexplained_base')::numeric <> 0 OR NOT (s ->> 'reconciled')::boolean THEN
        RAISE EXCEPTION 'FIXTURE 267 RECON % inventory control 1200 not reconciled: %', p_step, s;
    END IF;
END;
$f$;

-- 一张已提交的加工单,在一台机器上从 p_from 跑到 p_to(属主路径直插:血缘与产出腿,不动库存 —— fixture 264 的先例)
CREATE FUNCTION pg_temp.f267_run(p_code text, p_machine uuid, p_from timestamptz, p_to timestamptz, p_input uuid, p_output uuid) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v_run uuid;
BEGIN
    INSERT INTO processing_runs (code, status, allocation_basis, process_date, operation_type_code, equipment_id, started_at, ended_at, shift_code)
    VALUES (p_code, 'committed', 'weight', (p_from AT TIME ZONE 'Asia/Singapore')::date, 'manual_disassembly', p_machine, p_from, p_to, 'day')
    RETURNING id INTO v_run;
    PERFORM set_config('evoltrya.movement_ctx', 'processing:' || v_run, true);
    INSERT INTO processing_inputs (run_id, inbound_batch_id, quantity_consumed) VALUES (v_run, p_input, 10);
    PERFORM set_config('evoltrya.movement_ctx', '', true);
    INSERT INTO processing_outputs (run_id, output_batch_id, quantity_produced) VALUES (v_run, p_output, 10);
    RETURN v_run;
END;
$f$;

-- 一份独立数出来的"第 n 个工作日"(不调 business_days_after、不调 is_business_day):周一到周五,且不是一天启用的新加坡假期
CREATE FUNCTION pg_temp.f267_nth_workday(p_date date, p_n int) RETURNS date
LANGUAGE sql AS $f$
    SELECT d::date FROM (
        SELECT d, row_number() OVER (ORDER BY d) AS k
          FROM generate_series(p_date + 1, p_date + 60, interval '1 day') d
         WHERE extract(isodow FROM d) < 6
           AND NOT EXISTS (SELECT 1 FROM public_holidays h WHERE h.holiday_date = d::date AND h.country = 'SG' AND h.is_active)) x
     WHERE k = p_n
$f$;

DO $$
DECLARE
    u_all uuid; u_ed uuid; u_hl uuid; u_vw uuid; u_none uuid; u_inj uuid; u_qe uuid; u_ho uuid;
    e_inj uuid := gen_random_uuid(); e_resp uuid := gen_random_uuid(); e_out uuid := gen_random_uuid(); e_in uuid := gen_random_uuid();
    v_base text;
    v_today date := (now() AT TIME ZONE 'Asia/Singapore')::date;
    t_m timestamptz := now() - interval '2 hours';
    d date;
    v_sup uuid; v_bm uuid; v_out_mat uuid; fa uuid; fa2 uuid; loc uuid; loc2 uuid;
    ib_l uuid; ib_l2 uuid; ib_late uuid; ib_m uuid; ib_free uuid; ob_m uuid; ob_x uuid; run_m uuid; run_x uuid;
    dt_m uuid; dt_x uuid; ev_w bigint;
    i_inj uuid; i_rep uuid; i_loc uuid; i_mach uuid; i_cite uuid; i_nr uuid; i_kind uuid;
    v_j jsonb; v_msg text; v_n bigint; v_n2 bigint; v_txt text; v_d date; v_d2 date; v_code1 text; v_code2 text;
    v_ss_before text; v_mv_before text; v_rel_before text; v_rel_after text; v_link bigint; v_link2 bigint; v_ho uuid;
    v_y int; v_fri date;
BEGIN
    SELECT code INTO v_base FROM currencies WHERE is_base;
    PERFORM pg_temp.f267_as(NULL);
    UPDATE finance_settings SET locked_before = NULL;
    d := v_today - 5;

    -- ══════════════ REG ══════════════
    RAISE NOTICE 'fixture 267 · REG';
    IF (SELECT string_agg(code || ':' || category, ',' ORDER BY code) FROM permissions WHERE code LIKE 'module.safety.%')
         IS DISTINCT FROM 'module.safety.edit:module,module.safety.view:module' THEN
        RAISE EXCEPTION 'FIXTURE 267 REG: module.safety.view / .edit must exist as module codes'; END IF;
    IF (SELECT string_agg(code, ',' ORDER BY sort_order) FROM incident_kinds)
         IS DISTINCT FROM 'thermal_runaway,fire_smoke,gas_release,dust_concentration,injury,near_miss,emission_exceedance' THEN
        RAISE EXCEPTION 'FIXTURE 267 REG: the seven incident kinds (Q4), got %', (SELECT string_agg(code, ',' ORDER BY sort_order) FROM incident_kinds); END IF;
    BEGIN
        INSERT INTO incident_kinds (code, name_en, name_zh) VALUES ('other', 'Other', '其它');
        RAISE EXCEPTION 'FIXTURE 267 REG: a kind called other must be refused (no catch-all)';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    IF document_type_prefix('incident') <> 'INC' OR (SELECT route FROM document_types WHERE key = 'incident') <> '/safety/incidents'
       OR (SELECT view_permission FROM document_types WHERE key = 'incident') <> ARRAY['module.safety.view'] THEN
        RAISE EXCEPTION 'FIXTURE 267 REG: document type INC'; END IF;
    IF NOT EXISTS (SELECT 1 FROM trail_subjects() s WHERE s.subject = 'incident' AND s.root_table = 'incidents' AND s.view_codes = ARRAY['module.safety.view'])
       OR NOT EXISTS (SELECT 1 FROM trail_subjects() s WHERE s.subject = 'safety_settings')
       OR NOT EXISTS (SELECT 1 FROM trail_subjects() s WHERE s.subject = 'dictionary_incident_kinds')
       OR (SELECT count(*) FROM trail_subject_members() m WHERE m.subject = 'incident') <> 4
       OR NOT EXISTS (SELECT 1 FROM trail_subject_members() m WHERE m.subject = 'shift_handover' AND m.table_name = 'shift_handover_incident_refs' AND m.home)
       OR NOT EXISTS (SELECT 1 FROM trail_subject_members() m WHERE m.subject = 'inbound_batch' AND m.table_name = 'incident_batches' AND NOT m.home)
       OR NOT EXISTS (SELECT 1 FROM trail_subject_members() m WHERE m.subject = 'output_batch' AND m.table_name = 'incident_batches' AND NOT m.home) THEN
        RAISE EXCEPTION 'FIXTURE 267 REG: trail subjects incident / safety_settings / dictionary_incident_kinds and their members'; END IF;
    IF (SELECT string_agg(column_name || '=' || rule, ',' ORDER BY column_name) FROM change_log_mask_rules() WHERE table_name = 'incidents')
         IS DISTINCT FROM 'days_lost=code_or_self:data.view_health:injured_employee_id,injured_employee_id=code_or_self:data.view_health:injured_employee_id,injured_person_name=code_or_self:data.view_health:injured_employee_id,injury_nature=code_or_self:data.view_health:injured_employee_id,injury_treatment=code_or_self:data.view_health:injured_employee_id' THEN
        RAISE EXCEPTION 'FIXTURE 267 REG: exactly the five injury columns are masked (Q6)'; END IF;
    SELECT string_agg(c, ',') INTO v_txt FROM unnest(ARRAY['injured_employee_id', 'injured_person_name', 'injury_nature', 'injury_treatment', 'days_lost']) c
     WHERE has_column_privilege('authenticated', 'public.incidents'::regclass, c, 'SELECT');
    IF v_txt IS NOT NULL OR NOT has_column_privilege('authenticated', 'public.incidents'::regclass, 'what_happened', 'SELECT') THEN
        RAISE EXCEPTION 'FIXTURE 267 REG: the injury columns must be out of the column grant (got %) and the rest in it', v_txt; END IF;
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 10 THEN
        RAISE EXCEPTION 'FIXTURE 267 REG: change-log coverage (gaps 0, exclusions 9): %', v_j; END IF;
    IF EXISTS (SELECT 1 FROM unnest(ARRAY['incident_kinds', 'safety_settings', 'incidents', 'incident_updates', 'incident_batches',
                                          'shift_handover_incident_refs']) t
                WHERE NOT EXISTS (SELECT 1 FROM pg_trigger g WHERE g.tgname = 'zzz_change_log' AND g.tgrelid = ('public.' || t)::regclass)) THEN
        RAISE EXCEPTION 'FIXTURE 267 REG: every new table is change-logged'; END IF;
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 267 REG: mask gaps %', v_j -> 'gaps'; END IF;
    IF (SELECT nea_report_working_days FROM safety_settings) IS DISTINCT FROM 2
       OR (SELECT nea_report_days_confirmed_at FROM safety_settings) IS NOT NULL
       OR (SELECT nea_report_days_source FROM safety_settings) NOT LIKE '%docs/forward-queue.md:2402%' THEN
        RAISE EXCEPTION 'FIXTURE 267 REG: V19 is stored as 2 working days, unconfirmed, with its source (Q11)'; END IF;
    v_txt := (SELECT notes FROM material_kinds WHERE code = 'spare_part');
    IF v_txt NOT LIKE '%received as lots so stock and cost are counted%' OR v_txt NOT LIKE '%issued against a maintenance record%'
       OR v_txt NOT LIKE '%no per-piece traceability%' OR v_txt LIKE '%【不按批次追溯】%' THEN
        RAISE EXCEPTION 'FIXTURE 267 REG: the spare_part note (F12) is the new sentence: %', v_txt; END IF;
    IF pg_get_constraintdef((SELECT oid FROM pg_constraint WHERE conname = 'nonconformance_reports_source_check')) NOT LIKE '%''incident''%' THEN
        RAISE EXCEPTION 'FIXTURE 267 REG: the NCR source list knows incident'; END IF;
    IF EXISTS (SELECT 1 FROM unnest(ARRAY['incidents_masked', 'incident_rows', 'incident_batch_rows', 'incident_people']) v
                WHERE has_table_privilege('authenticated', ('public.' || v)::regclass, 'INSERT')
                   OR has_table_privilege('authenticated', ('public.' || v)::regclass, 'UPDATE')
                   OR has_table_privilege('authenticated', ('public.' || v)::regclass, 'DELETE')
                   OR NOT has_table_privilege('authenticated', ('public.' || v)::regclass, 'SELECT'))
       OR has_table_privilege('authenticated', 'public.incident_current_all'::regclass, 'SELECT') THEN
        RAISE EXCEPTION 'FIXTURE 267 REG: the new views are read-only to staff (an owner-rights view must not be writable through), the base view unreadable'; END IF;

    -- ══════════════ GRANT(引导)══════════════
    RAISE NOTICE 'fixture 267 · GRANT';
    SELECT string_agg(r.code, ',' ORDER BY r.code) INTO v_txt FROM roles r
     WHERE EXISTS (SELECT 1 FROM role_permissions rp WHERE rp.role_id = r.id AND rp.permission_code = 'module.processing.view')
       AND NOT EXISTS (SELECT 1 FROM role_permissions rp WHERE rp.role_id = r.id AND rp.permission_code = 'module.safety.view');
    IF v_txt IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 267 GRANT: every role holding module.processing.view holds module.safety.view (Q2); missing: %', v_txt; END IF;
    IF EXISTS (SELECT 1 FROM role_permissions rp WHERE rp.permission_code = 'module.safety.edit'
                  AND NOT EXISTS (SELECT 1 FROM role_permissions v WHERE v.role_id = rp.role_id AND v.permission_code = 'module.safety.view')) THEN
        RAISE EXCEPTION 'FIXTURE 267 GRANT: edit implies view'; END IF;
    IF (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         WHERE rp.permission_code = 'module.safety.edit' AND r.code NOT LIKE 'fx%') IS DISTINCT FROM 'admin,cto,warehouse' THEN
        RAISE EXCEPTION 'FIXTURE 267 GRANT: the bootstrap gives module.safety.edit to admin, cto and warehouse (GOLIVE-1 Q5: the bootstrap is live''s eleven roles)'; END IF;
    IF EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE r.code = 'warehouse' AND rp.permission_code = 'data.view_health') THEN
        RAISE EXCEPTION 'FIXTURE 267 GRANT: warehouse must not hold data.view_health (Q6)'; END IF;
    u_all := pg_temp.f267_user('all', ARRAY(SELECT code FROM permissions));
    DECLARE r_t uuid;
    BEGIN
        INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx267-edit-only', 'f', 'f', true) RETURNING id INTO r_t;
        v_msg := pg_temp.f267_do(u_all, format($q$SELECT set_role_permissions(%L::uuid, ARRAY['module.safety.edit'])$q$, r_t));
        PERFORM pg_temp.f267_expect('GRANT edit without view', v_msg, 'EDIT_REQUIRES_VIEW|safety');
        v_msg := pg_temp.f267_do(u_all, format($q$SELECT set_role_permissions(%L::uuid, ARRAY['module.safety.edit', 'module.safety.view'])$q$, r_t));
        PERFORM pg_temp.f267_expect('GRANT edit with view', v_msg, 'OK');
    END;

    -- ══════════════ 布景 ══════════════
    u_ed   := pg_temp.f267_user('ed', ARRAY['module.safety.view', 'module.safety.edit', 'module.inbound.view', 'module.output.view']);
    u_hl   := pg_temp.f267_user('hl', ARRAY['module.safety.view', 'data.view_health']);
    u_vw   := pg_temp.f267_user('vw', ARRAY['module.safety.view']);
    u_none := pg_temp.f267_user('none', ARRAY['module.processing.view']);
    u_inj  := pg_temp.f267_user('inj', ARRAY['module.tasks.view']);
    u_qe   := pg_temp.f267_user('qe', ARRAY['module.quality.view', 'module.quality.edit', 'module.inbound.view', 'module.output.view', 'module.safety.view']);
    u_ho   := pg_temp.f267_user('ho', ARRAY['module.processing.view', 'module.processing.edit']);
    PERFORM pg_temp.f267_user('qd', ARRAY['action.ncr_decide', 'module.quality.view', 'module.inbound.view', 'module.output.view']);
    INSERT INTO employees (id, code, legal_name, preferred_name, employment_type, work_category, hire_date, user_id) VALUES
        (e_inj, 'FX267-E1', 'f267 injured worker', 'Ah Hurt', 'full_time', 'shopfloor', DATE '2020-01-01', u_inj),
        (e_resp, 'FX267-E2', 'f267 shift lead', 'Lead', 'full_time', 'shopfloor', DATE '2020-01-01', NULL),
        (e_out, 'FX267-E3', 'f267 outgoing', 'Out', 'full_time', 'shopfloor', DATE '2020-01-01', NULL),
        (e_in, 'FX267-E4', 'f267 incoming', 'In', 'full_time', 'shopfloor', DATE '2020-01-01', NULL);

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ267-S', 'f267 cells vendor', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, unit)
    VALUES ('ZZ267-BM', 'f267 modules', 'battery_material', true, 'black_mass', 'end_of_life', 'kg') RETURNING id INTO v_bm;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, unit)
    VALUES ('ZZ267-OUT', 'f267 output', 'battery_material', true, 'black_mass', 'end_of_life', 'kg') RETURNING id INTO v_out_mat;
    INSERT INTO fixed_assets (code, description, category, acquisition_date, cost_ccy, currency, fx_rate, cost_base, useful_life_months, residual_base)
    VALUES ('FX267-M', 'fixture 267 shredder', 'equipment', d - 50, 0, v_base, 1, 0, 60, 0) RETURNING id INTO fa;
    INSERT INTO fixed_assets (code, description, category, acquisition_date, cost_ccy, currency, fx_rate, cost_base, useful_life_months, residual_base)
    VALUES ('FX267-M2', 'fixture 267 other machine', 'equipment', d - 50, 0, v_base, 1, 0, 60, 0) RETURNING id INTO fa2;
    INSERT INTO storage_locations (code, name, is_active) VALUES ('ZZ267-L1', 'f267 discharge bay', true) RETURNING id INTO loc;
    INSERT INTO storage_locations (code, name, is_active) VALUES ('ZZ267-L2', 'f267 other bay', true) RETURNING id INTO loc2;

    PERFORM pg_temp.f267_as(u_all);
    ib_l := (create_inbound_batch(v_bm, v_sup, 100, 'kg', d, '待加工', p_unit_price => 1, p_currency => v_base, p_location_id => loc,
                                  p_safety_states => ARRAY['discharged_verified'],
                                  p_source_reason_code => 'other', p_source_reason_note => 'fixture 267 at the bay') ->> 'batch_id')::uuid;
    ib_l2 := (create_inbound_batch(v_bm, v_sup, 50, 'kg', d, '待加工', p_unit_price => 1, p_currency => v_base, p_location_id => loc2,
                                   p_safety_states => ARRAY['discharged_verified'],
                                   p_source_reason_code => 'other', p_source_reason_note => 'fixture 267 other bay') ->> 'batch_id')::uuid;
    ib_m := (create_inbound_batch(v_bm, v_sup, 40, 'kg', d, '待加工', p_unit_price => 1, p_currency => v_base,
                                  p_safety_states => ARRAY['discharged_verified'],
                                  p_source_reason_code => 'other', p_source_reason_note => 'fixture 267 fed to the machine') ->> 'batch_id')::uuid;
    ib_free := (create_inbound_batch(v_bm, v_sup, 30, 'kg', d, '待加工', p_unit_price => 1, p_currency => v_base,
                                     p_safety_states => ARRAY['discharged_verified'],
                                     p_source_reason_code => 'other', p_source_reason_note => 'fixture 267 picked by code') ->> 'batch_id')::uuid;
    ob_m := (create_output_batch(v_out_mat, 10, 'kg', d) ->> 'batch_id')::uuid;
    ob_x := (create_output_batch(v_out_mat, 10, 'kg', d) ->> 'batch_id')::uuid;
    PERFORM pg_temp.f267_as(NULL);
    PERFORM pg_temp.f267_recon(u_all, 'after the receipts');
    -- 一张在 t_m 那一刻在 FX267-M 上跑的单(t_m − 1h → t_m + 1h),一张更早、不包含 t_m 的单(投入 ib_free、产出 ob_x)
    run_m := pg_temp.f267_run('ZZ267-RUN-1', fa, t_m - interval '1 hour', t_m + interval '1 hour', ib_m, ob_m);
    run_x := pg_temp.f267_run('ZZ267-RUN-2', fa, t_m - interval '5 hours', t_m - interval '3 hours', ib_free, ob_x);
    INSERT INTO equipment_downtime (equipment_id, started_at, ended_at, reason, cause_code, source)
    VALUES (fa, t_m - interval '10 minutes', t_m + interval '20 minutes', 'f267 stop after the smoke', 'breakdown', 'manual') RETURNING id INTO dt_m;
    INSERT INTO equipment_downtime (equipment_id, started_at, ended_at, reason, cause_code, source)
    VALUES (fa2, t_m - interval '10 minutes', t_m + interval '20 minutes', 'f267 stop on the other machine', 'breakdown', 'manual') RETURNING id INTO dt_x;
    -- 一条安全报警事件,随后被撤回(撤回是另一行,corrects_id 指回它)
    INSERT INTO processing_run_events (run_id, event_type_code, occurred_at, action_taken, responsible_person)
    VALUES (run_m, 'safety_alarm', t_m, 'f267 alarm', 'Lead') RETURNING id INTO ev_w;
    INSERT INTO processing_run_events (run_id, event_type_code, occurred_at, action_taken, responsible_person, withdrawn, corrects_id, correction_reason)
    VALUES (run_m, 'safety_alarm', t_m, 'f267 alarm', 'Lead', true, ev_w, 'false alarm');

    -- ══════════════ REFUSE ══════════════
    RAISE NOTICE 'fixture 267 · REFUSE';
    SELECT count(*) INTO v_n FROM incidents;
    v_msg := pg_temp.f267_do(u_vw, format($q$SELECT record_incident('fire_smoke', %L, 'x', 'y', false, p_responsible_name => 'Lead')$q$, t_m));
    PERFORM pg_temp.f267_expect('REFUSE no edit code', v_msg, 'PERMISSION_DENIED|module.safety.edit');
    v_msg := pg_temp.f267_do(u_ed, format($q$SELECT record_incident(NULL, %L, 'x', 'y', false, p_responsible_name => 'Lead')$q$, t_m));
    PERFORM pg_temp.f267_expect('REFUSE kind', v_msg, 'INCIDENT_KIND_REQUIRED');
    v_msg := pg_temp.f267_do(u_ed, $q$SELECT record_incident('fire_smoke', NULL, 'x', 'y', false, p_responsible_name => 'Lead')$q$);
    PERFORM pg_temp.f267_expect('REFUSE time', v_msg, 'INCIDENT_TIME_REQUIRED');
    v_msg := pg_temp.f267_do(u_ed, format($q$SELECT record_incident('fire_smoke', %L, '  ', 'y', false, p_responsible_name => 'Lead')$q$, t_m));
    PERFORM pg_temp.f267_expect('REFUSE what happened', v_msg, 'INCIDENT_WHAT_REQUIRED');
    v_msg := pg_temp.f267_do(u_ed, format($q$SELECT record_incident('fire_smoke', %L, 'x', NULL, false, p_responsible_name => 'Lead')$q$, t_m));
    PERFORM pg_temp.f267_expect('REFUSE immediate action', v_msg, 'INCIDENT_ACTION_REQUIRED');
    v_msg := pg_temp.f267_do(u_ed, format($q$SELECT record_incident('fire_smoke', %L, 'x', 'y', false, p_responsible_name => ' ')$q$, t_m));
    PERFORM pg_temp.f267_expect('REFUSE responsible', v_msg, 'INCIDENT_RESPONSIBLE_REQUIRED');
    v_msg := pg_temp.f267_do(u_ed, format($q$SELECT record_incident('fire_smoke', %L, 'x', 'y', NULL, p_responsible_name => 'Lead')$q$, t_m));
    PERFORM pg_temp.f267_expect('REFUSE NEA-reportable unanswered', v_msg, 'INCIDENT_NEA_REPORTABLE_REQUIRED');
    v_msg := pg_temp.f267_do(u_ed, format($q$SELECT record_incident('fire_smoke', %L, 'x', 'y', false, p_responsible_name => 'Lead')$q$, now() + interval '1 hour'));
    PERFORM pg_temp.f267_expect('REFUSE future time', v_msg, 'INCIDENT_TIME_IN_FUTURE|%');
    v_msg := pg_temp.f267_do(u_ed, format($q$SELECT record_incident('fire_smoke', %L, 'x', 'y', false, p_responsible_name => 'Lead', p_source => 'device')$q$, t_m));
    PERFORM pg_temp.f267_expect('REFUSE device source', v_msg, 'INCIDENT_SOURCE_RESERVED|device');
    v_msg := pg_temp.f267_do(u_ed, format($q$SELECT record_incident('lightning', %L, 'x', 'y', false, p_responsible_name => 'Lead')$q$, t_m));
    PERFORM pg_temp.f267_expect('REFUSE unknown kind', v_msg, 'INCIDENT_KIND_UNKNOWN|lightning');
    UPDATE incident_kinds SET is_active = false WHERE code = 'gas_release';
    v_msg := pg_temp.f267_do(u_ed, format($q$SELECT record_incident('gas_release', %L, 'x', 'y', false, p_responsible_name => 'Lead')$q$, t_m));
    PERFORM pg_temp.f267_expect('REFUSE inactive kind', v_msg, 'INCIDENT_KIND_INACTIVE|gas_release');
    UPDATE incident_kinds SET is_active = true WHERE code = 'gas_release';
    v_msg := pg_temp.f267_do(u_ed, format($q$SELECT record_incident('injury', %L, 'x', 'y', true, p_responsible_name => 'Lead', p_injured_employee_id => %L, p_injured_person_name => 'Visitor')$q$, t_m, e_inj));
    PERFORM pg_temp.f267_expect('REFUSE two injured people', v_msg, 'INCIDENT_INJURED_ONE_PERSON');
    v_msg := pg_temp.f267_do(u_ed, format($q$SELECT record_incident('injury', %L, 'x', 'y', true, p_responsible_name => 'Lead', p_injury_nature => 'burn')$q$, t_m));
    PERFORM pg_temp.f267_expect('REFUSE injury without a person', v_msg, 'INCIDENT_INJURY_NEEDS_PERSON');
    v_msg := pg_temp.f267_do(u_ed, format($q$SELECT record_incident('injury', %L, 'x', 'y', true, p_responsible_name => 'Lead', p_injured_person_name => 'Visitor', p_days_lost => -1)$q$, t_m));
    PERFORM pg_temp.f267_expect('REFUSE negative days lost', v_msg, 'INCIDENT_DAYS_LOST_INVALID');
    v_msg := pg_temp.f267_do(u_ed, format($q$SELECT record_incident('fire_smoke', %L, 'x', 'y', false, p_responsible_name => 'Lead', p_duration_min => -5)$q$, t_m));
    PERFORM pg_temp.f267_expect('REFUSE negative duration', v_msg, 'INCIDENT_DURATION_INVALID');
    IF (SELECT count(*) FROM incidents) <> v_n THEN
        RAISE EXCEPTION 'FIXTURE 267 REFUSE: a refused record wrote a row'; END IF;

    -- ══════════════ NUM + MASK ══════════════
    RAISE NOTICE 'fixture 267 · NUM · MASK';
    v_j := pg_temp.f267_get(u_ed, format($q$SELECT record_incident('injury', %L, 'A cell vented during discharge and burned a hand', 'First aid; area cleared', true,
               p_responsible_employee_id => %L, p_location_id => %L, p_injured_employee_id => %L, p_injury_nature => 'Burn to the left hand',
               p_injury_treatment => 'Hospital outpatient', p_days_lost => 2)$q$, t_m, e_resp, loc, e_inj));
    i_inj := (v_j ->> 'incident_id')::uuid; v_code1 := v_j ->> 'code';
    v_j := pg_temp.f267_get(u_ed, format($q$SELECT record_incident('near_miss', %L, 'A pallet nearly fell', 'Re-stacked', false, p_responsible_name => 'Lead')$q$, t_m));
    i_nr := (v_j ->> 'incident_id')::uuid; v_code2 := v_j ->> 'code';
    IF v_code1 !~ ('^INC-' || extract(year FROM CURRENT_DATE)::int || '-[0-9]{4,}$')
       OR split_part(v_code2, '-', 3)::int <> split_part(v_code1, '-', 3)::int + 1 THEN
        RAISE EXCEPTION 'FIXTURE 267 NUM: INC-YYYY-NNNN, gapless (% then %)', v_code1, v_code2; END IF;
    -- 记下它的编辑没有健康码:读回来受伤的细节是空,injury_visible 为假;基表那几列直接读是 42501
    v_j := pg_temp.f267_get(u_ed, format($q$SELECT to_jsonb(r) FROM incident_rows r WHERE r.id = %L$q$, i_inj));
    IF v_j IS NULL OR (v_j ->> 'injury_visible')::boolean OR v_j ->> 'injury_nature' IS NOT NULL OR v_j ->> 'injured_employee_id' IS NOT NULL
       OR v_j ->> 'days_lost' IS NOT NULL OR v_j ->> 'what_happened' <> 'A cell vented during discharge and burned a hand' THEN
        RAISE EXCEPTION 'FIXTURE 267 MASK: the recorder without data.view_health sees the incident but not the injury: %', v_j; END IF;
    v_msg := pg_temp.f267_do(u_ed, format($q$SELECT injury_nature FROM incidents WHERE id = %L$q$, i_inj));
    PERFORM pg_temp.f267_expect('MASK base column', v_msg, 'permission denied%');
    -- 持健康码的人读得到
    v_j := pg_temp.f267_get(u_hl, format($q$SELECT to_jsonb(r) FROM incident_rows r WHERE r.id = %L$q$, i_inj));
    IF NOT (v_j ->> 'injury_visible')::boolean OR v_j ->> 'injury_nature' <> 'Burn to the left hand' OR (v_j ->> 'days_lost')::numeric <> 2
       OR (v_j ->> 'injured_employee_id')::uuid <> e_inj OR v_j ->> 'injured_employee_label' NOT LIKE 'FX267-E1%' THEN
        RAISE EXCEPTION 'FIXTURE 267 MASK: a data.view_health holder reads the injury: %', v_j; END IF;
    -- 受伤的那名员工本人:没有安全码、没有健康码,读得到自己那一件与它的细节;别人的那一件读不到
    v_j := pg_temp.f267_get(u_inj, format($q$SELECT to_jsonb(r) FROM incidents_masked r WHERE r.id = %L$q$, i_inj));
    IF v_j IS NULL OR v_j ->> 'injury_nature' <> 'Burn to the left hand' OR v_j ->> 'injury_treatment' <> 'Hospital outpatient' THEN
        RAISE EXCEPTION 'FIXTURE 267 MASK: the injured employee reads their own details: %', v_j; END IF;
    v_j := pg_temp.f267_get(u_inj, format($q$SELECT to_jsonb(r) FROM incident_rows r WHERE r.id = %L$q$, i_inj));
    IF v_j IS NULL OR NOT (v_j ->> 'injury_visible')::boolean THEN
        RAISE EXCEPTION 'FIXTURE 267 MASK: the injured employee reads their own incident row with the injury visible: %', v_j; END IF;
    v_n := pg_temp.f267_get(u_inj, format($q$SELECT to_jsonb(count(*)) FROM incidents_masked WHERE id = %L$q$, i_nr))::bigint;
    IF v_n <> 0 THEN RAISE EXCEPTION 'FIXTURE 267 MASK: the injured employee must not read someone else''s incident'; END IF;
    v_n := pg_temp.f267_get(u_none, $q$SELECT to_jsonb(count(*)) FROM incident_rows$q$)::bigint;
    IF v_n <> 0 THEN RAISE EXCEPTION 'FIXTURE 267 MASK: a reader without module.safety.view reads no incident'; END IF;
    -- 审计记录:那几列对编辑是「受限」,对持健康码的人是原文
    v_j := pg_temp.f267_get(u_ed, format($q$SELECT t.new FROM record_trail('incident', %L) t WHERE t.table_name = 'incidents' AND t.op = 'INSERT'$q$, i_inj));
    IF v_j -> 'injury_nature' IS DISTINCT FROM '{"$restricted": true}'::jsonb OR v_j -> 'injured_employee_id' IS DISTINCT FROM '{"$restricted": true}'::jsonb
       OR v_j ->> 'what_happened' IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 267 MASK: the trail restricts the injury columns for a reader without data.view_health: %', v_j; END IF;
    v_j := pg_temp.f267_get(u_hl, format($q$SELECT t.new FROM record_trail('incident', %L) t WHERE t.table_name = 'incidents' AND t.op = 'INSERT'$q$, i_inj));
    IF v_j ->> 'injury_nature' IS DISTINCT FROM 'Burn to the left hand' THEN
        RAISE EXCEPTION 'FIXTURE 267 MASK: the trail shows the injury to a data.view_health holder: %', v_j; END IF;

    -- ══════════════ DIRECT ══════════════
    RAISE NOTICE 'fixture 267 · DIRECT';
    v_msg := pg_temp.f267_do(u_ed, format($q$INSERT INTO incidents (code, kind_code, occurred_at, what_happened, immediate_action, responsible_name, nea_reportable) VALUES ('INC-X', 'fire_smoke', %L, 'x', 'y', 'z', false)$q$, t_m));
    PERFORM pg_temp.f267_expect('DIRECT insert', v_msg, 'INCIDENT_THROUGH_FUNCTION_ONLY');
    v_msg := pg_temp.f267_do(u_ed, format($q$UPDATE incidents SET what_happened = 'rewritten' WHERE id = %L$q$, i_nr));
    PERFORM pg_temp.f267_expect('DIRECT update (staff)', v_msg, 'INCIDENT_IMMUTABLE|update');
    BEGIN
        UPDATE incidents SET what_happened = 'rewritten by the owner' WHERE id = i_nr;
        RAISE EXCEPTION 'FIXTURE 267 DIRECT: the owner path must not rewrite an incident';
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.f267_expect('DIRECT update (owner)', SQLERRM, 'INCIDENT_IMMUTABLE|update');
    END;
    v_msg := pg_temp.f267_do(u_ed, format($q$DELETE FROM incidents WHERE id = %L$q$, i_nr));
    PERFORM pg_temp.f267_expect('DIRECT delete', v_msg, 'INCIDENT_IMMUTABLE|delete');
    v_msg := pg_temp.f267_do(u_ed, format($q$INSERT INTO incident_updates (incident_id, kind, summary) VALUES (%L, 'closed', 'sneaky')$q$, i_nr));
    PERFORM pg_temp.f267_expect('DIRECT update row insert', v_msg, 'INCIDENT_UPDATE_THROUGH_FUNCTION_ONLY');
    v_msg := pg_temp.f267_do(u_ed, format($q$INSERT INTO incident_batches (incident_id, inbound_batch_id, basis) VALUES (%L, %L, 'picked')$q$, i_nr, ib_free));
    PERFORM pg_temp.f267_expect('DIRECT link insert', v_msg, 'INCIDENT_LINK_THROUGH_FUNCTION_ONLY');
    v_msg := pg_temp.f267_do(u_ed, $q$UPDATE incident_batches SET unlink_reason = 'x'$q$);
    PERFORM pg_temp.f267_expect('DIRECT link update (no row visible)', v_msg, 'INCIDENT_LINK_THROUGH_FUNCTION_ONLY');

    -- ══════════════ UPDATE ══════════════
    RAISE NOTICE 'fixture 267 · UPDATE';
    v_msg := pg_temp.f267_do(u_ed, format($q$SELECT record_incident_update(%L, 'nea_notified', %L)$q$, i_nr, now()));
    PERFORM pg_temp.f267_expect('UPDATE notify a non-reportable incident', v_msg, 'INCIDENT_NOT_NEA_REPORTABLE|' || v_code2);
    v_msg := pg_temp.f267_do(u_ed, format($q$SELECT record_incident_update(%L, 'nea_notified')$q$, i_inj));
    PERFORM pg_temp.f267_expect('UPDATE notify needs a time', v_msg, 'INCIDENT_UPDATE_TIME_REQUIRED');
    v_msg := pg_temp.f267_do(u_ed, format($q$SELECT record_incident_update(%L, 'nea_notified', %L)$q$, i_inj, now() + interval '1 hour'));
    PERFORM pg_temp.f267_expect('UPDATE notify in the future', v_msg, 'INCIDENT_UPDATE_TIME_IN_FUTURE');
    v_msg := pg_temp.f267_do(u_ed, format($q$SELECT record_incident_update(%L, 'nea_notified', %L)$q$, i_inj, t_m - interval '1 day'));
    PERFORM pg_temp.f267_expect('UPDATE notify before the incident', v_msg, 'INCIDENT_UPDATE_BEFORE_INCIDENT|%');
    v_msg := pg_temp.f267_do(u_vw, format($q$SELECT record_incident_update(%L, 'closed', p_summary => 'x')$q$, i_nr));
    PERFORM pg_temp.f267_expect('UPDATE needs the edit code', v_msg, 'PERMISSION_DENIED|module.safety.edit');
    v_msg := pg_temp.f267_do(u_ed, format($q$SELECT record_incident_update(%L, 'closed', p_summary => '  ')$q$, i_nr));
    PERFORM pg_temp.f267_expect('UPDATE close needs a summary', v_msg, 'INCIDENT_CLOSE_SUMMARY_REQUIRED');
    v_msg := pg_temp.f267_do(u_ed, format($q$SELECT record_incident_update(%L, 'correction', p_field => 'injury_nature', p_new_value => 'x', p_reason => 'r')$q$, i_nr));
    PERFORM pg_temp.f267_expect('UPDATE correction field', v_msg, 'INCIDENT_CORRECTION_FIELD_INVALID|injury_nature');
    v_msg := pg_temp.f267_do(u_ed, format($q$SELECT record_incident_update(%L, 'correction', p_field => 'what_happened', p_new_value => 'x')$q$, i_nr));
    PERFORM pg_temp.f267_expect('UPDATE correction reason', v_msg, 'INCIDENT_CORRECTION_REASON_REQUIRED');
    v_msg := pg_temp.f267_do(u_ed, format($q$SELECT record_incident_update(%L, 'correction', p_field => 'duration_min', p_new_value => 'ten', p_reason => 'r')$q$, i_nr));
    PERFORM pg_temp.f267_expect('UPDATE correction value', v_msg, 'INCIDENT_CORRECTION_VALUE_INVALID|duration_min');
    v_msg := pg_temp.f267_do(u_ed, format($q$SELECT record_incident_update(%L, 'correction', p_field => 'nea_reportable', p_new_value => 'maybe', p_reason => 'r')$q$, i_nr));
    PERFORM pg_temp.f267_expect('UPDATE correction boolean', v_msg, 'INCIDENT_CORRECTION_VALUE_INVALID|nea_reportable');
    v_msg := pg_temp.f267_do(u_ed, format($q$SELECT record_incident_update(%L, 'correction', p_field => 'occurred_at', p_new_value => %L, p_reason => 'r')$q$, i_nr, (now() + interval '1 day')::text));
    PERFORM pg_temp.f267_expect('UPDATE correction future time', v_msg, 'INCIDENT_TIME_IN_FUTURE|%');
    v_msg := pg_temp.f267_do(u_ed, format($q$SELECT record_incident_update(%L, 'correction', p_field => 'what_happened', p_new_value => 'A pallet nearly fell', p_reason => 'r')$q$, i_nr));
    PERFORM pg_temp.f267_expect('UPDATE correction no change', v_msg, 'INCIDENT_CORRECTION_NO_CHANGE|what_happened');
    v_msg := pg_temp.f267_do(u_ed, format($q$SELECT record_incident_update(%L, 'correction', p_field => 'what_happened', p_new_value => 'A pallet of modules nearly fell off the rack', p_reason => 'More precise wording')$q$, i_nr));
    PERFORM pg_temp.f267_expect('UPDATE correction', v_msg, 'OK');
    v_msg := pg_temp.f267_do(u_ed, format($q$SELECT record_incident_update(%L, 'correction', p_field => 'what_happened', p_new_value => 'A pallet of modules fell off the rack', p_reason => 'It did fall')$q$, i_nr));
    PERFORM pg_temp.f267_expect('UPDATE second correction', v_msg, 'OK');
    v_j := pg_temp.f267_get(u_vw, format($q$SELECT to_jsonb(r) FROM incident_rows r WHERE r.id = %L$q$, i_nr));
    IF v_j ->> 'what_happened' <> 'A pallet of modules fell off the rack' OR (v_j ->> 'corrections')::int <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 267 UPDATE: the last correction wins on incident_rows: %', v_j; END IF;
    IF (SELECT what_happened FROM incidents WHERE id = i_nr) <> 'A pallet nearly fell' THEN
        RAISE EXCEPTION 'FIXTURE 267 UPDATE: the incident row itself never changes'; END IF;
    v_msg := pg_temp.f267_do(u_ed, format($q$SELECT record_incident_update(%L, 'closed', p_summary => 'Rack replaced; staff briefed')$q$, i_nr));
    PERFORM pg_temp.f267_expect('UPDATE close', v_msg, 'OK');
    v_msg := pg_temp.f267_do(u_ed, format($q$SELECT record_incident_update(%L, 'closed', p_summary => 'again')$q$, i_nr));
    PERFORM pg_temp.f267_expect('UPDATE close twice', v_msg, 'INCIDENT_ALREADY_RECORDED|closed');
    v_msg := pg_temp.f267_do(u_ed, format($q$SELECT record_incident_update(%L, 'correction', p_field => 'immediate_action', p_new_value => 'z', p_reason => 'r')$q$, i_nr));
    PERFORM pg_temp.f267_expect('UPDATE no correction after close', v_msg, 'INCIDENT_CLOSED|' || v_code2);
    v_msg := pg_temp.f267_do(u_ed, $q$UPDATE incident_updates SET reason = 'x'$q$);
    PERFORM pg_temp.f267_expect('UPDATE rows are append-only', v_msg, 'INCIDENT_UPDATE_IMMUTABLE|update');

    -- ══════════════ KIND ══════════════
    RAISE NOTICE 'fixture 267 · KIND';
    v_msg := pg_temp.f267_do(u_ed, $q$UPDATE incident_kinds SET code = 'injuries' WHERE code = 'injury'$q$);
    PERFORM pg_temp.f267_expect('KIND used code locked', v_msg, 'INCIDENT_KIND_CODE_LOCKED|injury|1');
    v_msg := pg_temp.f267_do(u_ed, $q$DELETE FROM incident_kinds WHERE code = 'injury'$q$);
    PERFORM pg_temp.f267_expect('KIND used kind not deleted', v_msg, 'INCIDENT_KIND_CODE_LOCKED|injury|1');
    v_msg := pg_temp.f267_do(u_ed, $q$UPDATE incident_kinds SET name_en = 'Injury at work' WHERE code = 'injury'$q$);
    PERFORM pg_temp.f267_expect('KIND rename', v_msg, 'OK');
    v_msg := pg_temp.f267_do(u_ed, $q$UPDATE incident_kinds SET code = 'dust_alarm' WHERE code = 'dust_concentration'$q$);
    PERFORM pg_temp.f267_expect('KIND unused code', v_msg, 'OK');
    v_msg := pg_temp.f267_do(u_ed, $q$UPDATE incident_kinds SET code = 'dust_concentration' WHERE code = 'dust_alarm'$q$);
    -- 只被一次更正用过的种类同样锁住(那件事故的种类读的是更正里那个字)
    v_j := pg_temp.f267_get(u_ed, format($q$SELECT record_incident('fire_smoke', %L, 'Smoke from a module', 'Doused', false, p_responsible_name => 'Lead')$q$, t_m));
    i_kind := (v_j ->> 'incident_id')::uuid;
    v_msg := pg_temp.f267_do(u_ed, format($q$SELECT record_incident_update(%L, 'correction', p_field => 'kind_code', p_new_value => 'thermal_runaway', p_reason => 'It was a runaway')$q$, i_kind));
    PERFORM pg_temp.f267_expect('KIND correction', v_msg, 'OK');
    v_msg := pg_temp.f267_do(u_ed, $q$UPDATE incident_kinds SET code = 'runaway' WHERE code = 'thermal_runaway'$q$);
    PERFORM pg_temp.f267_expect('KIND locked by a correction', v_msg, 'INCIDENT_KIND_CODE_LOCKED|thermal_runaway|1');
    v_msg := pg_temp.f267_do(u_vw, $q$UPDATE incident_kinds SET name_en = 'x' WHERE code = 'near_miss'$q$);
    PERFORM pg_temp.f267_expect('KIND edit needs the edit code', v_msg, 'PERMISSION_DENIED|module.safety.edit');

    -- ══════════════ LINK ══════════════
    RAISE NOTICE 'fixture 267 · LINK';
    SELECT md5(COALESCE(string_agg(to_jsonb(s)::text, '' ORDER BY s.id), '')) INTO v_ss_before FROM inbound_batch_safety_states s;
    SELECT md5(COALESCE(string_agg(to_jsonb(m)::text, '' ORDER BY m.id), '')) INTO v_mv_before FROM inventory_movements m;
    -- 库位那一件:时刻 = 现在(事务开始那一刻 —— 收货流水的 occurred_at 也是它)
    v_j := pg_temp.f267_get(u_ed, format($q$SELECT record_incident('gas_release', %L, 'Electrolyte smell at the bay', 'Bay ventilated', false, p_responsible_name => 'Lead', p_location_id => %L)$q$, now(), loc));
    i_loc := (v_j ->> 'incident_id')::uuid;
    -- 机器那一件:时刻 t_m(RUN-1 正在跑,RUN-2 已经结束);同一刻的那一件受伤事故在库位上 —— 而收货在 t_m 之后才到
    v_j := pg_temp.f267_get(u_ed, format($q$SELECT record_incident('fire_smoke', %L, 'Smoke from the shredder', 'E-stop pressed', true, p_responsible_name => 'Lead', p_equipment_id => %L, p_downtime_id => %L)$q$, t_m, fa, dt_m));
    i_mach := (v_j ->> 'incident_id')::uuid;
    v_j := pg_temp.f267_get(u_ed, format($q$SELECT jsonb_agg(to_jsonb(s) ORDER BY s.basis, s.batch_code) FROM suggest_incident_batches(%L) s$q$, i_loc));
    IF (SELECT count(*) FROM jsonb_array_elements(v_j) x WHERE x ->> 'basis' = 'location' AND (x ->> 'batch_id')::uuid = ib_l AND (x ->> 'qty')::numeric = 100) <> 1
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) x WHERE (x ->> 'batch_id')::uuid = ib_l2) THEN
        RAISE EXCEPTION 'FIXTURE 267 LINK: the location suggestion lists the stock at the bay at that moment, and nothing at another bay: %', v_j; END IF;
    v_j := pg_temp.f267_get(u_ed, format($q$SELECT jsonb_agg(to_jsonb(s) ORDER BY s.basis, s.batch_code) FROM suggest_incident_batches(%L) s$q$, i_inj));
    IF jsonb_array_length(COALESCE(v_j, '[]'::jsonb)) <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 267 LINK: stock that arrived at the bay after the incident is not suggested (no invented window): %', v_j; END IF;
    v_j := pg_temp.f267_get(u_ed, format($q$SELECT jsonb_agg(to_jsonb(s) ORDER BY s.basis, s.batch_code) FROM suggest_incident_batches(%L) s$q$, i_mach));
    IF (SELECT count(*) FROM jsonb_array_elements(v_j) x WHERE x ->> 'basis' = 'machine_run' AND x ->> 'evidence' = 'ZZ267-RUN-1'
                                                         AND (x ->> 'batch_id')::uuid IN (ib_m, ob_m)) <> 2
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) x WHERE (x ->> 'batch_id')::uuid IN (ib_free, ob_x)) THEN
        RAISE EXCEPTION 'FIXTURE 267 LINK: the machine suggestion is the input and output of the run on that machine at that moment, not an earlier run: %', v_j; END IF;
    v_msg := pg_temp.f267_do(u_none, format($q$SELECT * FROM suggest_incident_batches(%L)$q$, i_mach));
    PERFORM pg_temp.f267_expect('LINK suggestions need the view code', v_msg, 'PERMISSION_DENIED|module.safety.view');
    -- 确认一条建议 · 不在建议里的拒 · 按批号挑 · 重复链拒
    v_msg := pg_temp.f267_do(u_ed, format($q$SELECT link_incident_batch(%L, 'location', p_inbound_batch_id => %L)$q$, i_loc, ib_l));
    PERFORM pg_temp.f267_expect('LINK confirm a location suggestion', v_msg, 'OK');
    v_msg := pg_temp.f267_do(u_ed, format($q$SELECT link_incident_batch(%L, 'machine_run', p_output_batch_id => %L)$q$, i_mach, ob_m));
    PERFORM pg_temp.f267_expect('LINK confirm a machine suggestion', v_msg, 'OK');
    v_msg := pg_temp.f267_do(u_ed, format($q$SELECT link_incident_batch(%L, 'location', p_inbound_batch_id => %L)$q$, i_loc, ib_l2));
    PERFORM pg_temp.f267_expect('LINK not suggested', v_msg, 'INCIDENT_LINK_NOT_SUGGESTED|location|%');
    v_msg := pg_temp.f267_do(u_ed, format($q$SELECT link_incident_batch(%L, 'picked', p_inbound_batch_id => %L)$q$, i_mach, ib_free));
    PERFORM pg_temp.f267_expect('LINK pick any batch by code', v_msg, 'OK');
    v_msg := pg_temp.f267_do(u_ed, format($q$SELECT link_incident_batch(%L, 'picked', p_inbound_batch_id => %L)$q$, i_mach, ib_free));
    PERFORM pg_temp.f267_expect('LINK twice', v_msg, 'INCIDENT_BATCH_ALREADY_LINKED|%');
    v_msg := pg_temp.f267_do(u_vw, format($q$SELECT link_incident_batch(%L, 'picked', p_inbound_batch_id => %L)$q$, i_mach, ib_l2));
    PERFORM pg_temp.f267_expect('LINK needs the edit code', v_msg, 'PERMISSION_DENIED|module.safety.edit');
    v_msg := pg_temp.f267_do(u_ed, format($q$SELECT link_incident_batch(%L, 'guess', p_inbound_batch_id => %L)$q$, i_mach, ib_l2));
    PERFORM pg_temp.f267_expect('LINK basis', v_msg, 'INCIDENT_LINK_BASIS_INVALID|guess');
    -- 解链接:要理由 · 只解一次
    SELECT id INTO v_link FROM incident_batches WHERE incident_id = i_mach AND inbound_batch_id = ib_free;
    v_msg := pg_temp.f267_do(u_ed, format($q$SELECT unlink_incident_batch(%L, '  ')$q$, v_link));
    PERFORM pg_temp.f267_expect('LINK unlink needs a reason', v_msg, 'INCIDENT_UNLINK_REASON_REQUIRED');
    v_msg := pg_temp.f267_do(u_ed, format($q$SELECT unlink_incident_batch(%L, 'Picked by mistake — it was in the other bay')$q$, v_link));
    PERFORM pg_temp.f267_expect('LINK unlink', v_msg, 'OK');
    v_msg := pg_temp.f267_do(u_ed, format($q$SELECT unlink_incident_batch(%L, 'again')$q$, v_link));
    PERFORM pg_temp.f267_expect('LINK unlink twice', v_msg, 'INCIDENT_LINK_ALREADY_UNLINKED|%');
    BEGIN
        UPDATE incident_batches SET unlink_reason = 'rewritten' WHERE id = v_link;
        RAISE EXCEPTION 'FIXTURE 267 LINK: an unlinked link must not change again';
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.f267_expect('LINK owner rewrite', SQLERRM, 'INCIDENT_LINK_IMMUTABLE|update');
    END;
    v_msg := pg_temp.f267_do(u_ed, format($q$DELETE FROM incident_batches WHERE id = %L$q$, v_link));
    PERFORM pg_temp.f267_expect('LINK delete', v_msg, 'INCIDENT_LINK_IMMUTABLE|delete');
    IF (SELECT md5(COALESCE(string_agg(to_jsonb(s)::text, '' ORDER BY s.id), '')) FROM inbound_batch_safety_states s) <> v_ss_before
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(m)::text, '' ORDER BY m.id), '')) FROM inventory_movements m) <> v_mv_before THEN
        RAISE EXCEPTION 'FIXTURE 267 LINK: linking and unlinking never set a safety state and never move stock (MES-0 Q73)'; END IF;
    v_j := pg_temp.f267_get(u_ed, format($q$SELECT jsonb_agg(to_jsonb(b)) FROM incident_batch_rows b WHERE b.incident_id = %L$q$, i_mach));
    IF jsonb_array_length(v_j) <> 2 OR (SELECT count(*) FROM jsonb_array_elements(v_j) x WHERE (x ->> 'active')::boolean) <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 267 LINK: the incident shows one active and one unlinked link: %', v_j; END IF;

    -- ══════════════ NCR ══════════════
    RAISE NOTICE 'fixture 267 · NCR';
    v_msg := pg_temp.f267_do(u_qe, format($q$SELECT open_ncr('incident', 'Smoke damage — hold until inspected', p_output_batch_id => %L, p_incident_id => %L)$q$, ob_x, i_mach));
    PERFORM pg_temp.f267_expect('NCR batch not linked', v_msg, 'NCR_INCIDENT_BATCH_NOT_LINKED|%');
    v_msg := pg_temp.f267_do(u_qe, format($q$SELECT open_ncr('incident', 'x', p_output_batch_id => %L)$q$, ob_m));
    PERFORM pg_temp.f267_expect('NCR incident source needs the incident', v_msg, 'NCR_INCIDENT_REQUIRED');
    v_msg := pg_temp.f267_do(u_qe, format($q$SELECT open_ncr('manual', 'x', p_output_batch_id => %L, p_incident_id => %L)$q$, ob_m, i_mach));
    PERFORM pg_temp.f267_expect('NCR incident only with its source', v_msg, 'NCR_INCIDENT_ONLY_WITH_SOURCE');
    v_msg := pg_temp.f267_do(u_ed, format($q$SELECT open_ncr('incident', 'x', p_output_batch_id => %L, p_incident_id => %L)$q$, ob_m, i_mach));
    PERFORM pg_temp.f267_expect('NCR needs the quality edit code', v_msg, 'PERMISSION_DENIED|module.quality.edit');
    IF EXISTS (SELECT 1 FROM batch_quality_hold(NULL, ob_m)) THEN
        RAISE EXCEPTION 'FIXTURE 267 NCR: an incident link alone never holds a batch (Q8)'; END IF;
    v_j := pg_temp.f267_get(u_qe, format($q$SELECT open_ncr('incident', 'Smoke damage — hold until inspected', p_output_batch_id => %L, p_incident_id => %L)$q$, ob_m, i_mach));
    IF NOT EXISTS (SELECT 1 FROM batch_quality_hold(NULL, ob_m) h WHERE h.ncr_id = (v_j ->> 'ncr_id')::uuid)
       OR (SELECT incident_id FROM nonconformance_reports WHERE id = (v_j ->> 'ncr_id')::uuid) <> i_mach
       OR (SELECT source FROM nonconformance_reports WHERE id = (v_j ->> 'ncr_id')::uuid) <> 'incident' THEN
        RAISE EXCEPTION 'FIXTURE 267 NCR: an incident-source NCR on a linked batch opens the quality hold: %', v_j; END IF;
    v_j := pg_temp.f267_get(u_qe, format($q$SELECT to_jsonb(n) FROM ncr_rows n WHERE n.id = %L$q$, (v_j ->> 'ncr_id')::uuid));
    IF v_j ->> 'incident_code' IS NULL OR NOT (v_j ->> 'holding')::boolean THEN
        RAISE EXCEPTION 'FIXTURE 267 NCR: ncr_rows names the incident and says the batch is held: %', v_j; END IF;

    -- ══════════════ CITE ══════════════
    RAISE NOTICE 'fixture 267 · CITE';
    v_msg := pg_temp.f267_do(u_ed, format($q$SELECT record_incident('fire_smoke', %L, 'x', 'y', false, p_responsible_name => 'Lead', p_equipment_id => %L, p_downtime_id => %L)$q$, t_m, fa, dt_x));
    PERFORM pg_temp.f267_expect('CITE downtime of another machine', v_msg, 'INCIDENT_DOWNTIME_OTHER_MACHINE|FX267-M2');
    v_msg := pg_temp.f267_do(u_ed, format($q$SELECT record_incident('fire_smoke', %L, 'x', 'y', false, p_responsible_name => 'Lead', p_downtime_id => %L)$q$, t_m, dt_m));
    PERFORM pg_temp.f267_expect('CITE downtime without a machine', v_msg, 'INCIDENT_DOWNTIME_NEEDS_MACHINE');
    v_msg := pg_temp.f267_do(u_ed, format($q$SELECT record_incident('fire_smoke', %L, 'x', 'y', false, p_responsible_name => 'Lead', p_equipment_id => %L, p_run_event_id => %L)$q$, t_m, fa, ev_w));
    PERFORM pg_temp.f267_expect('CITE withdrawn run event', v_msg, 'INCIDENT_RUN_EVENT_WITHDRAWN|%');
    -- 可靠性只数停机:引用了 dt_m 的事故(i_mach)在不在,FX267-M 的读数一样 —— 拿"把那件事故当没有"的同一个函数对比做不到(它不读事故),
    --   所以断言的是:函数体里一个字都没有提到 incidents
    IF position('incident' IN pg_get_functiondef('public.equipment_reliability(uuid, timestamp with time zone, timestamp with time zone)'::regprocedure)) > 0 THEN
        RAISE EXCEPTION 'FIXTURE 267 CITE: MTBF counts downtime only — equipment_reliability must not read incidents (Q9)'; END IF;
    v_n := (pg_temp.f267_get(u_all, format($q$SELECT to_jsonb(r.failures) FROM equipment_reliability(%L, %L, %L) r$q$, fa, t_m - interval '1 day', now())))::bigint;
    IF v_n <> 1 THEN RAISE EXCEPTION 'FIXTURE 267 CITE: the machine has exactly the one failure stop it had (got %)', v_n; END IF;

    -- ══════════════ NEA ══════════════
    RAISE NOTICE 'fixture 267 · NEA';
    -- business_days_after:一年没有日历 → 空;种上那一年的日历 → 跨周末与一天公共假期
    v_y := 2041;
    DELETE FROM public_holidays WHERE extract(year FROM holiday_date) = v_y;
    v_fri := (SELECT x::date FROM generate_series(make_date(v_y, 3, 1), make_date(v_y, 3, 10), interval '1 day') x WHERE extract(isodow FROM x) = 5 LIMIT 1);
    IF business_days_after(v_fri, 2) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 267 NEA: with no calendar for the year the deadline cannot be computed (NULL), got %', business_days_after(v_fri, 2); END IF;
    INSERT INTO public_holidays (holiday_date, name_en, name_zh, country, is_active, holiday_key)
    VALUES (v_fri + 3, 'f267 Monday holiday', 'f267 星期一假期', 'SG', true, 'f267-monday');
    IF business_days_after(v_fri, 2) <> v_fri + 5 OR business_days_after(v_fri, 1) <> v_fri + 4
       OR business_days_after(v_fri, 2) <> pg_temp.f267_nth_workday(v_fri, 2) THEN
        RAISE EXCEPTION 'FIXTURE 267 NEA: Friday + 2 working days over a weekend and a Monday holiday is Wednesday (got %)', business_days_after(v_fri, 2); END IF;
    IF business_days_after(v_fri, 0) IS NOT NULL OR business_days_after(NULL, 2) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 267 NEA: n < 1 or no date gives NULL'; END IF;
    -- 今年与明年的日历自己保证有(README 第 4 条:不继承按年播种的东西)—— 没有就种一天
    v_d := (t_m AT TIME ZONE 'Asia/Singapore')::date;
    FOR v_y IN SELECT generate_series(extract(year FROM v_d)::int, extract(year FROM v_d)::int + 1) LOOP
        IF NOT EXISTS (SELECT 1 FROM public_holidays WHERE is_active AND country = 'SG' AND extract(year FROM holiday_date) = v_y) THEN
            INSERT INTO public_holidays (holiday_date, name_en, name_zh, country, is_active, holiday_key)
            VALUES (make_date(v_y, 12, 25), 'f267 Christmas', 'f267 圣诞', 'SG', true, 'f267-christmas-' || v_y);
        END IF;
    END LOOP;
    -- 这件要通报的事故(i_inj,今天之前两小时):两条提醒都在,只给持安全查看码的人
    v_j := pg_temp.f267_get(u_vw, format($q$SELECT jsonb_agg(o.item_type ORDER BY o.item_type) FROM operations_now o WHERE o.item_id = %L$q$, i_inj));
    IF v_j IS DISTINCT FROM '["incident_nea_notify_due", "incident_report_due"]'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 267 NEA: a reportable incident raises both reminders: %', v_j; END IF;
    v_n := pg_temp.f267_get(u_none, format($q$SELECT to_jsonb(count(*)) FROM operations_now o WHERE o.item_id = %L$q$, i_inj))::bigint;
    IF v_n <> 0 THEN RAISE EXCEPTION 'FIXTURE 267 NEA: the reminders read module.safety.view'; END IF;
    v_j := pg_temp.f267_get(u_vw, format($q$SELECT to_jsonb(r) FROM incident_rows r WHERE r.id = %L$q$, i_inj));
    IF v_j ->> 'deadline_state' <> 'computed' OR (v_j ->> 'report_deadline')::date <> pg_temp.f267_nth_workday(v_d, 2)
       OR (v_j ->> 'deadline_confirmed')::boolean OR (v_j ->> 'deadline_working_days')::int <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 267 NEA: the deadline is the 2nd working day after the incident date, shown unconfirmed: % (independent count %)', v_j, pg_temp.f267_nth_workday(v_d, 2); END IF;
    -- 日历缺一年 → 算不出来,不猜日子
    UPDATE public_holidays SET is_active = false WHERE extract(year FROM holiday_date) BETWEEN extract(year FROM v_d) AND extract(year FROM v_d) + 1;
    v_j := pg_temp.f267_get(u_vw, format($q$SELECT to_jsonb(r) FROM incident_rows r WHERE r.id = %L$q$, i_inj));
    IF v_j ->> 'deadline_state' <> 'cannot_compute' OR v_j ->> 'report_deadline' IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 267 NEA: a missing holiday calendar gives cannot_compute and no date: %', v_j; END IF;
    UPDATE public_holidays SET is_active = true WHERE extract(year FROM holiday_date) BETWEEN extract(year FROM v_d) AND extract(year FROM v_d) + 1;
    -- 记下通报 → 第一条消失、第二条还在;交了书面报告 → 第二条也消失
    v_msg := pg_temp.f267_do(u_ed, format($q$SELECT record_incident_update(%L, 'nea_notified', %L, 'NEA hotline, ref 12345')$q$, i_inj, now()));
    PERFORM pg_temp.f267_expect('NEA notified', v_msg, 'OK');
    v_msg := pg_temp.f267_do(u_ed, format($q$SELECT record_incident_update(%L, 'nea_notified', %L)$q$, i_inj, now()));
    PERFORM pg_temp.f267_expect('NEA notified twice', v_msg, 'INCIDENT_ALREADY_RECORDED|nea_notified');
    v_j := pg_temp.f267_get(u_vw, format($q$SELECT jsonb_agg(o.item_type ORDER BY o.item_type) FROM operations_now o WHERE o.item_id = %L$q$, i_inj));
    IF v_j IS DISTINCT FROM '["incident_report_due"]'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 267 NEA: after the notification only the report reminder stays: %', v_j; END IF;
    v_msg := pg_temp.f267_do(u_ed, format($q$SELECT record_incident_update(%L, 'report_submitted', %L, 'NEA/WSH/2026/001')$q$, i_inj, now()));
    PERFORM pg_temp.f267_expect('NEA report submitted', v_msg, 'OK');
    v_j := pg_temp.f267_get(u_vw, format($q$SELECT jsonb_agg(o.item_type) FROM operations_now o WHERE o.item_id = %L$q$, i_inj));
    IF v_j IS NOT NULL THEN RAISE EXCEPTION 'FIXTURE 267 NEA: after the written report no reminder stays: %', v_j; END IF;
    -- 更正成不用通报 → 两条都没有(i_mach 是一件要通报的事故)
    v_j := pg_temp.f267_get(u_vw, format($q$SELECT jsonb_agg(o.item_type ORDER BY o.item_type) FROM operations_now o WHERE o.item_id = %L$q$, i_mach));
    IF v_j IS DISTINCT FROM '["incident_nea_notify_due", "incident_report_due"]'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 267 NEA: the machine incident is reportable: %', v_j; END IF;
    v_msg := pg_temp.f267_do(u_ed, format($q$SELECT record_incident_update(%L, 'correction', p_field => 'nea_reportable', p_new_value => 'false', p_reason => 'Smoke only, no fire — not reportable')$q$, i_mach));
    PERFORM pg_temp.f267_expect('NEA corrected to not reportable', v_msg, 'OK');
    v_j := pg_temp.f267_get(u_vw, format($q$SELECT jsonb_agg(o.item_type) FROM operations_now o WHERE o.item_id = %L$q$, i_mach));
    IF v_j IS NOT NULL THEN RAISE EXCEPTION 'FIXTURE 267 NEA: a corrected not-reportable incident raises nothing: %', v_j; END IF;

    -- ══════════════ V19 ══════════════
    RAISE NOTICE 'fixture 267 · V19';
    v_n := pg_temp.f267_get(u_vw, $q$SELECT to_jsonb(count(*)) FROM pending_values WHERE value_code = 'V19'$q$)::bigint;
    IF v_n <> 1 THEN RAISE EXCEPTION 'FIXTURE 267 V19: the unconfirmed value is on the pending list (Q11)'; END IF;
    v_n := pg_temp.f267_get(u_none, $q$SELECT to_jsonb(count(*)) FROM pending_values WHERE value_code = 'V19'$q$)::bigint;
    IF v_n <> 0 THEN RAISE EXCEPTION 'FIXTURE 267 V19: the V19 row reads module.safety.view'; END IF;
    v_msg := pg_temp.f267_do(u_vw, $q$SELECT set_safety_settings(2, true)$q$);
    PERFORM pg_temp.f267_expect('V19 needs the edit code', v_msg, 'PERMISSION_DENIED|module.safety.edit');
    v_msg := pg_temp.f267_do(u_ed, $q$SELECT set_safety_settings(NULL, true)$q$);
    PERFORM pg_temp.f267_expect('V19 no value no confirmation', v_msg, 'SAFETY_CONFIRM_NEEDS_VALUE');
    v_msg := pg_temp.f267_do(u_ed, $q$SELECT set_safety_settings(0, false)$q$);
    PERFORM pg_temp.f267_expect('V19 positive', v_msg, 'SAFETY_REPORT_DAYS_INVALID');
    v_msg := pg_temp.f267_do(u_ed, $q$SELECT set_safety_settings(2, true, 'NEA licence condition 7.3')$q$);
    PERFORM pg_temp.f267_expect('V19 confirm', v_msg, 'OK');
    v_n := pg_temp.f267_get(u_vw, $q$SELECT to_jsonb(count(*)) FROM pending_values WHERE value_code = 'V19'$q$)::bigint;
    IF v_n <> 0 OR NOT (SELECT deadline_confirmed FROM incident_current_all WHERE id = i_inj) THEN
        RAISE EXCEPTION 'FIXTURE 267 V19: a confirmed V19 leaves the pending list and the deadline reads confirmed'; END IF;
    v_msg := pg_temp.f267_do(u_ed, $q$SELECT set_safety_settings(3, false)$q$);
    PERFORM pg_temp.f267_expect('V19 change without confirming', v_msg, 'OK');
    v_n := pg_temp.f267_get(u_vw, $q$SELECT to_jsonb(count(*)) FROM pending_values WHERE value_code = 'V19'$q$)::bigint;
    IF v_n <> 1 OR (SELECT deadline_confirmed FROM incident_current_all WHERE id = i_inj) OR (SELECT deadline_working_days FROM incident_current_all WHERE id = i_inj) <> 3 THEN
        RAISE EXCEPTION 'FIXTURE 267 V19: a changed number does not inherit the old confirmation'; END IF;
    v_j := pg_temp.f267_get(u_ed, format($q$SELECT record_incident('injury', %L, 'A visitor slipped on electrolyte', 'Spill cleaned', true, p_responsible_name => 'Lead', p_injured_person_name => 'A visitor')$q$, t_m));
    i_rep := (v_j ->> 'incident_id')::uuid;
    v_msg := pg_temp.f267_do(u_ed, $q$SELECT set_safety_settings(NULL, false)$q$);
    PERFORM pg_temp.f267_expect('V19 cleared', v_msg, 'OK');
    IF (SELECT deadline_state FROM incident_current_all WHERE id = i_rep) <> 'not_set' OR (SELECT report_deadline FROM incident_current_all WHERE id = i_rep) IS NOT NULL
       OR (SELECT deadline_state FROM incident_current_all WHERE id = i_kind) <> 'not_reportable' THEN
        RAISE EXCEPTION 'FIXTURE 267 V19: with V19 empty an open reportable incident reads not_set and has no date'; END IF;
    v_n := pg_temp.f267_get(u_vw, $q$SELECT to_jsonb(count(*)) FROM pending_values WHERE value_code = 'V19'$q$)::bigint;
    IF v_n <> 1 THEN RAISE EXCEPTION 'FIXTURE 267 V19: an empty V19 is on the pending list'; END IF;
    PERFORM pg_temp.f267_do(u_ed, $q$SELECT set_safety_settings(2, false)$q$);

    -- ══════════════ HANDOVER ══════════════
    RAISE NOTICE 'fixture 267 · HANDOVER';
    v_msg := pg_temp.f267_do(u_ho, format($q$SELECT submit_shift_handover('day', %L, %L, %L, NULL, %L::jsonb, NULL, ARRAY[gen_random_uuid()])$q$, v_today, e_out, e_in,
                                       '[{"item_type_code": "unfinished_work", "body": "f267 nothing left"}]'));
    PERFORM pg_temp.f267_expect('HANDOVER unknown incident', v_msg, 'HANDOVER_INCIDENT_NOT_FOUND');
    v_j := pg_temp.f267_get(u_ho, format($q$SELECT to_jsonb(submit_shift_handover('day', %L, %L, %L, 'f267 handover', %L::jsonb, NULL, ARRAY[%L, %L]::uuid[]))$q$, v_today, e_out, e_in,
                                         '[{"item_type_code": "unfinished_work", "body": "f267 nothing left"}]', i_inj, i_mach));
    v_ho := (v_j #>> '{}')::uuid;
    IF (SELECT count(*) FROM shift_handover_incident_refs WHERE handover_id = v_ho) <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 267 HANDOVER: the handover cites the two incidents'; END IF;
    v_n := pg_temp.f267_get(u_ho, format($q$SELECT to_jsonb(count(*)) FROM shift_handover_incident_refs WHERE handover_id = %L$q$, v_ho))::bigint;
    v_n2 := pg_temp.f267_get(u_vw, format($q$SELECT to_jsonb(count(*)) FROM shift_handover_incident_refs WHERE incident_id = %L$q$, i_inj))::bigint;
    IF v_n <> 2 OR v_n2 <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 267 HANDOVER: the handover page (processing view) and the incident page (safety view) both read the reference (% / %)', v_n, v_n2; END IF;
    v_msg := pg_temp.f267_do(u_ho, format($q$INSERT INTO shift_handover_incident_refs (handover_id, incident_id) VALUES (%L, %L)$q$, v_ho, i_nr));
    PERFORM pg_temp.f267_expect('HANDOVER refs only through the function', v_msg, 'permission denied%');

    -- ══════════════ TRAIL ══════════════
    RAISE NOTICE 'fixture 267 · TRAIL';
    v_txt := (pg_temp.f267_get(u_vw, format($q$SELECT to_jsonb(string_agg(DISTINCT t.table_name, ',' ORDER BY t.table_name)) FROM record_trail('incident', %L, 50) t$q$, i_mach)) #>> '{}');
    IF v_txt NOT LIKE '%incident_batches%' OR v_txt NOT LIKE '%incident_updates%' OR v_txt NOT LIKE '%incidents%' OR v_txt NOT LIKE '%shift_handover_incident_refs%' THEN
        RAISE EXCEPTION 'FIXTURE 267 TRAIL: the incident trail carries the incident, its updates, its batch links and the handover reference: %', v_txt; END IF;
    v_txt := (pg_temp.f267_get(u_ed, format($q$SELECT to_jsonb(string_agg(DISTINCT t.table_name, ',')) FROM record_trail('output_batch', %L, 50) t$q$, ob_m)) #>> '{}');
    IF v_txt NOT LIKE '%incident_batches%' THEN
        RAISE EXCEPTION 'FIXTURE 267 TRAIL: the linked batch''s trail shows the incident link: %', v_txt; END IF;

    PERFORM pg_temp.f267_recon(u_all, 'at the end');
    RAISE NOTICE 'FIXTURE 267 全部通过: REG · GRANT · REFUSE · NUM · MASK · DIRECT · UPDATE · KIND · LINK · NCR · CITE · NEA · V19 · HANDOVER · TRAIL';
END $$;

ROLLBACK;
