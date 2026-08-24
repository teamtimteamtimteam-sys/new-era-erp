-- SOD-1-fu:`text[] || '字面量'` 里那个字面量【不是 text】,于是闸自己炸了
--
-- 【症状】fixture 127 的 C1 臂:开关本该因 APPROVALS_POLICY_INCOMPLETE 被拒,
-- 实际抛的是 `malformed array literal: "approval_level1_role_code"`。
--
-- 【机制】PL/pgSQL 里 `v_missing := v_missing || 'approval_level1_role_code';`
-- 的右操作数是一个【无类型字面量】。`||` 在 anyarray||anyelement 与
-- anyarray||anyarray 两个候选之间,把它解析成了【后者】—— 于是那串字符被当成
-- 一个数组字面量去解析,当场报错。加 `::text` 就没有歧义了。
--
-- 【为什么它值得单独记一笔,而不只是"手滑"】这个闸是【新加的】,而它抛出的
-- 不是它自己的名字,是一句 PostgreSQL 的内部错误。如果没有那一臂
-- 【断言拒绝的是哪一个错误码】,C1 会看见"更新失败了"就变绿 ——
-- 一个为了错的理由通过的臂。fixture 127 的每一个拒绝臂都比对
-- `SQLERRM LIKE '<CODE>|%'`,这一条正是它抓出来的。
--
-- 【范围】两支函数,同一个写法:guard_approvals_switch 的 v_missing,
-- 与 approvals_readiness 的 v_blocking。逻辑一字未改,只加类型。

BEGIN;

CREATE OR REPLACE FUNCTION public.approvals_readiness()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_s        record;
    v_blocking text[] := '{}';
    v_l1_real  integer := 0;
    v_l2_real  boolean := false;
    v_pending  integer := 0;
BEGIN
    SELECT approvals_enabled, approval_level1_role_code, approval_threshold_base,
           approval_level2_user_id
      INTO v_s FROM finance_settings LIMIT 1;

    IF v_s.approval_level1_role_code IS NULL THEN
        v_blocking := v_blocking || 'approval_level1_role_code'::text;
    ELSE
        -- 【数的是【真的登录得了的】持有人】线上有 66 条 user_roles 的 user_id
        -- 在 auth.users 里根本不存在(见 known-issues 的 ACCOUNTS-STALE 条)。
        -- 一个只由幽灵持有的角色,是一个永远不会有人来批的队列。
        SELECT count(*) INTO v_l1_real
          FROM user_roles ur
          JOIN roles r ON r.id = ur.role_id
          JOIN auth.users u ON u.id = ur.user_id
         WHERE r.code = v_s.approval_level1_role_code AND r.is_active;
        IF v_l1_real = 0 THEN
            v_blocking := v_blocking || 'approval_level1_role_has_no_real_holder'::text;
        END IF;
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

CREATE OR REPLACE FUNCTION public.guard_approvals_switch()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_missing text[] := '{}';
    v_holders integer;
    v_pending integer;
    v_codes   text;
BEGIN
    -- ── 开:三个策略值必须齐,而且必须【指向真的人】 ──
    IF NEW.approvals_enabled AND NOT OLD.approvals_enabled THEN
        IF NEW.approval_level1_role_code IS NULL THEN
            v_missing := v_missing || 'approval_level1_role_code'::text;
        END IF;
        IF NEW.approval_threshold_base IS NULL THEN
            v_missing := v_missing || 'approval_threshold_base'::text;
        END IF;
        IF NEW.approval_level2_user_id IS NULL THEN
            v_missing := v_missing || 'approval_level2_user_id'::text;
        END IF;
        IF cardinality(v_missing) > 0 THEN
            RAISE EXCEPTION 'APPROVALS_POLICY_INCOMPLETE|%', array_to_string(v_missing, ', ');
        END IF;

        SELECT count(*) INTO v_holders
          FROM user_roles ur JOIN roles r ON r.id = ur.role_id
          JOIN auth.users u ON u.id = ur.user_id
         WHERE r.code = NEW.approval_level1_role_code AND r.is_active;
        IF v_holders = 0 THEN
            RAISE EXCEPTION 'APPROVALS_LEVEL1_ROLE_UNHELD|%', NEW.approval_level1_role_code;
        END IF;

        IF NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = NEW.approval_level2_user_id) THEN
            RAISE EXCEPTION 'APPROVALS_LEVEL2_USER_UNKNOWN|%', NEW.approval_level2_user_id;
        END IF;
    END IF;

    -- ── 关:在途的 pending 单会被永远搁死,所以先点名 ──
    IF OLD.approvals_enabled AND NOT NEW.approvals_enabled THEN
        SELECT count(*), string_agg(code, ', ' ORDER BY code)
          INTO v_pending, v_codes
          FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL;
        IF COALESCE(v_pending, 0) > 0 THEN
            RAISE EXCEPTION 'APPROVALS_CANNOT_DISABLE_WITH_PENDING|%|%', v_pending, v_codes;
        END IF;
    END IF;

    -- ── 开着的时候不许把策略值抽走 ──
    IF NEW.approvals_enabled THEN
        IF NEW.approval_level1_role_code IS NULL AND OLD.approval_level1_role_code IS NOT NULL THEN
            RAISE EXCEPTION 'APPROVALS_POLICY_LOCKED_WHILE_ON|approval_level1_role_code';
        END IF;
        IF NEW.approval_threshold_base IS NULL AND OLD.approval_threshold_base IS NOT NULL THEN
            RAISE EXCEPTION 'APPROVALS_POLICY_LOCKED_WHILE_ON|approval_threshold_base';
        END IF;
        IF NEW.approval_level2_user_id IS NULL AND OLD.approval_level2_user_id IS NOT NULL THEN
            RAISE EXCEPTION 'APPROVALS_POLICY_LOCKED_WHILE_ON|approval_level2_user_id';
        END IF;
    END IF;

    RETURN NEW;
END;
$function$;

COMMIT;
