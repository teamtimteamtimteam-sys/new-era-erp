-- db/functions/record_contamination_check.sql
-- MES-4b(2026-10-07,规格 §3.4;MES-0 Q52;MES-4b Step 0 Q21–Q25,Tim):【在加工单页上记一次交叉污染抽检】(或"这一班没抽",带理由)。
--   码:action.processing_aftercare(提交之后补记的那一个码,MES-4a)。判据全在 contamination_check_internal。返回新行 id。
--   一个班可以抽不止一次(多条都留着);任何一条当前的抽检(两种都算)关掉那一班那条流的提醒(contamination_check_missing)。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4b-fields-and-products.sql.

CREATE OR REPLACE FUNCTION public.record_contamination_check(p_run_id uuid, p_stream_code text, p_kind text, p_output_batch_id uuid DEFAULT NULL::uuid, p_sample_mass_g numeric DEFAULT NULL::numeric, p_foreign_mass_g numeric DEFAULT NULL::numeric, p_sampled_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_method text DEFAULT NULL::text, p_not_sampled_reason text DEFAULT NULL::text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('action.processing_aftercare');
    RETURN contamination_check_internal(p_run_id, p_stream_code, p_kind, p_output_batch_id, p_sample_mass_g, p_foreign_mass_g,
                                        p_sampled_at, p_method, p_not_sampled_reason, NULL, NULL);
END;
$function$