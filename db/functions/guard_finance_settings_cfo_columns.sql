-- db/functions/guard_finance_settings_cfo_columns.sql
-- ROLE-1 · Batch 2a(Tim 的矩阵 §12,Batch 2 grilling Q10):**财务设置只归 CFO** ——
-- 除了两处:锁期(locked_before)仍归财务,审批四列仍只走 set_approvals_policy。
--
-- 【为什么是一支列守卫,而不是换掉这张表的写策略】finance_settings 是【一行、两个主人】:
-- 财务要直连写 locked_before(/finance/settings 的手动锁),CFO 要写其余各列。CFO 不持
-- module.finance.edit,所以写策略不能换成 action.finance_settings(那会把财务的锁拿走);
-- 也不能保持原样放任(那会让财务照旧改 GST 登记)。于是:写策略不动,
-- 【直连写】改到锁期与审批四列以外的任何一列 → 按名拒,那些列只走 set_finance_settings
-- (SECURITY DEFINER,要 action.finance_settings)。
--
-- 【判据写成"除了这几列,其余全归 CFO"】而不是列一份 CFO 的列清单:哪一天这张表多一列,
-- 它默认落在 CFO 那一边 —— 多一列设置而没有人想过它归谁,错在安全的那一边。
-- 审批四列在这里放行,是因为它们有自己的守卫(guard_approvals_policy_write),不是因为
-- 它们归财务;updated_at / updated_by 是盖章,不是设置。
--
-- 【INSERT 一律拒】这张表是单行表(id boolean CHECK (id)),那一行在建库时就在;
-- 客户端再插一行只可能是绕路。
--
-- 【为什么是 INVOKER】与 guard_lock_reopen_path、enforce_write_permission 同一个理由:
-- 要分出"直连写"(row_security_active = true)与属主路径(set_finance_settings、
-- set_approvals_policy、close_period 都是 SECURITY DEFINER,各自已经要过自己的码)。
--
-- NOTE: introduced by db/migrations/2026-09-24-role1b2a-cfo-settings-credit-and-supplier-approval.sql.

CREATE OR REPLACE FUNCTION public.guard_finance_settings_cfo_columns()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_col text;
BEGIN
    IF NOT row_security_active(TG_RELID) THEN
        RETURN NEW;
    END IF;
    IF TG_OP = 'INSERT' THEN
        RAISE EXCEPTION 'FINANCE_SETTINGS_THROUGH_FUNCTION_ONLY|insert';
    END IF;

    SELECT n.key INTO v_col
      FROM jsonb_each(to_jsonb(NEW)) n
      JOIN jsonb_each(to_jsonb(OLD)) o ON o.key = n.key
     WHERE n.key NOT IN ('locked_before', 'updated_at', 'updated_by',
                         'approval_level1_role_code', 'approval_level2_role_code',
                         'approval_threshold_base', 'approvals_enabled')
       AND n.value IS DISTINCT FROM o.value
     ORDER BY n.key
     LIMIT 1;
    IF v_col IS NOT NULL THEN
        RAISE EXCEPTION 'FINANCE_SETTINGS_THROUGH_FUNCTION_ONLY|%', v_col;
    END IF;
    RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.guard_finance_settings_cfo_columns() IS
'ROLE-1 Batch 2a:一次直连写(row_security_active)若改到 finance_settings 上锁期(locked_before)与审批四列以外的任何一列,或直连 INSERT,按名拒 FINANCE_SETTINGS_THROUGH_FUNCTION_ONLY|<列> —— 那些列只走 set_finance_settings(action.finance_settings,CFO)。判据写成"除了这几列",所以将来新加的列默认归 CFO。INVOKER,以分出直连写与属主路径。';
