-- db/views/batch_balance_tree_all.sql
-- MES-5b-1(2026-10-08,规格 §4.2;MES-0 Q59;MES-5b Step 0 Q3–Q7 · Q10 · Q11,Tim):【一个批次的质量去了哪里 —— 往下走的树】—— 基视图,不给人读。
--   每一个批次(进料与产出)是一棵树的根(root_kind / root_id)。树上的结点(node_type):
--     batch       根批次自己(depth 0),x = 它收进来的量(收货 + 加工产出的流水之和)
--     fate        一个批次结点的去向,line_key:on_hand · sold · written_off · adjusted · voided(回滚作废)· consumed(喂进消耗那几炉)·
--                 split(拆去隔离转给子批)· consumed_not_kg(喂进一炉单位不全是 kg 的单 —— 料离开了库存,但那一炉不展开、不合计)·
--                 unexplained(收进来的 − 以上之和;流水与投料腿对得上时恒为 0 —— 两边是两份真源,所以它动得开,是一个检查,不是装饰)
--     run         这个批次喂进的一炉(消耗或拆分),x = 这一条投料腿的量
--     run_output  那一炉的一条产出腿 = 一个子批次结点(x = 产出量,run_id = 产出它的那一炉);子批次自己的去向挂在它下面,并且接着往下走
--     run_loss    那一炉有名字的损耗(每一类更正链的末端),line_key = 类别,loss_basis = measured / derived
--     run_remainder  那一炉的余数(拆分那一炉没有:它没有损耗、没有余数,Q3 · Q11)
--     event       不进合计、另列的事:line_key = pass_through(深度放电 —— 料穿过去,"放电并核实,由 PROC-…")·
--                 reversed(回滚了的单,带回滚时刻与更正它的那一炉)· not_kg(喂进一炉单位不全是 kg 的单)
--   【份额(Q4):按投入质量成比例,逐层乘下去,精确】一炉的产出、损耗与余数按每条投料腿的 quantity_consumed ÷ 那一炉的投入分给它;
--     一个子批次接着带着它分到的那一份走进下一炉。份额写成一对精确的数 share_num / share_den(各层投料量之积 / 各层投入之积),
--     不做除法,所以每一层【精确】加得起来:一个结点的未缩放量 x 等于它孩子们的 x 之和(批次:收进来的 = 各去向;
--     一炉:投入 = 各产出 + 各损耗 + 余数;产出腿 = 子批次收进来的),同一层的孩子共用同一对份额。
--     qty = x × share_num ÷ share_den 只是给屏幕看的(四舍五入只在屏幕上)。
--   【不是 batch_lineage】那张往上走的表在一炉多产出时把整条投料腿重复到每一条产出上(Step 0 §1.8),加不起来,所以不复用。
--   只有【没回滚、单位全是 kg】的消耗与拆分那几炉会被展开(processing_run_flow_all 的 flow = consumption / transfer、not_kg = false)。
--   批次 → 一炉 → 产出的走法只经 processing_inputs / processing_outputs;一个产出批次只由一条产出腿生出来(processing_outputs 的约定),
--   所以子批次收进来的 = 那条产出腿的量。深度上限 20(工序链今天最长 6 段)。
--   读者:batch_balance_tree(带门)。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5b1-balance-and-yield.sql.

CREATE VIEW public.batch_balance_tree_all WITH (security_invoker = off) AS
 WITH RECURSIVE batches AS (
         SELECT 'inbound'::text AS kind,
            b.id,
            b.code,
            b.material_id,
            b.unit
           FROM inbound_batches b
        UNION ALL
         SELECT 'output'::text AS kind,
            b.id,
            b.code,
            b.material_id,
            b.unit
           FROM output_batches b
        ), legs AS (
         SELECT pi.id AS leg_id,
            pi.run_id,
                CASE
                    WHEN pi.inbound_batch_id IS NOT NULL THEN 'inbound'::text
                    ELSE 'output'::text
                END AS kind,
            COALESCE(pi.inbound_batch_id, pi.output_batch_id) AS batch_id,
            pi.quantity_consumed AS q,
            f.flow,
            f.not_kg,
            f.input_qty AS run_input
           FROM processing_inputs pi
             JOIN processing_run_flow_all f ON f.run_id = pi.run_id
        ), walk(root_kind, root_id, kind, batch_id, node_key, parent_key, depth, num, den, via_output_qty, via_run_id) AS (
         SELECT b.kind,
            b.id,
            b.kind,
            b.id,
            'r'::text AS node_key,
            NULL::text AS parent_key,
            0 AS depth,
            1::numeric AS num,
            1::numeric AS den,
            NULL::numeric AS via_output_qty,
            NULL::uuid AS via_run_id
           FROM batches b
        UNION ALL
         SELECT w.root_kind,
            w.root_id,
            'output'::text AS kind,
            po.output_batch_id,
            (((w.node_key || '/'::text) || l.leg_id::text) || '/o:'::text) || po.id::text,
            (w.node_key || '/'::text) || l.leg_id::text,
            w.depth + 2,
            w.num * l.q,
            w.den * l.run_input,
            po.quantity_produced,
            l.run_id
           FROM walk w
             JOIN legs l ON l.kind = w.kind AND l.batch_id = w.batch_id
             JOIN processing_outputs po ON po.run_id = l.run_id
          WHERE (l.flow = ANY (ARRAY['consumption'::text, 'transfer'::text])) AND NOT l.not_kg AND l.run_input > 0::numeric AND w.depth < 40
        ), mvagg AS (
         SELECT
                CASE
                    WHEN m.inbound_batch_id IS NOT NULL THEN 'inbound'::text
                    ELSE 'output'::text
                END AS kind,
            COALESCE(m.inbound_batch_id, m.output_batch_id) AS batch_id,
            COALESCE(sum(m.qty_delta) FILTER (WHERE m.movement_type = ANY (ARRAY['receipt'::text, 'processing_produce'::text])), 0::numeric) AS received,
            sum(m.qty_delta) AS on_hand,
            COALESCE(- sum(m.qty_delta) FILTER (WHERE m.movement_type = 'sale'::text), 0::numeric) AS sold,
            COALESCE(- sum(m.qty_delta) FILTER (WHERE m.movement_type = 'writeoff'::text), 0::numeric) AS written_off,
            COALESCE(- sum(m.qty_delta) FILTER (WHERE m.movement_type = 'adjustment'::text), 0::numeric) AS adjusted,
            COALESCE(- sum(m.qty_delta) FILTER (WHERE m.movement_type = 'reversal_void'::text), 0::numeric) AS voided
           FROM inventory_movements m
          GROUP BY (
                CASE
                    WHEN m.inbound_batch_id IS NOT NULL THEN 'inbound'::text
                    ELSE 'output'::text
                END), (COALESCE(m.inbound_batch_id, m.output_batch_id))
        ), legagg AS (
         SELECT l.kind,
            l.batch_id,
            COALESCE(sum(l.q) FILTER (WHERE l.flow = 'consumption'::text AND NOT l.not_kg), 0::numeric) AS consumed,
            COALESCE(sum(l.q) FILTER (WHERE l.flow = 'transfer'::text AND NOT l.not_kg), 0::numeric) AS split,
            COALESCE(sum(l.q) FILTER (WHERE (l.flow = ANY (ARRAY['consumption'::text, 'transfer'::text])) AND l.not_kg), 0::numeric) AS consumed_not_kg
           FROM legs l
          GROUP BY l.kind, l.batch_id
        ), nodes AS (
         SELECT w.root_kind,
            w.root_id,
            w.kind,
            w.batch_id,
            w.node_key,
            w.parent_key,
            w.depth,
            w.num,
            w.den,
            w.via_output_qty,
            w.via_run_id,
            COALESCE(ma.received, 0::numeric) AS received,
            COALESCE(ma.on_hand, 0::numeric) AS on_hand,
            COALESCE(ma.sold, 0::numeric) AS sold,
            COALESCE(ma.written_off, 0::numeric) AS written_off,
            COALESCE(ma.adjusted, 0::numeric) AS adjusted,
            COALESCE(ma.voided, 0::numeric) AS voided,
            COALESCE(la.consumed, 0::numeric) AS consumed,
            COALESCE(la.split, 0::numeric) AS split,
            COALESCE(la.consumed_not_kg, 0::numeric) AS consumed_not_kg
           FROM walk w
             LEFT JOIN mvagg ma ON ma.kind = w.kind AND ma.batch_id = w.batch_id
             LEFT JOIN legagg la ON la.kind = w.kind AND la.batch_id = w.batch_id
        ), tree AS (
         SELECT n.root_kind,
            n.root_id,
            n.node_key,
            n.parent_key,
            n.depth,
                CASE
                    WHEN n.depth = 0 THEN 'batch'::text
                    ELSE 'run_output'::text
                END AS node_type,
            NULL::text AS line_key,
            COALESCE(n.via_output_qty, n.received) AS x,
            n.num AS share_num,
            n.den AS share_den,
            n.kind AS batch_kind,
            n.batch_id,
            n.via_run_id AS run_id,
            NULL::text AS loss_category_code,
            NULL::text AS loss_basis
           FROM nodes n
        UNION ALL
         SELECT n.root_kind,
            n.root_id,
            (n.node_key || '|'::text) || v.line_key,
            n.node_key,
            n.depth + 1,
            'fate'::text,
            v.line_key,
            v.x,
            n.num,
            n.den,
            n.kind,
            n.batch_id,
            NULL::uuid,
            NULL::text,
            NULL::text
           FROM nodes n
             CROSS JOIN LATERAL ( VALUES ('on_hand'::text,n.on_hand,1), ('sold'::text,n.sold,2), ('written_off'::text,n.written_off,3), ('adjusted'::text,n.adjusted,4), ('voided'::text,n.voided,5), ('consumed'::text,n.consumed,6), ('split'::text,n.split,7), ('consumed_not_kg'::text,n.consumed_not_kg,8), ('unexplained'::text,n.received - n.on_hand - n.sold - n.written_off - n.adjusted - n.voided - n.consumed - n.split - n.consumed_not_kg,9)) v(line_key, x, ord)
        UNION ALL
         SELECT n.root_kind,
            n.root_id,
            (n.node_key || '/'::text) || l.leg_id::text,
            n.node_key,
            n.depth + 1,
                CASE
                    WHEN (l.flow = ANY (ARRAY['consumption'::text, 'transfer'::text])) AND NOT l.not_kg THEN 'run'::text
                    ELSE 'event'::text
                END,
                CASE
                    WHEN (l.flow = ANY (ARRAY['consumption'::text, 'transfer'::text])) AND NOT l.not_kg THEN l.flow
                    WHEN l.flow = 'pass_through'::text THEN 'pass_through'::text
                    WHEN l.flow = 'reversed'::text THEN 'reversed'::text
                    ELSE 'not_kg'::text
                END,
            l.q,
            n.num,
            n.den,
            n.kind,
            n.batch_id,
            l.run_id,
            NULL::text,
            NULL::text
           FROM nodes n
             JOIN legs l ON l.kind = n.kind AND l.batch_id = n.batch_id
        UNION ALL
         SELECT n.root_kind,
            n.root_id,
            (((n.node_key || '/'::text) || l.leg_id::text) || '/l:'::text) || pl.id::text,
            (n.node_key || '/'::text) || l.leg_id::text,
            n.depth + 2,
            'run_loss'::text,
            pl.loss_category_code,
            pl.quantity,
            n.num * l.q,
            n.den * l.run_input,
            NULL::text,
            NULL::uuid,
            l.run_id,
            pl.loss_category_code,
            pl.basis
           FROM nodes n
             JOIN legs l ON l.kind = n.kind AND l.batch_id = n.batch_id
             JOIN processing_run_losses pl ON pl.run_id = l.run_id
          WHERE l.flow = 'consumption'::text AND NOT l.not_kg AND l.run_input > 0::numeric AND NOT (EXISTS ( SELECT 1
                   FROM processing_run_losses x
                  WHERE x.corrects_id = pl.id))
        UNION ALL
         SELECT n.root_kind,
            n.root_id,
            ((n.node_key || '/'::text) || l.leg_id::text) || '/rem'::text,
            (n.node_key || '/'::text) || l.leg_id::text,
            n.depth + 2,
            'run_remainder'::text,
            f.remainder_state,
            f.remainder_qty,
            n.num * l.q,
            n.den * l.run_input,
            NULL::text,
            NULL::uuid,
            l.run_id,
            NULL::text,
            NULL::text
           FROM nodes n
             JOIN legs l ON l.kind = n.kind AND l.batch_id = n.batch_id
             JOIN processing_run_flow_all f ON f.run_id = l.run_id
          WHERE l.flow = 'consumption'::text AND NOT l.not_kg AND l.run_input > 0::numeric
        )
 SELECT t.root_kind,
    t.root_id,
    rb.code AS root_code,
    t.node_key,
    t.parent_key,
    t.depth,
    t.node_type,
    t.line_key,
    t.x,
    t.share_num,
    t.share_den,
    t.x * t.share_num / t.share_den AS qty,
    t.batch_kind,
    t.batch_id,
    bb.code AS batch_code,
    bb.unit,
    mat.name AS material_name,
    mat.form_code,
    t.run_id,
    rf.run_code,
    rf.operation_type_code,
    rf.process_date,
    rf.flow,
    rf.remainder_state,
    rf.era_mes4a,
    rf.deleted_at AS reversed_at,
    cr.code AS corrects_run_code,
    cb.code AS corrected_by_run_code,
    t.loss_category_code,
    t.loss_basis
   FROM tree t
     JOIN batches rb ON rb.kind = t.root_kind AND rb.id = t.root_id
     LEFT JOIN batches bb ON bb.kind = t.batch_kind AND bb.id = t.batch_id
     LEFT JOIN materials mat ON mat.id = bb.material_id
     LEFT JOIN processing_run_flow_all rf ON rf.run_id = t.run_id
     LEFT JOIN processing_runs cr ON cr.id = rf.corrects_run_id
     LEFT JOIN LATERAL ( SELECT c.code
           FROM processing_runs c
          WHERE c.corrects_run_id = t.run_id
          ORDER BY c.created_at, c.code
         LIMIT 1) cb ON true;

COMMENT ON VIEW public.batch_balance_tree_all IS
    'MES-5b-1:每一个批次往下走的质量树 —— 批次 → 去向(在手 · 卖出 · 注销 · 调整 · 回滚作废 · 消耗 · 拆去隔离 · 未解释)→ 喂进的每一炉 → 它的产出(子批次,接着往下走)、有名字的损耗与余数;放电、回滚与单位不是 kg 的单另列成事件。份额按投入质量成比例,写成精确的一对 share_num / share_den,每一层的未缩放量 x 精确相加;qty = x × num ÷ den 只给屏幕。基视图,不给人读。';

REVOKE ALL ON public.batch_balance_tree_all FROM authenticated, anon;
