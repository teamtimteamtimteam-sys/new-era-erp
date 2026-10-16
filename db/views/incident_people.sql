-- db/views/incident_people.sql
-- MES-7b-1(2026-10-16,MES-7b Step 0 Q3 · Q6):记事故那张表单的两个人选框(负责的人、受伤的人)读的名单 —— handover_people 的同一个形状。
--   【为什么它存在】employees 的行策略要 module.hr.view,而记事故的人是 cto 与仓库(module.safety.edit)。不给这张视图,两个下拉框会静默地空着。
--   只有 id / code / preferred_name 三列 —— 工号与称呼名;legal_name、身份、联系方式、薪酬一列都不透。
--   ★ 挑一个人做"受伤的人"不是读健康数据:伤情是记录人自己写下的,读回来才要 data.view_health。
--
-- NOTE: introduced by db/migrations/2026-10-16-mes7b1-incidents.sql.

CREATE VIEW public.incident_people WITH (security_invoker = off) AS
 SELECT e.id,
    e.code,
    e.preferred_name
   FROM employees e
  WHERE e.deleted_at IS NULL AND has_permission('module.safety.view'::text);

COMMENT ON VIEW public.incident_people IS
    'MES-7b-1:记事故表单的人选框读的名单(工号与称呼名),门 module.safety.view。employees 的行策略要 HR 查看码,记事故的人没有它。';

-- ★ 默认权限会把 INSERT / UPDATE / DELETE 也授给 authenticated(线上 pg_default_acl:postgres 建的表与视图 authenticated=arwdDxtm),
--   而一张简单的属主视图是【可以写穿的】—— 以属主身份写基表,绕开 RLS 与那几支 DEFINER 函数的码。所以先全收,再只授回 SELECT。
REVOKE ALL ON public.incident_people FROM authenticated, anon;
GRANT SELECT ON public.incident_people TO authenticated;
