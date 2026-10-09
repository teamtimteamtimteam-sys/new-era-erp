-- db/views/blending_plan_execution.sql
-- MES-5b-3(2026-10-09,MES-5b Step 0 Q18,Tim):【计划的公斤数与实际投的公斤数,逐行并排,差多少照直说】。
--   实际 = 执行那一炉在这一批上的投料腿(processing_inputs.quantity_consumed)—— 不另存一份(blending_plan_lines 的表注)。
--   计划还没执行:actual_kg 与 difference_kg 为 NULL;执行了而这一批这次没用上:actual_kg = 0、difference_kg = −计划。
--   那一炉的状态一并给出(committed / reversed)—— 回滚过的那一炉,数字照旧是它当时的投料,页面说它已回滚。
--   只有公斤数,没有含量,所以不遮;门 module.processing.view(计划与加工单的读码)。
-- NOTE: introduced by db/migrations/2026-10-09-mes5b3-blending.sql.

CREATE VIEW public.blending_plan_execution WITH (security_invoker = off) AS
 SELECT l.plan_id,
    l.id AS line_id,
        CASE
            WHEN l.inbound_batch_id IS NOT NULL THEN 'inbound'::text
            ELSE 'output'::text
        END AS batch_kind,
    COALESCE(l.inbound_batch_id, l.output_batch_id) AS batch_id,
    COALESCE(ib.code, ob.code) AS batch_code,
    l.planned_kg,
        CASE
            WHEN p.run_id IS NULL THEN NULL::numeric
            ELSE COALESCE(fed.qty, 0::numeric)
        END AS actual_kg,
        CASE
            WHEN p.run_id IS NULL THEN NULL::numeric
            ELSE COALESCE(fed.qty, 0::numeric) - l.planned_kg
        END AS difference_kg,
    p.run_id,
    r.code AS run_code,
    r.status AS run_status
   FROM blending_plan_lines l
     JOIN blending_plans p ON p.id = l.plan_id
     LEFT JOIN processing_runs r ON r.id = p.run_id
     LEFT JOIN inbound_batches ib ON ib.id = l.inbound_batch_id
     LEFT JOIN output_batches ob ON ob.id = l.output_batch_id
     LEFT JOIN LATERAL ( SELECT sum(pi.quantity_consumed) AS qty
           FROM processing_inputs pi
          WHERE pi.run_id = p.run_id
            AND (pi.inbound_batch_id = l.inbound_batch_id OR pi.output_batch_id = l.output_batch_id)) fed ON true
  WHERE has_permission('module.processing.view'::text);

COMMENT ON VIEW public.blending_plan_execution IS
    'MES-5b-3:配料计划逐行的计划公斤数、执行那一炉在这一批上实际投的公斤数与差(实际 − 计划),连同那一炉的编号与状态。门 module.processing.view;只有公斤数,不遮。';

GRANT SELECT ON public.blending_plan_execution TO authenticated;
REVOKE ALL ON public.blending_plan_execution FROM anon;
