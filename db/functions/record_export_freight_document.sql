CREATE OR REPLACE FUNCTION public.record_export_freight_document(p_doc_date date, p_supplier_id uuid, p_amount numeric, p_currency text, p_payment_status text DEFAULT 'unpaid'::text, p_bank_account text DEFAULT NULL::text, p_container_id uuid DEFAULT NULL::uuid, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user   uuid := auth.uid();
    v_doc_id uuid := gen_random_uuid();
    v_code   text;
    v_year   integer;
    v_seq    integer;
    v_fx     numeric;
    v_base   numeric;
    v_bank   text;
    v_ctr    text;
    v_lines  jsonb := '[]'::jsonb;
    v_je     jsonb;
BEGIN
    PERFORM require_permission('module.finance.edit');

    -- ── 必填项,与进料侧同一条规矩(FIN-10):日期决定期间与汇率,绝不默认 ────
    IF p_doc_date IS NULL THEN
        RAISE EXCEPTION 'FREIGHT_DATE_REQUIRED';
    END IF;
    IF p_supplier_id IS NULL THEN
        RAISE EXCEPTION 'FREIGHT_SUPPLIER_REQUIRED';
    END IF;
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'FREIGHT_AMOUNT_INVALID';
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

    -- ── 箱子可空;【指了就必须指得中】────────────────────────────────────────
    -- 单据是钱的对象(Tim 定),所以不指也成立:货代一张账单可能覆盖几个箱子,
    -- 也可能在箱子建档之前就到。但指向一个不存在或已注销的箱子,是一条
    -- 【看起来有出处、其实没有】的记录 —— 那比不指更坏。
    IF p_container_id IS NOT NULL THEN
        SELECT code INTO v_ctr FROM containers
         WHERE id = p_container_id AND deleted_at IS NULL;
        IF v_ctr IS NULL THEN
            RAISE EXCEPTION 'EXPORT_FREIGHT_CONTAINER_NOT_FOUND|%', p_container_id
              USING HINT = '这个箱子不存在,或者已经注销了 —— 指向它的运费单会带着一个查不回去的出处';
        END IF;
    END IF;

    -- ── 汇率:与进料侧【同一条】—— 单据日的行方卖出价(我们付钱出去)─────────
    IF p_currency = base_currency_code() THEN
        v_fx := 1;
    ELSE
        v_fx := fx_rate_for(p_currency, p_doc_date, 'tt_sell');
    END IF;
    v_base := round(p_amount * v_fx, 2);

    -- ── 无缝编号:【与进料侧同一个 FRT- 号段】(Tim 定)。同一把 advisory 锁,
    --    所以两个方向并发取号也不会撞 —— 号段是一条,不是两条。
    v_year := EXTRACT(YEAR FROM p_doc_date)::integer;
    PERFORM pg_advisory_xact_lock(hashtext('freight_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1 INTO v_seq
    FROM freight_documents WHERE code LIKE 'FRT-' || v_year::text || '-%';
    v_code := 'FRT-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');

    -- allocation_basis 在本表是 NOT NULL,而出境单据【没有分摊】。
    -- 'stated' 是三个取值里唯一一个不意味着"由系统算一个分法"的:它的意思是
    -- "金额是人直接列明的,没有可再导出的中间量" —— 对一张不分摊的单据,
    -- 这恰好是真话。写 'weight' 或 'value' 才是编造一个从未发生的口径。
    INSERT INTO freight_documents (id, code, doc_date, supplier_id, amount_ccy, currency,
        fx_rate, amount_base, allocation_basis, payment_status, bank_account_code,
        notes, created_by, updated_by, direction, container_id)
    VALUES (v_doc_id, v_code, p_doc_date, p_supplier_id, p_amount, p_currency,
        v_fx, v_base, 'stated', p_payment_status, v_bank,
        p_notes, v_user, v_user, 'outbound', p_container_id);

    -- ── 过账:借 6300(运输物流费,expense)/ 贷 2000 或银行 ─────────────────
    -- 【1200 与 5000 在这个函数里一次都没有出现】,这不是巧合,是本刀的全部内容。
    -- 出口运费不是落地成本:它没有一个"这批货还剩多少在库"可读,
    -- 也没有一个批次该背它 —— 给它编一个,就是把它藏进存货。
    v_lines := jsonb_build_array(
        jsonb_build_object('account_code', '6300', 'side', 'debit',
            'currency', base_currency_code(), 'amount_ccy', v_base,
            'line_memo', 'export freight' || COALESCE(' — ' || v_ctr, '')),
        jsonb_build_object(
            'account_code', CASE WHEN p_payment_status = 'paid' THEN v_bank ELSE '2000' END,
            'side', 'credit', 'currency', p_currency, 'amount_ccy', p_amount, 'fx_rate', v_fx,
            'line_memo', 'export freight payable — forwarder'));

    v_je := post_journal_entry(p_doc_date,
        'Export freight ' || v_code, 'freight', v_doc_id, v_lines);

    UPDATE freight_documents SET journal_entry_id = (v_je->>'entry_id')::uuid
     WHERE id = v_doc_id;

    RETURN jsonb_build_object(
        'freight_document_id', v_doc_id, 'code', v_code, 'direction', 'outbound',
        'amount_base', v_base, 'expense_account', '6300',
        'container_id', p_container_id, 'container_code', v_ctr,
        'entry_id', v_je->>'entry_id');
END;
$function$

