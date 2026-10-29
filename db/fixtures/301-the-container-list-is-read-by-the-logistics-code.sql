-- ═══════════════════════════════════════════════════════════════════════════
-- fixture 301 —— 货柜清单的读者 = module.logistics.view(GOLIVE-1 第 6 行,Tim 2026-10-20 d2 #30)
-- ═══════════════════════════════════════════════════════════════════════════
-- 【钉的事】container_overview(属主权限视图,门写在视图体里):
--   A  只持 module.logistics.view 的读者读得到本支自造的货柜(CONV-6 那三个角色 —— operations · sales · warehouse —— 当年读到的是空集)
--   B  只持 module.purchasing.view 的读者:0 行(FIX-2a 留下的 purchasing OR logistics 收成一个码;线上持 purchasing 的 9 个角色
--      每一个都持 logistics,所以没有一个真角色丢路 —— 那是一次线上读数,不是这支 fixture 能证的)
--   C  一个码都不持的会话:0 行
--   D  ★ 故障注入(每次都跑):子事务里把视图的谓词换回 purchasing,A 的判据必须读出 0、B 的判据必须读出 1;子事务回滚
-- 自带数据:角色、授予、一只货柜本支自造。
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
SET LOCAL statement_timeout = '120s';

CREATE FUNCTION pg_temp.f301_n(p_user uuid) RETURNS int
LANGUAGE plpgsql AS $f$
DECLARE n int;
BEGIN
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', p_user), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO n FROM container_overview WHERE code = 'CTR-2099-0301';
    EXECUTE 'RESET ROLE';
    RETURN n;
END;
$f$;

DO $f301$
DECLARE
    u_log  uuid := '00000000-0000-4000-8000-0000030100a1';
    u_pur  uuid := '00000000-0000-4000-8000-0000030100a2';
    u_none uuid := '00000000-0000-4000-8000-0000030100a3';
    v_def  text;
BEGIN
    INSERT INTO roles (code, name_en, name_zh) VALUES ('zz-fx301-log', 'ZZ fixture 301 logistics', 'ZZ fixture 301 logistics'),
                                                      ('zz-fx301-pur', 'ZZ fixture 301 purchasing', 'ZZ fixture 301 purchasing');
    INSERT INTO role_permissions (role_id, permission_code) SELECT id, 'module.logistics.view' FROM roles WHERE code = 'zz-fx301-log';
    INSERT INTO role_permissions (role_id, permission_code) SELECT id, 'module.purchasing.view' FROM roles WHERE code = 'zz-fx301-pur';
    INSERT INTO user_roles (user_id, role_id) SELECT u_log, id FROM roles WHERE code = 'zz-fx301-log';
    INSERT INTO user_roles (user_id, role_id) SELECT u_pur, id FROM roles WHERE code = 'zz-fx301-pur';
    INSERT INTO containers (code, container_number, departure_date) VALUES ('CTR-2099-0301', 'ZZFU3010001', DATE '2026-10-01');

    IF pg_temp.f301_n(u_log) <> 1 THEN RAISE EXCEPTION 'FIXTURE 301 A: a logistics-only reader read % container row(s) (want 1)', pg_temp.f301_n(u_log); END IF;
    IF pg_temp.f301_n(u_pur) <> 0 THEN RAISE EXCEPTION 'FIXTURE 301 B: a purchasing-only reader still reads the container list'; END IF;
    IF pg_temp.f301_n(u_none) <> 0 THEN RAISE EXCEPTION 'FIXTURE 301 C: a session with no code reads the container list'; END IF;

    -- D · 故障注入:谓词换回 purchasing
    v_def := pg_get_viewdef('public.container_overview'::regclass);
    IF v_def NOT LIKE '%module.logistics.view%' OR v_def LIKE '%purchasing%' THEN
        RAISE EXCEPTION 'FIXTURE 301 D: the view predicate is not the logistics code alone: %', v_def;
    END IF;
    BEGIN
        EXECUTE 'CREATE OR REPLACE VIEW public.container_overview WITH (security_invoker = off) AS '
             || replace(rtrim(v_def, '; ' || chr(10)), 'module.logistics.view', 'module.purchasing.view');
        IF pg_temp.f301_n(u_log) <> 0 OR pg_temp.f301_n(u_pur) <> 1 THEN
            RAISE EXCEPTION 'FIXTURE 301 D: with the old predicate arms A / B read % / % (want 0 / 1) — they do not measure the predicate',
                pg_temp.f301_n(u_log), pg_temp.f301_n(u_pur);
        END IF;
        RAISE EXCEPTION 'f301 injection ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'f301 injection ok' THEN RAISE; END IF;
    END;
    IF pg_get_viewdef('public.container_overview'::regclass) LIKE '%purchasing%' THEN RAISE EXCEPTION 'FIXTURE 301 D: the injection did not roll back'; END IF;
    RAISE NOTICE 'FIXTURE 301 全部通过: 只持物流码的读者读得到货柜(A);只持采购码的 0 行(B);零码 0 行(C);谓词换回采购,A / B 的判据随之翻过来(D)';
END
$f301$;
ROLLBACK;
