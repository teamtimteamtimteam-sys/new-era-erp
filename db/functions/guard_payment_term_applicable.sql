CREATE OR REPLACE FUNCTION public.guard_payment_term_applicable()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_kind   text;
    v_ok     boolean;
    v_code   text;
    v_label  text;
BEGIN
    v_kind := purchase_order_kind(NEW.purchase_order_id);
    SELECT code INTO v_code FROM purchase_orders WHERE id = NEW.purchase_order_id;

    -- 【主语缺席这一格不许放行】没有行的单判不出种类,也就判不出这一期该不该存在。
    IF v_kind IS NULL THEN
        RAISE EXCEPTION 'PO_TERM_KIND_UNKNOWN|%', COALESCE(v_code, NEW.purchase_order_id::text)
          USING HINT = '这张单还没有明细行,判不出它是设备单还是材料单 —— 判不出就不能判定这一期的里程碑适用。先落行,再落付款计划';
    END IF;

    SELECT CASE WHEN v_kind = 'equipment' THEN applies_to_equipment ELSE applies_to_material END,
           name_zh
    INTO v_ok, v_label
    FROM payment_trigger_events WHERE code = NEW.trigger_event;

    IF NOT COALESCE(v_ok, false) THEN
        RAISE EXCEPTION 'PO_TERM_EVENT_NOT_APPLICABLE|%|%|%|%',
            COALESCE(v_code, NEW.purchase_order_id::text), NEW.seq, NEW.trigger_event, v_kind
          USING HINT = '这一种里程碑在这一类采购单上用不上 —— 例如一台机器永远不会被化验(post_assay)。可选的种类见 payment_trigger_events';
    END IF;
    RETURN NEW;
END;
$function$