-- db/functions/guard_maintenance_capitalise_parts.sql
-- MES-7a-2(2026-10-16,MES-7a Step 0 Q14,Tim):【一条已经出过备件的保养记录,不能再资本化】—— equipment_maintenance BEFORE UPDATE OF
--   capitalised, capitalised_expense_id。从库里出给它的件已经照维修费(6800)记掉了,而资本化走的是费用单(record_expense 回填
--   capitalised_expense_id)—— 那些件没有一条路进资产成本,于是一条"资本化的大修"会少计资产。按名拒
--   MAINTENANCE_HAS_PARTS|<机器>|<日期>|<还挂着的件的条数>。另一个方向(往一条资本化了的记录上出件)由 issue_spare_parts 拒。
--   判据是【还挂着的】件:出库数量 − 已退的 > 0 的那几行。全部退回之后,这条记录上就没有件了,可以资本化。
--   "备件进资本化大修"登记在 docs/known-issues.md,等第一次真的大修再定那条路。
--   DEFINER:它要读全部出库记录(读策略认码),不能因为按按钮的人读不到就放过去(guard_quality_hold 同一个理由)。
-- NOTE: introduced by db/migrations/2026-10-16-mes7a2-spare-parts.sql.

CREATE OR REPLACE FUNCTION public.guard_maintenance_capitalise_parts()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_n    int;
    v_code text;
BEGIN
    IF NOT ((NEW.capitalised AND NOT OLD.capitalised)
            OR (NEW.capitalised_expense_id IS NOT NULL AND OLD.capitalised_expense_id IS NULL)) THEN
        RETURN NEW;
    END IF;
    SELECT count(*) INTO v_n
      FROM maintenance_part_issues i
     WHERE i.maintenance_id = NEW.id AND i.kind = 'issue'
       AND i.quantity > COALESCE((SELECT sum(r.quantity) FROM maintenance_part_issues r WHERE r.returns_issue_id = i.id), 0);
    IF v_n > 0 THEN
        SELECT code INTO v_code FROM fixed_assets WHERE id = NEW.equipment_id;
        RAISE EXCEPTION 'MAINTENANCE_HAS_PARTS|%|%|%', v_code, NEW.performed_on, v_n;
    END IF;
    RETURN NEW;
END;
$function$;
