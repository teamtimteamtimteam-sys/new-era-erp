-- db/views/finance_settings_lookup.sql
-- FIX-2a(2026-09-05)· 跨模块【查名】视图。
-- ★ 暴露面【就是】下面的列清单。加一列等于扩一次权 —— 连着 db/fixtures/194 一起想。
-- 不变量:本视图只改【行】谓词;每一列原样保留它已有的 data.* 遮蔽。
-- NOTE: introduced by db/migrations/2026-09-05-fix2a-cross-module-lookup-views.sql.

CREATE VIEW public.finance_settings_lookup WITH (security_invoker = off) AS
 SELECT id,
    gst_registered,
    gst_rate_pct,
    default_allocation_basis
   FROM finance_settings s
  WHERE has_permission('module.finance.view'::text) OR has_permission('module.customers.view'::text) OR has_permission('module.suppliers.view'::text) OR has_permission('module.processing.view'::text);

COMMENT ON VIEW public.finance_settings_lookup IS
    'FIX-2a:财务设置里【三个被别的模块读的开关】—— 是否 GST 登记 / GST 税率 / 默认分摊基准。客户与供应商编辑页要第一个,新建加工单要第三个。★ locked_before(期间锁)、approval_threshold_base(审批阈值)、gst_registration_no(登记号)【都不在列上】:没有调用点读它们,而它们各自是一条真正的财务配置。行谓词 finance.view OR customers.view OR suppliers.view OR processing.view。';

GRANT SELECT ON public.finance_settings_lookup TO authenticated;
