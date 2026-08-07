-- db/views/processing_metal_recovery.sql
-- Metal recovery view — one row per committed, live processing run × metal.
-- (First view in the repo; db/views/ is the mirror location for read-only views,
--  paralleling db/tables and db/functions. Introduced by
--  db/migrations/2026-07-02-phase1-cut2-cost-metal-foundation.sql.)
--
-- input_metal_kg  = Σ input legs  quantity_consumed × inbound content_pct/100
-- output_metal_kg = Σ output legs quantity_produced × output content_pct/100
-- recovery_pct    = round(output/input × 100, 2), NULL when input = 0.
-- Metals appearing on EITHER side are included (full join across the two aggregates).
-- Assumes kg throughout (the money path in allocate_processing_costs is unit-guarded).
--
-- Owner rights since OPS-14 (was security_invoker=true — the lone 'true' spelling in
-- the repo, and the reason a detector must match both spellings).
--
-- First-run script. Re-running requires DROP VIEW first. Run in the Supabase SQL Editor.
-- FIN-25:投入金属两路来源(进料批 / 再加工的产出批)—— 旧内联 join 丢产出边,
-- 投入金属低报、回收率【高报】,而这是评判工艺的数字。fixture 19 的 A 臂钉着。

-- OPS-14(2026-08-08):改为【属主权限】+ module.processing.view。
-- 借 inbound_batch_metals / output_batch_metals(挂 inbound / output 模块)的 content_pct。
-- 少了它们 input_metal_kg 低报、回收率【高报】—— 与 FIN-25 修掉的方向一模一样,
-- 这次的原因是 RLS 而不是漏了一条 join。是工艺数字不是钱,故修法 (a)。
-- 【它是全库唯一把 security_invoker 拼成 'true' 的视图】—— 只认 'on' 的检测器会检查
-- 15 个里的 14 个并报干净。OPS-13 踩过一次,OPS-14 的普查先验证了这一点才敢信零。

CREATE VIEW public.processing_metal_recovery WITH (security_invoker = off) AS
WITH ins AS (
    SELECT pi.run_id, m.metal,
           SUM(pi.quantity_consumed * m.content_pct / 100.0) AS input_metal_kg
    FROM public.processing_inputs pi
    JOIN LATERAL (
        SELECT ibm.metal, ibm.content_pct
        FROM public.inbound_batch_metals ibm
        WHERE ibm.inbound_batch_id = pi.inbound_batch_id
        UNION ALL
        SELECT obm.metal, obm.content_pct
        FROM public.output_batch_metals obm
        WHERE obm.output_batch_id = pi.output_batch_id
    ) m ON true
    GROUP BY pi.run_id, m.metal
),
outs AS (
    SELECT po.run_id, obm.metal,
           SUM(po.quantity_produced * obm.content_pct / 100.0) AS output_metal_kg
    FROM public.processing_outputs po
    JOIN public.output_batch_metals obm ON obm.output_batch_id = po.output_batch_id
    GROUP BY po.run_id, obm.metal
)
SELECT r.id            AS run_id,
       r.code          AS run_code,
       r.process_date,
       COALESCE(i.metal, o.metal) AS metal,
       COALESCE(i.input_metal_kg, 0)  AS input_metal_kg,
       COALESCE(o.output_metal_kg, 0) AS output_metal_kg,
       CASE WHEN COALESCE(i.input_metal_kg, 0) = 0 THEN NULL
            ELSE round(COALESCE(o.output_metal_kg, 0) / i.input_metal_kg * 100, 2)
       END AS recovery_pct
FROM ins i
FULL JOIN outs o ON o.run_id = i.run_id AND o.metal = i.metal
JOIN public.processing_runs r ON r.id = COALESCE(i.run_id, o.run_id)
WHERE r.status = 'committed' AND r.deleted_at IS NULL
  AND has_permission('module.processing.view'::text);

GRANT SELECT ON public.processing_metal_recovery TO authenticated;
