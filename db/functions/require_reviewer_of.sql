-- db/functions/require_reviewer_of.sql
-- 评估人写入路径的共用守卫:调用者是这一行的评估人(或持 module.hr.edit),
-- 且评估处在允许的状态。返回那一行,免得每个函数各查一次、各看到不同的行。
--
-- NOTE: introduced by db/migrations/2026-08-03-hr3d-reviewer-write-path.sql;

CREATE OR REPLACE FUNCTION public.require_reviewer_of(p_review_id uuid, p_allowed_status text[])
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
-- %ROWTYPE 在【函数体】里,check_function_bodies=off 豁免的正是这里,所以没问题。
DECLARE v_r performance_reviews%ROWTYPE;
BEGIN
    SELECT * INTO v_r FROM performance_reviews WHERE id = p_review_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'REVIEW_NOT_FOUND|%', COALESCE(p_review_id::text, '?');
    END IF;
    IF NOT (has_permission('module.hr.edit')
            OR is_reviewer_of(v_r.reviewer_employee_id)) THEN
        RAISE EXCEPTION 'NOT_REVIEW_REVIEWER';
    END IF;
    IF NOT (v_r.status = ANY (p_allowed_status)) THEN
        RAISE EXCEPTION 'REVIEW_BAD_STATUS|%', v_r.status;
    END IF;
END;
$function$
;