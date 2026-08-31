-- INV-VAL-1-fu2:B 节必须与 RPT-1 的数量表数出【同样的量】
--
-- 【发现于把两节放到同一个页面上的那一刻】fu1 之前 B 节只数进料腿,而
-- stock_snapshot(RPT-1 的数量表,同一页)把进料与产出【一起】按流水分组。
-- 于是同一个库位会有两张表给出两个数量,而读的人无从知道哪一张漏了什么 ——
-- 一张"金额表比数量表少了几百公斤"的报表,会被当成盘亏来查。
--
-- 本刀把 B 节 union 成两侧,并加 batch_kind 说明每一行的成本口径来自哪一支:
--   inbound → inbound_batch_landed_unit_cost;output → processing_outputs.unit_cost_base。
-- 【两个口径写在同一张表里,而每一行说得出自己是哪一个】—— 这不是把两种钱
-- 悄悄相加;R1 的"一个口径"管的是【同一类货不许有两个表达式】,
-- 而原料与产成品本来就是两类货、两个控制科目(1200 / 1220)。
--
-- 另:unpriced_qty 改名 uncosted_qty —— 进料侧是"没有价",产出侧是"从未分摊",
-- 一个只说得出前者的名字会让产出侧那 3,661kg 读起来像是已经计过价了。

BEGIN;

CREATE OR REPLACE FUNCTION public.inventory_valuation_snapshot(p_as_of date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_prices  boolean;
    v_base    text;
    v_loc     jsonb;
    v_age     jsonb;
    v_prod    jsonb;
    v_unpriced_qty numeric;
    v_unpriced_n   integer;
    v_nocost_qty   numeric;
    v_nocost_n     integer;
    v_noloc_n      integer;
    v_mv_n         integer;
    v_unalloc_n    integer;
BEGIN
    -- 【授权不是控制】见抬头第五节:本函数自己判,不靠 EXECUTE 授权收得够窄。
    PERFORM require_permission('module.inventory.view');
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'AS_OF_REQUIRED';
    END IF;
    -- R5:任意 as-at 具名拒绝 —— business_date 在 2026-07-03 之前【不存在】,
    -- 照样作答会返回一个自信的 0.00。月末从冻结的管理包里取。
    IF p_as_of < CURRENT_DATE THEN
        RAISE EXCEPTION 'AS_OF_NOT_RECONSTRUCTABLE|%|%', p_as_of,
            COALESCE((SELECT min(business_date)::text FROM inventory_movements
                       WHERE business_date IS NOT NULL), '?')
          USING HINT = '业务日在此之前不完整,历史时点的存货无法重建 —— '
                    || '月末数请从已冻结的管理包里取,不要在今天重算一个历史数字。';
    END IF;

    v_prices := has_permission('data.view_prices');
    SELECT code INTO v_base FROM currencies WHERE is_base;

    -- ── B 节:物料 × 库位 × 状态。★【必须与 stock_snapshot 数出同样的量】★
    -- 那张表(RPT-1 的数量表)把【进料与产出一起】按流水分组;本节若只数进料,
    -- 同一个页面上会出现两张对同一个库位给出不同数量的表 —— 而读的人无从知道
    -- 哪一张漏了什么。所以这里 union 两侧,并用 batch_kind 区分成本口径:
    --   进料腿 → inbound_batch_landed_unit_cost(到岸成本)
    --   产出腿 → processing_outputs.unit_cost_base(分摊出来的单位成本)
    -- 【两个口径,一张表,而它们各自说得出自己是谁】—— 不是把两种钱悄悄相加。
    SELECT COALESCE(jsonb_agg(x ORDER BY x->>'location_code' NULLS LAST,
                              x->>'material_code', x->>'batch_kind'), '[]'::jsonb)
      INTO v_loc
      FROM (
        SELECT jsonb_build_object(
                 'location_id',   mv.location_id,
                 'location_code', sl.code,
                 'location_name', sl.name,
                 'material_code', mt.code,
                 'material_name', mt.name,
                 'unit',          mt.unit,
                 'stock_status',  mv.stock_status,
                 'batch_kind',    CASE WHEN mv.inbound_batch_id IS NOT NULL THEN 'inbound' ELSE 'output' END,
                 'qty',           SUM(mv.qty_delta),
                 -- 【读不到价 → NULL,不是 0】
                 'value_base', CASE WHEN v_prices THEN
                     round(COALESCE(SUM(mv.qty_delta * COALESCE(
                         inbound_batch_landed_unit_cost(ib.id), po.unit_cost_base)), 0), 2)
                     ELSE NULL END,
                 -- 【没有成本口径的量单独报】进料侧是"没有价",产出侧是"从未分摊";
                 -- 两者都【不是】"值 0 的货",所以不进 value,单独出现在这里。
                 'uncosted_qty', SUM(CASE WHEN COALESCE(
                         inbound_batch_landed_unit_cost(ib.id), po.unit_cost_base) IS NULL
                                          THEN mv.qty_delta ELSE 0 END)
               ) AS x
          FROM inventory_movements mv
          LEFT JOIN inbound_batches ib ON ib.id = mv.inbound_batch_id
          LEFT JOIN output_batches  ob ON ob.id = mv.output_batch_id
          LEFT JOIN processing_outputs po ON po.output_batch_id = ob.id
          JOIN materials mt ON mt.id = COALESCE(ib.material_id, ob.material_id)
          LEFT JOIN storage_locations sl ON sl.id = mv.location_id
         WHERE mt.deleted_at IS NULL
           AND ib.deleted_at IS NULL AND ob.deleted_at IS NULL
         GROUP BY mv.location_id, sl.code, sl.name, mt.code, mt.name, mt.unit,
                  mv.stock_status, CASE WHEN mv.inbound_batch_id IS NOT NULL THEN 'inbound' ELSE 'output' END
        HAVING SUM(mv.qty_delta) <> 0
      ) s;

    -- ── C 节:库龄。档位取 aging_bucket,缺日期是一个【被渲染的档位】 ──
    SELECT COALESCE(jsonb_agg(x ORDER BY x->>'bucket'), '[]'::jsonb)
      INTO v_age
      FROM (
        SELECT jsonb_build_object(
                 'bucket',  COALESCE(aging_bucket((p_as_of - ib.arrival_date)::integer), 'no_date'),
                 'batches', count(*),
                 'qty',     SUM(ib.remaining_qty),
                 'value_base', CASE WHEN v_prices THEN
                     round(COALESCE(SUM(ib.remaining_qty * inbound_batch_landed_unit_cost(ib.id)), 0), 2)
                     ELSE NULL END
               ) AS x
          FROM inbound_batches ib
         WHERE ib.deleted_at IS NULL AND ib.remaining_qty > 0
         GROUP BY COALESCE(aging_bucket((p_as_of - ib.arrival_date)::integer), 'no_date')
      ) s;

    -- ── 产出侧:三种状态必须长得不一样(R6) ────────────────────────────
    --   有数 / 0.00(计过价,货卖光了) / NULL(从未分摊,'—')
    SELECT jsonb_build_object(
             'on_hand_batches', count(*),
             'on_hand_qty',     COALESCE(SUM(ob.remaining_qty),0),
             'costed_value_base', CASE WHEN v_prices THEN
                 round(COALESCE(SUM(ob.remaining_qty * po.unit_cost_base) FILTER (WHERE po.unit_cost_base IS NOT NULL),0),2)
                 ELSE NULL END,
             'never_costed_batches', count(*) FILTER (WHERE po.unit_cost_base IS NULL),
             'never_costed_qty',     COALESCE(SUM(ob.remaining_qty) FILTER (WHERE po.unit_cost_base IS NULL),0))
      INTO v_prod
      FROM output_batches ob
      LEFT JOIN processing_outputs po ON po.output_batch_id = ob.id
     WHERE ob.deleted_at IS NULL AND ob.remaining_qty > 0;

    -- ── 这张报表看不见什么 —— 逐条具名,不留给读的人猜 ──────────────────
    SELECT COALESCE(SUM(ib.remaining_qty),0), count(*)
      INTO v_unpriced_qty, v_unpriced_n
      FROM inbound_batches ib
     WHERE ib.deleted_at IS NULL AND ib.remaining_qty > 0
       AND inbound_batch_landed_unit_cost(ib.id) IS NULL;
    SELECT COALESCE(SUM(ob.remaining_qty),0), count(*)
      INTO v_nocost_qty, v_nocost_n
      FROM output_batches ob
      LEFT JOIN processing_outputs po ON po.output_batch_id = ob.id
     WHERE ob.deleted_at IS NULL AND ob.remaining_qty > 0 AND po.unit_cost_base IS NULL;
    SELECT count(*) INTO v_noloc_n FROM inventory_movements WHERE location_id IS NULL;
    SELECT count(*) INTO v_mv_n    FROM inventory_movements;
    SELECT count(*) INTO v_unalloc_n FROM processing_runs
     WHERE deleted_at IS NULL AND status='committed' AND allocated_at IS NULL;

    RETURN jsonb_build_object(
        'as_of', p_as_of,
        'base_currency', v_base,
        'basis', 'landed_cost',
        'prices_visible', v_prices,
        -- ★ 具名受限 —— 不是一个更小的合计
        'restriction', CASE WHEN v_prices THEN NULL
                            ELSE 'PRICE_COMPONENTS_RESTRICTED|data.view_prices' END,
        'by_location', v_loc,
        'ageing', v_age,
        'produced', v_prod,
        'cannot_see', jsonb_build_object(
            'unpriced_on_hand_qty',      v_unpriced_qty,
            'unpriced_on_hand_batches',  v_unpriced_n,
            'never_costed_produced_qty', v_nocost_qty,
            'never_costed_produced_batches', v_nocost_n,
            'movements_without_location', v_noloc_n,
            'movements_total',            v_mv_n,
            'committed_runs_unallocated', v_unalloc_n,
            -- 关账闸【关不住】的那四条,连同今天的金额一起写在报表脸上,
            -- 免得有人把 PROCESSING_COSTS_UNALLOCATED 读成"1200 从此不会漂"。
            'close_gate_does_not_cover',
                jsonb_build_array('stranded_capitalisation (M3)',
                                  'freight_split_residue (M4)',
                                  'stocktake_gain_over_relief (M5)',
                                  'relief_without_capitalisation (M7)')));
END;
$function$;

COMMIT;
