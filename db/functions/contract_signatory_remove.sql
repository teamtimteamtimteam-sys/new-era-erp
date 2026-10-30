-- db/functions/contract_signatory_remove.sql
-- CONTRACT-ESIGN(Tim 2026-10-29 · Q3 · Q7):把一名签署人移出名单 —— 那一行记 removed_at / removed_by,不删;
--   他已经签过的每一份照旧有效(Q7:移除不作废任何一份)。要 action.manage_signatories。
--   按名拒:没有码 → PERMISSION_DENIED|action.manage_signatories;这一行不存在或已经移除 → CONTRACT_SIGNATORY_NOT_LISTED。
-- NOTE: introduced by db/migrations/2026-10-30-contract-esign.sql.
CREATE OR REPLACE FUNCTION public.contract_signatory_remove(p_signatory_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('action.manage_signatories');
    UPDATE contract_signatories SET removed_at = now(), removed_by = auth.uid()
     WHERE id = p_signatory_id AND removed_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CONTRACT_SIGNATORY_NOT_LISTED';
    END IF;
    RETURN jsonb_build_object('id', p_signatory_id, 'state', 'removed');
END;
$function$;
