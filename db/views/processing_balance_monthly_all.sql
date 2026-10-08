-- db/views/processing_balance_monthly_all.sql
-- MES-5b-1(2026-10-08,规格 §4;MES-0 Q48 · Q59;MES-5b Step 0 Q8 · Q9 · Q10 · Q12,Tim):【月度物料平衡】—— 基视图,不给人读。
--   按 process_date 的月,全厂一份(scope = plant,operation_type_code 空)、每道工序一份(scope = operation;没有工序的老单
--   operation_type_code 为空、scope = operation —— "没记工序",不是"全厂")。长表:每一行是一条线。
--   line / line_key / basis:
--     input         —— 消耗那几炉的投入(flow = consumption,单位全是 kg)
--     output        —— 同那几炉的产出腿,line_key = 产出物料的形态(没有形态的物料 '(none)')
--     loss          —— 同那几炉有名字的损耗(每一类更正链的末端),line_key = 损耗类别,basis = measured / derived
--     remainder     —— 同那几炉的余数,line_key = 余数的状态(closed_within / closed_explained / open / before_closure)
--     pass_through  —— 不是消耗:line_key = discharge(深度放电穿过去的质量)/ split(拆去隔离转给子批的质量)
--     reversed      —— 回滚了的单:件数与公斤,另列,不进上面任何一条
--     not_kg        —— 有一条腿单位不是 kg 的单:件数,不合计(qty 为空 —— 混着单位的数加不起来)
--   【恒等式】每一个(月 × 范围 × 工序):input = Σ output + Σ loss + Σ remainder,逐炉成立所以逐月成立(余数就是那三者的差,
--     来自 processing_run_balance_all 那一份算术;产出腿之和 = 表头产出,commit_processing_run 保证)。fixture 257 MONTH 逐月断言它。
--   【实时数,不冻结】(Q9)一张事后补记的、日期落在过去的单会改掉过去那个月的数;冻结是 MES-8b 合规包的事(MES-0 Q82)。
--   读者经 processing_balance_monthly(带门)。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5b1-balance-and-yield.sql.

CREATE VIEW public.processing_balance_monthly_all WITH (security_invoker = off) AS
 WITH lines AS (
         SELECT f.month,
            f.operation_type_code,
            'input'::text AS line,
            NULL::text AS line_key,
            NULL::text AS basis,
            f.input_qty AS qty,
            f.run_id
           FROM processing_run_flow_all f
          WHERE f.flow = 'consumption'::text AND NOT f.not_kg
        UNION ALL
         SELECT f.month,
            f.operation_type_code,
            'output'::text AS line,
            COALESCE(m.form_code, '(none)'::text) AS line_key,
            NULL::text AS basis,
            po.quantity_produced AS qty,
            f.run_id
           FROM processing_run_flow_all f
             JOIN processing_outputs po ON po.run_id = f.run_id
             JOIN output_batches ob ON ob.id = po.output_batch_id
             JOIN materials m ON m.id = ob.material_id
          WHERE f.flow = 'consumption'::text AND NOT f.not_kg
        UNION ALL
         SELECT f.month,
            f.operation_type_code,
            'loss'::text AS line,
            l.loss_category_code AS line_key,
            l.basis,
            l.quantity AS qty,
            f.run_id
           FROM processing_run_flow_all f
             JOIN processing_run_losses l ON l.run_id = f.run_id
          WHERE f.flow = 'consumption'::text AND NOT f.not_kg AND NOT (EXISTS ( SELECT 1
                   FROM processing_run_losses x
                  WHERE x.corrects_id = l.id))
        UNION ALL
         SELECT f.month,
            f.operation_type_code,
            'remainder'::text AS line,
            f.remainder_state AS line_key,
            NULL::text AS basis,
            f.remainder_qty AS qty,
            f.run_id
           FROM processing_run_flow_all f
          WHERE f.flow = 'consumption'::text AND NOT f.not_kg
        UNION ALL
         SELECT f.month,
            f.operation_type_code,
            'pass_through'::text AS line,
                CASE f.flow
                    WHEN 'pass_through'::text THEN 'discharge'::text
                    ELSE 'split'::text
                END AS line_key,
            NULL::text AS basis,
            f.input_qty AS qty,
            f.run_id
           FROM processing_run_flow_all f
          WHERE f.flow = ANY (ARRAY['pass_through'::text, 'transfer'::text])
        UNION ALL
         SELECT f.month,
            f.operation_type_code,
            'reversed'::text AS line,
            NULL::text AS line_key,
            NULL::text AS basis,
            f.input_qty AS qty,
            f.run_id
           FROM processing_run_flow_all f
          WHERE f.flow = 'reversed'::text
        UNION ALL
         SELECT f.month,
            f.operation_type_code,
            'not_kg'::text AS line,
            NULL::text AS line_key,
            NULL::text AS basis,
            NULL::numeric AS qty,
            f.run_id
           FROM processing_run_flow_all f
          WHERE f.flow = 'consumption'::text AND f.not_kg
        )
 SELECT lines.month,
    'operation'::text AS scope,
    lines.operation_type_code,
    lines.line,
    lines.line_key,
    lines.basis,
    sum(lines.qty) AS qty,
    count(DISTINCT lines.run_id) AS runs
   FROM lines
  GROUP BY lines.month, lines.operation_type_code, lines.line, lines.line_key, lines.basis
UNION ALL
 SELECT lines.month,
    'plant'::text AS scope,
    NULL::text AS operation_type_code,
    lines.line,
    lines.line_key,
    lines.basis,
    sum(lines.qty) AS qty,
    count(DISTINCT lines.run_id) AS runs
   FROM lines
  GROUP BY lines.month, lines.line, lines.line_key, lines.basis;

COMMENT ON VIEW public.processing_balance_monthly_all IS
    'MES-5b-1:月度物料平衡(按 process_date 的月;全厂与每道工序)—— 投入 · 按形态的产出 · 按类别 × 来由的有名字损耗 · 按状态的余数 · 穿过去的质量(放电 / 拆去隔离)· 回滚的单 · 单位不是 kg 的单。实时数,不冻结。基视图,不给人读。';

REVOKE ALL ON public.processing_balance_monthly_all FROM authenticated, anon;
