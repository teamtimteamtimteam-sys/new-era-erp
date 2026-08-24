-- 2026-08-24 GST-1 fu:把两个查表函数从 authenticated 手里收回来。
--
-- 【为什么补这一刀】check_mirrors 的 definer 判词点了两个名字:
--   gst_registered() 与 tax_rate_for(code, date) 是 SECURITY DEFINER,
--   却没有任何调用者检查,而 authenticated 手里有 EXECUTE。
--
-- 【判断依据不是"它们看起来无害",是【谁够得着】】—— SOD-1 的 B2 教训:
--   一条规矩走它自己的执行路径能过,不等于它的每一个零件都不可达。
--   实测:app / lib 里【没有任何一处】调这两个函数;
--   界面调的是 f5_return 与 f5_box_detail(两者都带 require_permission),
--   以及 finance_settings.gst_registered 这一【列】(走该表自己的 RLS)。
--   库内的调用方只有 f5_return 与 post_journal_entry —— 两个都是 SECURITY
--   DEFINER,以属主身份执行,收回 authenticated 的 EXECUTE 不影响它们。
--
-- 【为什么不是加 require_permission】加了反而会坏:它们被属主(postgres)在
--   definer 内部调用,而 postgres 没有 claims —— require_permission 会在
--   过账与出表的路上抛权限错。与 SOD-1 里 assert_segregated 那三个同形:
--   够不着的东西不需要门,需要的是【真的够不着】。
--
-- 收回之后,这两个函数在 check_mirrors 里以【纵深防御】为由进白名单,
-- 理由与 approvals_readiness(那一个界面要调,所以加的是门)【分开写】。

BEGIN;

-- ★【实测踩到的坑,写在这里给下一个人】★ 只把 REVOKE 写进迁移是【没有用的】:
--   db/apply_migration.sh 在迁移提交之后紧接着重放 db/views/zzz_function_grants.sql,
--   而那个文件里有一句 GRANT EXECUTE ON ALL FUNCTIONS ... TO authenticated,
--   会把这里的 REVOKE 在三十秒内原样撤销。第一次跑完之后查 proacl,
--   authenticated 确实又回来了。
--   所以下面这两行是【重放一次让它落地】,真正持久的声明在
--   db/views/zzz_function_grants.sql 里 —— 那也是它唯一能活过一次重建的地方。

REVOKE EXECUTE ON FUNCTION public.gst_registered() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.tax_rate_for(text, date) FROM authenticated;

-- 顺带确认 anon 从来就没有过(默认权限只发给 postgres/authenticated/service_role
-- 之外的角色时才会出现) —— 写在这里是为了让下一个人不必再查一遍。
REVOKE EXECUTE ON FUNCTION public.gst_registered() FROM anon;
REVOKE EXECUTE ON FUNCTION public.tax_rate_for(text, date) FROM anon;

COMMIT;
