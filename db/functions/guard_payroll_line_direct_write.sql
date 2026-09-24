-- db/functions/guard_payroll_line_direct_write.sql
-- PAYROLL-APR-1(2026-09-24,grilling Q5):已过账、或挂着未了结申请的工资期,它的【行】不许直连改。
--
-- 【Step 0 实测的侧门】payroll_lines 的写策略开在 module.hr.edit 上;以 chooer@ 在一笔回滚的
-- 事务里直连改 PAY-2026-0001(已过账、已付清)的一行 —— 1 行,成功。一期被批过、过过账的工资,
-- 它的行可以在总账脚下被改掉;一期正在等 CFO 批的工资,它的行可以在批之前被换掉。
--
-- 本守卫(直连写才判,row_security_active):行所在的期间 payroll_period_frozen ≠ 'open'
-- (已过账或挂着 submitted / approved 的申请)时,INSERT / UPDATE / DELETE 一律按名拒
-- PAYROLL_LINES_FROZEN|<期间编号>|<posted|requested>。UPDATE 把行挪到另一期,两边都判。
-- 草稿且没有申请的期间照旧可以直连改(那是 hr.edit 本来的活)。
-- upsert_payroll_period 与付款三支函数都是 SECURITY DEFINER,本守卫看不见它们。
--
-- 【为什么是 INVOKER】同 guard_payroll_period_direct_write。
-- NOTE: introduced by db/migrations/2026-09-24-payrollapr1-payroll-posts-only-after-cfo-approval.sql.

CREATE OR REPLACE FUNCTION public.guard_payroll_line_direct_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_pid   uuid;
    v_state text;
BEGIN
    IF NOT row_security_active(TG_RELID) THEN
        RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
    END IF;
    FOREACH v_pid IN ARRAY (CASE TG_OP
                                WHEN 'INSERT' THEN ARRAY[NEW.payroll_period_id]
                                WHEN 'DELETE' THEN ARRAY[OLD.payroll_period_id]
                                ELSE ARRAY[OLD.payroll_period_id, NEW.payroll_period_id] END) LOOP
        v_state := payroll_period_frozen(v_pid);
        IF v_state <> 'open' THEN
            RAISE EXCEPTION 'PAYROLL_LINES_FROZEN|%|%',
                COALESCE((SELECT code FROM payroll_period_lookup WHERE id = v_pid), v_pid::text), v_state;
        END IF;
    END LOOP;
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$function$;

COMMENT ON FUNCTION public.guard_payroll_line_direct_write() IS
'PAYROLL-APR-1(Tim 的 Q5):直连写(row_security_active)一个已过账或挂着未了结申请的工资期的行(INSERT / UPDATE / DELETE),按名拒 PAYROLL_LINES_FROZEN|<期间>|<posted|requested>。草稿且没有申请的期间照旧。INVOKER,以分出直连写与属主路径;冻结状态经 payroll_period_frozen(DEFINER)问。';
