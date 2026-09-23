-- db/functions/self_leg.sql
-- APR-ROUTE-1:【账号 p_user 是不是这份单据的"自己"—— 如果是,是哪一条腿】
--
-- 返回 'raiser' | 'subject' | 'none'。★ 永远不返回 NULL ★:本函数的三个
-- 读者(forbid_self_approval · approval_deciders · record_approval_decision)
-- 各自拿它做一个判断,而一个 NULL 在 `<> 'none'` 里会被读成"不是自己"——
-- 那正是 AGENTS.md「一次被 COALESCE 掉的拒绝就是一次放行」的形状。
--
-- 【为什么从 forbid_self_approval 里搬出来】APR-2 的那两条腿原来只在拒绝时
-- 被问一次。R2 与 R4 之后同一个问题有三个问法:
--   ① 拒不拒(forbid_self_approval,问的是【当前调用者】);
--   ② 批了之后,这是不是一次自批(record_approval_decision 的 self_decided);
--   ③ 假设是【某一个】持有人,他算不算"别人"(approval_deciders,R4)。
-- 三处各写一遍,就是三份会漂开的"谁是自己"。所以它只在这里。
--
-- 【两条腿的先后与 APR-2 一字不差】raiser 先判;两条同时成立时报 raiser。
-- 【"同一个人"按人认,不按账号认】(R3)—— 两个账号相同,或者两个账号
--   属于同一名员工(account_person 相等且不为 NULL)。
-- 【NULL 一律不匹配】p_user 为空(没有会话)、p_raiser 为空(老数据)、
--   账号不属于任何员工 —— 都不会凭两个 NULL 相等被判成"是你"。
--
-- 【为什么 SECURITY DEFINER 并被收权】它经 account_person 读 employees。
--
-- NOTE: introduced by db/migrations/2026-09-23-aproute1a-higher-decides-lower-and-the-flagged-self.sql.

CREATE OR REPLACE FUNCTION public.self_leg(p_raiser uuid, p_subject_employee uuid, p_user uuid)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_person uuid;
BEGIN
    IF p_user IS NULL THEN
        RETURN 'none';
    END IF;
    v_person := account_person(p_user);

    -- ① 提单的人:同一个账号,或者同一个人的另一个账号
    IF p_raiser IS NOT NULL
       AND (p_raiser = p_user
            OR (v_person IS NOT NULL AND account_person(p_raiser) = v_person)) THEN
        RETURN 'raiser';
    END IF;

    -- ② 单据说的是谁
    IF p_subject_employee IS NOT NULL AND v_person IS NOT NULL
       AND p_subject_employee = v_person THEN
        RETURN 'subject';
    END IF;

    RETURN 'none';
END;
$function$;

COMMENT ON FUNCTION public.self_leg(uuid, uuid, uuid) IS
'APR-ROUTE-1:账号 p_user 相对于一份单据(提单人 p_raiser、主角 p_subject_employee)是不是"自己",是的话是哪条腿 —— raiser | subject | none,永不返回 NULL。raiser 先判(与 APR-2 同序);"同一个人"经 account_person 按人认(R3)。三个读者:forbid_self_approval(拒不拒)· record_approval_decision(self_decided)· approval_deciders(R4 的"别人")。EXECUTE 已从 authenticated 收回。';
