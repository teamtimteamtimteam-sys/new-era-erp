CREATE OR REPLACE FUNCTION public.guard_sales_order_confirmed_immutable()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- draft 随便改;作废/关闭之后也不该再改商业字段
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

    RETURN NEW;
END;
$function$

;
