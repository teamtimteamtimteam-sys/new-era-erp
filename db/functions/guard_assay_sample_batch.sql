-- db/functions/guard_assay_sample_batch.sql
-- MES-6a-1(2026-10-09,MES-6a Step 0 Q9,Tim):一份化验指着的样品必须挂在同一批上 —— SAMPLE_NOT_FOR_BATCH。
--   record_assay_result 先按名拒;这一道守着 assay_results 上的直连写(进料 / 产出编辑码持有人有写策略)。
--   DEFINER:按属主身份读 samples —— 一个看不见那份样品的写入者不该把"不是这一批的"读成"不存在"(OPS-14)。
-- NOTE: introduced by db/migrations/2026-10-09-mes6a1-samples-and-disputes.sql.
CREATE OR REPLACE FUNCTION public.guard_assay_sample_batch()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_s record;
BEGIN
    IF NEW.sample_id IS NULL THEN
        RETURN NEW;
    END IF;
    SELECT s.code, s.inbound_batch_id, s.output_batch_id INTO v_s FROM samples s WHERE s.id = NEW.sample_id;
    IF NOT FOUND OR v_s.inbound_batch_id IS DISTINCT FROM NEW.inbound_batch_id
       OR v_s.output_batch_id IS DISTINCT FROM NEW.output_batch_id THEN
        RAISE EXCEPTION 'SAMPLE_NOT_FOR_BATCH|%', COALESCE(v_s.code, NEW.sample_id::text);
    END IF;
    RETURN NEW;
END;
$function$
