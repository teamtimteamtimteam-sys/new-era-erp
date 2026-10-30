-- db/functions/contract_signatory_add.sql
-- CONTRACT-ESIGN(Tim 2026-10-29 · Q3):把一名员工加进签署人名单(设置页 · 签署人)。要 action.manage_signatories(只授 admin)。
--   按名拒:没有这个码 → PERMISSION_DENIED|action.manage_signatories;员工不存在 / 已删 → CONTRACT_SIGNATORY_EMPLOYEE_NOT_FOUND;
--   员工没有登录账号(签字要他以自己的账号登录)→ CONTRACT_SIGNATORY_NO_LOGIN|<员工号>;已经在册 → CONTRACT_SIGNATORY_ALREADY_LISTED|<员工号>;
--   职衔空(签字时要印出来)→ CONTRACT_SIGNATORY_TITLE_REQUIRED。过了写一行(变更记录记下谁、何时加了谁)。
-- NOTE: introduced by db/migrations/2026-10-30-contract-esign.sql.
CREATE OR REPLACE FUNCTION public.contract_signatory_add(p_employee_id uuid, p_title text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_e  employees%ROWTYPE;
    v_id uuid;
BEGIN
    PERFORM require_permission('action.manage_signatories');
    SELECT * INTO v_e FROM employees WHERE id = p_employee_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CONTRACT_SIGNATORY_EMPLOYEE_NOT_FOUND';
    END IF;
    IF v_e.user_id IS NULL AND NOT EXISTS (SELECT 1 FROM employee_accounts a WHERE a.employee_id = v_e.id) THEN
        RAISE EXCEPTION 'CONTRACT_SIGNATORY_NO_LOGIN|%', v_e.code;
    END IF;
    IF EXISTS (SELECT 1 FROM contract_signatories s WHERE s.employee_id = v_e.id AND s.removed_at IS NULL) THEN
        RAISE EXCEPTION 'CONTRACT_SIGNATORY_ALREADY_LISTED|%', v_e.code;
    END IF;
    IF p_title IS NULL OR btrim(p_title) = '' THEN
        RAISE EXCEPTION 'CONTRACT_SIGNATORY_TITLE_REQUIRED';
    END IF;
    INSERT INTO contract_signatories (employee_id, title, added_by)
    VALUES (v_e.id, left(btrim(p_title), 120), auth.uid())
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('id', v_id, 'employee_id', v_e.id);
END;
$function$;
