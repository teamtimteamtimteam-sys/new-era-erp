-- ═══════════════════════════════════════════════════════════════════════════
-- fixture 268 —— 一次巡检照清单记下就不改、一条发现跟到关闭为止,一条超标的环境监测结果当场开一件事故;视图一律不可写
--   (MES-7b-2,2026-10-16;MES-0 Q53 · Q72 · Q75;MES-7b Step 0 Q13–Q16 · Q17 · Q19–Q22 · Q27,Tim;F16 是 Tim 新加的)
-- ═══════════════════════════════════════════════════════════════════════════
-- 臂:
--   REG    八张新表都在、一张清单 / 一个参数都不引导;单据登记 INS;审计主语 inspection_run · inspection_template ·
--          dictionary_environmental_parameters · safety_environment 与成员;八张新表进变更记录,豁免仍是 8;新表没有遮蔽的列(规则仍 119);
--          不合格报告的来源约束认 inspection、并且 inspection ⇔ 引用一条发现;新视图 authenticated 只读、底视图读不到
--   F16    没有一张 public 视图对 anon / authenticated 带 INSERT / UPDATE / DELETE / TRUNCATE;一句零行的写穿视图对 authenticated 按 42501 拒
--   TPL    存清单要 module.safety.edit;代号必填 / 只许大写字母数字 / 不重复;名字、片区、频率 ≥ 1、至少一项、每项有字 —— 各自按名拒;
--          会话里直连写清单或检查项按名拒;清单不许删;改清单时检查项按位置对齐(字没变的那一行不动,少了的删掉)
--   NUM    INS-年-NNNN,按年无洞(两次连号)
--   RUN    必填(清单 · 时刻 · 巡检的人)、停用的清单、没有检查项的清单、不在清单上的项、重复、结果不是 pass / fail / na、不合格没说明、
--          少一项、时刻在未来 —— 各自按名拒,拒了什么都没写;pass / fail(带说明)/ na 原样存下;每一项的字与清单的代号 / 名字 / 片区
--          抄进来 —— 之后改清单(改字、删一项、改名)这一次一个字都不动
--   IMMUT  交了的巡检、结果、关闭:改与删对谁(连属主)都按名拒;会话里直连插入按名拒
--   CORR   更正:引用它、带理由 → 收;没理由 / 有理由没引用 / 引用不存在的 / 引用一次已经被更正过的 —— 按名拒;被更正的那一次读得出
--          "被谁更正";一次被更正过的巡检上不再收新的发现
--   FIND   发现挂在一项不合格上(合格那一项按名拒);纠正措施、负责的人必填;到期日可空;开着的发现在提醒里(只给持安全查看码的人);
--          关闭要写做了什么、只关一次;关闭之后提醒消失;发现写下之后不改
--   TASK   "建一张任务":给按下的人建一张【私人】任务(归属人是他、类型 personal、标题带巡检编号与那一项、说明是纠正措施、到期日跟着发现),
--          发现的 task_id 指着它;只建一次;没有员工档案按名拒;没有任务码按名拒;【关掉那张任务,发现照旧开着、提醒照旧在】;
--          之后关闭发现照常;关了的发现不再建任务;任务表本身一列一支触发器都没加
--   DUE    有频率的清单:还没巡过 → 提醒(never_run);刚巡过 → 没有提醒;上一次巡检早于频率 → 提醒(due,日子 = 上一次 + 频率);
--          频率空着 → 没有提醒;停用 → 没有提醒;被更正过的那一次不算"最近一次"
--   V18    清单一张都没有时一行;有了之后每一张频率空着的启用清单一行;有频率就不列;只给持安全查看码的人
--   ENV    参数字典:限值与口径成对(ENV_LIMIT_NEEDS_BASIS);写要 module.safety.edit;用过的代号冻住(ENV_PARAMETER_CODE_LOCKED),名字照改。
--          结果:必填各自按名拒;参数不在 / 停用、实验室不在、采样日在未来按名拒;没有限值 → 不判定(exceeds 空,没有事故);
--          在限值之内 → false;超标(max:高于 · min:低于)→ 同一笔事务里开一件 emission_exceedance(要不要通报由记录的人答,
--          不答按名拒;当场做了什么不写按名拒;拒了连事故也没有);限值与单位在记下那一刻抄下来 —— 之后改字典不改写它;
--          只追加(改与删按名拒,直连插入按名拒);更正一条超标的结果、仍超标 → 指着同一件事故,不开第二件
--   V20    参数字典空着时一行;有了之后每一个没有限值的启用参数一行;有限值就不列;只给持安全查看码的人
--   NCR    来源 inspection 引用一条说的是一批货的发现 → 那一批进质量暂扣;发现那一行数得出引用它的报告(263 的两臂管拒绝与接受)
--   TRAIL  巡检的审计记录里有它自己、结果、发现与关闭;清单的记录里有检查项;环境监测是一条集合记录,看得见结果
--
-- 自带数据(README 第 2 条);以 postgres 跑;员工的调用切成 authenticated + JWT(AGENTS.md:RLS 断言必须切角色)。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '300s';

CREATE FUNCTION pg_temp.f268_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims',
                      CASE WHEN p_user IS NULL THEN '' ELSE format('{"sub":"%s","role":"authenticated"}', p_user) END, true)
$f$;

CREATE FUNCTION pg_temp.f268_do(p_user uuid, p_sql text) RETURNS text
LANGUAGE plpgsql AS $f$
BEGIN
    PERFORM pg_temp.f268_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql;
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f268_as(NULL);
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f268_as(NULL);
    RETURN SQLERRM;
END;
$f$;

CREATE FUNCTION pg_temp.f268_get(p_user uuid, p_sql text) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v jsonb;
BEGIN
    PERFORM pg_temp.f268_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f268_as(NULL);
    RETURN v;
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f268_as(NULL);
    RAISE;
END;
$f$;

CREATE FUNCTION pg_temp.f268_user(p_label text, p_codes text[]) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE u uuid := gen_random_uuid(); r uuid;
BEGIN
    INSERT INTO auth.users (id, email, email_confirmed_at, created_at) VALUES (u, 'fx268-' || p_label || '@test.local', now(), now());
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx268-' || p_label, 'f', 'f', true) RETURNING id INTO r;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r, c FROM unnest(p_codes) c;
    INSERT INTO user_roles (user_id, role_id) VALUES (u, r);
    RETURN u;
END;
$f$;

CREATE FUNCTION pg_temp.f268_expect(p_arm text, p_got text, p_like text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
    IF (p_got IS NULL OR p_got NOT LIKE p_like) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 268 % expected % got %', p_arm, p_like, COALESCE(p_got, '<null>');
    END IF;
END;
$f$;

-- 一次巡检的结果数组:每一项 pass,除了点名的那几项
CREATE FUNCTION pg_temp.f268_results(p_n int, p_fail int DEFAULT NULL, p_na int DEFAULT NULL) RETURNS jsonb
LANGUAGE sql AS $f$
    SELECT jsonb_agg(jsonb_build_object('position', i,
                                        'result', CASE WHEN i = p_fail THEN 'fail' WHEN i = p_na THEN 'na' ELSE 'pass' END,
                                        'note', CASE WHEN i = p_fail THEN 'f268 failed item ' || i END) ORDER BY i)
      FROM generate_series(1, p_n) i
$f$;

DO $$
DECLARE
    u_all uuid; u_ed uuid; u_vw uuid; u_vwt uuid; u_noemp uuid; u_none uuid; u_qe uuid;
    e_ed uuid := gen_random_uuid(); e_vw uuid := gen_random_uuid(); e_vwt uuid := gen_random_uuid(); e_owner uuid := gen_random_uuid();
    v_base text; v_today date := (now() AT TIME ZONE 'Asia/Singapore')::date;
    t1 uuid; t2 uuid; t3 uuid; t_nofreq uuid; t_off uuid;
    r1 uuid; r2 uuid; r_c uuid; r_old uuid; v_code1 text; v_code2 text;
    f1 uuid; f2 uuid; v_task uuid; v_task_code text;
    er_nj uuid; er_in uuid; er_ex uuid; er_min uuid; er_cor uuid; v_inc uuid;
    v_sup uuid; v_mat uuid; ib uuid;
    v_j jsonb; v_msg text; v_n bigint; v_n2 bigint; v_txt text;
BEGIN
    SELECT code INTO v_base FROM currencies WHERE is_base;
    PERFORM pg_temp.f268_as(NULL);
    UPDATE finance_settings SET locked_before = NULL;

    -- ══════════════ REG ══════════════
    RAISE NOTICE 'fixture 268 · REG';
    IF (EXISTS (SELECT 1 FROM unnest(ARRAY['inspection_templates', 'inspection_template_items', 'inspection_runs', 'inspection_results',
                                          'inspection_findings', 'inspection_finding_closures', 'environmental_parameters',
                                          'environmental_results']) t WHERE to_regclass('public.' || t) IS NULL)) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 268 REG: the eight new tables'; END IF;
    IF (EXISTS (SELECT 1 FROM inspection_templates) OR EXISTS (SELECT 1 FROM environmental_parameters)) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 268 REG: no checklist and no parameter is seeded (V18 · V20 — Q13 · Q16)'; END IF;
    IF (document_type_prefix('inspection') <> 'INS' OR (SELECT route FROM document_types WHERE key = 'inspection') <> '/safety/inspections'
       OR (SELECT view_permission FROM document_types WHERE key = 'inspection') <> ARRAY['module.safety.view']
       OR (SELECT table_name FROM document_types WHERE key = 'inspection') <> 'inspection_runs') IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 268 REG: document type INS'; END IF;
    IF (NOT EXISTS (SELECT 1 FROM trail_subjects() s WHERE s.subject = 'inspection_run' AND s.root_table = 'inspection_runs' AND s.view_codes = ARRAY['module.safety.view'])
       OR NOT EXISTS (SELECT 1 FROM trail_subjects() s WHERE s.subject = 'inspection_template' AND s.root_table = 'inspection_templates')
       OR NOT EXISTS (SELECT 1 FROM trail_subjects() s WHERE s.subject = 'dictionary_environmental_parameters' AND s.root_rule = 'collection')
       OR NOT EXISTS (SELECT 1 FROM trail_subjects() s WHERE s.subject = 'safety_environment' AND s.root_table = 'environmental_results' AND s.root_rule = 'collection')
       OR (SELECT count(*) FROM trail_subject_members() m WHERE m.subject = 'inspection_run') <> 4
       OR NOT EXISTS (SELECT 1 FROM trail_subject_members() m WHERE m.subject = 'inspection_run' AND m.table_name = 'inspection_finding_closures' AND m.home)
       OR NOT EXISTS (SELECT 1 FROM trail_subject_members() m WHERE m.subject = 'inspection_run' AND m.table_name = 'nonconformance_reports' AND NOT m.home)
       OR NOT EXISTS (SELECT 1 FROM trail_subject_members() m WHERE m.subject = 'inspection_template' AND m.table_name = 'inspection_template_items' AND m.home)) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 268 REG: trail subjects inspection_run / inspection_template / dictionary_environmental_parameters / safety_environment and their members'; END IF;
    v_j := change_log_coverage_gaps();
    IF (jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 8) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 268 REG: change-log coverage (gaps 0, exclusions 8): %', v_j; END IF;
    IF (EXISTS (SELECT 1 FROM unnest(ARRAY['inspection_templates', 'inspection_template_items', 'inspection_runs', 'inspection_results',
                                          'inspection_findings', 'inspection_finding_closures', 'environmental_parameters', 'environmental_results']) t
                WHERE NOT EXISTS (SELECT 1 FROM pg_trigger g WHERE g.tgname = 'zzz_change_log' AND g.tgrelid = ('public.' || t)::regclass))) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 268 REG: every new table is change-logged'; END IF;
    IF (EXISTS (SELECT 1 FROM change_log_mask_rules() WHERE table_name LIKE 'inspection%' OR table_name LIKE 'environmental%')
       OR (SELECT count(*) FROM change_log_mask_rules()) <> 119) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 268 REG: no masked column in MES-7b-2 (rules stay 119)'; END IF;
    -- COALESCE:约束被摘掉时 pg_get_constraintdef 给 NULL,而 NULL NOT LIKE … 是 NULL,IF 会把它读成"通过"
    IF (COALESCE(pg_get_constraintdef((SELECT oid FROM pg_constraint WHERE conname = 'nonconformance_reports_source_check')), '') NOT LIKE '%''inspection''%'
       OR COALESCE(pg_get_constraintdef((SELECT oid FROM pg_constraint WHERE conname = 'nonconformance_reports_inspection_source')), '') NOT LIKE '%inspection_finding_id IS NOT NULL%') IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 268 REG: the NCR source inspection must cite a finding'; END IF;
    IF (EXISTS (SELECT 1 FROM unnest(ARRAY['inspection_template_rows', 'inspection_run_rows', 'inspection_finding_rows', 'environmental_result_rows']) v
                WHERE NOT has_table_privilege('authenticated', ('public.' || v)::regclass, 'SELECT'))
       OR has_table_privilege('authenticated', 'public.inspection_template_due_all'::regclass, 'SELECT')) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 268 REG: the new views are readable by staff, the base view is not'; END IF;

    -- ══════════════ F16 ══════════════
    RAISE NOTICE 'fixture 268 · F16';
    SELECT string_agg(c.relname || ':' || g.r || ':' || p.priv, ', ' ORDER BY c.relname) INTO v_txt
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     CROSS JOIN (VALUES ('anon'), ('authenticated')) g(r)
     CROSS JOIN (VALUES ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE')) p(priv)
     WHERE n.nspname = 'public' AND c.relkind = 'v' AND has_table_privilege(g.r, c.oid, p.priv);
    IF (v_txt IS NOT NULL) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 268 F16: no view may carry a write grant to anon / authenticated: %', v_txt; END IF;
    IF ((SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relkind = 'v') < 100) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 268 F16: the view census saw fewer than 100 views — blind, not clean'; END IF;

    -- ══════════════ 布景 ══════════════
    u_all   := pg_temp.f268_user('all', ARRAY(SELECT code FROM permissions));
    u_ed    := pg_temp.f268_user('ed', ARRAY['module.safety.view', 'module.safety.edit', 'module.tasks.view']);
    u_vw    := pg_temp.f268_user('vw', ARRAY['module.safety.view']);
    u_vwt   := pg_temp.f268_user('vwt', ARRAY['module.safety.view', 'module.tasks.view', 'module.tasks.edit']);
    u_noemp := pg_temp.f268_user('noemp', ARRAY['module.safety.view', 'module.tasks.view']);
    u_none  := pg_temp.f268_user('none', ARRAY['module.processing.view', 'module.tasks.view']);
    u_qe    := pg_temp.f268_user('qe', ARRAY['module.quality.view', 'module.quality.edit', 'module.inbound.view', 'module.output.view', 'module.safety.view']);
    PERFORM pg_temp.f268_user('qd', ARRAY['action.ncr_decide', 'module.quality.view', 'module.inbound.view']);
    INSERT INTO employees (id, code, legal_name, preferred_name, employment_type, work_category, hire_date, user_id) VALUES
        (e_ed, 'FX268-E1', 'f268 safety officer', 'Safe', 'full_time', 'shopfloor', DATE '2020-01-01', u_ed),
        (e_vw, 'FX268-E2', 'f268 viewer', 'View', 'full_time', 'shopfloor', DATE '2020-01-01', u_vw),
        (e_vwt, 'FX268-E3', 'f268 task person', 'Task', 'full_time', 'shopfloor', DATE '2020-01-01', u_vwt),
        (e_owner, 'FX268-E4', 'f268 owner', 'Owner', 'full_time', 'shopfloor', DATE '2020-01-01', NULL);

    -- ══════════════ V18 · V20(字典空着)══════════════
    RAISE NOTICE 'fixture 268 · V18 · V20 (empty)';
    v_n := pg_temp.f268_get(u_vw, $q$SELECT to_jsonb(count(*)) FROM pending_values WHERE value_code = 'V18' AND item_code = 'inspection_templates'$q$)::bigint;
    IF (v_n <> 1) IS NOT FALSE THEN RAISE EXCEPTION 'FIXTURE 268 V18: with no checklist, V18 is one row (got %)', v_n; END IF;
    v_n := pg_temp.f268_get(u_vw, $q$SELECT to_jsonb(count(*)) FROM pending_values WHERE value_code = 'V20' AND item_code = 'environmental_parameters'$q$)::bigint;
    IF (v_n <> 1) IS NOT FALSE THEN RAISE EXCEPTION 'FIXTURE 268 V20: with no parameter, V20 is one row (got %)', v_n; END IF;
    v_n := pg_temp.f268_get(u_none, $q$SELECT to_jsonb(count(*)) FROM pending_values WHERE value_code IN ('V18', 'V20')$q$)::bigint;
    IF (v_n <> 0) IS NOT FALSE THEN RAISE EXCEPTION 'FIXTURE 268 V18: V18 / V20 read module.safety.view'; END IF;

    -- ══════════════ TPL ══════════════
    RAISE NOTICE 'fixture 268 · TPL';
    v_msg := pg_temp.f268_do(u_vw, $q$SELECT save_inspection_template(NULL, 'FX268-T1', 'x', 'y', '["a"]'::jsonb)$q$);
    PERFORM pg_temp.f268_expect('TPL no edit code', v_msg, 'PERMISSION_DENIED|module.safety.edit');
    v_msg := pg_temp.f268_do(u_ed, $q$SELECT save_inspection_template(NULL, '  ', 'x', 'y', '["a"]'::jsonb)$q$);
    PERFORM pg_temp.f268_expect('TPL code', v_msg, 'INSPECTION_TEMPLATE_CODE_REQUIRED');
    v_msg := pg_temp.f268_do(u_ed, $q$SELECT save_inspection_template(NULL, 'bad code!', 'x', 'y', '["a"]'::jsonb)$q$);
    PERFORM pg_temp.f268_expect('TPL code shape', v_msg, 'INSPECTION_TEMPLATE_CODE_INVALID|BAD CODE!');
    v_msg := pg_temp.f268_do(u_ed, $q$SELECT save_inspection_template(NULL, 'FX268-T1', ' ', 'y', '["a"]'::jsonb)$q$);
    PERFORM pg_temp.f268_expect('TPL name', v_msg, 'INSPECTION_TEMPLATE_NAME_REQUIRED');
    v_msg := pg_temp.f268_do(u_ed, $q$SELECT save_inspection_template(NULL, 'FX268-T1', 'x', NULL, '["a"]'::jsonb)$q$);
    PERFORM pg_temp.f268_expect('TPL area', v_msg, 'INSPECTION_TEMPLATE_AREA_REQUIRED');
    v_msg := pg_temp.f268_do(u_ed, $q$SELECT save_inspection_template(NULL, 'FX268-T1', 'x', 'y', '["a"]'::jsonb, 0)$q$);
    PERFORM pg_temp.f268_expect('TPL frequency', v_msg, 'INSPECTION_TEMPLATE_FREQUENCY_INVALID');
    v_msg := pg_temp.f268_do(u_ed, $q$SELECT save_inspection_template(NULL, 'FX268-T1', 'x', 'y', '[]'::jsonb)$q$);
    PERFORM pg_temp.f268_expect('TPL items', v_msg, 'INSPECTION_TEMPLATE_ITEMS_REQUIRED');
    v_msg := pg_temp.f268_do(u_ed, $q$SELECT save_inspection_template(NULL, 'FX268-T1', 'x', 'y', '["a", "  "]'::jsonb)$q$);
    PERFORM pg_temp.f268_expect('TPL blank item', v_msg, 'INSPECTION_TEMPLATE_ITEM_BLANK|2');
    IF (EXISTS (SELECT 1 FROM inspection_templates)) IS NOT FALSE THEN RAISE EXCEPTION 'FIXTURE 268 TPL: a refused save wrote a row'; END IF;
    -- 三项的清单(每 7 天巡一次)
    v_j := pg_temp.f268_get(u_ed, $q$SELECT save_inspection_template(NULL, 'fx268-t1', 'Discharge bay weekly', 'Discharge bay',
               '["Extinguishers in place and charged", "Cells stored dry, off the floor", "Emergency stop tested"]'::jsonb, 7)$q$);
    t1 := (v_j ->> 'template_id')::uuid;
    IF (v_j ->> 'code' <> 'FX268-T1' OR (SELECT count(*) FROM inspection_template_items WHERE template_id = t1) <> 3) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 268 TPL: a template with three ordered items (code upper-cased): %', v_j; END IF;
    v_msg := pg_temp.f268_do(u_ed, $q$SELECT save_inspection_template(NULL, 'FX268-T1', 'dup', 'y', '["a"]'::jsonb)$q$);
    PERFORM pg_temp.f268_expect('TPL code taken', v_msg, 'INSPECTION_TEMPLATE_CODE_TAKEN|FX268-T1');
    v_msg := pg_temp.f268_do(u_ed, $q$INSERT INTO inspection_templates (code, name, area) VALUES ('FX268-X', 'x', 'y')$q$);
    PERFORM pg_temp.f268_expect('TPL direct insert', v_msg, 'INSPECTION_TEMPLATE_THROUGH_FUNCTION_ONLY');
    v_msg := pg_temp.f268_do(u_ed, format($q$UPDATE inspection_template_items SET item_text = 'sneaky' WHERE template_id = %L$q$, t1));
    PERFORM pg_temp.f268_expect('TPL direct item update', v_msg, 'INSPECTION_TEMPLATE_THROUGH_FUNCTION_ONLY');
    BEGIN
        DELETE FROM inspection_templates WHERE id = t1;
        RAISE EXCEPTION 'FIXTURE 268 TPL: a template must not be deletable, even by the owner';
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.f268_expect('TPL delete (owner)', SQLERRM, 'INSPECTION_TEMPLATE_NOT_DELETABLE');
    END;
    v_j := pg_temp.f268_get(u_ed, $q$SELECT save_inspection_template(NULL, 'FX268-T2', 'Cutting station daily', 'Cutting station', '["Fume extraction running", "Guard closed"]'::jsonb, 1)$q$);
    t2 := (v_j ->> 'template_id')::uuid;
    v_j := pg_temp.f268_get(u_ed, $q$SELECT save_inspection_template(NULL, 'FX268-T3', 'Store room', 'Store', '["Racks anchored"]'::jsonb)$q$);
    t_nofreq := (v_j ->> 'template_id')::uuid;
    v_j := pg_temp.f268_get(u_ed, $q$SELECT save_inspection_template(NULL, 'FX268-OFF', 'Retired checklist', 'Old bay', '["n/a"]'::jsonb, 3, false)$q$);
    t_off := (v_j ->> 'template_id')::uuid;

    -- ══════════════ NUM + RUN ══════════════
    RAISE NOTICE 'fixture 268 · NUM · RUN';
    v_msg := pg_temp.f268_do(u_vw, format($q$SELECT record_inspection_run(%L, now(), %L, pg_temp.f268_results(3))$q$, t1, e_ed));
    PERFORM pg_temp.f268_expect('RUN no edit code', v_msg, 'PERMISSION_DENIED|module.safety.edit');
    v_msg := pg_temp.f268_do(u_ed, format($q$SELECT record_inspection_run(NULL, now(), %L, pg_temp.f268_results(3))$q$, e_ed));
    PERFORM pg_temp.f268_expect('RUN template', v_msg, 'INSPECTION_TEMPLATE_REQUIRED');
    v_msg := pg_temp.f268_do(u_ed, format($q$SELECT record_inspection_run(%L, NULL, %L, pg_temp.f268_results(3))$q$, t1, e_ed));
    PERFORM pg_temp.f268_expect('RUN time', v_msg, 'INSPECTION_TIME_REQUIRED');
    v_msg := pg_temp.f268_do(u_ed, format($q$SELECT record_inspection_run(%L, now(), NULL, pg_temp.f268_results(3))$q$, t1));
    PERFORM pg_temp.f268_expect('RUN inspector', v_msg, 'INSPECTION_INSPECTOR_REQUIRED');
    v_msg := pg_temp.f268_do(u_ed, format($q$SELECT record_inspection_run(%L, now(), %L, pg_temp.f268_results(1))$q$, t_off, e_ed));
    PERFORM pg_temp.f268_expect('RUN inactive template', v_msg, 'INSPECTION_TEMPLATE_INACTIVE|FX268-OFF');
    v_msg := pg_temp.f268_do(u_ed, format($q$SELECT record_inspection_run(%L, now(), %L, pg_temp.f268_results(4))$q$, t1, e_ed));
    PERFORM pg_temp.f268_expect('RUN unknown item', v_msg, 'INSPECTION_RESULT_UNKNOWN_ITEM|4');
    v_msg := pg_temp.f268_do(u_ed, format($q$SELECT record_inspection_run(%L, now(), %L, pg_temp.f268_results(3) || '[{"position": 2, "result": "pass"}]'::jsonb)$q$, t1, e_ed));
    PERFORM pg_temp.f268_expect('RUN duplicate', v_msg, 'INSPECTION_RESULT_DUPLICATE|2');
    v_msg := pg_temp.f268_do(u_ed, format($q$SELECT record_inspection_run(%L, now(), %L, '[{"position": 1, "result": "ok"}, {"position": 2, "result": "pass"}, {"position": 3, "result": "pass"}]'::jsonb)$q$, t1, e_ed));
    PERFORM pg_temp.f268_expect('RUN invalid result', v_msg, 'INSPECTION_RESULT_INVALID|1|ok');
    v_msg := pg_temp.f268_do(u_ed, format($q$SELECT record_inspection_run(%L, now(), %L, '[{"position": 1, "result": "fail", "note": " "}, {"position": 2, "result": "pass"}, {"position": 3, "result": "pass"}]'::jsonb)$q$, t1, e_ed));
    PERFORM pg_temp.f268_expect('RUN fail without a note', v_msg, 'INSPECTION_FAIL_NOTE_REQUIRED|1');
    v_msg := pg_temp.f268_do(u_ed, format($q$SELECT record_inspection_run(%L, now(), %L, pg_temp.f268_results(2))$q$, t1, e_ed));
    PERFORM pg_temp.f268_expect('RUN missing item', v_msg, 'INSPECTION_RESULT_MISSING|3');
    v_msg := pg_temp.f268_do(u_ed, format($q$SELECT record_inspection_run(%L, now() + interval '1 hour', %L, pg_temp.f268_results(3))$q$, t1, e_ed));
    PERFORM pg_temp.f268_expect('RUN future time', v_msg, 'INSPECTION_TIME_IN_FUTURE|%');
    IF (EXISTS (SELECT 1 FROM inspection_runs) OR EXISTS (SELECT 1 FROM inspection_results)) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 268 RUN: a refused run wrote a row'; END IF;
    -- 一次:第 2 项不合格(带说明)、第 3 项不适用;再一次全合格
    v_j := pg_temp.f268_get(u_ed, format($q$SELECT record_inspection_run(%L, now() - interval '2 hours', %L, pg_temp.f268_results(3, 2, 3), p_notes => 'f268 morning round')$q$, t1, e_ed));
    r1 := (v_j ->> 'run_id')::uuid; v_code1 := v_j ->> 'code';
    v_j := pg_temp.f268_get(u_ed, format($q$SELECT record_inspection_run(%L, now() - interval '1 hour', %L, pg_temp.f268_results(2))$q$, t2, e_ed));
    r2 := (v_j ->> 'run_id')::uuid; v_code2 := v_j ->> 'code';
    IF (v_code1 !~ ('^INS-' || extract(year FROM CURRENT_DATE)::int || '-[0-9]{4,}$')
       OR split_part(v_code2, '-', 3)::int <> split_part(v_code1, '-', 3)::int + 1) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 268 NUM: INS-YYYY-NNNN, gapless (% then %)', v_code1, v_code2; END IF;
    IF ((SELECT string_agg(position || ':' || result, ',' ORDER BY position) FROM inspection_results WHERE run_id = r1) <> '1:pass,2:fail,3:na'
       OR (SELECT note FROM inspection_results WHERE run_id = r1 AND position = 2) <> 'f268 failed item 2'
       OR (SELECT item_text FROM inspection_results WHERE run_id = r1 AND position = 2) <> 'Cells stored dry, off the floor') IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 268 RUN: pass / fail with its note / n/a stored with the item text copied'; END IF;
    v_j := pg_temp.f268_get(u_vw, format($q$SELECT to_jsonb(r) FROM inspection_run_rows r WHERE r.id = %L$q$, r1));
    IF ((v_j ->> 'pass_count')::int <> 1 OR (v_j ->> 'fail_count')::int <> 1 OR (v_j ->> 'na_count')::int <> 1
       OR v_j ->> 'template_name' <> 'Discharge bay weekly' OR COALESCE(v_j ->> 'inspector_label', '') NOT LIKE 'FX268-E1%') IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 268 RUN: the run row counts its results and names the checklist and inspector: %', v_j; END IF;
    v_n := pg_temp.f268_get(u_none, $q$SELECT to_jsonb(count(*)) FROM inspection_run_rows$q$)::bigint;
    IF (v_n <> 0) IS NOT FALSE THEN RAISE EXCEPTION 'FIXTURE 268 RUN: a reader without module.safety.view reads no run'; END IF;
    -- 改清单:改第 2 项的字、删第 3 项、改名字 —— 第 1 项那一行不动;过去那一次一个字都不变
    SELECT id INTO v_n FROM inspection_template_items WHERE template_id = t1 AND position = 1;
    v_j := pg_temp.f268_get(u_ed, format($q$SELECT save_inspection_template(%L, 'FX268-T1', 'Discharge bay weekly (rev 2)', 'Discharge bay',
               '["Extinguishers in place and charged", "Cells stored dry on racks"]'::jsonb, 7)$q$, t1));
    IF ((SELECT id FROM inspection_template_items WHERE template_id = t1 AND position = 1) <> v_n
       OR (SELECT string_agg(item_text, '|' ORDER BY position) FROM inspection_template_items WHERE template_id = t1)
            <> 'Extinguishers in place and charged|Cells stored dry on racks') IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 268 TPL: items realigned by position (unchanged row kept, changed text updated, extra item deleted)'; END IF;
    IF ((SELECT string_agg(item_text, '|' ORDER BY position) FROM inspection_results WHERE run_id = r1)
         <> 'Extinguishers in place and charged|Cells stored dry, off the floor|Emergency stop tested'
       OR (SELECT template_name FROM inspection_runs WHERE id = r1) <> 'Discharge bay weekly') IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 268 RUN: editing the checklist never rewrites a past run (Q13)'; END IF;

    -- ══════════════ IMMUT ══════════════
    RAISE NOTICE 'fixture 268 · IMMUT';
    v_msg := pg_temp.f268_do(u_ed, format($q$INSERT INTO inspection_runs (code, template_id, template_code, template_name, template_area, inspected_at, inspector_employee_id) VALUES ('INS-X', %L, 'x', 'x', 'x', now(), %L)$q$, t1, e_ed));
    PERFORM pg_temp.f268_expect('IMMUT direct run insert', v_msg, 'INSPECTION_THROUGH_FUNCTION_ONLY');
    v_msg := pg_temp.f268_do(u_ed, format($q$UPDATE inspection_runs SET notes = 'rewritten' WHERE id = %L$q$, r1));
    PERFORM pg_temp.f268_expect('IMMUT run update (staff)', v_msg, 'INSPECTION_RECORD_IMMUTABLE|inspection_runs|update');
    BEGIN
        UPDATE inspection_results SET result = 'pass' WHERE run_id = r1;
        RAISE EXCEPTION 'FIXTURE 268 IMMUT: the owner path must not rewrite a result';
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.f268_expect('IMMUT result update (owner)', SQLERRM, 'INSPECTION_RECORD_IMMUTABLE|inspection_results|update');
    END;
    BEGIN
        DELETE FROM inspection_runs WHERE id = r2;
        RAISE EXCEPTION 'FIXTURE 268 IMMUT: the owner path must not delete a run';
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.f268_expect('IMMUT run delete (owner)', SQLERRM, 'INSPECTION_RECORD_IMMUTABLE|inspection_runs|delete');
    END;

    -- ══════════════ FIND ══════════════
    RAISE NOTICE 'fixture 268 · FIND';
    v_msg := pg_temp.f268_do(u_ed, format($q$SELECT record_inspection_finding(%L, 1, 'x', %L)$q$, r1, e_owner));
    PERFORM pg_temp.f268_expect('FIND on a pass', v_msg, 'INSPECTION_FINDING_NOT_A_FAIL|1');
    v_msg := pg_temp.f268_do(u_ed, format($q$SELECT record_inspection_finding(%L, 2, '  ', %L)$q$, r1, e_owner));
    PERFORM pg_temp.f268_expect('FIND action', v_msg, 'INSPECTION_FINDING_ACTION_REQUIRED');
    v_msg := pg_temp.f268_do(u_ed, format($q$SELECT record_inspection_finding(%L, 2, 'x', NULL)$q$, r1));
    PERFORM pg_temp.f268_expect('FIND owner', v_msg, 'INSPECTION_FINDING_OWNER_REQUIRED');
    v_msg := pg_temp.f268_do(u_ed, format($q$SELECT record_inspection_finding(%L, 9, 'x', %L)$q$, r1, e_owner));
    PERFORM pg_temp.f268_expect('FIND unknown item', v_msg, 'INSPECTION_RESULT_UNKNOWN_ITEM|9');
    v_msg := pg_temp.f268_do(u_vw, format($q$SELECT record_inspection_finding(%L, 2, 'x', %L)$q$, r1, e_owner));
    PERFORM pg_temp.f268_expect('FIND needs the edit code', v_msg, 'PERMISSION_DENIED|module.safety.edit');
    v_j := pg_temp.f268_get(u_ed, format($q$SELECT record_inspection_finding(%L, 2, 'Move the cells onto racks and dry the floor', %L, %L)$q$, r1, e_owner, v_today + 3));
    f1 := (v_j ->> 'finding_id')::uuid;
    v_j := pg_temp.f268_get(u_ed, format($q$SELECT record_inspection_finding(%L, 2, 'Fix the roof leak above the bay', %L)$q$, r1, e_owner));
    f2 := (v_j ->> 'finding_id')::uuid;
    IF ((SELECT due_date FROM inspection_findings WHERE id = f2) IS NOT NULL) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 268 FIND: no default due date (Q14)'; END IF;
    v_j := pg_temp.f268_get(u_vw, format($q$SELECT jsonb_agg(o.item_id ORDER BY o.item_id) FROM operations_now o WHERE o.item_type = 'inspection_finding_open' AND o.doc_kind = %L$q$, r1::text));
    IF (jsonb_array_length(COALESCE(v_j, '[]'::jsonb)) <> 2) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 268 FIND: both open findings are on the reminder (doc_kind = the run): %', v_j; END IF;
    v_n := pg_temp.f268_get(u_none, $q$SELECT to_jsonb(count(*)) FROM operations_now o WHERE o.item_type LIKE 'inspection%'$q$)::bigint;
    IF (v_n <> 0) IS NOT FALSE THEN RAISE EXCEPTION 'FIXTURE 268 FIND: the inspection reminders read module.safety.view'; END IF;
    v_msg := pg_temp.f268_do(u_ed, format($q$UPDATE inspection_findings SET corrective_action = 'rewritten' WHERE id = %L$q$, f1));
    PERFORM pg_temp.f268_expect('FIND direct update (staff)', v_msg, 'INSPECTION_THROUGH_FUNCTION_ONLY');
    BEGIN
        UPDATE inspection_findings SET corrective_action = 'rewritten by the owner' WHERE id = f1;
        RAISE EXCEPTION 'FIXTURE 268 FIND: the owner path must not rewrite a finding';
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.f268_expect('FIND owner rewrite', SQLERRM, 'INSPECTION_FINDING_IMMUTABLE');
    END;

    -- ══════════════ TASK ══════════════
    RAISE NOTICE 'fixture 268 · TASK';
    v_msg := pg_temp.f268_do(u_noemp, format($q$SELECT raise_inspection_finding_task(%L)$q$, f1));
    PERFORM pg_temp.f268_expect('TASK without an employee', v_msg, 'INSPECTION_TASK_NEEDS_EMPLOYEE');
    v_msg := pg_temp.f268_do(u_vw, format($q$SELECT raise_inspection_finding_task(%L)$q$, f1));
    PERFORM pg_temp.f268_expect('TASK without a task code', v_msg, 'PERMISSION_DENIED|module.tasks.view');
    v_msg := pg_temp.f268_do(u_none, format($q$SELECT raise_inspection_finding_task(%L)$q$, f1));
    PERFORM pg_temp.f268_expect('TASK needs the safety view', v_msg, 'PERMISSION_DENIED|module.safety.view');
    v_j := pg_temp.f268_get(u_vwt, format($q$SELECT raise_inspection_finding_task(%L)$q$, f1));
    v_task := (v_j ->> 'task_id')::uuid; v_task_code := v_j ->> 'task_code';
    IF ((SELECT task_id FROM inspection_findings WHERE id = f1) IS DISTINCT FROM v_task
       OR (SELECT owner_id FROM tasks WHERE id = v_task) IS DISTINCT FROM e_vwt
       OR (SELECT task_type FROM tasks WHERE id = v_task) <> 'personal'
       OR COALESCE((SELECT title FROM tasks WHERE id = v_task), '') NOT LIKE v_code1 || ' · 2. Cells stored dry, off the floor%'
       OR (SELECT description FROM tasks WHERE id = v_task) <> 'Move the cells onto racks and dry the floor'
       OR (SELECT due_date FROM tasks WHERE id = v_task) IS DISTINCT FROM v_today + 3) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 268 TASK: a personal task for whoever pressed it, linked from the finding: %', (SELECT to_jsonb(t) FROM tasks t WHERE id = v_task); END IF;
    v_msg := pg_temp.f268_do(u_ed, format($q$SELECT raise_inspection_finding_task(%L)$q$, f1));
    PERFORM pg_temp.f268_expect('TASK twice', v_msg, 'INSPECTION_TASK_ALREADY_RAISED|' || v_task_code);
    -- 那张任务是按下的人自己的私人任务:他读得到,别人读不到(任务模块自己的规矩)
    v_n := pg_temp.f268_get(u_vwt, format($q$SELECT to_jsonb(count(*)) FROM tasks WHERE id = %L$q$, v_task))::bigint;
    v_n2 := pg_temp.f268_get(u_ed, format($q$SELECT to_jsonb(count(*)) FROM tasks WHERE id = %L$q$, v_task))::bigint;
    IF (v_n <> 1 OR v_n2 <> 0) IS NOT FALSE THEN RAISE EXCEPTION 'FIXTURE 268 TASK: the task is the presser''s own (% / %)', v_n, v_n2; END IF;
    -- 关掉那张任务(它的主人自己关)—— 发现照旧开着、提醒照旧在
    v_msg := pg_temp.f268_do(u_vwt, format($q$UPDATE tasks SET status = 'done' WHERE id = %L$q$, v_task));
    PERFORM pg_temp.f268_expect('TASK closed by its owner', v_msg, 'OK');
    IF ((SELECT status FROM tasks WHERE id = v_task) <> 'done') IS NOT FALSE THEN RAISE EXCEPTION 'FIXTURE 268 TASK: the task did not close'; END IF;
    v_j := pg_temp.f268_get(u_vw, format($q$SELECT to_jsonb(f) FROM inspection_finding_rows f WHERE f.id = %L$q$, f1));
    IF (NOT (v_j ->> 'is_open')::boolean OR v_j ->> 'task_code' <> v_task_code) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 268 TASK: closing the task does not close the finding (Q14): %', v_j; END IF;
    v_n := pg_temp.f268_get(u_vw, format($q$SELECT to_jsonb(count(*)) FROM operations_now WHERE item_type = 'inspection_finding_open' AND item_id = %L$q$, f1))::bigint;
    IF (v_n <> 1) IS NOT FALSE THEN RAISE EXCEPTION 'FIXTURE 268 TASK: the finding stays on the reminder after its task is closed'; END IF;
    -- 任务模块一行不改:任务表没有一列、没有一支(非内部的)触发器说到巡检 —— 发现指着任务的那条外键是 PostgreSQL 自己挂的内部触发器,不算
    IF (EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'tasks' AND column_name ~ 'inspection|finding')
       OR EXISTS (SELECT 1 FROM pg_trigger g WHERE g.tgrelid = 'public.tasks'::regclass AND NOT g.tgisinternal
                     AND pg_get_triggerdef(g.oid) ~ 'inspection')) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 268 TASK: the tasks module is unchanged'; END IF;
    -- 关闭发现:要写做了什么、只关一次;关了之后提醒消失、不再建任务
    v_msg := pg_temp.f268_do(u_ed, format($q$SELECT close_inspection_finding(%L, '  ')$q$, f1));
    PERFORM pg_temp.f268_expect('FIND close needs a note', v_msg, 'INSPECTION_FINDING_CLOSE_NOTE_REQUIRED');
    v_msg := pg_temp.f268_do(u_vw, format($q$SELECT close_inspection_finding(%L, 'x')$q$, f1));
    PERFORM pg_temp.f268_expect('FIND close needs the edit code', v_msg, 'PERMISSION_DENIED|module.safety.edit');
    v_msg := pg_temp.f268_do(u_ed, format($q$SELECT close_inspection_finding(%L, 'Cells moved to racks 3–4; floor dried and coated')$q$, f1));
    PERFORM pg_temp.f268_expect('FIND close', v_msg, 'OK');
    v_msg := pg_temp.f268_do(u_ed, format($q$SELECT close_inspection_finding(%L, 'again')$q$, f1));
    PERFORM pg_temp.f268_expect('FIND close twice', v_msg, 'INSPECTION_FINDING_ALREADY_CLOSED');
    v_n := pg_temp.f268_get(u_vw, format($q$SELECT to_jsonb(count(*)) FROM operations_now WHERE item_type = 'inspection_finding_open' AND item_id = %L$q$, f1))::bigint;
    IF (v_n <> 0) IS NOT FALSE THEN RAISE EXCEPTION 'FIXTURE 268 FIND: a closed finding leaves the reminder'; END IF;
    v_msg := pg_temp.f268_do(u_vwt, format($q$SELECT raise_inspection_finding_task(%L)$q$, f1));
    PERFORM pg_temp.f268_expect('TASK on a closed finding', v_msg, 'INSPECTION_FINDING_ALREADY_CLOSED');
    BEGIN
        UPDATE inspection_finding_closures SET what_was_done = 'rewritten' WHERE finding_id = f1;
        RAISE EXCEPTION 'FIXTURE 268 FIND: a closure must not be rewritten';
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.f268_expect('FIND closure immutable', SQLERRM, 'INSPECTION_RECORD_IMMUTABLE|inspection_finding_closures|update');
    END;

    -- ══════════════ CORR ══════════════
    RAISE NOTICE 'fixture 268 · CORR';
    v_msg := pg_temp.f268_do(u_ed, format($q$SELECT record_inspection_run(%L, now(), %L, pg_temp.f268_results(1), p_correction_reason => 'x')$q$, t_nofreq, e_ed));
    PERFORM pg_temp.f268_expect('CORR reason without a run', v_msg, 'INSPECTION_CORRECTION_NEEDS_RUN');
    v_msg := pg_temp.f268_do(u_ed, format($q$SELECT record_inspection_run(%L, now(), %L, pg_temp.f268_results(2), p_corrects_run_id => %L)$q$, t2, e_ed, r2));
    PERFORM pg_temp.f268_expect('CORR without a reason', v_msg, 'INSPECTION_CORRECTION_REASON_REQUIRED');
    v_msg := pg_temp.f268_do(u_ed, format($q$SELECT record_inspection_run(%L, now(), %L, pg_temp.f268_results(2), p_corrects_run_id => gen_random_uuid(), p_correction_reason => 'x')$q$, t2, e_ed));
    PERFORM pg_temp.f268_expect('CORR unknown run', v_msg, 'INSPECTION_RUN_NOT_FOUND|%');
    v_j := pg_temp.f268_get(u_ed, format($q$SELECT record_inspection_run(%L, now() - interval '30 minutes', %L, pg_temp.f268_results(2, 1),
               p_corrects_run_id => %L, p_correction_reason => 'The guard was found open — recorded as pass by mistake')$q$, t2, e_ed, r2));
    r_c := (v_j ->> 'run_id')::uuid;
    v_j := pg_temp.f268_get(u_vw, format($q$SELECT to_jsonb(r) FROM inspection_run_rows r WHERE r.id = %L$q$, r2));
    IF (v_j ->> 'corrected_by_run_code' IS DISTINCT FROM (SELECT code FROM inspection_runs WHERE id = r_c)
       OR (SELECT corrects_run_id FROM inspection_runs WHERE id = r_c) <> r2
       OR (SELECT string_agg(result, ',' ORDER BY position) FROM inspection_results WHERE run_id = r2) <> 'pass,pass') IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 268 CORR: the corrected run is unchanged and names its correction: %', v_j; END IF;
    v_msg := pg_temp.f268_do(u_ed, format($q$SELECT record_inspection_run(%L, now(), %L, pg_temp.f268_results(2), p_corrects_run_id => %L, p_correction_reason => 'again')$q$, t2, e_ed, r2));
    PERFORM pg_temp.f268_expect('CORR twice', v_msg, 'INSPECTION_RUN_ALREADY_CORRECTED|%');
    -- 更正的那一次(r_c)第 1 项不合格 → 它上面照收发现。"被更正过的一次不再收新的发现"要一项不合格的被更正巡检 —— r2 全合格,
    --   所以更正 r1(它第 2 项不合格),再往 r1 上记一条 → INSPECTION_RUN_SUPERSEDED(守卫判【行】,对每一个写入者都成立)。
    v_j := pg_temp.f268_get(u_ed, format($q$SELECT record_inspection_finding(%L, 1, 'Close and lock the guard', %L)$q$, r_c, e_owner));
    v_j := pg_temp.f268_get(u_ed, format($q$SELECT record_inspection_run(%L, now() - interval '90 minutes', %L, pg_temp.f268_results(2, 2),
               p_corrects_run_id => %L, p_correction_reason => 'Item 3 removed from the checklist; re-recorded')$q$, t1, e_ed, r1));
    v_msg := pg_temp.f268_do(u_ed, format($q$SELECT record_inspection_finding(%L, 2, 'late finding', %L)$q$, r1, e_owner));
    PERFORM pg_temp.f268_expect('CORR no new finding on a superseded run', v_msg, 'INSPECTION_RUN_SUPERSEDED|%');

    -- ══════════════ DUE ══════════════
    RAISE NOTICE 'fixture 268 · DUE';
    -- t1(7 天):最近一次没被更正的巡检就在 2 小时之前 → 不到期;t_nofreq:没有频率 → 不进来;t_off:停用 → 不进来
    v_j := COALESCE(pg_temp.f268_get(u_vw, $q$SELECT jsonb_object_agg(o.item_code, o.doc_kind) FROM operations_now o WHERE o.item_type = 'inspection_due'$q$), '{}');
    IF (v_j ? 'FX268-T1' OR v_j ? 'FX268-T3' OR v_j ? 'FX268-OFF') IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 268 DUE: just inspected / no frequency / inactive → no reminder: %', v_j; END IF;
    -- 一张新的(每 2 天)从没巡过 → never_run;一张(每 3 天)只在 5 天前巡过 → due,日子 = 那一天 + 3
    v_j := pg_temp.f268_get(u_ed, $q$SELECT save_inspection_template(NULL, 'FX268-NEW', 'New area', 'New', '["Walkway clear"]'::jsonb, 2)$q$);
    t3 := (v_j ->> 'template_id')::uuid;
    v_j := pg_temp.f268_get(u_ed, $q$SELECT save_inspection_template(NULL, 'FX268-OLD', 'Old area', 'Old', '["Walkway clear"]'::jsonb, 3)$q$);
    v_j := pg_temp.f268_get(u_ed, format($q$SELECT record_inspection_run(%L, now() - interval '5 days', %L, pg_temp.f268_results(1))$q$, (v_j ->> 'template_id')::uuid, e_ed));
    r_old := (v_j ->> 'run_id')::uuid;
    v_j := pg_temp.f268_get(u_vw, $q$SELECT jsonb_object_agg(o.item_code, jsonb_build_object('k', o.doc_kind, 'd', o.item_date)) FROM operations_now o WHERE o.item_type = 'inspection_due'$q$);
    IF (v_j -> 'FX268-NEW' ->> 'k' IS DISTINCT FROM 'never_run'
       OR v_j -> 'FX268-OLD' ->> 'k' IS DISTINCT FROM 'due'
       OR (v_j -> 'FX268-OLD' ->> 'd')::date <> ((SELECT inspected_at FROM inspection_runs WHERE id = r_old) AT TIME ZONE 'Asia/Singapore')::date + 3) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 268 DUE: never run → never_run; last run older than the frequency → due on last + frequency: %', v_j; END IF;
    v_j := pg_temp.f268_get(u_vw, format($q$SELECT to_jsonb(t) FROM inspection_template_rows t WHERE t.id = %L$q$, t1));
    IF (v_j ->> 'due_state' <> 'not_due' OR (v_j ->> 'last_inspected_at')::timestamptz IS NULL OR (v_j ->> 'run_count')::int <> 2) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 268 DUE: the checklist row reads the same due state as the reminder: %', v_j; END IF;

    -- ══════════════ V18 ══════════════
    RAISE NOTICE 'fixture 268 · V18';
    v_j := pg_temp.f268_get(u_vw, $q$SELECT jsonb_agg(p.item_code ORDER BY p.item_code) FROM pending_values p WHERE p.value_code = 'V18'$q$);
    IF (v_j IS DISTINCT FROM '["FX268-T3"]'::jsonb) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 268 V18: with checklists, one row per active checklist without a frequency: %', v_j; END IF;

    -- ══════════════ ENV ══════════════
    RAISE NOTICE 'fixture 268 · ENV';
    v_msg := pg_temp.f268_do(u_vw, $q$INSERT INTO environmental_parameters (code, name_en, name_zh, unit) VALUES ('hf_stack', 'HF', 'HF', 'mg/Nm3')$q$);
    PERFORM pg_temp.f268_expect('ENV dictionary needs the edit code', v_msg, 'new row violates row-level security%');
    v_msg := pg_temp.f268_do(u_ed, $q$INSERT INTO environmental_parameters (code, name_en, name_zh, unit, limit_value) VALUES ('hf_stack', 'HF', 'HF', 'mg/Nm3', 5)$q$);
    PERFORM pg_temp.f268_expect('ENV limit without basis', v_msg, 'ENV_LIMIT_NEEDS_BASIS');
    v_msg := pg_temp.f268_do(u_ed, $q$INSERT INTO environmental_parameters (code, name_en, name_zh, unit, limit_value, limit_basis, sort_order) VALUES
        ('hf_stack', 'Hydrogen fluoride at the stack', '烟囱氟化氢', 'mg/Nm3', 5, 'max', 10),
        ('ph_discharge', 'pH of discharged water', '排水 pH', 'pH', 6, 'min', 20),
        ('dust_stack', 'Dust at the stack', '烟囱粉尘', 'mg/Nm3', NULL, NULL, 30)$q$);
    PERFORM pg_temp.f268_expect('ENV dictionary rows', v_msg, 'OK');
    v_j := pg_temp.f268_get(u_vw, $q$SELECT jsonb_agg(p.item_code ORDER BY p.item_code) FROM pending_values p WHERE p.value_code = 'V20'$q$);
    IF (v_j IS DISTINCT FROM '["dust_stack"]'::jsonb) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 268 V20: with parameters, one row per active parameter without a limit: %', v_j; END IF;
    -- 结果:拒绝
    v_msg := pg_temp.f268_do(u_vw, $q$SELECT record_environmental_result('hf_stack', 'Stack A', CURRENT_DATE - 1, 'FRL', 'R-1', 1)$q$);
    PERFORM pg_temp.f268_expect('ENV needs the edit code', v_msg, 'PERMISSION_DENIED|module.safety.edit');
    v_msg := pg_temp.f268_do(u_ed, $q$SELECT record_environmental_result(NULL, 'Stack A', CURRENT_DATE - 1, 'FRL', 'R-1', 1)$q$);
    PERFORM pg_temp.f268_expect('ENV parameter', v_msg, 'ENV_PARAMETER_REQUIRED');
    v_msg := pg_temp.f268_do(u_ed, $q$SELECT record_environmental_result('hf_stack', ' ', CURRENT_DATE - 1, 'FRL', 'R-1', 1)$q$);
    PERFORM pg_temp.f268_expect('ENV sample point', v_msg, 'ENV_SAMPLE_POINT_REQUIRED');
    v_msg := pg_temp.f268_do(u_ed, $q$SELECT record_environmental_result('hf_stack', 'Stack A', NULL, 'FRL', 'R-1', 1)$q$);
    PERFORM pg_temp.f268_expect('ENV sampled on', v_msg, 'ENV_SAMPLED_ON_REQUIRED');
    v_msg := pg_temp.f268_do(u_ed, $q$SELECT record_environmental_result('hf_stack', 'Stack A', CURRENT_DATE - 1, NULL, 'R-1', 1)$q$);
    PERFORM pg_temp.f268_expect('ENV laboratory', v_msg, 'ENV_LABORATORY_REQUIRED');
    v_msg := pg_temp.f268_do(u_ed, $q$SELECT record_environmental_result('hf_stack', 'Stack A', CURRENT_DATE - 1, 'FRL', '', 1)$q$);
    PERFORM pg_temp.f268_expect('ENV report reference', v_msg, 'ENV_REPORT_REFERENCE_REQUIRED');
    v_msg := pg_temp.f268_do(u_ed, $q$SELECT record_environmental_result('hf_stack', 'Stack A', CURRENT_DATE - 1, 'FRL', 'R-1', NULL)$q$);
    PERFORM pg_temp.f268_expect('ENV value', v_msg, 'ENV_VALUE_REQUIRED');
    v_msg := pg_temp.f268_do(u_ed, $q$SELECT record_environmental_result('nox', 'Stack A', CURRENT_DATE - 1, 'FRL', 'R-1', 1)$q$);
    PERFORM pg_temp.f268_expect('ENV unknown parameter', v_msg, 'ENV_PARAMETER_UNKNOWN|nox');
    v_msg := pg_temp.f268_do(u_ed, $q$SELECT record_environmental_result('hf_stack', 'Stack A', CURRENT_DATE - 1, 'NOSUCH', 'R-1', 1)$q$);
    PERFORM pg_temp.f268_expect('ENV unknown laboratory', v_msg, 'ENV_LABORATORY_UNKNOWN|NOSUCH');
    v_msg := pg_temp.f268_do(u_ed, $q$SELECT record_environmental_result('hf_stack', 'Stack A', CURRENT_DATE + 5, 'FRL', 'R-1', 1)$q$);
    PERFORM pg_temp.f268_expect('ENV future date', v_msg, 'ENV_SAMPLED_IN_FUTURE|%');
    v_msg := pg_temp.f268_do(u_ed, $q$UPDATE environmental_parameters SET is_active = false WHERE code = 'dust_stack'$q$);
    v_msg := pg_temp.f268_do(u_ed, $q$SELECT record_environmental_result('dust_stack', 'Stack A', CURRENT_DATE - 1, 'FRL', 'R-1', 1)$q$);
    PERFORM pg_temp.f268_expect('ENV inactive parameter', v_msg, 'ENV_PARAMETER_INACTIVE|dust_stack');
    v_msg := pg_temp.f268_do(u_ed, $q$UPDATE environmental_parameters SET is_active = true WHERE code = 'dust_stack'$q$);
    -- 超标而没回答 NEA / 没写当场做了什么 → 按名拒,连事故也没有
    SELECT count(*) INTO v_n FROM incidents;
    v_msg := pg_temp.f268_do(u_ed, $q$SELECT record_environmental_result('hf_stack', 'Stack A', CURRENT_DATE - 1, 'FRL', 'R-2', 7.5)$q$);
    PERFORM pg_temp.f268_expect('ENV exceedance needs the NEA answer', v_msg, 'ENV_EXCEEDANCE_NEA_ANSWER_REQUIRED|7.5|max|5|mg/Nm3');
    v_msg := pg_temp.f268_do(u_ed, $q$SELECT record_environmental_result('hf_stack', 'Stack A', CURRENT_DATE - 1, 'FRL', 'R-2', 7.5, p_nea_reportable => true)$q$);
    PERFORM pg_temp.f268_expect('ENV exceedance needs the immediate action', v_msg, 'ENV_EXCEEDANCE_ACTION_REQUIRED');
    IF ((SELECT count(*) FROM incidents) <> v_n OR EXISTS (SELECT 1 FROM environmental_results)) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 268 ENV: a refused result wrote nothing (no incident either)'; END IF;
    -- 不判定(没有限值)· 在限值之内 · 超标(max)· 低于下限(min)
    v_j := pg_temp.f268_get(u_ed, $q$SELECT record_environmental_result('dust_stack', 'Stack A', CURRENT_DATE - 2, 'FRL', 'R-0', 12.3)$q$);
    er_nj := (v_j ->> 'result_id')::uuid;
    v_j := pg_temp.f268_get(u_ed, $q$SELECT record_environmental_result('hf_stack', 'Stack A', CURRENT_DATE - 2, 'FRL', 'R-1', 4.2)$q$);
    er_in := (v_j ->> 'result_id')::uuid;
    v_j := pg_temp.f268_get(u_ed, $q$SELECT record_environmental_result('hf_stack', 'Stack A', CURRENT_DATE - 1, 'FRL', 'R-2', 7.5,
               p_nea_reportable => true, p_immediate_action => 'Scrubber checked; line slowed pending re-test')$q$);
    er_ex := (v_j ->> 'result_id')::uuid; v_inc := (v_j ->> 'incident_id')::uuid;
    IF ((SELECT exceeds FROM environmental_results WHERE id = er_nj) IS NOT NULL OR (SELECT incident_id FROM environmental_results WHERE id = er_nj) IS NOT NULL
       OR (SELECT exceeds FROM environmental_results WHERE id = er_in) IS DISTINCT FROM false
       OR (SELECT exceeds FROM environmental_results WHERE id = er_ex) IS DISTINCT FROM true) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 268 ENV: not judged (no limit) · within · exceeds'; END IF;
    IF v_inc IS NULL OR (SELECT incident_id FROM environmental_results WHERE id = er_ex) <> v_inc
       OR (SELECT kind_code FROM incidents WHERE id = v_inc) <> 'emission_exceedance'
       OR NOT (SELECT nea_reportable FROM incidents WHERE id = v_inc)
       OR (SELECT immediate_action FROM incidents WHERE id = v_inc) <> 'Scrubber checked; line slowed pending re-test'
       OR (SELECT responsible_employee_id FROM incidents WHERE id = v_inc) IS DISTINCT FROM e_ed
       OR (SELECT occurred_at FROM incidents WHERE id = v_inc) <> ((CURRENT_DATE - 1)::timestamp AT TIME ZONE 'Asia/Singapore')
       OR COALESCE((SELECT what_happened FROM incidents WHERE id = v_inc), '') NOT LIKE 'Hydrogen fluoride at the stack at Stack A: 7.5 mg/Nm3 against a maximum limit of 5 mg/Nm3%'
       OR (SELECT count(*) FROM incidents) <> v_n + 1 THEN
        RAISE EXCEPTION 'FIXTURE 268 ENV: an exceedance opens one emission_exceedance incident in the same transaction: %', (SELECT to_jsonb(i) FROM incidents i WHERE id = v_inc); END IF;
    v_j := pg_temp.f268_get(u_ed, $q$SELECT record_environmental_result('ph_discharge', 'Outfall', CURRENT_DATE - 1, 'FRL', 'R-3', 5.5,
               p_nea_reportable => false, p_immediate_action => 'Discharge valve closed')$q$);
    er_min := (v_j ->> 'result_id')::uuid;
    IF ((SELECT exceeds FROM environmental_results WHERE id = er_min) IS DISTINCT FROM true OR (v_j ->> 'incident_id') IS NULL) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 268 ENV: below a minimum limit is an exceedance: %', v_j; END IF;
    v_j := pg_temp.f268_get(u_vw, format($q$SELECT jsonb_object_agg(r.id, r.judgement) FROM environmental_result_rows r WHERE r.id IN (%L, %L, %L)$q$, er_nj, er_in, er_ex));
    IF (v_j ->> er_nj::text <> 'not_judged' OR v_j ->> er_in::text <> 'within' OR v_j ->> er_ex::text <> 'exceeds') IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 268 ENV: the result rows read the judgement: %', v_j; END IF;
    -- 限值与单位抄下来了:改字典不改写过去的结果
    v_msg := pg_temp.f268_do(u_ed, $q$UPDATE environmental_parameters SET limit_value = 10, unit = 'mg/m3' WHERE code = 'hf_stack'$q$);
    PERFORM pg_temp.f268_expect('ENV limit changed', v_msg, 'OK');
    IF ((SELECT limit_value FROM environmental_results WHERE id = er_ex) <> 5 OR (SELECT unit FROM environmental_results WHERE id = er_ex) <> 'mg/Nm3'
       OR NOT (SELECT exceeds FROM environmental_results WHERE id = er_ex)) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 268 ENV: the limit in force is copied at entry and never rewritten'; END IF;
    -- 只追加
    v_msg := pg_temp.f268_do(u_ed, format($q$UPDATE environmental_results SET value = 1 WHERE id = %L$q$, er_ex));
    PERFORM pg_temp.f268_expect('ENV update (staff)', v_msg, 'ENV_RESULT_IMMUTABLE|update');
    BEGIN
        DELETE FROM environmental_results WHERE id = er_ex;
        RAISE EXCEPTION 'FIXTURE 268 ENV: the owner path must not delete a result';
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.f268_expect('ENV delete (owner)', SQLERRM, 'ENV_RESULT_IMMUTABLE|delete');
    END;
    v_msg := pg_temp.f268_do(u_ed, $q$INSERT INTO environmental_results (parameter_code, sample_point, sampled_on, laboratory_code, report_reference, value, unit) VALUES ('dust_stack', 'x', CURRENT_DATE, 'FRL', 'x', 1, 'x')$q$);
    PERFORM pg_temp.f268_expect('ENV direct insert', v_msg, 'ENV_RESULT_THROUGH_FUNCTION_ONLY');
    -- 更正:仍超标 → 指着同一件事故,不开第二件;没理由 / 有理由没引用按名拒
    v_msg := pg_temp.f268_do(u_ed, format($q$SELECT record_environmental_result('hf_stack', 'Stack A', CURRENT_DATE - 1, 'FRL', 'R-2b', 11, p_corrects_result_id => %L)$q$, er_ex));
    PERFORM pg_temp.f268_expect('ENV correction without a reason', v_msg, 'ENV_CORRECTION_REASON_REQUIRED');
    v_msg := pg_temp.f268_do(u_ed, $q$SELECT record_environmental_result('hf_stack', 'Stack A', CURRENT_DATE - 1, 'FRL', 'R-2b', 11, p_correction_reason => 'x')$q$);
    PERFORM pg_temp.f268_expect('ENV reason without a result', v_msg, 'ENV_CORRECTION_NEEDS_RESULT');
    SELECT count(*) INTO v_n FROM incidents;
    v_j := pg_temp.f268_get(u_ed, format($q$SELECT record_environmental_result('hf_stack', 'Stack A', CURRENT_DATE - 1, 'FRL', 'R-2b', 11,
               p_corrects_result_id => %L, p_correction_reason => 'Laboratory reissued the report with a corrected value')$q$, er_ex));
    er_cor := (v_j ->> 'result_id')::uuid;
    IF ((v_j ->> 'incident_id')::uuid IS DISTINCT FROM v_inc OR (SELECT count(*) FROM incidents) <> v_n
       OR (SELECT limit_value FROM environmental_results WHERE id = er_cor) <> 10) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 268 ENV: a still-exceeding correction cites the same incident, no second one: %', v_j; END IF;
    v_msg := pg_temp.f268_do(u_ed, format($q$SELECT record_environmental_result('hf_stack', 'Stack A', CURRENT_DATE - 1, 'FRL', 'R-2c', 1, p_corrects_result_id => %L, p_correction_reason => 'again')$q$, er_ex));
    PERFORM pg_temp.f268_expect('ENV correction twice', v_msg, 'ENV_RESULT_ALREADY_CORRECTED');
    -- 用过的代号冻住;名字照改
    v_msg := pg_temp.f268_do(u_ed, $q$UPDATE environmental_parameters SET code = 'hf' WHERE code = 'hf_stack'$q$);
    PERFORM pg_temp.f268_expect('ENV used code locked', v_msg, 'ENV_PARAMETER_CODE_LOCKED|hf_stack|3');
    v_msg := pg_temp.f268_do(u_ed, $q$DELETE FROM environmental_parameters WHERE code = 'hf_stack'$q$);
    PERFORM pg_temp.f268_expect('ENV used parameter not deleted', v_msg, 'ENV_PARAMETER_CODE_LOCKED|hf_stack|3');
    v_msg := pg_temp.f268_do(u_ed, $q$UPDATE environmental_parameters SET name_en = 'HF (stack)' WHERE code = 'hf_stack'$q$);
    PERFORM pg_temp.f268_expect('ENV rename', v_msg, 'OK');

    -- ══════════════ NCR ══════════════
    RAISE NOTICE 'fixture 268 · NCR';
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ268-S', 'f268 vendor', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, unit)
    VALUES ('ZZ268-BM', 'f268 modules', 'battery_material', true, 'black_mass', 'end_of_life', 'kg') RETURNING id INTO v_mat;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note)
    VALUES ('ZZ268-IB', v_mat, v_sup, 50, 50, 'kg', v_today - 3, 'other', 'fixture 268') RETURNING id INTO ib;
    v_j := pg_temp.f268_get(u_qe, format($q$SELECT open_ncr('inspection', 'Wet cells found on the discharge-bay inspection', p_inbound_batch_id => %L, p_inspection_finding_id => %L)$q$, ib, f2));
    IF (NOT EXISTS (SELECT 1 FROM batch_quality_hold(ib, NULL) h WHERE h.ncr_id = (v_j ->> 'ncr_id')::uuid)) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 268 NCR: an inspection-source NCR citing a finding about a batch opens the quality hold: %', v_j; END IF;
    v_j := pg_temp.f268_get(u_vw, format($q$SELECT to_jsonb(f) FROM inspection_finding_rows f WHERE f.id = %L$q$, f2));
    IF ((v_j ->> 'ncr_count')::int <> 1) IS NOT FALSE THEN RAISE EXCEPTION 'FIXTURE 268 NCR: the finding counts the NCR citing it: %', v_j; END IF;

    -- ══════════════ TRAIL ══════════════
    RAISE NOTICE 'fixture 268 · TRAIL';
    v_txt := (pg_temp.f268_get(u_vw, format($q$SELECT to_jsonb(string_agg(DISTINCT t.table_name, ',' ORDER BY t.table_name)) FROM record_trail('inspection_run', %L, 50) t$q$, r1)) #>> '{}');
    IF (v_txt NOT LIKE '%inspection_findings%' OR v_txt NOT LIKE '%inspection_results%' OR v_txt NOT LIKE '%inspection_runs%'
       OR v_txt NOT LIKE '%inspection_finding_closures%') IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 268 TRAIL: the run trail carries the run, its results, its findings and their closure: %', v_txt; END IF;
    v_txt := (pg_temp.f268_get(u_vw, format($q$SELECT to_jsonb(string_agg(DISTINCT t.table_name, ',' ORDER BY t.table_name)) FROM record_trail('inspection_template', %L, 50) t$q$, t1)) #>> '{}');
    IF (v_txt NOT LIKE '%inspection_template_items%' OR v_txt NOT LIKE '%inspection_templates%') IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 268 TRAIL: the checklist trail carries its items: %', v_txt; END IF;
    v_n := (pg_temp.f268_get(u_vw, $q$SELECT to_jsonb(count(*)) FROM record_trail('safety_environment', NULL, 50) t WHERE t.table_name = 'environmental_results'$q$))::bigint;
    IF (v_n < 5) IS NOT FALSE THEN RAISE EXCEPTION 'FIXTURE 268 TRAIL: the environment trail shows the results (got %)', v_n; END IF;
    v_msg := pg_temp.f268_do(u_none, $q$SELECT * FROM record_trail('safety_environment', NULL, 5)$q$);
    PERFORM pg_temp.f268_expect('TRAIL needs the safety view', v_msg, 'TRAIL_NOT_PERMITTED|safety_environment');

    RAISE NOTICE 'FIXTURE 268 全部通过: REG · F16 · TPL · NUM · RUN · IMMUT · FIND · TASK · CORR · DUE · V18 · ENV · V20 · NCR · TRAIL';
END $$;

ROLLBACK;
