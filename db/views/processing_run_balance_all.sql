-- db/views/processing_run_balance_all.sql
-- MES-4a(2026-10-07,规格 §4.1;MES-0 Q46–Q48;MES-4a Step 0 Q17–Q22,Tim):【一炉的物料平衡,一份算术】—— 基视图,不给人读。
--   投入(表头 total_input)= 产出(表头 total_output)+ 有名字的损耗(每一类更正链末端之和)+ 余数。余数就是"没解释的质量"。
--   balance_state:
--     reversed        已回滚 / 已删 —— 不进任何清单
--     not_applicable  状态改变型(放电):投入恒等于产出、损耗恒为 0,没有平衡可结(Q20)
--     before_closure  开始时刻为空 = MES-4a 之前记下的单:不能结、不进清单,不回填(Q21)
--     closed          最新一次结平【还是当前的】—— 它之后没有更晚的损耗行、值行(按 id 水位线,Q19)
--     open            其余:还没结,或结过而被之后的更正重开
--   required_missing:这道工序上必填、启用着、而这一炉没有当前值的字段码(结平时拒,Q11)。
--   outputs_unweighed:没挂称重的产出腿条数(结平时拒,Q22 —— MES-4a 之后的单按构造是 0)。
--   tolerance_pct:这道工序【此刻】的容差(为空 = Not yet set);within_tolerance:余数的绝对值不超过 投入 × 容差%(容差为空时 NULL)。
--   derived_loss_qty(MES-4b,Step 0 Q20):有名字的损耗里【算出来的】那一截(basis = derived 的当前行之和)。算术不变 ——
--   算出来的就是又一笔有名字的损耗,余数 = 投入 − 产出 − 有名字的损耗(不分 basis);面板单独报出这一截。列只在末尾加。
--   【一份算术三个读者】close_run_balance(以属主身份读它)· processing_run_balance(带门的外壳,加工单页与清单读)·
--   operations_now 的 processing_balance_unclosed 与月末那一行(processing_runs_unclosed_balance)。
--   【属主视图、不带谓词、SELECT 从 authenticated 收回】—— 读者经 processing_run_balance。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.

CREATE VIEW public.processing_run_balance_all WITH (security_invoker = off) AS
 SELECT r.id AS run_id,
    r.code AS run_code,
    r.process_date,
    r.status,
    r.operation_type_code,
    k.produces_outputs,
    r.started_at,
    r.total_input AS input_qty,
    r.total_output AS output_qty,
    r.loss_qty,
    COALESCE(nl.named_loss_qty, 0::numeric) AS named_loss_qty,
    r.total_input - r.total_output - COALESCE(nl.named_loss_qty, 0::numeric) AS remainder_qty,
    ot.balance_tolerance_pct AS tolerance_pct,
        CASE
            WHEN ot.balance_tolerance_pct IS NULL THEN NULL::boolean
            ELSE abs(r.total_input - r.total_output - COALESCE(nl.named_loss_qty, 0::numeric)) <= (r.total_input * ot.balance_tolerance_pct / 100::numeric)
        END AS within_tolerance,
    COALESCE(ow.outputs_total, 0::bigint) AS outputs_total,
    COALESCE(ow.outputs_unweighed, 0::bigint) AS outputs_unweighed,
    COALESCE(rq.required_missing, ARRAY[]::text[]) AS required_missing,
    lc.id AS last_closure_id,
    lc.closed_at AS last_closed_at,
    (lc.id IS NOT NULL AND COALESCE(mx.max_loss_id, 0::bigint) <= lc.loss_watermark AND COALESCE(mx.max_value_id, 0::bigint) <= lc.value_watermark) AS closure_current,
        CASE
            WHEN r.status <> 'committed'::text OR r.deleted_at IS NOT NULL THEN 'reversed'::text
            WHEN NOT k.produces_outputs THEN 'not_applicable'::text
            WHEN r.started_at IS NULL THEN 'before_closure'::text
            WHEN lc.id IS NOT NULL AND COALESCE(mx.max_loss_id, 0::bigint) <= lc.loss_watermark AND COALESCE(mx.max_value_id, 0::bigint) <= lc.value_watermark THEN 'closed'::text
            ELSE 'open'::text
        END AS balance_state,
    COALESCE(mx.max_loss_id, 0::bigint) AS max_loss_id,
    COALESCE(mx.max_value_id, 0::bigint) AS max_value_id,
    COALESCE(nl.derived_loss_qty, 0::numeric) AS derived_loss_qty
   FROM processing_runs r
     LEFT JOIN operation_types ot ON ot.code = r.operation_type_code
     LEFT JOIN operation_kinds k ON k.code = ot.kind_code
     LEFT JOIN LATERAL ( SELECT sum(l.quantity) AS named_loss_qty,
            sum(l.quantity) FILTER (WHERE l.basis = 'derived'::text) AS derived_loss_qty
           FROM processing_run_losses l
          WHERE l.run_id = r.id AND NOT (EXISTS ( SELECT 1
                   FROM processing_run_losses x
                  WHERE x.corrects_id = l.id))) nl ON true
     LEFT JOIN LATERAL ( SELECT count(*) AS outputs_total,
            count(*) FILTER (WHERE po.weighing_id IS NULL) AS outputs_unweighed
           FROM processing_outputs po
          WHERE po.run_id = r.id) ow ON true
     LEFT JOIN LATERAL ( SELECT array_agg(f.field_code ORDER BY f.sort_order, f.field_code) AS required_missing
           FROM operation_type_fields f
          WHERE f.operation_type_code = r.operation_type_code AND f.is_required AND f.is_active
            AND NOT (EXISTS ( SELECT 1
                   FROM processing_run_values v
                  WHERE v.run_id = r.id AND v.field_code = f.field_code
                    AND num_nonnulls(v.value_number, v.value_text, v.value_bool) > 0
                    AND NOT (EXISTS ( SELECT 1
                           FROM processing_run_values x
                          WHERE x.corrects_id = v.id))))) rq ON true
     LEFT JOIN LATERAL ( SELECT c.id, c.closed_at, c.loss_watermark, c.value_watermark
           FROM processing_run_closures c
          WHERE c.run_id = r.id
          ORDER BY c.id DESC
         LIMIT 1) lc ON true
     LEFT JOIN LATERAL ( SELECT ( SELECT max(l.id) AS max
                   FROM processing_run_losses l
                  WHERE l.run_id = r.id) AS max_loss_id,
            ( SELECT max(v.id) AS max
                   FROM processing_run_values v
                  WHERE v.run_id = r.id) AS max_value_id) mx ON true;

COMMENT ON VIEW public.processing_run_balance_all IS
    'MES-4a:一炉的物料平衡(规格 §4.1)—— 投入 · 产出 · 有名字的损耗 · 余数 · 此刻的容差与判断 · 缺的必填值 · 没称重的产出 · 最新结平是否当前 · balance_state(reversed / not_applicable / before_closure / closed / open)。基视图,不给人读:读者经 processing_run_balance;结平与两支清单以属主身份读它。';

REVOKE ALL ON public.processing_run_balance_all FROM authenticated, anon;
