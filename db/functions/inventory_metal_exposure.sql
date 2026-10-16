-- db/functions/inventory_metal_exposure.sql
-- MES-8b-1(2026-10-17,MES-0 Q81;MES-8 Step 0 Q12 · Q13,Tim):【还在库的料里,可计价金属按最新的价值多少 —— 美元,带每一个价的日子】。
--   ★ 只算可计价金属(substances.role = 'payable_metal')—— 惩罚元素与别的物质不进来。
--   ★ 每一个金属:Σ 在库量(kg,进料批与产出批的流水之和 —— MES-5b 的同一个真源)× 含量 % × 那个金属【今天(新加坡日期)或之前】最新的一条
--     metal_prices(美元 / 吨),逐行带出那条价的日子(Q12)。价比那一批含量的日子还旧时,那一批记作 price_older_than_content(Step 0 Q12:标出来,不改数)。
--   ★ 只看可能含金属的料:物料种类 may_ever_be_processed(电池料、电子废料)—— 备件、耗材、包装没有含量,列进来只会是一屏的"not measured"。
--   ★ 一批一种可计价金属都没有含量:「not measured」—— 列出它的 kg,不估值;一批有别的金属的含量而缺这一种:这一种对它「not measured」。
--   ★ 一个金属一条价都没有:「no price」—— 金属吨数照列,不估值。同一个最新日子上有几条价(不同的指数):「price ambiguous」—— 不替人挑一条。
--   ★ 单位不是 kg 的批不合计,另列(unit not kg)。
--   ★ 不折算(Q81:USD,换算的那一条裁定还开着 —— BLOCKERS-0 Q1/Q2),不设阈值(Q12)。
--   ★ 门(Q13,AGENTS.md 常设决定 2):data.view_prices AND (module.finance.view OR module.processing.view);不满足按名拒,页面先画「受限」。
--     (一份"一行都没有"的敞口与一次拒绝是两件事 —— 返回集合的函数用零行表示受限就分不开,CLEANUP-A。)
-- NOTE: introduced by db/migrations/2026-10-17-mes8b1-margin-exposure-and-compliance-pack.sql.
CREATE OR REPLACE FUNCTION public.inventory_metal_exposure()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_today date := (now() AT TIME ZONE 'Asia/Singapore')::date;
    v_metals jsonb;
    v_unmeasured jsonb;
    v_not_kg jsonb;
    v_total numeric;
    v_complete boolean;
BEGIN
    PERFORM require_permission('data.view_prices');
    IF NOT (has_permission('module.finance.view') OR has_permission('module.processing.view')) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.finance.view · module.processing.view';
    END IF;

    WITH stock AS (          -- 每一批在库量(流水之和),只看可能含金属的料、没删的批、量 > 0
        SELECT 'inbound'::text AS kind, b.id, b.code, b.unit, sum(mv.qty_delta) AS qty
          FROM inventory_movements mv JOIN inbound_batches b ON b.id = mv.inbound_batch_id
          JOIN materials m ON m.id = b.material_id JOIN material_kinds k ON k.code = m.kind_code
         WHERE b.deleted_at IS NULL AND k.may_ever_be_processed GROUP BY b.id, b.code, b.unit
        UNION ALL
        SELECT 'output'::text, b.id, b.code, b.unit, sum(mv.qty_delta)
          FROM inventory_movements mv JOIN output_batches b ON b.id = mv.output_batch_id
          JOIN materials m ON m.id = b.material_id JOIN material_kinds k ON k.code = m.kind_code
         WHERE b.deleted_at IS NULL AND k.may_ever_be_processed GROUP BY b.id, b.code, b.unit
    ), live AS (
        SELECT * FROM stock WHERE qty > 0
    ), content AS (          -- 可计价金属的含量,带含量的日子(新加坡日期)
        SELECT 'inbound'::text AS kind, c.inbound_batch_id AS id, c.metal, c.content_pct,
               (c.updated_at AT TIME ZONE 'Asia/Singapore')::date AS content_on
          FROM inbound_batch_metals c JOIN substances s ON s.code = c.metal AND s.role = 'payable_metal'
        UNION ALL
        SELECT 'output'::text, c.output_batch_id, c.metal, c.content_pct, (c.updated_at AT TIME ZONE 'Asia/Singapore')::date
          FROM output_batch_metals c JOIN substances s ON s.code = c.metal AND s.role = 'payable_metal'
    ), measured AS (         -- 单位是 kg、至少有一种可计价金属的含量的批
        SELECT l.* FROM live l WHERE l.unit = 'kg' AND EXISTS (SELECT 1 FROM content c WHERE c.kind = l.kind AND c.id = l.id)
    ), latest AS (           -- 每一个可计价金属今天或之前最新的那一天,与那一天上的几条价
        SELECT s.code AS metal, s.sort_order, d.price_date,
               (SELECT count(*) FROM metal_prices p WHERE p.metal = s.code AND p.deleted_at IS NULL AND p.price_date = d.price_date) AS n_prices,
               (SELECT p.price_usd_per_tonne FROM metal_prices p WHERE p.metal = s.code AND p.deleted_at IS NULL AND p.price_date = d.price_date
                 ORDER BY p.price_index NULLS FIRST LIMIT 1) AS price,
               (SELECT p.price_index FROM metal_prices p WHERE p.metal = s.code AND p.deleted_at IS NULL AND p.price_date = d.price_date
                 ORDER BY p.price_index NULLS FIRST LIMIT 1) AS price_index,
               (SELECT p.source FROM metal_prices p WHERE p.metal = s.code AND p.deleted_at IS NULL AND p.price_date = d.price_date
                 ORDER BY p.price_index NULLS FIRST LIMIT 1) AS price_source
          FROM substances s
          LEFT JOIN LATERAL (SELECT max(p.price_date) AS price_date FROM metal_prices p
                              WHERE p.metal = s.code AND p.deleted_at IS NULL AND p.price_date <= v_today) d ON true
         WHERE s.role = 'payable_metal'
    ), per AS (              -- 一个金属 × 一批:那一批这个金属的吨数
        SELECT m.kind, m.id, m.code, m.qty, c.metal, c.content_pct, c.content_on,
               m.qty * c.content_pct / 100 AS metal_kg
          FROM measured m JOIN content c ON c.kind = m.kind AND c.id = m.id
    ), lines AS (
        SELECT lt.metal, lt.sort_order, lt.price_date, lt.n_prices, lt.price, lt.price_index, lt.price_source,
               CASE WHEN lt.price_date IS NULL THEN 'no_price' WHEN lt.n_prices > 1 THEN 'price_ambiguous' ELSE 'priced' END AS state,
               (SELECT count(*) FROM per p WHERE p.metal = lt.metal) AS batches,
               (SELECT COALESCE(sum(p.qty), 0) FROM per p WHERE p.metal = lt.metal) AS material_kg,
               (SELECT COALESCE(sum(p.metal_kg), 0) FROM per p WHERE p.metal = lt.metal) AS metal_kg,
               (SELECT count(*) FROM per p WHERE p.metal = lt.metal AND lt.price_date IS NOT NULL AND lt.price_date < p.content_on) AS price_older_than_content,
               (SELECT COALESCE(sum(m.qty), 0) FROM measured m WHERE NOT EXISTS (SELECT 1 FROM per p WHERE p.kind = m.kind AND p.id = m.id AND p.metal = lt.metal)) AS not_measured_kg,
               (SELECT COALESCE(jsonb_agg(jsonb_build_object('kind', p.kind, 'code', p.code, 'kg', round(p.qty, 3), 'content_pct', p.content_pct,
                                                             'content_on', p.content_on, 'metal_kg', round(p.metal_kg, 3),
                                                             'price_older_than_content', lt.price_date IS NOT NULL AND lt.price_date < p.content_on)
                                          ORDER BY p.code), '[]'::jsonb) FROM per p WHERE p.metal = lt.metal) AS batch_lines
          FROM latest lt
    )
    SELECT jsonb_agg(jsonb_build_object(
               'metal', l.metal, 'state', l.state, 'price_date', l.price_date,
               'price_usd_per_tonne', CASE WHEN l.state = 'priced' THEN l.price END,
               'price_index', CASE WHEN l.state = 'priced' THEN l.price_index END,
               'price_source', CASE WHEN l.state = 'priced' THEN l.price_source END,
               'prices_on_that_date', l.n_prices,
               'batches', l.batches, 'material_kg', round(l.material_kg, 3), 'metal_kg', round(l.metal_kg, 3),
               'value_usd', CASE WHEN l.state = 'priced' THEN round(l.metal_kg / 1000 * l.price, 2) END,
               'price_older_than_content', l.price_older_than_content,
               'not_measured_kg', round(l.not_measured_kg, 3),
               'batch_lines', l.batch_lines) ORDER BY l.sort_order, l.metal),
           sum(CASE WHEN l.state = 'priced' THEN round(l.metal_kg / 1000 * l.price, 2) END),
           bool_and(l.state = 'priced' OR l.metal_kg = 0)
      INTO v_metals, v_total, v_complete
      FROM lines l;

    WITH stock AS (
        SELECT 'inbound'::text AS kind, b.id, b.code, b.unit, sum(mv.qty_delta) AS qty
          FROM inventory_movements mv JOIN inbound_batches b ON b.id = mv.inbound_batch_id
          JOIN materials m ON m.id = b.material_id JOIN material_kinds k ON k.code = m.kind_code
         WHERE b.deleted_at IS NULL AND k.may_ever_be_processed GROUP BY b.id, b.code, b.unit
        UNION ALL
        SELECT 'output'::text, b.id, b.code, b.unit, sum(mv.qty_delta)
          FROM inventory_movements mv JOIN output_batches b ON b.id = mv.output_batch_id
          JOIN materials m ON m.id = b.material_id JOIN material_kinds k ON k.code = m.kind_code
         WHERE b.deleted_at IS NULL AND k.may_ever_be_processed GROUP BY b.id, b.code, b.unit
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object('kind', s.kind, 'code', s.code, 'kg', round(s.qty, 3)) ORDER BY s.code)
                    FILTER (WHERE s.unit = 'kg' AND NOT EXISTS (SELECT 1 FROM inbound_batch_metals c JOIN substances x ON x.code = c.metal AND x.role = 'payable_metal'
                                                                  WHERE s.kind = 'inbound' AND c.inbound_batch_id = s.id)
                                              AND NOT EXISTS (SELECT 1 FROM output_batch_metals c JOIN substances x ON x.code = c.metal AND x.role = 'payable_metal'
                                                                  WHERE s.kind = 'output' AND c.output_batch_id = s.id)), '[]'::jsonb),
           COALESCE(jsonb_agg(jsonb_build_object('kind', s.kind, 'code', s.code, 'qty', round(s.qty, 3), 'unit', s.unit) ORDER BY s.code)
                    FILTER (WHERE s.unit <> 'kg'), '[]'::jsonb)
      INTO v_unmeasured, v_not_kg
      FROM stock s WHERE s.qty > 0;

    RETURN jsonb_build_object(
        'as_of', v_today,
        'metals', COALESCE(v_metals, '[]'::jsonb),
        'value_usd_priced', round(COALESCE(v_total, 0), 2),
        'complete', COALESCE(v_complete, true) AND jsonb_array_length(v_unmeasured) = 0 AND jsonb_array_length(v_not_kg) = 0,
        'not_measured', v_unmeasured,
        'not_measured_kg', (SELECT COALESCE(round(sum((x ->> 'kg')::numeric), 3), 0) FROM jsonb_array_elements(v_unmeasured) x),
        'unit_not_kg', v_not_kg);
END;
$function$
