-- db/functions/set_customer_credit.sql
-- ROLE-1 · Batch 2a(Tim 的矩阵 §10,Batch 2 grilling Q11):客户信用限额与冻结的唯一写入口 —— CFO 一个。
--
-- 【为什么要一支函数】CFO 不持 module.customers.edit,customers 的写策略会把他挡在外面;
-- 而那条策略不能换(客户别的列仍归 cco / cto / finance)。于是两列走这里
-- (SECURITY DEFINER,要 action.customer_credit),直连改它们由 guard_customer_credit_write 按名拒。
--
-- 【两个参数都要给】限额 NULL = 没设限额(放行),0 = 现款现货 —— 两个都正当,而且相反
-- (SAL-B 的列注释)。所以 NULL 在这里是一个【值】,不是"不改";冻结不许 NULL
-- (列本身 NOT NULL)→ CUSTOMER_CREDIT_HOLD_REQUIRED。负数 → CUSTOMER_CREDIT_LIMIT_INVALID
-- (表上的 CHECK 也会拒,这里先按名说出来)。
--
-- 【留痕不用这里写】trg_customers_credit_history(BEFORE UPDATE OF 两列)照常写
-- customer_credit_history,changed_by = auth.uid() —— 属主路径里 auth.uid() 仍是按下去的那个人。
-- 两列都没变 → 不写(不留一行"改成了原样"的痕),返回 changed = false。
--
-- NOTE: introduced by db/migrations/2026-09-24-role1b2a-cfo-settings-credit-and-supplier-approval.sql.

CREATE OR REPLACE FUNCTION public.set_customer_credit(p_customer_id uuid, p_credit_limit_base numeric, p_credit_hold boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_c customers%ROWTYPE;
BEGIN
    PERFORM require_permission('action.customer_credit');

    IF p_credit_hold IS NULL THEN
        RAISE EXCEPTION 'CUSTOMER_CREDIT_HOLD_REQUIRED';
    END IF;
    IF p_credit_limit_base IS NOT NULL AND p_credit_limit_base < 0 THEN
        RAISE EXCEPTION 'CUSTOMER_CREDIT_LIMIT_INVALID|%', p_credit_limit_base;
    END IF;

    SELECT * INTO v_c FROM customers WHERE id = p_customer_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CUSTOMER_NOT_FOUND|%', COALESCE(p_customer_id::text, '?');
    END IF;

    IF v_c.credit_limit_base IS NOT DISTINCT FROM p_credit_limit_base
       AND v_c.credit_hold IS NOT DISTINCT FROM p_credit_hold THEN
        RETURN jsonb_build_object('code', v_c.code, 'changed', false,
                                  'credit_limit_base', v_c.credit_limit_base, 'credit_hold', v_c.credit_hold);
    END IF;

    UPDATE customers
       SET credit_limit_base = p_credit_limit_base,
           credit_hold = p_credit_hold,
           updated_by = auth.uid()
     WHERE id = p_customer_id;

    RETURN jsonb_build_object('code', v_c.code, 'changed', true,
                              'credit_limit_base', p_credit_limit_base, 'credit_hold', p_credit_hold);
END;
$function$;

COMMENT ON FUNCTION public.set_customer_credit(uuid, numeric, boolean) IS
'ROLE-1 Batch 2a:客户信用限额与冻结的唯一写入口,要 action.customer_credit(CFO)。限额 NULL = 不设限(是一个值,不是"不改");冻结必填。留痕由 trg_customers_credit_history 照常写。';
