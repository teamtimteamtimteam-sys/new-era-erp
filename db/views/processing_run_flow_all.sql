-- db/views/processing_run_flow_all.sql
-- MES-5b-1(2026-10-08,规格 §4 · §3.5;MES-0 Q59 · Q60;MES-5b Step 0 Q3 · Q6 · Q7 · Q10 · Q13 · Q37,Tim):【一炉在质量账上算哪一类】—— 基视图,不给人读。
--   每一炉一行;平衡、得率、月度平衡与批次的去向树都从这里读"这一炉算不算消耗、算多少公斤",一份分类、一份算术。
--   flow:
--     reversed      已回滚 / 已删(status <> committed 或 deleted_at 不空)—— 不进任何合计,另列(Q7)
--     pass_through  工序的种类不吃料(operation_kinds.consumes_input = false:深度放电)—— 料穿过去,另列成事件,不是消耗(Q3)
--     transfer      拆去隔离那一炉(discharge_module_splits 里有它)—— 一次转给子批的搬运:没有损耗、没有余数,子批接着带走份额(Q3 · Q11)
--     consumption   其余:工序的种类吃料;以及【没有工序】的老单(MES-4a 之前、工序必填之前记下的 13 张 —— PROC-SUPPORT-1 之前的单全是转化型,
--                   operation_kinds 的 transforming 那一行的注释写着"今天线上 13 张加工单全部是这一类(虽然它们还没有工序类型)")
--   not_kg:这一炉有任何一条投料腿或产出腿的批次单位不是 kg —— 整炉不进任何合计、另列成"单位不是 kg —— 不合计"(Q10);
--     一炉里混着两种单位时它的投入、余数与得率都没有定义,所以按炉排除,不按腿。
--   era_mes4a:有开始时刻 = MES-4a 之后记下的单。之前的单照样进质量合计(Q6),它的余数读作"记在有名字的损耗之前的损耗"。
--   公斤数全部取自 processing_run_balance_all(投入 = 表头 total_input、产出、有名字的损耗、余数)—— 一份算术,这里一个字都不重算;
--     放电那一炉没有产出腿,穿过去的质量 = 它的投入(表头)。
--   remainder_state:closed_within(最新一次结平当前、在给了的容差里,或余数正好是 0)· closed_explained(当前、带说明 —— 容差外或容差没给)·
--     open · before_closure(MES-4a 之前)· not_applicable(放电)· reversed。
--   processing_run_energy 不读这里也不被这里读(Q37:它的读者只画一炉,印着那一炉自己的状态;一切按炉求和的地方都在这里先滤掉回滚的)。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5b1-balance-and-yield.sql.

CREATE VIEW public.processing_run_flow_all WITH (security_invoker = off) AS
 SELECT r.id AS run_id,
    r.code AS run_code,
    r.process_date,
    (date_trunc('month'::text, r.process_date::timestamp without time zone))::date AS month,
    r.status,
    r.deleted_at,
    r.operation_type_code,
    r.equipment_id,
    r.corrects_run_id,
    r.started_at IS NOT NULL AS era_mes4a,
        CASE
            WHEN r.status <> 'committed'::text OR r.deleted_at IS NOT NULL THEN 'reversed'::text
            WHEN k.consumes_input IS FALSE THEN 'pass_through'::text
            WHEN EXISTS ( SELECT 1
               FROM discharge_module_splits s
              WHERE s.split_run_id = r.id) THEN 'transfer'::text
            ELSE 'consumption'::text
        END AS flow,
    (EXISTS ( SELECT 1
           FROM processing_inputs pi
             LEFT JOIN inbound_batches ib ON ib.id = pi.inbound_batch_id
             LEFT JOIN output_batches ob ON ob.id = pi.output_batch_id
          WHERE pi.run_id = r.id AND COALESCE(ib.unit, ob.unit) IS DISTINCT FROM 'kg'::text)) OR (EXISTS ( SELECT 1
           FROM processing_outputs po
             JOIN output_batches ob ON ob.id = po.output_batch_id
          WHERE po.run_id = r.id AND ob.unit IS DISTINCT FROM 'kg'::text)) AS not_kg,
    b.input_qty,
    b.output_qty,
    b.named_loss_qty,
    b.remainder_qty,
    b.balance_state,
        CASE
            WHEN b.balance_state = 'closed'::text AND (c.within_tolerance IS TRUE OR c.remainder_qty = 0::numeric) THEN 'closed_within'::text
            WHEN b.balance_state = 'closed'::text THEN 'closed_explained'::text
            ELSE b.balance_state
        END AS remainder_state
   FROM processing_runs r
     JOIN processing_run_balance_all b ON b.run_id = r.id
     LEFT JOIN operation_types ot ON ot.code = r.operation_type_code
     LEFT JOIN operation_kinds k ON k.code = ot.kind_code
     LEFT JOIN processing_run_closures c ON c.id = b.last_closure_id;

COMMENT ON VIEW public.processing_run_flow_all IS
    'MES-5b-1:一炉在质量账上算哪一类(flow:consumption / pass_through / transfer / reversed)、单位是不是全是 kg、是不是 MES-4a 之后的单,连同它的投入 · 产出 · 有名字的损耗 · 余数与余数的状态(公斤数取自 processing_run_balance_all,一份算术)。基视图,不给人读。';

REVOKE ALL ON public.processing_run_flow_all FROM authenticated, anon;
