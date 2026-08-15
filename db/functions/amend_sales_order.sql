CREATE OR REPLACE FUNCTION public.amend_sales_order(p_order_id uuid, p_reason text, p_header jsonb DEFAULT NULL::jsonb, p_lines jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user     uuid := auth.uid();
    v_order    sales_orders%ROWTYPE;
    v_draft    boolean;
    v_addonly  boolean;
    v_ctx      boolean;
    v_reason   text;
    v_el       jsonb;
    v_line_id  uuid;
    v_qty      numeric;
    v_price    numeric;
    v_no       integer;
    v_changed  integer := 0;
    v_status   text;
    -- 【为什么不是 FOUND】PERFORM set_config(...) 【自己会重设 FOUND】,而清标记
    -- 那一句正好夹在语句与判断之间 —— 于是 "IF NOT FOUND" 问的会是 set_config 的
    -- 结果,不是那条 DELETE/UPDATE 的。行数当场取走,再清标记。
    v_rows     integer;
BEGIN
    PERFORM require_permission('module.sales.edit');

    SELECT * INTO v_order FROM sales_orders
     WHERE id = p_order_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SO_NOT_FOUND|%', COALESCE(p_order_id::text, '?');
    END IF;

    v_draft   := (v_order.status = 'draft');
    v_addonly := (v_order.status = 'shipped');

    -- 【可改的状态,逐个写出来】closed / cancelled 一律拒:一张走完了的单、
    -- 一张作废了的单,要改就先让状态变化成为一次有记录的动作 —— 而这两个都是
    -- 终态,所以真正的答案是"另开一张"。
    IF v_order.status NOT IN ('draft', 'confirmed', 'partially_shipped', 'shipped') THEN
        RAISE EXCEPTION 'SO_NOT_AMENDABLE|%|%', v_order.code, v_order.status;
    END IF;

    -- 【shipped 只开一条缝:加行】—— 见本文件抬头。表头一个字都不能动
    -- (发完的单,它的条款已经履行完了),既有的行也不能动(每一行都在
    -- 发货与发票后面)。加一行是一件【新的承诺】,而状态会自己翻回去。
    IF v_addonly THEN
        IF p_header IS NOT NULL THEN
            RAISE EXCEPTION 'SO_NOT_AMENDABLE|%|%', v_order.code, v_order.status;
        END IF;
        IF p_lines IS NOT NULL AND jsonb_typeof(p_lines) = 'array'
           AND EXISTS (SELECT 1 FROM jsonb_array_elements(p_lines) e
                        WHERE NULLIF(e->>'id', '') IS NOT NULL) THEN
            RAISE EXCEPTION 'SO_NOT_AMENDABLE|%|%', v_order.code, v_order.status;
        END IF;
    END IF;

    -- 【理由必填 —— 但草稿不要】一次改动没有理由,历史上就只是一行"数字变了"。
    -- 草稿还不是承诺:给一件还没发生的事要一句解释,只会训练人随手敲一个句号。
    IF NOT v_draft AND (p_reason IS NULL OR btrim(p_reason) = '') THEN
        RAISE EXCEPTION 'SO_AMEND_REASON_REQUIRED|%', v_order.code;
    END IF;
    v_reason := btrim(COALESCE(p_reason, ''));

    -- 【草稿不设标记】它不需要通行证(守卫的第一个分支就放行),而留痕触发器
    -- 只在标记为 '1' 时写行 —— 于是"草稿的编辑不进改单历史"是同一个机制的推论。
    v_ctx := NOT v_draft;

    -- ── 表头:能改的只有 notes 与 terms_text ────────────────────────────────
    IF p_header IS NOT NULL AND jsonb_typeof(p_header) = 'object' THEN
        -- 【set → 语句 → 立刻清,每一条语句都这样】(PUR-2 fu2 的教训)
        -- set_config(..., true) 是【事务】局部而不是语句局部:只在函数开头设一次,
        -- 守卫会在这次调用之后、整个事务余下的时间里一直关着,一条直连的 UPDATE
        -- 就此畅通。下面重复出现的这三行不是啰嗦,它们【就是】那条规矩。
        IF v_ctx THEN
            PERFORM set_config('evoltrya.so_amend_ctx', '1', true);
            PERFORM set_config('evoltrya.so_amend_reason', v_reason, true);
        END IF;
        UPDATE sales_orders SET
            notes = CASE WHEN p_header ? 'notes'
                         THEN NULLIF(btrim(COALESCE(p_header->>'notes', '')), '') ELSE notes END,
            terms_text = CASE WHEN p_header ? 'terms_text'
                         THEN NULLIF(btrim(COALESCE(p_header->>'terms_text', '')), '') ELSE terms_text END,
            updated_at = now(), updated_by = v_user
        WHERE id = p_order_id;
        IF v_ctx THEN
            PERFORM set_config('evoltrya.so_amend_ctx', '', true);
            PERFORM set_config('evoltrya.so_amend_reason', '', true);
        END IF;
    END IF;

    -- ── 明细 ────────────────────────────────────────────────────────────────
    -- 【五列身份字段一个都不在这里】customer_id / currency / fx_rate / order_date /
    -- code 不接;行的 material_id 也不接 —— 一行的物料就是这一行本身,换掉它
    -- 等于换一行,而"换一行"在这个函数里写得出来:先 remove,再 add(两者各自
    -- 都要过下限守卫,所以这条路不会绕开任何一条规则)。
    IF p_lines IS NOT NULL AND jsonb_typeof(p_lines) = 'array' THEN
        FOR v_el IN SELECT * FROM jsonb_array_elements(p_lines)
        LOOP
            v_line_id := NULLIF(v_el->>'id', '')::uuid;

            -- 删行
            IF COALESCE((v_el->>'remove')::boolean, false) THEN
                IF v_line_id IS NULL THEN
                    RAISE EXCEPTION 'SO_LINE_REMOVE_NEEDS_ID|%', v_order.code;
                END IF;
                IF v_ctx THEN
                    PERFORM set_config('evoltrya.so_amend_ctx', '1', true);
                    PERFORM set_config('evoltrya.so_amend_reason', v_reason, true);
                END IF;
                DELETE FROM sales_order_lines
                 WHERE id = v_line_id AND sales_order_id = p_order_id;
                GET DIAGNOSTICS v_rows = ROW_COUNT;
                IF v_ctx THEN
                    PERFORM set_config('evoltrya.so_amend_ctx', '', true);
                    PERFORM set_config('evoltrya.so_amend_reason', '', true);
                END IF;
                IF v_rows = 0 THEN
                    RAISE EXCEPTION 'SO_LINE_NOT_FOUND|%', v_line_id;
                END IF;
                v_changed := v_changed + 1;
                CONTINUE;
            END IF;

            v_qty   := NULLIF(v_el->>'quantity', '')::numeric;
            v_price := NULLIF(v_el->>'unit_price', '')::numeric;

            IF v_line_id IS NULL THEN
                -- 新增行:与建单同口径(数量与单价都必须为正,CHECK 也这么写着;
                -- 点名拒而不是让约束去报 —— 表单上有二十个格子,一句"违反约束"
                -- 等于让人自己去数是哪一格,SO_CREATE_LINE_INVALID 付过这笔账)
                IF v_qty IS NULL OR v_qty <= 0 THEN
                    RAISE EXCEPTION 'SO_AMEND_LINE_INVALID|%|%',
                        COALESCE(v_el->>'line_no', '+'), 'quantity';
                END IF;
                IF v_price IS NULL OR v_price <= 0 THEN
                    RAISE EXCEPTION 'SO_AMEND_LINE_INVALID|%|%',
                        COALESCE(v_el->>'line_no', '+'), 'unit_price';
                END IF;
                IF NULLIF(v_el->>'material_id', '') IS NULL THEN
                    RAISE EXCEPTION 'SO_AMEND_LINE_INVALID|%|%',
                        COALESCE(v_el->>'line_no', '+'), 'material_id';
                END IF;
                SELECT COALESCE(MAX(line_no), 0) + 1 INTO v_no
                  FROM sales_order_lines WHERE sales_order_id = p_order_id;
                IF v_ctx THEN
                    PERFORM set_config('evoltrya.so_amend_ctx', '1', true);
                    PERFORM set_config('evoltrya.so_amend_reason', v_reason, true);
                END IF;
                -- 【price_source / price_provenance 留空,而这不是遗漏】FIN-26:
                -- 出处是【记录】的,不是事后【推断】的。改单上手敲进来的价格
                -- 没有出处可记,编一条("按当时的公式")比留空坏得多。
                INSERT INTO sales_order_lines
                    (sales_order_id, line_no, material_id, quantity, unit_price, notes)
                VALUES (p_order_id, v_no, (v_el->>'material_id')::uuid, v_qty, v_price,
                        NULLIF(btrim(COALESCE(v_el->>'notes', '')), ''));
                IF v_ctx THEN
                    PERFORM set_config('evoltrya.so_amend_ctx', '', true);
                    PERFORM set_config('evoltrya.so_amend_reason', '', true);
                END IF;
            ELSE
                -- 改行:数量与单价。三条下限由触发器把关,它看得见每一条路径。
                IF v_qty IS NULL OR v_qty <= 0 THEN
                    RAISE EXCEPTION 'SO_AMEND_LINE_INVALID|%|%',
                        COALESCE(v_el->>'line_no', v_line_id::text), 'quantity';
                END IF;
                IF v_el ? 'unit_price' AND (v_price IS NULL OR v_price <= 0) THEN
                    RAISE EXCEPTION 'SO_AMEND_LINE_INVALID|%|%',
                        COALESCE(v_el->>'line_no', v_line_id::text), 'unit_price';
                END IF;
                IF v_ctx THEN
                    PERFORM set_config('evoltrya.so_amend_ctx', '1', true);
                    PERFORM set_config('evoltrya.so_amend_reason', v_reason, true);
                END IF;
                UPDATE sales_order_lines SET
                    quantity   = v_qty,
                    unit_price = CASE WHEN v_el ? 'unit_price' THEN v_price ELSE unit_price END
                WHERE id = v_line_id AND sales_order_id = p_order_id;
                GET DIAGNOSTICS v_rows = ROW_COUNT;
                IF v_ctx THEN
                    PERFORM set_config('evoltrya.so_amend_ctx', '', true);
                    PERFORM set_config('evoltrya.so_amend_reason', '', true);
                END IF;
                IF v_rows = 0 THEN
                    RAISE EXCEPTION 'SO_LINE_NOT_FOUND|%', v_line_id;
                END IF;
            END IF;
            v_changed := v_changed + 1;
        END LOOP;
    END IF;

    -- ── 履约状态重算 ────────────────────────────────────────────────────────
    -- 【只对已经在履约里的单重算】confirmed(一件没发)重算会得到
    -- partially_shipped,那等于让改单顺手把状态往前推 —— 而那是发货干的事。
    -- 两个方向都真的会发生:
    --   * 加一行 → 一张 shipped 的单退回 partially_shipped;
    --   * 把一行改到正好等于已发(短装收尾)→ partially_shipped 变成 shipped。
    -- 【不为这次翻转另写一行历史】状态在这里是【推导出来的】,不是一次动作 ——
    -- 造成它的那次改动已经有自己的一行(line_add / line_update),再写一行
    -- "状态变了"是把一个结果记成一个决定。返回值把新状态带回去。
    v_status := v_order.status;
    IF v_order.status IN ('partially_shipped', 'shipped') THEN
        v_status := sales_order_fulfilment_status(p_order_id);
        IF v_status IS DISTINCT FROM v_order.status THEN
            PERFORM set_config('evoltrya.so_status_ctx', '1', true);
            UPDATE sales_orders
               SET status = v_status, updated_at = now(), updated_by = v_user
             WHERE id = p_order_id;
            PERFORM set_config('evoltrya.so_status_ctx', '', true);
        END IF;
    END IF;

    RETURN jsonb_build_object(
        'sales_order_id', p_order_id,
        'code', v_order.code,
        'status', v_status,
        'lines_changed', v_changed,
        -- 草稿的编辑【不进】改单历史 —— 把这件事说出来,免得调用方以为写了
        'history_written', v_ctx);
END;
$function$

;
