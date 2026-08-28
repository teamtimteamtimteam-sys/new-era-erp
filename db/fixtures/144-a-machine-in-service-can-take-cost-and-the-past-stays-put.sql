-- 144 CAPEX-1:一台【在跑的】机器加得上成本,而【过去一动不动】
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【为什么这一份要比别的仔细】
--   它改的是一段【跑在已经过账的分录上】的算术。本仓库为「以为行为不变的改动」
--   付过 SGD 56,532.48(docs/fx-revaluation-misstatement-2026-07.md),
--   而那次的形状与这次逐字相同:一次【从头重算】的聚合,输入变了,
--   于是一个【已经过账的数】悄悄变错,没有任何东西报错。
--
-- 【这份 fixture 钉住的东西,按重要性排】
--
--   ★★ ① 【A 臂,在别的臂之前跑】depreciation_months_elapsed 是一次【干净的提取】。
--         它的算术逐字取自 preview_depreciate_fixed_assets 的内联版本。
--         **"提取是干净的"这句话本身要被证明,不是被相信**(Tim 2026-08-24 裁定 A2:
--         「先提取,并在任何别的东西跑之前证明等价」)。
--         所以 A 臂拿【手算出来的】已知值断言它,而且排在最前面 ——
--         如果它错了,后面每一个数字都是在一个错的基础上算的,
--         而那时红的会是别的臂,人会去改别的地方。
--
--   ★★ ② 【D 臂,本刀最要紧的一句】资本化【不动】已经过账的折旧。
--         判据不是"函数返回了",是**逐月比对资本化前后那几行的 amount_base
--         一个字节都没变**。**六行,不是一行** —— 一行的比对与"根本没有历史"
--         长得一模一样,而那正是这一臂要排除的东西。
--
--   ★ ③ 【C 臂】**先复现回溯补提,再证明前摊**(Tim 2026-08-24 裁定 A5)。
--        C 臂算出【旧算术】在同一情形下会补多少(550.00),再断言新算术给的是
--        255.56,**并且先断言两者不等**。一个"改了但其实没改"的实现,
--        以及一个"两边碰巧一样"的巧合,都过不去。
--        方法写在这里,是为了下一个人**看见这个方法,而不是重新发明它**。
--
--   ④ 【B 臂】没有维修记录 → 按名拒并指路;记录不合格 → 各自按名拒。
--   ⑤ 【E 臂】锚点表只可追加;寿命走完的机器按名拒;非首日的生效日进不去。
--   ⑥ 【F 臂】权限:读锚点要 module.finance.view。
--
-- 【躲开的五个陷阱,逐条写出来,因为它们都能让这一份变成一句空话】
--   (a) **空集不是断言**:每一次比对之前先断言那个集合【非空】——
--       没有折旧行时,"前后一致"恒真(fixture 39 与 FIN-30 各栽过一次)。
--   (b) **一行的历史不是历史**:D 臂逐月过账六期,不是一次性提到 6 月底。
--   (c) **两边碰巧相等**:C 臂先断言【前摊 ≠ 回溯】,再断言前摊等于手算值。
--   (d) **主语缺席**:B 臂的第一问是"没有维修记录时会怎样",
--       而不是"有维修记录时对不对"(fixture 39 那一课)。
--   (e) **时间相关的判据**:所有日期都是写死的,没有一处读 CURRENT_DATE;
--       locked_before 显式置空,不继承(README 第 4 条)。
--
-- 【手算的出处,写下来,因为一个没有推导的字面量是一句咒语】
--   成本 12,000 · 残值 0 · 年限 60 个月 · 2026-01-01 投用 → 每月 200.00
--   · 2026-06-30 累计目标 = 12000/60 × 6 = 1,200.00
--   · 2026-07-15 资本化 3,000 → 成本 15,000;锚点 2026-07-01;
--     锚点前常数 = 1,200.00(按【加钱之前】的成本算);剩余 = 60 − 6 = 54
--   · 2026-07-31 目标 = 1200 + 13800/54 × 1 = 1200 + 255.5555… = 1,455.56
--     本期 = 1455.56 − 1200 = 255.56
--   · 【旧算术会给的那个数】15000/60 × 7 = 1,750.00,本期 = 550.00
--     差 294.44 —— **那个差就是这一刀消灭掉的回溯补提**
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '180s';
DO $$
DECLARE
    v_user   uuid := gen_random_uuid();
    r_all    uuid;
    v_sup    uuid;
    v_asset  uuid;
    v_asset2 uuid;
    v_maint  uuid;
    v_maint2 uuid;
    v_r      jsonb;
    v_before jsonb;
    v_after  jsonb;
    v_m      numeric;
    v_target numeric;
    v_delta  numeric;
    v_old    numeric;
    v_n      integer;
    v_denied boolean;
    v_msg    text;
    def_prev text;
    def_mon  text;
    v_anchor uuid;
    d        date;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-144', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);
    -- 【不继承,显式设定】locked_before 随月结移动,是 README 第 4 条点名的时间相关状态
    UPDATE finance_settings SET locked_before = NULL;
    -- 【原样定义在任何注入之前取齐】临用临取会取到已经被上一个注入改过的那一份
    def_prev := pg_get_functiondef('public.preview_depreciate_fixed_assets(date)'::regprocedure);
    def_mon  := pg_get_functiondef('public.depreciation_months_elapsed(date,date)'::regprocedure);

    -- ══════════ A. depreciation_months_elapsed 是一次【干净的提取】═══════════
    -- ★ 这一臂排在最前面是【刻意的】:后面每一个数字都建立在它之上。
    --   每一个期望值都是手算的,推导写在旁边 —— 一个没有推导的字面量是一句咒语。

    -- 整月:1 月 1 日 → 1 月 31 日 = 31/31 = 1
    v_m := depreciation_months_elapsed('2026-01-01','2026-01-31');
    IF v_m <> 1 THEN RAISE EXCEPTION 'FIXTURE 144A 失败:整月应当 = 1,实得 %', v_m; END IF;

    -- 同月内按天:1 月 1 日 → 1 月 15 日 = 15/31
    v_m := depreciation_months_elapsed('2026-01-01','2026-01-15');
    IF round(v_m, 6) <> round(15::numeric/31, 6) THEN
        RAISE EXCEPTION 'FIXTURE 144A 失败:同月内应当按天折算 15/31,实得 %', v_m; END IF;

    -- 首月不满 + 中间整月 + 末月整月:
    --   1 月 16 日 → 3 月 31 日 = (31−16+1)/31 + 1(二月) + 31/31 = 16/31 + 1 + 1
    v_m := depreciation_months_elapsed('2026-01-16','2026-03-31');
    IF round(v_m, 6) <> round(16::numeric/31 + 2, 6) THEN
        RAISE EXCEPTION 'FIXTURE 144A 失败:跨月应当 = 16/31 + 2,实得 %', v_m; END IF;

    -- 末月不满:1 月 1 日 → 3 月 10 日 = 1 + 1 + 10/31
    v_m := depreciation_months_elapsed('2026-01-01','2026-03-10');
    IF round(v_m, 6) <> round(2 + 10::numeric/31, 6) THEN
        RAISE EXCEPTION 'FIXTURE 144A 失败:末月应当按天折算 10/31,实得 %', v_m; END IF;

    -- 【二月这个特例值得单独一句】2026 年二月 28 天:2 月 1 日 → 2 月 28 日 = 28/28 = 1
    v_m := depreciation_months_elapsed('2026-02-01','2026-02-28');
    IF v_m <> 1 THEN RAISE EXCEPTION 'FIXTURE 144A 失败:二月整月应当 = 1,实得 %', v_m; END IF;

    -- 边界:期末早于起点 → 0;起点为 NULL(未投用)→ 0
    IF depreciation_months_elapsed('2026-03-01','2026-02-28') <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 144A 失败:期末早于起点应当 = 0'; END IF;
    IF depreciation_months_elapsed(NULL,'2026-02-28') <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 144A 失败:未投用(起点 NULL)应当 = 0'; END IF;

    -- ══════════ 场景搭建:一台真的在跑、而且【真的提过折旧】的机器 ═══════════
    INSERT INTO suppliers (code, legal_name, country, counterparty_type, default_tax_code)
    VALUES ('FIXT-S144', 'Fixture Supplier 144', 'SG', 'goods_supplier', 'TX')
    RETURNING id INTO v_sup;

    v_r := record_expense('2026-01-01', '1500', 12000, 'SGD', NULL, 'unpaid', NULL, v_sup, NULL, NULL,
        jsonb_build_object('description','Fixture 144 machine','useful_life_months',60,'residual_base',0));
    v_asset := (v_r->>'asset_id')::uuid;
    PERFORM set_asset_in_service(v_asset, '2026-01-01');

    -- ★【逐月过账,不是一次提到 6 月底】★ 陷阱 (b):一行的历史与【没有历史】
    --   在一次"前后一致"的比对里长得一模一样。要六行。
    FOR d IN SELECT generate_series('2026-01-31'::date, '2026-06-30'::date, '1 month')::date LOOP
        PERFORM depreciate_fixed_assets((date_trunc('month', d) + interval '1 month - 1 day')::date);
    END LOOP;

    -- 陷阱 (a):比对之前先证明这个集合【非空】,而且正好是六行
    SELECT count(*) INTO v_n FROM fixed_asset_depreciation WHERE asset_id = v_asset;
    IF v_n <> 6 THEN
        RAISE EXCEPTION 'FIXTURE 144 搭建失败:应当有 6 期已过账的折旧,实得 % —— 后面那句"逐字未变"在少于两行时是一句空话', v_n;
    END IF;
    IF (SELECT SUM(amount_base) FROM fixed_asset_depreciation WHERE asset_id = v_asset) <> 1200 THEN
        RAISE EXCEPTION 'FIXTURE 144 搭建失败:六期合计应当 = 1200.00(12000/60 × 6),实得 %',
            (SELECT SUM(amount_base) FROM fixed_asset_depreciation WHERE asset_id = v_asset);
    END IF;

    -- ══════════ B. 【主语缺席】那一问先问:没有维修记录会怎样 ════════════════
    -- 陷阱 (d):一套只问"规则适用时对不对"的断言,看不见"规则根本没被走到"。
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM record_expense('2026-07-15', '1500', 3000, 'SGD', NULL, 'unpaid', NULL, v_sup, NULL, NULL,
        jsonb_build_object('asset_id', v_asset));
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'ASSET_IN_SERVICE_NEEDS_MAINTENANCE|%' THEN
        RAISE EXCEPTION 'FIXTURE 144B 失败:裸追加要按名拒并指路,实得 %', COALESCE(v_msg,'(加进去了)');
    END IF;

    -- 指着一条不存在的记录 —— 否则"必须经维修记录"只是一个参数名,不是一道门
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM record_expense('2026-07-15', '1500', 3000, 'SGD', NULL, 'unpaid', NULL, v_sup, NULL, NULL,
        jsonb_build_object('asset_id', v_asset), NULL, NULL, NULL, NULL, NULL, NULL,
        '00000000-0000-0000-0000-000000000000'::uuid);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'MAINTENANCE_NOT_FOUND|%' THEN
        RAISE EXCEPTION 'FIXTURE 144B 失败:不存在的维修记录要按名拒,实得 %', COALESCE(v_msg,'(加进去了)');
    END IF;

    -- 有记录、但【没标资本化】—— 判断没做过,钱就不该走
    INSERT INTO equipment_maintenance (equipment_id, performed_on, kind, description,
                                       performed_by_name, capitalised)
    VALUES (v_asset, '2026-07-15', 'repair', 'Fixture 144 routine', 'Probe', false)
    RETURNING id INTO v_maint2;
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM record_expense('2026-07-15', '1500', 3000, 'SGD', NULL, 'unpaid', NULL, v_sup, NULL, NULL,
        jsonb_build_object('asset_id', v_asset), NULL, NULL, NULL, NULL, NULL, NULL, v_maint2);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'MAINTENANCE_NOT_CAPITALISED|%' THEN
        RAISE EXCEPTION 'FIXTURE 144B 失败:没标资本化的记录要按名拒,实得 %', COALESCE(v_msg,'(加进去了)');
    END IF;

    -- 【每一次被拒之后,成本一分钱都不该动】—— 一次"拒了但已经写进去一半"的实现
    -- 会在这里被抓住,而它在上面那三条断言里【完全看不出来】。
    IF (SELECT cost_base FROM fixed_assets WHERE id = v_asset) <> 12000 THEN
        RAISE EXCEPTION 'FIXTURE 144B 失败:被拒的追加改动了成本,实得 %',
            (SELECT cost_base FROM fixed_assets WHERE id = v_asset);
    END IF;
    IF EXISTS (SELECT 1 FROM fixed_asset_depreciation_anchors WHERE asset_id = v_asset) THEN
        RAISE EXCEPTION 'FIXTURE 144B 失败:被拒的追加落下了一个锚点';
    END IF;

    -- ══════════ C. 先复现【回溯补提】,再证明【前摊】═══════════════════════
    -- ★ Tim 2026-08-24 裁定 A5:「先复现那个回溯补提……把方法写在 fixture 里,
    --   好让下一个人看见这个方法,而不是重新发明它」。
    --   **方法**:把【旧算术】原样写在这里(它只有一行),用同一批输入算一次。
    --   旧算术 = LEAST(成本−残值, (成本−残值)/年限 × 在役月数(投用日→期末))
    --   这不是"再实现一遍生产代码" —— 生产代码里【已经没有这一支了】,
    --   这里写的是一个【被删掉的东西的复制品】,它的全部用途就是当对照。
    v_old := round(
        LEAST(15000::numeric,
              round(15000::numeric / 60 * depreciation_months_elapsed('2026-01-01','2026-07-31'), 2))
        - 1200, 2);
    IF v_old <> 550.00 THEN
        RAISE EXCEPTION 'FIXTURE 144C 失败:回溯补提的对照值应当 = 550.00(15000/60 × 7 − 1200),实得 %', v_old;
    END IF;

    -- 判断在前,钱在后
    INSERT INTO equipment_maintenance (equipment_id, performed_on, kind, description,
                                       performed_by_name, capitalised, capitalisation_reason)
    VALUES (v_asset, '2026-07-15', 'repair', 'Fixture 144 overhaul', 'Probe',
            true, '大修:更换主轴,产能提高')
    RETURNING id INTO v_maint;

    -- ★ 资本化【之前】的逐月快照 —— D 臂要拿它逐字比对
    SELECT jsonb_agg(jsonb_build_object('p', period_end, 'a', amount_base) ORDER BY period_end)
      INTO v_before FROM fixed_asset_depreciation WHERE asset_id = v_asset;

    v_r := record_expense('2026-07-15', '1500', 3000, 'SGD', NULL, 'unpaid', NULL, v_sup, NULL, NULL,
        jsonb_build_object('asset_id', v_asset), NULL, NULL, NULL, NULL, NULL, NULL, v_maint);

    IF (v_r->>'anchor_from') <> '2026-07-01' THEN
        RAISE EXCEPTION 'FIXTURE 144C 失败:锚点应当从花钱那个月的 1 号起,实得 %', v_r->>'anchor_from'; END IF;
    IF round((v_r->>'anchor_remaining_months')::numeric, 6) <> 54 THEN
        RAISE EXCEPTION 'FIXTURE 144C 失败:剩余月数应当 = 54(60 − 6),实得 %', v_r->>'anchor_remaining_months'; END IF;
    IF (SELECT pre_anchor_target_base FROM fixed_asset_depreciation_anchors WHERE asset_id = v_asset) <> 1200 THEN
        RAISE EXCEPTION 'FIXTURE 144C 失败:锚点前常数应当 = 1200.00(按【加钱之前】的成本算),实得 %',
            (SELECT pre_anchor_target_base FROM fixed_asset_depreciation_anchors WHERE asset_id = v_asset);
    END IF;
    IF (SELECT cost_base FROM fixed_assets WHERE id = v_asset) <> 15000 THEN
        RAISE EXCEPTION 'FIXTURE 144C 失败:成本应当 = 15000.00'; END IF;
    -- 1.5 找到的那个缺口:在此之前【没有任何代码路径】写过这一列
    IF (SELECT capitalised_expense_id FROM equipment_maintenance WHERE id = v_maint) IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 144C 失败:capitalised_expense_id 应当被回填';
    END IF;
    -- 同一条记录不许资本化两次
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM record_expense('2026-07-20', '1500', 100, 'SGD', NULL, 'unpaid', NULL, v_sup, NULL, NULL,
        jsonb_build_object('asset_id', v_asset), NULL, NULL, NULL, NULL, NULL, NULL, v_maint);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'MAINTENANCE_ALREADY_CAPITALISED|%' THEN
        RAISE EXCEPTION 'FIXTURE 144C 失败:同一条维修记录不该资本化第二次,实得 %', COALESCE(v_msg,'(加进去了)');
    END IF;

    SELECT (r->>'target_base')::numeric, (r->>'delta_base')::numeric INTO v_target, v_delta
      FROM jsonb_array_elements(preview_depreciate_fixed_assets('2026-07-31')->'rows') r
     WHERE (r->>'asset_id')::uuid = v_asset;

    -- 陷阱 (c):**先断言两者不等**。一个"改了但其实没改"的实现,以及一个
    -- 两边碰巧相同的巧合,都要在这里死掉 —— 而不是靠下一句碰巧对上。
    IF v_delta = v_old THEN
        RAISE EXCEPTION 'FIXTURE 144C 失败:前摊与回溯补提给出了【同一个数】(%) —— 这一臂因此证明不了任何事', v_delta;
    END IF;
    IF v_target <> 1455.56 THEN
        RAISE EXCEPTION 'FIXTURE 144C 失败:7 月累计目标应当 = 1455.56(1200 + 13800/54 × 1),实得 %', v_target; END IF;
    IF v_delta <> 255.56 THEN
        RAISE EXCEPTION 'FIXTURE 144C 失败:7 月本期应当 = 255.56,实得 %(回溯补提会给 550.00)', v_delta; END IF;

    -- ══════════ D. ★★ 本刀最要紧的一句:过去【一个字节都没变】★★ ═══════════
    SELECT jsonb_agg(jsonb_build_object('p', period_end, 'a', amount_base) ORDER BY period_end)
      INTO v_after FROM fixed_asset_depreciation WHERE asset_id = v_asset;

    -- 陷阱 (a) 的第二道:比对的两边都必须非空,而且【就是那六行】
    IF v_before IS NULL OR jsonb_array_length(v_before) <> 6 THEN
        RAISE EXCEPTION 'FIXTURE 144D 失败:资本化之前的快照不是六行(%)—— 那么下面这句比对是一句空话',
            COALESCE(jsonb_array_length(v_before), -1);
    END IF;
    IF v_after IS NULL OR jsonb_array_length(v_after) <> 6 THEN
        RAISE EXCEPTION 'FIXTURE 144D 失败:资本化之后不该多出或少掉折旧行,实得 % 行',
            COALESCE(jsonb_array_length(v_after), -1);
    END IF;
    IF v_before IS DISTINCT FROM v_after THEN
        RAISE EXCEPTION 'FIXTURE 144D 失败:★ 资本化改动了【已经过账】的折旧 ★%s 之前 = % / 之后 = %',
            E'\n', v_before, v_after;
    END IF;

    -- ★ 而"没变"还不够 —— 再跑一次月度例程,它也不许回头去补那几期。
    --   这一句抓的是另一种死法:数据没被 UPDATE,但下一次例程把差额补了出来。
    PERFORM depreciate_fixed_assets('2026-07-31');
    IF (SELECT SUM(amount_base) FROM fixed_asset_depreciation
         WHERE asset_id = v_asset AND period_end <= '2026-06-30') <> 1200 THEN
        RAISE EXCEPTION 'FIXTURE 144D 失败:月度例程回头补了 6 月及以前的期间';
    END IF;
    IF (SELECT amount_base FROM fixed_asset_depreciation
         WHERE asset_id = v_asset AND period_end = '2026-07-31') <> 255.56 THEN
        RAISE EXCEPTION 'FIXTURE 144D 失败:7 月过账的金额应当 = 255.56,实得 %',
            (SELECT amount_base FROM fixed_asset_depreciation WHERE asset_id = v_asset AND period_end = '2026-07-31');
    END IF;

    -- 幂等靠算术:同一期第二次跑差额为 0(锚定那一支必须保住这条)
    SELECT (r->>'delta_base')::numeric INTO v_delta
      FROM jsonb_array_elements(preview_depreciate_fixed_assets('2026-07-31')->'rows') r
     WHERE (r->>'asset_id')::uuid = v_asset;
    IF v_delta <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 144D 失败:同期第二次跑应当 = 0(幂等靠算术),实得 %', v_delta; END IF;

    -- 【封顶仍然成立】把期末推到年限之外,累计目标不得超过 成本 − 残值
    SELECT (r->>'target_base')::numeric INTO v_target
      FROM jsonb_array_elements(preview_depreciate_fixed_assets('2040-12-31')->'rows') r
     WHERE (r->>'asset_id')::uuid = v_asset;
    IF v_target <> 15000 THEN
        RAISE EXCEPTION 'FIXTURE 144D 失败:锚定之后仍要封顶在 成本−残值 = 15000.00,实得 %', v_target; END IF;

    -- ══════════ E. 锚点是一件【发生过的事】═══════════════════════════════════
    SELECT id INTO v_anchor FROM fixed_asset_depreciation_anchors WHERE asset_id = v_asset;
    v_denied := false; v_msg := NULL;
    BEGIN UPDATE fixed_asset_depreciation_anchors SET remaining_months = 99 WHERE id = v_anchor;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'DEPRECIATION_ANCHOR_IMMUTABLE|%' THEN
        RAISE EXCEPTION 'FIXTURE 144E 失败:锚点不该改得动,实得 %', COALESCE(v_msg,'(改了)'); END IF;
    v_denied := false; v_msg := NULL;
    BEGIN DELETE FROM fixed_asset_depreciation_anchors WHERE id = v_anchor;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'DEPRECIATION_ANCHOR_IMMUTABLE|%' THEN
        RAISE EXCEPTION 'FIXTURE 144E 失败:锚点不该删得掉,实得 %', COALESCE(v_msg,'(删了)'); END IF;

    -- 生效日必须是某个月的 1 号 —— 否则"本期用哪个锚点"会掉进半个月的缝里
    v_denied := false; v_msg := NULL;
    BEGIN INSERT INTO fixed_asset_depreciation_anchors
        (asset_id, effective_from, pre_anchor_target_base, remaining_months, reason)
        VALUES (v_asset, '2026-09-15', 0, 10, 'x');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied THEN RAISE EXCEPTION 'FIXTURE 144E 失败:非首日的生效日不该进得去'; END IF;

    -- 同一个资产、同一个月只能有一个锚点(否则"哪一个有效"又回到按写入时刻破平局)
    v_denied := false; v_msg := NULL;
    BEGIN INSERT INTO fixed_asset_depreciation_anchors
        (asset_id, effective_from, pre_anchor_target_base, remaining_months, reason)
        VALUES (v_asset, '2026-07-01', 0, 10, 'x');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied THEN RAISE EXCEPTION 'FIXTURE 144E 失败:同一个月不该落得下第二个锚点'; END IF;

    -- 【寿命走完的机器按名拒】—— 分母会是零或负,而现实里那是另一件事
    v_r := record_expense('2026-01-01', '1500', 6000, 'SGD', NULL, 'unpaid', NULL, v_sup, NULL, NULL,
        jsonb_build_object('description','Fixture 144 short-life','useful_life_months',3,'residual_base',0));
    v_asset2 := (v_r->>'asset_id')::uuid;
    PERFORM set_asset_in_service(v_asset2, '2026-01-01');
    INSERT INTO equipment_maintenance (equipment_id, performed_on, kind, description,
                                       performed_by_name, capitalised, capitalisation_reason)
    VALUES (v_asset2, '2026-07-15', 'repair', 'Fixture 144 late overhaul', 'Probe', true, '晚到的大修')
    RETURNING id INTO v_maint2;
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM record_expense('2026-07-15', '1500', 500, 'SGD', NULL, 'unpaid', NULL, v_sup, NULL, NULL,
        jsonb_build_object('asset_id', v_asset2), NULL, NULL, NULL, NULL, NULL, NULL, v_maint2);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'ASSET_LIFE_EXHAUSTED|%' THEN
        RAISE EXCEPTION 'FIXTURE 144E 失败:年限走完的机器要按名拒,实得 %', COALESCE(v_msg,'(加进去了)'); END IF;

    -- 【未锚定那一支一个字没改】—— 一台没有锚点的机器,答案要与 FIN-22 时代一致
    --   6000 / 3 个月 × 3 = 6000(封顶),而 2026-03-31 正好走完
    SELECT (r->>'target_base')::numeric, (r->>'anchored')::boolean INTO v_target, v_denied
      FROM jsonb_array_elements(preview_depreciate_fixed_assets('2026-03-31')->'rows') r
     WHERE (r->>'asset_id')::uuid = v_asset2;
    IF v_denied THEN RAISE EXCEPTION 'FIXTURE 144E 失败:这台机器不该有锚点'; END IF;
    IF v_target <> 6000 THEN
        RAISE EXCEPTION 'FIXTURE 144E 失败:未锚定那一支应当逐字不变(6000/3 × 3 封顶 = 6000.00),实得 %', v_target; END IF;

    -- ══════════ F. 权限:锚点是财务数据 ═════════════════════════════════════
    -- ★ fixture 跑在 postgres 下,【绕过 RLS】—— 不切角色的断言是空的
    --   (AGENTS.md 为 fixture 26 记过这一条)。
    DELETE FROM role_permissions WHERE role_id = r_all AND permission_code = 'module.finance.view';
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM fixed_asset_depreciation_anchors;
    EXECUTE 'RESET ROLE';
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 144F 失败:没有 module.finance.view 不该读得到锚点,实得 % 行', v_n; END IF;

    -- 【而这一句证明上面那个 0 是一次【测量】,不是一个空表】
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_all, 'module.finance.view');
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM fixed_asset_depreciation_anchors;
    EXECUTE 'RESET ROLE';
    IF v_n < 1 THEN
        RAISE EXCEPTION 'FIXTURE 144F 失败:有权限时应当读得到锚点 —— 上面那个 0 因此不是一次测量'; END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- 【故障注入 —— 一条从没见它红过的断言,只知道它是安静的,不知道它管用】
    --   四道都跑过,四道都红在【该红的那一臂】。放在最后,因为每一道都在改
    --   函数或策略,而整支 fixture 跑在一笔必然回滚的事务里,所以注入即用即弃。
    -- ══════════════════════════════════════════════════════════════════════

    -- 注入 1:把 preview 的【锚定】那一支短路掉 → 回溯补提当场复现
    --   此刻 v_asset 已经过账 1200 + 255.56 = 1455.56。
    --   退回旧算术:目标 = 15000/60 × 7 = 1750.00,于是本期 = 294.44 ——
    --   **那正是 C 臂量到的那个差**,只是这一次它会【真的被过账】。
    EXECUTE replace(def_prev, 'IF NOT FOUND THEN', 'IF true THEN');
    SELECT (r->>'delta_base')::numeric INTO v_delta
      FROM jsonb_array_elements(preview_depreciate_fixed_assets('2026-07-31')->'rows') r
     WHERE (r->>'asset_id')::uuid = v_asset;
    IF v_delta <> 294.44 THEN
        RAISE EXCEPTION 'FIXTURE 144 注入1 失败:摘掉锚定那一支之后,回溯补提应当【真的出现】(294.44),实得 % —— 说明 C/D 臂拒住它的不是那一支', v_delta;
    END IF;
    EXECUTE def_prev;   -- 放回去,后面还要用

    -- 注入 2:动一分钱的历史 → D 臂那句"逐字未变"必须咬得住
    SELECT jsonb_agg(jsonb_build_object('p', period_end, 'a', amount_base) ORDER BY period_end)
      INTO v_before FROM fixed_asset_depreciation WHERE asset_id = v_asset;
    UPDATE fixed_asset_depreciation SET amount_base = amount_base + 0.01
     WHERE asset_id = v_asset AND period_end = '2026-03-31';
    SELECT jsonb_agg(jsonb_build_object('p', period_end, 'a', amount_base) ORDER BY period_end)
      INTO v_after FROM fixed_asset_depreciation WHERE asset_id = v_asset;
    IF v_before IS NOT DISTINCT FROM v_after THEN
        RAISE EXCEPTION 'FIXTURE 144 注入2 失败:改了一分钱的历史,而 D 臂用的那个比对没看出来 —— 那句"逐字未变"因此是一句空话';
    END IF;
    UPDATE fixed_asset_depreciation SET amount_base = amount_base - 0.01
     WHERE asset_id = v_asset AND period_end = '2026-03-31';

    -- 注入 3:把末月那一项改成整月(最像笔误的那一种)→ A 臂必须咬
    EXECUTE replace(def_mon, '+ EXTRACT(day FROM p_period_end)::numeric',
                             '+ EXTRACT(day FROM (v_mn + interval ''1 month - 1 day''))::numeric');
    IF round(depreciation_months_elapsed('2026-01-01','2026-03-10'), 6)
       = round(2 + 10::numeric/31, 6) THEN
        RAISE EXCEPTION 'FIXTURE 144 注入3 失败:末月改成整月之后答案没变 —— A 臂那几个手算值因此证明不了提取是干净的';
    END IF;
    EXECUTE def_mon;

    -- 注入 4:把锚点表那道门拆掉 → F 臂必须咬
    DROP POLICY "fa depreciation anchors select by permission" ON fixed_asset_depreciation_anchors;
    CREATE POLICY "fixture 144 injection" ON fixed_asset_depreciation_anchors
        FOR SELECT TO authenticated USING (true);
    DELETE FROM role_permissions WHERE role_id = r_all AND permission_code = 'module.finance.view';
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM fixed_asset_depreciation_anchors;
    EXECUTE 'RESET ROLE';
    IF v_n = 0 THEN
        RAISE EXCEPTION 'FIXTURE 144 注入4 失败:门拆了还是读不到 —— 说明 F 臂那个 0 不是那道门给的';
    END IF;
END $$;
ROLLBACK;
