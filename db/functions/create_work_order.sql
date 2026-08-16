CREATE OR REPLACE FUNCTION public.create_work_order(p_lines jsonb, p_expected jsonb DEFAULT NULL::jsonb, p_scheduled_date date DEFAULT NULL::date, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_id   uuid;
    v_code text;
    v_elem jsonb;
    v_mat  uuid;
    v_qty  numeric;
BEGIN
    PERFORM require_permission('module.processing.edit');

    -- 【拒绝的顺序就是"人下一步该改什么"的顺序】两条同时不成立时,先说哪一条
    -- 决定了他打开哪个输入框(与 record_invoice_issue 的四条同一条道理)。
    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'WO_NO_LINES';
    END IF;

    -- 投料行:先把每一行自己看一遍,再看行与行之间
    FOR v_elem IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        v_qty := (v_elem->>'planned_qty')::numeric;
        IF v_qty IS NULL OR v_qty <= 0 THEN
            RAISE EXCEPTION 'WO_LINE_QTY_INVALID';
        END IF;
        v_mat := (v_elem->>'material_id')::uuid;
        IF v_mat IS NULL OR NOT EXISTS (
            SELECT 1 FROM materials WHERE id = v_mat AND deleted_at IS NULL) THEN
            RAISE EXCEPTION 'WO_MATERIAL_NOT_FOUND|%', COALESCE(v_mat::text, '?');
        END IF;
    END LOOP;
    -- 【重复物料按名拒,而不是靠唯一约束抛 23505】约束是兜底,不是文案:
    -- 一条 duplicate key value violates unique constraint 到不了人眼里就是机器串。
    SELECT (elem->>'material_id')::uuid INTO v_mat
      FROM jsonb_array_elements(p_lines) elem
     GROUP BY 1 HAVING count(*) > 1 LIMIT 1;
    IF v_mat IS NOT NULL THEN
        RAISE EXCEPTION 'WO_DUPLICATE_MATERIAL|%', v_mat;
    END IF;

    -- 预期产出:【可以整个不给】—— 没有预期是一种诚实的状态,不是缺失。
    IF p_expected IS NOT NULL AND jsonb_typeof(p_expected) = 'array'
       AND jsonb_array_length(p_expected) > 0 THEN
        FOR v_elem IN SELECT * FROM jsonb_array_elements(p_expected)
        LOOP
            v_qty := (v_elem->>'expected_qty')::numeric;
            IF v_qty IS NULL OR v_qty <= 0 THEN
                RAISE EXCEPTION 'WO_EXPECTED_QTY_INVALID';
            END IF;
            v_mat := (v_elem->>'material_id')::uuid;
            IF v_mat IS NULL OR NOT EXISTS (
                SELECT 1 FROM materials WHERE id = v_mat AND deleted_at IS NULL) THEN
                RAISE EXCEPTION 'WO_EXPECTED_MATERIAL_NOT_FOUND|%', COALESCE(v_mat::text, '?');
            END IF;
        END LOOP;
        SELECT (elem->>'material_id')::uuid INTO v_mat
          FROM jsonb_array_elements(p_expected) elem
         GROUP BY 1 HAVING count(*) > 1 LIMIT 1;
        IF v_mat IS NOT NULL THEN
            RAISE EXCEPTION 'WO_DUPLICATE_EXPECTED|%', v_mat;
        END IF;
    END IF;

    v_code := next_work_order_code(COALESCE(p_scheduled_date, CURRENT_DATE));
    -- 【注意这个 COALESCE 是给【年份】用的,不是给 scheduled_date 用的】
    -- 存进表里的仍然是 p_scheduled_date 本身(可以是 NULL)。取号要一个年份,
    -- 而"没排期"的单子只能落在今年 —— 这与"永不给日期默认值"不冲突:
    -- 被默认的是号码的年段,不是那句对外的承诺。
    INSERT INTO work_orders (code, status, scheduled_date, notes, created_by, updated_by)
    VALUES (v_code, 'draft', p_scheduled_date, NULLIF(btrim(COALESCE(p_notes,'')), ''), v_user, v_user)
    RETURNING id INTO v_id;

    INSERT INTO work_order_lines (work_order_id, material_id, planned_qty)
    SELECT v_id, (elem->>'material_id')::uuid, (elem->>'planned_qty')::numeric
      FROM jsonb_array_elements(p_lines) elem;

    IF p_expected IS NOT NULL AND jsonb_typeof(p_expected) = 'array'
       AND jsonb_array_length(p_expected) > 0 THEN
        INSERT INTO work_order_expected_outputs (work_order_id, material_id, expected_qty)
        SELECT v_id, (elem->>'material_id')::uuid, (elem->>'expected_qty')::numeric
          FROM jsonb_array_elements(p_expected) elem;
    END IF;

    INSERT INTO work_order_history (work_order_id, change_type, detail, changed_by)
    VALUES (v_id, 'created', v_code, v_user);

    RETURN jsonb_build_object('work_order_id', v_id, 'code', v_code, 'status', 'draft');
END;
$function$

;
