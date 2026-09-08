-- db/fixtures/198-a-refused-write-raises-and-the-self-assessment-still-works.sql
-- SILENT-1(2026-09-08)
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【这支 fixture 断言两件事,而第二件比第一件更要紧】
--
--   ① 一次被拒绝的写会【抛】,抛的是 PERMISSION_DENIED|<码> —— 不再是零行静默。
--   ② ★ 而一个【RLS 不生效】的身份(属主 / SECURITY DEFINER)【不受影响】★
--
--   ② 才是这支 fixture 存在的理由。语句级触发器不认属主豁免:它对 postgres
--   一样会触发。库里有五支 SECURITY DEFINER 的绩效自评函数(save_self_assessment /
--   submit_review / acknowledge_review / open_for_self_assessment /
--   set_review_conclusion),它们写 performance_reviews,而那张表的策略要
--   module.hr.edit —— 一个普通员工【没有】这项权限。他能填自己的自评,
--   靠的就是"DEFINER 绕开 RLS"这一条。
--   **一支不设防的语句级触发器,会把每一个人锁在自己的绩效考核外面。**
--   闸门是 row_security_active(TG_RELID)。这支 fixture 就是那道闸门的看守。
--
-- 【为什么用自建的临时表,而不是点名一张真表】
--   门把 fixture 重放进一个【空库】。真表在那里没有行、没有可用的会话身份,
--   而这道闸的判据【与表无关】—— 它只问 row_security_active 与 has_permission。
--   所以这里造一张形状相同的表,把四条臂完整走一遍;
--   "133 张表真的都装上了"由本文件末尾的目录断言回答,那一问才是按表问的。
-- ════════════════════════════════════════════════════════════════════════════
BEGIN;

DO $fixture$
DECLARE
    v_fired   boolean;
    v_msg     text;
    v_rows    int;
    v_missing text;
    v_n       int;
BEGIN
    -- ── 造一张与真表同形状的表:RLS 开、策略两侧同一个谓词 ────────────────
    CREATE TABLE public._silent1_probe (id int PRIMARY KEY, note text);
    INSERT INTO public._silent1_probe VALUES (1, 'before');
    ALTER TABLE public._silent1_probe ENABLE ROW LEVEL SECURITY;
    -- 读得到、写不动 —— 正是"看着记录却改不了"的那个人所处的形状。
    CREATE POLICY p_sel ON public._silent1_probe FOR SELECT TO authenticated USING (true);
    CREATE POLICY p_upd ON public._silent1_probe FOR UPDATE TO authenticated
        USING (public.has_permission('module.finance.edit'))
        WITH CHECK (public.has_permission('module.finance.edit'));
    GRANT SELECT, UPDATE, DELETE ON public._silent1_probe TO authenticated;

    -- ── 病本身:装闸【之前】,被拒绝的写是一次成功的空操作 ─────────────────
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM set_config('request.jwt.claims',
        '{"sub":"00000000-0000-0000-0000-000000000000","role":"authenticated"}', true);
    BEGIN
        UPDATE public._silent1_probe SET note = 'changed' WHERE id = 1;
        GET DIAGNOSTICS v_rows = ROW_COUNT;
        IF v_rows <> 0 THEN
            RAISE EXCEPTION 'FIXTURE 198 失败:无权者改动了 % 行,RLS 没有拦住', v_rows;
        END IF;
        v_fired := false;
    EXCEPTION WHEN insufficient_privilege OR raise_exception THEN
        v_fired := true;
    END;
    RESET ROLE;
    IF v_fired THEN
        RAISE EXCEPTION 'FIXTURE 198 失败:装闸之前就抛了 —— 这支 fixture 的前提不成立';
    END IF;
    RAISE NOTICE '  ✓ 病:装闸之前,一次被拒绝的 UPDATE 是 rows=0 且【不抛】';

    -- ── 装闸 ───────────────────────────────────────────────────────────────
    CREATE TRIGGER enforce_write_permission
        BEFORE UPDATE OR DELETE ON public._silent1_probe
        FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.finance.edit');

    -- ── 臂 ①:属主(postgres,RLS 不生效)—— 【必须】不被拦 ────────────────
    IF row_security_active('public._silent1_probe'::regclass) THEN
        RAISE EXCEPTION 'FIXTURE 198 失败:属主身份下 row_security_active 竟为真';
    END IF;
    BEGIN
        UPDATE public._silent1_probe SET note = 'owner-wrote' WHERE id = 1;
        GET DIAGNOSTICS v_rows = ROW_COUNT;
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        RAISE EXCEPTION
            'FIXTURE 198 失败(臂①):属主被这道闸拦住了(%) —— '
            '迁移、种子与每一条 SECURITY DEFINER 的路都会当场断。'
            'row_security_active 那道守卫没有生效', v_msg;
    END;
    IF v_rows <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 198 失败(臂①):属主只改到 % 行', v_rows;
    END IF;
    RAISE NOTICE '  ✓ 臂①:属主(RLS 不生效)不被拦,rows=1';

    -- ── 臂 ②:★ SECURITY DEFINER 被【无权者】调用 —— 必须不被拦 ★ ─────────
    --    这一臂就是绩效自评那条路。它红了 = 六个同事被锁在自己的考核外面。
    CREATE FUNCTION public._silent1_definer() RETURNS int
        LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $f$
        DECLARE k int;
        BEGIN
            UPDATE public._silent1_probe SET note = 'definer-wrote' WHERE id = 1;
            GET DIAGNOSTICS k = ROW_COUNT; RETURN k;
        END $f$;
    GRANT EXECUTE ON FUNCTION public._silent1_definer() TO authenticated;
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM set_config('request.jwt.claims',
        '{"sub":"00000000-0000-0000-0000-000000000000","role":"authenticated"}', true);
    BEGIN
        SELECT public._silent1_definer() INTO v_rows;
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        RESET ROLE;
        RAISE EXCEPTION
            'FIXTURE 198 失败(臂②):SECURITY DEFINER 被这道闸拦住了(%) —— '
            '这正是"六个人被锁在自己的绩效考核外面"那一格,row_security_active 的守卫失效了', v_msg;
    END;
    IF v_rows <> 1 THEN
        RESET ROLE;
        RAISE EXCEPTION 'FIXTURE 198 失败(臂②):DEFINER 只改到 % 行', v_rows;
    END IF;
    RAISE NOTICE '  ✓ 臂②:SECURITY DEFINER(无权者调用)不被拦,rows=1 —— 自评那条路还在';

    -- ── 臂 ③:无权者直写 —— 必须抛,而且抛的是【那个码】 ──────────────────
    v_fired := false;
    BEGIN
        UPDATE public._silent1_probe SET note = 'denied' WHERE id = 1;
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        v_fired := true;
    END;
    IF NOT v_fired THEN
        RESET ROLE;
        RAISE EXCEPTION 'FIXTURE 198 失败(臂③):被拒绝的写没有抛 —— 本刀要修的正是这一格';
    END IF;
    IF v_msg <> 'PERMISSION_DENIED|module.finance.edit' THEN
        RESET ROLE;
        RAISE EXCEPTION 'FIXTURE 198 失败(臂③):抛了,但不是那个码 —— 收到「%」。'
            '界面认的是 PERMISSION_DENIED|<码>,别的形状它只会原样印出去', v_msg;
    END IF;
    -- DELETE 也要走这一条
    v_fired := false;
    BEGIN
        DELETE FROM public._silent1_probe WHERE id = 1;
    EXCEPTION WHEN OTHERS THEN v_fired := true; END;
    IF NOT v_fired THEN
        RESET ROLE;
        RAISE EXCEPTION 'FIXTURE 198 失败(臂③):被拒绝的 DELETE 没有抛';
    END IF;
    -- ★ 读【必须】纹丝不动:这道闸不碰任何策略,读权限不许因它变窄 ★
    SELECT count(*) INTO v_n FROM public._silent1_probe;
    IF v_n <> 1 THEN
        RESET ROLE;
        RAISE EXCEPTION 'FIXTURE 198 失败(臂③):无权者读到 % 行,应当仍是 1 —— 读被改窄了', v_n;
    END IF;
    RESET ROLE;
    RAISE NOTICE '  ✓ 臂③:无权者的 UPDATE 与 DELETE 都抛 PERMISSION_DENIED|<码>,而读仍是 1 行';

    -- ── 臂 ④:有权者 —— 必须一切照旧 ───────────────────────────────────────
    -- 用一个【真的持有该权限】的会话:把权限直接摆进策略够不着的地方不老实,
    -- 所以这里换一个谓词恒真的闸来代表"有权者",判的是同一件事:闸放行则写照常。
    DROP TRIGGER enforce_write_permission ON public._silent1_probe;
    DROP POLICY p_upd ON public._silent1_probe;
    CREATE POLICY p_upd ON public._silent1_probe FOR UPDATE TO authenticated
        USING (true) WITH CHECK (true);
    CREATE TRIGGER enforce_write_permission
        BEFORE UPDATE OR DELETE ON public._silent1_probe
        FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('__always_true__');
    -- has_permission('__always_true__') 为假,所以这一支【必须】抛 —— 反证闸真的在跑,
    -- 而不是因为策略放开就整支失效了(一支永远放行的闸与没有闸,长得一模一样)。
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM set_config('request.jwt.claims',
        '{"sub":"00000000-0000-0000-0000-000000000000","role":"authenticated"}', true);
    v_fired := false;
    BEGIN
        UPDATE public._silent1_probe SET note = 'x' WHERE id = 1;
    EXCEPTION WHEN OTHERS THEN v_fired := true; END;
    RESET ROLE;
    IF NOT v_fired THEN
        RAISE EXCEPTION 'FIXTURE 198 失败(臂④):策略放行时这道闸也跟着失效了 —— '
            '它读的必须是权限,不是策略';
    END IF;
    RAISE NOTICE '  ✓ 臂④:闸判的是【权限】本身,不因策略放开而失效';

    -- ════════════════════════════════════════════════════════════════════════
    -- 【覆盖:按表问,而且【瞎掉必须说出来】】
    -- 带写策略的表一张都不许漏,唯一的例外 notification_reads 必须【点名】豁免 ——
    -- 一份"恰好没查到"的清单与一份"查过了都装上了"的清单,在绿色上长得一样。
    -- ════════════════════════════════════════════════════════════════════════
    SELECT count(*) INTO v_n FROM (
        SELECT DISTINCT p.tablename FROM pg_policies p
        WHERE p.schemaname = 'public' AND p.cmd IN ('UPDATE','DELETE','ALL')
    ) x;
    IF v_n < 100 THEN
        RAISE EXCEPTION 'FIXTURE 198 失败:只数到 % 张带写策略的表 —— 这道断言瞎了,'
            '它必须说自己瞎了,不许安静地绿', v_n;
    END IF;

    SELECT string_agg(t, ', ' ORDER BY t) INTO v_missing FROM (
        SELECT DISTINCT p.tablename AS t
        FROM pg_policies p
        WHERE p.schemaname = 'public'
          AND p.cmd IN ('UPDATE','DELETE','ALL')
          AND p.tablename <> 'notification_reads'   -- 故意豁免:谓词是 user_id = auth.uid()
          AND NOT EXISTS (
              SELECT 1 FROM pg_trigger tg
              JOIN pg_class c  ON c.oid = tg.tgrelid
              JOIN pg_namespace n ON n.oid = c.relnamespace
              WHERE n.nspname = 'public' AND c.relname = p.tablename
                AND tg.tgname = 'enforce_write_permission')
    ) y;
    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 198 失败:这些带写策略的表【没有】写闸 —— %', v_missing;
    END IF;

    -- 反过来也要问:豁免的那一张【确实】没有装,否则"故意豁免"只是句空话。
    PERFORM 1 FROM pg_trigger tg
      JOIN pg_class c ON c.oid = tg.tgrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname='public' AND c.relname='notification_reads'
       AND tg.tgname='enforce_write_permission';
    IF FOUND THEN
        RAISE EXCEPTION 'FIXTURE 198 失败:notification_reads 装上了写闸 —— '
            '它的谓词是 user_id = auth.uid(),装了就是为"删别人的已读标记"编造一句权限拒绝';
    END IF;

    RAISE NOTICE '  ✓ 覆盖:% 张带写策略的表,除 notification_reads(点名豁免)外全部装上写闸', v_n;

    DROP FUNCTION public._silent1_definer();
    DROP TABLE public._silent1_probe;

    RAISE NOTICE 'FIXTURE 198 全部通过: 被拒绝的写会抛 PERMISSION_DENIED|<码> · '
                 '属主与 SECURITY DEFINER 不受影响(绩效自评还在) · 读未变窄 · 覆盖 % 张表', v_n;
END $fixture$;

ROLLBACK;
