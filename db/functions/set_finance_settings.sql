-- db/functions/set_finance_settings.sql
-- ROLE-1 · Batch 2a(Tim 的矩阵 §12,Batch 2 grilling Q10):财务设置【只归 CFO】的唯一写入口。
--
-- 【为什么要一支函数】CFO 不持任何 .edit 码,所以 finance_settings 的写策略
-- (module.finance.edit)会把他挡在外面;而那条策略不能换 —— 锁期仍归财务。
-- 于是 CFO 那几列走这里(SECURITY DEFINER,要 action.finance_settings),
-- 直连写那几列由 guard_finance_settings_cfo_columns 按名拒。
--
-- 【参数是一份 jsonb,只写出现了的键】今天界面上只有 GST 那一块(Q10:不加新屏),
-- 但这支函数管的是 CFO 那一边的【每一列】:
--     gst_registered · gst_registration_no · gst_rate_pct · system_start_date
--     fy_end_month · fy_end_day · first_fy_end · default_allocation_basis
-- 只 SET 出现了的键:BEFORE UPDATE OF gst_registered, gst_registration_no 的
-- trg_gst_switch 只在那两列真的出现在 SET 里时才触发,不让一次改会计年度的写
-- 去惊动 GST 的业务守卫。
--   · 锁期与审批四列【不在这里】→ FINANCE_SETTINGS_KEY_NOT_HERE|<键>(各有自己的门:
--     手动锁 / close_period / reopen_period;set_approvals_policy)。
--   · 不认识的键 → FINANCE_SETTINGS_KEY_UNKNOWN|<键>;一个空对象 → FINANCE_SETTINGS_NOTHING_TO_CHANGE。
--   · 取值的类型与约束由 jsonb_populate_record 与表自己的 CHECK 把关(一份定义)。
--
-- 【它不绕过任何业务守卫】guard_gst_switch(注销 GST 时有已带税码的单据 → 拒)、
-- guard_finance_settings_sod 都照常触发:SECURITY DEFINER 只跳过【谁可以写】那一层
-- (RLS 与 enforce_write_permission),不跳过【能不能这样写】那一层。
--
-- NOTE: introduced by db/migrations/2026-09-24-role1b2a-cfo-settings-credit-and-supplier-approval.sql.

CREATE OR REPLACE FUNCTION public.set_finance_settings(p_changes jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_allowed text[] := ARRAY['gst_registered', 'gst_registration_no', 'gst_rate_pct',
                              'system_start_date', 'fy_end_month', 'fy_end_day',
                              'first_fy_end', 'default_allocation_basis'];
    v_elsewhere text[] := ARRAY['locked_before', 'approval_level1_role_code',
                                'approval_level2_role_code', 'approval_threshold_base',
                                'approvals_enabled'];
    v_key  text;
    v_row  finance_settings%ROWTYPE;
    v_new  finance_settings%ROWTYPE;
    v_set  text;
BEGIN
    PERFORM require_permission('action.finance_settings');

    IF p_changes IS NULL OR jsonb_typeof(p_changes) <> 'object' OR p_changes = '{}'::jsonb THEN
        RAISE EXCEPTION 'FINANCE_SETTINGS_NOTHING_TO_CHANGE';
    END IF;
    FOR v_key IN SELECT jsonb_object_keys(p_changes) ORDER BY 1 LOOP
        IF v_key = ANY (v_elsewhere) THEN
            RAISE EXCEPTION 'FINANCE_SETTINGS_KEY_NOT_HERE|%', v_key;
        END IF;
        IF NOT (v_key = ANY (v_allowed)) THEN
            RAISE EXCEPTION 'FINANCE_SETTINGS_KEY_UNKNOWN|%', v_key;
        END IF;
    END LOOP;

    SELECT * INTO v_row FROM finance_settings WHERE id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'FINANCE_SETTINGS_ROW_MISSING';
    END IF;
    v_new := jsonb_populate_record(v_row, p_changes);

    SELECT string_agg(format('%I = ($1).%I', k, k), ', ' ORDER BY k) INTO v_set
      FROM jsonb_object_keys(p_changes) k;
    EXECUTE format('UPDATE finance_settings SET %s, updated_by = $2 WHERE id', v_set)
      USING v_new, auth.uid();

    SELECT * INTO v_new FROM finance_settings WHERE id;
    RETURN jsonb_build_object(
        'gst_registered', v_new.gst_registered,
        'gst_registration_no', v_new.gst_registration_no,
        'gst_rate_pct', v_new.gst_rate_pct,
        'system_start_date', v_new.system_start_date,
        'fy_end_month', v_new.fy_end_month,
        'fy_end_day', v_new.fy_end_day,
        'first_fy_end', v_new.first_fy_end,
        'default_allocation_basis', v_new.default_allocation_basis);
END;
$function$;

COMMENT ON FUNCTION public.set_finance_settings(jsonb) IS
'ROLE-1 Batch 2a:CFO 那一边的财务设置(GST 登记、系统起始日、会计年度、默认分摊基准)的唯一写入口。要 action.finance_settings。只 SET 出现了的键;锁期与审批四列按名拒(FINANCE_SETTINGS_KEY_NOT_HERE),它们各有自己的门。业务守卫(guard_gst_switch 等)照常触发。';
