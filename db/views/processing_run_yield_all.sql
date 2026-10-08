-- db/views/processing_run_yield_all.sql
-- MES-5b-1(2026-10-08,规格 §3.5a;MES-5a Q23;MES-5b Step 0 Q13 · Q15,Tim):【一炉的质量得率】—— 基视图,不给人读。
--   只算【消耗】那几炉(processing_run_flow_all.flow = consumption、单位全是 kg):放电与拆去隔离没有得率(它们不消耗),
--   回滚了的单不算;MES-4a 之前的单算,era_mes4a = false 让页面标出来(Q6)。
--   分母一律是这一炉的总投入(MES-5a Q23 的裁定;electrode_powder_line 的总投入就是极片,所以它正是规格 §3.5 的"每单位极片出多少粉")。
--   每一炉几行(line_kind / line_key):
--     output        —— 一种产出形态(产出物料的 form_code;没有形态 '(none)')一行,qty = 这一形态的产出腿之和。除尘收集的粉尘是一种产出(MES-4b)
--     total_output  —— 全部产出
--     loss          —— 一个损耗类别一行(更正链末端),recoverable = 这一类不是真损耗(loss_categories.is_true_loss = false:设备挂料、扫地料 —— 金属"留着")
--     remainder     —— 余数,line_key = 它的状态
--   yield_pct = qty × 100 ÷ 投入(投入为 0 时为空)。
--   V37(Q15):output 那几行带上 operation_type_output_forms.expected_yield_pct(这道工序 × 这一形态的预期得率,Not yet set = 空)与
--     below_expected(得率低于它为真;没给为空 —— "判断不了",不是"没低于")。只标,从不拒。
--   读者:processing_run_yield(带门);分组的合计在 processing_yield_summary_all。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5b1-balance-and-yield.sql.

CREATE VIEW public.processing_run_yield_all WITH (security_invoker = off) AS
 WITH runs AS (
         SELECT f.run_id,
            f.run_code,
            f.process_date,
            f.month,
            f.operation_type_code,
            f.equipment_id,
            f.era_mes4a,
            f.input_qty,
            f.output_qty,
            f.remainder_qty,
            f.remainder_state
           FROM processing_run_flow_all f
          WHERE f.flow = 'consumption'::text AND NOT f.not_kg
        ), lines AS (
         SELECT r.run_id,
            'output'::text AS line_kind,
            COALESCE(m.form_code, '(none)'::text) AS line_key,
            NULL::boolean AS recoverable,
            sum(po.quantity_produced) AS qty
           FROM runs r
             JOIN processing_outputs po ON po.run_id = r.run_id
             JOIN output_batches ob ON ob.id = po.output_batch_id
             JOIN materials m ON m.id = ob.material_id
          GROUP BY r.run_id, (COALESCE(m.form_code, '(none)'::text))
        UNION ALL
         SELECT r.run_id,
            'total_output'::text,
            NULL::text,
            NULL::boolean,
            r.output_qty
           FROM runs r
        UNION ALL
         SELECT r.run_id,
            'loss'::text,
            l.loss_category_code,
            NOT lc.is_true_loss,
            sum(l.quantity) AS sum
           FROM runs r
             JOIN processing_run_losses l ON l.run_id = r.run_id
             JOIN loss_categories lc ON lc.code = l.loss_category_code
          WHERE NOT (EXISTS ( SELECT 1
                   FROM processing_run_losses x
                  WHERE x.corrects_id = l.id))
          GROUP BY r.run_id, l.loss_category_code, lc.is_true_loss
        UNION ALL
         SELECT r.run_id,
            'remainder'::text,
            r.remainder_state,
            NULL::boolean,
            r.remainder_qty
           FROM runs r
        )
 SELECT r.run_id,
    r.run_code,
    r.process_date,
    r.month,
    r.operation_type_code,
    r.equipment_id,
    r.era_mes4a,
    r.input_qty,
    l.line_kind,
    l.line_key,
    l.recoverable,
    l.qty,
        CASE
            WHEN r.input_qty > 0::numeric THEN l.qty * 100::numeric / r.input_qty
            ELSE NULL::numeric
        END AS yield_pct,
    tf.expected_yield_pct,
        CASE
            WHEN l.line_kind = 'output'::text AND tf.expected_yield_pct IS NOT NULL AND r.input_qty > 0::numeric THEN (l.qty * 100::numeric / r.input_qty) < tf.expected_yield_pct
            ELSE NULL::boolean
        END AS below_expected
   FROM runs r
     JOIN lines l ON l.run_id = r.run_id
     LEFT JOIN operation_type_output_forms tf ON l.line_kind = 'output'::text AND tf.operation_type_code = r.operation_type_code AND tf.form_code = l.line_key;

COMMENT ON VIEW public.processing_run_yield_all IS
    'MES-5b-1:一炉的质量得率(只算消耗那几炉,分母 = 总投入):每一种产出形态 · 全部产出 · 每一类有名字的损耗(带"可回收")· 余数,各占投入的 %;产出那几行带 V37(预期得率)与 below_expected(只标,不拒)。基视图,不给人读。';

REVOKE ALL ON public.processing_run_yield_all FROM authenticated, anon;
