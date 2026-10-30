-- db/functions/contract_file_can_read.sql
-- CONTRACT-ESIGN(Tim 2026-10-30 Q8):【存储策略的判据】—— 这个会话能不能读 contract-files 里的这一个对象。
--   成立 = 它是一行合同文件的路径,这个会话读得到那份合同的文件(那一侧的读码 + 价格码,contract_file_readable),而且那一行已经存下
--   (current / superseded / void —— 作废的照样读得到,Q7),或者是这个会话自己刚登记、还在传的那一条(Storage API 的读回)。【绝不抛】。
-- NOTE: introduced by db/migrations/2026-10-30-contract-esign.sql.
CREATE OR REPLACE FUNCTION public.contract_file_can_read(p_bucket text, p_name text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT COALESCE(p_bucket = 'contract-files'
       AND EXISTS (SELECT 1 FROM contract_files f
                    WHERE f.file_path = p_name
                      AND (f.status IN ('current', 'superseded', 'void') OR (f.status = 'uploading' AND f.created_by = auth.uid()))
                      AND contract_file_readable(f.contract_id)), false)
$function$;
