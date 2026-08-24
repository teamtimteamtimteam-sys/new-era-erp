-- SOD-1-fu2:一个管控【开得起来】,不等于它【有人来运行】
--
-- 【来历】SOD-1 落地后的一次独立复测(第二个会话,只读、全部回滚)量到:
--
--     finance 的真实持有人 .............................. 1
--     finance 的真实持有人中【不能提采购单】的 .......... 0
--
-- 原因是 `finance` 这个角色【自己就持有 module.purchasing.edit`】。
-- 于是被裁定的一级审批角色,今天没有一个"结构上不可能是提单人"的审批人:
-- SELF_APPROVAL_FORBIDDEN 仍然拦得住【同一个人】提了又批,但"同角色内 A 提 B 批"
-- 是唯一可用的形状,而在只有一个持有人时连那个形状都不成立。
--
-- 【为什么它是【报告】,不是【闸】—— 这一条是这次改动的全部要点】
-- 把它做成拒绝,会让 Tim 自己已经裁定的策略(level1 = finance)【开不起来】。
-- **一道拦住既定决定的闸,是一道会被绕过去的闸** —— 而绕过去之后,连报告都没有了。
-- approvals_readiness() 本来就是"报告",不是"执行":它是这句话诚实的家。
-- guard_approvals_switch 一个字都没有改。
--
-- 【它答的是一个【结构】问题,所以它答得准】它不试图分辨"谁是真人"——
-- 那件事今天答不了(线上五个 test.local 账号持 admin,66 条授权认不到人,
-- 见 docs/known-issues.md 的 ACCOUNTS-STALE 条),而一个靠命名规则去猜人的判据
-- 会因为残留账号而变绿,那正是"为了错的理由通过"。
-- 这里问的是权限矩阵里一件确定的事:**这个角色的持有人里,有几个是提不了单的。**
--
-- 【留给 Tim 的问题,记在这里因为它不是代码能答的】三选一:
--   ① 一级审批不再是 `finance`;② `finance` 不再持 `module.purchasing.edit`;
--   ③ 明确接受"同角色内互批"。**这是"管控开着"与"管控有人运行"的区别。**

BEGIN;

CREATE OR REPLACE FUNCTION public.approvals_readiness()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_s          record;
    v_blocking   text[] := '{}';
    v_l1_real    integer := 0;
    v_l1_norais  integer := 0;
    v_l2_real    boolean := false;
    v_pending    integer := 0;
BEGIN
    PERFORM require_permission('module.finance.view');

    SELECT approvals_enabled, approval_level1_role_code, approval_threshold_base,
           approval_level2_user_id
      INTO v_s FROM finance_settings LIMIT 1;

    IF v_s.approval_level1_role_code IS NULL THEN
        v_blocking := v_blocking || 'approval_level1_role_code'::text;
    ELSE
        SELECT count(*) INTO v_l1_real
          FROM user_roles ur
          JOIN roles r ON r.id = ur.role_id
          JOIN auth.users u ON u.id = ur.user_id
         WHERE r.code = v_s.approval_level1_role_code AND r.is_active;
        IF v_l1_real = 0 THEN
            v_blocking := v_blocking || 'approval_level1_role_has_no_real_holder'::text;
        END IF;

        -- 【报告,不拦】这个角色的持有人里,有几个是【提不了采购单】的。
        -- 0 意味着这道控制没有一个结构上合格的审批人 —— 见本迁移抬头。
        SELECT count(*) INTO v_l1_norais
          FROM (
            SELECT DISTINCT ur.user_id
              FROM user_roles ur
              JOIN roles r ON r.id = ur.role_id
              JOIN auth.users u ON u.id = ur.user_id
             WHERE r.code = v_s.approval_level1_role_code AND r.is_active
          ) h
         WHERE NOT EXISTS (
            SELECT 1 FROM user_roles ur2
              JOIN roles r2 ON r2.id = ur2.role_id
              JOIN role_permissions rp ON rp.role_id = r2.id
             WHERE ur2.user_id = h.user_id AND r2.is_active
               AND rp.permission_code = 'module.purchasing.edit');
    END IF;

    IF v_s.approval_threshold_base IS NULL THEN
        v_blocking := v_blocking || 'approval_threshold_base'::text;
    END IF;

    IF v_s.approval_level2_user_id IS NULL THEN
        v_blocking := v_blocking || 'approval_level2_user_id'::text;
    ELSE
        SELECT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = v_s.approval_level2_user_id)
          INTO v_l2_real;
        IF NOT v_l2_real THEN
            v_blocking := v_blocking || 'approval_level2_user_is_not_a_real_account'::text;
        END IF;
    END IF;

    SELECT count(*) INTO v_pending
      FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL;

    RETURN jsonb_build_object(
        'enabled',                 v_s.approvals_enabled,
        'level1_role_code',        v_s.approval_level1_role_code,
        'level1_real_holders',     v_l1_real,
        -- 【非阻塞的忠告】0 = 这个角色里没有人是"提不了单"的
        'level1_holders_who_cannot_raise', v_l1_norais,
        'threshold_base',          v_s.approval_threshold_base,
        'level2_user_id',          v_s.approval_level2_user_id,
        'level2_user_is_real',     v_l2_real,
        'pending_purchase_orders', v_pending,
        'blocking',                to_jsonb(v_blocking),
        'can_enable',              (NOT v_s.approvals_enabled AND cardinality(v_blocking) = 0),
        'can_disable',             (v_s.approvals_enabled AND v_pending = 0)
    );
END;
$function$;

COMMIT;
