-- db/functions/guard_processing_run_header.sql
-- MES-4a(2026-10-07,MES-0 Q42;MES-4a Step 0 Q7,Tim):processing_runs 的 BEFORE INSERT 触发器 —— 每一张【新】加工单的表头过
--   assert_run_header(开始、结束、班次必填;时间合理;加工日落在两者之间)。只挂 INSERT:旧单(开始时刻为空)永远不被它碰,
--   于是它们照样分摊得了、冲销得了 —— 一条 NOT VALID 的 CHECK 做不到这一点(它对旧行的每一次 UPDATE 照样检查)。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.

CREATE OR REPLACE FUNCTION public.guard_processing_run_header()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM assert_run_header(NEW.process_date, NEW.started_at, NEW.ended_at, NEW.shift_code);
    RETURN NEW;
END;
$function$
