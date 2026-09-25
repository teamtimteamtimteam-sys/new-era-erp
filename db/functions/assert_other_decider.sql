-- db/functions/assert_other_decider.sql
-- ROLE-1 Batch 3a(Tim 2026-09-25,Batch 3 grilling Q12):**提单人之外没人批得动,提交就拒**。
--
-- 【Step 0 量出来的】admin@ 与 tim@ 是同一个人(account_person 两个都是 4737faa9…),二级今天只有
-- tim@ 一个真持有人,而 admin 角色持每一个码(Tim 的常设裁定)—— 于是 admin@ 能提一张工资申请
-- (module.hr.edit)或一张付款 / 转账 / 预扣税申请(module.finance.edit),提单人那条腿按人认,
-- tim@ 批不了,又没有第二个人:它挂在那里,还经 blocks_disable 挡住关审批。收货定价申请在 4b 里
-- 按名拒了同一个形状(RECEIPT_PRICE_NO_OTHER_DECIDER);本函数把那几行抽成一份,给工资申请与六支
-- 付款申请的提交共用。
--
-- 【判据】审批开着时,approval_deciders(本链、本级、提单人 = auth.uid()、无主角)一个人都没有 →
-- RAISE p_refusal(调用方给出按名拒的那一句)。审批关着时不拒:申请生下来就是 approved。
-- 【为什么 RAISE 而不是返回布尔】它是一句断言,不是一个读者 —— 没有返回值的函数,
-- "不拒"与"成功"是同一个字节(void-assertion 那一条)。
-- 【EXECUTE 从 authenticated 收回】调用它的都是 SECURITY DEFINER 的提交函数;approval_deciders
-- 本身也收回了。
--
-- NOTE: introduced by db/migrations/2026-09-25-role1b3a-the-counter-never-posts.sql.

CREATE OR REPLACE FUNCTION public.assert_other_decider(p_subject_type text, p_action_function text, p_level smallint, p_refusal text)
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_l1 text;
    v_l2 text;
BEGIN
    IF NOT approvals_enabled() THEN
        RETURN;
    END IF;
    SELECT approval_level1_role_code, approval_level2_role_code
      INTO v_l1, v_l2 FROM finance_settings LIMIT 1;
    IF NOT EXISTS (SELECT 1 FROM approval_deciders(p_subject_type, p_action_function, p_level,
                                                   auth.uid(), NULL, v_l1, v_l2)) THEN
        RAISE EXCEPTION '%', p_refusal;
    END IF;
END;
$function$;

COMMENT ON FUNCTION public.assert_other_decider(text, text, smallint, text) IS
'ROLE-1 Batch 3a:审批开着、approval_deciders(本链、本级、提单人 = auth.uid())一个人都没有时,RAISE 调用方给的那一句(工资申请 PAYROLL_NO_OTHER_DECIDER|工资期;付款申请一族 PAYMENT_REQUEST_NO_OTHER_DECIDER)。审批关着时不拒。EXECUTE 已从 authenticated 收回。';
