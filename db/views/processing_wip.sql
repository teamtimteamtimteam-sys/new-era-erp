-- db/views/processing_wip.sql
-- PROC-WIRE-1B-ii(R3):在制品 —— 已被指定为下游工序投料、且还有余量的产出批。
--
-- ★【它是一个【投影】,不是一张表】★ R3:在制品不需要新对象。那一行就是
-- output_batches 里那一行(PROC-WIRE-1A 立的);再建一张 WIP 表会把同一批料
-- 数两遍,而两处迟早各说各话。fixture 166 L2 直接对着 pg_class 钉住这一条。
--
-- 【属主权限 + 体内谓词】(修法 (a))它跨 output 与 processing 两个模块 ——
-- invoker 会让一个只有 processing.view 的读者把每一行都丢掉,而**一块"在等什么"
-- 的屏幕空着,与"没有东西在等"长得一模一样**。
--
-- NOTE: introduced by db/migrations/2026-08-31-procwire1bii-an-assertion-that-cannot-see-must-refuse-by-name.sql.
-- First-run script. Re-running requires DROP VIEW first.

CREATE VIEW public.processing_wip WITH (security_invoker = off) AS
 SELECT ob.id AS output_batch_id,
    ob.code AS batch_code,
    ob.material_id,
    m.code AS material_code,
    m.name AS material_name,
    ob.remaining_qty,
    ob.unit,
    ob.purpose_code,
    ob.awaiting_operation_type_code,
    ot.name_zh AS awaiting_operation_zh,
    ot.name_en AS awaiting_operation_en,
    ob.output_date,
    -- 【安全状态记了没有】—— 这块屏要能回答"这批为什么投不进去"。
    -- 【0 的意思是"没有人记过",不是"安全"】与那道闸同一个意思。
    (SELECT count(*) FROM public.output_batch_safety_states s
      WHERE s.output_batch_id = ob.id) AS safety_states_recorded
   FROM public.output_batches ob
   JOIN public.materials m ON m.id = ob.material_id
   JOIN public.output_batch_purposes p ON p.code = ob.purpose_code
   LEFT JOIN public.operation_types ot ON ot.code = ob.awaiting_operation_type_code
  WHERE ob.deleted_at IS NULL
    AND p.is_saleable_stock IS FALSE      -- 【判据读的是那一列,不是写死的码】
    AND ob.remaining_qty > 0              -- 【吃光了就不在等了】
    AND has_permission('module.processing.view'::text);

COMMENT ON VIEW public.processing_wip IS
'PROC-WIRE-1B-ii(R3):在制品 —— 已被指定为下游工序投料、且还有余量的产出批。

★【它是一个【投影】,不是一张表】★ 在制品那一行**就是** output_batches 里
那一行(PROC-WIRE-1A 立的)。建一张 WIP 表会让同一批料被数两遍,
而两处迟早各说各话。**本视图不存任何东西。**

【判据读的是 output_batch_purposes.is_saleable_stock 那一列,不是写死的码】
将来多一种不可售用途,这块屏自动跟着走。

【remaining_qty > 0】被工序吃光的投料不再"在等" —— 而它的 state 仍然不是"已售罄"
(那是另一条轴,合并会认下一笔从来没发生过的收入)。

【属主权限 + 体内谓词】(修法 (a))它跨 output(批次)与 processing(工序字典)
两个模块 —— invoker 会让一个只有 processing.view 的读者把每一行都丢掉,
而**一块"在等什么"的屏幕空着,与"没有东西在等"长得一模一样**。';

GRANT SELECT ON public.processing_wip TO authenticated;
