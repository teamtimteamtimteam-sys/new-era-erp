-- db/functions/guard_ncr_mutation.sql
-- MES-6b-1(2026-10-15,MES-6b Step 0 Q7):不合格报告【只追加】—— 一行写下就不改,唯一的例外是 open → decided 那一次,而那一次只许动决定的那几列
--   (status · disposition · decision_note · decided_at · decided_by · 两张钱的单据)。别的改动、任何删除一律按名拒 NCR_IMMUTABLE|<编号>|<操作>。
--   更正一张报告 = 开一张新的、在描述里指出旧的那一张(Q7)。
--   【属主路径同样受它管】它守的是记录的形状(一张决定过的报告不许被改回开着,一张报告的批次与来源不许换),不是权限 —— 与
--   guard_append_only_log 同一个立场。写这张表的只有 open_ncr / decide_ncr / judge_quality_limits 三支 DEFINER 函数。
--   INVOKER:它不读别的表。
-- NOTE: introduced by db/migrations/2026-10-15-mes6b1-quality-hold-ncr-and-limits.sql.
CREATE OR REPLACE FUNCTION public.guard_ncr_mutation()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'NCR_IMMUTABLE|%|delete', OLD.code;
    END IF;
    -- UPDATE:只认 open → decided,而且除了决定那几列,一个字都不许变
    IF OLD.status <> 'open' OR NEW.status <> 'decided'
       OR (to_jsonb(NEW) - 'status' - 'disposition' - 'decision_note' - 'decided_at' - 'decided_by'
                         - 'penalty_invoice_request_id' - 'penalty_price_request_id')
          IS DISTINCT FROM
          (to_jsonb(OLD) - 'status' - 'disposition' - 'decision_note' - 'decided_at' - 'decided_by'
                         - 'penalty_invoice_request_id' - 'penalty_price_request_id') THEN
        RAISE EXCEPTION 'NCR_IMMUTABLE|%|update', OLD.code
          USING HINT = '一张不合格报告只在【决定】那一次改得动(open → decided,只动决定那几列)。要更正,开一张新的、在描述里指出这一张。';
    END IF;
    RETURN NEW;
END;
$function$
