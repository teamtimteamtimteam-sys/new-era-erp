-- db/functions/create_output_batch.sql
-- MES-3a(2026-10-06,MES-3a Step 0 Q9 · Q10,Tim):手工建一批产出 = 料从外面进厂(加工出来的产出批不走这里)——
--   落库之后对着执照的库存上限判一次并记下来(receipt_ceiling_check_internal),超过给了的上限按名拒。
--   隔离闸不在这里:产出批建出来时身上没有状态(状态在产出批页面上记)。签名不变;返回值多一个 'ceiling'。

CREATE OR REPLACE FUNCTION public.create_output_batch(p_material_id uuid, p_quantity numeric, p_unit text DEFAULT 'kg'::text, p_output_date date DEFAULT NULL::date, p_state text DEFAULT '库存中'::text, p_customer_id uuid DEFAULT NULL::uuid, p_purity text DEFAULT NULL::text, p_notes text DEFAULT NULL::text, p_location_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_id   uuid;
    v_warn text[];
    v_ceiling jsonb;
BEGIN
    PERFORM require_permission('module.output.edit');

    -- IOD-2-fu1:产出日【按名】必填 —— 手走就是在这一条上看见了约束原文。
    IF p_output_date IS NULL THEN
        RAISE EXCEPTION 'OUTPUT_DATE_REQUIRED';
    END IF;

    PERFORM set_config('evoltrya.location_ctx',
                       COALESCE(resolve_receipt_location(p_location_id)::text, ''), true);

    -- IOD-2:落闸,写入之前。
    v_warn := check_location_class(p_location_id, p_material_id);
    -- NTF-1:告警留一份下来 —— 此前它渲染一次就没了,连响过的痕迹都没有。
    PERFORM notify_landing_warnings(v_warn, p_location_id, p_material_id);

    INSERT INTO output_batches (
        material_id, customer_id, quantity, unit, remaining_qty, output_date,
        state, purity, notes, created_by, updated_by)
    VALUES (
        p_material_id, p_customer_id, p_quantity, COALESCE(p_unit,'kg'), p_quantity, p_output_date,
        COALESCE(p_state,'库存中'), p_purity, p_notes, v_user, v_user)
    RETURNING id INTO v_id;

    PERFORM set_config('evoltrya.location_ctx', '', true);

    -- MES-3a:库存上限(见文件抬头)。落库之后判 —— 这一批的入库流水已经在存量里。
    v_ceiling := receipt_ceiling_check_internal(NULL, v_id);
    RETURN jsonb_build_object('batch_id', v_id, 'warnings', to_jsonb(v_warn), 'ceiling', v_ceiling);
END;
$function$

;
