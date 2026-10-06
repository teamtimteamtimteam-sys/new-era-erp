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
        NEW.code := document_type_prefix('device') || '-' || EXTRACT(YEAR FROM NOW())::TEXT || '-' ||
                    LPAD(nextval('device_code_seq')::TEXT, 4, '0');
    END IF;
    RETURN NEW;
END;
$function$;
