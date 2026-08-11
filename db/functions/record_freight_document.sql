CREATE OR REPLACE FUNCTION public.record_freight_document(p_doc_date date, p_supplier_id uuid, p_amount numeric, p_currency text, p_allocation_basis text, p_payment_status text DEFAULT 'unpaid'::text, p_bank_account text DEFAULT NULL::text, p_allocations jsonb DEFAULT NULL::jsonb, p_notes text DEFAULT NULL::text, p_gst_amount numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user      uuid := auth.uid();
    v_doc_id    uuid := gen_random_uuid();
    v_code      text;
    v_year      integer;
    v_seq       integer;
    v_fx        numeric;
    v_base      numeric;
    v_bank      text;
    v_el        jsonb;
    v_batch     record;
    v_ids       uuid[] := ARRAY[]::uuid[];
    v_units     text[];
    v_basis_tot numeric := 0;
    v_stated    numeric := 0;
    v_share     numeric;
    v_basis_qty numeric;
    v_ratio     numeric;
    v_inv_tot   numeric := 0;
    v_cost_tot  numeric := 0;
    v_alloc_tot numeric := 0;
    v_lines     jsonb := '[]'::jsonb;
    v_je        jsonb;
    v_rows      jsonb := '[]'::jsonb;
    v_last      uuid;
BEGIN
    PERFORM require_permission('module.finance.edit');

    -- ── 必填项:日期决定期间与汇率,绝不默认(FIN-10)────────────────────────
    IF p_doc_date IS NULL THEN
        RAISE EXCEPTION 'FREIGHT_DATE_REQUIRED';
    END IF;
    IF p_supplier_id IS NULL THEN
        RAISE EXCEPTION 'FREIGHT_SUPPLIER_REQUIRED';
    END IF;
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'FREIGHT_AMOUNT_INVALID';
    END IF;
    IF p_allocation_basis IS NULL OR p_allocation_basis NOT IN ('weight','value','stated') THEN
        RAISE EXCEPTION 'FREIGHT_BASIS_INVALID|%', COALESCE(p_allocation_basis, '?');
    END IF;
    IF p_allocations IS NULL OR jsonb_typeof(p_allocations) <> 'array'
       OR jsonb_array_length(p_allocations) = 0 THEN
        RAISE EXCEPTION 'FREIGHT_NO_BATCHES';
    END IF;

    -- ── GST 是一道闸门,不是一句备注 ─────────────────────────────────────────
    -- 进口 GST 是【可抵扣的进项税】(1400):资本化它会同时高估存货【并】毁掉抵扣。
    -- 今天 gst_registered = false、税率 0,所以这里直接点名拒收。
    -- 【登记之后该怎么走,写在这里而不是留给人猜】:GST 部分单独借 1400、
    -- 不参与任何分摊,只有净额进 1200/5000。
    IF p_gst_amount IS NOT NULL AND p_gst_amount <> 0 THEN
        RAISE EXCEPTION 'FREIGHT_GST_NOT_CAPITALISABLE|%', p_gst_amount;
    END IF;

    IF p_payment_status NOT IN ('paid','unpaid') THEN
        RAISE EXCEPTION 'FREIGHT_PAYMENT_STATUS_INVALID|%', p_payment_status;
    END IF;
    IF p_payment_status = 'paid' THEN
        v_bank := COALESCE(p_bank_account, bank_account_for_currency(p_currency));
        IF v_bank IS NULL THEN
            RAISE EXCEPTION 'BANK_ACCOUNT_REQUIRED';
        END IF;
    ELSE
        v_bank := NULL;
    END IF;

    -- ── 汇率:本位币免换算;外币按【单据日】的行方卖出价(我们付钱出去)──────
    IF p_currency = base_currency_code() THEN
        v_fx := 1;
    ELSE
        v_fx := fx_rate_for(p_currency, p_doc_date, 'tt_sell');
    END IF;
    v_base := round(p_amount * v_fx, 2);

    -- ── 批次集合:先取回来,顺便验单位与货值 ─────────────────────────────────
    FOR v_el IN SELECT * FROM jsonb_array_elements(p_allocations)
    LOOP
        v_last := (v_el->>'inbound_batch_id')::uuid;
        IF v_last = ANY (v_ids) THEN
            RAISE EXCEPTION 'FREIGHT_DUPLICATE_BATCH|%', v_last;
        END IF;
        SELECT ib.id, ib.code, ib.quantity, ib.unit, ib.unit_price, ib.remaining_qty
        INTO v_batch
        FROM inbound_batches ib WHERE ib.id = v_last AND ib.deleted_at IS NULL;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', COALESCE(v_last::text, '?');
        END IF;
        v_ids   := v_ids || v_batch.id;
        v_units := COALESCE(v_units, ARRAY[]::text[]) || v_batch.unit;

        IF p_allocation_basis = 'weight' THEN
            v_basis_tot := v_basis_tot + v_batch.quantity;
        ELSIF p_allocation_basis = 'value' THEN
            -- 【未计价批次:点名拒绝,不给零份额】零份额等于把它那部分运费悄悄
            -- 摊到别的批次头上,而那是一个没人看得见的错误 —— 正是资本化的代价所在。
            IF v_batch.unit_price IS NULL THEN
                RAISE EXCEPTION 'FREIGHT_BATCH_UNPRICED|%', v_batch.code;
            END IF;
            v_basis_tot := v_basis_tot + v_batch.quantity * v_batch.unit_price;
        ELSE
            IF (v_el->>'amount_base') IS NULL THEN
                RAISE EXCEPTION 'FREIGHT_STATED_AMOUNT_REQUIRED|%', v_batch.code;
            END IF;
            IF (v_el->>'amount_base')::numeric < 0 THEN
                RAISE EXCEPTION 'FREIGHT_STATED_AMOUNT_INVALID|%', v_batch.code;
            END IF;
            v_stated := v_stated + (v_el->>'amount_base')::numeric;
        END IF;
    END LOOP;

    -- weight:跨不同单位的"按重量分"没有意义 —— 拒绝,不是近似
    IF p_allocation_basis = 'weight'
       AND (SELECT count(DISTINCT u) FROM unnest(v_units) u) > 1 THEN
        RAISE EXCEPTION 'FREIGHT_MIXED_UNITS|%', array_to_string(
            ARRAY(SELECT DISTINCT u FROM unnest(v_units) u ORDER BY 1), ',');
    END IF;
    IF p_allocation_basis IN ('weight','value') AND COALESCE(v_basis_tot, 0) <= 0 THEN
        RAISE EXCEPTION 'FREIGHT_BASIS_ZERO|%', p_allocation_basis;
    END IF;
    -- stated:必须【正好】加总到单据金额。差一分就拒 —— 单据自己列明了,
    -- 对不上就是抄错了,而"差一点"在存货里同样看不见。
    IF p_allocation_basis = 'stated' AND round(v_stated, 2) <> v_base THEN
        RAISE EXCEPTION 'FREIGHT_STATED_SUM_MISMATCH|%|%', round(v_stated, 2), v_base;
    END IF;

    -- ── 无缝编号(同 EXP/JE 手法)────────────────────────────────────────────
    v_year := EXTRACT(YEAR FROM p_doc_date)::integer;
    PERFORM pg_advisory_xact_lock(hashtext('freight_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1 INTO v_seq
    FROM freight_documents WHERE code LIKE 'FRT-' || v_year::text || '-%';
    v_code := 'FRT-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');

    -- ── 单据先落地,分录号后补 ───────────────────────────────────────────────
    -- 【顺序是被外键逼出来的,不是风格】freight_allocations 的外键指向本单,
    -- 所以分摊行不可能先于单据存在。record_expense 是"先过分录再插单据",
    -- 那条顺序在这里【不成立】—— 照抄它就是第一版那个外键错。
    INSERT INTO freight_documents (id, code, doc_date, supplier_id, amount_ccy, currency,
        fx_rate, amount_base, allocation_basis, payment_status, bank_account_code,
        notes, created_by, updated_by)
    VALUES (v_doc_id, v_code, p_doc_date, p_supplier_id, p_amount, p_currency,
        v_fx, v_base, p_allocation_basis, p_payment_status, v_bank,
        p_notes, v_user, v_user);

    -- ── 逐批分摊 + 拆账 ─────────────────────────────────────────────────────
    FOR v_el IN SELECT * FROM jsonb_array_elements(p_allocations)
    LOOP
        SELECT ib.id, ib.code, ib.quantity, ib.unit_price, ib.remaining_qty
        INTO v_batch FROM inbound_batches ib WHERE ib.id = (v_el->>'inbound_batch_id')::uuid;

        IF p_allocation_basis = 'weight' THEN
            v_basis_qty := v_batch.quantity;
            v_share := round(v_base * v_batch.quantity / v_basis_tot, 2);
        ELSIF p_allocation_basis = 'value' THEN
            v_basis_qty := round(v_batch.quantity * v_batch.unit_price, 2);
            v_share := round(v_base * (v_batch.quantity * v_batch.unit_price) / v_basis_tot, 2);
        ELSE
            -- stated:金额是人直接列明的,没有可再导出的中间量 —— basis_qty 留空。
            v_basis_qty := NULL;
            v_share := round((v_el->>'amount_base')::numeric, 2);
        END IF;

        -- 【拆账比例取此刻】迟到的运费是主路径;收货即到就是 ratio = 1。
        v_ratio := CASE WHEN v_batch.quantity = 0 THEN 1
                        ELSE LEAST(1, GREATEST(0, v_batch.remaining_qty / v_batch.quantity)) END;

        INSERT INTO freight_allocations (freight_document_id, inbound_batch_id,
                                         amount_base, basis_qty, in_stock_ratio, created_by)
        VALUES (v_doc_id, v_batch.id, v_share, v_basis_qty, round(v_ratio, 6), v_user);

        v_inv_tot  := v_inv_tot + round(v_share * v_ratio, 2);
        v_cost_tot := v_cost_tot + (v_share - round(v_share * v_ratio, 2));
        v_alloc_tot := v_alloc_tot + v_share;
        v_rows := v_rows || jsonb_build_object(
            'inbound_batch_id', v_batch.id, 'batch_code', v_batch.code,
            'amount_base', v_share, 'basis_qty', v_basis_qty,
            'in_stock_ratio', round(v_ratio, 6));
    END LOOP;

    -- 取整误差归到最后一批 —— 分摊之和必须【等于】单据金额,不是约等于
    IF v_alloc_tot <> v_base THEN
        UPDATE freight_allocations
           SET amount_base = amount_base + (v_base - v_alloc_tot)
         WHERE freight_document_id = v_doc_id AND inbound_batch_id = v_last;
        SELECT in_stock_ratio INTO v_ratio FROM freight_allocations
         WHERE freight_document_id = v_doc_id AND inbound_batch_id = v_last;
        v_inv_tot  := v_inv_tot + round((v_base - v_alloc_tot) * v_ratio, 2);
        v_cost_tot := v_base - v_inv_tot;
    END IF;

    -- ── 过账。借:在库 1200 / 已耗 5000;贷:【货代】—— 已付走银行,未付走 2000 ──
    IF round(v_inv_tot, 2) <> 0 THEN
        v_lines := v_lines || jsonb_build_object('account_code', '1200', 'side', 'debit',
            'currency', base_currency_code(), 'amount_ccy', round(v_inv_tot, 2),
            'line_memo', 'freight — in-stock share');
    END IF;
    IF round(v_cost_tot, 2) <> 0 THEN
        v_lines := v_lines || jsonb_build_object('account_code', '5000', 'side', 'debit',
            'currency', base_currency_code(), 'amount_ccy', round(v_cost_tot, 2),
            'line_memo', 'freight — consumed share');
    END IF;
    v_lines := v_lines || jsonb_build_object(
        'account_code', CASE WHEN p_payment_status = 'paid' THEN v_bank ELSE '2000' END,
        'side', 'credit', 'currency', p_currency, 'amount_ccy', p_amount, 'fx_rate', v_fx,
        'line_memo', 'freight payable — forwarder');

    v_je := post_journal_entry(p_doc_date,
        'Freight ' || v_code, 'freight', v_doc_id, v_lines);

    UPDATE freight_documents SET journal_entry_id = (v_je->>'entry_id')::uuid
     WHERE id = v_doc_id;

    RETURN jsonb_build_object(
        'freight_document_id', v_doc_id, 'code', v_code,
        'amount_base', v_base, 'allocation_basis', p_allocation_basis,
        'in_stock_base', round(v_inv_tot, 2), 'consumed_base', round(v_cost_tot, 2),
        'entry_id', v_je->>'entry_id', 'allocations', v_rows);
END;
$function$;