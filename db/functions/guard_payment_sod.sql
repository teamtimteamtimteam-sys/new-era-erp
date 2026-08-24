-- db/functions/guard_payment_sod.sql
-- SOD-1:后门② —— payments 的直连 INSERT。authenticated 持表级 INSERT 授权。
--
-- 【范围,说出来而不是让人以为查过了】只管【出款】给【供应商】:
--   · 收款(direction='in')不是"付给收款人",风险形状不同(虚构收入),不在本刀;
--   · 出款给【员工】(报销)由 HR 建档、财务付款,已跨两个模块的门。
-- 【冲销不是付款】reverse_payment 的镜像行 direction/counterparty 与原单相同,
-- 由调用方【显式声明】上下文放行(po_status_ctx / close_ctx / alloc_ctx 同一惯用法),
-- 不由守卫去猜。拦住冲销只会把一笔记错的付款锁死在账上,而拦不住任何舞弊。
--
-- NOTE: introduced by db/migrations/2026-08-24-sod1-one-rule-two-questions.sql.

CREATE OR REPLACE FUNCTION public.guard_payment_sod()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code text;
BEGIN
    -- 范围:【出款】给【供应商】。
    --   · 收款(direction='in')不是"付给收款人",风险形状不同(虚构收入),
    --     不在本刀范围 —— 说出来,而不是让读的人以为查过了;
    --   · 出款给【员工】(报销)由 HR 建档、财务付款,已经跨了两个模块的门,
    --     不是同一个人端到端。
    IF NEW.direction <> 'out' OR NEW.counterparty_type <> 'supplier' THEN
        RETURN NEW;
    END IF;

    -- 【冲销不是付款】reverse_payment 造的镜像行 direction/counterparty 与原单相同,
    -- 所以它会走到这里。冲销是把钱【收回来】的更正动作,拦住它只会把一笔记错的
    -- 付款锁死在账上 —— 而且拦不住任何舞弊。
    -- 由调用方【显式声明】,不由守卫去猜(与 po_status_ctx / close_ctx / alloc_ctx
    -- 同一个惯用法)。
    IF COALESCE(current_setting('evoltrya.payment_reversal_ctx', true), '') = '1' THEN
        RETURN NEW;
    END IF;

    SELECT s.code INTO v_code FROM suppliers s WHERE s.id = NEW.supplier_id;
    PERFORM assert_segregated(
        'SOD_PAYEE_AND_PAY',
        sod_supplier_creator(NEW.supplier_id),
        COALESCE(v_code, NEW.supplier_id::text));
    RETURN NEW;
END;
$function$;