-- 76 行情陈旧的阈值【现读配置】,而不是被记住的一个数(EXEC-1a)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【为什么这一条要单独钉】fixture 30 已经验了"条件成立那一支在、解除后不在"。
-- 它验不到的是【那个 14 从哪里来】—— 一个把 14 写死在视图里的实现,
-- 在 fixture 30 里从头到尾都是绿的。
--
-- 这份 fixture 只做一件事:**在同一个事务里改 pricing_settings,看那一支动**。
-- 阈值从 14 改到 30,同一条 20 天前的报价就从"旧"变成"不旧";改回 14,它又变旧。
-- 写死那个数的实现,两次都给同一个答案 —— 当场红。
--
-- 【为什么不能只测一个方向】只把阈值调大、看它消失,一个"永远返回空"的实现也过;
-- 只调小、看它出现,一个"永远返回全部"的实现也过。两个方向都要。
--
-- 【共享数据要自己接管】metal_prices 是运营数据,线上七个金属都有真报价。
-- 不先把它们清干净,这一支会掺进线上的行(README 第 5 条:要什么就自己设)。
-- 整个事务回滚,线上一个字不动。
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    v_user  uuid := gen_random_uuid();
    v_other uuid := gen_random_uuid();   -- 只持别的模块
    r_all uuid; r_other uuid;
    v_n integer; v_days integer;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-76', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code)
    VALUES (r_all, 'module.pricing.view');
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-76-other', 'f', 'f', true) RETURNING id INTO r_other;
    INSERT INTO role_permissions (role_id, permission_code)
    VALUES (r_other, 'module.hr.view');
    INSERT INTO user_roles (user_id, role_id) VALUES (v_other, r_other);

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    -- 接管共享数据:清掉既有报价,只留【一条 20 天前的】
    UPDATE metal_prices SET deleted_at = now() WHERE deleted_at IS NULL;
    INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date, source)
    VALUES ('cu', 9000, CURRENT_DATE - 20, 'broker_quote');

    -- ══════════ A. 阈值 14:20 天前的报价是【旧】的 ═════════════════════════
    UPDATE pricing_settings SET metal_quote_stale_days = 14;
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM operations_now WHERE item_type = 'metal_quote_stale';
    RESET ROLE;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 76A 失败:阈值 14 天时,20 天前的报价应当算旧(应 1 行,实得 %)', v_n;
    END IF;

    -- ══════════ B. 同一事务里把阈值改到 30:同一条报价【不再旧】═════════════
    -- 【这一臂是整份 fixture 的心脏】数据一个字没动,只动了配置 ——
    -- 一个把 14 写死在视图里的实现,这里仍然报 1 行。
    UPDATE pricing_settings SET metal_quote_stale_days = 30;
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM operations_now WHERE item_type = 'metal_quote_stale';
    RESET ROLE;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 76B 失败:阈值改到 30 天之后,20 天前的报价不该再算旧(应 0 行,实得 % 行)—— 说明那个数不是从 pricing_settings 读的', v_n;
    END IF;

    -- ══════════ C. 改回 14:它又旧了(两个方向都要,见文件头)═══════════════
    UPDATE pricing_settings SET metal_quote_stale_days = 14;
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM operations_now WHERE item_type = 'metal_quote_stale';
    RESET ROLE;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 76C 失败:阈值改回 14 之后应当重新算旧(应 1 行,实得 %)—— 只验一个方向,一个恒空或恒满的实现都能蒙混过去', v_n;
    END IF;

    -- ══════════ D. 边界是【>】不是【>=】════════════════════════════════════
    -- 阈值 20、报价 20 天前 —— 恰好到线,不算旧。
    UPDATE pricing_settings SET metal_quote_stale_days = 20;
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM operations_now WHERE item_type = 'metal_quote_stale';
    RESET ROLE;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 76D 失败:恰好等于阈值不该算旧(> 不是 >=),实得 % 行 —— 在一个六周录两次的序列上,差一天就是差一次维护', v_n;
    END IF;
    UPDATE pricing_settings SET metal_quote_stale_days = 14;

    -- ══════════ E. 按 price_date,【不是】按 created_at ═════════════════════
    -- 【补录是真事:6-25 的行情 7-2 才录进来(ASY-3 实测)】所以判据必须看
    -- 报价日,不看录入日。这一臂造的正是那种行:今天录进去的、20 天前的报价。
    -- 它【必须】算旧 —— 一个按 created_at 判断的实现会说"刚刚更新过",
    -- 而那正好是最需要提醒的时刻。
    -- (本 fixture 里的那条 cu 报价就是今天 INSERT 的,created_at = 现在,
    --  price_date = 20 天前 —— A/C 两臂已经在这条行上成立,所以这一臂
    --  只需把这个事实说出来并断言它。)
    IF (SELECT created_at::date FROM metal_prices
         WHERE source = 'fixture-76' AND deleted_at IS NULL) <> CURRENT_DATE THEN
        RAISE EXCEPTION 'FIXTURE 76E 前提不成立:这条报价应当是【今天录入】的';
    END IF;
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM operations_now WHERE item_type = 'metal_quote_stale';
    RESET ROLE;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 76E 失败:一条【今天录入、20 天前的】报价必须算旧 —— 按 created_at 判断的实现会把补录当成刚更新过';
    END IF;

    -- ══════════ F. 权限:别的模块看见的是【空】,不是报错 ═══════════════════
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_other), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM operations_now WHERE item_type = 'metal_quote_stale';
    RESET ROLE;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 76F 失败:没有 module.pricing.view 的读者不该看见这一支,实得 % 行', v_n;
    END IF;
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    -- ══════════ 注入:把阈值换成写死的 14 ═══════════════════════════════════
    -- 【这一支的守卫没有第二层】视图里那个子查询就是唯一的读法;写死一个数
    -- 不会违反任何约束、不会报错,它只是让配置从此不起作用。
    -- 所以注入把子查询替换成字面量 14,B 臂那个断言必须当场失效。
    -- 【两处都要对,而第一次两处都错了 —— 所以断言写在替换【之前】】
    --   ① pg_get_viewdef 只吐 SELECT 体,不带 CREATE VIEW —— 直接 EXECUTE 它
    --      等于跑一条无害的查询,视图【一个字没改】;
    --   ② 匹配的字符串要用 pg_get_viewdef 自己的排版,不是迁移文件里的排版。
    -- 两次都表现为"注入之后行为没变",而那与"这一支本来就没读配置"在结果上
    -- 一模一样。所以这里先断言【替换确实改动了字节】,再谈行为。
    DECLARE
        v_def text := pg_get_viewdef('public.operations_now'::regclass, true);
        v_inj text;
        -- 【用对空白不敏感的模式,而不是逐字复制排版】pg_get_viewdef 的缩进随
        -- 嵌套深度变化,照抄一次就等于把这份 fixture 钉在今天这个排版上。
        v_needle text := '\(\s*SELECT ps\.metal_quote_stale_days\s+FROM pricing_settings ps\s+LIMIT 1\)';
    BEGIN
        v_inj := regexp_replace(v_def, v_needle, '14');
        IF v_inj = v_def THEN
            RAISE EXCEPTION 'FIXTURE 76 注入 失败:在视图定义里没找到那段读配置的子查询 —— 这个注入什么也没删,下面那句"应当不再起作用"会变成空转';
        END IF;
        EXECUTE 'CREATE OR REPLACE VIEW public.operations_now AS ' || v_inj;
    END;
    -- 现在视图里是写死的 14,改配置应当【不再起作用】
    UPDATE pricing_settings SET metal_quote_stale_days = 30;
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM operations_now WHERE item_type = 'metal_quote_stale';
    RESET ROLE;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 76 注入 失败:把阈值换成写死的 14 之后,改配置应当【不再起作用】(应仍 1 行,实得 %)—— 走到这里说明注入没有命中视图里那段子查询,于是 B 臂并没有被证明有牙', v_n;
    END IF;
END $$;
ROLLBACK;
