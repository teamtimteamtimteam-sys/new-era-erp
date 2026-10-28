-- db/functions/generate_overtime_batch_code.sql
-- SYSTEM-MAP-3(Tim 2026-10-27 Q4):加班批登记成单据种类,于是它要一个单据号。
--   形状与"一个月一份、补充的一份带序号"的那几种逐字同一条(管理月报 PACK、合规包 CPK、代扣汇缴 WHT):
--   OT-YYYY-MM(当月第一批)· OT-YYYY-MM-2、-3 …(补充批)。序号就是这张表自己的 seq(一个月内 1, 2, 3 …)。
--   原来的 label(「OT 2026-10 #1」)留着,是显示名。前缀取自 document_types(document_type_prefix),不写字面量。
-- 触发器而不是在 create_overtime_batch 里铸:每一条插进这张表的路(含 fixture 直接插)都得到同一个号。
--
-- NOTE: introduced by db/migrations/2026-10-27-system-map-3-chain-bar.sql.

CREATE OR REPLACE FUNCTION public.generate_overtime_batch_code()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NEW.code IS NULL OR NEW.code = '' THEN
        NEW.code := document_type_prefix('overtime_batch') || '-' || to_char(NEW.period_month, 'YYYY-MM')
                    || CASE WHEN NEW.seq > 1 THEN '-' || NEW.seq::text ELSE '' END;
    END IF;
    RETURN NEW;
END;
$function$;
