-- db/functions/forbid_self_approval.sql
-- APR-2:【四眼原则的唯一一份定义】—— 谁不许批这一份单据。
--
-- 【为什么是一支函数,而不是五处 IF】Tim 的裁定(APR-0 Q6)是"自批统一拒,
-- 在每一条【今天存在】的链和每一条【将来加进来】的链上"。一条写成五遍的规矩,
-- 第六条链一定会漏掉它 —— 而漏掉的形状是【什么都不发生】,没有任何东西变红。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★【"自己"是两个人,不是一个】★★(Tim 的 Q8 裁定,2026-09-22)
-- ════════════════════════════════════════════════════════════════════════════
--   ① 提单的人(raiser)—— created_by / submitted_by。老的那条规矩只管这一个。
--   ② 单据【说的是谁】(subject)—— 请假是请假的那位员工,报销是报销的那位,
--      绩效是被评的那位。★ 这一条此前【全库都没有】,而它是真的会咬人的那一条:
--      `approve_review` 只拒 submitted_by,于是【别人提交、主角自己批准】这条路
--      一直是通的 —— 而 approve_review 会写 employees.monthly_salary 与一行
--      employment_history 调薪记录。**一个人可以批准自己的加薪。**
--      线上三个持 module.hr.edit 的人【全部】是在册员工,所以它不是理论上的。
--
-- 【两条判据的先后是确定的,而且要说出来】raiser 先判。两条同时成立时,
-- 屏幕上出现的是 |raiser —— 因为那是更早、更窄、也更好懂的那一句
-- ("你自己提的单")。不留给实现去碰运气。
--
-- 【NULL 一律不匹配,这是刻意的】p_raiser_user 为空(老数据没有 created_by)、
-- 或者调用者根本不是在册员工(current_user_employee() 为 NULL)时,
-- 这一条【放行】。理由:一个 NULL 不是一个"人",拿两个 NULL 相等去拒绝
-- 会把"我不知道"变成"就是你" —— 那正是本仓库反复付账的那个形状。
-- ★ 代价照直说:created_by 为空的历史单据,raiser 那一条对它们【不生效】。
--
-- 【为什么它 RAISE,而不是返回 boolean】AGENTS.md:一支 void 函数的"沉默"
-- 与"成功"是同一个字节,所以它的 NULL 永远有主 —— 返回值会被 COALESCE 掉,
-- 而一次被 COALESCE 掉的拒绝就是一次放行。
--
-- 【为什么它【不是】SECURITY DEFINER】它自己不读任何受 RLS 约束的东西:
-- auth.uid() 是一个 GUC,current_user_employee() 自己就是 DEFINER。
-- 不声明 DEFINER,gate 的 B2(DEFINER 且无调用者检查)就与它无关 ——
-- 少一个需要在 zzz_function_grants 里解释的对象。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★ APR-ROUTE-1(2026-09-23):一个例外,以及"自己"从此按【人】认 ★★
-- ════════════════════════════════════════════════════════════════════════════
--   ① 【唯一的例外】(Tim 的 R2 · Q3):二级审批角色的持有人可以决定【他自己的】
--      报销单与医疗申报 —— 判据住在 self_approval_exception,不住在这里。
--      那一次决定照常落留痕,并被 record_approval_decision 标成 self_decided。
--      ☞ 所以本函数多了第三个参数 p_subject_type,而它【没有默认值】:
--        下一条接进来的链必须说出自己是什么类型,才调得动这支函数 ——
--        一个默认值会让它在不知不觉中落进(或落出)例外。
--   ② 【"自己"的判据搬去了 self_leg】(R3):同一个人的另一个账号也是"自己"。
--      两条腿的先后、NULL 不匹配,与上面写的一字不差。
--   ③ 【两条腿什么时候一起被豁免】例外要求"主角就是我",所以
--      "raiser 腿成立 且 例外成立"只可能是"我提的、说的也是我"。
--      一张我替别人提的单,例外不成立,|raiser 照拒。
--   ★ 它【仍然不是】SECURITY DEFINER —— 它读的三样东西(self_leg、
--     self_approval_exception、finance_settings)在调用它的 DEFINER 决定函数里
--     以属主身份执行;fixture 203 的 P 臂钉着这一条。
--
-- NOTE: introduced by db/migrations/2026-09-22-apr2-self-approval-and-the-approver-that-nobody-is.sql.

CREATE OR REPLACE FUNCTION public.forbid_self_approval(p_raiser_user uuid, p_subject_employee uuid, p_subject_type text)
 RETURNS void
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_leg text;
    v_l2  text;
BEGIN
    -- 两条腿:raiser 先判,"同一个人"按人认(self_leg)。
    v_leg := self_leg(p_raiser_user, p_subject_employee, auth.uid());
    IF v_leg = 'none' THEN
        RETURN;
    END IF;

    -- ★ APR-ROUTE-1(R2):唯一的例外。它要求"主角就是我",所以一张我替别人提的单
    --   不会从这里漏过去 —— 那一张的 raiser 腿照拒。
    SELECT approval_level2_role_code INTO v_l2 FROM finance_settings LIMIT 1;
    IF self_approval_exception(p_subject_type, p_subject_employee, auth.uid(), v_l2) THEN
        RETURN;
    END IF;

    RAISE EXCEPTION 'SELF_APPROVAL_FORBIDDEN|%', v_leg;
END;
$function$;
