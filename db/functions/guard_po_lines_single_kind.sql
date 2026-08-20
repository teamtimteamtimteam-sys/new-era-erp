CREATE OR REPLACE FUNCTION public.guard_po_lines_single_kind()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE v_mat int; v_ast int; v_code text;
BEGIN
    SELECT count(*) FILTER (WHERE material_id IS NOT NULL),
           count(*) FILTER (WHERE asset_id IS NOT NULL)
      INTO v_mat, v_ast
      FROM public.purchase_order_lines
     WHERE purchase_order_id = NEW.purchase_order_id;

    IF v_mat > 0 AND v_ast > 0 THEN
        SELECT code INTO v_code FROM public.purchase_orders WHERE id = NEW.purchase_order_id;
        RAISE EXCEPTION 'PO_LINES_MIXED_KINDS|%|%|%', COALESCE(v_code,'?'), v_mat, v_ast
          USING HINT = '一张采购单要么全是材料行,要么全是设备行 —— 混装会让"订购量"变成一个把公斤和台数加在一起的数';
    END IF;
    RETURN NULL;
END;
$function$

