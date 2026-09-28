-- db/functions/change_log_redact_employee.sql
-- HISTORY-1(Tim 的 Q11 · Q9):匿名化时涂抹 change_log 里关于这个人的个人字段 ——
-- change_log 【唯一】能被改的那条路。
--
-- 【谁调它】只有 anonymise_employee,在它自己那两句 UPDATE【之后】、同一笔事务里。
--   ★ 顺序是承重的:anonymise_employee 那句 UPDATE employees 本身就会被 change_log_capture
--     记一行,而那一行的 old 里装着【匿名化之前的每一个个人字段】。涂抹必须在它之后跑,
--     才涂得到它(fixture 234 的涂抹那一臂专门钉这一格)。
-- 【涂什么】employees 上这个人那一行的全部记录 + employment_history 上属于他的那些行的全部记录,
--   只涂 change_log_redactable_columns() 名单上的列(改成 JSON null),盖 redacted_at。
--   别的表只按 employee_id 引用他 —— 与 anonymise_employee 的范围逐字相同,不多不少。
-- 【证明别的都没动】不靠本函数自证:change_log 上的守卫(guard_change_log_append_only)
--   逐行核对这一句 UPDATE 的形状,多改一个键、多动一列,整句被拒。
-- 【为什么自己也查权限】它是 SECURITY DEFINER;EXECUTE 虽已从 authenticated 收回,
--   调用方 anonymise_employee 的持码人查得过这一道,多一道不多。
CREATE OR REPLACE FUNCTION public.change_log_redact_employee(p_employee_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_hist text[];
    v_n    integer;
BEGIN
    PERFORM require_permission('action.anonymise_employee');
    IF p_employee_id IS NULL THEN
        RAISE EXCEPTION 'PDPA_EMPLOYEE_NOT_FOUND';
    END IF;

    SELECT COALESCE(array_agg(h.id::text), ARRAY[]::text[]) INTO v_hist
      FROM employment_history h WHERE h.employee_id = p_employee_id;

    UPDATE change_log c
       SET old = change_log_null_keys(c.old, change_log_redactable_columns(c.table_name)),
           new = change_log_null_keys(c.new, change_log_redactable_columns(c.table_name)),
           redacted_at = clock_timestamp()
     WHERE c.redacted_at IS NULL
       AND (   (c.table_name = 'employees' AND c.row_key ->> 'id' = p_employee_id::text)
            OR (c.table_name = 'employment_history' AND c.row_key ->> 'id' = ANY (v_hist)));
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n;
END;
$function$;
