-- db/functions/set_approvals_policy.sql
-- APR-1:审批策略那四列的【唯一】写入口。
--
-- 【判据为什么是 action.manage_permissions,不是 module.finance.edit】
-- 后者被 admin · finance · gm 持有,而 finance 是被裁定的一级审批角色 ——
-- 一个人不该改得动那条约束她自己的策略(APR0-APPROVALS-SWITCH-WRITE-GATE)。
-- 它与 /settings/approvals 那一页的闸【逐字同一个码】,于是"看得见这一页"
-- 与"改得动这条策略"不可能各错一次。
--
-- 【为什么四列一起写】guard_approvals_switch 是把它们【放在一起】判的:
-- 开之前策略必须齐、两级必须有真持有人且看得见金额。一次只写一列,会让操作员
-- 走进一个数据库已经保证【到不了】的中间状态。
--
-- ★【它不绕过那道闸,而且是【靠什么】不绕过的】它发出的是一条普通的 UPDATE,
--   所以 trg_approvals_switch 照常开火;**本函数里没有 EXCEPTION 块** ——
--   那九条具名拒绝原样穿过它到达界面。接住它们再翻译一遍,就是"谁可以开这个
--   开关"的第二份实现,而那是本仓库反复付账的形状。
--
-- ★【它也不绕过写闸,它是【被写闸认得的那条路】】UPDATE 之前举旗,
--   guard_approvals_policy_write 在放行的那一行上把旗放倒(用完即焚)。
--
-- 【什么都没改 → 不写库、不落史】一份记满了"没发生的事"的历史,会把真正
-- 发生过的那几次埋掉。
--
-- NOTE: introduced by db/migrations/2026-09-22-apr1-the-approvals-switch-gets-a-door.sql.

CREATE OR REPLACE FUNCTION public.set_approvals_policy(p_enabled boolean, p_level1_role_code text, p_level2_role_code text, p_threshold_base numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_old   finance_settings%ROWTYPE;
    v_actor uuid := auth.uid();
BEGIN
    -- ★ 这一刀的全部理由:写这条策略的判据是【能不能管权限】,
    --   不是【能不能编辑财务设置】。后者 finance 自己就持有,而 finance
    --   正是被裁定的一级审批角色。
    PERFORM require_permission('action.manage_permissions');

    SELECT * INTO v_old FROM finance_settings WHERE id LIMIT 1;
    IF NOT FOUND THEN
        -- 单行表的那一行不见了。响亮地说,而不是 INSERT 一行把它变成默认值 ——
        -- 后者会把"策略丢了"悄悄换成"策略是空的"。
        RAISE EXCEPTION 'APPROVALS_SETTINGS_MISSING';
    END IF;

    -- 【什么都没改 = 不写库,也不落一行史】一份记满了"没发生的事"的历史,
    --   会把真正发生过的那几次埋掉。
    IF  v_old.approvals_enabled         IS NOT DISTINCT FROM p_enabled
    AND v_old.approval_level1_role_code IS NOT DISTINCT FROM p_level1_role_code
    AND v_old.approval_level2_role_code IS NOT DISTINCT FROM p_level2_role_code
    AND v_old.approval_threshold_base   IS NOT DISTINCT FROM p_threshold_base THEN
        RETURN jsonb_build_object('changed', false);
    END IF;

    -- 举旗 —— 守卫会在它放行的那一行上把它放倒(用完即焚,见守卫函数体)。
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);

    -- ★【没有 EXCEPTION 块,这是刻意的】guard_approvals_switch 的九条具名拒绝
    --   必须原样穿过这里到达屏幕。接住它们再翻译一遍,就是"谁可以开这个开关"
    --   的第二份实现。
    UPDATE finance_settings
       SET approvals_enabled         = p_enabled,
           approval_level1_role_code = p_level1_role_code,
           approval_level2_role_code = p_level2_role_code,
           approval_threshold_base   = p_threshold_base,
           updated_by                = v_actor
     WHERE id;

    -- 守卫已经放倒了它;这一句是为了"这条路上没有任何一面旗留在事务里"
    -- 这件事不依赖于守卫有没有开火(比如将来有人把守卫改成语句级)。
    PERFORM set_config('evoltrya.approvals_policy_ctx', '', true);

    INSERT INTO finance_settings_history (
        old_approvals_enabled,         new_approvals_enabled,
        old_approval_level1_role_code, new_approval_level1_role_code,
        old_approval_level2_role_code, new_approval_level2_role_code,
        old_approval_threshold_base,   new_approval_threshold_base,
        changed_by)
    VALUES (
        v_old.approvals_enabled,         p_enabled,
        v_old.approval_level1_role_code, p_level1_role_code,
        v_old.approval_level2_role_code, p_level2_role_code,
        v_old.approval_threshold_base,   p_threshold_base,
        v_actor);

    RETURN jsonb_build_object('changed', true);
END;
$function$;
