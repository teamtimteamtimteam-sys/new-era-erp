-- db/functions/guard_approvals_switch.sql
-- SOD-1:审批开关的两道闸 —— 把"开着但没配"变成一个【到不了】的状态。
--
-- docs/approvals-scoping.md 记着三个状态,其中"on, policy unset → 拒绝路由"。
-- 那个状态会把在途单据搁死:create_purchase_order 照常生成 pending 的单,
-- 而 approve_purchase_order 撞上 APPROVAL_LEVEL1_ROLE_NOT_SET —— 批不了也收不了货。
-- 所以这里做成【到不了】,而不是【到了会拒绝】。
--
-- 【反方向那一半才是真正会搁死人的】关掉开关时,已经 pending 的单会永远停在
-- pending(approve_purchase_order 抛 APPROVALS_NOT_ENABLED)。所以关闭同样有闸,
-- 并且【点名】还剩几张、是哪几张 —— 拒绝要给出路,不是给一堵墙。
--
-- NOTE: introduced by db/migrations/2026-08-24-sod1-one-rule-two-questions.sql.

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