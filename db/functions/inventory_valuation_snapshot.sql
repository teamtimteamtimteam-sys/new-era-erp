-- db/functions/inventory_valuation_snapshot.sql
-- INV-VAL-1:RPT-1 快照的金额与库龄两节(物料 × 库位 × 状态 + 库龄档 + 产出三态)。
--
-- ★【读不到价的人拿到具名受限,不是一个更小的合计】★ operations 与 warehouse
--   实测有 module.inventory.view、【没有】data.view_prices —— 他们正是这张报表
--   最主要的读者。本仓库有三次"读取器读不到就返回 0"的前科,而一个悄悄少算的
--   合计会被抄进决策。所以 value_base 是 NULL + restriction 具名,数量照给。
--
-- 【p_as_of DEFAULT NULL =「此刻」,而"此刻"只能由数据库说了算】线上 DB 的时区
--   是 Asia/Singapore,应用侧 toISOString() 给的是 UTC 日期 —— 每天 00:00–08:00
--   两者差一天(fu3/fu4 的抬头记着实测)。任意历史 as-at 仍按名拒。
--
-- NOTE: introduced by db/migrations/2026-08-31-invval1-the-valuation-report-the-close-gate-and-the-fields-already-mandatory.sql,
--       amended by …-fu2(与数量表数出同样的量)、…-fu3、…-fu4。
-- CLEANUP-A fu1:落地成本改读 inbound_batch_landed_unit_cost_all(无判据的过账原语)——
-- 计值不许取决于谁按的按钮。

CREATE OR REPLACE FUNCTION public.inventory_valuation_snapshot(p_as_of date DEFAULT NULL::date)
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
    -- ★【这里 NULL =「此刻」,而这与 gl_control_reconciliation 的 AS_OF_REQUIRED
    -- 【不矛盾】,理由要写下来,否则下一个人会把它当成放松了的判词】★
    --   那一条拒绝 NULL,是因为一个【历史时点】被默默填成今天,会让人把今天的
    --   数字读成六月的数字 —— 那是无中生有。
    --   这一支是【实时快照】:「此刻」不是一个被编造的时点,它就是这张屏幕的含义。
    -- 【而且强迫应用自己算"今天"是一个真的 bug】线上 DB 的 TimeZone 是
    --   Asia/Singapore,而 Next.js 侧 toISOString() 给的是 UTC 日期。
    --   每天 00:00–08:00(SGT)两者【差一天】,应用会送来"昨天",于是这张页面
    --   会被自己的 as-at 判词拒掉八个小时。日期的唯一权威是数据库自己。
    p_as_of := COALESCE(p_as_of, CURRENT_DATE);
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
    --   进料腿 → inbound_batch_landed_unit_cost_all(到岸成本)
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
                         inbound_batch_landed_unit_cost_all(ib.id), po.unit_cost_base)), 0), 2)
                     ELSE NULL END,
                 -- 【没有成本口径的量单独报】进料侧是"没有价",产出侧是"从未分摊";
                 -- 两者都【不是】"值 0 的货",所以不进 value,单独出现在这里。
                 'uncosted_qty', SUM(CASE WHEN COALESCE(
                         inbound_batch_landed_unit_cost_all(ib.id), po.unit_cost_base) IS NULL
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
                     round(COALESCE(SUM(ib.remaining_qty * inbound_batch_landed_unit_cost_all(ib.id)), 0), 2)
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
       AND inbound_batch_landed_unit_cost_all(ib.id) IS NULL;
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

COMMENT ON FUNCTION public.inventory_valuation_snapshot(p_as_of date) IS
    'INV-VAL-1:RPT-1 快照的金额与库龄两节(物料 × 库位 × 状态 + 库龄档 + 产出三态)。口径是 inbound_batch_landed_unit_cost,与注销/盘点/勾稽同一份定义。★读不到 data.view_prices 的人拿到 value_base = NULL 加一条具名 restriction,【不是一个更小的合计】—— operations 与 warehouse 实测就是这一类,而本仓库有三次"读不到就返回 0"的前科。数量照给:数量不是价格。库龄档取 aging_bucket(AGING-1 的唯一定义),缺到货日进 no_date 档并被渲染出来,不是零、不是 90 天以上。任意历史 as-at 具名拒绝(AS_OF_NOT_RECONSTRUCTABLE):business_date 在 2026-07-03 之前不存在,照答会给出一个自信的 0.00。';
