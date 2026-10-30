-- db/functions/contract_file_void.sql
-- CONTRACT-ESIGN(Tim 2026-10-30 Q7):【作废一份签过的版本(或一份对方签回件)】—— 签署人名单上的人或 admin(持 action.manage_signatories),
--   要一句理由;在对方签回之前或之后都可以。作废的 PDF 留在桶里、照样列出来,标「作废」;之后那份合同文件可以替换,或者重新签。
--   作废一份我方签过的版本时,建在它上面、还在用的对方签回件一起作废(同一句理由)—— 签回件签的是那一份。
--   按名拒:文件不存在 → CONTRACT_FILE_NOT_FOUND;不是一份在用的 signed / countersigned → CONTRACT_FILE_NOT_VOIDABLE|<合同号>|<种类>|<状态>;
--     既不在名单上也不持 action.manage_signatories → CONTRACT_VOID_NOT_PERMITTED;读不到这份合同的文件 → CONTRACT_FILE_RESTRICTED|<合同号>;
--     理由空 → CONTRACT_VOID_REASON_REQUIRED|<合同号>。
-- NOTE: introduced by db/migrations/2026-10-30-contract-esign.sql.
CREATE OR REPLACE FUNCTION public.contract_file_void(p_file_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_f  contract_files%ROWTYPE;
    v_c  contracts%ROWTYPE;
    v_n  int := 0;
BEGIN
    SELECT * INTO v_f FROM contract_files WHERE id = p_file_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CONTRACT_FILE_NOT_FOUND';
    END IF;
    SELECT * INTO v_c FROM contracts WHERE id = v_f.contract_id;
    IF v_f.kind NOT IN ('signed', 'countersigned') OR v_f.status <> 'current' THEN
        RAISE EXCEPTION 'CONTRACT_FILE_NOT_VOIDABLE|%|%|%', v_c.code, v_f.kind, v_f.status;
    END IF;
    IF NOT (contract_signatory_active() OR has_permission('action.manage_signatories')) THEN
        RAISE EXCEPTION 'CONTRACT_VOID_NOT_PERMITTED';
    END IF;
    IF NOT contract_file_readable(v_c.id) THEN
        RAISE EXCEPTION 'CONTRACT_FILE_RESTRICTED|%', v_c.code;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'CONTRACT_VOID_REASON_REQUIRED|%', v_c.code;
    END IF;
    IF v_f.kind = 'signed' THEN
        UPDATE contract_files SET status = 'void', voided_at = now(), voided_by = auth.uid(), void_reason = btrim(p_reason)
         WHERE source_file_id = v_f.id AND kind = 'countersigned' AND status = 'current';
        GET DIAGNOSTICS v_n = ROW_COUNT;
    END IF;
    UPDATE contract_files SET status = 'void', voided_at = now(), voided_by = auth.uid(), void_reason = btrim(p_reason)
     WHERE id = v_f.id;
    RETURN jsonb_build_object('id', v_f.id, 'state', 'void', 'countersigned_voided', v_n);
END;
$function$;
