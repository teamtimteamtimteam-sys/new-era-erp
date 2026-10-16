-- db/views/incidents_masked.sql
-- MES-7b-1(2026-10-16,MES-7b Step 0 Q6 · MES-0 Q76 · Q91,Tim):事故的遮蔽伴生视图。受伤的人(一名员工或一个名字)、伤情、处理、误工天数
--   要 data.view_health,【对受伤的那名员工本人让路】(行谓词与列遮蔽两处都带 OR injured_employee_id = current_user_employee() ——
--   medical_claims_masked 的同一个形状;COALESCE 收住 current_user_employee() 为空时的 NULL,CLEANUP-A 的那个陷阱)。
-- 行谓词 = 基表的读策略(module.safety.view)或本人。每一列都在这里(colgrant)。
-- 判据与 change_log_mask_rules 的 code_or_self:data.view_health:injured_employee_id 逐字同一个。

CREATE VIEW public.incidents_masked WITH (security_invoker = off) AS
 SELECT id,
    code,
    kind_code,
    occurred_at,
    location_id,
    equipment_id,
    duration_min,
    what_happened,
    immediate_action,
    responsible_employee_id,
    responsible_name,
    nea_reportable,
    source,
    downtime_id,
    run_event_id,
        CASE
            WHEN has_permission('data.view_health'::text) OR COALESCE(injured_employee_id = current_user_employee(), false) THEN injured_employee_id
            ELSE NULL::uuid
        END AS injured_employee_id,
        CASE
            WHEN has_permission('data.view_health'::text) OR COALESCE(injured_employee_id = current_user_employee(), false) THEN injured_person_name
            ELSE NULL::text
        END AS injured_person_name,
        CASE
            WHEN has_permission('data.view_health'::text) OR COALESCE(injured_employee_id = current_user_employee(), false) THEN injury_nature
            ELSE NULL::text
        END AS injury_nature,
        CASE
            WHEN has_permission('data.view_health'::text) OR COALESCE(injured_employee_id = current_user_employee(), false) THEN injury_treatment
            ELSE NULL::text
        END AS injury_treatment,
        CASE
            WHEN has_permission('data.view_health'::text) OR COALESCE(injured_employee_id = current_user_employee(), false) THEN days_lost
            ELSE NULL::numeric
        END AS days_lost,
    recorded_at,
    recorded_by
   FROM incidents
  WHERE has_permission('module.safety.view'::text) OR COALESCE(injured_employee_id = current_user_employee(), false);

COMMENT ON VIEW public.incidents_masked IS
    'MES-7b-1(Q6):事故的遮蔽伴生视图。受伤的人、伤情、处理、误工天数要 data.view_health 或就是受伤的那名员工本人;行谓词 = 基表的读策略(module.safety.view)或本人。';

-- ★ 默认权限会把 INSERT / UPDATE / DELETE 也授给 authenticated(线上 pg_default_acl:postgres 建的表与视图 authenticated=arwdDxtm),
--   而一张简单的属主视图是【可以写穿的】—— 以属主身份写基表,绕开 RLS 与那几支 DEFINER 函数的码。所以先全收,再只授回 SELECT。
REVOKE ALL ON public.incidents_masked FROM authenticated, anon;
GRANT SELECT ON public.incidents_masked TO authenticated;
