-- db/functions/generate_device_code.sql
-- MES-1(2026-10-06,Q28):设备编号 DEV-YYYY-NNNN —— 有洞(nextval 回滚不还号),保存时生成。
-- 形状与 generate_task_code 逐字同一个(前缀经 document_type_prefix('device') 读,年取 NOW(),四位补零);
-- 只填空的 code。不是 SECURITY DEFINER:它是 devices 的 BEFORE INSERT 触发器,插入只经 save_device。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes1-entry-point.sql.

CREATE OR REPLACE FUNCTION public.generate_device_code()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NEW.code IS NULL OR NEW.code = '' THEN
        -- MES-4b(CODE-WIDTH-4,Step 0 Q14):补到 4 位、【不截断】—— 超过 9,999 照实长出去;低于 10,000 的号逐字不变。
        NEW.code := document_type_prefix('device') || '-' || EXTRACT(YEAR FROM NOW())::TEXT || '-' ||
                    (SELECT LPAD(n, GREATEST(4, length(n)), '0') FROM (SELECT nextval('device_code_seq')::TEXT AS n) s);
    END IF;
    RETURN NEW;
END;
$function$;
