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
-- SOD-1(2026-08-24):职责分离的三支内层函数。**gate 的 B2 抓到它们**,
-- 而其中两支是真的越权读:sod_manual_posters_in / sod_supplier_creator 是
-- SECURITY DEFINER 且没有调用者检查,留着 authenticated 的 EXECUTE,任何登录用户
-- 都能绕过 RLS 读出"谁记过手工凭证"与"谁建了这家供应商"。
-- 三支都只从 guard_payment_sod / guard_finance_settings_sod 的函数体内被调用,
-- 而那两个是属主身份跑的触发器 —— 所以收回之后照常工作,靠的就是调不到。
-- (approvals_readiness 不在此列:它【要】被页面调用,所以走的是另一半保证 ——
--  fu2 给它加了 require_permission('module.finance.view')。)
REVOKE EXECUTE ON FUNCTION public.assert_segregated(text, uuid[], text) FROM authenticated;

-- GST-1(2026-08-24):两支查表函数。**gate 的 definer 判词点了它们的名**。
-- 它们都是 SECURITY DEFINER 且没有调用者检查:tax_rate_for 绕过 tax_rates 的 RLS,
-- gst_registered 绕过 finance_settings 的 RLS。
-- 实测 app / lib 里没有任何一处调它们 —— 界面调的是 f5_return / f5_box_detail
-- (两者都带 require_permission),以及 finance_settings.gst_registered 这一【列】
-- (走该表自己的 RLS)。库内只有 f5_return 与 post_journal_entry 调它们,
-- 两个都是 SECURITY DEFINER,以属主身份执行,收回之后照常工作。
-- 【为什么不给它们加 require_permission】它们被属主(postgres)在 definer 内部调用,
-- 而 postgres 没有 claims —— 加了门反而会在过账与出表的路上抛权限错。
-- 与上面三支同形:够不着的东西不需要门,需要的是【真的够不着】。
REVOKE EXECUTE ON FUNCTION public.gst_registered() FROM authenticated;

-- EQP-PAY-1(2026-09-01):一张采购单是设备单还是材料单。**gate 的 B2 点了它的名。**
-- 它是 SECURITY DEFINER 且没有调用者检查 —— 而那是【故意的】:它是给守卫触发器
-- 认主语用的。若它受 RLS 约束,一个看不见行的调用者会拿到 NULL,而守卫会因此
-- 【静默放行】—— 正是本仓库记过的"守卫对主语缺席这一格是瞎的"那条病。
--
-- 【为什么不给它加 require_permission,而是收回 EXECUTE】它唯一的库内调用者
-- guard_payment_term_applicable 是【属主身份跑的触发器】,而属主(postgres)没有
-- claims —— 加一道门反而会在每一次写付款计划的路上抛权限错。与上面
-- gst_registered / tax_rate_for 同形:**够不着的东西不需要门,需要的是【真的够不着】。**
-- app / lib 里没有任何一处调它(实测);报表里要用它,以 postgres 身份跑。
REVOKE EXECUTE ON FUNCTION public.purchase_order_kind(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.tax_rate_for(text, date) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.sod_manual_posters_in(date, date) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.sod_supplier_creator(uuid) FROM authenticated;

-- COD-1(2026-09-07):销毁证书的三支内层函数。**gate 的 B2 点了它们的名,
-- 而其中一支是真的越权动作** —— void_cod_internal 是 SECURITY DEFINER 且【没有
-- 调用者检查】,留着 authenticated 的 EXECUTE,任何登录用户都能作废任何一张
-- 已签发的销毁证书,完全绕开 action.issue_cod。带门的那一支叫 void_cod;
-- 这一支存在,是因为【冲销加工单的人不持有签发权限】,而冲销必须能作废证书。
--
-- 三支各自的唯一调用者,全部是属主身份跑的 SECURITY DEFINER:
--   * void_cod_internal      ← void_cod、refresh_cod_for_batch
--   * refresh_cod_for_batch  ← commit_processing_run / rollback_processing_run /
--                              soft_delete_inbound_batch(三处挂钩)
--   * cod_delivery_completion ← refresh_cod_for_batch、cod_certificate_data
-- 所以收回之后照常工作,靠的就是【真的够不着】。
--
-- 【为什么不给它们加 require_permission,而是收回 EXECUTE】与上面 gst_registered /
-- purchase_order_kind 同形,但这里的理由更硬一格:refresh_cod_for_batch 是在
-- 【投料的那个人】的会话里被调用的,而运营角色不持有 action.issue_cod ——
-- 加一道门会让"提交加工单"这个动作本身抛权限错。
--
-- ★【界面因此走带门的那一支】★ 面板要显示"为什么还不能签发",而那句话
-- 由 cod_certificate_data 的 CANNOT_CERTIFY|批号|理由 抛出 —— 它有
-- action.issue_cod 的门。判据仍然只有一份实现,而外面只有一扇门。
REVOKE EXECUTE ON FUNCTION public.void_cod_internal(uuid, text, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.refresh_cod_for_batch(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.cod_delivery_completion(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.pricing_terms_of_formula(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.pricing_terms_of_commitment(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.calculate_metal_price_from_terms(jsonb, jsonb, numeric, date) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.commit_pricing_terms(uuid, uuid, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.resolve_pricing_commitment(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.committed_terms_price(uuid, date) FROM authenticated;
-- TASK-1c-a-fu1:【一个事实,一个写入者】那个函数 —— 归属人置为活跃参与者。
-- 它没有调用者检查,只从两扇门的触发器体内被调用(属主身份),所以靠的就是调不到。
-- 门被 gate 的 B2 抓到过一次:留着 authenticated 的 EXECUTE,任何登录用户都能
-- 把【自己】插成【任何一张任务】的活跃参与者 —— 而活跃参与者正是 can_edit_task
-- 团队分支的全部判据。也就是说它等于一把万能写权限。
REVOKE EXECUTE ON FUNCTION public.ensure_task_owner_participant(uuid, uuid, uuid) FROM authenticated;
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
-- IOD-2:库位/物料分类的判词。同 resolve_receipt_location —— 四个落地点共用它,
-- 而那四个分属三个模块(inbound.edit / output.edit / inventory.edit)且各自已把
-- 过关;给它挑一个权限码只能挑一个比三者都松的,那不是把关、是把关的样子。
-- 它没有调用者检查,靠的就是调不到(gate 的 B2 判词认这条出路)。
REVOKE EXECUTE ON FUNCTION public.check_location_class(uuid, uuid) FROM authenticated;
-- NTF-1:两个通知发射器。【它们能凭空写出一条通知】,而 notifications 之所以可信,
-- 靠的正是"只有属主身份的函数写得进"(与 approval_log 同一条:留痕不该有第二个
-- 写法)。给了 authenticated,任何登录用户都能伪造一条"某某库位违规"的事件 ——
-- 而通知是拿来被相信的东西。
-- 【调用它们的是谁】notify_landing_warnings 从四个建批次 RPC 的函数体内被调用
-- (那四个是 DEFINER,以属主身份执行);notify_class_violations 从两个触发器函数
-- 内被调用,而那两个触发器函数【也声明了 SECURITY DEFINER】—— 触发器函数默认以
-- 调用者身份跑,不声明就会在这里撞上"调不到"。
REVOKE EXECUTE ON FUNCTION public.notify_landing_warnings(text[], uuid, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.notify_class_violations(text, uuid[], uuid[]) FROM authenticated;
-- SO-3b:发货单号的取号器。无调用者检查,靠的就是调不到 —— 唯一调用方是
-- ship_order(DEFINER,module.sales.edit,以属主身份执行)。给了 authenticated
-- 就等于任何登录用户都能凭空烧掉一个无缝单号,而无缝的意思正是"号码之间没有洞"。
REVOKE EXECUTE ON FUNCTION public.next_shipment_code(date) FROM authenticated;
-- LOG-2a:集装箱取号器。同 next_shipment_code —— 无调用者检查,靠的就是调不到。
REVOKE EXECUTE ON FUNCTION public.next_container_code(date) FROM authenticated;
-- SO-3b fu5:"这一行已经许出去多少"(已发 + 活预留)。无调用者检查,靠的就是
-- 调不到 —— 消费方是 reserve_stock(DEFINER,module.sales.edit),以及下一刀
-- SO-1b 的改单下限。它读的是订单行的履约情况,而那是 module.sales.view 的东西;
-- 给了 authenticated 就等于任何登录用户都能一行一行问出别人订单的发货进度。
REVOKE EXECUTE ON FUNCTION public.line_spoken_for(uuid) FROM authenticated;
-- SO-1b:"这张单发完了没有"(已发 vs 已订)。同上 —— 没有调用者检查,靠的就是
-- 调不到;两个消费方 ship_order 与 amend_sales_order 都是 DEFINER、都要
-- module.sales.edit,以属主身份执行。给了 authenticated 就等于任何登录用户都能
-- 一张一张问出别人订单的履约进度,而那是 module.sales.view 的东西。
REVOKE EXECUTE ON FUNCTION public.sales_order_fulfilment_status(uuid) FROM authenticated;
-- CN-1:贷项凭证的取号器。同 next_shipment_code —— 无调用者检查,靠的就是调不到;
-- 唯一调用方是 create_credit_note(DEFINER,module.finance.edit,以属主身份执行)。
-- 给了 authenticated 就等于任何登录用户都能凭空烧掉一个无缝单号,而无缝的意思
-- 正是"号码之间没有洞"。
REVOKE EXECUTE ON FUNCTION public.next_credit_note_code(date) FROM authenticated;
-- SO-4a:报价的取号器。同上 —— 无调用者检查,靠的就是调不到。
-- 【而建报价【走直连】,没有 RPC 门可以代取】—— 两者放在一起,客户端就永远
-- 拿不到号。解法不是把它授出去,是让号【根本不由客户端取】:
-- generate_quote_code(BEFORE INSERT,属主身份)在同一条语句里补上,
-- 先例是 customers.generate_customer_code。客户端插的是一行没有号的报价。
REVOKE EXECUTE ON FUNCTION public.next_quote_code(date) FROM authenticated;
-- EQP-1c-a:固定资产的取号器。同 next_shipment_code / next_container_code /
-- next_quote_code —— 没有调用者检查,靠的就是调不到。它有【两个】调用方
-- (record_expense 的新建支与 create_fixed_asset),两个都是 DEFINER 且各自
-- require_permission('module.finance.edit'),以属主身份执行。给了 authenticated
-- 就等于任何登录用户都能凭空烧掉一个 FA 号,而"无缝"的意思正是号码之间没有洞。
REVOKE EXECUTE ON FUNCTION public.next_fixed_asset_code(date) FROM authenticated;

-- GST-2(2026-08-25):税码解析器。与上面 GST-1 那两支【逐字同一条理由】——
-- SECURITY DEFINER、没有调用者检查、绕过 tax_codes 的 RLS 读出整本税码字典。
-- 界面从不调它:屏幕上的税码下拉读的是 tax_codes 这张表本身(走它自己的 RLS,
-- 谓词是 has_permission('module.finance.view'))。库内只有 create_invoice /
-- create_order_invoice / record_expense 调它,三支都是 SECURITY DEFINER、
-- 以属主身份执行,收回之后照常工作。
-- 【为什么不给它加 require_permission】它被属主(postgres)在 definer 内部调用,
-- 而 postgres 没有 claims —— 加了门反而会在开票与记费用的路上抛权限错。
REVOKE EXECUTE ON FUNCTION public.resolve_tax_code(text, text, text, text) FROM authenticated;

-- CHAIN-BUILD-1(2026-08-30):审批链的两支内层判据。
-- 【为什么收回】两支都是 SECURITY DEFINER 且【没有调用者检查】,而 gate 的 B2
-- 正是查这个。它们【不需要】门,需要的是【真的够不着】——
-- real_role_holders 读 auth.users(账号是否确认/封禁/删除)与 user_roles,
-- 给了 authenticated 就等于任何登录用户都能把整个账号目录的登录状态问出来;
-- role_can_see_amounts 读 role_permissions,同理会把权限矩阵问出来。
-- 【唯一的调用方,逐个点名】三支都是 SECURITY DEFINER、以属主身份执行,
-- 而且三支各自已经把过关(readiness 有 require_permission;另两支是闸自己):
--   · real_role_holders   ← guard_approvals_switch / approvals_readiness / require_approver_for
--   · role_can_see_amounts ← guard_approvals_switch / approvals_readiness
-- 收回之后照常工作,靠的就是调不到 —— 与上面 SOD-1 那三支逐字同一条理由。
REVOKE EXECUTE ON FUNCTION public.real_role_holders(text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.role_can_see_amounts(text) FROM authenticated;

-- ★ C-1(2026-09-04):real_role_grants —— 与上面 real_role_holders 【同源同理由】。
-- 它就是那四条判据的行级形状(返回 grant_id + user_id),real_role_holders 如今
-- 是它的投影。所以它读的东西一字不差:auth.users 的确认/封禁/删除 + user_roles。
-- 给了 authenticated 就等于把整个账号目录的登录状态问出来 —— 收回。
-- 【唯一的调用方】guard_last_admin(user_roles 上的 BEFORE UPDATE/DELETE 触发器)。
-- ★ 它正是因此才被改成 SECURITY DEFINER 的:调用者权限的触发器以 authenticated
--   身份跑,收回之后就【调不到】,守卫会在每一次撤销授权时抛权限错。
--   DEFINER 让它以属主身份跑,于是"收回"与"守卫能用"同时成立。
--
-- ⚠【这一行是被实测逼出来的,不是照抄】C-1 起初只把 REVOKE 写在迁移里。
--   apply_migration.sh 在 COMMIT 之后会【重新断言一遍本文件】(那是它的兜底),
--   而本文件当时没有这一行 —— 于是那次 REVOKE 被原样冲掉,
--   实测 has_function_privilege('authenticated', 'real_role_grants', 'EXECUTE') = true,
--   一条【活的 B2 违规】。**收回必须写在这里,写在迁移里不算数。**
REVOKE EXECUTE ON FUNCTION public.real_role_grants(text) FROM authenticated;

-- PROC-COST-2(2026-08-31):【计值读取器】与【单位落地成本】三支内层函数。
-- 三支都是 SECURITY DEFINER 且【没有调用者检查】,而 gate 的 B2 正是查这个。
-- 它们【不该】有门,需要的是【真的够不着】—— 理由与上面那一族逐字同源,
-- 但这里的"为什么不加门"有它自己的一条,值得写清楚:
--
-- 【为什么这两支【必须】没有判据】batch_freight_base / batch_processing_cost_base
-- 是【屏幕读取器】,无权返回 NULL(受限)——「受限」与 0.00 不是同一件事。
-- 而注销与盘点要过账的那个金额【不许取决于谁按的按钮】:一个只有
-- module.inbound.edit 的仓管按下注销时,若计值读的是带判据的那一支,
-- COALESCE(NULL, 0) 会让它安静地退回按 unit_price 计值 —— 也就是 PROC-COST-2
-- 正在修的那个缺陷原样复发,而且再没有人看得见。所以算术与受众拆成两层:
-- 算术在 _all 这一对里(只有一份定义),受众在带判据的那一对里。
--
-- 【唯一的调用方,逐个点名】三支都只从属主身份执行的地方被调用:
--   · batch_freight_base_all          ← batch_freight_base(definer,带判据)
--                                       inbound_batch_landed_unit_cost(definer)
--   · batch_processing_cost_base_all  ← batch_processing_cost_base(definer,带判据)
--                                       inbound_batch_landed_unit_cost(definer)
--   · inbound_batch_landed_unit_cost_all ← emit_batch_writeoff_movement(触发器,definer)
--                                       post_stocktake(definer)
--                                       inventory_control_reconciliation(definer)
--                                       inventory_valuation_snapshot(definer)
--     【CLEANUP-A fu1】它是【过账】原语,刻意没有判据 —— 账上的金额不许取决于
--     按按钮的人有什么读权限。所以它必须靠"调不到"活着,与上面那一对同一条规矩。
--   · inbound_batch_landed_unit_cost  ← inbound_batch_valuation_rows(definer)
--     【它自己带判据(CLEANUP-A / R3)】,收权是第二层,不是唯一那层。
--                                       post_stocktake(definer,module.stocktakes.edit)
-- 给了 authenticated 就等于把【绕过 RLS 的运费与加工成本读取】敞开给任何登录
-- 用户 —— 那正是带判据的那一对存在的全部理由,而这三支会把它一句话作废。
-- 收回之后照常工作,靠的就是调不到。
REVOKE EXECUTE ON FUNCTION public.batch_freight_base_all(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.batch_processing_cost_base_all(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.inbound_batch_landed_unit_cost(uuid) FROM authenticated;
-- CLEANUP-A fu1:过账原语,无判据,必须靠"调不到"活着。
REVOKE EXECUTE ON FUNCTION public.inbound_batch_landed_unit_cost_all(uuid) FROM authenticated;

-- ════════════════════════════════════════════════════════════════════════════
-- ★★★ COD-2(2026-09-08):本仓库【第一条】给 anon 的 EXECUTE ★★★
-- ════════════════════════════════════════════════════════════════════════════
-- 本文件抬头写着:「anon 在 public 架构里不该有任何 EXECUTE……真有哪个函数
-- 将来必须给 anon,就在下面显式加一行【并写明理由】。」这就是那一行,
-- 而下面是那个理由。
--
-- 【它是什么】cod_verification(text) —— 销毁证书核验页的取数。供应商扫证书上
-- 的二维码打开 /verify/cod/<令牌>,那一页就是这支函数的输出。**这是本系统
-- 第一个不用登录就打得开的页面**,而这支函数是它够得着的【唯一】一样东西。
--
-- 【为什么必须给 anon,不能靠"页面在服务端用 service_role 读"】
--   两种都成立,而选这一种的理由是【判据落在哪里】:给 anon 授权,把关的是
--   数据库 —— 这支函数收一个令牌、回一份白名单子集,任何调用者都只拿得到那些。
--   走 service_role 的话,把关的是"那一页恰好是服务端渲染的、而且它恰好只
--   显示了该显示的" —— 一次页面重写就可能悄悄改掉它,而没有任何东西会说话。
--   ★ 一条能在数据库这边说清的判据,不该寄存在一个页面的写法里。★
--
-- 【它没有调用者检查,而这是【正确的】】它的"权限"就是【持有那个令牌】:
--   122 位随机、与证书号毫无关系、改一位数字得到的是一个不存在的值。
--   一个匿名的核验入口若还要问 has_permission,它就永远回答不了任何人。
--   check_mirrors 的 DEFINER_NO_CHECK_ALLOWED 里有它,理由逐字同此。
--
-- 【它的限流住在函数体里,不在路由上】anon key 随浏览器包发出去,所以
--   POST /rest/v1/rpc/cod_verification 是第二条门,不经过 Vercel ——
--   一个住在路由上的限流器会被它要拦的那个工具整个绕过去。
--
-- ⚠★【这一行【必须】在这里,而不是只在迁移里】★⚠ 与 C-1 的 real_role_grants
--   那一段【方向相反、道理相同】:db/apply_migration.sh 把本文件拼在 COMMIT
--   之前、同一个事务里重跑一遍,而本文件的第一句是
--       REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC, anon;
--   一条只写在迁移里的 GRANT 会在提交之前被它冲掉,**而迁移报告成功**。
--   所以真源在这里,写在那句 REVOKE 的【后面】。
GRANT EXECUTE ON FUNCTION public.cod_verification(text) TO anon;

-- COD-2:执照判据(在完成日当天在效的那一张 GWDF)。与 cod_delivery_completion
-- 逐字同一条理由 —— SECURITY DEFINER、没有调用者检查,靠的就是【调不到】。
-- 它绕过 company_compliance 的 RLS(那张表的谓词借的是 module.suppliers.view,
-- 而仓储现场读不到它,却仍然被这道闸管着 —— 那正是它必须 DEFINER 的原因)。
-- 给了 authenticated 就等于任何登录用户都能把公司的执照号、发证机关与有效期
-- 问出来。唯一的两个调用方 issue_cod 与 cod_certificate_data 都是 DEFINER、
-- 各自 require action.issue_cod,以属主身份执行,收回之后照常工作。
REVOKE EXECUTE ON FUNCTION public.cod_governing_licence(date) FROM authenticated;
