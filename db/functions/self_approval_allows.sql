-- db/functions/self_approval_allows.sql
-- SYSTEM-MAP-2(2026-10-27):【四眼原则的判据】—— 账号 p_user 可不可以决定这一份单据(提单人 p_raiser、主角 p_subject_employee)。
--   从 forbid_self_approval 里原样搬出来,判据一字未改:self_leg 说"不是自己" → 可以;否则只有 R2 那个例外
--   (self_approval_exception:报销 · 医疗 · 请假,主角就是我,而我此刻是二级审批角色的真持有人)。
-- 两个读者,一份判据:forbid_self_approval(拒)· waiting_decisions(待办只列我批得了的)。
-- 永不返回 NULL。EXECUTE 已从 authenticated 收回(只给属主权限的调用方用)。
--
-- NOTE: introduced by db/migrations/2026-10-27-system-map-2-my-workbench.sql.

CREATE OR REPLACE FUNCTION public.self_approval_allows(p_raiser uuid, p_subject_employee uuid, p_subject_type text, p_user uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT self_leg(p_raiser, p_subject_employee, p_user) = 'none'
        OR self_approval_exception(p_subject_type, p_subject_employee, p_user,
                                   (SELECT fs.approval_level2_role_code FROM finance_settings fs LIMIT 1));
$function$;

COMMENT ON FUNCTION public.self_approval_allows(uuid, uuid, text, uuid) IS
'SYSTEM-MAP-2:四眼原则的判据(从 forbid_self_approval 原样搬出):self_leg = none,或 R2 的自批例外成立。两个读者:forbid_self_approval(拒)与 waiting_decisions(待办只列我批得了的)。永不返回 NULL。EXECUTE 已从 authenticated 收回。';
