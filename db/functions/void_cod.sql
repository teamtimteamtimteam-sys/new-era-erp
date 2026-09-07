CREATE OR REPLACE FUNCTION public.void_cod(p_cod_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_cod record;
BEGIN
    IF NOT has_permission('action.issue_cod') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED';
    END IF;

    -- 【没有 p_reversal_date】证书不入账,没有期间可言。void_invoice 的第 8 条:
    -- 一个用不上的参数要【拒绝】而不是收下再丢掉 —— 收下再丢掉是在对调用者撒谎。
    -- 这里更进一步:那个参数压根不存在。
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'REASON_REQUIRED';
    END IF;

    SELECT c.id, c.code, c.status INTO v_cod
      FROM certificates_of_destruction c WHERE c.id = p_cod_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'COD_NOT_FOUND|%', COALESCE(p_cod_id::text, '?');
    END IF;
    -- 【只有已签发的才作废得掉,而且作废不是幂等的】与 INVOICE_ALREADY_VOID 同一条。
    IF v_cod.status <> 'issued' THEN
        RAISE EXCEPTION 'COD_NOT_ISSUED|%|%', COALESCE(v_cod.code, v_cod.id::text), v_cod.status;
    END IF;

    PERFORM void_cod_internal(p_cod_id, p_reason, NULL);
    RETURN jsonb_build_object('cod_id', p_cod_id, 'code', v_cod.code, 'status', 'void');
END;
$function$;
