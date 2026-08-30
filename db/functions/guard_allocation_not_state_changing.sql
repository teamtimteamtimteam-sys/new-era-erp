CREATE OR REPLACE FUNCTION public.guard_allocation_not_state_changing(p_run_id uuid)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE v_op text; v_code text;
BEGIN
    SELECT pr.operation_type_code, pr.code INTO v_op, v_code
      FROM public.processing_runs pr
      JOIN public.operation_types ot ON ot.code = pr.operation_type_code
      JOIN public.operation_kinds k  ON k.code  = ot.kind_code
     WHERE pr.id = p_run_id AND k.produces_outputs IS FALSE;

    IF FOUND THEN
        RAISE EXCEPTION 'ALLOCATION_STATE_CHANGING_UNRESOLVED|%|%', v_code, v_op
          USING HINT = '状态改变型工序没有产出腿,所以今天的分摊无处可落。Tim 已裁定成本应资本化回投料批,但 unit_price 是【应付之锚】(改它就是改欠供应商的钱),所以那需要一个与它分开的成本载体 —— 一次会计裁定 + 新结构,记在 docs/proc-operations-wired.md。在那之前这条路【按名拒绝】,而不是静默地什么都不分摊。';
    END IF;
END;
$function$
