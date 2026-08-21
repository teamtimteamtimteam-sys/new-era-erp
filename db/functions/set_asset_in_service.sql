CREATE OR REPLACE FUNCTION public.set_asset_in_service(p_asset_id uuid, p_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_a    fixed_assets%ROWTYPE;
BEGIN
    PERFORM require_permission('module.finance.edit');
    IF p_date IS NULL THEN
        RAISE EXCEPTION 'DATE_REQUIRED';
    END IF;

    SELECT * INTO v_a FROM fixed_assets WHERE id = p_asset_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ASSET_NOT_FOUND|%', COALESCE(p_asset_id::text, '?');
    END IF;
    -- 【投用只发生一次】改投用日等于把已经提过的折旧全部推翻 —— 那是一次更正,
    -- 走人工分录,与改年限/残值同一条(见 preview_depreciate_fixed_assets 的头)。
    IF v_a.in_service_date IS NOT NULL THEN
        RAISE EXCEPTION 'ASSET_ALREADY_IN_SERVICE|%|%', v_a.code, v_a.in_service_date;
    END IF;
    IF v_a.status <> 'active' THEN
        RAISE EXCEPTION 'ASSET_DISPOSED|%', v_a.code;
    END IF;
    -- EQP-1c-a:【没有成本的卡投用不了】。create_fixed_asset 建出来的卡成本是 0,
    -- 它代表"我们已经决定买这台机器",而不是"这台机器已经可以开始折旧"。
    -- 【为什么必须按名拒,而不是让它过去】投用一张零成本卡不会报错 ——
    -- 折旧目标是 LEAST(0 - 0, ...) = 0,于是它会【安静地】每期提 0 元,
    -- 看起来像一台在役资产,实际上永远不进损益。**一个静默的空转比一条拒绝坏得多**,
    -- 而且投用是【一次性】的(改投用日要走人工分录),所以错过这一刻就很贵。
    IF v_a.cost_base = 0 THEN
        RAISE EXCEPTION 'ASSET_HAS_NO_COST|%', v_a.code
          USING HINT = '这张卡还没有任何成本 —— 先把发票经追加模式记到它上面,再投用';
    END IF;
    -- 表上那条 CHECK 也拦得住,但它给的是约束名;这里按名拒,人才知道该改哪个日期。
    IF p_date < v_a.acquisition_date THEN
        RAISE EXCEPTION 'IN_SERVICE_BEFORE_ACQUISITION|%|%', p_date, v_a.acquisition_date;
    END IF;

    UPDATE fixed_assets SET in_service_date = p_date WHERE id = p_asset_id;

    -- 折旧从这一天起算(首月按天折算,见 preview_depreciate_fixed_assets),
    -- 而成本从这一刻起冻住 —— 再往上追加会被 record_expense 按名拒。
    RETURN jsonb_build_object('asset_id', p_asset_id, 'code', v_a.code,
                              'in_service_date', p_date, 'cost_base', v_a.cost_base);
END;
$function$;
