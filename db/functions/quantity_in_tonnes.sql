-- db/functions/quantity_in_tonnes.sql
-- MES-3a(2026-10-06,MES-3a Step 0 Q8,Tim):一个数量连同它的单位,换成吨 —— 库存上限的唯一一份换算。
--   kg → ÷1000 · 吨 / t → ×1 · 克 / g → ÷1,000,000;件,或任何别的(包括空)→ NULL = 换算不成。
--   【不猜】一"件"有多重,这里不知道,也不该编一个数(allocate_processing_costs 的 UNIT_NOT_KG 同一条);
--   调用方拿到 NULL 时:这一类或总量给了上限 → 按名拒(STORAGE_CEILING_UNIT_NOT_CONVERTIBLE),没给 → 记 unit_not_convertible。
--   纯函数(IMMUTABLE,不读表),所以属主视图里调它不撞读者的 RLS。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes3a-storage-safety.sql.

CREATE OR REPLACE FUNCTION public.quantity_in_tonnes(p_qty numeric, p_unit text)
 RETURNS numeric
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE lower(btrim(COALESCE(p_unit, '')))
               WHEN 'kg' THEN p_qty / 1000
               WHEN 't' THEN p_qty
               WHEN '吨' THEN p_qty
               WHEN 'g' THEN p_qty / 1000000
               WHEN '克' THEN p_qty / 1000000
           END;
$function$;
