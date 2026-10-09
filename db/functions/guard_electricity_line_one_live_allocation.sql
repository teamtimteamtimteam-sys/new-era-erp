-- db/functions/guard_electricity_line_one_live_allocation.sql
-- MES-5b-2(2026-10-09,MES-5b Step 0 Q23,Tim):【一炉最多在一张没撤回的分摊里】—— 取代 electricity_allocation_lines.run_id 的唯一约束。
--   唯一约束不认"撤回过":一炉的分摊撤回之后,它那一行仍在(分摊与行只追加),于是改正过的账单永远插不进同一炉。
--   这里只数【没撤回】的分摊(electricity_allocation_reversals 里没有它那一行)里的同一炉;有 → ELECTRICITY_RUN_ALREADY_ALLOCATED|PROC-…
--   (electricity_allocation_compute 在预览那一步就按同一句拒,这一道是落库时的最后一道 —— 两次过账之间由 post 的咨询锁串行)。
--
-- NOTE: introduced by db/migrations/2026-10-09-mes5b2-reversals.sql.

CREATE OR REPLACE FUNCTION public.guard_electricity_line_one_live_allocation()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF EXISTS (SELECT 1 FROM electricity_allocation_lines l
                WHERE l.run_id = NEW.run_id AND l.allocation_id <> NEW.allocation_id
                  AND NOT EXISTS (SELECT 1 FROM electricity_allocation_reversals v WHERE v.allocation_id = l.allocation_id)) THEN
        RAISE EXCEPTION 'ELECTRICITY_RUN_ALREADY_ALLOCATED|%', (SELECT code FROM processing_runs WHERE id = NEW.run_id);
    END IF;
    IF EXISTS (SELECT 1 FROM electricity_allocation_lines l WHERE l.run_id = NEW.run_id AND l.allocation_id = NEW.allocation_id) THEN
        RAISE EXCEPTION 'ELECTRICITY_RUN_ALREADY_ALLOCATED|%', (SELECT code FROM processing_runs WHERE id = NEW.run_id);
    END IF;
    RETURN NEW;
END;
$function$;
