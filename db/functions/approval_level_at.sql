-- db/functions/approval_level_at.sql
-- APR-3(2026-09-22):★【「达到或超过」这个比较号的【唯一】一份定义】★
--
-- 【它为什么被从 approval_level_for 里搬出来,而这不是整理】
-- APR-3 给 guard_approvals_switch 装了 APPROVALS_POLICY_WOULD_STRAND:一次策略
-- 编辑要【拿新的门槛】把每一张在途单据重新分一次档,再问那一档有没有人批得动。
-- 而 guard_approvals_switch 是 BEFORE UPDATE —— 它从 finance_settings 读到的是
-- OLD 那一行。approval_level_for() 自己去读表,所以在那道闸里它答的是【上一版
-- 策略】,并且全绿。这正是 approval_gate_intersections 抬头记着的同一个陷阱,
-- 而那里的处置是【把 NEW 的值当参数传进去】—— 这里照做。
--
-- ★【于是仓库里仍然只有一句 >=】approval_level_for(numeric) 的签名与它的两句
--   按名拒绝(THRESHOLD_NOT_SET / AMOUNT_REQUIRED)一个字都没有变,它只是把
--   那一次比较交给本函数。把比较号抄第二遍才是这一刀会付账的做法:两处 >= 的
--   系统,迟早有一处被改成 >,而它只在【恰好等于门槛】那一个数上现形。
--
-- 【db/fixtures/151 注入④ 的目标跟着搬到这里】那一臂把 >= 换成 > ,断言恰好
--   等于门槛的那一笔当场降级。判据搬了家,注入的目标就得跟着搬 —— 否则它会
--   什么也替换不掉,而 fixture 151 自己抬头里的 C-1 那一段记的正是这件事
--   (real_role_holders → real_role_grants 那一次,旧目标注入什么也没删)。
--
-- 【为什么不是 SECURITY DEFINER】它一个东西都不读:两个入参,一次比较。
--
-- NOTE: introduced by db/migrations/2026-09-22-apr3-the-claim-the-count-and-the-edit-that-strands.sql.

CREATE OR REPLACE FUNCTION public.approval_level_at(p_amount_base numeric, p_threshold numeric)
 RETURNS smallint
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    -- 「1000 及以上归二级」—— Doc 1 的原话是 "and above",所以是 >= 。
    -- ★ 仓库里这个比较【只在这里出现一次】。
    SELECT CASE WHEN p_amount_base >= p_threshold THEN 2 ELSE 1 END::smallint;
$function$;

COMMENT ON FUNCTION public.approval_level_at(numeric, numeric) IS
'APR-3:分档那个比较号(>=)的【唯一】定义 —— 给定金额与给定门槛,归哪一级。★ 它被从 approval_level_for 里搬出来,是因为 guard_approvals_switch 是 BEFORE UPDATE:自己去读 finance_settings 读到的是 OLD 那一行,于是 APPROVALS_POLICY_WOULD_STRAND 会拿【上一版门槛】去重新分档并且全绿(与 approval_gate_intersections 抬头记的是同一个陷阱)。approval_level_for(numeric) 的签名与两句按名拒绝一字未改,它只是把比较交给这里 —— 于是仓库里仍然只有一句 >=。db/fixtures/151 注入④ 的目标跟着搬到本函数。';
