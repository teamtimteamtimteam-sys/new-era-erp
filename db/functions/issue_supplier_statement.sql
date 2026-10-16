-- db/functions/issue_supplier_statement.sql
-- MES-8a(2026-10-16,MES-0 Q79 · MES-8 Step 0 Q7 · Q8,Tim):【签发一份供应商对账单】—— 门 module.finance.edit(签发是一个动作,比读高一档)。
--   算的那一支就是预览读的那一支(supplier_statement_data),不在这里重写。
--   ★【对不上就不签发】★ 期末按总账 2000 归到这一家的分录算;另一边是期末未结单据 − 挂账付款 − 登记的残留。两边差一分 →
--     SUPPLIER_STATEMENT_DOES_NOT_TIE|<供应商>|<差额>|<总账期末>|<单据那一边>。一份自己都对不上的对账单寄出去,是把一个内部错误变成一场供应商争议。
--   【同一段期间已经出过 → 新起一行,把旧的标掉】(Q7):必须写理由(SUPPLIER_STATEMENT_SUPERSEDE_REASON_REQUIRED|<旧号>|<供应商>);
--     没有旧的而写了理由按名拒(SUPPLIER_STATEMENT_REASON_WITHOUT_SUPERSEDE)—— 一句没有对象的理由是一句会被误读的话。
--   收件人(代码与名字)与我们的抬头一起冻进这一行 —— 没有公司法定名按名拒 SUPPLIER_STATEMENT_COMPANY_PROFILE_INCOMPLETE。
--   员工的报销永远不会有一份:p_supplier_id 只认 suppliers(SUPPLIER_NOT_FOUND)。
-- NOTE: introduced by db/migrations/2026-10-16-mes8a-supplier-scorecards-and-statements.sql.
CREATE OR REPLACE FUNCTION public.issue_supplier_statement(p_supplier_id uuid, p_from date, p_to date, p_supersede_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_d      jsonb;
    v_id     uuid := gen_random_uuid();
    v_code   text;
    v_prev   uuid;
    v_prevcd text;
    v_reason text := NULLIF(btrim(COALESCE(p_supersede_reason, '')), '');
    v_company jsonb;
BEGIN
    PERFORM require_permission('module.finance.edit');

    v_d := supplier_statement_data(p_supplier_id, p_from, p_to);

    IF (v_d ->> 'ties')::boolean IS NOT TRUE THEN
        RAISE EXCEPTION 'SUPPLIER_STATEMENT_DOES_NOT_TIE|%|%|%|%',
            (v_d ->> 'supplier_code'), (v_d ->> 'tie_difference'), (v_d ->> 'closing_base'),
            round((v_d ->> 'list_base')::numeric - (v_d ->> 'on_account_base')::numeric - (v_d ->> 'residue_base')::numeric, 2);
    END IF;

    SELECT id, code INTO v_prev, v_prevcd
      FROM supplier_statements
     WHERE supplier_id = p_supplier_id AND period_start = p_from AND period_end = p_to AND superseded_at IS NULL
     ORDER BY issued_at DESC, code DESC
     LIMIT 1
       FOR UPDATE;

    IF v_prev IS NOT NULL AND v_reason IS NULL THEN
        RAISE EXCEPTION 'SUPPLIER_STATEMENT_SUPERSEDE_REASON_REQUIRED|%|%', v_prevcd, (v_d ->> 'supplier_code');
    END IF;
    IF v_prev IS NULL AND v_reason IS NOT NULL THEN
        RAISE EXCEPTION 'SUPPLIER_STATEMENT_REASON_WITHOUT_SUPERSEDE';
    END IF;

    -- 【收件人与抬头一起冻】PDF 只从这一行渲染:没有公司法定名就不签发(一份没有我们名字的"要钱的纸"寄出去是真实事故 —— 客户对账单的同一条)
    SELECT jsonb_build_object('legal_name', cp.legal_name, 'registration_no', cp.registration_no, 'address_lines', cp.address_lines,
                              'city', cp.city, 'postal_code', cp.postal_code, 'country', cp.country, 'phone', cp.phone, 'email', cp.email,
                              'website', cp.website)
      INTO v_company FROM company_profile cp LIMIT 1;
    IF v_company IS NULL OR btrim(COALESCE(v_company ->> 'legal_name', '')) = '' THEN
        RAISE EXCEPTION 'SUPPLIER_STATEMENT_COMPANY_PROFILE_INCOMPLETE';
    END IF;

    v_code := next_supplier_statement_code(CURRENT_DATE);

    INSERT INTO supplier_statements
        (id, code, supplier_id, supplier_code, supplier_name, company, period_start, period_end, base_currency,
         opening_base, charges_base, credits_base, payments_base, prepayments_base, closing_base,
         list_base, on_account_base, residue_base, lines, open_items, on_account, unpriced, by_currency, issued_by)
    VALUES (v_id, v_code, p_supplier_id, (v_d ->> 'supplier_code'), (v_d ->> 'supplier_name'), v_company, p_from, p_to, (v_d ->> 'base_currency'),
            (v_d ->> 'opening_base')::numeric, (v_d ->> 'charges_base')::numeric, (v_d ->> 'credits_base')::numeric,
            (v_d ->> 'payments_base')::numeric, (v_d ->> 'prepayments_base')::numeric, (v_d ->> 'closing_base')::numeric,
            (v_d ->> 'list_base')::numeric, (v_d ->> 'on_account_base')::numeric, (v_d ->> 'residue_base')::numeric,
            v_d -> 'lines', v_d -> 'open_items', v_d -> 'on_account', v_d -> 'unpriced', v_d -> 'by_currency', auth.uid());

    IF v_prev IS NOT NULL THEN
        UPDATE supplier_statements
           SET superseded_at = now(), superseded_by = v_id, superseded_reason = v_reason
         WHERE id = v_prev;
    END IF;

    RETURN jsonb_build_object(
        'statement_id', v_id, 'code', v_code, 'supplier_code', (v_d ->> 'supplier_code'),
        'period_start', p_from, 'period_end', p_to, 'closing_base', (v_d ->> 'closing_base')::numeric,
        'no_movement', (v_d ->> 'no_movement')::boolean, 'superseded', v_prevcd);
END;
$function$
