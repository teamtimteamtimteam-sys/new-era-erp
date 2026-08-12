-- db/views/zzz_function_grants.sql
-- 【函数的 EXECUTE 权限 —— 镜像此前完全没有记它们】
--
-- ════════════════════════════════════════════════════════════════════════════
-- pg_get_functiondef 不吐 GRANT/REVOKE,而表镜像是【手写】把 GRANT 补进去的
-- (22 个表镜像里都有),函数镜像没有。后果是实测出来的:
--     live    calculate_metal_price_internal  anon=false authenticated=false
--     rebuilt calculate_metal_price_internal  anon=true  authenticated=true
--     live    reverse_journal_entry_internal  anon=false authenticated=false
--     rebuilt reverse_journal_entry_internal  anon=true  authenticated=true
-- 也就是说【这个系统里每一次 REVOKE 都活不过一次重建】。照镜像切到生产,
-- 冲销分录的引擎会向匿名用户敞开 —— 而匿名 key 是随应用公开发出去的。
--
-- 【为什么这个文件住在 db/views/ 而不是 db/functions/】重放顺序是
-- functions → tables → views,而【表镜像里也定义函数】(守卫触发器、取号函数,共 36 个)。
-- 放在 db/functions 里跑,那 36 个还没建出来,REVOKE ON ALL FUNCTIONS 收不到它们 ——
-- 实测:重建之后 anon 仍能调 36 个。放在 views 阶段、文件名 zzz 排最后,才真的收得干净。
-- 它不定义任何视图,只声明权限。
--
-- 【anon 在 public 架构里不该有任何 EXECUTE】anon 就是互联网。
-- 未登录的界面(登录页、设置密码页)走的是 Supabase auth 端点,不调 public 的函数,
-- 所以这是一句可以下得很死的断言,而不是需要逐个斟酌的清单。
-- 真有哪个函数将来必须给 anon,就在下面显式加一行【并写明理由】。
-- ════════════════════════════════════════════════════════════════════════════

-- 先全部收回(含 PUBLIC —— 默认授权给的是 PUBLIC,authenticated 是从它继承的;
-- 只收 authenticated/anon 是没有用的,OPS-3 实测过)。
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC, anon;

-- 再把登录用户与服务角色需要的授回。
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO authenticated, service_role;

-- 【内层函数:连 authenticated 也不给】它们没有调用者检查,靠的就是调不到。
-- 有调用者检查的函数不在此列 —— 那是另一半保证(见 check 的 C1 不变式)。
REVOKE EXECUTE ON FUNCTION public.calculate_metal_price_internal(uuid, jsonb, numeric, date) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.reverse_journal_entry_internal(uuid, date, text) FROM authenticated;
-- FIN-27:条款解析与承诺写入的内层算子。同上 —— 没有调用者检查,靠的就是调不到;
-- 它们只从 calculate_metal_price_internal / apply_assay_result /
-- reprice_from_committed_terms / create_purchase_order 的函数体内被调用(属主身份)。
REVOKE EXECUTE ON FUNCTION public.pricing_terms_of_formula(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.pricing_terms_of_commitment(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.calculate_metal_price_from_terms(jsonb, jsonb, numeric, date) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.commit_pricing_terms(uuid, uuid, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.resolve_pricing_commitment(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.committed_terms_price(uuid, date) FROM authenticated;
-- APR-1:审批留痕的唯一写入口。没有调用者检查 —— 它只从 decide_leave_request /
-- decide_medical_claim / submit_review / approve_review / acknowledge_review 的函数体内
-- 以属主身份被调用,而那五个各自已经把过关了。给了 authenticated 就等于任何登录用户
-- 都能伪造一行留痕,而留痕正是"不可伪造"才有意义的东西。
REVOKE EXECUTE ON FUNCTION public.record_approval_decision(text, uuid, text, smallint, text) FROM authenticated;
-- APR-2:审批引擎的两个内层算子。approval_level_for 读的是 finance_settings 上的阈值,
-- require_approver_for 是"你能不能批这一级"的判词本身 —— 两个都没有调用者检查,
-- 靠的就是调不到。公开入口是 approve_purchase_order / reject_purchase_order,
-- 它们各自 require_permission。给了 authenticated 就等于把阈值和授权判断敞开。
REVOKE EXECUTE ON FUNCTION public.approval_level_for(numeric) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.require_approver_for(smallint) FROM authenticated;
-- SAL-B:客户敞口算子。无调用者检查,靠调不到 —— 消费方是 record_output_sale
-- (definer)与 operations_now(属主视图),两者都以属主身份执行。给了
-- authenticated 就等于把任意客户的应收敞口敞开给没有财务权限的人。
REVOKE EXECUTE ON FUNCTION public.customer_ar_exposure_base(uuid) FROM authenticated;
-- IOD-1:库存排空与冲销镜像的内层算子。无调用者检查,靠的就是调不到 ——
-- drain_stock 的调用方是 record_output_sale(output.edit)、commit_processing_run
-- (processing.edit)与注销触发器(批次侧的 edit),【三者各自已经把过关】,
-- 而它们分属不同模块:给 drain_stock 挑一个权限码只能挑一个比三者都松的,
-- 那不是把关、那是把关的样子。mirror_consume_restore 只从 rollback_processing_run
-- 体内被调用。给了 authenticated 就等于任何登录用户都能凭空写出入库/出库流水。
REVOKE EXECUTE ON FUNCTION public.drain_stock(numeric, text, date, uuid, uuid, text[], uuid, text, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.mirror_consume_restore(uuid, uuid, uuid, numeric, date, uuid) FROM authenticated;
-- IOD-1b:收货库位的翻译器。三个建批次 RPC 共用它,而那三个分属两个模块
-- (进料 inbound.edit / 产出 output.edit)且各自已把过关 —— 给它挑一个权限码
-- 只能挑一个比两者都松的。靠"调不到"。
REVOKE EXECUTE ON FUNCTION public.resolve_receipt_location(uuid) FROM authenticated;
