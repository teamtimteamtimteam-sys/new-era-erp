-- 235 HISTORY-1:账号是停用、不是删掉,而且每一步都记下来;每一张表要么被记录、要么在豁免名单上(2026-09-28)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】(HISTORY-1 Step 0 Q2 · Q3 · Q5 · Q12,Tim 2026-09-28)
--   N  record_account_event:
--        N1 没有 action.manage_permissions → PERMISSION_DENIED
--        N2 最后一个真的管理员 → LAST_ADMIN_PROTECTED(判据与 guard_last_admin 同一份:real_role_grants × is_system)
--        N3 停用自己 → CANNOT_DISABLE_SELF
--        N4 有第二个管理员之后,停用第一个 → 记一行 ACCOUNT_DISABLE(actor 是按按钮的人,new 里有邮箱)
--        N5 已停用(banned_until 在将来)再停用 → ACCOUNT_ALREADY_DISABLED
--        N6 启用 → 记一行 ACCOUNT_ENABLE;N7 未停用再启用 → ACCOUNT_NOT_DISABLED
--        N8 建号 → ACCOUNT_CREATE;账号还在就记删除 → ACCOUNT_STILL_EXISTS;
--           删掉之后记删除(reason = create_rolled_back)→ ACCOUNT_DELETE,new 里有 reason 与邮箱
--        N9 user_directory.disabled 跟着 banned_until 走
--   O  change_log_coverage_gaps():
--        O1 重建出来的库零缺口,看了 ≥ 200 张,4 张豁免
--        O2 ★ 注入一张没绑也没豁免的表 → unbound:<表>
--        O3 ★ 注入给一张豁免的表挂上记录触发器 → excluded_but_bound:<表>
--        O4 ★ 注入把一张表的记录触发器停掉(DISABLE TRIGGER)→ unbound:<表>(停着的触发器不算绑着)
--
-- 【auth 那一步证不了】真正的封禁是 Supabase auth(banned_until 由 auth 服务写);这里直接写 banned_until
-- 模拟"auth 那一步已经做了",问的是本库这一半的判据。"封了之后还登不登得上、旧令牌还管多久"
-- 是对着线上量的(docs/handbacks/HISTORY-1.md 的停用证明)。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '120s';

CREATE FUNCTION pg_temp.f235_event(p_actor uuid, p_user uuid, p_event text, p_detail jsonb DEFAULT '{}') RETURNS text
LANGUAGE plpgsql AS $f$
DECLARE v bigint;
BEGIN
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', p_actor), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    v := record_account_event(p_user, p_event, p_detail);
    EXECUTE 'RESET ROLE';
    RETURN 'OK:' || v;
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    RETURN SQLERRM;
END;
$f$;

DO $$
DECLARE
    u_mgr  uuid := gen_random_uuid();   -- 持 action.manage_permissions(非系统角色)
    u_adm1 uuid := gen_random_uuid();   -- 第一个管理员(is_system 角色)
    u_adm2 uuid := gen_random_uuid();   -- 第二个管理员
    u_no   uuid := gen_random_uuid();   -- 一个码都不持
    u_new  uuid := gen_random_uuid();   -- 刚建的号
    r_mgr uuid; r_sys uuid;
    v_msg text; v_row jsonb; v_j jsonb; v_seq bigint;
BEGIN
    -- ══════════════ 布景 ══════════════
    -- 重建出来的库里没有任何真的管理员 —— 本支自己造第一个;别的真管理员若存在,N2 这一臂无从证起。
    IF EXISTS (SELECT 1 FROM roles r CROSS JOIN LATERAL real_role_grants(r.code) g
                WHERE r.is_system AND r.is_active AND r.deleted_at IS NULL) THEN
        RAISE EXCEPTION 'FIXTURE 235 布景失败:重建库里已经有真的管理员授权,N2 证不了';
    END IF;
    SELECT id INTO r_sys FROM roles WHERE is_system AND is_active AND deleted_at IS NULL ORDER BY code LIMIT 1;
    IF r_sys IS NULL THEN RAISE EXCEPTION 'FIXTURE 235 布景失败:没有 is_system 角色'; END IF;
    INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
        (u_mgr, 'fx235-mgr@test.local', now()), (u_adm1, 'fx235-adm1@test.local', now()),
        (u_adm2, 'fx235-adm2@test.local', now()), (u_no, 'fx235-no@test.local', now()),
        (u_new, 'fx235-new@test.local', now());
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx235-mgr','f','f',true) RETURNING id INTO r_mgr;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_mgr, 'action.manage_permissions');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_mgr, r_mgr), (u_adm1, r_sys);

    -- ══════════════ N · 账号事件 ══════════════
    v_msg := pg_temp.f235_event(u_no, u_adm1, 'ACCOUNT_DISABLE');
    IF v_msg NOT LIKE 'PERMISSION_DENIED|action.manage_permissions%' THEN
        RAISE EXCEPTION 'FIXTURE 235N1 失败:无权者应被拒,实为 %', v_msg; END IF;

    v_msg := pg_temp.f235_event(u_mgr, u_adm1, 'ACCOUNT_DISABLE');
    IF v_msg IS DISTINCT FROM 'LAST_ADMIN_PROTECTED' THEN
        RAISE EXCEPTION 'FIXTURE 235N2 失败:停用最后一个真管理员应当 LAST_ADMIN_PROTECTED,实为 %', v_msg; END IF;

    v_msg := pg_temp.f235_event(u_mgr, u_mgr, 'ACCOUNT_DISABLE');
    IF v_msg IS DISTINCT FROM 'CANNOT_DISABLE_SELF' THEN
        RAISE EXCEPTION 'FIXTURE 235N3 失败:停用自己应当 CANNOT_DISABLE_SELF,实为 %', v_msg; END IF;

    INSERT INTO user_roles (user_id, role_id) VALUES (u_adm2, r_sys);
    SELECT COALESCE(max(seq), 0) INTO v_seq FROM change_log;
    v_msg := pg_temp.f235_event(u_mgr, u_adm1, 'ACCOUNT_DISABLE');
    SELECT to_jsonb(c) INTO v_row FROM change_log c WHERE c.seq > v_seq AND c.table_name = 'auth.users';
    IF v_msg NOT LIKE 'OK:%' OR v_row->>'op' IS DISTINCT FROM 'ACCOUNT_DISABLE' OR v_row->'row_key' IS DISTINCT FROM jsonb_build_object('id', u_adm1)
       OR (v_row->>'actor_account')::uuid IS DISTINCT FROM u_mgr OR v_row->>'db_role' IS DISTINCT FROM 'authenticated'
       OR v_row->'new'->>'email' IS DISTINCT FROM 'fx235-adm1@test.local' THEN
        RAISE EXCEPTION 'FIXTURE 235N4 失败:停用应记一行 ACCOUNT_DISABLE(actor = 按按钮的人),实为 % / %', v_msg, v_row;
    END IF;

    UPDATE auth.users SET banned_until = now() + interval '100 years' WHERE id = u_adm1;   -- 模拟 auth 那一步
    v_msg := pg_temp.f235_event(u_mgr, u_adm1, 'ACCOUNT_DISABLE');
    IF v_msg IS DISTINCT FROM 'ACCOUNT_ALREADY_DISABLED' THEN
        RAISE EXCEPTION 'FIXTURE 235N5 失败:已停用再停用应当 ACCOUNT_ALREADY_DISABLED,实为 %', v_msg; END IF;

    SELECT max(seq) INTO v_seq FROM change_log;
    v_msg := pg_temp.f235_event(u_mgr, u_adm1, 'ACCOUNT_ENABLE');
    IF v_msg NOT LIKE 'OK:%' OR NOT EXISTS (SELECT 1 FROM change_log c WHERE c.seq > v_seq AND c.op = 'ACCOUNT_ENABLE'
                                             AND c.row_key = jsonb_build_object('id', u_adm1)) THEN
        RAISE EXCEPTION 'FIXTURE 235N6 失败:启用应记一行 ACCOUNT_ENABLE,实为 %', v_msg; END IF;
    UPDATE auth.users SET banned_until = NULL WHERE id = u_adm1;
    v_msg := pg_temp.f235_event(u_mgr, u_adm1, 'ACCOUNT_ENABLE');
    IF v_msg IS DISTINCT FROM 'ACCOUNT_NOT_DISABLED' THEN
        RAISE EXCEPTION 'FIXTURE 235N7 失败:未停用再启用应当 ACCOUNT_NOT_DISABLED,实为 %', v_msg; END IF;

    v_msg := pg_temp.f235_event(u_mgr, u_new, 'ACCOUNT_CREATE', '{"role_code": "fx235-mgr"}');
    IF v_msg NOT LIKE 'OK:%' OR NOT EXISTS (SELECT 1 FROM change_log c WHERE c.op = 'ACCOUNT_CREATE'
                                             AND c.row_key = jsonb_build_object('id', u_new)
                                             AND c.new->>'email' = 'fx235-new@test.local' AND c.new->>'role_code' = 'fx235-mgr') THEN
        RAISE EXCEPTION 'FIXTURE 235N8 失败:建号应记一行 ACCOUNT_CREATE,实为 %', v_msg; END IF;
    v_msg := pg_temp.f235_event(u_mgr, u_new, 'ACCOUNT_DELETE', '{"reason": "create_rolled_back", "email": "fx235-new@test.local"}');
    IF v_msg IS DISTINCT FROM 'ACCOUNT_STILL_EXISTS' THEN
        RAISE EXCEPTION 'FIXTURE 235N8 失败:账号还在就不许记删除,实为 %', v_msg; END IF;
    DELETE FROM auth.users WHERE id = u_new;
    v_msg := pg_temp.f235_event(u_mgr, u_new, 'ACCOUNT_DELETE', '{"reason": "create_rolled_back", "email": "fx235-new@test.local"}');
    IF v_msg NOT LIKE 'OK:%' OR NOT EXISTS (SELECT 1 FROM change_log c WHERE c.op = 'ACCOUNT_DELETE'
                                             AND c.row_key = jsonb_build_object('id', u_new)
                                             AND c.new->>'reason' = 'create_rolled_back'
                                             AND c.new->>'email' = 'fx235-new@test.local') THEN
        RAISE EXCEPTION 'FIXTURE 235N8 失败:回滚删除应记一行 ACCOUNT_DELETE(reason = create_rolled_back),实为 %', v_msg; END IF;

    -- N9:user_directory.disabled 跟着 banned_until 走(以持码人的身份读视图)
    UPDATE auth.users SET banned_until = now() + interval '1 day' WHERE id = u_adm2;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_mgr), true);
    IF (SELECT disabled FROM user_directory WHERE user_id = u_adm2) IS NOT TRUE
       OR (SELECT disabled FROM user_directory WHERE user_id = u_adm1) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 235N9 失败:user_directory.disabled 应跟着 banned_until 走';
    END IF;

    -- ══════════════ O · 覆盖 ══════════════
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j->'gaps') IS DISTINCT FROM 0 OR COALESCE((v_j->>'examined')::int, 0) < 200 OR (v_j->>'excluded')::int IS DISTINCT FROM 8 THEN
        -- ★ MES-1(2026-10-06,MES-0 Q14):4 → 7 —— 采集层的三份日志(收件箱 · 传输日志 · 网关中断)豁免,理由在 change_log_exclusions()
        -- ★ MES-3b(2026-10-07,MES-3b Step 0 Q20):7 → 8 —— 扫码日志 scan_events 豁免(它自己就是一本只追加的日志)
        RAISE EXCEPTION 'FIXTURE 235O1 失败:重建库应零缺口(看了 ≥ 200 张、8 张豁免),实为 %', v_j;
    END IF;
    BEGIN
        CREATE TABLE public.fx235_orphan (id integer PRIMARY KEY);
        v_j := change_log_coverage_gaps();
        IF NOT (v_j->'gaps') @> '["unbound:fx235_orphan"]'::jsonb THEN
            RAISE EXCEPTION 'FIXTURE 235O2 失败:一张没绑也没豁免的表应当出现 unbound,实为 %', v_j; END IF;
        RAISE EXCEPTION 'f235_rollback';
    EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'f235_rollback' THEN RAISE; END IF;
    END;
    BEGIN
        CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.home_greetings
            FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
        v_j := change_log_coverage_gaps();
        IF NOT (v_j->'gaps') @> '["excluded_but_bound:home_greetings"]'::jsonb THEN
            RAISE EXCEPTION 'FIXTURE 235O3 失败:豁免了却绑着应当出现 excluded_but_bound,实为 %', v_j; END IF;
        RAISE EXCEPTION 'f235_rollback';
    EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'f235_rollback' THEN RAISE; END IF;
    END;
    BEGIN
        ALTER TABLE public.laboratories DISABLE TRIGGER zzz_change_log;
        v_j := change_log_coverage_gaps();
        IF NOT (v_j->'gaps') @> '["unbound:laboratories"]'::jsonb THEN
            RAISE EXCEPTION 'FIXTURE 235O4 失败:停着的触发器不算绑着,实为 %', v_j; END IF;
        RAISE EXCEPTION 'f235_rollback';
    EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'f235_rollback' THEN RAISE; END IF;
    END;
    IF jsonb_array_length(change_log_coverage_gaps()->'gaps') IS DISTINCT FROM 0 THEN
        RAISE EXCEPTION 'FIXTURE 235O 布景失败:注入没有撤干净';
    END IF;
END;
$$;

ROLLBACK;
