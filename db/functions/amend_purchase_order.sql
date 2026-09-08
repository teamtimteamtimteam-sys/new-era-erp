CREATE OR REPLACE FUNCTION public.amend_purchase_order(p_purchase_order_id uuid, p_reason text, p_header jsonb DEFAULT NULL::jsonb, p_lines jsonb DEFAULT NULL::jsonb, p_payment_terms jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user     uuid := auth.uid();
    v_po       record;
    v_el       jsonb;
    v_line_id  uuid;
    v_qty      numeric;
    v_price    numeric;
    v_price_status text;      -- PUR-1:这一行的定价状态选择
    -- ── PUR-1:付款条款 ─────────────────────────────────────────────────────
    v_term       jsonb;
    v_seq        integer;
    v_expect     integer;
    v_pct_total  numeric;
    v_new_date date;
    v_fx       numeric;
    v_total    numeric;
    v_plan_fixed numeric;
    v_plan_pct   numeric;
    v_changed  integer := 0;
    -- ── PO-GST-1:改单之后,存下来的税要跟着改过的行走 ────────────────────────
    v_gst        boolean := gst_registered();
    v_sup_tax_default text;
    v_tax_code   text;
    v_tax_rate   numeric;
BEGIN
    PERFORM require_permission('module.purchasing.edit');

    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        -- 【理由必填】一次改动没有理由,历史上就是一行"数字变了"而没有"为什么"。
        RAISE EXCEPTION 'PO_AMEND_REASON_REQUIRED';
    END IF;

    SELECT * INTO v_po FROM purchase_orders
     WHERE id = p_purchase_order_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PO_NOT_FOUND|%', COALESCE(p_purchase_order_id::text, '?');
    END IF;

    -- 【已结束 / 已作废的单不能改】先 reopen,让状态变化成为一次有记录的动作,
    -- 而不是修改的副作用。
    IF v_po.status IN ('closed','cancelled') THEN
        RAISE EXCEPTION 'PO_NOT_AMENDABLE|%|%', v_po.code, v_po.status;
    END IF;

    -- PO-GST-1:新增行要用到供应商的默认进项税码(与建单同一条播种规则)。
    SELECT default_tax_code INTO v_sup_tax_default FROM suppliers WHERE id = v_po.supplier_id;

    -- 理由传给留痕触发器(触发器读不到函数参数)
    PERFORM set_config('evoltrya.amend_reason', btrim(p_reason), true);
    PERFORM set_config('evoltrya.po_amend_ctx', '1', true);

    -- ── 表头 ────────────────────────────────────────────────────────────────
    IF p_header IS NOT NULL AND jsonb_typeof(p_header) = 'object' THEN
        v_new_date := COALESCE((p_header->>'order_date')::date, v_po.order_date);
        -- 【汇率从不由调用方递入】改单据日就要重取牌价:缺牌价即拒绝、绝不编一个。
        -- 采购是我们买外币 → tt_sell。本位币恒 1(定义,不是兜底)。
        IF v_new_date IS DISTINCT FROM v_po.order_date THEN
            IF v_po.currency = base_currency_code() THEN
                v_fx := 1;
            ELSE
                v_fx := fx_rate_for(v_po.currency, v_new_date, 'tt_sell');
            END IF;
        ELSE
            v_fx := v_po.fx_rate;
        END IF;

        UPDATE purchase_orders SET
            order_date = v_new_date,
            expected_delivery_date = CASE WHEN p_header ? 'expected_delivery_date'
                THEN (p_header->>'expected_delivery_date')::date ELSE expected_delivery_date END,
            incoterm = CASE WHEN p_header ? 'incoterm' THEN p_header->>'incoterm' ELSE incoterm END,
            terms_text = CASE WHEN p_header ? 'terms_text' THEN p_header->>'terms_text' ELSE terms_text END,
            notes = CASE WHEN p_header ? 'notes' THEN p_header->>'notes' ELSE notes END,
            -- PUR-1:交货地点。【键在不在,与值是不是空,是两件事】——
            -- 不传这个键 = 不动它;传一个空串 = 把它清掉(收成 NULL,于是纸上不印)。
            delivery_location = CASE WHEN p_header ? 'delivery_location'
                THEN NULLIF(btrim(COALESCE(p_header->>'delivery_location', '')), '')
                ELSE delivery_location END,
            fx_rate = v_fx,
            updated_by = v_user
        WHERE id = p_purchase_order_id;
    END IF;

    -- ── 明细 ────────────────────────────────────────────────────────────────
    IF p_lines IS NOT NULL AND jsonb_typeof(p_lines) = 'array' THEN
        FOR v_el IN SELECT * FROM jsonb_array_elements(p_lines)
        LOOP
            v_line_id := NULLIF(v_el->>'id', '')::uuid;

            IF COALESCE((v_el->>'remove')::boolean, false) THEN
                IF v_line_id IS NULL THEN
                    RAISE EXCEPTION 'PO_LINE_REMOVE_NEEDS_ID';
                END IF;
                -- 收过货的行删不掉 —— 守卫触发器点名拒(货真的到了,单据上却没有出处)
                DELETE FROM purchase_order_lines
                 WHERE id = v_line_id AND purchase_order_id = p_purchase_order_id;
                v_changed := v_changed + 1;
                CONTINUE;
            END IF;

            v_qty := (v_el->>'quantity')::numeric;
            -- EQP-1a-TAIL:设备行同一条规矩 —— 省略即给默认,给错则按名拒。
            IF (v_el->>'asset_id') IS NOT NULL THEN
                IF v_qty IS NULL THEN v_qty := 1; END IF;
                IF v_qty <> 1 THEN
                    RAISE EXCEPTION 'PO_LINE_EQUIPMENT_QTY|%|%', COALESCE(v_el->>'line_no','?'), v_qty
                      USING HINT = '一条设备行订的是【一台】机器 —— 四台是四条行';
                END IF;
                IF COALESCE(v_el->>'unit', 'unit') <> 'unit' THEN
                    RAISE EXCEPTION 'PO_LINE_EQUIPMENT_UNIT|%|%', COALESCE(v_el->>'line_no','?'), v_el->>'unit'
                      USING HINT = '设备行的计量单位恒为 unit —— 留空即取它';
                END IF;
            END IF;
            IF v_qty IS NULL OR v_qty <= 0 THEN
                RAISE EXCEPTION 'PO_LINE_QUANTITY_INVALID|%', COALESCE(v_el->>'line_no', '?');
            END IF;
            v_price := NULLIF(v_el->>'estimated_unit_price', '')::numeric;
            -- PUR-1:定价状态 —— 与建单同一条校验,同一个码。
            v_price_status := NULLIF(btrim(COALESCE(v_el->>'price_status', '')), '');
            IF v_price_status IS NOT NULL AND v_price_status NOT IN ('fixed', 'provisional') THEN
                RAISE EXCEPTION 'PO_LINE_PRICE_STATUS_INVALID|%|%',
                    COALESCE(v_el->>'line_no', '?'), v_price_status
                  USING HINT = '定价状态只有两个取值:fixed(定价)与 provisional(暂定价)。留空表示按事实推导';
            END IF;

            IF v_line_id IS NULL THEN
                -- 新增行:与建单同口径(金额 = 数量 × 单价,无价则 0)
                -- EQP-1a:改单也能加设备行 —— 恰一非空,与建单同一句话
                IF num_nonnulls((v_el->>'material_id')::uuid, (v_el->>'asset_id')::uuid) <> 1 THEN
                    RAISE EXCEPTION 'PO_LINE_KIND_INVALID|%', COALESCE(v_el->>'line_no', '?')
                      USING HINT = '一行要么订材料、要么订一台已建卡的设备,不能都给、也不能都不给';
                END IF;
                IF (v_el->>'asset_id') IS NOT NULL AND NOT EXISTS (
                    SELECT 1 FROM fixed_assets WHERE id = (v_el->>'asset_id')::uuid
                ) THEN
                    RAISE EXCEPTION 'ASSET_NOT_FOUND|%', v_el->>'asset_id';
                END IF;
                -- ── PO-GST-1:改单加进来的【新行】与建单同口径 ──────────────
                -- ★ 税率按【这张单的下单日】解析,不是按今天 ★ 一张单上所有的行
                -- 共用同一个日期的税率;拿今天的税率去补一条 2023 年的单上的新行,
                -- 会让同一张纸上出现两个不同的税率。
                IF v_gst THEN
                    v_tax_code := resolve_tax_code(v_el->>'tax_code', v_sup_tax_default, 'input', 'supplier');
                    v_tax_rate := tax_rate_for(v_tax_code, v_po.order_date);
                ELSE
                    IF NULLIF(btrim(COALESCE(v_el->>'tax_code', '')), '') IS NOT NULL THEN
                        RAISE EXCEPTION 'GST_NOT_REGISTERED|%', v_el->>'tax_code';
                    END IF;
                    v_tax_code := NULL; v_tax_rate := NULL;
                END IF;
                INSERT INTO purchase_order_lines (purchase_order_id, line_no, material_id, asset_id,
                    quantity, unit, estimated_unit_price, estimated_amount_ccy, notes, created_by,
                    tax_code, tax_rate_pct, tax_amount_ccy, price_status)
                VALUES (p_purchase_order_id,
                    COALESCE((v_el->>'line_no')::integer,
                        (SELECT COALESCE(MAX(line_no), 0) + 1 FROM purchase_order_lines
                          WHERE purchase_order_id = p_purchase_order_id)),
                    (v_el->>'material_id')::uuid, (v_el->>'asset_id')::uuid,
                    v_qty, COALESCE(v_el->>'unit', CASE WHEN (v_el->>'asset_id') IS NOT NULL THEN 'unit' ELSE 'kg' END),
                    v_price, round(v_qty * COALESCE(v_price, 0), 2), v_el->>'notes', v_user,
                    v_tax_code, v_tax_rate,
                    CASE WHEN v_tax_rate IS NULL THEN NULL
                         ELSE tax_amount_for(round(v_qty * COALESCE(v_price, 0), 2), v_tax_rate) END,
                    v_price_status);
            ELSE
                -- 【已收下限由触发器把关】砍到已收之下 → PO_LINE_BELOW_RECEIVED
                UPDATE purchase_order_lines SET
                    quantity = v_qty,
                    -- PUR-1:键在不在,与值是不是空,是两件事(与表头那一条同形)。
                    -- 传 '' 把它清回 NULL —— 也就是"别再替我选了,按事实推导"。
                    price_status = CASE WHEN v_el ? 'price_status'
                        THEN v_price_status ELSE price_status END,
                    unit = COALESCE(v_el->>'unit', unit),
                    estimated_unit_price = CASE WHEN v_el ? 'estimated_unit_price'
                        THEN v_price ELSE estimated_unit_price END,
                    estimated_amount_ccy = round(v_qty * COALESCE(
                        CASE WHEN v_el ? 'estimated_unit_price' THEN v_price
                             ELSE estimated_unit_price END, 0), 2),
                    -- ★★【PO-GST-1:改过的行,税跟着【新的净额】重算 —— 但税【率】
                    --     不重解析】★★ 改单改的是数量或单价,不是这一行的税务性质,
                    --     也不是这张单的日期。用行上冻着的那个 tax_rate_pct 重算,
                    --     于是 ①c 那条"存下来的税不随今天的税率漂移"在改单之后仍然成立。
                    --     【历史行(tax_rate_pct 为 NULL)保持 NULL】—— 改一改数量,
                    --     不该让一张 PO-GST-1 之前的单凭空长出一个它当时没有的税额。
                    tax_amount_ccy = CASE WHEN tax_rate_pct IS NULL THEN NULL
                        ELSE tax_amount_for(round(v_qty * COALESCE(
                            CASE WHEN v_el ? 'estimated_unit_price' THEN v_price
                                 ELSE estimated_unit_price END, 0), 2), tax_rate_pct) END
                WHERE id = v_line_id AND purchase_order_id = p_purchase_order_id;
                IF NOT FOUND THEN
                    RAISE EXCEPTION 'PO_LINE_NOT_FOUND|%', v_line_id;
                END IF;
            END IF;
            v_changed := v_changed + 1;
        END LOOP;
    END IF;

    -- ── 总额:与明细【同一条语句】算完 ───────────────────────────────────────
    -- 【顺序就是要点】这一列是 APR-2 作废触发器盯着的东西。若先改行、再另起一条
    -- 语句写总额,触发器判断时依据的总额与产生它的那批行已经不是一回事 ——
    -- 那会产生一个看起来完全正常、却基于陈旧数字的审批决定。
    -- PO-GST-1:税额合计与净额【在同一条语句里】算完 —— 理由与上面那段逐字相同
    -- (作废触发器盯着的是净额那一列,而两个数必须来自同一批行)。
    -- 【SUM 而不是 COALESCE(...,0)】全是 NULL(历史单/未注册)时合计就是 NULL,
    -- 那正是"这张单没有税"与"这张单的税是零"的区别。
    UPDATE purchase_orders po SET
        estimated_total_ccy = COALESCE(s.total, 0),
        tax_total_ccy = s.tax_total,
        updated_by = v_user
    FROM (SELECT COALESCE(SUM(estimated_amount_ccy), 0) AS total,
                 SUM(tax_amount_ccy) AS tax_total
            FROM purchase_order_lines WHERE purchase_order_id = p_purchase_order_id) s
    WHERE po.id = p_purchase_order_id;

    SELECT estimated_total_ccy INTO v_total FROM purchase_orders WHERE id = p_purchase_order_id;

    -- ════════════════════════════════════════════════════════════════════════
    -- ★★【PUR-1:改单可以改付款条款 —— 而档案接得住,那才是本段的重点】★★
    -- ════════════════════════════════════════════════════════════════════════
    --   【此前改不了,而那【不是】一道锁】(2026-09-08 实测):没有参数、没有
    --   表单字段,而 purchase_order_payment_terms 的 INSERT/UPDATE/DELETE 策略
    --   对持 module.purchasing.edit 的人【全开】—— 也就是说这条路今天就通,
    --   通的是一条直连改库、且在档案里【完全沉默】的路。
    --   留痕在触发器上(trg_po_history_payment_term),不在这里 —— 与 PUR-2 同一条:
    --   触发器接得住每一条路径,包括上面那一条。
    --
    --   ★【为什么是【按期落位】而不是整表删了重灌】★
    --     删了重灌在档案里读起来是"整份计划被换掉了",而真相常常是"第二期
    --     从 40% 改成了 30%"。按 seq 落位之后,没动过的那几期【一条历史都不长】
    --     (触发器对无改动的 UPDATE 直接返回),读的人一眼看得出改的是哪一期。
    --
    --   ★【NULL 与 [] 是两件事】★ 不传这个参数 = 不动付款计划(既有调用方
    --     一个字不用改);传一个空数组 = 把整份计划清掉,那是一次明说的动作。
    --
    --   【适用性不在这里判】trg_po_payment_terms_event_applicable 已经在表上按名拒
    --   (PO_TERM_EVENT_NOT_APPLICABLE)—— 在这里再抄一遍就是同一条规矩的第二份实现。
    IF p_payment_terms IS NOT NULL THEN
        IF jsonb_typeof(p_payment_terms) <> 'array' THEN
            RAISE EXCEPTION 'PO_PAYMENT_TERMS_INVALID|%', jsonb_typeof(p_payment_terms)
              USING HINT = '付款计划要么不传(不动它),要么传一个数组(整份计划按期落位)';
        END IF;

        -- 【先整份验完,再动一个字】—— 验到一半才拒,会留下一份改了一半的计划。
        v_expect := 0; v_pct_total := 0;
        FOR v_term IN SELECT * FROM jsonb_array_elements(p_payment_terms)
        LOOP
            v_expect := v_expect + 1;
            v_seq := (v_term->>'seq')::integer;
            -- 与建单【同一个码】:一条规矩只能有一个码,否则屏幕上会有一半的
            -- 拒绝印出裸码(EQP-PAY-1 A2 那一课)。
            IF v_seq IS DISTINCT FROM v_expect THEN
                RAISE EXCEPTION 'TERMS_SEQ_INVALID';
            END IF;
            v_pct_total := v_pct_total + COALESCE((v_term->>'percentage')::numeric, 0);
        END LOOP;
        IF v_pct_total > 100 THEN
            RAISE EXCEPTION 'TERMS_PCT_EXCEEDS|%', v_pct_total;
        END IF;

        -- 多出来的期数先删(触发器记 payment_term_remove)
        DELETE FROM purchase_order_payment_terms
         WHERE purchase_order_id = p_purchase_order_id AND seq > v_expect;

        FOR v_term IN SELECT * FROM jsonb_array_elements(p_payment_terms)
        LOOP
            INSERT INTO purchase_order_payment_terms (purchase_order_id, seq, label,
                percentage, fixed_amount_ccy, trigger_event, due_date, notes)
            VALUES (p_purchase_order_id, (v_term->>'seq')::integer, v_term->>'label',
                (v_term->>'percentage')::numeric, (v_term->>'fixed_amount_ccy')::numeric,
                v_term->>'trigger_event', (v_term->>'due_date')::date, v_term->>'notes')
            ON CONFLICT (purchase_order_id, seq) DO UPDATE SET
                label            = EXCLUDED.label,
                percentage       = EXCLUDED.percentage,
                fixed_amount_ccy = EXCLUDED.fixed_amount_ccy,
                trigger_event    = EXCLUDED.trigger_event,
                due_date         = EXCLUDED.due_date,
                notes            = EXCLUDED.notes;
            v_changed := v_changed + 1;
        END LOOP;
    END IF;

    -- ── 付款计划:定额腿必须仍然加得上 ───────────────────────────────────────
    -- 【PUR-1:这道闸现在【也】管新传进来的那份计划】—— 顺序没有变,
    -- 它读的仍然是库里此刻的计划,而上面那一段已经把新计划落位了。
    SELECT COALESCE(SUM(fixed_amount_ccy), 0), COALESCE(SUM(percentage), 0)
      INTO v_plan_fixed, v_plan_pct
      FROM purchase_order_payment_terms WHERE purchase_order_id = p_purchase_order_id;

    IF v_plan_fixed > 0 THEN
        -- 【定额腿在场:拒绝,不缩放】一条定额腿之所以是定额,正因为有人谈的是一个
        -- 数字而不是一个比例。替它按比例缩放,就是系统替操作员重新谈了一次条款,
        -- 而没有任何人被告知(与调高信用额度让告警安静同族)。
        -- 报出三个数:订单额、计划额、差额 —— 补救归操作员,而两条路都是有记录的动作。
        DECLARE
            v_plan_total numeric :=
                v_plan_fixed + round(v_total * v_plan_pct / 100.0, 2);
        BEGIN
            IF round(v_plan_total, 2) <> round(v_total, 2) THEN
                RAISE EXCEPTION 'PO_PLAN_FIXED_MISMATCH|%|%|%',
                    round(v_total, 2), round(v_plan_total, 2),
                    round(v_plan_total - v_total, 2);
            END IF;
        END;
    END IF;
    -- 【比例计划不在此列,而且这不是遗漏】百分比的意思就是"订单的这一份",
    -- 它按构造跟着总额走;定额的意思是"这么多钱",只有它需要被拦住。

    PERFORM set_config('evoltrya.po_amend_ctx', '', true);
    PERFORM set_config('evoltrya.amend_reason', '', true);

    RETURN jsonb_build_object(
        'purchase_order_id', p_purchase_order_id,
        'code', v_po.code,
        'lines_changed', v_changed,
        'estimated_total_ccy', v_total,
        'approval_status', (SELECT approval_status FROM purchase_orders WHERE id = p_purchase_order_id));
END;
$function$
