-- db/functions/preview_depreciate_fixed_assets.sql
-- 折旧算术的【唯一来源】(FIN-22)。writer(depreciate_fixed_assets)问它,界面也问它 ——
-- 屏幕预览和真正过账共用同一份算术(ask-the-database 规矩,重估的同款结构)。
-- 应提 = 目标 − Σ 已提(recorded)。
-- 负差额报 0:残值/年限被改动导致的下修是【更正】,走人工分录,不由月度例程悄悄回冲。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★【CAPEX-1:目标怎么算,现在有两支 —— 而第二支存在的全部理由是
--     【不许把过去的月份重新推导一遍】】★★
--
--   **未锚定(原样,一个字没改):**
--       target = LEAST(成本−残值, (成本−残值)/年限月数 × 在役月数(投用日→期末))
--
--   **已锚定(CAPEX-1 新增):**
--       target = 锚点前的常数
--              + LEAST(成本−残值−常数,
--                      (成本−残值−常数)/锚点剩余月数 × 在役月数(锚点生效日→期末))
--     整体再封顶在 成本−残值。
--
--   【为什么这就防住了回溯补提】原算术里,"过去那一段"是一个【表达式】——
--   (成本−残值)/年限 × 已过月数 —— 于是抬高成本,过去每一个月的目标一起抬高,
--   整笔补提落在本期。锚定之后,"过去那一段"是 `pre_anchor_target_base`,
--   一个【锚定那一刻存下来的标量】。**新成本乘不到它身上,因为它已经不是一个
--   乘法了。** 这是结构性的,不是一句约束:没有任何路径能让新的 cost_base
--   参与到锚点之前那一段的计算里。
--
--   【4.7 的公式与这里的对应】4.7 写的是
--   `(cost + addition − residual − accumulated) / remaining_months`。
--   分子就是 `成本−残值−常数`(成本此时已含追加),分母就是锚点上那个
--   `remaining_months` —— 逐项对得上,只是这里把它写成累计目标的形式,
--   好让【幂等靠算术】那条(同期第二次跑差额为 0)原样继续成立。
--
--   【在役月数只有一份实现】两支都调 depreciation_months_elapsed(起点, 期末),
--   只是起点不同。那段首/末月按天折算的算术最容易写错,所以不许有第二份;
--   而"提取是干净的"由 fixture 144 的 A 臂用手算值证明,不靠相信。
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.preview_depreciate_fixed_assets(p_period_end date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_rows   jsonb := '[]'::jsonb;
    v_total  numeric := 0;
    v_a      record;
    v_anchor record;
    v_months numeric;
    v_cap    numeric;
    v_target numeric;
    v_posted numeric;
    v_delta  numeric;
BEGIN
    PERFORM require_permission('module.finance.view');
    IF p_period_end IS NULL THEN
        RAISE EXCEPTION 'DATE_REQUIRED';
    END IF;

    FOR v_a IN
        SELECT fa.id, fa.code, fa.description, fa.in_service_date, fa.cost_base,
               fa.residual_base, fa.useful_life_months, fa.depreciation_account_code
        FROM fixed_assets fa
        WHERE fa.status = 'active'
        ORDER BY fa.code
    LOOP
        -- 【每一轮先清空】PL/pgSQL 的 SELECT ... INTO 在无行时会把 record 置空,
        -- 所以这一句今天是多余的 —— 写出来是因为它防的是【下一次重构】:
        -- 一个跨迭代残留的锚点会让上一台资产的锚点漏给下一台,
        -- 而那是一个算得出数、不报错的错误(WHT-1 在 record_payment 里踩过同形)。
        v_anchor := NULL;
        -- 【本期适用哪个锚点】= 生效日不晚于期末的那些里,最晚的一个。
        -- 排序键是【业务日期】effective_from,不是写入时刻 —— 见那张表的表注:
        -- 按 created_at 取最新是 AGING-1 栽过的坑。
        SELECT * INTO v_anchor
        FROM fixed_asset_depreciation_anchors an
        WHERE an.asset_id = v_a.id AND an.effective_from <= p_period_end
        ORDER BY an.effective_from DESC
        LIMIT 1;

        v_cap := round(v_a.cost_base - v_a.residual_base, 2);

        IF NOT FOUND THEN
            -- ── 未锚定:原样的那一支,逐字保留 ────────────────────────────
            -- 【未投用 → 0】由 depreciation_months_elapsed 自己处理(起点为 NULL 返回 0),
            -- 所以这里不再重复那个判断 —— 两处判 NULL 就是两份实现的小号版本。
            v_months := depreciation_months_elapsed(v_a.in_service_date, p_period_end);
            v_target := LEAST(v_cap,
                              round((v_a.cost_base - v_a.residual_base)
                                    / v_a.useful_life_months * v_months, 2));
        ELSE
            -- ── 已锚定:过去那一段是【常数】,只往前算 ────────────────────
            v_months := depreciation_months_elapsed(v_anchor.effective_from, p_period_end);
            v_target := v_anchor.pre_anchor_target_base
                      + LEAST(round(v_cap - v_anchor.pre_anchor_target_base, 2),
                              round((v_cap - v_anchor.pre_anchor_target_base)
                                    / v_anchor.remaining_months * v_months, 2));
            -- 整体封顶:任何情况下都不许提过 成本−残值。
            v_target := LEAST(v_cap, round(v_target, 2));
        END IF;

        SELECT COALESCE(SUM(d.amount_base), 0) INTO v_posted
        FROM fixed_asset_depreciation d WHERE d.asset_id = v_a.id;
        v_delta := round(v_target - v_posted, 2);
        -- 负差额不冲回:残值/年限被改动导致的目标下修是【更正】,走人工分录,
        -- 不由月度例程悄悄回冲。这里报 0。
        -- 【4.7 刻意模仿了这一侧】月度例程两个方向都不往回够:向上的变化从此刻起
        -- 往前摊(锚点),向下的变化仍然是一次更正、仍然走人工分录。
        IF v_delta < 0 THEN v_delta := 0; END IF;
        v_total := v_total + v_delta;

        v_rows := v_rows || jsonb_build_object(
            'asset_id', v_a.id, 'code', v_a.code, 'description', v_a.description,
            'account', v_a.depreciation_account_code,
            'target_base', v_target, 'posted_base', v_posted, 'delta_base', v_delta,
            -- 【本期这一行是按哪套算术算的,说出来】屏幕与导出都读得到它;
            -- 一个数字旁边写着它的来路,比事后去猜便宜得多。
            'anchored', (v_anchor.id IS NOT NULL),
            'anchor_from', v_anchor.effective_from,
            'pre_anchor_target_base', v_anchor.pre_anchor_target_base,
            'anchor_remaining_months', v_anchor.remaining_months);
    END LOOP;

    RETURN jsonb_build_object('period_end', p_period_end, 'rows', v_rows,
                              'total_delta', round(v_total, 2));
END;
$function$;

COMMENT ON FUNCTION public.preview_depreciate_fixed_assets(date) IS
'折旧算术的唯一来源(FIN-22),CAPEX-1 起分两支。**未锚定那一支一个字没改。**
已锚定那一支把"锚点之前"换成一个存下来的常数 pre_anchor_target_base,只从锚点
往后算 —— 于是抬高 cost_base 再也乘不到过去的月份上,4.7 禁止的回溯补提在
【结构上】不可能发生,不是靠一句约束拦着。两支共用 depreciation_months_elapsed,
所以首/末月按天折算只有一份实现。';
