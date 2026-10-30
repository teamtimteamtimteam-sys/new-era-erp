-- db/functions/contract_file_can_upload.sql
-- CONTRACT-ESIGN(Tim 2026-10-30):【存储策略的判据】—— 这个会话能不能往 contract-files 的这一条路径传字节。
--   成立 = 有一行 status = uploading 的合同文件,路径正是这一条、是【这个会话自己】在十分钟内登记的(contract_file_begin 或
--   contract_sign_begin 判过调用者之后才写那一行)。于是:没先过 begin 的字节存不进来;别人的路径、已经存下的、过了十分钟的,一律存不进来。
--   传的人此刻仍要读得到那份合同的文件(contract_file_readable,Q8)。改与删没有策略(一份存下的文件不能被覆盖)。【绝不抛】,不成立就回 false。
-- NOTE: introduced by db/migrations/2026-10-30-contract-esign.sql.
CREATE OR REPLACE FUNCTION public.contract_file_can_upload(p_bucket text, p_name text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT COALESCE(p_bucket = 'contract-files'
       AND EXISTS (SELECT 1 FROM contract_files f
                    WHERE f.file_path = p_name AND f.status = 'uploading' AND f.created_by = auth.uid()
                      AND f.created_at > now() - interval '10 minutes' AND contract_file_readable(f.contract_id)), false)
$function$;
