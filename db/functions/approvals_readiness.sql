-- db/functions/approvals_readiness.sql
-- SOD-1:审批开关【能不能开】,以及开不了的话缺哪几样 —— 屏幕与闸读同一份判据。
-- 一个屏幕上说"可以开"、闸却拒绝的系统,比两者都拒绝更坏(fixture 127 C8 钉这一条)。
--
-- 【数的是【真的登录得了的】持有人】线上有 66 条 user_roles 的 user_id 在
-- auth.users 里根本不存在(docs/known-issues.md 的 ACCOUNTS-STALE 条)。
-- 一个只由幽灵持有的角色,是一个永远不会有人来批的队列。
--
-- 【它答不了的那一件,不假装答得了】"是否存在第二个真人",本函数【不判】——
-- 线上五个 test.local 走查账号都持 admin,任何按账号数的判据都会因为它们而通过,
-- 也就是为了错的理由通过。那一条留在 docs/fresh-install-checklist.md 里由人判断。
--
-- NOTE: introduced by db/migrations/2026-08-24-sod1-one-rule-two-questions.sql.
--
-- 【fu2:一个【非阻塞】的忠告字段 level1_holders_who_cannot_raise】
-- 独立复测量到:`finance` 角色自己就持 module.purchasing.edit,于是被裁定的
-- 一级审批角色里,"结构上提不了单"的持有人是 **0** 个。
-- **它报告,不拦** —— 做成拒绝会让 Tim 自己裁定的策略开不起来,
-- 而一道拦住既定决定的闸是一道会被绕过去的闸。留给 Tim 的三选一写在
-- db/migrations/2026-08-24-sod1-fu2-*.sql 的抬头。
--
-- 【fu2 同时补上了调用者检查】gate 的 B2 抓到它是 SECURITY DEFINER 且无检查而可调用。
-- 它【要】被 /finance/settings 调用,所以走的是"加检查"这一半,不是"收权限"那一半
-- (另外三支内层函数走的是后者,见 db/views/zzz_function_grants.sql)。

CREATE OR REPLACE FUNCTION public.approvals_readiness()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_s          record;
    v_blocking   text[] := '{}';
    v_l1_total   integer := 0;  v_l1_real integer := 0;
    v_l2_total   integer := 0;  v_l2_real integer := 0;
    v_l1_norais  integer := 0;
    v_l1_sees    boolean := false;
    v_l2_sees    boolean := false;
    v_pending    integer := 0;
BEGIN
    PERFORM require_permission('module.finance.view');

    SELECT approvals_enabled, approval_level1_role_code, approval_threshold_base,
           approval_level2_role_code
      INTO v_s FROM finance_settings LIMIT 1;

    -- ── 一级 ──
    IF v_s.approval_level1_role_code IS NULL THEN
        v_blocking := v_blocking || 'approval_level1_role_code'::text;
    ELSE
        SELECT count(*) INTO v_l1_real FROM real_role_holders(v_s.approval_level1_role_code);
        SELECT count(*) INTO v_l1_total
          FROM user_roles ur JOIN roles r ON r.id = ur.role_id
         WHERE r.code = v_s.approval_level1_role_code AND r.is_active AND ur.revoked_at IS NULL;
        v_l1_sees := role_can_see_amounts(v_s.approval_level1_role_code);

        IF v_l1_real = 0 AND v_l1_total > 0 THEN
            v_blocking := v_blocking || 'approval_level1_holder_cannot_sign_in'::text;
        ELSIF v_l1_real = 0 THEN
            v_blocking := v_blocking || 'approval_level1_role_has_no_real_holder'::text;
        END IF;
        IF NOT v_l1_sees THEN
            v_blocking := v_blocking || 'approval_level1_role_cannot_see_amounts'::text;
        END IF;

        -- 【报告,不拦】这个角色的持有人里,有几个是【提不了采购单】的(SOD-1 fu2)。
        SELECT count(*) INTO v_l1_norais
          FROM real_role_holders(v_s.approval_level1_role_code) h
         WHERE NOT EXISTS (
            SELECT 1 FROM user_roles ur2
              JOIN roles r2 ON r2.id = ur2.role_id
              JOIN role_permissions rp ON rp.role_id = r2.id
             WHERE ur2.user_id = h.user_id AND r2.is_active AND ur2.revoked_at IS NULL
               AND rp.permission_code = 'module.purchasing.edit');
    END IF;

    IF v_s.approval_threshold_base IS NULL THEN
        v_blocking := v_blocking || 'approval_threshold_base'::text;
    END IF;

    -- ── 二级:与一级【同等对待】,这正是本刀要的 ──
    IF v_s.approval_level2_role_code IS NULL THEN
        v_blocking := v_blocking || 'approval_level2_role_code'::text;
    ELSE
        SELECT count(*) INTO v_l2_real FROM real_role_holders(v_s.approval_level2_role_code);
        SELECT count(*) INTO v_l2_total
          FROM user_roles ur JOIN roles r ON r.id = ur.role_id
         WHERE r.code = v_s.approval_level2_role_code AND r.is_active AND ur.revoked_at IS NULL;
        v_l2_sees := role_can_see_amounts(v_s.approval_level2_role_code);

        IF v_l2_real = 0 AND v_l2_total > 0 THEN
            v_blocking := v_blocking || 'approval_level2_holder_cannot_sign_in'::text;
        ELSIF v_l2_real = 0 THEN
            v_blocking := v_blocking || 'approval_level2_role_has_no_real_holder'::text;
        END IF;
        IF NOT v_l2_sees THEN
            v_blocking := v_blocking || 'approval_level2_role_cannot_see_amounts'::text;
        END IF;
    END IF;

    SELECT count(*) INTO v_pending
      FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL;

    RETURN jsonb_build_object(
        'enabled',                 v_s.approvals_enabled,
        'level1_role_code',        v_s.approval_level1_role_code,
        'level1_holders_total',    v_l1_total,
        'level1_real_holders',     v_l1_real,
        'level1_can_see_amounts',  v_l1_sees,
        'level1_holders_who_cannot_raise', v_l1_norais,
        'threshold_base',          v_s.approval_threshold_base,
        'level2_role_code',        v_s.approval_level2_role_code,
        'level2_holders_total',    v_l2_total,
        'level2_real_holders',     v_l2_real,
        'level2_can_see_amounts',  v_l2_sees,
        'pending_purchase_orders', v_pending,
        'blocking',                to_jsonb(v_blocking),
        'can_enable',              (NOT v_s.approvals_enabled AND cardinality(v_blocking) = 0),
        'can_disable',             (v_s.approvals_enabled AND v_pending = 0),
        -- 跟着数字走的那句话,不只躺在文档里(与 PARTY-1 的处置同形)
        'no_deputy_by_decision',   true);
END;
$function$;

COMMENT ON FUNCTION public.approvals_readiness() IS
'SOD-1,CHAIN-BUILD-1 改写(2026-08-30):审批开关能不能开,以及开不了缺哪几样 —— 屏幕与闸读同一份判据。★两级【同等对待】★:各返回 holders_total(未撤销的授权数)与 real_holders(真的登录得了的),**两个数而不是一个数加一个布尔**,因为要分开的是三种状态:没人持有 / 有人持有但登录不了 / 有能干活的人 —— 中间那一种若报成"没有持有人",操作的人会去再授一次权,而那个角色已经授过了。持有人判据只有一处定义(real_role_holders)。另报每一级的 can_see_amounts(R4)。**没有代理人、没有升级**:某一级没人就停在那一级,这是裁定,不是遗漏(no_deputy_by_decision 跟着返回值走)。';
