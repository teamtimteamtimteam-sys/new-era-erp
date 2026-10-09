-- db/functions/guard_blended_batch_metals_from_assay.sql
-- MES-5b-3(2026-10-09,MES-5b Step 0 Q18,Tim):【混出来那一批的含量只来自化验,绝不来自预测】—— output_batch_metals 上的 BEFORE INSERT / UPDATE 守卫。
--   这一批是一炉 blending 的产出,而写进来的一行不是 content_source = 'assay'(只有 apply_output_assay 写那一种,guard_batch_metals_assay_source
--   管着它的门)→ 按名拒 BLEND_CONTENT_FROM_ASSAY_ONLY|<批号>。人填的一个数、或从计划页抄过去的预测,都过不去。
--   ★ SECURITY DEFINER:它要读 processing_outputs / processing_runs 才认得出"这是混出来的那一批";以写入者的身份读,一个看不见加工的
--     产出编辑者会读到零行,而零行在这里就是"放行" —— 一支 void 守卫的沉默与通过是同一个字节(AGENTS.md 那一族)。
-- NOTE: introduced by db/migrations/2026-10-09-mes5b3-blending.sql.
CREATE OR REPLACE FUNCTION public.guard_blended_batch_metals_from_assay()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NEW.content_source IS DISTINCT FROM 'assay'
       AND EXISTS (SELECT 1 FROM processing_outputs po JOIN processing_runs r ON r.id = po.run_id
                    WHERE po.output_batch_id = NEW.output_batch_id AND r.operation_type_code = 'blending') THEN
        RAISE EXCEPTION 'BLEND_CONTENT_FROM_ASSAY_ONLY|%', (SELECT ob.code FROM output_batches ob WHERE ob.id = NEW.output_batch_id)
          USING HINT = '混出来的那一批的金属含量只来自化验:记一份化验,再应用它。计划页上的预测不是含量。';
    END IF;
    RETURN NEW;
END;
$function$
