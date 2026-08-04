-- db/migrations/2026-08-04-fin6-relieve-processing-accruals.sql
-- FIN-6:2200 的加工成本应计,沿 schema 早已带着的缝(is_estimate)各走各的路:
--   实际额(false)= 应付,FIN-5 形状的汇付(remit_processing_costs,一笔一条银行行);
--   估算(true)  = 真实发票冲抵(relieve_processing_accruals):借 2200 清应计,
--                  差额进【发票所在期间】该类型的 5xxx 损益行,贷 银行/应付记实际。
--
-- 【差异不回摊到批次 —— 既定,别把它"修"成不一致】
-- 化验(assay)改的是那一批自己的料价,回摊天经地义;水电账单是横跨整月多个 run
-- 的公摊,它的估算差异不属于任何单一批次 —— 批次毛利就留在估算口径上。
-- 谁要是想让它"和 reprice 一致",先读这段:两者本来就不该一致。
--
-- 防重复是结构性的:发票只从 relieve 进账(record_expense 一直拒收 5xxx ——
-- ACCOUNT_NOT_EXPENSE,5xxx 是 cogs 型);结过的行改不动(guard 触发器)、清不了第二次。
BEGIN;

ALTER TABLE public.processing_cost_entries ADD COLUMN remitted_at date;
ALTER TABLE public.processing_cost_entries ADD COLUMN remitted_journal_entry_id uuid REFERENCES public.journal_entries (id);
ALTER TABLE public.processing_cost_entries ADD COLUMN relieved_at date;
ALTER TABLE public.processing_cost_entries ADD COLUMN relief_expense_id uuid REFERENCES public.expenses (id);

CREATE OR REPLACE FUNCTION public.guard_cost_entry_settled()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF (OLD.remitted_at IS NOT NULL OR OLD.relieved_at IS NOT NULL)
       AND (NEW.amount_base IS DISTINCT FROM OLD.amount_base
            OR NEW.deleted_at IS DISTINCT FROM OLD.deleted_at
            OR NEW.cost_type IS DISTINCT FROM OLD.cost_type
            OR NEW.is_estimate IS DISTINCT FROM OLD.is_estimate) THEN
        RAISE EXCEPTION 'COST_ENTRY_SETTLED|%', OLD.cost_type;
    END IF;
    RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_processing_cost_entries_settled_guard
    BEFORE UPDATE ON public.processing_cost_entries
    FOR EACH ROW EXECUTE FUNCTION public.guard_cost_entry_settled();


CREATE OR REPLACE FUNCTION public.remit_processing_costs(p_entry_ids uuid[], p_payment_date date DEFAULT NULL::date, p_bank_account text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_total numeric := 0;
    v_n int := 0;
    v_e record;
    v_bank text;
    v_date date;
    v_je jsonb;
BEGIN
    PERFORM require_permission('module.finance.edit');
    IF p_entry_ids IS NULL OR array_length(p_entry_ids, 1) IS NULL THEN
        RAISE EXCEPTION 'NO_LINES';
    END IF;
    v_bank := COALESCE(p_bank_account, '1000');
    IF v_bank NOT IN ('1000','1010') THEN RAISE EXCEPTION 'BANK_INVALID|%', v_bank; END IF;
    v_date := COALESCE(p_payment_date, CURRENT_DATE);

    FOR v_e IN SELECT * FROM processing_cost_entries WHERE id = ANY (p_entry_ids) FOR UPDATE
    LOOP
        IF v_e.deleted_at IS NOT NULL THEN RAISE EXCEPTION 'COST_ENTRY_INVALID|%', v_e.id; END IF;
        IF v_e.is_estimate THEN RAISE EXCEPTION 'COST_ENTRY_IS_ESTIMATE|%', v_e.cost_type; END IF;
        IF v_e.remitted_at IS NOT NULL OR v_e.relieved_at IS NOT NULL THEN
            RAISE EXCEPTION 'COST_ENTRY_ALREADY_SETTLED|%', v_e.cost_type;
        END IF;
        v_total := round(v_total + v_e.amount_base, 2);
        v_n := v_n + 1;
    END LOOP;
    IF v_n = 0 OR v_total <= 0 THEN RAISE EXCEPTION 'NO_LINES'; END IF;

    v_je := post_journal_entry(v_date, 'Processing cost remittance', 'processing_cost', NULL,
        jsonb_build_array(
            jsonb_build_object('account_code', '2200', 'side', 'debit', 'currency', 'SGD',
                               'amount_ccy', v_total, 'fx_rate', 1),
            jsonb_build_object('account_code', v_bank, 'side', 'credit', 'currency', 'SGD',
                               'amount_ccy', v_total, 'fx_rate', 1)));

    UPDATE processing_cost_entries
    SET remitted_at = v_date, remitted_journal_entry_id = (v_je->>'entry_id')::uuid
    WHERE id = ANY (p_entry_ids);

    RETURN jsonb_build_object('journal_code', v_je->>'code', 'entries', v_n, 'total', v_total);
END;
$function$;

CREATE OR REPLACE FUNCTION public.relieve_processing_accruals(p_entry_ids uuid[], p_actual_amount numeric, p_expense_date date, p_payment_status text DEFAULT 'paid'::text, p_bank_account text DEFAULT NULL::text, p_supplier_id uuid DEFAULT NULL::uuid, p_payee_name text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_accrued numeric := 0;
    v_type    text;
    v_n int := 0;
    v_e record;
    v_var numeric;
    v_bank text;
    v_lines jsonb;
    v_je jsonb;
    v_expense_id uuid := gen_random_uuid();
    v_code text;
BEGIN
    PERFORM require_permission('module.finance.edit');
    IF p_entry_ids IS NULL OR array_length(p_entry_ids, 1) IS NULL THEN
        RAISE EXCEPTION 'NO_LINES';
    END IF;
    IF p_actual_amount IS NULL OR p_actual_amount <= 0 THEN
        RAISE EXCEPTION 'AMOUNT_INVALID';
    END IF;
    IF p_payment_status NOT IN ('paid','unpaid') THEN
        RAISE EXCEPTION 'PAYMENT_STATUS_INVALID|%', COALESCE(p_payment_status, '?');
    END IF;
    IF p_payment_status = 'unpaid' AND p_supplier_id IS NULL THEN
        RAISE EXCEPTION 'SUPPLIER_REQUIRED_FOR_UNPAID';
    END IF;

    FOR v_e IN SELECT * FROM processing_cost_entries WHERE id = ANY (p_entry_ids) FOR UPDATE
    LOOP
        IF v_e.deleted_at IS NOT NULL THEN RAISE EXCEPTION 'COST_ENTRY_INVALID|%', v_e.id; END IF;
        IF NOT v_e.is_estimate THEN RAISE EXCEPTION 'COST_ENTRY_NOT_ESTIMATE|%', v_e.cost_type; END IF;
        IF v_e.remitted_at IS NOT NULL OR v_e.relieved_at IS NOT NULL THEN
            RAISE EXCEPTION 'COST_ENTRY_ALREADY_SETTLED|%', v_e.cost_type;
        END IF;
        IF v_type IS NULL THEN v_type := v_e.cost_type;
        ELSIF v_type <> v_e.cost_type THEN
            RAISE EXCEPTION 'RELIEF_MIXED_COST_TYPES|%|%', v_type, v_e.cost_type;
        END IF;
        v_accrued := round(v_accrued + v_e.amount_base, 2);
        v_n := v_n + 1;
    END LOOP;
    IF v_n = 0 OR v_accrued <= 0 THEN RAISE EXCEPTION 'NO_LINES'; END IF;

    IF p_payment_status = 'paid' THEN
        v_bank := COALESCE(p_bank_account, '1000');
        IF v_bank NOT IN ('1000','1010') THEN RAISE EXCEPTION 'BANK_INVALID|%', v_bank; END IF;
    END IF;

    -- 借 2200 清应计;差额进当期 5xxx;贷 银行/应付 记实际
    v_var := round(p_actual_amount - v_accrued, 2);
    v_lines := jsonb_build_array(jsonb_build_object(
        'account_code', '2200', 'side', 'debit', 'currency', 'SGD',
        'amount_ccy', v_accrued, 'fx_rate', 1, 'line_memo', 'clear accrued ' || v_type));
    IF v_var > 0 THEN
        v_lines := v_lines || jsonb_build_object('account_code', fin_cost_account(v_type),
            'side', 'debit', 'currency', 'SGD', 'amount_ccy', v_var, 'fx_rate', 1,
            'line_memo', 'estimate-to-actual variance');
    ELSIF v_var < 0 THEN
        v_lines := v_lines || jsonb_build_object('account_code', fin_cost_account(v_type),
            'side', 'credit', 'currency', 'SGD', 'amount_ccy', -v_var, 'fx_rate', 1,
            'line_memo', 'estimate-to-actual variance');
    END IF;
    v_lines := v_lines || jsonb_build_object(
        'account_code', CASE WHEN p_payment_status = 'paid' THEN v_bank ELSE '2000' END,
        'side', 'credit', 'currency', 'SGD', 'amount_ccy', p_actual_amount, 'fx_rate', 1);

    -- 单据号:与 record_expense 同一套(advisory lock + 年内递增)
    PERFORM pg_advisory_xact_lock(hashtext('expense_code_' || EXTRACT(YEAR FROM p_expense_date)::integer::text)::bigint);
    SELECT 'EXP-' || EXTRACT(YEAR FROM p_expense_date)::integer::text || '-' ||
           LPAD((COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1)::text, 4, '0')
    INTO v_code
    FROM expenses
    WHERE code LIKE 'EXP-' || EXTRACT(YEAR FROM p_expense_date)::integer::text || '-%';
    v_je := post_journal_entry(p_expense_date, 'Expense ' || v_code || ' ' || fin_cost_account(v_type),
                               'expense', v_expense_id, v_lines);

    -- 发票立成正常开支单据:挂账的走既有收付款核销;科目 = 该成本类型的 5xxx
    INSERT INTO expenses (id, code, expense_date, account_code, amount_ccy, currency, fx_rate,
                          amount_base, payment_status, bank_account_code, supplier_id,
                          payee_name, notes, journal_entry_id, created_by)
    VALUES (v_expense_id, v_code, p_expense_date, fin_cost_account(v_type), p_actual_amount, 'SGD', 1,
            p_actual_amount, p_payment_status, v_bank, p_supplier_id,
            p_payee_name, p_notes, (v_je->>'entry_id')::uuid, auth.uid());

    UPDATE processing_cost_entries
    SET relieved_at = p_expense_date, relief_expense_id = v_expense_id
    WHERE id = ANY (p_entry_ids);

    RETURN jsonb_build_object('expense_id', v_expense_id, 'expense_code', v_code,
        'journal_code', v_je->>'code', 'cost_type', v_type,
        'accrued_cleared', v_accrued, 'actual', p_actual_amount, 'variance', v_var, 'entries', v_n);
END;
$function$;

CREATE VIEW public.processing_cost_variance WITH (security_invoker = on) AS
 SELECT date_trunc('month'::text, e.expense_date::timestamp with time zone)::date AS month,
    x.cost_type,
    round(sum(x.accrued), 2) AS estimated_total,
    round(sum(x.actual), 2) AS actual_total,
    round(sum(x.actual) - sum(x.accrued), 2) AS variance,
        CASE
            WHEN sum(x.actual) > sum(x.accrued) THEN 'under_estimated'::text
            WHEN sum(x.actual) < sum(x.accrued) THEN 'over_estimated'::text
            ELSE 'exact'::text
        END AS direction
   FROM ( SELECT pce.relief_expense_id,
            pce.cost_type,
            sum(pce.amount_base) AS accrued,
            max(ex.amount_base) AS actual
           FROM processing_cost_entries pce
             JOIN expenses ex ON ex.id = pce.relief_expense_id
          WHERE pce.relieved_at IS NOT NULL
          GROUP BY pce.relief_expense_id, pce.cost_type) x
     JOIN expenses e ON e.id = x.relief_expense_id
  GROUP BY (date_trunc('month'::text, e.expense_date::timestamp with time zone)::date), x.cost_type
  ORDER BY (date_trunc('month'::text, e.expense_date::timestamp with time zone)::date), x.cost_type;

REVOKE EXECUTE ON FUNCTION public.remit_processing_costs(uuid[], date, text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.relieve_processing_accruals(uuid[], numeric, date, text, text, uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.remit_processing_costs(uuid[], date, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.relieve_processing_accruals(uuid[], numeric, date, text, text, uuid, text, text) TO authenticated, service_role;

COMMIT;
