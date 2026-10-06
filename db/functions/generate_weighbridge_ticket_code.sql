-- db/functions/generate_weighbridge_ticket_code.sql
-- MES-2(2026-10-06,MES-0 Q53;MES-2 Step 0 Q16):地磅单编号 WB-YYYY-NNNN —— 有洞(nextval 回滚不还号),保存时生成。
-- 形状与 generate_device_code 逐字同一个(前缀经 document_type_prefix('weighbridge_ticket') 读,年取 NOW(),四位补零);
-- 只填空的 code。不是 SECURITY DEFINER:它是 weighbridge_tickets 的 BEFORE INSERT 触发器,插入只经确认 / 手工录入那几支函数。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql.

CREATE OR REPLACE FUNCTION public.generate_weighbridge_ticket_code()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NEW.code IS NULL OR NEW.code = '' THEN
        NEW.code := document_type_prefix('weighbridge_ticket') || '-' || EXTRACT(YEAR FROM NOW())::TEXT || '-' ||
                    LPAD(nextval('weighbridge_ticket_code_seq')::TEXT, 4, '0');
    END IF;
    RETURN NEW;
END;
$function$;
