-- 294 TABLE-FEATURES-3:一个保存的视图只属于存它的那个人;每人每张列表至多一个默认(Tim 2026-10-25 Q3 · 2026-10-26 Q1–Q3)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】
--   S  本人存、读、改、删自己的视图;user_id 不写也落到本人(DEFAULT auth.uid())
--   X  ★ 别人:读到 0 行;改 / 删【零行】(RLS 让语句什么都碰不到 —— 断言的是行还在、值没变,不是"没报错");
--      以别人的 user_id 插入 → 被 WITH CHECK 拒
--   D  ★ 每人每张列表至多一个默认:同一张列表第二个默认被唯一索引拒;另一张列表各自有一个默认照走;
--      另一个人在同一张列表上有自己的默认照走
--   N  名字:同人同列表重名被拒;空白名字、超过 60 字被拒;list_key 不是路由的形状被拒
--   A  anon 对这张表没有任何权限;没有写闸(谓词是 user_id = auth.uid(),fixture 198 点名豁免)
--   C  账号删掉,视图跟着走(ON DELETE CASCADE)
--
-- 自带数据(README 第 2 条)。RLS 断言一律在 SET LOCAL ROLE authenticated 之下、一律 RAISE。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '60s';

-- 以某人的身份跑一句,返回 'OK' 或那一句拒绝
CREATE FUNCTION pg_temp.f294_try(p_user uuid, p_sql text) RETURNS text
LANGUAGE plpgsql AS $f$
BEGIN
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', p_user), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql;
    EXECUTE 'RESET ROLE';
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    RETURN SQLERRM;
END;
$f$;

-- 以某人的身份数一句(RLS 生效)
CREATE FUNCTION pg_temp.f294_count(p_user uuid, p_sql text) RETURNS int
LANGUAGE plpgsql AS $f$
DECLARE n int;
BEGIN
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', p_user), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    IF current_user <> 'authenticated' OR auth.uid() IS DISTINCT FROM p_user THEN
        RAISE EXCEPTION 'FIXTURE 294 布景失败:身份没有切过去(%, %)', current_user, auth.uid(); END IF;
    EXECUTE p_sql INTO n;
    EXECUTE 'RESET ROLE';
    RETURN n;
END;
$f$;

DO $$
DECLARE
    u_a uuid := gen_random_uuid();
    u_b uuid := gen_random_uuid();
    v_a1 uuid; v_msg text; v_n int;
BEGIN
    INSERT INTO auth.users (id, email_confirmed_at) VALUES (u_a, now()), (u_b, now());

    -- ── S · 本人 ──
    v_msg := pg_temp.f294_try(u_a, $s$INSERT INTO saved_views (list_key, name, query, is_default)
        VALUES ('/finance/expenses', 'Unpaid this month', 'status=unpaid&date_preset=thisMonth', true)$s$);
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 294S 失败:本人存不下视图:%', v_msg; END IF;
    SELECT id INTO v_a1 FROM saved_views WHERE user_id = u_a AND name = 'Unpaid this month';
    IF v_a1 IS NULL THEN RAISE EXCEPTION 'FIXTURE 294S 失败:user_id 没有落到本人(DEFAULT auth.uid())'; END IF;
    IF pg_temp.f294_count(u_a, 'SELECT count(*) FROM saved_views') <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 294S 失败:本人读不到自己的视图'; END IF;
    v_msg := pg_temp.f294_try(u_a, format($s$UPDATE saved_views SET query = 'status=paid' WHERE id = %L$s$, v_a1));
    IF v_msg <> 'OK' OR (SELECT query FROM saved_views WHERE id = v_a1) <> 'status=paid' THEN
        RAISE EXCEPTION 'FIXTURE 294S 失败:本人改不了自己的视图:%', v_msg; END IF;
    RAISE NOTICE '  ✓ S 本人存 / 读 / 改自己的视图';

    -- ── X · 别人 ──
    IF pg_temp.f294_count(u_b, 'SELECT count(*) FROM saved_views') <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 294X 失败:别人读到了不是自己的视图'; END IF;
    v_msg := pg_temp.f294_try(u_b, format($s$UPDATE saved_views SET query = 'hijacked', name = 'x' WHERE id = %L$s$, v_a1));
    IF (SELECT query FROM saved_views WHERE id = v_a1) <> 'status=paid' THEN
        RAISE EXCEPTION 'FIXTURE 294X 失败:别人改动了本人的视图(%)', v_msg; END IF;
    v_msg := pg_temp.f294_try(u_b, format($s$DELETE FROM saved_views WHERE id = %L$s$, v_a1));
    IF NOT EXISTS (SELECT 1 FROM saved_views WHERE id = v_a1) THEN
        RAISE EXCEPTION 'FIXTURE 294X 失败:别人删掉了本人的视图(%)', v_msg; END IF;
    v_msg := pg_temp.f294_try(u_b, format($s$INSERT INTO saved_views (user_id, list_key, name, query)
        VALUES (%L, '/finance/expenses', 'planted', 'x=1')$s$, u_a));
    IF v_msg NOT LIKE '%row-level security%' THEN
        RAISE EXCEPTION 'FIXTURE 294X 失败:以别人的 user_id 插入应被 WITH CHECK 拒,实为 %', v_msg; END IF;
    RAISE NOTICE '  ✓ X 别人读 0 行;改 / 删碰不到(行还在、值没变);冒名插入被拒';

    -- ── D · 默认 ──
    v_msg := pg_temp.f294_try(u_a, $s$INSERT INTO saved_views (list_key, name, query, is_default)
        VALUES ('/finance/expenses', 'Second default', 'status=paid', true)$s$);
    IF v_msg NOT LIKE '%saved_views_one_default%' THEN
        RAISE EXCEPTION 'FIXTURE 294D 失败:同一张列表第二个默认应被唯一索引拒,实为 %', v_msg; END IF;
    v_msg := pg_temp.f294_try(u_a, $s$INSERT INTO saved_views (list_key, name, query, is_default)
        VALUES ('/finance/invoices', 'Overdue', 'state=overdue', true)$s$);
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 294D 失败:另一张列表的默认应照走:%', v_msg; END IF;
    v_msg := pg_temp.f294_try(u_b, $s$INSERT INTO saved_views (list_key, name, query, is_default)
        VALUES ('/finance/expenses', 'Mine', 'status=unpaid', true)$s$);
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 294D 失败:另一个人在同一张列表上的默认应照走:%', v_msg; END IF;
    RAISE NOTICE '  ✓ D 每人每张列表至多一个默认;别的列表、别的人各自照走';

    -- ── N · 名字与 list_key ──
    v_msg := pg_temp.f294_try(u_a, $s$INSERT INTO saved_views (list_key, name, query) VALUES ('/finance/expenses', 'Unpaid this month', 'a=1')$s$);
    IF v_msg NOT LIKE '%saved_views_name_unique%' THEN
        RAISE EXCEPTION 'FIXTURE 294N 失败:同人同列表重名应被拒,实为 %', v_msg; END IF;
    v_msg := pg_temp.f294_try(u_a, $s$INSERT INTO saved_views (list_key, name, query) VALUES ('/finance/expenses', '   ', 'a=1')$s$);
    IF v_msg NOT LIKE '%saved_views_name_check%' THEN
        RAISE EXCEPTION 'FIXTURE 294N 失败:空白名字应被拒,实为 %', v_msg; END IF;
    v_msg := pg_temp.f294_try(u_a, format($s$INSERT INTO saved_views (list_key, name, query) VALUES ('/finance/expenses', %L, 'a=1')$s$, repeat('x', 61)));
    IF v_msg NOT LIKE '%saved_views_name_check%' THEN
        RAISE EXCEPTION 'FIXTURE 294N 失败:61 字的名字应被拒,实为 %', v_msg; END IF;
    v_msg := pg_temp.f294_try(u_a, $s$INSERT INTO saved_views (list_key, name, query) VALUES ('https://evil.example/x', 'n', 'a=1')$s$);
    IF v_msg NOT LIKE '%saved_views_list_key_check%' THEN
        RAISE EXCEPTION 'FIXTURE 294N 失败:不是路由形状的 list_key 应被拒,实为 %', v_msg; END IF;
    RAISE NOTICE '  ✓ N 重名 · 空白名 · 超长名 · 非路由 list_key 各被按约束名拒';

    -- ── A · anon 与写闸 ──
    IF has_table_privilege('anon', 'public.saved_views', 'SELECT') OR has_table_privilege('anon', 'public.saved_views', 'INSERT')
       OR has_table_privilege('anon', 'public.saved_views', 'UPDATE') OR has_table_privilege('anon', 'public.saved_views', 'DELETE') THEN
        RAISE EXCEPTION 'FIXTURE 294A 失败:anon 对 saved_views 有权限'; END IF;
    IF has_table_privilege('authenticated', 'public.saved_views', 'TRUNCATE') THEN
        RAISE EXCEPTION 'FIXTURE 294A 失败:authenticated 能清空 saved_views'; END IF;
    PERFORM 1 FROM pg_trigger WHERE tgrelid = 'public.saved_views'::regclass AND tgname = 'enforce_write_permission';
    IF FOUND THEN RAISE EXCEPTION 'FIXTURE 294A 失败:saved_views 装上了写闸(谓词是 user_id = auth.uid(),不是权限问题)'; END IF;
    RAISE NOTICE '  ✓ A anon 无权限;authenticated 不能清空;没有写闸';

    -- ── C · 账号删掉,视图跟着走 ──
    DELETE FROM auth.users WHERE id = u_a;
    SELECT count(*) INTO v_n FROM saved_views WHERE user_id = u_a;
    IF v_n <> 0 THEN RAISE EXCEPTION 'FIXTURE 294C 失败:账号删掉之后还剩 % 个视图', v_n; END IF;
    RAISE NOTICE '  ✓ C 账号删掉,视图跟着走';

    RAISE NOTICE 'FIXTURE 294 全部通过: 视图只属于本人 · 别人碰不到 · 每人每张列表一个默认 · 名字与 list_key 有约束 · anon 无权限';
END $$;

ROLLBACK;
