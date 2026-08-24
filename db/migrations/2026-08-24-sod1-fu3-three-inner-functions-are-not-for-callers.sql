-- SOD-1-fu3:三支内层函数收回 authenticated 的 EXECUTE(gate 的 B2 抓到的)
--
-- **两支是真的越权读。** sod_manual_posters_in 与 sod_supplier_creator 都是
-- SECURITY DEFINER 且没有调用者检查;留着 authenticated 的 EXECUTE,任何登录用户
-- 都能绕过 RLS 读出「谁在这个期间记过手工凭证」与「谁建了这家供应商」。
-- assert_segregated 泄不了数据(它只抛或只返回),但同样没有调用者检查,
-- 而本仓库对这一类的处置是统一的:**没有检查的内层函数,靠的就是调不到。**
--
-- 三支都只从 guard_payment_sod / guard_finance_settings_sod 的函数体内被调用,
-- 那两个是【属主身份】跑的触发器函数,所以收回之后照常工作(fixture 127 全绿即证)。
--
-- **approvals_readiness 不在此列** —— 它要被 /finance/settings 调用,
-- 所以走的是 B2 的另一半:fu2 给它加了 require_permission('module.finance.view')。
--
-- 真源是 db/views/zzz_function_grants.sql(重建时由它施加);本迁移把同样三句
-- 施加到线上,两边因此一致。**这一条是 OPS-3/OPS-7 那一课的又一次实例:
-- 每一次 REVOKE 都必须写进那个文件,否则它活不过一次重建。**

BEGIN;

REVOKE EXECUTE ON FUNCTION public.assert_segregated(text, uuid[], text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.sod_manual_posters_in(date, date) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.sod_supplier_creator(uuid) FROM authenticated;

COMMIT;
