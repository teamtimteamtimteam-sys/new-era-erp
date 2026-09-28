-- 234 HISTORY-1:每一次改动都记下谁做的、改之前是什么 —— 而记录本身改不动、读的人只看得见他该看的(2026-09-28)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】(HISTORY-1 Step 0 Q1–Q15 + HISTORY-0 Q1–Q30,Tim 2026-09-28 全部裁定)
--   A  写入:A1 新增 → 一行 INSERT,账号 + 写入时的员工 + authenticated,new 是整行;
--        A2 编辑 → changed_columns 只有改了的列,old/new 只含那几列、前后值对;
--        A3 改了等于没改 → 不写行;A4 删除 → 一行 DELETE,old 是整行
--   B  主键:B1 复合主键(role_permissions)→ row_key 两个键;B2 非 uuid 单列主键(laboratories.code)
--   C  无会话:C1 没有 JWT 的写 → no_session + 数据库角色(postgres);C2 service_role → db_role = service_role
--   D  change_log 本身:D1 anon / authenticated / service_role 的 SELECT / UPDATE / DELETE / TRUNCATE 全拒;
--        D2 属主的 UPDATE / DELETE / TRUNCATE → CHANGE_LOG_IMMUTABLE
--   E  历史表:E1 17 张全部拒 TRUNCATE;E2 task_history 与 work_order_history 拒 UPDATE / DELETE
--   F  TRUNCATE 一张被记录的表 → 一行 TRUNCATE
--   G  读法:没有 data.view_change_log → PERMISSION_DENIED
--   H  遮蔽(一个只持 data.view_change_log 的合成角色):H1 采购单历史的价格 → 受限标记,本来就空的留空,
--        不遮的列照常;H2 持 data.view_purchase_prices 的读者看得见;H3 自己那一行的月薪看得见、别人的受限;
--        H4 定价公式按方向:销售公式对只持采购价码的人受限、采购公式看得见;
--        H5 purchase_order_history_masked:无价格码的采购读者读到 NULL,基表价格列 42501
--   I  任务隐私:别人的个人任务 → 整行受限(row_restricted);归属人自己看得见;团队任务看得见
--   J  遮蔽名单完整性:目录零缺口;★ 注入"删掉一条规则" → missing_rule 出现
--   K  涂抹:只涂那个人的名单列(含 greeting_name),盖 redacted_at;匿名化那一句 UPDATE 自己的记录也涂到;
--        另一个人一个字不动;其余任何 UPDATE 被拒
--   L  个人数据导出:my_record_changes 带着自己那一行的改动,改的人只给员工名,不带账号 id / 邮箱
--   M  set_role_permissions:只记增删的那两个码;重复的码被吸收
--   N  账号事件:停用 / 启用记下;最后一个管理员、停用自己、已停用、未停用四种拒绝;建 / 回滚删除;无权拒
--   O  覆盖:目录零缺口;★ 注入"一张没绑也没豁免的表"与"一张豁免了却绑着的表" → 各自出现
--
-- 自带数据(README 第 2 条):账号、角色、员工、部门、实验室、采购单、任务全部本支自建;
-- change_log 里本支读的每一行都由本支写(遮蔽那几臂直接 INSERT 合成的记录 —— 它问的是读法,不是写法)。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '180s';

CREATE FUNCTION pg_temp.f234_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims',
                      CASE WHEN p_user IS NULL THEN '' ELSE format('{"sub":"%s","role":"authenticated"}', p_user) END, true)
$f$;

-- 以某个角色(authenticated / anon / service_role)跑一句,返回 'OK' 或那一句拒绝
CREATE FUNCTION pg_temp.f234_try(p_user uuid, p_sql text, p_role text DEFAULT 'authenticated') RETURNS text
LANGUAGE plpgsql AS $f$
BEGIN
    PERFORM pg_temp.f234_as(p_user);
    EXECUTE format('SET LOCAL ROLE %I', p_role);
    IF current_user IS DISTINCT FROM p_role OR auth.uid() IS DISTINCT FROM p_user THEN
        RAISE EXCEPTION 'FIXTURE 234 布景失败:身份没有切过去(%, %)', current_user, auth.uid(); END IF;
    EXECUTE p_sql;
    EXECUTE 'RESET ROLE';
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    RETURN SQLERRM;
END;
$f$;

-- 以某人的身份(authenticated)读一个 jsonb
CREATE FUNCTION pg_temp.f234_json(p_user uuid, p_sql text) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v jsonb;
BEGIN
    PERFORM pg_temp.f234_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    RETURN v;
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    RETURN jsonb_build_object('error', SQLERRM);
END;
$f$;

-- 以某人的身份读 change_log_rows 里某张表的全部行(jsonb 数组,seq 升序)
CREATE FUNCTION pg_temp.f234_read(p_user uuid, p_table text) RETURNS jsonb
LANGUAGE sql AS $f$
    SELECT pg_temp.f234_json(p_user, format(
        'SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.seq), ''[]''::jsonb) FROM change_log_rows(p_table => %L, p_limit => 200) r',
        p_table))
$f$;

DO $$
DECLARE
    k_restricted constant jsonb := '{"$restricted": true}'::jsonb;
    u_all uuid := gen_random_uuid();   -- 持全部码(含 data.view_change_log)
    u_m   uuid := gen_random_uuid();   -- 合成读者:data.view_change_log + module.tasks.view,别的数据码一个没有
    u_pp  uuid := gen_random_uuid();   -- 合成读者 + data.view_purchase_prices
    u_no  uuid := gen_random_uuid();   -- 一个码都不持
    u_buy uuid := gen_random_uuid();   -- 采购读者:module.purchasing.view,没有价格码
    u_hr  uuid := gen_random_uuid();   -- HR:module.hr.edit + view + action.anonymise_employee
    r_all uuid; r_m uuid; r_pp uuid; r_buy uuid; r_hr uuid; r_x uuid;
    e_all uuid := gen_random_uuid(); e_m uuid := gen_random_uuid(); e_hr uuid := gen_random_uuid();
    e_gone uuid := gen_random_uuid(); e_keep uuid := gen_random_uuid(); e_other uuid := gen_random_uuid();
    v_dep uuid; v_sup uuid; v_po uuid; v_task_p uuid; v_task_t uuid; v_task_mine uuid; v_wo uuid; v_th uuid;
    v_j jsonb; v_row jsonb; v_msg text; v_n int; v_seq bigint; v_base bigint;
    t text;
BEGIN
    -- ══════════════ 布景 ══════════════
    INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
        (u_all, 'fx234-all@test.local', now()), (u_m, 'fx234-m@test.local', now()),
        (u_pp, 'fx234-pp@test.local', now()), (u_no, 'fx234-no@test.local', now()),
        (u_buy, 'fx234-buy@test.local', now()), (u_hr, 'fx234-hr@test.local', now());
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx234-all','f','f',true) RETURNING id INTO r_all;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx234-m','f','f',true)   RETURNING id INTO r_m;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx234-pp','f','f',true)  RETURNING id INTO r_pp;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx234-buy','f','f',true) RETURNING id INTO r_buy;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx234-hr','f','f',true)  RETURNING id INTO r_hr;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_m, c FROM unnest(ARRAY['data.view_change_log', 'module.tasks.view']) c;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_pp, c FROM unnest(ARRAY['data.view_change_log', 'module.tasks.view', 'data.view_purchase_prices']) c;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_buy, 'module.purchasing.view');
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_hr, c FROM unnest(ARRAY['module.hr.edit', 'module.hr.view', 'action.anonymise_employee']) c;
    INSERT INTO user_roles (user_id, role_id) VALUES (u_all, r_all), (u_m, r_m), (u_pp, r_pp), (u_buy, r_buy), (u_hr, r_hr);
    INSERT INTO employees (id, code, legal_name, employment_type, work_category, hire_date, employment_status, user_id) VALUES
        (e_all, 'FX234-ALL', 'FX234 All Legal', 'full_time', 'office', DATE '2020-01-01', 'active', u_all),
        (e_m,   'FX234-M',   'FX234 Reader Legal', 'full_time', 'office', DATE '2020-01-01', 'active', u_m),
        (e_hr,  'FX234-HR',  'FX234 HR Legal', 'full_time', 'office', DATE '2020-01-01', 'active', u_hr);

    -- ══════════════ A · 新增 / 编辑 / 没改 / 删除(以 authenticated 身份,经 RLS)══════════════
    SELECT COALESCE(max(seq), 0) INTO v_base FROM change_log;
    v_msg := pg_temp.f234_try(u_all, 'INSERT INTO departments (code, name_en, name_zh, notes) VALUES (''FX234-D'', ''Dept'', ''部门'', ''before'')');
    IF v_msg IS DISTINCT FROM 'OK' THEN RAISE EXCEPTION 'FIXTURE 234A 布景失败:建部门 %', v_msg; END IF;
    SELECT id INTO v_dep FROM departments WHERE code = 'FX234-D';
    SELECT to_jsonb(c) INTO v_row FROM change_log c WHERE c.table_name = 'departments' AND c.seq > v_base ORDER BY c.seq DESC LIMIT 1;
    IF v_row IS NULL OR v_row->>'op' IS DISTINCT FROM 'INSERT' OR v_row->'row_key' IS DISTINCT FROM jsonb_build_object('id', v_dep)
       OR (v_row->>'actor_account')::uuid IS DISTINCT FROM u_all OR (v_row->>'actor_employee')::uuid IS DISTINCT FROM e_all
       OR v_row->>'actor_kind' IS DISTINCT FROM 'user' OR v_row->>'db_role' IS DISTINCT FROM 'authenticated'
       OR v_row->'old' IS DISTINCT FROM 'null'::jsonb OR v_row->'changed_columns' IS DISTINCT FROM 'null'::jsonb
       OR v_row->'new'->>'notes' IS DISTINCT FROM 'before' OR v_row->'new'->>'code' IS DISTINCT FROM 'FX234-D'
       OR (SELECT count(*) FROM jsonb_object_keys(v_row->'new')) IS DISTINCT FROM (SELECT count(*) FROM information_schema.columns
                                                                       WHERE table_schema = 'public' AND table_name = 'departments') THEN
        RAISE EXCEPTION 'FIXTURE 234A1 失败:新增应记一行 INSERT(账号 + 员工 + authenticated + 整行),实为 %', v_row;
    END IF;

    v_msg := pg_temp.f234_try(u_all, format('UPDATE departments SET notes = ''after'' WHERE id = %L', v_dep));
    SELECT to_jsonb(c) INTO v_row FROM change_log c WHERE c.table_name = 'departments' AND c.seq > v_base ORDER BY c.seq DESC LIMIT 1;
    IF v_msg IS DISTINCT FROM 'OK' OR v_row->>'op' IS DISTINCT FROM 'UPDATE'
       OR NOT (v_row->'changed_columns' ? 'notes')
       OR v_row->'old'->>'notes' IS DISTINCT FROM 'before' OR v_row->'new'->>'notes' IS DISTINCT FROM 'after'
       OR (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(v_row->'old') k)
          IS DISTINCT FROM (SELECT array_agg(k ORDER BY k) FROM jsonb_array_elements_text(v_row->'changed_columns') k)
       OR v_row->'old' ? 'code' THEN
        RAISE EXCEPTION 'FIXTURE 234A2 失败:编辑只记改了的列与前后值,实为 %', v_row;
    END IF;

    SELECT max(seq) INTO v_seq FROM change_log;
    v_msg := pg_temp.f234_try(u_all, format('UPDATE departments SET notes = notes WHERE id = %L', v_dep));
    IF v_msg IS DISTINCT FROM 'OK' OR (SELECT max(seq) FROM change_log) IS DISTINCT FROM v_seq THEN
        RAISE EXCEPTION 'FIXTURE 234A3 失败:改了等于没改不该写行(%)', v_msg;
    END IF;

    v_msg := pg_temp.f234_try(u_all, format('DELETE FROM departments WHERE id = %L', v_dep));
    SELECT to_jsonb(c) INTO v_row FROM change_log c WHERE c.table_name = 'departments' AND c.seq > v_base ORDER BY c.seq DESC LIMIT 1;
    IF v_msg IS DISTINCT FROM 'OK' OR v_row->>'op' IS DISTINCT FROM 'DELETE' OR v_row->'new' IS DISTINCT FROM 'null'::jsonb
       OR v_row->'old'->>'notes' IS DISTINCT FROM 'after' OR v_row->'old'->>'code' IS DISTINCT FROM 'FX234-D'
       OR v_row->'row_key' IS DISTINCT FROM jsonb_build_object('id', v_dep) THEN
        RAISE EXCEPTION 'FIXTURE 234A4 失败:删除应记一行 DELETE(old 是整行),实为 % / %', v_msg, v_row;
    END IF;

    -- ══════════════ B · 主键形状 ══════════════
    SELECT id INTO r_x FROM roles WHERE code = 'fx234-m';
    SELECT to_jsonb(c) INTO v_row FROM change_log c
     WHERE c.table_name = 'role_permissions' AND c.row_key = jsonb_build_object('role_id', r_x, 'permission_code', 'module.tasks.view');
    IF v_row IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 234B1 失败:复合主键 role_permissions 的 row_key 应为 {role_id, permission_code}';
    END IF;
    PERFORM pg_temp.f234_as(NULL);
    INSERT INTO laboratories (code, name_en, name_zh) VALUES ('FX234LAB', 'Lab', '实验室');
    SELECT to_jsonb(c) INTO v_row FROM change_log c WHERE c.table_name = 'laboratories' ORDER BY c.seq DESC LIMIT 1;
    IF v_row->'row_key' IS DISTINCT FROM '{"code": "FX234LAB"}'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 234B2 失败:非 uuid 主键的 row_key 应为 {"code": "FX234LAB"},实为 %', v_row->'row_key';
    END IF;

    -- ══════════════ C · 没有会话的写 ══════════════
    IF v_row->>'actor_kind' IS DISTINCT FROM 'no_session' OR v_row->'actor_account' IS DISTINCT FROM 'null'::jsonb
       OR v_row->'actor_employee' IS DISTINCT FROM 'null'::jsonb OR v_row->>'db_role' IS DISTINCT FROM session_user::text THEN
        RAISE EXCEPTION 'FIXTURE 234C1 失败:无会话的写应记 no_session + %,实为 %', session_user, v_row;
    END IF;
    v_msg := pg_temp.f234_try(NULL, 'UPDATE laboratories SET notes = ''svc'' WHERE code = ''FX234LAB''', 'service_role');
    SELECT to_jsonb(c) INTO v_row FROM change_log c WHERE c.table_name = 'laboratories' ORDER BY c.seq DESC LIMIT 1;
    IF v_msg IS DISTINCT FROM 'OK' OR v_row->>'actor_kind' IS DISTINCT FROM 'no_session' OR v_row->>'db_role' IS DISTINCT FROM 'service_role' THEN
        RAISE EXCEPTION 'FIXTURE 234C2 失败:service_role 的写应记 no_session + service_role,实为 % / %', v_msg, v_row;
    END IF;

    -- ══════════════ D · change_log 本身 ══════════════
    FOREACH t IN ARRAY ARRAY['anon', 'authenticated', 'service_role'] LOOP
        FOREACH v_msg IN ARRAY ARRAY['SELECT 1 FROM change_log LIMIT 1', 'UPDATE change_log SET db_role = ''x''',
                                     'DELETE FROM change_log', 'TRUNCATE change_log'] LOOP
            IF pg_temp.f234_try(CASE WHEN t = 'anon' THEN NULL ELSE u_all END, v_msg, t) NOT LIKE 'permission denied%' THEN
                RAISE EXCEPTION 'FIXTURE 234D1 失败:% 对 change_log 的「%」应被拒(permission denied),实为 %',
                    t, v_msg, pg_temp.f234_try(CASE WHEN t = 'anon' THEN NULL ELSE u_all END, v_msg, t);
            END IF;
        END LOOP;
    END LOOP;
    FOREACH v_msg IN ARRAY ARRAY['UPDATE change_log SET db_role = ''x'' WHERE seq = (SELECT max(seq) FROM change_log)',
                                 'DELETE FROM change_log WHERE seq = (SELECT max(seq) FROM change_log)',
                                 'TRUNCATE change_log'] LOOP
        BEGIN
            EXECUTE v_msg;
            RAISE EXCEPTION 'FIXTURE 234D2 失败:属主的「%」没有被拒', v_msg;
        EXCEPTION WHEN OTHERS THEN
            IF SQLERRM NOT LIKE 'CHANGE_LOG_IMMUTABLE%' THEN
                RAISE EXCEPTION 'FIXTURE 234D2 失败:属主的「%」应抛 CHANGE_LOG_IMMUTABLE,实为 %', v_msg, SQLERRM;
            END IF;
        END;
    END LOOP;

    -- ══════════════ E · 17 张历史表 ══════════════
    v_n := 0;
    FOREACH t IN ARRAY ARRAY['approval_log', 'customer_credit_history', 'employee_account_history', 'employment_history',
            'finance_settings_history', 'fixed_asset_history', 'fx_rate_history', 'price_history', 'pricing_formula_history',
            'processing_cost_entry_history', 'purchase_order_history', 'quote_history', 'sales_attribution_log',
            'sales_order_history', 'supplier_status_history', 'task_history', 'work_order_history'] LOOP
        BEGIN
            EXECUTE format('TRUNCATE %I CASCADE', t);
            RAISE EXCEPTION 'FIXTURE 234E1 失败:TRUNCATE % 没有被拒', t;
        EXCEPTION WHEN OTHERS THEN
            IF SQLERRM NOT LIKE 'HISTORY_TRUNCATE_FORBIDDEN|%' THEN
                RAISE EXCEPTION 'FIXTURE 234E1 失败:TRUNCATE % 应抛 HISTORY_TRUNCATE_FORBIDDEN,实为 %', t, SQLERRM;
            END IF;
            v_n := v_n + 1;
        END;
    END LOOP;
    IF v_n IS DISTINCT FROM 17 THEN RAISE EXCEPTION 'FIXTURE 234E1 失败:只问到 % 张', v_n; END IF;

    PERFORM pg_temp.f234_as(u_all);
    INSERT INTO tasks (title, task_type, owner_id) VALUES ('FX234 history task', 'team', e_all) RETURNING id INTO v_task_t;
    INSERT INTO task_history (task_id, change_type, new_title) VALUES (v_task_t, 'header_update', 'x') RETURNING id INTO v_th;
    INSERT INTO work_orders (code) VALUES ('FX234-WO') RETURNING id INTO v_wo;
    INSERT INTO work_order_history (work_order_id, change_type) VALUES (v_wo, 'created');
    FOREACH v_msg IN ARRAY ARRAY[
            format('UPDATE task_history SET new_title = ''y'' WHERE id = %L', v_th),
            format('DELETE FROM task_history WHERE id = %L', v_th)] LOOP
        BEGIN
            EXECUTE v_msg;
            RAISE EXCEPTION 'FIXTURE 234E2 失败:「%」没有被拒', v_msg;
        EXCEPTION WHEN OTHERS THEN
            IF SQLERRM NOT LIKE 'TASK_HISTORY_IMMUTABLE%' THEN
                RAISE EXCEPTION 'FIXTURE 234E2 失败:「%」应抛 TASK_HISTORY_IMMUTABLE,实为 %', v_msg, SQLERRM; END IF;
        END;
    END LOOP;
    FOREACH v_msg IN ARRAY ARRAY[
            format('UPDATE work_order_history SET detail = ''y'' WHERE work_order_id = %L', v_wo),
            format('DELETE FROM work_order_history WHERE work_order_id = %L', v_wo)] LOOP
        BEGIN
            EXECUTE v_msg;
            RAISE EXCEPTION 'FIXTURE 234E2 失败:「%」没有被拒', v_msg;
        EXCEPTION WHEN OTHERS THEN
            IF SQLERRM NOT LIKE 'WORK_ORDER_HISTORY_IMMUTABLE%' THEN
                RAISE EXCEPTION 'FIXTURE 234E2 失败:「%」应抛 WORK_ORDER_HISTORY_IMMUTABLE,实为 %', v_msg, SQLERRM; END IF;
        END;
    END LOOP;

    -- ══════════════ F · TRUNCATE 一张被记录的表 ══════════════
    SELECT max(seq) INTO v_seq FROM change_log;
    TRUNCATE cod_verification_failures;
    SELECT to_jsonb(c) INTO v_row FROM change_log c WHERE c.seq > v_seq AND c.table_name = 'cod_verification_failures';
    IF v_row IS NULL OR v_row->>'op' IS DISTINCT FROM 'TRUNCATE' OR v_row->'row_key' IS DISTINCT FROM 'null'::jsonb
       OR (v_row->>'actor_account')::uuid IS DISTINCT FROM u_all THEN
        RAISE EXCEPTION 'FIXTURE 234F 失败:TRUNCATE 应记一行 TRUNCATE(无 row_key、带 actor),实为 %', v_row;
    END IF;

    -- ══════════════ G · 没有码的人读不到 ══════════════
    v_j := pg_temp.f234_json(u_no, 'SELECT to_jsonb(count(*)) FROM change_log_rows()');
    IF COALESCE(v_j->>'error', '') NOT LIKE 'PERMISSION_DENIED|data.view_change_log%' THEN
        RAISE EXCEPTION 'FIXTURE 234G 失败:没有 data.view_change_log 应当 PERMISSION_DENIED,实为 %', v_j;
    END IF;
    v_j := pg_temp.f234_json(u_no, 'SELECT change_log_filters()');
    IF COALESCE(v_j->>'error', '') NOT LIKE 'PERMISSION_DENIED|data.view_change_log%' THEN
        RAISE EXCEPTION 'FIXTURE 234G 失败:筛选项同样要拒,实为 %', v_j;
    END IF;

    -- ══════════════ H · 遮蔽 ══════════════
    -- 合成记录:问的是【读法】—— 同一行记录,不同的读者
    INSERT INTO change_log (table_name, row_key, op, actor_kind, db_role, new) VALUES
        ('purchase_order_history', '{"id": "00000000-0000-0000-0000-00000000a234"}', 'INSERT', 'no_session', 'postgres',
         '{"new_estimated_unit_price": 12.5, "old_estimated_unit_price": null, "new_quantity": 7, "new_payment_term": {"fixed_amount_ccy": 100}}');
    v_j := pg_temp.f234_read(u_m, 'purchase_order_history');
    v_row := v_j->0;
    IF v_row->'new'->'new_estimated_unit_price' IS DISTINCT FROM k_restricted OR v_row->'new'->'old_estimated_unit_price' IS DISTINCT FROM 'null'::jsonb
       OR v_row->'new'->'new_quantity' IS DISTINCT FROM '7'::jsonb OR v_row->'new'->'new_payment_term' IS DISTINCT FROM k_restricted
       OR (v_row->>'row_restricted')::boolean THEN
        RAISE EXCEPTION 'FIXTURE 234H1 失败:无价格码的读者 —— 价格受限、本来就空的留空、数量照常,实为 %', v_j;
    END IF;
    v_row := pg_temp.f234_read(u_pp, 'purchase_order_history')->0;
    IF v_row->'new'->'new_estimated_unit_price' IS DISTINCT FROM '12.5'::jsonb OR v_row->'new'->'new_payment_term' IS NOT DISTINCT FROM k_restricted THEN
        RAISE EXCEPTION 'FIXTURE 234H2 失败:持 data.view_purchase_prices 的读者应当看得见,实为 %', v_row;
    END IF;

    INSERT INTO change_log (table_name, row_key, op, actor_kind, db_role, changed_columns, old, new) VALUES
        ('employees', jsonb_build_object('id', e_m), 'UPDATE', 'no_session', 'postgres', ARRAY['monthly_salary'],
         '{"monthly_salary": 1000}', '{"monthly_salary": 1100}'),
        ('employees', jsonb_build_object('id', e_all), 'UPDATE', 'no_session', 'postgres', ARRAY['monthly_salary'],
         '{"monthly_salary": 2000}', '{"monthly_salary": 2200}');
    v_j := pg_temp.f234_read(u_m, 'employees');
    IF (SELECT r->'new'->'monthly_salary' FROM jsonb_array_elements(v_j) r WHERE r->'row_key'->>'id' = e_m::text ORDER BY (r->>'seq')::bigint DESC LIMIT 1) IS DISTINCT FROM '1100'::jsonb
       OR (SELECT r->'new'->'monthly_salary' FROM jsonb_array_elements(v_j) r WHERE r->'row_key'->>'id' = e_all::text ORDER BY (r->>'seq')::bigint DESC LIMIT 1) IS DISTINCT FROM k_restricted THEN
        RAISE EXCEPTION 'FIXTURE 234H3 失败:自己的月薪看得见、别人的受限(与 employees_masked 同一句 OR),实为 %', v_j;
    END IF;

    INSERT INTO change_log (table_name, row_key, op, actor_kind, db_role, new) VALUES
        ('pricing_formulas', '{"id": "00000000-0000-0000-0000-00000000b234"}', 'INSERT', 'no_session', 'postgres',
         '{"direction": "sale", "flat_discount_pct": 3}'),
        ('pricing_formulas', '{"id": "00000000-0000-0000-0000-00000000c234"}', 'INSERT', 'no_session', 'postgres',
         '{"direction": "purchase", "flat_discount_pct": 4}');
    v_j := pg_temp.f234_read(u_pp, 'pricing_formulas');
    IF (SELECT r->'new'->'flat_discount_pct' FROM jsonb_array_elements(v_j) r WHERE r->'new'->>'direction' = 'sale') IS DISTINCT FROM k_restricted
       OR (SELECT r->'new'->'flat_discount_pct' FROM jsonb_array_elements(v_j) r WHERE r->'new'->>'direction' = 'purchase') IS DISTINCT FROM '4'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 234H4 失败:销售公式对只持采购价码的人受限、采购公式看得见,实为 %', v_j;
    END IF;

    INSERT INTO suppliers (status, code, legal_name, country, counterparty_type)
        VALUES ('active', 'ZZ-FX234-SUP', 'ZZ FX234 Supplier', 'SG', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO purchase_orders (code, supplier_id, order_date, status, currency, fx_rate, category)
        VALUES ('ZZ-FX234-PO', v_sup, CURRENT_DATE, 'confirmed', 'SGD', 1, 'equipment_goods') RETURNING id INTO v_po;
    INSERT INTO purchase_order_history (purchase_order_id, change_type, old_estimated_unit_price, new_estimated_unit_price, amend_reason)
        VALUES (v_po, 'line_update', 10, 11, 'fx234');
    v_j := pg_temp.f234_json(u_buy, format(
        'SELECT jsonb_build_object(''p'', new_estimated_unit_price, ''r'', amend_reason) FROM purchase_order_history_masked WHERE purchase_order_id = %L', v_po));
    IF v_j->'p' IS DISTINCT FROM 'null'::jsonb OR v_j->>'r' IS DISTINCT FROM 'fx234' THEN
        RAISE EXCEPTION 'FIXTURE 234H5 失败:无价格码的采购读者经视图应读到 NULL 的价格与照常的理由,实为 %', v_j;
    END IF;
    v_msg := pg_temp.f234_try(u_buy, 'SELECT new_estimated_unit_price FROM purchase_order_history');
    IF v_msg NOT LIKE 'permission denied%' THEN
        RAISE EXCEPTION 'FIXTURE 234H5 失败:基表的价格列应当 42501,实为 %', v_msg;
    END IF;
    v_j := pg_temp.f234_json(u_all, format(
        'SELECT jsonb_build_object(''p'', new_estimated_unit_price) FROM purchase_order_history_masked WHERE purchase_order_id = %L', v_po));
    IF v_j->'p' IS DISTINCT FROM '11'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 234H5 失败:持价格码的读者经视图应读到 11,实为 %', v_j;
    END IF;

    -- ══════════════ I · 任务隐私 ══════════════
    INSERT INTO employees (id, code, legal_name, employment_type, work_category, hire_date, employment_status) VALUES
        (e_other, 'FX234-OTHER', 'FX234 Other Legal', 'full_time', 'office', DATE '2020-01-01', 'active');
    INSERT INTO tasks (title, description, task_type, owner_id)
        VALUES ('FX234 secret title', 'secret body', 'personal', e_other) RETURNING id INTO v_task_p;
    INSERT INTO tasks (title, task_type, owner_id) VALUES ('FX234 my own', 'personal', e_m) RETURNING id INTO v_task_mine;
    v_j := pg_temp.f234_read(u_m, 'tasks');
    v_row := (SELECT r FROM jsonb_array_elements(v_j) r WHERE r->'row_key'->>'id' = v_task_p::text AND r->>'op' = 'INSERT');
    IF v_row IS NULL OR NOT COALESCE((v_row->>'row_restricted')::boolean, false) OR v_row->'new'->'title' IS DISTINCT FROM k_restricted OR v_row->'new'->'description' IS DISTINCT FROM k_restricted
       OR v_row->>'actor_email' IS NULL OR v_row->>'op' IS DISTINCT FROM 'INSERT' THEN
        RAISE EXCEPTION 'FIXTURE 234I 失败:别人的个人任务应当整行受限(时间、人、动作照常),实为 %', v_row;
    END IF;
    v_row := (SELECT r FROM jsonb_array_elements(v_j) r WHERE r->'row_key'->>'id' = v_task_mine::text AND r->>'op' = 'INSERT');
    IF (v_row->>'row_restricted')::boolean OR v_row->'new'->>'title' IS DISTINCT FROM 'FX234 my own' THEN
        RAISE EXCEPTION 'FIXTURE 234I 失败:自己的个人任务看得见,实为 %', v_row;
    END IF;
    v_row := (SELECT r FROM jsonb_array_elements(v_j) r WHERE r->'row_key'->>'id' = v_task_t::text AND r->>'op' = 'INSERT');
    IF (v_row->>'row_restricted')::boolean OR v_row->'new'->>'title' IS DISTINCT FROM 'FX234 history task' THEN
        RAISE EXCEPTION 'FIXTURE 234I 失败:团队任务看得见,实为 %', v_row;
    END IF;

    -- ══════════════ J · 遮蔽名单完整性 ══════════════
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j->'gaps') IS DISTINCT FROM 0 OR COALESCE((v_j->>'examined_tables')::int, 0) < 20 THEN
        RAISE EXCEPTION 'FIXTURE 234J 失败:遮蔽名单应与目录零缺口(看了 ≥ 20 张),实为 %', v_j;
    END IF;
    BEGIN
        -- ★ 注入:把名单原样重建、只删掉 purchase_order_history.new_estimated_unit_price 那一行
        v_msg := pg_get_functiondef('public.change_log_mask_rules()'::regprocedure);
        v_msg := regexp_replace(v_msg, E'\\n\\s*\\(''purchase_order_history'', ''new_estimated_unit_price''[^\\n]*', '');
        IF v_msg = pg_get_functiondef('public.change_log_mask_rules()'::regprocedure) THEN
            RAISE EXCEPTION 'FIXTURE 234J 布景失败:注入没有改到那一行';
        END IF;
        EXECUTE v_msg;
        v_j := change_log_mask_gaps();
        IF NOT (v_j->'gaps') @> '["missing_rule:purchase_order_history.new_estimated_unit_price"]'::jsonb THEN
            RAISE EXCEPTION 'FIXTURE 234J 失败:注入之后 missing_rule 没有出现,实为 %', v_j;
        END IF;
        RAISE EXCEPTION 'f234_rollback_injection';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM IS DISTINCT FROM 'f234_rollback_injection' THEN RAISE; END IF;
    END;
    IF jsonb_array_length(change_log_mask_gaps()->'gaps') IS DISTINCT FROM 0 THEN
        RAISE EXCEPTION 'FIXTURE 234J 布景失败:注入没有撤干净';
    END IF;

    -- ══════════════ K · 匿名化涂抹 ══════════════
    UPDATE hr_settings SET personal_data_retention_months = 12;
    PERFORM pg_temp.f234_as(u_hr);
    INSERT INTO employees (id, code, legal_name, greeting_name, identity_no, work_email, notes, employment_type, work_category,
                           hire_date, employment_status, separation_date, separation_type) VALUES
        (e_gone, 'FX234-GONE', 'FX234 Gone Legal', 'Gonzo', 'S1234567Z', 'gone@x.test', 'private note', 'full_time', 'office',
         DATE '2019-01-01', 'separated', DATE '2020-01-31', 'resignation'),
        (e_keep, 'FX234-KEEP', 'FX234 Keep Legal', 'Keeper', 'S7654321Z', 'keep@x.test', 'keep note', 'full_time', 'office',
         DATE '2019-01-01', 'separated', DATE '2020-01-31', 'resignation');
    UPDATE employees SET greeting_name = 'Gonz' WHERE id IN (e_gone, e_keep);
    INSERT INTO employment_history (employee_id, effective_date, change_type, notes)
        VALUES (e_gone, DATE '2019-06-01', 'transfer', 'moved desks');
    PERFORM anonymise_employee(e_gone, 'fixture 234: retention elapsed');

    -- 他的每一行记录:名单列全空、redacted_at 盖了、名单外的列原样
    SELECT count(*) INTO v_n FROM change_log c
     WHERE c.table_name = 'employees' AND c.row_key->>'id' = e_gone::text;
    IF v_n < 3 THEN RAISE EXCEPTION 'FIXTURE 234K 布景失败:他应当至少有新增、改称呼、匿名化三行,实为 %', v_n; END IF;
    IF EXISTS (SELECT 1 FROM change_log c WHERE c.table_name = 'employees' AND c.row_key->>'id' = e_gone::text
                AND (c.redacted_at IS NULL
                     OR EXISTS (SELECT 1 FROM jsonb_each(COALESCE(c.old, '{}') || COALESCE(c.new, '{}')) e
                                 WHERE e.key = ANY (change_log_redactable_columns('employees')) AND e.value <> 'null'::jsonb))) THEN
        RAISE EXCEPTION 'FIXTURE 234K 失败:他的记录里仍有未涂抹的个人字段或没盖 redacted_at';
    END IF;
    -- ★ 匿名化那一句 UPDATE 自己的记录(old 里装着匿名化之前的姓名)也涂到了
    SELECT to_jsonb(c) INTO v_row FROM change_log c
     WHERE c.table_name = 'employees' AND c.row_key->>'id' = e_gone::text AND c.op = 'UPDATE' AND 'anonymised_at' = ANY (c.changed_columns);
    IF v_row IS NULL OR NOT (v_row->'old' ? 'legal_name') OR v_row->'old'->'legal_name' IS DISTINCT FROM 'null'::jsonb
       OR NOT (v_row->'old' ? 'greeting_name') OR v_row->'old'->'greeting_name' IS DISTINCT FROM 'null'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 234K 失败:匿名化那一句 UPDATE 的记录应当被涂(legal_name / greeting_name 为 null),实为 %', v_row;
    END IF;
    -- 名单外的列没被碰(新增那一行的 code / hire_date 原样)
    IF NOT EXISTS (SELECT 1 FROM change_log c WHERE c.table_name = 'employees' AND c.row_key->>'id' = e_gone::text
                    AND c.op = 'INSERT' AND c.new->>'code' = 'FX234-GONE' AND c.new->>'hire_date' = '2019-01-01') THEN
        RAISE EXCEPTION 'FIXTURE 234K 失败:名单外的列(code / hire_date)不该被涂';
    END IF;
    -- 履历那一行的记录也涂了
    IF EXISTS (SELECT 1 FROM change_log c JOIN employment_history h ON c.row_key->>'id' = h.id::text
                WHERE c.table_name = 'employment_history' AND h.employee_id = e_gone
                  AND (c.redacted_at IS NULL OR COALESCE(c.new->'notes', 'null') IS DISTINCT FROM 'null'::jsonb)) THEN
        RAISE EXCEPTION 'FIXTURE 234K 失败:他的履历记录应当涂掉 notes';
    END IF;
    -- 另一个人一个字不动
    IF EXISTS (SELECT 1 FROM change_log c WHERE c.table_name = 'employees' AND c.row_key->>'id' = e_keep::text
                AND c.redacted_at IS NOT NULL)
       OR NOT EXISTS (SELECT 1 FROM change_log c WHERE c.table_name = 'employees' AND c.row_key->>'id' = e_keep::text
                       AND c.new->>'identity_no' = 'S7654321Z') THEN
        RAISE EXCEPTION 'FIXTURE 234K 失败:另一个人的记录不该被涂';
    END IF;
    -- 其余任何 UPDATE:涂抹形状但动了名单外的键 / 不盖 redacted_at 就改 / 已涂过的再改 —— 全拒
    FOREACH v_msg IN ARRAY ARRAY[
        format('UPDATE change_log SET new = new || ''{"code": null}''::jsonb, redacted_at = now() WHERE table_name = ''employees'' AND row_key->>''id'' = %L AND op = ''INSERT''', e_keep),
        format('UPDATE change_log SET new = jsonb_set(new, ''{identity_no}'', ''null'') WHERE table_name = ''employees'' AND row_key->>''id'' = %L AND op = ''INSERT''', e_keep),
        format('UPDATE change_log SET new = new - ''identity_no'', redacted_at = now() WHERE table_name = ''employees'' AND row_key->>''id'' = %L AND op = ''INSERT''', e_keep),
        format('UPDATE change_log SET db_role = ''x'', redacted_at = now() WHERE table_name = ''employees'' AND row_key->>''id'' = %L AND op = ''INSERT''', e_keep),
        format('UPDATE change_log SET redacted_at = now() + interval ''1 day'' WHERE table_name = ''employees'' AND row_key->>''id'' = %L', e_gone)] LOOP
        BEGIN
            EXECUTE v_msg;
            RAISE EXCEPTION 'FIXTURE 234K 失败:「%」没有被拒', v_msg;
        EXCEPTION WHEN OTHERS THEN
            IF SQLERRM NOT LIKE 'CHANGE_LOG_IMMUTABLE%' THEN
                RAISE EXCEPTION 'FIXTURE 234K 失败:「%」应抛 CHANGE_LOG_IMMUTABLE,实为 %', v_msg, SQLERRM; END IF;
        END;
    END LOOP;

    -- ══════════════ L · 个人数据导出 ══════════════
    PERFORM pg_temp.f234_as(u_hr);
    UPDATE employees SET notes = 'HR changed this' WHERE id = e_m;
    v_j := pg_temp.f234_json(u_m, 'SELECT export_my_personal_data() -> ''my_record_changes''');
    v_row := (SELECT r FROM jsonb_array_elements(v_j) r WHERE r->'after'->>'notes' = 'HR changed this');
    IF v_row IS NULL OR v_row->>'changed_by' IS DISTINCT FROM 'FX234 HR Legal' OR v_row->>'operation' IS DISTINCT FROM 'UPDATE'
       OR NOT (v_row->'changed_fields' ? 'notes') OR v_row->'changed_fields' ? 'updated_by' THEN
        RAISE EXCEPTION 'FIXTURE 234L 失败:导出应带着自己那一行的改动、改的人给员工名,实为 %', v_j;
    END IF;
    IF v_j::text LIKE '%' || u_hr::text || '%' OR v_j::text LIKE '%' || u_m::text || '%'
       OR v_j::text LIKE '%fx234-hr@test.local%' OR v_j::text LIKE '%"user_id"%' OR v_j::text LIKE '%"created_by"%' THEN
        RAISE EXCEPTION 'FIXTURE 234L 失败:导出里不许出现账号 id 或邮箱,实为 %', v_j;
    END IF;

    -- ══════════════ M · set_role_permissions 只记差别 ══════════════
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx234-diff','f','f',true) RETURNING id INTO r_x;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_x, c FROM unnest(ARRAY['module.tasks.view', 'module.hr.view']) c;
    SELECT max(seq) INTO v_seq FROM change_log;
    v_j := pg_temp.f234_json(u_all, format(
        'SELECT set_role_permissions(%L::uuid, ARRAY[''module.hr.view'', ''module.materials.view'', ''module.materials.view''])', r_x));
    IF v_j->>'error' IS NOT NULL OR (v_j->>'added')::int IS DISTINCT FROM 1 OR (v_j->>'removed')::int IS DISTINCT FROM 1 OR (v_j->>'permission_count')::int IS DISTINCT FROM 2 THEN
        RAISE EXCEPTION 'FIXTURE 234M 失败:应加 1 删 1、重复的码被吸收,实为 %', v_j;
    END IF;
    SELECT string_agg(c.op || ':' || (c.row_key->>'permission_code'), ',' ORDER BY c.op) INTO v_msg
      FROM change_log c WHERE c.seq > v_seq AND c.table_name = 'role_permissions';
    IF v_msg IS DISTINCT FROM 'DELETE:module.tasks.view,INSERT:module.materials.view' THEN
        RAISE EXCEPTION 'FIXTURE 234M 失败:记录应当只有删掉的与加上的那两个码,实为 %', v_msg;
    END IF;
END;
$$;

ROLLBACK;
