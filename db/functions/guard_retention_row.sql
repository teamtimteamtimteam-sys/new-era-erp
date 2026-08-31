CREATE OR REPLACE FUNCTION public.guard_retention_row()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_asset uuid;
    v_anchor_ok boolean;
BEGIN
    SELECT asset_id INTO v_asset
    FROM purchase_order_lines WHERE id = NEW.purchase_order_line_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PO_LINE_NOT_FOUND|%', NEW.purchase_order_line_id;
    END IF;
    IF v_asset IS NULL THEN
        RAISE EXCEPTION 'RETENTION_NOT_AN_EQUIPMENT_LINE|%', NEW.purchase_order_line_id
          USING HINT = '质保金是设备的事 —— 一条材料行没有验收,也就没有可以起算的锚';
    END IF;

    SELECT can_anchor_retention INTO v_anchor_ok
    FROM payment_trigger_events WHERE code = NEW.anchor_event;
    IF NOT COALESCE(v_anchor_ok, false) THEN
        RAISE EXCEPTION 'RETENTION_ANCHOR_HAS_NO_DATE|%', NEW.anchor_event
          USING HINT = '锚事件必须是一个系统真的记录得下日期的事件(payment_trigger_events.can_anchor_retention)—— 否则到期日算不出来,而算不出来的到期日会诱人去编一个';
    END IF;
    RETURN NEW;
END;
$function$