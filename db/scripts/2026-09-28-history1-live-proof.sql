-- db/scripts/2026-09-28-history1-live-proof.sql
-- HISTORY-1 的线上证明 —— 【一笔事务,整支回滚】。不写任何一行留下来。
--
-- 为什么它在 db/scripts/ 而不在 db/fixtures/:它问的是【线上】那一份 —— 真的 admin@ 账号、真的 cfo 角色、
-- 真的 238 条触发器 —— 而 fixture 234 / 235 问的是重建出来的库。两边问同一批判据。
--
-- 三件事(Tim 的委托书 §Live verification):
--   ① 一个【登录着的账号】(admin@,SET LOCAL ROLE authenticated,经 RLS)改一行 → 记录里有这一行,
--      账号 + 员工两个 actor 都对(admin@ → EMP-2026-0002);
--   ② 读法对一个【不持数据码】的读者遮住一个值(付款条款模板行的 fixed_amount_ccy,data.view_purchase_prices),
--      而 tim@(cfo,持码)看得见同一个值;
--   ③ 对 change_log 的 UPDATE 被拒:authenticated → permission denied;属主 → CHANGE_LOG_IMMUTABLE。
-- 【不碰任何既有单据】:改的是本支自己新建的一张付款条款模板;读者角色也是本支自建。全部随 ROLLBACK 消失。
-- 前后读数(本支之外):change_log 的行数与最大 seq、每一张表的指纹、被封禁账号数 —— 见交回报告。

BEGIN;
SET LOCAL statement_timeout = '120s';

DO $proof$
DECLARE
    u_admin uuid := (SELECT id FROM auth.users WHERE email = 'admin@swm-os.test');
    u_tim   uuid := (SELECT id FROM auth.users WHERE email = 'tim@evoltrya.test');
    u_r     uuid := gen_random_uuid();       -- 合成读者:只持 data.view_change_log(不进 auth.users —— 不是一个能登录的号)
    r_r     uuid;
    v_emp   uuid;
    v_tpl   uuid;
    v_row   jsonb;
    v_j     jsonb;
    v_msg   text;
BEGIN
    IF u_admin IS NULL OR u_tim IS NULL THEN RAISE EXCEPTION 'H1_LIVE 布景失败:找不到 admin@ / tim@'; END IF;
    v_emp := account_person(u_admin);

    -- ① 登录着的账号改一行
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_admin), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    INSERT INTO payment_term_templates (name, currency) VALUES ('ZZ-H1-LIVE template', (SELECT code FROM currencies WHERE is_base)) RETURNING id INTO v_tpl;
    INSERT INTO payment_term_template_lines (template_id, seq, label, fixed_amount_ccy, trigger_event)
        VALUES (v_tpl, 1, 'ZZ-H1-LIVE', 123, (SELECT code FROM payment_trigger_events ORDER BY code LIMIT 1));
    UPDATE payment_term_templates SET description = 'edited by HISTORY-1 live proof' WHERE id = v_tpl;
    EXECUTE 'RESET ROLE';
    SELECT to_jsonb(c) INTO v_row FROM change_log c
     WHERE c.table_name = 'payment_term_templates' AND c.row_key = jsonb_build_object('id', v_tpl) AND c.op = 'UPDATE';
    IF v_row IS NULL
       OR (v_row->>'actor_account')::uuid IS DISTINCT FROM u_admin
       OR (v_row->>'actor_employee')::uuid IS DISTINCT FROM v_emp OR v_emp IS NULL
       OR v_row->>'actor_kind' IS DISTINCT FROM 'user' OR v_row->>'db_role' IS DISTINCT FROM 'authenticated'
       OR v_row->'old'->'description' IS DISTINCT FROM 'null'::jsonb
       OR v_row->'new'->>'description' IS DISTINCT FROM 'edited by HISTORY-1 live proof' THEN
        RAISE EXCEPTION 'H1_LIVE ① 失败:登录账号的编辑应当带着账号 + 员工记下来,实为 %', v_row;
    END IF;
    RAISE NOTICE 'H1_LIVE ① ok: seq % · op % · account % · employee % (%) · db_role % · changed %',
        v_row->>'seq', v_row->>'op', v_row->>'actor_account', v_row->>'actor_employee',
        (SELECT code FROM employees WHERE id = v_emp), v_row->>'db_role', v_row->'changed_columns';

    -- ② 读法遮住一个值:合成读者只持 data.view_change_log;tim@(cfo)持 data.view_purchase_prices
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('zz-h1-live-reader', 'x', 'x', true) RETURNING id INTO r_r;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_r, 'data.view_change_log');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_r, r_r);

    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_r), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT r.new INTO v_j FROM change_log_rows(p_table => 'payment_term_template_lines', p_limit => 5) r
     WHERE r.new->>'label' = 'ZZ-H1-LIVE';
    EXECUTE 'RESET ROLE';
    IF v_j->'fixed_amount_ccy' IS DISTINCT FROM '{"$restricted": true}'::jsonb OR v_j->>'label' IS DISTINCT FROM 'ZZ-H1-LIVE' THEN
        RAISE EXCEPTION 'H1_LIVE ② 失败:不持 data.view_purchase_prices 的读者应当看到受限标记,实为 %', v_j;
    END IF;
    RAISE NOTICE 'H1_LIVE ② ok (reader without the data code): fixed_amount_ccy = %', v_j->'fixed_amount_ccy';

    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_tim), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT r.new INTO v_j FROM change_log_rows(p_table => 'payment_term_template_lines', p_limit => 5) r
     WHERE r.new->>'label' = 'ZZ-H1-LIVE';
    EXECUTE 'RESET ROLE';
    IF v_j->'fixed_amount_ccy' IS DISTINCT FROM '123'::jsonb THEN
        RAISE EXCEPTION 'H1_LIVE ② 失败:tim@(cfo,持码)应当看到 123,实为 %', v_j;
    END IF;
    RAISE NOTICE 'H1_LIVE ② ok (tim@, cfo, holds the code): fixed_amount_ccy = %', v_j->'fixed_amount_ccy';

    -- ③ change_log 的 UPDATE 被拒
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_admin), true);
    BEGIN
        EXECUTE 'SET LOCAL ROLE authenticated';
        EXECUTE format('UPDATE change_log SET db_role = %L WHERE seq = %s', 'x', v_row->>'seq');
        EXECUTE 'RESET ROLE';
        RAISE EXCEPTION 'H1_LIVE ③ 失败:authenticated 的 UPDATE 没有被拒';
    EXCEPTION WHEN insufficient_privilege THEN
        EXECUTE 'RESET ROLE';
        RAISE NOTICE 'H1_LIVE ③ ok (authenticated): %', SQLERRM;
    END;
    BEGIN
        EXECUTE format('UPDATE change_log SET db_role = %L WHERE seq = %s', 'x', v_row->>'seq');
        RAISE EXCEPTION 'H1_LIVE ③ 失败:属主的 UPDATE 没有被拒';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'CHANGE_LOG_IMMUTABLE%' THEN RAISE; END IF;
        RAISE NOTICE 'H1_LIVE ③ ok (owner): %', SQLERRM;
    END;
    RAISE NOTICE 'H1_LIVE all three arms passed; rolling back';
END;
$proof$;

ROLLBACK;
