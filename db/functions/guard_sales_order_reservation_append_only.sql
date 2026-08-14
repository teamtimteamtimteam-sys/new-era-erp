CREATE OR REPLACE FUNCTION public.guard_sales_order_reservation_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_move text := current_setting('evoltrya.reservation_move_ctx', true);
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'SO_RESERVATION_IMMUTABLE|delete';
    END IF;

    -- 【放行的只有三种改动,逐条写出来】
    -- ① 一次性的释放:三列一起从空变成非空,其余一个字不动。
    IF OLD.released_at IS NULL AND NEW.released_at IS NOT NULL
       AND OLD.consumed_at IS NULL AND NEW.consumed_at IS NULL
       AND NEW.id                  IS NOT DISTINCT FROM OLD.id
       AND NEW.sales_order_line_id IS NOT DISTINCT FROM OLD.sales_order_line_id
       AND NEW.output_batch_id     IS NOT DISTINCT FROM OLD.output_batch_id
       AND NEW.location_id         IS NOT DISTINCT FROM OLD.location_id
       AND NEW.qty                 IS NOT DISTINCT FROM OLD.qty
       AND NEW.pair_id             IS NOT DISTINCT FROM OLD.pair_id
       AND NEW.created_at          IS NOT DISTINCT FROM OLD.created_at
       AND NEW.created_by          IS NOT DISTINCT FROM OLD.created_by
    THEN
        RETURN NEW;
    END IF;

    -- ② 一次性的消耗(发货):consumed_at / consumed_by 从空变成非空,其余
    --    一个字不动。与释放并列,而不是共用那三列 —— 见表头。
    --    ("被哪一行发货消耗"由 shipment_lines.reservation_id 反查,不在本表。)
    IF OLD.consumed_at IS NULL AND NEW.consumed_at IS NOT NULL
       AND OLD.released_at IS NULL AND NEW.released_at IS NULL
       AND NEW.id                  IS NOT DISTINCT FROM OLD.id
       AND NEW.sales_order_line_id IS NOT DISTINCT FROM OLD.sales_order_line_id
       AND NEW.output_batch_id     IS NOT DISTINCT FROM OLD.output_batch_id
       AND NEW.location_id         IS NOT DISTINCT FROM OLD.location_id
       AND NEW.qty                 IS NOT DISTINCT FROM OLD.qty
       AND NEW.pair_id             IS NOT DISTINCT FROM OLD.pair_id
       AND NEW.created_at          IS NOT DISTINCT FROM OLD.created_at
       AND NEW.created_by          IS NOT DISTINCT FROM OLD.created_by
    THEN
        RETURN NEW;
    END IF;

    -- ③ 整桶转移带着它换库位 —— 只在转移函数设下的上下文里,且【只有】库位变。
    IF v_move IS NOT NULL AND btrim(v_move) <> ''
       AND OLD.released_at IS NULL AND NEW.released_at IS NULL
       AND OLD.consumed_at IS NULL AND NEW.consumed_at IS NULL
       AND NEW.id                  IS NOT DISTINCT FROM OLD.id
       AND NEW.sales_order_line_id IS NOT DISTINCT FROM OLD.sales_order_line_id
       AND NEW.output_batch_id     IS NOT DISTINCT FROM OLD.output_batch_id
       AND NEW.qty                 IS NOT DISTINCT FROM OLD.qty
       AND NEW.pair_id             IS NOT DISTINCT FROM OLD.pair_id
       AND NEW.created_at          IS NOT DISTINCT FROM OLD.created_at
       AND NEW.created_by          IS NOT DISTINCT FROM OLD.created_by
    THEN
        RETURN NEW;
    END IF;

    RAISE EXCEPTION 'SO_RESERVATION_IMMUTABLE|update';
END;
$function$

;
