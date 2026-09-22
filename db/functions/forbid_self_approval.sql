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
-- NOTE: introduced by db/migrations/2026-09-22-apr2-self-approval-and-the-approver-that-nobody-is.sql.

CREATE OR REPLACE FUNCTION public.forbid_self_approval(p_raiser_user uuid, p_subject_employee uuid)
 RETURNS void
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- ① 提单的人。与 approve_purchase_order 的那一句同源(它保留裸码,见 APR-2 §3)。
    IF p_raiser_user IS NOT NULL AND p_raiser_user = auth.uid() THEN
        RAISE EXCEPTION 'SELF_APPROVAL_FORBIDDEN|raiser';
    END IF;

    -- ② 单据说的是谁。★ 这一条是 APR-2 新加的,而它此前全库都没有。
    IF p_subject_employee IS NOT NULL
       AND p_subject_employee = current_user_employee() THEN
        RAISE EXCEPTION 'SELF_APPROVAL_FORBIDDEN|subject';
    END IF;
END;
$function$;
