CREATE OR REPLACE FUNCTION public.guard_sales_order_confirmed_immutable()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- 草稿随便改;作废/关闭之后也不该再改商业字段
    IF OLD.status = 'draft' THEN
        -- 状态列仍然只走转换函数
        IF current_setting('evoltrya.so_status_ctx', true) IS DISTINCT FROM '1'
           AND NEW.status IS DISTINCT FROM OLD.status THEN
            RAISE EXCEPTION 'SO_STATUS_NOT_EDITABLE|%|%', OLD.status, NEW.status;
        END IF;
        RETURN NEW;
    END IF;

    IF current_setting('evoltrya.so_status_ctx', true) = '1' THEN
        RETURN NEW;   -- 转换函数自己在动状态列
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- 【永久冻结的五列 —— 不认任何上下文标记】改了就是另一笔交易。
    -- 改单函数根本不接它们,而这里再挡一遍,是因为守卫要挡的是那条直连的 UPDATE
    -- (RLS 今天就允许任何持 module.sales.edit 的人对本表发 UPDATE)。
    -- 三列日期/币种/汇率是一体的:发票的 2500 就是按订单存下来的 fx_rate 记进去的,
    -- 发货再按发票存下来的汇率把它换成收入。动其中任何一列都是在给一笔已经过账的
    -- 负债重新定价,而分录不会跟着动 —— 所以 PUR-2 的"改单据日就重取牌价"在这里
    -- 【故意不成立】:那边 fx_rate 只是个估价用的锚,这边它是已经入账的那个数。
    -- ════════════════════════════════════════════════════════════════════════
    IF NEW.customer_id IS DISTINCT FROM OLD.customer_id THEN
        RAISE EXCEPTION 'SO_CONFIRMED_IMMUTABLE|customer_id|%', OLD.code;
    END IF;
    IF NEW.currency IS DISTINCT FROM OLD.currency THEN
        RAISE EXCEPTION 'SO_CONFIRMED_IMMUTABLE|currency|%', OLD.code;
    END IF;
    IF NEW.fx_rate IS DISTINCT FROM OLD.fx_rate THEN
        RAISE EXCEPTION 'SO_CONFIRMED_IMMUTABLE|fx_rate|%', OLD.code;
    END IF;
    IF NEW.order_date IS DISTINCT FROM OLD.order_date THEN
        RAISE EXCEPTION 'SO_CONFIRMED_IMMUTABLE|order_date|%', OLD.code;
    END IF;
    IF NEW.code IS DISTINCT FROM OLD.code THEN
        RAISE EXCEPTION 'SO_CONFIRMED_IMMUTABLE|code|%', OLD.code;
    END IF;
    IF NEW.status IS DISTINCT FROM OLD.status THEN
        RAISE EXCEPTION 'SO_STATUS_NOT_EDITABLE|%|%', OLD.status, NEW.status;
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- 【§0(b):notes 与 terms_text 此前不在名单里,而 terms_text 会印在客户手里
    -- 那份 PDF 上】—— 于是一张已经签发出去的单,它的条款可以被任何持
    -- module.sales.edit 的人直连改掉,不留痕迹、不升版本、不告诉任何人。
    -- 现在它们【也是冻结的】,唯一的出路是改单上下文 —— 走那条路会留下一行带
    -- 理由的 header_update,而详情页会据此说出"签发之后又改过"。
    -- 【为什么不干脆焊死】条款与备注本来就是要改的东西(付款方式谈定了、
    -- 交货地点变了)。焊死等于把一件日常动作赶回"作废重开"。
    -- ════════════════════════════════════════════════════════════════════════
    IF current_setting('evoltrya.so_amend_ctx', true) IS DISTINCT FROM '1' THEN
        IF NEW.notes IS DISTINCT FROM OLD.notes THEN
            RAISE EXCEPTION 'SO_CONFIRMED_IMMUTABLE|notes|%', OLD.code;
        END IF;
        IF NEW.terms_text IS DISTINCT FROM OLD.terms_text THEN
            RAISE EXCEPTION 'SO_CONFIRMED_IMMUTABLE|terms_text|%', OLD.code;
        END IF;
    END IF;

    RETURN NEW;
END;
$function$

;
