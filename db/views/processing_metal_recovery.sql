-- db/views/processing_metal_recovery.sql
-- Metal recovery view — one row per committed, live processing run × metal.
-- (First view in the repo; db/views/ is the mirror location for read-only views,
--  paralleling db/tables and db/functions. Introduced by
--  db/migrations/2026-07-02-phase1-cut2-cost-metal-foundation.sql.)
--
-- input_metal_kg  = Σ input legs  quantity_consumed × inbound content_pct/100
-- output_metal_kg = Σ output legs quantity_produced × output content_pct/100
-- recovery_pct    = round(output/input × 100, 2);仅当【两侧都测过】且投入 > 0。
--
-- REC-1(2026-08-10):【测出来是零】与【根本没测】分开。此前 COALESCE(...,0) 把
-- "这一侧没有这个金属的任何测量"压成数字 0,两者导向相反的结论(前者回收率无从
-- 谈起,后者是无中生有的异常),页面的 `?? '—'` 因此是走不到的死分支。走查实例:
-- PROC-2026-0164 的钴 —— 投入批 IN-2026-0001 只测过 cu。NULL 现在一路活到界面,
-- recovery_blocked_by 给出可枚举的原因,conservation_warning 只在两侧都测过时才为真
-- (永远只是提示:没测过的投入没有可守恒的对象;产出含量往往在提交之后才录)。
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
         SELECT pi.run_id,
            m.metal,
            sum(pi.quantity_consumed * m.content_pct / 100.0) AS input_metal_kg
           FROM processing_inputs pi
             JOIN LATERAL ( SELECT ibm.metal,
                    ibm.content_pct
                   FROM inbound_batch_metals ibm
                  WHERE ibm.inbound_batch_id = pi.inbound_batch_id
                UNION ALL
                 SELECT obm.metal,
                    obm.content_pct
                   FROM output_batch_metals obm
                  WHERE obm.output_batch_id = pi.output_batch_id) m ON true
          GROUP BY pi.run_id, m.metal
        ), outs AS (
         SELECT po.run_id,
            obm.metal,
            sum(po.quantity_produced * obm.content_pct / 100.0) AS output_metal_kg
           FROM processing_outputs po
             JOIN output_batch_metals obm ON obm.output_batch_id = po.output_batch_id
          GROUP BY po.run_id, obm.metal
        )
 SELECT r.id AS run_id,
    r.code AS run_code,
    r.process_date,
    COALESCE(i.metal, o.metal) AS metal,
    i.input_metal_kg,
    o.output_metal_kg,
    i.metal IS NOT NULL AS input_measured,
    o.metal IS NOT NULL AS output_measured,
        CASE
            WHEN i.metal IS NOT NULL AND o.metal IS NOT NULL AND i.input_metal_kg > 0::numeric THEN round(o.output_metal_kg / i.input_metal_kg * 100::numeric, 2)
            ELSE NULL::numeric
        END AS recovery_pct,
        CASE
            WHEN i.metal IS NULL THEN 'input_not_measured'::text
            WHEN o.metal IS NULL THEN 'output_not_measured'::text
            WHEN i.input_metal_kg = 0::numeric THEN 'input_measured_zero'::text
            ELSE NULL::text
        END AS recovery_blocked_by,
    i.metal IS NOT NULL AND o.metal IS NOT NULL AND o.output_metal_kg > i.input_metal_kg AS conservation_warning,
    bool_or(i.metal IS NOT NULL AND o.metal IS NOT NULL AND i.input_metal_kg > 0::numeric) OVER (PARTITION BY r.id) AS run_recovery_computable
   FROM ins i
     FULL JOIN outs o ON o.run_id = i.run_id AND o.metal = i.metal
     JOIN processing_runs r ON r.id = COALESCE(i.run_id, o.run_id)
  WHERE r.status = 'committed'::text AND r.deleted_at IS NULL AND has_permission('module.processing.view'::text);

COMMENT ON VIEW public.processing_metal_recovery IS
    '每个已提交加工单 × 金属的回收率(REC-1 起区分【测出来是零】与【根本没测】)。input_metal_kg / output_metal_kg 为 NULL 表示那一侧从未测过这个金属 —— 不再压成 0,因为两者导向相反的结论。recovery_blocked_by 说明算不出的原因;conservation_warning 只在两侧都测过、且产出大于投入时为真,它【永远只是提示】:没测过的投入没有可守恒的对象,而产出含量往往在提交之后才录入,所以元素守恒天然不是提交时能把的闸(重量守恒能把,因为两边都是提交载荷的必填项)。';

GRANT SELECT ON public.processing_metal_recovery TO authenticated;
