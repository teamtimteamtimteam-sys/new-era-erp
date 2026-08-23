-- 120 一件【发生过】的事,不可能在明天发生
--
-- 【一个主题,两个器官】停机的起止,与资产的投用日 —— 都是"记录世界上发生过
-- 什么"的日期,都不可以在未来。放在一份 fixture 里,是因为它们是同一条规矩。
--
-- 【每一臂钉什么】
-- F1 前提【两半】:一次寻常的"开一段 → 关一段"照旧;一台【真的在役】的资产照旧。
--    先于一切派生量,而且断言【值】,不是"没报错"。
-- F2 A-D1:结束在未来 → 按名拒;反面(结束在过去)→ 成功。开始在未来同样拒。
-- F3 A-D2 三种形状:新的一段【开始落在】已关闭的一段里 · 【结束落在】里面 ·
--    以及【整段把它包住】。**三臂,不是一臂** —— 只为第一种写的重叠判据
--    通常漏掉第三种。
-- F4 A-D2 的【相接】:一段正好在下一段开始的那一刻结束 —— **允许**,正面断言。
-- F5 B:投用日在未来按名拒;计划投用日【可以】在未来且不锁任何东西;
--    而计划列绝不被任何规则读到。
--
-- 日期:一律用 CURRENT_DATE / now() 的【相对】写法。**写死一个年份就是时间相关**
-- (README 第 4 条):它今天在过去,某一年会变成未来,那一支测的东西就换了意思。
-- 本刀正是被这件事咬过 —— 五支 fixture 因为写死 2027/2028 而当场红。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid; v_ccy text;
    v_asset uuid; v_asset2 uuid; v_dt uuid; v_n int;
    v_denied boolean; v_msg text;
    v_base timestamptz := date_trunc('hour', now()) - INTERVAL '10 days';
    v_d date; v_p date;
BEGIN
    UPDATE finance_settings SET locked_before = NULL;
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-120', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);
    SELECT code INTO v_ccy FROM currencies WHERE is_base;

    INSERT INTO fixed_assets (code, description, category, acquisition_date, cost_base, currency, cost_ccy, fx_rate, status, useful_life_months, residual_base)
    VALUES ('ZZ120-FA1', 'f120 machine', 'equipment', CURRENT_DATE - 400, 0, v_ccy, 0, 1, 'active', 100, 0)
    RETURNING id INTO v_asset;
    INSERT INTO fixed_assets (code, description, category, acquisition_date, cost_base, currency, cost_ccy, fx_rate, status, useful_life_months, residual_base)
    VALUES ('ZZ120-FA2', 'f120 machine 2', 'equipment', CURRENT_DATE - 400, 0, v_ccy, 0, 1, 'active', 100, 0)
    RETURNING id INTO v_asset2;

    -- ══════════ F1 · 前提两半 ═══════════════════════════════════════════════
    RAISE NOTICE 'fixture 120 · 进入 F1';
    -- (a) 开一段 → 关一段,照旧
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO equipment_downtime (equipment_id, started_at, reason)
        VALUES (v_asset, v_base, 'f120 ordinary stop') RETURNING id INTO v_dt;
        UPDATE equipment_downtime SET ended_at = v_base + INTERVAL '8 hours' WHERE id = v_dt;
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 120F1 失败:进入 F1 —— 一次寻常的"开一段 → 关一段"必须照旧走得通。**新规矩只该拦不可能的事,不该拦日常** 。实得「%」', v_msg;
    END IF;
    IF (SELECT ended_at FROM equipment_downtime WHERE id = v_dt) IS DISTINCT FROM v_base + INTERVAL '8 hours' THEN
        RAISE EXCEPTION 'FIXTURE 120F1 失败:进入 F1 —— 关闭时间要原样存下来(断言的是值,不是"没报错")';
    END IF;

    -- (b) 一台【真的在役】的资产照旧
    v_denied := false; v_msg := NULL;
    BEGIN
        UPDATE fixed_assets SET in_service_date = CURRENT_DATE - 30 WHERE id = v_asset2;
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF v_denied OR (SELECT in_service_date FROM fixed_assets WHERE id = v_asset2)
                   IS DISTINCT FROM CURRENT_DATE - 30 THEN
        RAISE EXCEPTION 'FIXTURE 120F1 失败:进入 F1 —— 一个【过去的】投用日必须照旧写得进去。实得「%」', COALESCE(v_msg,'(值不对)');
    END IF;

    -- ══════════ F2 · A-D1:不许在未来 ═══════════════════════════════════════
    RAISE NOTICE 'fixture 120 · 进入 F2';
    v_denied := false; v_msg := NULL;
    BEGIN
        UPDATE equipment_downtime SET ended_at = now() + INTERVAL '1 day' WHERE id = v_dt;
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE '%DOWNTIME_END_IN_FUTURE%' THEN
        RAISE EXCEPTION 'FIXTURE 120F2 失败:进入 F2 —— 结束时刻在未来必须按 DOWNTIME_END_IN_FUTURE 拒。**线上那一行就是这么来的**:一段 23 日开始的停机被填了 24 日结束,而 24 日还没到。实得「%」', COALESCE(v_msg,'(收下了)');
    END IF;
    -- 【反面:结束在过去要成功】少了这一半,一个"永远拒绝关闭"的实现也能全绿。
    UPDATE equipment_downtime SET ended_at = v_base + INTERVAL '9 hours' WHERE id = v_dt;
    IF (SELECT ended_at FROM equipment_downtime WHERE id = v_dt) IS DISTINCT FROM v_base + INTERVAL '9 hours' THEN
        RAISE EXCEPTION 'FIXTURE 120F2 失败:进入 F2 —— 一个【过去的】结束时刻必须改得进去';
    END IF;
    -- 开始时刻在未来同样拒(简报只点名了结束;而同一句话对开始一样成立)
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO equipment_downtime (equipment_id, started_at, reason)
        VALUES (v_asset2, now() + INTERVAL '2 days', 'f120 future start');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE '%DOWNTIME_START_IN_FUTURE%' THEN
        RAISE EXCEPTION 'FIXTURE 120F2 失败:进入 F2 —— 开始时刻在未来同样必须拒。一段"明天开始"的停机记的是【计划】,而这一列装不下计划(与投用日那一半是同一条)。实得「%」', COALESCE(v_msg,'(收下了)');
    END IF;

    -- ══════════ F3 · A-D2:重叠的三种形状 ═══════════════════════════════════
    RAISE NOTICE 'fixture 120 · 进入 F3';
    -- 基准段:v_base → v_base+9h(上面已关闭)
    -- (a) 新的一段【开始落在】它里面
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO equipment_downtime (equipment_id, started_at, ended_at, reason)
        VALUES (v_asset, v_base + INTERVAL '3 hours', v_base + INTERVAL '20 hours', 'f120 starts inside');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE '%DOWNTIME_OVERLAPS%' THEN
        RAISE EXCEPTION 'FIXTURE 120F3 失败:进入 F3(a)—— 开始落在已有一段【里面】必须按 DOWNTIME_OVERLAPS 拒。**线上那对就是这个形状**,而既有的 uq_equipment_downtime_open 只拦"第二段开口",对它一个字都不说。实得「%」', COALESCE(v_msg,'(收下了)');
    END IF;
    -- 【D6:句子里要有挡路那一段的起止】否则改它的人对着一张列表不知道是哪一段
    IF v_msg NOT LIKE '%' || to_char(v_base, 'YYYY-MM-DD HH24:MI') || '%' THEN
        RAISE EXCEPTION 'FIXTURE 120F3 失败:进入 F3(a)—— 拒绝消息里要点名【挡路那一段的起止】,实得「%」', v_msg;
    END IF;

    -- (b) 新的一段【结束落在】它里面
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO equipment_downtime (equipment_id, started_at, ended_at, reason)
        VALUES (v_asset, v_base - INTERVAL '5 hours', v_base + INTERVAL '2 hours', 'f120 ends inside');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE '%DOWNTIME_OVERLAPS%' THEN
        RAISE EXCEPTION 'FIXTURE 120F3 失败:进入 F3(b)—— 结束落在已有一段里面必须拒。实得「%」', COALESCE(v_msg,'(收下了)');
    END IF;

    -- (c) 新的一段【整个把它包住】
    -- **这一支是最容易漏的**:一个只比"新段起点在不在旧段内"的实现,在这里会放行 ——
    -- 因为新段的起点在旧段【之前】,终点在旧段【之后】,两个端点都不在旧段里。
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO equipment_downtime (equipment_id, started_at, ended_at, reason)
        VALUES (v_asset, v_base - INTERVAL '5 hours', v_base + INTERVAL '30 hours', 'f120 contains it');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE '%DOWNTIME_OVERLAPS%' THEN
        RAISE EXCEPTION 'FIXTURE 120F3 失败:进入 F3(c)—— 【整段包住】已有的一段同样必须拒。一个只检查"新段端点是否落在旧段内"的实现在这里会放行:两个端点都在旧段【外面】。实得「%」', COALESCE(v_msg,'(收下了)');
    END IF;

    -- ══════════ F4 · A-D2 的【相接】:允许,正面断言 ═════════════════════════
    RAISE NOTICE 'fixture 120 · 进入 F4';
    -- 基准段是 v_base → v_base+9h;新的一段【正好】从 v_base+9h 开始。
    -- 【定死为允许】分钟精度下"机器回来了又立刻停了"是一句真话,
    -- 拒绝它只会逼人把时间填歪一分钟。判据是左闭右开的区间语义。
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO equipment_downtime (equipment_id, started_at, ended_at, reason)
        VALUES (v_asset, v_base + INTERVAL '9 hours', v_base + INTERVAL '12 hours', 'f120 touching');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 120F4 失败:进入 F4 —— 两段【相接】(一段正好在下一段开始的那一刻结束)必须【允许】。这是刻意定死的,不是没想过:分钟精度下它是一句真话,而拒绝它只会逼人把时间填歪。实得「%」', v_msg;
    END IF;
    SELECT count(*) INTO v_n FROM equipment_downtime WHERE equipment_id = v_asset;
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 120F4 失败:进入 F4 —— 相接的两段应当都在(共 2 段),实得 % 段', v_n;
    END IF;

    -- ══════════ F5 · B:计划与事件 ══════════════════════════════════════════
    RAISE NOTICE 'fixture 120 · 进入 F5';
    -- (a) 投用日在未来 → 按名拒
    v_denied := false; v_msg := NULL;
    BEGIN
        UPDATE fixed_assets SET in_service_date = CURRENT_DATE + 120 WHERE id = v_asset;
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE '%ASSET_IN_SERVICE_IN_FUTURE%' THEN
        RAISE EXCEPTION 'FIXTURE 120F5 失败:进入 F5 —— 未来的投用日必须按 ASSET_IN_SERVICE_IN_FUTURE 拒。**线上那台就是这样锁死的**:in_service_date 是 2027-01-01,每一条规则测的都是 IS NOT NULL 而不是"到了没有",于是锁全上、折旧全无。实得「%」', COALESCE(v_msg,'(收下了)');
    END IF;

    -- (b) 计划投用日【可以】在未来
    v_denied := false; v_msg := NULL;
    BEGIN
        UPDATE fixed_assets SET planned_in_service_date = CURRENT_DATE + 120 WHERE id = v_asset;
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 120F5 失败:进入 F5 —— 【计划】投用日必须允许在未来,那正是它存在的全部理由。实得「%」', v_msg;
    END IF;

    -- (c) 而它【不锁任何东西】—— 这一臂是那一列的全部意义
    -- 有计划、没投用的机器:成本仍然追加得进去(投用才冻结)。
    SELECT in_service_date, planned_in_service_date INTO v_d, v_p
      FROM fixed_assets WHERE id = v_asset;
    IF v_d IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 120F5 失败:进入 F5 —— 填了【计划】投用日不该让 in_service_date 变成非空。两列是两件事';
    END IF;
    IF v_p IS DISTINCT FROM CURRENT_DATE + 120 THEN
        RAISE EXCEPTION 'FIXTURE 120F5 失败:进入 F5 —— 计划投用日应当原样存下来';
    END IF;
    -- (d) 【没有任何规则读那一列】—— 这是 B-D1 的承诺本身,所以正面钉住它
    -- 【为什么用目录扫描而不是"试着写一笔成本"】写一笔成本要一整条支出链
    -- (expense_id NOT NULL),而那一臂测到的只是"这一个调用没被拒";
    -- **承诺是"没有一条规则读它"** —— 那是一句关于【整个系统】的话,
    -- 只有把每一个函数体与视图定义扫一遍才证明得了。
    -- 它一旦被某条规则读了,就又变回了 in_service_date 那个问题:
    -- 一个"打算"开始产生"已经发生"才该有的后果。
    SELECT count(*) INTO v_n FROM (
        SELECT p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public' AND p.prokind = 'f'
           AND regexp_replace(pg_get_functiondef(p.oid), '--[^\n]*', '', 'g')
               LIKE '%planned_in_service_date%'
        UNION ALL
        SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'public' AND c.relkind IN ('v','m')
           AND pg_get_viewdef(c.oid) LIKE '%planned_in_service_date%') x;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 120F5 失败:进入 F5(d)—— **不该有任何函数或视图读 planned_in_service_date**,实得 % 处。那一列是一个【计划】:它一旦被规则读了,就又变回了 in_service_date 当初那个问题 —— 一个"打算"开始产生"已经发生"才该有的后果(线上那台机器就是这么被锁死的)', v_n;
    END IF;
END $$;
ROLLBACK;
