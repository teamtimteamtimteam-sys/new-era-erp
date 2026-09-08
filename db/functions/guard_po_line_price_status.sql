CREATE OR REPLACE FUNCTION public.guard_po_line_price_status()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code text;
BEGIN
    -- 只有 'fixed' 这一个方向需要拦。标成 provisional 永远是真话:
    -- 一行【没有】公式也可以是暂定价(逐笔谈的暂定价,§6.2),那正是本刀补的能力。
    IF NEW.price_status IS DISTINCT FROM 'fixed' THEN
        RETURN NEW;
    END IF;

    IF NEW.pricing_formula_id IS NOT NULL THEN
        SELECT code INTO v_code FROM purchase_orders WHERE id = NEW.purchase_order_id;
        RAISE EXCEPTION 'PO_LINE_PRICE_STATUS_CONFLICT|%|%|%',
            COALESCE(v_code, NEW.purchase_order_id::text), NEW.line_no, 'pricing_formula'
          USING HINT = '这一行挂着计价公式 —— 它按公式结算,把它标成【定价】会在发给供应商的纸上印一句假话。要它是定价,先把公式去掉';
    END IF;

    IF EXISTS (SELECT 1 FROM pricing_term_commitments c
                WHERE c.purchase_order_line_id = NEW.id) THEN
        SELECT code INTO v_code FROM purchase_orders WHERE id = NEW.purchase_order_id;
        RAISE EXCEPTION 'PO_LINE_PRICE_STATUS_CONFLICT|%|%|%',
            COALESCE(v_code, NEW.purchase_order_id::text), NEW.line_no, 'committed_terms'
          USING HINT = '这一行已经抄下了一份结算条款(承诺定价)—— 它按那份条款结算,标成【定价】是一句假话';
    END IF;

    RETURN NEW;
END;
$function$
