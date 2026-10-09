-- db/functions/guard_blending_run_from_plan.sql
-- MES-5b-3(2026-10-09,MES-5b Step 0 Q18,Tim):【配料那一炉只从配料计划上记】—— processing_runs 上的 BEFORE INSERT 守卫。
--   一炉的工序是 blending,而事务级标记 evoltrya.blend_ctx 不在(只有 execute_blending_plan 在调引擎的前后设它、用毕即清)→
--   按名拒 BLEND_RUN_FROM_PLAN_ONLY。新建加工单的表单本来就不列它(operation_types.started_from_run_page),这一道管的是不经表单的路:
--   直接调 commit_processing_run。连属主也一样。引擎的签名与函数体都没动。一炉的工序事后改不了(correct_run_header 不收这一栏,
--   直连改由 guard_processing_direct_write 拒),所以只守插入。
-- NOTE: introduced by db/migrations/2026-10-09-mes5b3-blending.sql.
CREATE OR REPLACE FUNCTION public.guard_blending_run_from_plan()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NEW.operation_type_code = 'blending'
       AND COALESCE(current_setting('evoltrya.blend_ctx', true), '') = '' THEN
        RAISE EXCEPTION 'BLEND_RUN_FROM_PLAN_ONLY'
          USING HINT = '配料那一炉只从一份已放行的配料计划的页面上执行(/operation/blending)。';
    END IF;
    RETURN NEW;
END;
$function$
