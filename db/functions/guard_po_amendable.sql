CREATE OR REPLACE FUNCTION public.guard_po_amendable()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- 【改了就是另一笔交易 —— 重开一张,不是改这一张】
    -- 供应商:应付、预付、签发档全挂在这笔交易上,换人等于把它们悄悄重指。
    -- 币种:fx_rate 锚在 order_date 的 tt_sell 上,而付款计划的定额腿是按【那个】
    --       币种谈的(FIN-29 明确拒绝换币种的单)—— 换币种把整个金额框架作废。
    IF NEW.supplier_id IS DISTINCT FROM OLD.supplier_id THEN
        RAISE EXCEPTION 'PO_FIELD_IMMUTABLE|supplier_id|%', OLD.code;
    END IF;
    IF NEW.currency IS DISTINCT FROM OLD.currency THEN
        RAISE EXCEPTION 'PO_FIELD_IMMUTABLE|currency|%', OLD.code;
    END IF;
    IF NEW.code IS DISTINCT FROM OLD.code THEN
        RAISE EXCEPTION 'PO_FIELD_IMMUTABLE|code|%', OLD.code;
    END IF;

    -- 【状态与审批状态不走"修改"这条路】它们各有自己的转换
    -- (cancel/close/reopen、审批函数)。一个能把 approval_status 设成 approved 的
    -- 编辑表单,就是一条不经审批的审批路径。
    -- 【但要放行那三个转换本身】—— 它们改的正是这两列,靠上下文标记区分,
    -- 与 FIN-36c 的 alloc_ctx、年结的 close_ctx 同一个惯用法。
    IF current_setting('evoltrya.po_status_ctx', true) IS DISTINCT FROM '1' THEN
        IF NEW.status IS DISTINCT FROM OLD.status THEN
            RAISE EXCEPTION 'PO_STATUS_NOT_AMENDABLE|status|%|%', OLD.status, NEW.status;
        END IF;
        -- APR-2 的作废触发器【也】改 approval_status。它是 BEFORE UPDATE、
        -- 与本守卫同级,执行顺序按名字排:guard_(g) 在 trg_(t) 之前,
        -- 于是本守卫看到的是【还没被作废触发器改过的】值 —— 放行的判据因此是
        -- "调用方有没有自己动它",而不是"最终值是不是变了"。
        IF NEW.approval_status IS DISTINCT FROM OLD.approval_status THEN
            RAISE EXCEPTION 'PO_STATUS_NOT_AMENDABLE|approval_status|%|%',
                OLD.approval_status, NEW.approval_status;
        END IF;
    END IF;

    RETURN NEW;
END;
$function$;