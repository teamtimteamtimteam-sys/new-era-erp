CREATE OR REPLACE FUNCTION public.amend_work_order(p_work_order_id uuid, p_reason text, p_scheduled_date date DEFAULT NULL::date, p_set_scheduled boolean DEFAULT false, p_notes text DEFAULT NULL::text, p_set_notes boolean DEFAULT false, p_lines jsonb DEFAULT NULL::jsonb, p_expected jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user     uuid := auth.uid();
    v_wo       work_orders%ROWTYPE;
    v_elem     jsonb;
    v_line     work_order_lines%ROWTYPE;
    v_exp      work_order_expected_outputs%ROWTYPE;
    v_basis    text;   -- PROC-SUPPORT-1(R3):这一条预期产出的出处
    v_ref      text;   -- 同上,凭据(自由文本)
    v_mat      uuid;
    v_qty      numeric;
    v_consumed numeric;
    v_changes  integer := 0;
BEGIN
    PERFORM require_permission('module.processing.edit');
    SELECT * INTO v_wo FROM work_orders WHERE id = p_work_order_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'WO_NOT_FOUND|%', COALESCE(p_work_order_id::text, '?');
    END IF;
    IF v_wo.status NOT IN ('draft','released') THEN
        RAISE EXCEPTION 'WO_NOT_AMENDABLE|%|%', v_wo.code, v_wo.status;
    END IF;
    -- 【理由必填,而且在动手之前就问】—— 一次没有理由的计划改动,过两天没人
    -- 说得清当时是为了什么(与 hold_stock 的 STK_REASON_REQUIRED 同一条)。
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'WO_AMEND_REASON_REQUIRED|%', v_wo.code;
    END IF;

    -- ── 表头 ────────────────────────────────────────────────────────────────
    -- 【为什么要 p_set_* 这个布尔】NULL 在这里有两个意思:"不改这一项"与
    -- "把它清空"。少了这个开关,"取消排期"就表达不出来 —— 而取消排期是一件
    -- 真实的事(计划推迟到不知道什么时候)。
    IF p_set_scheduled AND p_scheduled_date IS DISTINCT FROM v_wo.scheduled_date THEN
        INSERT INTO work_order_history (work_order_id, change_type,
                    old_scheduled_date, new_scheduled_date, amend_reason, changed_by)
        VALUES (p_work_order_id, 'header_update', v_wo.scheduled_date, p_scheduled_date,
                btrim(p_reason), v_user);
        UPDATE work_orders SET scheduled_date = p_scheduled_date WHERE id = p_work_order_id;
        v_changes := v_changes + 1;
    END IF;
    IF p_set_notes AND NULLIF(btrim(COALESCE(p_notes,'')),'') IS DISTINCT FROM v_wo.notes THEN
        INSERT INTO work_order_history (work_order_id, change_type,
                    old_notes, new_notes, amend_reason, changed_by)
        VALUES (p_work_order_id, 'header_update', v_wo.notes,
                NULLIF(btrim(COALESCE(p_notes,'')),''), btrim(p_reason), v_user);
        UPDATE work_orders SET notes = NULLIF(btrim(COALESCE(p_notes,'')),'')
         WHERE id = p_work_order_id;
        v_changes := v_changes + 1;
    END IF;

    -- ── 计划投料行 ──────────────────────────────────────────────────────────
    -- 每个元素:{material_id, planned_qty}。planned_qty 省略或为 null = 删这一行。
    IF p_lines IS NOT NULL AND jsonb_typeof(p_lines) = 'array' THEN
        FOR v_elem IN SELECT * FROM jsonb_array_elements(p_lines)
        LOOP
            v_mat := (v_elem->>'material_id')::uuid;
            IF v_mat IS NULL OR NOT EXISTS (
                SELECT 1 FROM materials WHERE id = v_mat AND deleted_at IS NULL) THEN
                RAISE EXCEPTION 'WO_MATERIAL_NOT_FOUND|%', COALESCE(v_mat::text, '?');
            END IF;
            v_qty := (v_elem->>'planned_qty')::numeric;

            -- 【地板:已经吃掉的量】—— 挂在这张工单上的加工单,吃掉了多少这种料。
            -- 投料腿指向批次,批次才有物料,所以两侧都要 join 过去(进料批与
            -- 再加工的产出批各一条腿,FIN-25 的 XOR)。
            SELECT COALESCE(sum(pi.quantity_consumed), 0) INTO v_consumed
              FROM processing_runs r
              JOIN processing_inputs pi ON pi.run_id = r.id
              LEFT JOIN inbound_batches ib ON ib.id = pi.inbound_batch_id
              LEFT JOIN output_batches  ob ON ob.id = pi.output_batch_id
             WHERE r.work_order_id = p_work_order_id
               AND r.deleted_at IS NULL
               AND r.status = 'committed'
               AND COALESCE(ib.material_id, ob.material_id) = v_mat;

            SELECT * INTO v_line FROM work_order_lines
             WHERE work_order_id = p_work_order_id AND material_id = v_mat;

            IF v_qty IS NULL THEN
                -- 删行
                IF NOT FOUND THEN
                    RAISE EXCEPTION 'WO_LINE_NOT_FOUND|%', v_mat;
                END IF;
                -- 【删掉一条已经吃过料的行,与把它改成 0 是同一件事】所以同一道地板
                IF v_consumed > 0 THEN
                    RAISE EXCEPTION 'WO_LINE_BELOW_CONSUMED|%|%|%', v_mat, 0, v_consumed;
                END IF;
                INSERT INTO work_order_history (work_order_id, change_type, work_order_line_id,
                            material_id, old_qty, new_qty, amend_reason, changed_by)
                VALUES (p_work_order_id, 'line_remove', v_line.id, v_mat,
                        v_line.planned_qty, NULL, btrim(p_reason), v_user);
                DELETE FROM work_order_lines WHERE id = v_line.id;
                v_changes := v_changes + 1;
            ELSIF v_qty <= 0 THEN
                RAISE EXCEPTION 'WO_LINE_QTY_INVALID';
            ELSIF NOT FOUND THEN
                -- 加行
                INSERT INTO work_order_lines (work_order_id, material_id, planned_qty)
                VALUES (p_work_order_id, v_mat, v_qty) RETURNING * INTO v_line;
                INSERT INTO work_order_history (work_order_id, change_type, work_order_line_id,
                            material_id, old_qty, new_qty, amend_reason, changed_by)
                VALUES (p_work_order_id, 'line_add', v_line.id, v_mat, NULL, v_qty,
                        btrim(p_reason), v_user);
                v_changes := v_changes + 1;
            ELSIF v_qty IS DISTINCT FROM v_line.planned_qty THEN
                -- 改量 —— 地板在这里
                IF v_qty < v_consumed THEN
                    RAISE EXCEPTION 'WO_LINE_BELOW_CONSUMED|%|%|%', v_mat, v_qty, v_consumed;
                END IF;
                INSERT INTO work_order_history (work_order_id, change_type, work_order_line_id,
                            material_id, old_qty, new_qty, amend_reason, changed_by)
                VALUES (p_work_order_id, 'line_update', v_line.id, v_mat,
                        v_line.planned_qty, v_qty, btrim(p_reason), v_user);
                UPDATE work_order_lines SET planned_qty = v_qty WHERE id = v_line.id;
                v_changes := v_changes + 1;
            END IF;
        END LOOP;
    END IF;

    -- ── 预期产出行 ──────────────────────────────────────────────────────────
    -- 【预期产出没有地板】它是一句估计,不是一个已经发生的事实 —— 改小它不会
    -- 与任何已经发生的事情矛盾。这与计划投料行刻意不同,而不同的理由值得写下来:
    -- 地板护的是"实绩不可否认",预期产出这一侧没有实绩可否认。
    IF p_expected IS NOT NULL AND jsonb_typeof(p_expected) = 'array' THEN
        FOR v_elem IN SELECT * FROM jsonb_array_elements(p_expected)
        LOOP
            v_mat := (v_elem->>'material_id')::uuid;
            IF v_mat IS NULL OR NOT EXISTS (
                SELECT 1 FROM materials WHERE id = v_mat AND deleted_at IS NULL) THEN
                RAISE EXCEPTION 'WO_EXPECTED_MATERIAL_NOT_FOUND|%', COALESCE(v_mat::text, '?');
            END IF;
            v_qty := (v_elem->>'expected_qty')::numeric;
            -- PROC-SUPPORT-1(R3):出处。**改一行预期产出时它是可选的** ——
            -- 不给就是"这一次不改出处",给了就必须是三个取值之一。
            -- 【新增一行时它是必填的】,那一条在下面的 add 分支里。
            v_basis := NULLIF(btrim(COALESCE(v_elem->>'basis','')), '');
            v_ref   := NULLIF(btrim(COALESCE(v_elem->>'basis_reference','')), '');
            IF v_basis IS NOT NULL
               AND v_basis NOT IN ('planner_estimate','seeded_industry','calibrated') THEN
                RAISE EXCEPTION 'WO_EXPECTED_BASIS_REQUIRED'
                  USING HINT = '出处只有三个取值:planner_estimate / seeded_industry / calibrated。';
            END IF;
            SELECT * INTO v_exp FROM work_order_expected_outputs
             WHERE work_order_id = p_work_order_id AND material_id = v_mat;

            IF v_qty IS NULL THEN
                IF NOT FOUND THEN
                    RAISE EXCEPTION 'WO_EXPECTED_NOT_FOUND|%', v_mat;
                END IF;
                INSERT INTO work_order_history (work_order_id, change_type, work_order_expected_id,
                            material_id, old_qty, new_qty, amend_reason, changed_by)
                VALUES (p_work_order_id, 'expected_remove', v_exp.id, v_mat,
                        v_exp.expected_qty, NULL, btrim(p_reason), v_user);
                DELETE FROM work_order_expected_outputs WHERE id = v_exp.id;
                v_changes := v_changes + 1;
            ELSIF v_qty <= 0 THEN
                RAISE EXCEPTION 'WO_EXPECTED_QTY_INVALID';
            ELSIF NOT FOUND THEN
                -- PROC-SUPPORT-1(R3):**新增一行必须说出出处。**
                IF v_basis IS NULL THEN
                    RAISE EXCEPTION 'WO_EXPECTED_BASIS_REQUIRED'
                      USING HINT = '新增一条预期产出要说出它是怎么来的:排计划的人估的、照行业经验播的、还是对着真实生产校准过的。';
                END IF;
                INSERT INTO work_order_expected_outputs (work_order_id, material_id, expected_qty, basis, basis_reference)
                VALUES (p_work_order_id, v_mat, v_qty, v_basis, v_ref) RETURNING * INTO v_exp;
                INSERT INTO work_order_history (work_order_id, change_type, work_order_expected_id,
                            material_id, old_qty, new_qty, amend_reason, changed_by)
                VALUES (p_work_order_id, 'expected_add', v_exp.id, v_mat, NULL, v_qty,
                        btrim(p_reason), v_user);
                v_changes := v_changes + 1;
            ELSIF v_qty IS DISTINCT FROM v_exp.expected_qty
                  OR (v_basis IS NOT NULL AND v_basis IS DISTINCT FROM v_exp.basis)
                  OR (jsonb_exists(v_elem, 'basis_reference')
                      AND v_ref IS DISTINCT FROM v_exp.basis_reference) THEN
                -- ════════════════════════════════════════════════════════════
                -- PROC-SUPPORT-1(R3):**改出处也算一次改动,而且要留痕。**
                -- 一个数从 seeded_industry 变成 calibrated,是这张表上
                -- 【最重要】的一次变化 —— 那是"猜的"变成"验证过的"那一刻。
                -- 让它悄悄发生,六个月后就没有人说得出它是什么时候变的。
                -- 【出处的新旧值写进 detail】—— old_qty/new_qty 那一对是给数字的,
                -- 借用它去装文本会让那一对的含义在第二种用法上就开始漂。
                -- ════════════════════════════════════════════════════════════
                INSERT INTO work_order_history (work_order_id, change_type, work_order_expected_id,
                            material_id, old_qty, new_qty, amend_reason, changed_by, detail)
                VALUES (p_work_order_id, 'expected_update', v_exp.id, v_mat,
                        v_exp.expected_qty, v_qty, btrim(p_reason), v_user,
                        CASE WHEN v_basis IS NOT NULL AND v_basis IS DISTINCT FROM v_exp.basis
                             THEN format('basis: %s -> %s', COALESCE(v_exp.basis, '(none stated)'), v_basis)
                        END);
                UPDATE work_order_expected_outputs
                   SET expected_qty    = v_qty,
                       basis           = COALESCE(v_basis, basis),
                       basis_reference = CASE WHEN jsonb_exists(v_elem, 'basis_reference')
                                              THEN v_ref ELSE basis_reference END
                 WHERE id = v_exp.id;
                v_changes := v_changes + 1;
            END IF;
        END LOOP;
    END IF;

    IF v_changes = 0 THEN
        RAISE EXCEPTION 'WO_AMEND_NO_CHANGES|%', v_wo.code;
    END IF;

    UPDATE work_orders SET updated_at = now(), updated_by = v_user WHERE id = p_work_order_id;
    RETURN jsonb_build_object('work_order_id', p_work_order_id, 'code', v_wo.code,
                              'changes', v_changes);
END;
$function$

