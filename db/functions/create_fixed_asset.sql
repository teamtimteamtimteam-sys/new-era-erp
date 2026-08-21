-- db/functions/create_fixed_asset.sql
-- EQP-1c-a:【第二扇】建卡的门 —— 一张还没有成本的资产卡。
-- 它是关于一台【我们已经决定要买】的机器的主数据,不是一笔过账:不碰总账,
-- 一分钱也不动。成本随后经既有的追加门(record_expense 的 p_asset.asset_id)落上来。
-- 【为什么需要它】采购单的设备行必须引用一张【已存在】的卡(EQP-1a),
-- 而现实顺序是订单在前、发票在后 —— 此前唯一那扇门要同时过一笔账,
-- 于是整条设备链根本起不了步。
-- 【另一扇门没有作废】见 record_expense 新建支旁边那段注释:一台没有采购单、
-- 当场买断的机器,卡与成本同时诞生才是那件事的真实形状。

CREATE OR REPLACE FUNCTION public.create_fixed_asset(p_description text, p_useful_life_months integer, p_acquisition_date date, p_category text DEFAULT 'equipment'::text, p_depreciation_account_code text DEFAULT '6700'::text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user  uuid := auth.uid();
    v_id    uuid := gen_random_uuid();
    v_code  text;
    v_base  text := base_currency_code();
BEGIN
    PERFORM require_permission('module.finance.edit');

    IF COALESCE(btrim(p_description), '') = '' THEN
        RAISE EXCEPTION 'ASSET_DESCRIPTION_REQUIRED';
    END IF;
    IF p_useful_life_months IS NULL OR p_useful_life_months <= 0 THEN
        RAISE EXCEPTION 'ASSET_LIFE_INVALID|%', COALESCE(p_useful_life_months::text, '?');
    END IF;
    -- 【取得日必填,不给默认】它不决定期间、也不决定汇率(这扇门不过账),
    -- 但它是 in_service_date 的下界(fixed_assets_service_after_acquisition),
    -- 于是一个悄悄填成"今天"的取得日会把投用日的合法范围一起挪掉。
    -- 与 AGENTS.md 那条"决定期间/汇率/金额的日期必填,永不默认"同源:
    -- 会被别的规则读的日期,不该由函数替人猜。
    IF p_acquisition_date IS NULL THEN
        RAISE EXCEPTION 'ASSET_ACQUISITION_DATE_REQUIRED';
    END IF;
    -- 分类:表上那条 CHECK 也拦得住,但它只给得出约束名。按名拒,并且【把可选
    -- 值报出来】—— 一条不告诉你有哪些选项的拒绝,会让人去翻建表脚本。
    IF p_category IS NULL OR p_category NOT IN ('equipment', 'vehicle', 'office', 'other') THEN
        RAISE EXCEPTION 'ASSET_CATEGORY_INVALID|%|%', COALESCE(p_category, '?'),
            'equipment,vehicle,office,other';
    END IF;

    v_code := next_fixed_asset_code(p_acquisition_date);

    -- 【零成本卡的三个金额列,逐个说清它们为什么是这些值】
    --   cost_base = 0 / cost_ccy = 0  —— 还没有任何成本落在这台机器上;
    --   currency  = 本位币             —— 不是占位符:没有发生过换算,
    --   fx_rate   = 1                     所以本位币 + 1 是这件事的实话,
    --                                     而它让 fx_rate > 0 那条 CHECK 保持原样。
    --   residual_base = 0             —— 见 fixed_assets_residual_below_cost 的注释。
    -- 【expense_id 留空】这张卡不是由一笔支出生出来的,那一列的注释写清了这件事。
    INSERT INTO fixed_assets (id, code, description, category, acquisition_date, in_service_date,
                              cost_ccy, currency, fx_rate, cost_base, useful_life_months,
                              residual_base, depreciation_account_code, expense_id, notes, created_by)
    VALUES (v_id, v_code, btrim(p_description), p_category, p_acquisition_date, NULL,
            0, v_base, 1, 0, p_useful_life_months,
            0, COALESCE(p_depreciation_account_code, '6700'), NULL, p_notes, v_user);

    RETURN jsonb_build_object(
        'asset_id', v_id, 'code', v_code,
        'cost_base', 0, 'in_service_date', NULL,
        'acquisition_date', p_acquisition_date);
END;
$function$;
