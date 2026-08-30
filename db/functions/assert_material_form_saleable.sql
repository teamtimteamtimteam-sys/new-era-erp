CREATE OR REPLACE FUNCTION public.assert_material_form_saleable(p_material_id uuid)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_form text;
    v_zh   text;
    v_en   text;
BEGIN
    SELECT f.code, f.name_zh, f.name_en INTO v_form, v_zh, v_en
      FROM public.materials m
      JOIN public.material_forms f ON f.code = m.form_code
     WHERE m.id = p_material_id
       AND f.may_be_sold IS FALSE;

    IF FOUND THEN
        RAISE EXCEPTION 'SALE_FORM_NOT_SALEABLE|%|%|%', v_form, v_zh, v_en
          USING HINT = '这个形态在法律上不允许出售(R5)。这【不是】库存问题,也【不是】审批问题 —— 没有例外路径。';
    END IF;
END;
$function$
