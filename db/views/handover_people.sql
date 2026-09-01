-- db/views/handover_people.sql
-- PROC-SUPPORT-1(R4):交接班那两个人选框读的名单。
-- 【为什么它存在】employees 的行策略要 module.hr.view,而交接班的使用者是车间
-- 技师(module.processing.*)。不给这张视图,两个下拉框会**静默地空着** ——
-- 那正是 docs/silent-disable-inventory.md 记的那个病。
-- 属主权限 + 把模块谓词原样写回视图体,形状抄 processing_runs_masked。
--
-- NOTE: introduced by db/migrations/2026-09-01-procsupport1-a-an-operation-is-not-optional.sql.

CREATE VIEW public.handover_people WITH (security_invoker = off) AS
 SELECT e.id,
        e.code,
        e.preferred_name,
        e.work_category
   FROM employees e
  WHERE e.deleted_at IS NULL
    AND has_permission('module.processing.view'::text);

COMMENT ON VIEW public.handover_people IS
    'PROC-SUPPORT-1(R4):交接班那两个人选框读的名单。
【为什么它存在】employees 的行策略要 module.hr.view,而交接班的使用者是车间技师(module.processing.*)。不给这张视图,两个下拉框会**静默地空着** —— 屏幕上没有任何解释,而这正是 docs/silent-disable-inventory.md 记的那个病。
【它透出什么、不透出什么】只有 id / code / preferred_name / work_category 四列。legal_name、身份证件、联系方式、薪酬**一列都不透**(那些由 employees_masked 的字段级遮蔽护着,与本视图无关)。**给同事看见同事的工号与称呼是相称的;给他看见薪酬不是。**
★【第一天它会返回几行?】★ 未软删员工 6 人(2 真 + 4 张 ZZ 刮擦行),而 work_category = ''shopfloor'' 的是 **0 人**。**本视图刻意【不】按 work_category 过滤** —— 过滤会让它第一天返回 0 行,于是屏幕在还没有技师的时候连"这里应该有人"都说不出来;而按 work_category 限制谁能交接班,本身是一条【没有人下过】的政策裁定。不发明它。';

GRANT SELECT ON public.handover_people TO authenticated;
