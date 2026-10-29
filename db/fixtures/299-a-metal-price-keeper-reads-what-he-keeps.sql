-- ═══════════════════════════════════════════════════════════════════════════
-- fixture 299 —— 持 action.metal_prices 的人读得到他维护的三样东西(GOLIVE-1 第 1 行,Tim 2026-10-20 d2 #2 · 2026-10-29 Q6)
-- ═══════════════════════════════════════════════════════════════════════════
-- 【钉的事】一个【只】持 action.metal_prices 的角色(今天线上没有这样的角色 —— admin 与 finance 都另持 module.pricing.view;
--   这一支钉的是"将来只给这个码的人"):
--   A  读得到 metal_prices · index_market_calendar · pricing_settings 里本支自造 / 引导的行(三张一起,Q6);
--   B  一个码都不持的会话:三张都是 0 行(收窄的那一半没有被这一次放宽带走);
--   C  ★ 故障注入(每次都跑):在一个子事务里把 metal_prices 的读策略换回本刀之前那一句(不含 action.metal_prices),
--      A 那一臂的判据必须读出 0 行 —— 证明 A 读到的行真的是这一句放进来的,不是别的哪条路;子事务回滚,策略回到原样。
-- 【身份】读都在 SET LOCAL ROLE authenticated 下(RLS 真的在判),判断由 request.jwt.claims 的 sub 决定。
-- 自带数据(README 第 2 条):角色、授予、一天的行情与日历本支自造;pricing_settings 是引导的单行配置(稳定的引导数据)。
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
SET LOCAL statement_timeout = '120s';

CREATE FUNCTION pg_temp.f299_counts(p_user uuid) RETURNS int[]
LANGUAGE plpgsql AS $f$
DECLARE a int; b int; c int;
BEGIN
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', p_user), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO a FROM metal_prices WHERE source = 'published_index' AND price_date = DATE '2026-09-01' AND metal = 'ni' AND price_index = 'LME';
    SELECT count(*) INTO b FROM index_market_calendar WHERE note = 'fixture 299';
    SELECT count(*) INTO c FROM pricing_settings;
    EXECUTE 'RESET ROLE';
    RETURN ARRAY[a, b, c];
END;
$f$;

DO $f299$
DECLARE
    u_act  uuid := '00000000-0000-4000-8000-0000029900a1';
    u_none uuid := '00000000-0000-4000-8000-0000029900a2';
    v int[];
    v_old text;
BEGIN
    INSERT INTO roles (code, name_en, name_zh) VALUES ('zz-fx299-metal-only', 'ZZ fixture 299', 'ZZ fixture 299');
    INSERT INTO role_permissions (role_id, permission_code) SELECT id, 'action.metal_prices' FROM roles WHERE code = 'zz-fx299-metal-only';
    INSERT INTO user_roles (user_id, role_id) SELECT u_act, id FROM roles WHERE code = 'zz-fx299-metal-only';
    INSERT INTO index_market_calendar (index_code, calendar_date, is_trading_day, note) VALUES ('LME', DATE '2026-09-01', true, 'fixture 299');
    INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date, source, price_index) VALUES ('ni', 10000, DATE '2026-09-01', 'published_index', 'LME');

    -- A
    v := pg_temp.f299_counts(u_act);
    IF v[1] < 1 OR v[2] <> 1 OR v[3] < 1 THEN
        RAISE EXCEPTION 'FIXTURE 299 A: a reader holding only action.metal_prices should read the price, the calendar day and the threshold — got metal_prices % · calendar % · pricing_settings %', v[1], v[2], v[3];
    END IF;
    -- B
    v := pg_temp.f299_counts(u_none);
    IF v <> ARRAY[0, 0, 0] THEN
        RAISE EXCEPTION 'FIXTURE 299 B: a session with no code should read nothing — got %', v;
    END IF;
    -- C · 故障注入:策略换回本刀之前那一句,A 的判据必须变成 0
    BEGIN
        DROP POLICY "metal_prices select by permission" ON metal_prices;
        CREATE POLICY "metal_prices select by permission" ON metal_prices AS PERMISSIVE FOR SELECT TO authenticated
            USING ((SELECT has_any_permission(ARRAY['module.pricing.view'::text, 'module.suppliers.view'::text, 'module.inventory.view'::text, 'module.materials.view'::text])));
        v := pg_temp.f299_counts(u_act);
        IF v[1] <> 0 THEN
            RAISE EXCEPTION 'FIXTURE 299 C: with the old read policy the action-only reader still read % metal price row(s) — arm A does not measure the new policy', v[1];
        END IF;
        RAISE EXCEPTION 'f299 injection ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'f299 injection ok' THEN RAISE; END IF;
    END;
    -- 子事务回滚之后,策略是本刀那一句
    SELECT qual INTO v_old FROM pg_policies WHERE tablename = 'metal_prices' AND policyname = 'metal_prices select by permission';
    IF v_old NOT LIKE '%action.metal_prices%' THEN
        RAISE EXCEPTION 'FIXTURE 299 C: the injection did not roll back — policy is %', v_old;
    END IF;
    RAISE NOTICE 'FIXTURE 299 全部通过: action.metal_prices 一个码读得到行情 · 日历 · 阈值(A);零码的会话三张都是 0(B);故障注入换回旧策略,A 的判据读出 0(C)';
END
$f299$;
ROLLBACK;
