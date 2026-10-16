-- db/functions/inbound_batch_margin.sql
-- MES-8b-1(2026-10-17,MES-0 Q80;MES-8 Step 0 Q10 · Q11 · Q13,Tim):【一批进料到今天为止赚了多少 —— 经由用它做出来、卖出去的每一样】。
--   ★ 归属(Q10):一批进料在每一个下游产出批里的份额 = MES-5b 的按投入质量成比例的份额(batch_balance_tree_all,share_num / share_den,
--     精确,逐层乘下去)—— 【不是】那一炉的 allocation_basis:那一条把一炉的【成本】分到它的几样产出上,它不说一样产出的收入怎么分回几条投料腿
--     (MES-8 Step 0 §14 第 1 条)。成本那一半已经带着 allocation_basis 的分法:它就是那个产出批的 unit_cost_base。
--   ★ 毛利 = Σ 份额 × (那个产出批已售数量的收入 − 它的 unit_cost_base × 已售数量)。收入与已售数量取 sales_records,
--     与 batch_margin 读法逐字相同(Q11,一个定义、一个地方):sum(amount_base) 与 sum(quantity)。
--     卖方结算(sales_settlements)【只在它过了账之后才算】—— 今天没有一条结算会过账(SETTLE-1),所以它们一笔都不进来,
--     而这是按构造的:本函数一个字都不读那张表。
--   ★ 没卖出去的那一份:按成本列为在库(份额 × 在库量 × 单位成本;进料批自己剩下的按它的落地单价)—— 不算进毛利。
--   ★ 路径上【任何】一条腿没价(进料批自己没有落地成本 / 一个产出批没有单位成本 / 一个产出批的成本不完整 —— 有没计价的投入被当成零),
--     毛利与在库成本都读「not computable」(NULL),原因逐条列出 —— 【永远不是 0】(batch_margin 那一条,NULL 传播,不靠 COALESCE)。
--     一样都没卖出去时 margin_state = nothing_sold、毛利为 NULL(没有可说的毛利,也不是 0)。
--   ★ 门(AGENTS.md 常设决定 2,Q13):data.view_prices AND (module.finance.view OR module.processing.view)。不满足就按名拒 ——
--     这支函数的 NULL 已经有主了(「not computable」),所以拒绝不能也是 NULL(CLEANUP-A 的判据);页面在调用之前按同一个判据画「受限」。
--   SECURITY DEFINER:它要读的落地单价函数刻意没授给 authenticated(inbound_batch_valuation_rows 的同一个理由)。
-- NOTE: introduced by db/migrations/2026-10-17-mes8b1-margin-exposure-and-compliance-pack.sql.
CREATE OR REPLACE FUNCTION public.inbound_batch_margin(p_inbound_batch_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_b        inbound_batches%ROWTYPE;
    v_base     text;
    v_landed   numeric;
    v_priced   boolean;
    v_lines    jsonb;
    v_reasons  jsonb;
    v_rev      numeric;
    v_cost     numeric;
    v_sold     numeric;
    v_onhand   numeric;
    v_onval    numeric;
    v_root_on  numeric;
    v_any_sold boolean;
    v_ok       boolean;
BEGIN
    PERFORM require_permission('data.view_prices');
    IF NOT (has_permission('module.finance.view') OR has_permission('module.processing.view')) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.finance.view · module.processing.view';
    END IF;

    SELECT * INTO v_b FROM inbound_batches WHERE id = p_inbound_batch_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INBOUND_BATCH_NOT_FOUND|%', COALESCE(p_inbound_batch_id::text, '?');
    END IF;
    SELECT code INTO v_base FROM currencies WHERE is_base;

    -- 落地单价(读者名:它自己再问 data.view_prices);它的 NULL 就是"这批没有落地成本"(inbound_batch_has_landed_cost 与它逐字互补 ——
    --   那一支问的是库存查看码,而本函数的门是常设决定 2,两条门不相同,所以这里只读价格那一支)
    v_landed := inbound_batch_landed_unit_cost(v_b.id);
    v_priced := v_landed IS NOT NULL;

    WITH t AS (
        SELECT * FROM batch_balance_tree_all WHERE root_kind = 'inbound' AND root_id = v_b.id
    ), nodes AS (            -- 树上的每一个产出批结点(一个产出批可以经两条路出现两次 —— 每一次是它自己的一份)
        SELECT t.node_key, t.depth, t.batch_id, t.share_num, t.share_den,
               ob.code AS batch_code, po.unit_cost_base, COALESCE(po.cost_incomplete, false) AS cost_incomplete, po.id AS po_id,
               COALESCE((SELECT f.x FROM t f WHERE f.parent_key = t.node_key AND f.node_type = 'fate' AND f.line_key = 'on_hand'), 0) AS on_hand
          FROM t JOIN output_batches ob ON ob.id = t.batch_id
          LEFT JOIN processing_outputs po ON po.output_batch_id = t.batch_id
         WHERE t.node_type = 'run_output'
    ), s AS (                -- 与 batch_margin 同一句:每一个产出批的已售数量与收入
        SELECT sr.output_batch_id, sum(sr.quantity) AS qty, sum(sr.amount_base) AS rev
          FROM sales_records sr WHERE sr.output_batch_id IN (SELECT batch_id FROM nodes) GROUP BY sr.output_batch_id
    ), l AS (
        SELECT n.*, COALESCE(s.qty, 0) AS qty_sold, COALESCE(s.rev, 0) AS revenue
          FROM nodes n LEFT JOIN s ON s.output_batch_id = n.batch_id
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'node_key', l.node_key, 'depth', l.depth, 'batch_id', l.batch_id, 'batch_code', l.batch_code,
               'share', round(l.share_num / l.share_den, 6),
               'unit_cost_base', l.unit_cost_base, 'cost_incomplete', l.cost_incomplete,
               'qty_sold', round(l.qty_sold * l.share_num / l.share_den, 3),
               'revenue_base', round(l.revenue * l.share_num / l.share_den, 2),
               'cost_base', round(l.unit_cost_base * l.qty_sold * l.share_num / l.share_den, 2),
               'margin_base', round((l.revenue - l.unit_cost_base * l.qty_sold) * l.share_num / l.share_den, 2),
               'on_hand', round(l.on_hand * l.share_num / l.share_den, 3),
               'on_hand_at_cost_base', round(l.unit_cost_base * l.on_hand * l.share_num / l.share_den, 2))
             ORDER BY l.depth, l.batch_code, l.node_key), '[]'::jsonb),
           COALESCE(jsonb_agg(DISTINCT jsonb_build_object('code', CASE WHEN l.po_id IS NULL THEN 'output_not_from_a_run'
                                                                       WHEN l.unit_cost_base IS NULL THEN 'output_no_unit_cost'
                                                                       ELSE 'output_cost_incomplete' END,
                                                          'batch_code', l.batch_code))
                    FILTER (WHERE l.unit_cost_base IS NULL OR l.cost_incomplete), '[]'::jsonb),
           sum(l.revenue * l.share_num / l.share_den),
           sum(l.unit_cost_base * l.qty_sold * l.share_num / l.share_den),
           COALESCE(sum(l.qty_sold * l.share_num / l.share_den), 0),
           COALESCE(sum(l.on_hand * l.share_num / l.share_den), 0),
           sum(l.unit_cost_base * l.on_hand * l.share_num / l.share_den),
           COALESCE(bool_or(l.qty_sold > 0), false)
      INTO v_lines, v_reasons, v_rev, v_cost, v_sold, v_onhand, v_onval, v_any_sold
      FROM l;

    -- 进料批自己还在库的(份额 1)
    SELECT COALESCE(t.x, 0) INTO v_root_on FROM batch_balance_tree_all t
     WHERE t.root_kind = 'inbound' AND t.root_id = v_b.id AND t.node_type = 'fate' AND t.line_key = 'on_hand' AND t.parent_key = 'r';
    v_root_on := COALESCE(v_root_on, 0);
    IF NOT v_priced THEN
        v_reasons := jsonb_build_array(jsonb_build_object('code', 'inbound_unpriced', 'batch_code', v_b.code)) || v_reasons;
    END IF;
    v_ok := jsonb_array_length(v_reasons) = 0;

    RETURN jsonb_build_object(
        'inbound_batch_id', v_b.id, 'code', v_b.code, 'unit', v_b.unit, 'base_currency', v_base,
        'computable', v_ok, 'reasons', v_reasons,
        'margin_state', CASE WHEN NOT v_ok THEN 'not_computable' WHEN NOT v_any_sold THEN 'nothing_sold' ELSE 'computed' END,
        'qty_sold', round(v_sold, 3),
        'revenue_base', CASE WHEN v_ok THEN round(COALESCE(v_rev, 0), 2) END,
        'cost_of_sold_base', CASE WHEN v_ok THEN round(COALESCE(v_cost, 0), 2) END,
        'margin_base', CASE WHEN v_ok AND v_any_sold THEN round(v_rev - v_cost, 2) END,
        'on_hand_downstream', round(v_onhand, 3),
        'on_hand_own', round(v_root_on, 3),
        'landed_unit_cost', v_landed,
        'on_hand_at_cost_base', CASE WHEN v_ok THEN round(COALESCE(v_onval, 0) + v_root_on * v_landed, 2) END,
        'revenue_source', 'sales_records',
        'lines', v_lines);
END;
$function$
