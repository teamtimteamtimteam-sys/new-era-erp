-- db/functions/guard_approvals_policy_write.sql
-- APR-1:审批策略那四列的写闸 —— 【不经 set_approvals_policy 的改动一律按名拒绝】。
--
-- 【它补的洞】finance_settings 的表级写闸是 enforce_write_permission('module.finance.edit'),
-- 而持有那个码的是 admin · finance · gm —— ★ finance 正是被裁定的一级审批角色。
-- 也就是说:约束她的那条策略,写闸这一侧对她是开着的
-- (docs/known-issues.md APR0-APPROVALS-SWITCH-WRITE-GATE)。
--
-- ★★【它靠什么认出"这是 RPC 写的"—— 两道测试,而载重的是第一道】★★
--
-- ① row_security_active(TG_RELID) —— **真正的边界**。
--    它不是一个值,是一件关于【调用者是谁】的事实。APR-1 实测(2026-09-22,
--    一次回滚掉的探针):as postgres → f;as authenticated → t;
--    而 `SET LOCAL row_security = off` 在 authenticated 下【被接受却不起作用】——
--    row_security_active 仍然是 t,任何一次读当场报
--    "query would be affected by row-level security policy"。
--    ☞ 举不起来:要豁免只能【是】属主或跑在属主的 DEFINER 函数体内,那是一次授权。
--
-- ② 事务局部的旗子 —— **属主边界之内的精确度,不是边界本身**。
--    同一次探针量到:`SET LOCAL ROLE authenticated` 之后
--    `set_config('evoltrya.apr1_forge_probe','1',true)` **成功、读得回、不报错**。
--    ★ 一个自定义命名空间的 GUC 不是一项权限,是一个谁都写得进的值。
--    所以它只能用来要求"任何直写这四列的路必须在源码里说出这句话",
--    不能用来挡人。db/fixtures/35 · 75 · 127 · 151 各自显式举旗,共 22 处。
--
-- ★【用完即焚】set_config(..., true) 的 true 是 is_local = **事务局部**,不是语句局部
--   (PUR2-FU2,2026-08-11 被自己的探针抓到)。举一次旗本来会把这道闸放倒到事务结束;
--   守卫在它放行的那一行上自己把旗放倒,于是一次举旗只授权一行。
--   finance_settings 是单行表 ⇒ 一条语句就是一行,所以这是精确的,不是近似的。
--
-- ★【为什么是 INVOKER,不是 DEFINER】row_security_active 必须反映【调用者】的视角。
--   enforce_write_permission 的抬头逐字写着同一句话。一支 DEFINER 的守卫问的是
--   它自己,于是它会放行一切。
--
-- ★★【它【不】拦 postgres,照直说 —— 没有任何东西拦得住】★★ 属主可以 DROP 掉这个
--   触发器。它建起来的边界是:**任何受 RLS 约束的调用者都改不动这四列,包括
--   持 module.finance.edit 的一级审批人本人。**
--
-- 【列作用域:比【值】,不比【提没提到】】UPDATE OF col 在列被写进 SET 子句时就开火,
-- 哪怕值没变。setPeriodLock 与 GST 开关送的是各自的补丁,close_period / reopen_period
-- 只写 locked_before —— 比值,这道闸才真的只管这四列。
--
-- NOTE: introduced by db/migrations/2026-09-22-apr1-the-approvals-switch-gets-a-door.sql.

CREATE OR REPLACE FUNCTION public.guard_approvals_policy_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_changed text[] := '{}';
BEGIN
    -- 【列作用域:比【值】,不比【提没提到】】`UPDATE OF col` 在列被【写进
    -- SET 子句】时就开火,哪怕值没变;而 setPeriodLock 与 GST 开关送的是整份
    -- 补丁。比值,这道闸才真的只管这四列。
    IF NEW.approvals_enabled IS DISTINCT FROM OLD.approvals_enabled THEN
        v_changed := v_changed || 'approvals_enabled'::text;
    END IF;
    IF NEW.approval_level1_role_code IS DISTINCT FROM OLD.approval_level1_role_code THEN
        v_changed := v_changed || 'approval_level1_role_code'::text;
    END IF;
    IF NEW.approval_level2_role_code IS DISTINCT FROM OLD.approval_level2_role_code THEN
        v_changed := v_changed || 'approval_level2_role_code'::text;
    END IF;
    IF NEW.approval_threshold_base IS DISTINCT FROM OLD.approval_threshold_base THEN
        v_changed := v_changed || 'approval_threshold_base'::text;
    END IF;

    -- 四列一个都没变 → 这不是一次策略改动,放行(setPeriodLock 走这一支)。
    IF cardinality(v_changed) = 0 THEN
        RETURN NEW;
    END IF;

    -- ★★ 真正的边界:受 RLS 约束的调用者一律拒。举不起来的那一道。★★
    IF row_security_active(TG_RELID) THEN
        RAISE EXCEPTION 'APPROVALS_POLICY_DIRECT_WRITE|%', array_to_string(v_changed, ', ');
    END IF;

    -- ★ 属主边界【之内】的精确度:必须是【显式举过旗】的那条路。
    --   它拦不住一个铁了心的属主(属主可以 DROP 这个触发器),它要的是:
    --   任何一条直接写这四列的路,都必须在源码里说出这句话。
    IF NULLIF(current_setting('evoltrya.approvals_policy_ctx', true), '') IS NULL THEN
        RAISE EXCEPTION 'APPROVALS_POLICY_DIRECT_WRITE|%', array_to_string(v_changed, ', ');
    END IF;

    -- ★★ 用完即焚 —— PUR2-FU2 那一课的修法。set_config(..., true) 是【事务局部】,
    --    举一次旗本来会把这道闸放倒到事务结束;在这里放倒它,一次举旗就只
    --    授权【这一行】。单行表 ⇒ 一条语句就是一行,所以这是精确的。
    PERFORM set_config('evoltrya.approvals_policy_ctx', '', true);
    RETURN NEW;
END;
$function$;
