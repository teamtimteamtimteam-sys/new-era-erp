-- db/functions/contract_file_abandon.sql
-- CONTRACT-ESIGN(Tim 2026-10-30):【一个合同文件没传成 / 没签成】—— 自己登记的、还在 uploading 的那一行变成 abandoned。
--   传字节失败、服务端按文件头认出不是 PDF、PDF 带密码打不开、或盖章那一步失败时,由服务端动作调它。桶里若已留下字节,它们留着
--   (没有删除策略 —— 与报销收据、门户同一条)。按名拒:不是自己登记的、或此刻读不到那份合同的文件 → CONTRACT_FILE_NOT_FOUND;不在 uploading → CONTRACT_FILE_NOT_UPLOADING|<状态>。
-- NOTE: introduced by db/migrations/2026-10-30-contract-esign.sql.
CREATE OR REPLACE FUNCTION public.contract_file_abandon(p_file_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_status   text;
    v_contract uuid;
BEGIN
    SELECT x.status, x.contract_id INTO v_status, v_contract FROM contract_files x WHERE x.id = p_file_id AND x.created_by = auth.uid() FOR UPDATE;
    IF NOT FOUND OR NOT contract_file_readable(v_contract) THEN
        RAISE EXCEPTION 'CONTRACT_FILE_NOT_FOUND';
    END IF;
    IF v_status <> 'uploading' THEN
        RAISE EXCEPTION 'CONTRACT_FILE_NOT_UPLOADING|%', v_status;
    END IF;
    UPDATE contract_files SET status = 'abandoned' WHERE id = p_file_id;
    RETURN jsonb_build_object('id', p_file_id, 'state', 'abandoned');
END;
$function$;
