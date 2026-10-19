-- ═══════════════════════════════════════════════════════════════════════════
-- fixture 273 —— 一块车间大屏只看得见计数,它也是唯一一种空闲时不被登出的会话
--   (MES-8b-2,2026-10-17;MES-0 Q83 · Q90;MES-8 Step 0 Q19 · Q20 · Q29,Tim)
-- ═══════════════════════════════════════════════════════════════════════════
-- 臂:
--   REG      floor_display 是一个在用、不是系统角色的角色;data.view_floor_board 是一个 data 码(不声明查看码);floor_display【只】持它;
--            admin 持目录里每一个码(含它)
--   ARMS     floor_board_arms() 是一份闭合的清单:23 支,每一支都在 operations_arms_all 里;门是 module.processing.view · module.safety.view ·
--            module.inventory.view 的【每一支】都在清单里(以后加一支加工 / 安全 / 库存的支而不加进大屏,这里红);
--            operations_now 与 operations_arms_all 是同一份支(全码读者读 operations_now 的行数 = 基视图的行数);基视图 authenticated 读不到
--   COUNTS   floor_board() 只吐计数:返回的键恰好是 {as_of, tiles, refresh_seconds, settings_set},每一块牌子的键恰好是 {section, item_type, count}
--            —— 没有 subject、item_code、item_id、日子、名字、钱或健康信息;每一块的数 = 基视图里那一支的行数(两张开着的盘点 → stocktake_open 2)
--   GATE     floor_board() 的门是 data.view_floor_board:不持的会话 → PERMISSION_DENIED|data.view_floor_board;大屏会话读 operations_now 是 0 行、
--            读进料批 / 事故是 0 行 —— 它除了计数什么都读不到
--   IDLE     session_is_floor_display_only():只挂 floor_display、只持那一个码 → 真;没有会话 → 假;floor_display + 另一个角色(哪怕零个码)→ 假;
--            floor_display 多【任何一个】码(目录里逐码试)→ 假;只持那一个码却经别的角色持 → 假;重建库里每一个别的角色 → 假;
--            另一个角色撤销之后 → 回到真;floor_display 停用 → 假(判据在库里,由 auth.uid() 求值)
--   V28      待补的值:没有大屏账号时没有 V28 那一行;有了一个在用的大屏账号 → 持 action.manage_permissions 的人看见一行,大屏自己看不见;
--            设了之后那一行消失,floor_board() 只画选中的牌子、按选中的顺序、带回间隔;只给一半 / 未知的牌子 / 重复 / 空 / 非正的间隔 /
--            不持码的人 → 按名拒;清空 → 回到全部牌子、没有间隔
--   LOG      floor_board_settings 进变更记录(豁免仍 8 —— MES-9b 起是 9);floor_board 与 session_is_floor_display_only 是 STABLE(不写任何东西)
--
-- 自带数据(README 第 2 条);读者那几臂切成 authenticated + JWT。全部判定写成 IF (…) IS NOT FALSE —— 一个 NULL 也是红。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '300s';

CREATE FUNCTION pg_temp.f273_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims',
                      CASE WHEN p_user IS NULL THEN '' ELSE format('{"sub":"%s","role":"authenticated"}', p_user) END, true)
$f$;

CREATE FUNCTION pg_temp.f273_do(p_user uuid, p_sql text) RETURNS text
LANGUAGE plpgsql AS $f$
BEGIN
    PERFORM pg_temp.f273_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql;
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f273_as(NULL);
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f273_as(NULL);
    RETURN SQLERRM;
END;
$f$;

CREATE FUNCTION pg_temp.f273_get(p_user uuid, p_sql text) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v jsonb;
BEGIN
    PERFORM pg_temp.f273_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f273_as(NULL);
    RETURN v;
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f273_as(NULL);
    RAISE;
END;
$f$;

-- 一个账号(auth.users 一行),不挂角色
CREATE FUNCTION pg_temp.f273_account(p_label text) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE u uuid := gen_random_uuid();
BEGIN
    INSERT INTO auth.users (id, email, email_confirmed_at, created_at) VALUES (u, 'fx273-' || p_label || '@test.local', now(), now());
    RETURN u;
END;
$f$;

-- 一个持给定码的一次性角色,挂到账号上
CREATE FUNCTION pg_temp.f273_grant_codes(p_user uuid, p_label text, p_codes text[]) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE r uuid;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx273-' || p_label, 'f', 'f', true) RETURNING id INTO r;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r, c FROM unnest(p_codes) c;
    INSERT INTO user_roles (user_id, role_id) VALUES (p_user, r);
    RETURN r;
END;
$f$;

CREATE FUNCTION pg_temp.f273_expect_like(p_got text, p_like text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
    IF (p_got IS NULL OR p_got NOT LIKE p_like) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 273 V28 expected % got %', p_like, COALESCE(p_got, '<null>');
    END IF;
END;
$f$;

-- 以某个会话问一次豁免
CREATE FUNCTION pg_temp.f273_exempt(p_user uuid) RETURNS boolean
LANGUAGE plpgsql AS $f$
DECLARE v boolean;
BEGIN
    PERFORM pg_temp.f273_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT session_is_floor_display_only() INTO v;
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f273_as(NULL);
    RETURN v;
END;
$f$;

DO $$
DECLARE
    r_floor uuid; r_admin uuid;
    u_floor uuid; u_all uuid; u_none uuid; u_mgr uuid; u_codeonly uuid; u_x uuid;
    v_b jsonb; v_t jsonb; v_x jsonb; v_msg text; v_n bigint; v_m bigint; v_codes text[]; v_bad text; v_rule text[]; v_list text[];
    v_arms text[]; c text; rr record; v_ur uuid;
BEGIN
    PERFORM pg_temp.f273_as(NULL);
    SELECT id INTO r_floor FROM roles WHERE code = 'floor_display';
    SELECT id INTO r_admin FROM roles WHERE code = 'admin';

    -- ══════════════ REG ══════════════
    RAISE NOTICE 'fixture 273 · REG';
    IF (r_floor IS NULL OR (SELECT is_system FROM roles WHERE id = r_floor) OR NOT (SELECT is_active FROM roles WHERE id = r_floor)
        OR (SELECT deleted_at FROM roles WHERE id = r_floor) IS NOT NULL) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 273 REG: floor_display must exist, be active, not deleted and not a system role'; END IF;
    IF (NOT EXISTS (SELECT 1 FROM permissions WHERE code = 'data.view_floor_board' AND category = 'data' AND requires_view_any IS NULL)) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 273 REG: data.view_floor_board must be a data code declaring no view'; END IF;
    SELECT array_agg(permission_code ORDER BY permission_code) INTO v_codes FROM role_permissions WHERE role_id = r_floor;
    IF (v_codes IS DISTINCT FROM ARRAY['data.view_floor_board']) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 273 REG: floor_display holds exactly data.view_floor_board, got %', v_codes; END IF;
    IF (EXISTS (SELECT 1 FROM permissions p WHERE NOT EXISTS (SELECT 1 FROM role_permissions rp WHERE rp.role_id = r_admin AND rp.permission_code = p.code))) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 273 REG: admin holds every code, data.view_floor_board included'; END IF;

    -- 身份:大屏(只挂 floor_display)· 全码 · 零码 · 设 V28 的人(action.manage_permissions)· 只持大屏码、却经别的角色
    u_floor := pg_temp.f273_account('floor');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_floor, r_floor);
    u_all := pg_temp.f273_account('all');
    PERFORM pg_temp.f273_grant_codes(u_all, 'all', ARRAY(SELECT code FROM permissions));
    u_none := pg_temp.f273_account('none');
    PERFORM pg_temp.f273_grant_codes(u_none, 'none', ARRAY['module.hr.view']);
    u_mgr := pg_temp.f273_account('mgr');
    PERFORM pg_temp.f273_grant_codes(u_mgr, 'mgr', ARRAY['action.manage_permissions']);
    u_codeonly := pg_temp.f273_account('codeonly');
    PERFORM pg_temp.f273_grant_codes(u_codeonly, 'codeonly', ARRAY['data.view_floor_board']);

    -- ══════════════ ARMS ══════════════
    RAISE NOTICE 'fixture 273 · ARMS';
    SELECT array_agg(item_type ORDER BY item_type) INTO v_list FROM floor_board_arms();
    IF (cardinality(v_list) <> 23 OR (SELECT count(DISTINCT item_type) FROM floor_board_arms()) <> 23) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 273 ARMS: the floor board lists 23 distinct arms, got %', v_list; END IF;
    SELECT COALESCE(array_agg(DISTINCT m[1] ORDER BY m[1]), '{}') INTO v_arms
      FROM regexp_matches(pg_get_viewdef('public.operations_arms_all'::regclass), '''([a-z_0-9]+)''::text AS item_type', 'g') m;
    IF (cardinality(v_arms) < 72) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 273 ARMS: the arm parser found % arms — a broken parser is not an empty set', cardinality(v_arms); END IF;
    SELECT string_agg(x, ', ') INTO v_bad FROM unnest(v_list) x WHERE NOT x = ANY (v_arms);
    IF (v_bad IS NOT NULL) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 273 ARMS: every floor arm is an arm of operations_arms_all; not found: %', v_bad; END IF;
    -- 判据 ①:门是这三个模块查看码的每一支都在清单里
    SELECT COALESCE(array_agg(DISTINCT m[1] ORDER BY m[1]), '{}') INTO v_rule
      FROM regexp_matches(pg_get_viewdef('public.operations_arms_all'::regclass),
                          '''([a-z_0-9]+)''::text AS item_type,\s+''(module\.processing\.view|module\.safety\.view|module\.inventory\.view)''::text AS permission', 'g') m;
    IF (cardinality(v_rule) < 19) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 273 ARMS: the gate parser found % processing / safety / inventory arms (expected 19) — a broken parser is not an empty set', cardinality(v_rule); END IF;
    SELECT string_agg(x, ', ') INTO v_bad FROM unnest(v_rule) x WHERE NOT x = ANY (v_list);
    IF (v_bad IS NOT NULL) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 273 ARMS: an arm gated by processing / safety / inventory is missing from the floor board: %', v_bad; END IF;
    -- 同一份支:全码读者读 operations_now 的行数 = 基视图的行数;基视图对 authenticated 关着
    INSERT INTO stocktakes (code) VALUES ('FX273-ST1'), ('FX273-ST2');
    SELECT count(*) INTO v_m FROM operations_arms_all;
    v_x := pg_temp.f273_get(u_all, $q$SELECT to_jsonb(count(*)) FROM operations_now$q$);
    IF ((v_x #>> '{}')::bigint <> v_m OR v_m < 2) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 273 ARMS: an all-codes reader reads every row of the arms view through operations_now (% vs %)', v_x, v_m; END IF;
    IF (has_table_privilege('authenticated', 'public.operations_arms_all', 'SELECT') OR has_table_privilege('anon', 'public.operations_arms_all', 'SELECT')) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 273 ARMS: the arms view is a base view nobody reads directly'; END IF;

    -- ══════════════ COUNTS ══════════════
    RAISE NOTICE 'fixture 273 · COUNTS';
    v_b := pg_temp.f273_get(u_floor, $q$SELECT floor_board()$q$);
    IF ((SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(v_b) k) IS DISTINCT FROM ARRAY['as_of', 'refresh_seconds', 'settings_set', 'tiles']) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 273 COUNTS: floor_board() returns exactly {as_of, refresh_seconds, settings_set, tiles}, got %', (SELECT array_agg(k) FROM jsonb_object_keys(v_b) k); END IF;
    IF (jsonb_array_length(v_b -> 'tiles') <> 23
        OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_b -> 'tiles') t
                    WHERE (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(t) k) IS DISTINCT FROM ARRAY['count', 'item_type', 'section'])) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 273 COUNTS: 23 tiles, each exactly {section, item_type, count} — no subject, code, id, date, name, money or health detail, got %', v_b -> 'tiles'; END IF;
    SELECT string_agg(t ->> 'item_type', ', ') INTO v_bad FROM jsonb_array_elements(v_b -> 'tiles') t
     WHERE (t ->> 'count')::bigint <> (SELECT count(*) FROM operations_arms_all a WHERE a.item_type = t ->> 'item_type');
    IF (v_bad IS NOT NULL) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 273 COUNTS: each tile counts the rows of its arm; wrong: %', v_bad; END IF;
    IF ((SELECT (t ->> 'count')::int FROM jsonb_array_elements(v_b -> 'tiles') t WHERE t ->> 'item_type' = 'stocktake_open') <> 2
        OR (SELECT t ->> 'section' FROM jsonb_array_elements(v_b -> 'tiles') t WHERE t ->> 'item_type' = 'stocktake_open') <> 'inventory') IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 273 COUNTS: two open stocktakes → stocktake_open 2 in the stock section, got %', v_b -> 'tiles'; END IF;
    IF ((SELECT array_agg(t ->> 'item_type' ORDER BY ord) FROM jsonb_array_elements(v_b -> 'tiles') WITH ORDINALITY x(t, ord))
        IS DISTINCT FROM (SELECT array_agg(item_type ORDER BY sort_order) FROM floor_board_arms())
        OR jsonb_typeof(v_b -> 'refresh_seconds') <> 'null' OR (v_b ->> 'settings_set')::boolean IS NOT FALSE) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 273 COUNTS: V28 not set → every floor arm in section order, no refresh interval (nothing guessed), got %', v_b - 'tiles'; END IF;

    -- ══════════════ GATE ══════════════
    RAISE NOTICE 'fixture 273 · GATE';
    v_msg := pg_temp.f273_do(u_none, $q$SELECT floor_board()$q$);
    IF (v_msg NOT LIKE 'PERMISSION_DENIED|data.view_floor_board%') IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 273 GATE: a session without the code is refused by name, got %', v_msg; END IF;
    IF (pg_temp.f273_do(u_all, $q$SELECT floor_board()$q$) <> 'OK' OR pg_temp.f273_do(u_codeonly, $q$SELECT floor_board()$q$) <> 'OK') IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 273 GATE: any holder of the code reads the board'; END IF;
    v_x := pg_temp.f273_get(u_floor, $q$SELECT jsonb_build_object('ops', (SELECT count(*) FROM operations_now), 'ib', (SELECT count(*) FROM inbound_batches),
                                                                  'inc', (SELECT count(*) FROM incidents), 'st', (SELECT count(*) FROM stocktakes))$q$);
    IF ((v_x ->> 'ops')::int <> 0 OR (v_x ->> 'ib')::int <> 0 OR (v_x ->> 'inc')::int <> 0 OR (v_x ->> 'st')::int <> 0) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 273 GATE: a display session reads no row anywhere — only the counts, got %', v_x; END IF;

    -- ══════════════ IDLE ══════════════
    RAISE NOTICE 'fixture 273 · IDLE';
    IF (pg_temp.f273_exempt(u_floor) IS NOT TRUE) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 273 IDLE: only floor_display, only data.view_floor_board → exempt'; END IF;
    IF (pg_temp.f273_exempt(NULL) IS NOT FALSE) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 273 IDLE: no session → not exempt'; END IF;
    IF (pg_temp.f273_exempt(u_codeonly) IS NOT FALSE) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 273 IDLE: the code held through another role is not the display role → not exempt'; END IF;
    IF (pg_temp.f273_exempt(u_all) IS NOT FALSE OR pg_temp.f273_exempt(u_none) IS NOT FALSE OR pg_temp.f273_exempt(u_mgr) IS NOT FALSE) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 273 IDLE: an all-codes, an HR and an account-manager session keep the idle logout'; END IF;
    -- 重建库里每一个别的角色(真角色的引导),挂在一个账号上 → 不豁免
    FOR rr IN SELECT id, code FROM roles WHERE code <> 'floor_display' AND deleted_at IS NULL ORDER BY code LOOP
        u_x := pg_temp.f273_account('role-' || rr.code);
        INSERT INTO user_roles (user_id, role_id) VALUES (u_x, rr.id);
        IF (pg_temp.f273_exempt(u_x) IS NOT FALSE) IS NOT FALSE THEN
            RAISE EXCEPTION 'FIXTURE 273 IDLE: a session holding role % keeps the idle logout', rr.code; END IF;
    END LOOP;
    -- floor_display + 另一个角色(零个码)→ 不豁免;撤掉那一个 → 回到豁免
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx273-empty', 'f', 'f', true) RETURNING id INTO v_ur;
    INSERT INTO user_roles (user_id, role_id) VALUES (u_floor, v_ur);
    IF (pg_temp.f273_exempt(u_floor) IS NOT FALSE) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 273 IDLE: any other role on the account (even one with no code) removes the exemption'; END IF;
    UPDATE user_roles SET revoked_at = now() WHERE user_id = u_floor AND role_id = v_ur;
    IF (pg_temp.f273_exempt(u_floor) IS NOT TRUE) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 273 IDLE: once the other role is revoked, the display is exempt again'; END IF;
    -- floor_display 多【任何一个】码 → 不豁免,而 /display 的码照样在(目录里逐码试)
    v_n := 0;
    FOR c IN SELECT code FROM permissions WHERE code <> 'data.view_floor_board' ORDER BY code LOOP
        INSERT INTO role_permissions (role_id, permission_code) VALUES (r_floor, c);
        IF (pg_temp.f273_exempt(u_floor) IS NOT FALSE) IS NOT FALSE THEN
            RAISE EXCEPTION 'FIXTURE 273 IDLE: floor_display holding % as well keeps the idle logout', c; END IF;
        IF (pg_temp.f273_do(u_floor, $q$SELECT floor_board()$q$) <> 'OK') IS NOT FALSE THEN
            RAISE EXCEPTION 'FIXTURE 273 IDLE: with % added the board still opens', c; END IF;
        DELETE FROM role_permissions WHERE role_id = r_floor AND permission_code = c;
        v_n := v_n + 1;
    END LOOP;
    IF (v_n < 80 OR pg_temp.f273_exempt(u_floor) IS NOT TRUE) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 273 IDLE: every other catalogue code was tried (% codes) and the display is exempt again afterwards', v_n; END IF;
    -- 角色停用 → 不豁免(它也就没有码了)
    UPDATE roles SET is_active = false WHERE id = r_floor;
    IF (pg_temp.f273_exempt(u_floor) IS NOT FALSE) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 273 IDLE: an inactive floor_display role exempts nobody'; END IF;
    UPDATE roles SET is_active = true WHERE id = r_floor;

    -- ══════════════ V28 ══════════════
    RAISE NOTICE 'fixture 273 · V28';
    -- 本 fixture 的大屏账号是 u_floor;先把它停掉一下,看"没有大屏就没有那一行"
    UPDATE user_roles SET revoked_at = now() WHERE user_id = u_floor AND role_id = r_floor;
    v_x := pg_temp.f273_get(u_mgr, $q$SELECT to_jsonb(count(*)) FROM pending_values WHERE value_code = 'V28'$q$);
    IF ((v_x #>> '{}')::int <> 0) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 273 V28: no display account → no V28 row (nobody can act on it yet), got %', v_x; END IF;
    INSERT INTO user_roles (user_id, role_id) VALUES (u_floor, r_floor);
    v_x := pg_temp.f273_get(u_mgr, $q$SELECT jsonb_agg(to_jsonb(p)) FROM pending_values p WHERE value_code = 'V28'$q$);
    IF (jsonb_array_length(v_x) <> 1 OR v_x -> 0 ->> 'href' <> '/display' OR v_x -> 0 ->> 'permission' <> 'action.manage_permissions') IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 273 V28: a display account exists → one V28 row for the account manager, pointing at /display, got %', v_x; END IF;
    v_x := pg_temp.f273_get(u_floor, $q$SELECT to_jsonb(count(*)) FROM pending_values WHERE value_code = 'V28'$q$);
    IF ((v_x #>> '{}')::int <> 0) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 273 V28: the display itself does not see the V28 row, got %', v_x; END IF;
    v_msg := pg_temp.f273_do(u_mgr, $q$SELECT set_floor_board_settings(60, NULL)$q$);
    PERFORM pg_temp.f273_expect_like(v_msg, 'FLOOR_BOARD_SETTINGS_PAIR_INCOMPLETE%');
    v_msg := pg_temp.f273_do(u_mgr, $q$SELECT set_floor_board_settings(NULL, ARRAY['stocktake_open'])$q$);
    PERFORM pg_temp.f273_expect_like(v_msg, 'FLOOR_BOARD_SETTINGS_PAIR_INCOMPLETE%');
    v_msg := pg_temp.f273_do(u_mgr, $q$SELECT set_floor_board_settings(0, ARRAY['stocktake_open'])$q$);
    PERFORM pg_temp.f273_expect_like(v_msg, 'FLOOR_BOARD_REFRESH_INVALID%');
    v_msg := pg_temp.f273_do(u_mgr, $q$SELECT set_floor_board_settings(60, ARRAY[]::text[])$q$);
    PERFORM pg_temp.f273_expect_like(v_msg, 'FLOOR_BOARD_TILES_EMPTY%');
    v_msg := pg_temp.f273_do(u_mgr, $q$SELECT set_floor_board_settings(60, ARRAY['ap_over_90'])$q$);
    PERFORM pg_temp.f273_expect_like(v_msg, 'FLOOR_BOARD_TILE_UNKNOWN|ap_over_90%');
    v_msg := pg_temp.f273_do(u_mgr, $q$SELECT set_floor_board_settings(60, ARRAY['stocktake_open', 'stocktake_open'])$q$);
    PERFORM pg_temp.f273_expect_like(v_msg, 'FLOOR_BOARD_TILE_DUPLICATE|stocktake_open%');
    v_msg := pg_temp.f273_do(u_floor, $q$SELECT set_floor_board_settings(60, ARRAY['stocktake_open'])$q$);
    PERFORM pg_temp.f273_expect_like(v_msg, 'PERMISSION_DENIED|action.manage_permissions%');
    v_msg := pg_temp.f273_do(u_mgr, $q$SELECT set_floor_board_settings(45, ARRAY['stocktake_open', 'inspection_due'])$q$);
    PERFORM pg_temp.f273_expect_like(v_msg, 'OK');
    v_b := pg_temp.f273_get(u_floor, $q$SELECT floor_board()$q$);
    IF ((SELECT array_agg(t ->> 'item_type' ORDER BY ord) FROM jsonb_array_elements(v_b -> 'tiles') WITH ORDINALITY x(t, ord)) IS DISTINCT FROM ARRAY['stocktake_open', 'inspection_due']
        OR (v_b ->> 'refresh_seconds')::int <> 45 OR (v_b ->> 'settings_set')::boolean IS NOT TRUE) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 273 V28: set → only the chosen tiles, in the chosen order, and the interval, got %', v_b; END IF;
    v_x := pg_temp.f273_get(u_mgr, $q$SELECT to_jsonb(count(*)) FROM pending_values WHERE value_code = 'V28'$q$);
    IF ((v_x #>> '{}')::int <> 0) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 273 V28: once set, the V28 row is gone, got %', v_x; END IF;
    v_msg := pg_temp.f273_do(u_mgr, $q$SELECT set_floor_board_settings(NULL, NULL)$q$);
    PERFORM pg_temp.f273_expect_like(v_msg, 'OK');
    v_b := pg_temp.f273_get(u_floor, $q$SELECT floor_board()$q$);
    IF (jsonb_array_length(v_b -> 'tiles') <> 23 OR jsonb_typeof(v_b -> 'refresh_seconds') <> 'null') IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 273 V28: cleared → every floor arm again, no interval, got %', v_b - 'tiles'; END IF;

    -- ══════════════ LOG ══════════════
    RAISE NOTICE 'fixture 273 · LOG';
    v_x := change_log_coverage_gaps();
    IF (jsonb_array_length(v_x -> 'gaps') <> 0 OR (v_x ->> 'excluded')::int <> 9) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 273 LOG: change-log coverage (gaps 0, exclusions 9): %', v_x; END IF;
    IF (NOT EXISTS (SELECT 1 FROM pg_trigger g WHERE g.tgname = 'zzz_change_log' AND g.tgrelid = 'public.floor_board_settings'::regclass)) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 273 LOG: floor_board_settings is change-logged'; END IF;
    IF ((SELECT provolatile FROM pg_proc WHERE oid = 'public.floor_board()'::regprocedure) <> 's'
        OR (SELECT provolatile FROM pg_proc WHERE oid = 'public.session_is_floor_display_only()'::regprocedure) <> 's') IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 273 LOG: the board and the exemption predicate are STABLE (they write nothing)'; END IF;

    RAISE NOTICE 'FIXTURE 273 全部通过: REG · ARMS · COUNTS · GATE · IDLE · V28 · LOG';
END
$$;

ROLLBACK;
