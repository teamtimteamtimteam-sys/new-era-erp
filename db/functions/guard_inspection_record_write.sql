-- db/functions/guard_inspection_record_write.sql
-- MES-7b-2(2026-10-16,MES-7b Step 0 Q13 · Q14,Tim):一次巡检的四张表(inspection_runs · inspection_results · inspection_findings ·
--   inspection_finding_closures)的守卫,一支函数几种挂法 ——
--   语句级 UPDATE / DELETE:对谁都按名拒 INSPECTION_RECORD_IMMUTABLE|<表>|<动作> —— 交了的巡检不改(Q13),记错了再记一次、引用它。
--     唯一的例外是 inspection_findings 的 UPDATE:会话里直连按名拒 INSPECTION_THROUGH_FUNCTION_ONLY,属主路径放行到行级那一支
--     (只许 task_id 从空到有 —— raise_inspection_finding_task 那一次);删一条发现对谁都拒。
--   行级 INSERT:会话里直连按名拒 INSPECTION_THROUGH_FUNCTION_ONLY;下面这几条说的是【行】,对每一个写入者都成立:
--     巡检时刻不在未来(INSPECTION_TIME_IN_FUTURE|<时刻>)· 一条发现挂在同一次巡检的一项结果上(INSPECTION_FINDING_RESULT_MISMATCH)、
--     那一项是不合格(INSPECTION_FINDING_NOT_A_FAIL|<项>)、那一次巡检没有被更正过(INSPECTION_RUN_SUPERSEDED|<编号>)。
--   行级 UPDATE(只挂在 inspection_findings 上):只许 task_id 从空到有、别的一列都不动,否则 INSPECTION_FINDING_IMMUTABLE。
--   【INVOKER】row_security_active 要反映调用者的视角。
-- NOTE: introduced by db/migrations/2026-10-16-mes7b2-inspections-and-environment.sql.
CREATE OR REPLACE FUNCTION public.guard_inspection_record_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_res record;
    v_by  text;
BEGIN
    IF TG_LEVEL = 'STATEMENT' THEN
        IF TG_TABLE_NAME = 'inspection_findings' AND TG_OP = 'UPDATE' THEN
            IF row_security_active(TG_RELID) THEN
                RAISE EXCEPTION 'INSPECTION_THROUGH_FUNCTION_ONLY';
            END IF;
            RETURN NULL;
        END IF;
        RAISE EXCEPTION 'INSPECTION_RECORD_IMMUTABLE|%|%', TG_TABLE_NAME, lower(TG_OP)
          USING HINT = '一次交了的巡检不改。记错了就再记一次,引用它、写下理由;一条发现的关闭写下就不改。';
    END IF;
    IF TG_OP = 'UPDATE' THEN
        IF OLD.task_id IS NULL AND NEW.task_id IS NOT NULL
           AND (to_jsonb(NEW) - 'task_id') = (to_jsonb(OLD) - 'task_id') THEN
            RETURN NEW;
        END IF;
        RAISE EXCEPTION 'INSPECTION_FINDING_IMMUTABLE'
          USING HINT = '一条发现写下之后只有"建一张任务"那一次能填它的任务;要关闭它,记一次关闭。';
    END IF;
    IF row_security_active(TG_RELID) THEN
        RAISE EXCEPTION 'INSPECTION_THROUGH_FUNCTION_ONLY';
    END IF;
    IF TG_TABLE_NAME = 'inspection_runs' THEN
        IF NEW.inspected_at > now() THEN
            RAISE EXCEPTION 'INSPECTION_TIME_IN_FUTURE|%', to_char(NEW.inspected_at AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI');
        END IF;
    ELSIF TG_TABLE_NAME = 'inspection_findings' THEN
        SELECT r.run_id, r.result, r.position INTO v_res FROM inspection_results r WHERE r.id = NEW.result_id;
        IF NOT FOUND OR v_res.run_id IS DISTINCT FROM NEW.run_id THEN
            RAISE EXCEPTION 'INSPECTION_FINDING_RESULT_MISMATCH';
        END IF;
        IF v_res.result <> 'fail' THEN
            RAISE EXCEPTION 'INSPECTION_FINDING_NOT_A_FAIL|%', v_res.position
              USING HINT = '一条发现跟着一项不合格的结果 —— 合格与不适用的项没有要纠正的事。';
        END IF;
        SELECT x.code INTO v_by FROM inspection_runs x WHERE x.corrects_run_id = NEW.run_id;
        IF v_by IS NOT NULL THEN
            RAISE EXCEPTION 'INSPECTION_RUN_SUPERSEDED|%', v_by
              USING HINT = '这一次巡检已经被更正过 —— 把发现记在更正的那一次上。';
        END IF;
    END IF;
    RETURN NEW;
END;
$function$;
