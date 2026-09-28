-- db/functions/overtime_other_approver_exists.sql
-- OVERTIME-1(Tim Q12):除了提单人与批里的每一个员工(都按人认),还有没有一个【真持有人】持
-- action.overtime_approve。没有 → 建批与提交按名拒 OVERTIME_NO_OTHER_APPROVER,
-- 否则那一批生下来就没人批得动。
--   "真持有人" = real_role_grants(未撤销 / 已确认 / 未封禁 / 未删除),与 create_work_order 的
--   WO_NO_OTHER_RELEASER 同一句判据;"不是同一个人" = self_leg(…) = 'none'(跨账号)。
-- 【不看审批开关】加班永远等人批(Tim Q5)。
-- 【不是 SECURITY DEFINER,EXECUTE 从 authenticated 收回】它读 real_role_grants(已收回),
--   调用者全是 DEFINER。
--
-- NOTE: introduced by db/migrations/2026-09-28-overtime1-site-staff-overtime-by-month.sql.

CREATE OR REPLACE FUNCTION public.overtime_other_approver_exists(p_raiser uuid, p_subjects uuid[])
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT EXISTS (
        SELECT 1
          FROM role_permissions rp
          JOIN roles r ON r.id = rp.role_id
         CROSS JOIN LATERAL real_role_grants(r.code) g
         WHERE rp.permission_code = 'action.overtime_approve'
           AND self_leg(p_raiser, NULL::uuid, g.user_id) = 'none'
           AND NOT EXISTS (SELECT 1 FROM unnest(COALESCE(p_subjects, '{}'::uuid[])) s(emp)
                            WHERE self_leg(NULL::uuid, s.emp, g.user_id) <> 'none'));
$function$;

COMMENT ON FUNCTION public.overtime_other_approver_exists(uuid, uuid[]) IS
'OVERTIME-1(Tim Q12):除了提单人与批里的每一个员工(按人认,跨账号),还有没有一个真持有人(real_role_grants)持 action.overtime_approve。不看审批开关。EXECUTE 已从 authenticated 收回。';
