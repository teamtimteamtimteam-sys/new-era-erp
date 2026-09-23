-- db/functions/release_work_order.sql
-- 放行一张工单。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★★ APR-2(2026-09-22):这里【曾经】有一句按级别授权的检查,而它是一把锁 ★★★
-- ════════════════════════════════════════════════════════════════════════════
-- WO-1b 的推理只错了一步,而那一步没有任何东西在看:它选了"层级 1",
-- 却没有问【第一级那个角色的人,持不持有 module.processing.edit】。
-- 实测(2026-09-22,以 postgres 读 user_roles / role_permissions / auth.users 基表,
-- 外加 require_approver_for 自己逐人给出的答案):
--     一级 = finance,唯一真持有人 chooer@evoltrya.test
--     module.processing.edit 的持有人 = admin · phua · sandra · vince
--     ★ 交集 = 空
-- 于是 Tim 在 2026-09-22 12:25:06 打开审批的那一刻起,
-- **线上没有任何人放行得了一张工单** —— 而屏幕上出现的是
-- 「APPROVAL_NOT_AUTHORISED|1|finance」,一句听起来像"你级别不够"、
-- 实际上对每一个人都成立的话。当时 work_orders 的 draft = 0,所以没有单据卡住;
-- 下一张就再也放行不了。**WO-1b 写下那一行时,三道闸全绿。**
--
-- ★ Tim 的裁定(Q1,2026-09-22)——【修订】了他自己早前那条"没有金额的单据
--   一律走一级":**按角色分级只管【带钱的单据】。** 不带钱的单据,谁能批仍由
--   它自己的模块权限说了算。工单没有金额,所以它回到 module.processing.edit。
-- ☞ 代价照直说:**工单少了一道名义上的一级闸,而那道闸【谁都过不去】。**
--   换来的是这条链重新走得通。真要给工单一个独立的审批人,那是一次建模改动
--   (给它自己的审批角色),不是把那一句放回来。登记在 docs/forward-queue.md。
-- ★ 而【下一次不会再靠人看出来】:approval_gate_intersections() 逐条断言
--   "这条链真的有人批得动",guard_approvals_switch 在【开】的那一刻按名拒。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ⚠★【为什么这一整段写在函数体【外面】】★⚠
-- ════════════════════════════════════════════════════════════════════════════
-- db/fixtures/203 的 P 臂与本刀迁移的自证 ⑥ 都断言
--     pg_proc.prosrc NOT LIKE '%require_approver_for%'
-- —— 而 **prosrc 里是带注释的**。第一版把这段解释写在 BEGIN 之后,
-- 于是那条断言被【这段解释自己】点亮,fixture 当场红。
-- ☞ 这就是 AGENTS.md「一句注释可以污染将来对它自己的计数」那一条,
--   而本刀在同一天里撞了它两次(另一次在 app/finance/financeErrorCodes.ts:
--   注释里一个带引号的码被 check-i18n 的 tsSet 当成了真的码)。
-- **要解释一件"这里【没有】什么"的事,就不要在它旁边写出那个名字。**
--
-- NOTE: introduced by db/migrations/2026-08-16-wo1b-*.sql;
-- 按级别授权那一句由 db/migrations/2026-09-22-apr2-self-approval-and-the-approver-that-nobody-is.sql 摘除。

CREATE OR REPLACE FUNCTION public.release_work_order(p_work_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user    uuid := auth.uid();
    v_wo      work_orders%ROWTYPE;
    v_appr_on boolean := approvals_enabled();
BEGIN
    PERFORM require_permission('module.processing.edit');
    SELECT * INTO v_wo FROM work_orders WHERE id = p_work_order_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'WO_NOT_FOUND|%', COALESCE(p_work_order_id::text, '?');
    END IF;
    IF v_wo.status <> 'draft' THEN
        RAISE EXCEPTION 'WO_NOT_DRAFT|%|%', v_wo.code, v_wo.status;
    END IF;

    -- ★ APR-2:四眼。判据只有一份定义(forbid_self_approval)。
    -- 【只有一条腿】—— 工单没有"这张单说的是谁"(它说的是一批料,不是一个人),
    -- 所以第二个参数是 NULL,而 NULL 一律不匹配。不硬塞一个主语进去。
    PERFORM forbid_self_approval(v_wo.created_by, NULL::uuid, 'work_order');

    -- 【放行是那个要有人负责的动作】(WO-1b)Doc 2 点名要"who approved the work
    -- order"。可审批的是放行 —— 不是新建(草稿谁都可以写),也不是收工(事后记录)。
    --
    -- ★ APR-2:谁能放行,由 module.processing.edit 说了算 —— 本函数【不】按角色
    --   分级。工单没有金额,而按角色分级只管带钱的单据(Tim 的 Q1 裁定)。
    --   ☞ 这里原先有一句按级别授权的检查,而它在线上是一把【谁都过不去】的锁。
    --     整段来龙去脉写在本文件的抬头 —— **刻意写在函数体外面**,
    --     见抬头最后一段说明为什么。

    UPDATE work_orders
       SET status = 'released', updated_at = now(), updated_by = v_user
     WHERE id = p_work_order_id;
    INSERT INTO work_order_history (work_order_id, change_type, changed_by)
    VALUES (p_work_order_id, 'released', v_user);

    -- 【留痕要说实话】—— 而 APR-3(Tim 的 Q7)把"实话"这一句本身改了。
    -- ★ 两条分支现在写的是【同一个决定值】:放行是一个人按下去的动作,
    --   审批开着还是关着都是;开关只改变"有没有一道按级别的授权",
    --   不改变"有没有人做过这个决定"。
    -- ★ 层级恒 NULL,不写 1。此前写的是 1,而那是一句【假记录】——
    --   这条路上【没有跑过任何一级授权检查】(上面那一段说明了为什么),
    --   于是 level = 1 会让留痕声称发生过一件没有发生的事。
    --   与 HR 三条链同形:它们也一律 NULL(approval_log 的 level 列注释)。
    PERFORM record_approval_decision('work_order', p_work_order_id, 'approved', NULL::smallint,
        CASE WHEN v_appr_on THEN NULL
             ELSE '审批流未启用(finance_settings.approvals_enabled = false)—— 没有按级别的授权步骤,而放行是这个人按下去的' END);

    RETURN jsonb_build_object('work_order_id', p_work_order_id, 'code', v_wo.code,
                              'status', 'released', 'approvals_enabled', v_appr_on);
END;
$function$

;
