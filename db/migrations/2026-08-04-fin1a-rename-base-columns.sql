-- db/migrations/2026-08-04-fin1a-rename-base-columns.sql
-- FIN-1a:本位币金额列改名 *_usd → *_base。【纯改名】—— 无任何行为改动。
-- 为什么叫 _base 不叫 _sgd:把币种烤进名字正是 FIN-0 变成 39 处改动的原因;
-- _base 在本位币再变时仍然为真。交易币种真是 USD 的列【保留原名】:
-- 金属报价(metal_prices/pricing_formulas)、采购单据与付款条款
-- (purchase_order*/payment_term_template_lines 的 estimated_*/fixed_amount_usd)——
-- 那些是 USD 报价,不是本位币金额。视图输出的派生列名(settled/open/doc_value/
-- prepaid_*/applicable/batch_ap_open/po_unapplied_prepayment/expense_amount)一并
-- 改 _base;改输出列名需 DROP 后重建。函数体内引用与三个局部变量名同步改。
-- fx_rates.rate_sgd_per_unit 留名未动,报请与 FIN-1b 一并定夺(该表的币种对定义
-- 本身写着 SGD —— CHECK (currency <> 'SGD') —— 只改列名是半吊子)。
BEGIN;

ALTER TABLE public.expenses RENAME COLUMN amount_usd TO amount_base;
COMMENT ON COLUMN public.expenses.amount_base IS '本位币金额(以 currencies.is_base 为币种 —— 不写死币种;FIN-1a 前列名 amount_usd)。';

ALTER TABLE public.invoice_lines RENAME COLUMN amount_usd TO amount_base;
COMMENT ON COLUMN public.invoice_lines.amount_base IS '本位币金额(以 currencies.is_base 为币种 —— 不写死币种;FIN-1a 前列名 amount_usd)。';

ALTER TABLE public.invoices RENAME COLUMN subtotal_usd TO subtotal_base;
COMMENT ON COLUMN public.invoices.subtotal_base IS '本位币小计(以 currencies.is_base 为币种 —— 不写死币种;FIN-1a 前列名 subtotal_usd)。';
ALTER TABLE public.invoices RENAME COLUMN tax_usd TO tax_base;
COMMENT ON COLUMN public.invoices.tax_base IS '本位币税额(以 currencies.is_base 为币种 —— 不写死币种;FIN-1a 前列名 tax_usd)。';
ALTER TABLE public.invoices RENAME COLUMN total_usd TO total_base;
COMMENT ON COLUMN public.invoices.total_base IS '本位币总额(以 currencies.is_base 为币种 —— 不写死币种;FIN-1a 前列名 total_usd)。';

ALTER TABLE public.payment_allocations RENAME COLUMN allocated_usd TO allocated_base;
COMMENT ON COLUMN public.payment_allocations.allocated_base IS '本位币核销金额(以 currencies.is_base 为币种 —— 不写死币种;FIN-1a 前列名 allocated_usd)。';

ALTER TABLE public.payments RENAME COLUMN amount_usd TO amount_base;
COMMENT ON COLUMN public.payments.amount_base IS '本位币金额(以 currencies.is_base 为币种 —— 不写死币种;FIN-1a 前列名 amount_usd)。';

ALTER TABLE public.prepayment_applications RENAME COLUMN amount_usd TO amount_base;
COMMENT ON COLUMN public.prepayment_applications.amount_base IS '本位币金额(以 currencies.is_base 为币种 —— 不写死币种;FIN-1a 前列名 amount_usd)。';

ALTER TABLE public.processing_cost_entries RENAME COLUMN amount_usd TO amount_base;
COMMENT ON COLUMN public.processing_cost_entries.amount_base IS '本位币金额(以 currencies.is_base 为币种 —— 不写死币种;FIN-1a 前列名 amount_usd)。';

ALTER TABLE public.processing_outputs RENAME COLUMN allocated_cost_usd TO allocated_cost_base;
COMMENT ON COLUMN public.processing_outputs.allocated_cost_base IS '本位币分摊成本(以 currencies.is_base 为币种 —— 不写死币种;FIN-1a 前列名 allocated_cost_usd)。';
ALTER TABLE public.processing_outputs RENAME COLUMN unit_cost_usd TO unit_cost_base;
COMMENT ON COLUMN public.processing_outputs.unit_cost_base IS '本位币单位成本(以 currencies.is_base 为币种 —— 不写死币种;FIN-1a 前列名 unit_cost_usd)。';

ALTER TABLE public.processing_runs RENAME COLUMN capitalized_cost_usd TO capitalized_cost_base;
COMMENT ON COLUMN public.processing_runs.capitalized_cost_base IS '本位币资本化成本(以 currencies.is_base 为币种 —— 不写死币种;FIN-1a 前列名 capitalized_cost_usd)。';
ALTER TABLE public.processing_runs RENAME COLUMN material_cost_usd TO material_cost_base;
COMMENT ON COLUMN public.processing_runs.material_cost_base IS '本位币材料成本(以 currencies.is_base 为币种 —— 不写死币种;FIN-1a 前列名 material_cost_usd)。';
ALTER TABLE public.processing_runs RENAME COLUMN process_cost_usd TO process_cost_base;
COMMENT ON COLUMN public.processing_runs.process_cost_base IS '本位币加工成本(以 currencies.is_base 为币种 —— 不写死币种;FIN-1a 前列名 process_cost_usd)。';
ALTER TABLE public.processing_runs RENAME COLUMN total_cost_usd TO total_cost_base;
COMMENT ON COLUMN public.processing_runs.total_cost_base IS '本位币总成本(以 currencies.is_base 为币种 —— 不写死币种;FIN-1a 前列名 total_cost_usd)。';

ALTER TABLE public.sales_records RENAME COLUMN amount_usd TO amount_base;
COMMENT ON COLUMN public.sales_records.amount_base IS '本位币金额(以 currencies.is_base 为币种 —— 不写死币种;FIN-1a 前列名 amount_usd)。';

-- ── 引用这些列的函数,整体以镜像为准替换 ──
CREATE OR REPLACE FUNCTION public.allocate_processing_costs(p_run_id uuid, p_basis text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
-- Cost allocation. Metals with a usable price (deleted_at IS NULL, price_date <= run
-- process_date) contribute to metal value; metals WITHOUT one contribute 0 and are
-- recorded in allocation_snapshot.skipped_metals (the former missing-price hard error is gone).
-- NO_METAL_VALUE still blocks when the total metal value across all legs is 0.
-- (Phase 1 follow-up 1, 2026-07-03.)
-- cut 2a (2026-07-06): 10a 资本化分录(借 1220 / 贷 1200 材料 + 贷 5xxx 费用;
-- 重分摊 = 冲旧 + 重挂);10b 给无 COGS 的既有销售按原 sale_date 补挂 COGS。
DECLARE
    v_user                 uuid := auth.uid();
    v_run                  processing_runs%ROWTYPE;
    v_basis                text;
    v_process_date         date;
    v_material             numeric;
    v_process              numeric;
    v_total                numeric;
    v_inputs_without_price integer;
    v_total_basis          numeric;
    v_total_metal_value    numeric;
    v_bad_code             text;
    v_bad_metal            text;
    v_prices_used          jsonb;
    v_skipped_metals       jsonb;
    v_outputs              jsonb;
    v_sum_alloc            numeric;
    v_snapshot             jsonb;
    v_ct                   record;
    v_sale                 record;
    v_cap_lines            jsonb;
    v_cap_total            numeric;
    v_cap_je               jsonb;
    v_cap_entry_id         uuid;
    v_cogs                 numeric;
    v_cogs_je              jsonb;
BEGIN
    PERFORM require_permission('module.processing.edit');
    -- 1. Lock the run; must exist and be a live committed run.
    SELECT * INTO v_run FROM processing_runs WHERE id = p_run_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'RUN_NOT_FOUND|%', p_run_id;
    END IF;
    IF v_run.deleted_at IS NOT NULL OR v_run.status <> 'committed' THEN
        RAISE EXCEPTION 'RUN_NOT_COMMITTED|%', v_run.status;
    END IF;

    -- 2. Resolve + validate basis.
    v_basis := COALESCE(p_basis, v_run.allocation_basis);
    IF v_basis NOT IN ('weight','metal_value') THEN
        RAISE EXCEPTION 'INVALID_BASIS|%', v_basis;
    END IF;
    v_process_date := v_run.process_date;

    -- 3. Unit guard: all math assumes kg.
    SELECT ib.code INTO v_bad_code
    FROM processing_inputs pi
    JOIN inbound_batches ib ON ib.id = pi.inbound_batch_id
    WHERE pi.run_id = p_run_id AND ib.unit <> 'kg'
    LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'UNIT_NOT_KG|%', v_bad_code;
    END IF;

    SELECT ob.code INTO v_bad_code
    FROM processing_outputs po
    JOIN output_batches ob ON ob.id = po.output_batch_id
    WHERE po.run_id = p_run_id AND ob.unit <> 'kg'
    LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'UNIT_NOT_KG|%', v_bad_code;
    END IF;

    -- 4. Material cost = Σ input legs quantity_consumed × inbound.unit_price (NULL price = 0).
    SELECT COALESCE(SUM(pi.quantity_consumed * COALESCE(ib.unit_price, 0)), 0),
           COUNT(*) FILTER (WHERE ib.unit_price IS NULL)
      INTO v_material, v_inputs_without_price
    FROM processing_inputs pi
    JOIN inbound_batches ib ON ib.id = pi.inbound_batch_id
    WHERE pi.run_id = p_run_id;

    -- 5. Process cost = Σ live cost entries.
    SELECT COALESCE(SUM(amount_base), 0) INTO v_process
    FROM processing_cost_entries
    WHERE run_id = p_run_id AND deleted_at IS NULL;

    -- 6. Total.
    v_total := v_material + v_process;

    -- 7. Basis totals. Metals without a usable price contribute 0 (LEFT JOIN + COALESCE)
    --    and are recorded in skipped_metals; only a zero grand total blocks (NO_METAL_VALUE).
    IF v_basis = 'metal_value' THEN
        SELECT COALESCE(SUM(
                 po.quantity_produced * obm.content_pct / 100.0 / 1000.0 * COALESCE(pr.price_usd_per_tonne, 0)
               ), 0)
          INTO v_total_metal_value
        FROM processing_outputs po
        JOIN output_batch_metals obm ON obm.output_batch_id = po.output_batch_id
        LEFT JOIN LATERAL (
            SELECT mp.price_usd_per_tonne
            FROM metal_prices mp
            WHERE mp.metal = obm.metal AND mp.deleted_at IS NULL
              AND mp.price_date <= v_process_date
            ORDER BY mp.price_date DESC
            LIMIT 1
        ) pr ON true
        WHERE po.run_id = p_run_id;

        IF COALESCE(v_total_metal_value, 0) = 0 THEN
            RAISE EXCEPTION 'NO_METAL_VALUE';
        END IF;

        v_total_basis := v_total_metal_value;

        SELECT COALESCE(jsonb_agg(
                   jsonb_build_object('metal', metal,
                                      'price_usd_per_tonne', price_usd_per_tonne,
                                      'price_date', price_date)
                   ORDER BY metal), '[]'::jsonb)
          INTO v_prices_used
        FROM (
            SELECT DISTINCT ON (mp.metal) mp.metal, mp.price_usd_per_tonne, mp.price_date
            FROM metal_prices mp
            WHERE mp.deleted_at IS NULL AND mp.price_date <= v_process_date
              AND mp.metal IN (
                  SELECT DISTINCT obm.metal
                  FROM processing_outputs po
                  JOIN output_batch_metals obm ON obm.output_batch_id = po.output_batch_id
                  WHERE po.run_id = p_run_id AND obm.content_pct > 0
              )
            ORDER BY mp.metal, mp.price_date DESC
        ) q;

        -- Metals present (content > 0) on this run with NO usable price row: excluded from
        -- value (they contributed 0 above) and reported in the snapshot as skipped.
        SELECT COALESCE(jsonb_agg(m ORDER BY m), '[]'::jsonb)
          INTO v_skipped_metals
        FROM (
            SELECT DISTINCT obm.metal AS m
            FROM processing_outputs po
            JOIN output_batch_metals obm ON obm.output_batch_id = po.output_batch_id
            WHERE po.run_id = p_run_id AND obm.content_pct > 0
              AND NOT EXISTS (
                  SELECT 1 FROM metal_prices mp
                  WHERE mp.metal = obm.metal AND mp.deleted_at IS NULL
                    AND mp.price_date <= v_process_date
              )
        ) s;
    ELSE
        SELECT COALESCE(SUM(quantity_produced), 0) INTO v_total_basis
        FROM processing_outputs WHERE run_id = p_run_id;
        v_total_metal_value := NULL;
        v_prices_used := '[]'::jsonb;
        v_skipped_metals := '[]'::jsonb;
    END IF;

    -- 8 + 9. Allocate (largest-share row absorbs the rounding remainder), persist legs,
    --        and collect the per-output result — all in one statement.
    WITH legs AS (
        SELECT po.id AS leg_id, po.output_batch_id, po.quantity_produced,
               CASE WHEN v_basis = 'weight' THEN po.quantity_produced::numeric
                    ELSE COALESCE((
                        SELECT SUM(po.quantity_produced * obm.content_pct / 100.0 / 1000.0 * COALESCE(pr.price_usd_per_tonne, 0))
                        FROM output_batch_metals obm
                        LEFT JOIN LATERAL (
                            SELECT mp.price_usd_per_tonne
                            FROM metal_prices mp
                            WHERE mp.metal = obm.metal AND mp.deleted_at IS NULL
                              AND mp.price_date <= v_process_date
                            ORDER BY mp.price_date DESC
                            LIMIT 1
                        ) pr ON true
                        WHERE obm.output_batch_id = po.output_batch_id
                    ), 0)
               END AS basis_value
        FROM processing_outputs po
        WHERE po.run_id = p_run_id
    ),
    calc AS (
        SELECT leg_id, output_batch_id, quantity_produced, basis_value,
               round(v_total * basis_value / NULLIF(v_total_basis, 0), 2) AS alloc_raw,
               row_number() OVER (ORDER BY basis_value DESC, leg_id) AS rn
        FROM legs
    ),
    adj AS (
        SELECT c.*, (round(v_total, 2) - SUM(alloc_raw) OVER ()) AS remainder
        FROM calc c
    ),
    final AS (
        SELECT leg_id, output_batch_id, quantity_produced, basis_value,
               alloc_raw + CASE WHEN rn = 1 THEN remainder ELSE 0 END AS allocated
        FROM adj
    ),
    upd AS (
        UPDATE processing_outputs po
        SET allocated_cost_base = f.allocated,
            unit_cost_base = round(f.allocated / f.quantity_produced, 4)
        FROM final f
        WHERE po.id = f.leg_id
        RETURNING f.output_batch_id, f.basis_value, f.allocated, po.unit_cost_base
    )
    SELECT jsonb_agg(
               jsonb_build_object(
                   'output_batch_id', output_batch_id,
                   'share', round(basis_value / NULLIF(v_total_basis, 0), 6),
                   'allocated_cost_base', allocated,
                   'unit_cost_base', unit_cost_base)
               ORDER BY output_batch_id),
           COALESCE(SUM(allocated), 0)
      INTO v_outputs, v_sum_alloc
    FROM upd;

    -- 9b. Snapshot + run header.
    v_snapshot := jsonb_build_object(
        'basis', v_basis,
        'computed_at', now(),
        'inputs_without_price', v_inputs_without_price,
        'total_output_metal_value_usd',
            CASE WHEN v_basis = 'metal_value' THEN round(v_total_metal_value, 2) ELSE NULL END,
        'prices_used', v_prices_used,
        'skipped_metals', v_skipped_metals
    );

    UPDATE processing_runs
    SET material_cost_base   = round(v_material, 2),
        process_cost_base    = round(v_process, 2),
        total_cost_base      = round(v_total, 2),
        allocation_basis    = v_basis,
        allocation_snapshot = v_snapshot,
        allocated_at        = now(),
        allocated_by        = v_user,
        updated_at          = now(),
        updated_by          = v_user
    WHERE id = p_run_id;

    -- 10a. cut 2a:资本化分录。重分摊 = 先冲销旧资本化分录再重挂(净效果即差额,
    --      且材料/费用构成变化时各科目仍精确;两张均记 CURRENT_DATE)。
    --      借方 1220 取各对方行四舍五入后的合计,保证分录自平
    --      (round(总) ≠ Σround(部分) 的边角防护;capitalized_cost_base 存该合计)。
    IF v_run.capitalization_entry_id IS NOT NULL
       AND (SELECT status FROM journal_entries WHERE id = v_run.capitalization_entry_id) = 'posted' THEN
        -- 已被人工冲销过的旧资本化分录不再重复冲(status <> 'posted' 直接跳过)
        PERFORM reverse_journal_entry_internal(v_run.capitalization_entry_id, CURRENT_DATE, 'Re-allocation ' || v_run.code);
    END IF;

    v_cap_lines := '[]'::jsonb;
    v_cap_total := 0;
    IF round(v_material, 2) <> 0 THEN
        v_cap_lines := v_cap_lines || jsonb_build_object('account_code', '1200', 'side', 'credit', 'currency', 'SGD', 'amount_ccy', round(v_material, 2));
        v_cap_total := v_cap_total + round(v_material, 2);
    END IF;
    FOR v_ct IN
        SELECT cost_type, round(sum(amount_base), 2) AS amt
        FROM processing_cost_entries
        WHERE run_id = p_run_id AND deleted_at IS NULL
        GROUP BY cost_type
        ORDER BY cost_type
    LOOP
        IF v_ct.amt > 0 THEN
            v_cap_lines := v_cap_lines || jsonb_build_object('account_code', fin_cost_account(v_ct.cost_type), 'side', 'credit', 'currency', 'SGD', 'amount_ccy', v_ct.amt);
            v_cap_total := v_cap_total + v_ct.amt;
        ELSIF v_ct.amt < 0 THEN
            -- 负净额(冲减类成本):翻到借方,保持各行 amount_ccy > 0
            v_cap_lines := v_cap_lines || jsonb_build_object('account_code', fin_cost_account(v_ct.cost_type), 'side', 'debit', 'currency', 'SGD', 'amount_ccy', -v_ct.amt);
            v_cap_total := v_cap_total + v_ct.amt;
        END IF;
    END LOOP;

    v_cap_entry_id := NULL;
    IF v_cap_total <> 0 THEN
        v_cap_lines := jsonb_build_array(
            jsonb_build_object('account_code', '1220',
                               'side', CASE WHEN v_cap_total > 0 THEN 'debit' ELSE 'credit' END,
                               'currency', 'SGD', 'amount_ccy', abs(v_cap_total))
        ) || v_cap_lines;
        v_cap_je := post_journal_entry(
            CURRENT_DATE,
            'Capitalize ' || v_run.code,
            'allocation', p_run_id,
            v_cap_lines);
        v_cap_entry_id := (v_cap_je->>'entry_id')::uuid;
    END IF;

    UPDATE processing_runs
    SET capitalized_cost_base = v_cap_total,
        capitalization_entry_id = v_cap_entry_id
    WHERE id = p_run_id;

    -- 10b. cut 2a:COGS 补挂 —— 只补此前无 COGS 分录的销售(cogs_entry_id IS NULL),
    --      用最新 unit_cost_base,按各自原 sale_date(撞期间锁则 PERIOD_LOCKED 直接抛出)。
    --      已挂 COGS 不追溯重述(标准成本式简化;重述属人工冲销决策)。
    FOR v_sale IN
        SELECT sr.id, sr.quantity, sr.sale_date, ob.code AS batch_code, po.unit_cost_base
        FROM sales_records sr
        JOIN processing_outputs po ON po.output_batch_id = sr.output_batch_id AND po.run_id = p_run_id
        JOIN output_batches ob ON ob.id = sr.output_batch_id
        WHERE sr.cogs_entry_id IS NULL
        ORDER BY sr.sale_date, sr.created_at
    LOOP
        v_cogs := round(v_sale.quantity * v_sale.unit_cost_base, 2);
        IF v_cogs <> 0 THEN
            v_cogs_je := post_journal_entry(
                v_sale.sale_date,
                'COGS ' || v_sale.batch_code,
                'sale', v_sale.id,
                jsonb_build_array(
                    jsonb_build_object('account_code', '5000', 'side', 'debit',  'currency', 'SGD', 'amount_ccy', v_cogs),
                    jsonb_build_object('account_code', '1220', 'side', 'credit', 'currency', 'SGD', 'amount_ccy', v_cogs)));
            UPDATE sales_records SET cogs_entry_id = (v_cogs_je->>'entry_id')::uuid WHERE id = v_sale.id;
        END IF;
    END LOOP;

    -- 10. Return.
    RETURN jsonb_build_object(
        'run_id', p_run_id,
        'basis', v_basis,
        'material_cost_base', round(v_material, 2),
        'process_cost_base', round(v_process, 2),
        'total_cost_base', round(v_total, 2),
        'inputs_without_price', v_inputs_without_price,
        'outputs', COALESCE(v_outputs, '[]'::jsonb)
    );
END;
$function$;
CREATE OR REPLACE FUNCTION public.apply_prepayment(p_purchase_order_id uuid, p_inbound_batch_id uuid, p_amount numeric, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user      uuid := auth.uid();
    v_po        record;
    v_batch     record;
    v_prepaid   numeric;
    v_applied   numeric;
    v_available numeric;
    v_value     numeric;
    v_settled   numeric;
    v_open      numeric;
    v_app_id    uuid := gen_random_uuid();
    v_je        jsonb;
BEGIN
    PERFORM require_permission('module.finance.edit');
    SELECT po.id, po.code, po.supplier_id, po.status
    INTO v_po
    FROM purchase_orders po
    WHERE po.id = p_purchase_order_id AND po.deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PO_NOT_FOUND|%', COALESCE(p_purchase_order_id::text, '?');
    END IF;
    IF v_po.status = 'cancelled' THEN
        RAISE EXCEPTION 'PO_CANCELLED|%', v_po.code;
    END IF;

    SELECT ib.id, ib.code, ib.supplier_id, ib.quantity, ib.unit_price
    INTO v_batch
    FROM inbound_batches ib
    WHERE ib.id = p_inbound_batch_id AND ib.deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', COALESCE(p_inbound_batch_id::text, '?');
    END IF;
    IF v_batch.unit_price IS NULL THEN
        RAISE EXCEPTION 'INBOUND_UNPRICED|%', v_batch.code;
    END IF;
    IF v_batch.supplier_id IS DISTINCT FROM v_po.supplier_id THEN
        RAISE EXCEPTION 'SUPPLIER_MISMATCH|%|%', v_po.code, v_batch.code;
    END IF;
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'AMOUNT_INVALID';
    END IF;

    -- 可用预付 = 已付到该 PO 的预付(仅 posted 收付款) − 已冲抵的部分
    SELECT COALESCE(SUM(pa.allocated_base), 0) INTO v_prepaid
    FROM payment_allocations pa
    JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
    WHERE pa.purchase_order_id = p_purchase_order_id;

    SELECT COALESCE(SUM(ppa.amount_base), 0) INTO v_applied
    FROM prepayment_applications ppa
    WHERE ppa.purchase_order_id = p_purchase_order_id;

    v_available := round(v_prepaid - v_applied, 2);
    IF p_amount > v_available THEN
        RAISE EXCEPTION 'PREPAY_INSUFFICIENT|%|%', v_available, p_amount;
    END IF;

    -- 批次敞口 = 当前批次价值 − 收付款核销 − 已冲抵的预付
    v_value := round(v_batch.quantity * v_batch.unit_price, 2);
    SELECT COALESCE(SUM(pa.allocated_base), 0) INTO v_settled
    FROM payment_allocations pa
    JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
    WHERE pa.inbound_batch_id = p_inbound_batch_id;
    v_settled := v_settled + COALESCE(
        (SELECT SUM(ppa.amount_base) FROM prepayment_applications ppa
          WHERE ppa.inbound_batch_id = p_inbound_batch_id), 0);
    v_open := round(v_value - v_settled, 2);
    IF p_amount > v_open THEN
        RAISE EXCEPTION 'EXCEEDS_OPEN|%|%', v_open, p_amount;
    END IF;

    -- 分录:预付转为对该批次应付的清偿(钱早就出去了,这里只是科目之间的搬运)
    v_je := post_journal_entry(
        CURRENT_DATE,
        'Prepayment applied ' || v_po.code || ' → ' || v_batch.code,
        'prepayment', v_app_id,
        jsonb_build_array(
            jsonb_build_object('account_code', '2000', 'side', 'debit',  'currency', 'SGD', 'amount_ccy', p_amount, 'fx_rate', 1),
            jsonb_build_object('account_code', '1300', 'side', 'credit', 'currency', 'SGD', 'amount_ccy', p_amount, 'fx_rate', 1)));

    INSERT INTO prepayment_applications (id, purchase_order_id, inbound_batch_id, amount_base,
                                         notes, journal_entry_id, created_by)
    VALUES (v_app_id, p_purchase_order_id, p_inbound_batch_id, p_amount,
            p_notes, (v_je->>'entry_id')::uuid, v_user);

    RETURN jsonb_build_object(
        'application_id', v_app_id,
        'purchase_order_id', p_purchase_order_id,
        'inbound_batch_id', p_inbound_batch_id,
        'amount_base', p_amount,
        'journal_code', v_je->>'code',
        'prepaid_remaining', round(v_available - p_amount, 2)
    );
END;
$function$;
CREATE OR REPLACE FUNCTION public.cancel_purchase_order(p_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user    uuid := auth.uid();
    v_po      record;
    v_batches integer;
    v_applied numeric;
BEGIN
    PERFORM require_permission('module.purchasing.edit');
    SELECT id, code, status INTO v_po
    FROM purchase_orders WHERE id = p_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PO_NOT_FOUND|%', COALESCE(p_id::text, '?');
    END IF;
    IF v_po.status = 'cancelled' THEN
        RAISE EXCEPTION 'PO_CANCELLED|%', v_po.code;
    END IF;

    SELECT count(*) INTO v_batches
    FROM inbound_batches WHERE purchase_order_id = p_id AND deleted_at IS NULL;
    IF v_batches > 0 THEN
        RAISE EXCEPTION 'PO_HAS_RECEIPTS|%', v_batches;
    END IF;

    SELECT COALESCE(SUM(amount_base), 0) INTO v_applied
    FROM prepayment_applications WHERE purchase_order_id = p_id;
    IF v_applied > 0 THEN
        RAISE EXCEPTION 'PO_HAS_APPLIED_PREPAYMENTS|%', v_applied;
    END IF;

    UPDATE purchase_orders
    SET status = 'cancelled', cancelled_at = now(), cancel_reason = p_reason, updated_by = v_user
    WHERE id = p_id;

    RETURN jsonb_build_object('purchase_order_id', p_id, 'code', v_po.code, 'status', 'cancelled');
END;
$function$;
CREATE OR REPLACE FUNCTION public.close_purchase_order(p_purchase_order_id uuid, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user      uuid := auth.uid();
    v_po        record;
    v_prepaid   numeric;
    v_applied   numeric;
    v_unapplied numeric;
    v_received  numeric;
    v_ordered   numeric;
BEGIN
    PERFORM require_permission('module.purchasing.edit');
    SELECT id, code, status, notes INTO v_po
    FROM purchase_orders
    WHERE id = p_purchase_order_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PO_NOT_FOUND|%', COALESCE(p_purchase_order_id::text, '?');
    END IF;
    IF v_po.status = 'cancelled' THEN
        RAISE EXCEPTION 'PO_CANCELLED|%', v_po.code;
    END IF;
    IF v_po.status = 'closed' THEN
        RAISE EXCEPTION 'PO_ALREADY_CLOSED|%', v_po.code;
    END IF;

    -- 未抵扣预付 = 已付到该单的预付(posted 收付款)− 已抵扣到批次的部分。
    -- 大于 0 时必须写说明:这是【真金白银】躺在 1300 预付款项里,而这张单永远不会
    -- 再吸收它了 —— 退款、转到别的单、核销,系统今天都还没建模,所以允许关单,
    -- 但必须留下一句写下来的解释,不许无声搁浅。
    SELECT COALESCE(SUM(pa.allocated_base), 0) INTO v_prepaid
    FROM payment_allocations pa
    JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
    WHERE pa.purchase_order_id = p_purchase_order_id;
    SELECT COALESCE(SUM(ppa.amount_base), 0) INTO v_applied
    FROM prepayment_applications ppa
    WHERE ppa.purchase_order_id = p_purchase_order_id;
    v_unapplied := round(v_prepaid - v_applied, 2);

    IF v_unapplied > 0 AND (p_notes IS NULL OR btrim(p_notes) = '') THEN
        RAISE EXCEPTION 'CLOSE_NOTES_REQUIRED|%', v_unapplied;
    END IF;

    SELECT COALESCE(SUM(ib.quantity), 0) INTO v_received
    FROM inbound_batches ib
    WHERE ib.purchase_order_id = p_purchase_order_id AND ib.deleted_at IS NULL;
    SELECT COALESCE(SUM(pol.quantity), 0) INTO v_ordered
    FROM purchase_order_lines pol
    WHERE pol.purchase_order_id = p_purchase_order_id;

    UPDATE purchase_orders
    SET status = 'closed',
        closed_at = now(),
        -- 追加而不覆盖:关单说明带时间戳进 notes,原有内容原样保留
        notes = CASE
            WHEN p_notes IS NULL OR btrim(p_notes) = '' THEN notes
            ELSE COALESCE(notes || E'\n', '')
                 || '[' || to_char(now(), 'YYYY-MM-DD HH24:MI') || ' closed] ' || btrim(p_notes)
        END,
        updated_by = v_user
    WHERE id = p_purchase_order_id;

    RETURN jsonb_build_object(
        'purchase_order_id', p_purchase_order_id,
        'code', v_po.code,
        'status', 'closed',
        'unapplied_prepayment_usd', v_unapplied,
        'received_qty', v_received,
        'ordered_qty', v_ordered,
        'receipt_pct', CASE WHEN v_ordered = 0 THEN NULL
                            ELSE round(v_received / v_ordered * 100, 2) END
    );
END;
$function$;
CREATE OR REPLACE FUNCTION public.create_invoice(p_customer_id uuid, p_sales_record_ids uuid[], p_issue_date date DEFAULT NULL::date, p_payment_terms_days integer DEFAULT NULL::integer, p_notes text DEFAULT NULL::text, p_terms_text text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_cust        customers%ROWTYPE;
    v_issue       date := COALESCE(p_issue_date, CURRENT_DATE);
    v_terms       integer;
    v_due         date;
    v_invoice_id  uuid := gen_random_uuid();
    v_year        integer;
    v_seq         integer;
    v_code        text;
    v_sale_id     uuid;
    v_seen        uuid[] := ARRAY[]::uuid[];
    v_sale        record;
    v_currency    text;
    v_no          integer := 0;
    v_subtotal    numeric := 0;
    v_gst_on      boolean;
    v_gst_rate    numeric;
    v_tax_rate    numeric := 0;
    v_tax         numeric := 0;
    v_existing    text;
    v_lines       jsonb := '[]'::jsonb;  -- 第一趟收集,第二趟落库
    v_line        jsonb;
BEGIN
    PERFORM require_permission('module.finance.edit');
    -- 1. 客户
    SELECT * INTO v_cust FROM customers
    WHERE id = p_customer_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CUSTOMER_NOT_FOUND|%', COALESCE(p_customer_id::text, '?');
    END IF;

    IF p_sales_record_ids IS NULL OR array_length(p_sales_record_ids, 1) IS NULL THEN
        RAISE EXCEPTION 'NO_LINES';
    END IF;

    -- 2. 账期:显式 > 客户设定 > 30 天
    v_terms := COALESCE(p_payment_terms_days, v_cust.payment_terms_days, 30);
    IF v_terms < 0 THEN
        RAISE EXCEPTION 'TERMS_INVALID|%', v_terms;
    END IF;
    v_due := v_issue + v_terms;

    -- 3. 无缝编号(按 issue_date 的年份),咨询锁串行化;回滚即释放号码
    v_year := EXTRACT(YEAR FROM v_issue)::integer;
    PERFORM pg_advisory_xact_lock(hashtext('invoice_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM invoices
    WHERE code LIKE 'INV-' || v_year::text || '-%';
    v_code := 'INV-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');

    -- 4. 第一趟:逐张销售校验(存在 → 归属 → 未被占用 → 币种一致)并累计金额。
    FOREACH v_sale_id IN ARRAY p_sales_record_ids
    LOOP
        IF v_sale_id = ANY (v_seen) THEN
            RAISE EXCEPTION 'DUPLICATE_SALE|%',
                COALESCE((SELECT ob.code FROM sales_records sr
                          JOIN output_batches ob ON ob.id = sr.output_batch_id
                          WHERE sr.id = v_sale_id), v_sale_id::text);
        END IF;
        v_seen := v_seen || v_sale_id;

        SELECT sr.id, sr.customer_id, sr.quantity, sr.unit_price, sr.currency,
               sr.amount_base, ob.code AS batch_code, ob.unit, m.name AS material_name
        INTO v_sale
        FROM sales_records sr
        JOIN output_batches ob ON ob.id = sr.output_batch_id
        LEFT JOIN materials m ON m.id = ob.material_id
        WHERE sr.id = v_sale_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'SALE_NOT_FOUND|%', v_sale_id;
        END IF;

        -- sales_records.customer_id 可空 —— 批次可能在客户还没登记时就卖了。
        IF v_sale.customer_id IS NOT NULL AND v_sale.customer_id <> p_customer_id THEN
            RAISE EXCEPTION 'SALE_WRONG_CUSTOMER|%', v_sale.batch_code;
        END IF;

        SELECT i.code INTO v_existing
        FROM invoice_lines il
        JOIN invoices i ON i.id = il.invoice_id
        WHERE il.sales_record_id = v_sale_id AND NOT il.invoice_voided
        LIMIT 1;
        IF FOUND THEN
            RAISE EXCEPTION 'ALREADY_INVOICED|%|%', v_sale.batch_code, v_existing;
        END IF;

        IF v_currency IS NULL THEN
            v_currency := v_sale.currency;
        ELSIF v_currency <> v_sale.currency THEN
            RAISE EXCEPTION 'MIXED_CURRENCY|%|%', v_currency, v_sale.currency;
        END IF;

        v_no := v_no + 1;
        v_lines := v_lines || jsonb_build_object(
            'sales_record_id', v_sale_id,
            'line_no', v_no,
            'description', v_sale.batch_code || COALESCE(' — ' || v_sale.material_name, ''),
            'quantity', v_sale.quantity,
            'unit', v_sale.unit,
            'unit_price', v_sale.unit_price,
            'amount_base', v_sale.amount_base);

        v_subtotal := v_subtotal + v_sale.amount_base;
    END LOOP;

    -- 5. 税:未做 GST 登记时一律 0。【不过任何税金分录】—— 正确确认时点是销售,不是开票。
    SELECT gst_registered, gst_rate_pct INTO v_gst_on, v_gst_rate
    FROM finance_settings LIMIT 1;
    IF COALESCE(v_gst_on, false) THEN
        v_tax_rate := COALESCE(v_gst_rate, 0);
        v_tax := round(v_subtotal * v_tax_rate / 100.0, 2);
    END IF;

    v_subtotal := round(v_subtotal, 2);

    -- 6. 第二趟:金额已定,一次写对发票头,再落明细行。
    INSERT INTO invoices (id, code, customer_id, issue_date, due_date, payment_terms_days,
                          currency, subtotal_base, tax_rate_pct, tax_base, total_base,
                          notes, terms_text, bill_to_snapshot)
    VALUES (v_invoice_id, v_code, p_customer_id, v_issue, v_due, v_terms,
            v_currency, v_subtotal, v_tax_rate, v_tax, round(v_subtotal + v_tax, 2),
            p_notes, p_terms_text,
            jsonb_build_object(
                'code', v_cust.code,
                'legal_name', v_cust.legal_name,
                'short_name', v_cust.short_name,
                'country', v_cust.country,
                'tax_id', v_cust.tax_id,
                'address', v_cust.address,
                'payment_terms', v_cust.payment_terms,
                'incoterm', v_cust.incoterm,
                -- cut 2b 新增
                'contact_person', v_cust.contact_person,
                'email', v_cust.email,
                'phone', v_cust.phone));

    FOR v_line IN SELECT * FROM jsonb_array_elements(v_lines)
    LOOP
        INSERT INTO invoice_lines (invoice_id, sales_record_id, line_no, description,
                                   quantity, unit, unit_price, amount_base)
        VALUES (v_invoice_id,
                (v_line->>'sales_record_id')::uuid,
                (v_line->>'line_no')::integer,
                v_line->>'description',
                (v_line->>'quantity')::numeric,
                v_line->>'unit',
                (v_line->>'unit_price')::numeric,
                (v_line->>'amount_base')::numeric);
    END LOOP;

    RETURN jsonb_build_object(
        'invoice_id', v_invoice_id,
        'code', v_code,
        'issue_date', v_issue,
        'due_date', v_due,
        'subtotal_base', v_subtotal,
        'tax_base', v_tax,
        'total_base', round(v_subtotal + v_tax, 2),
        'line_count', v_no,
        'currency', v_currency
    );
END;
$function$;
-- db/functions/finance_journal_triggers.sql
-- cut 2a auto-journal engine — cost-entry journaling triggers + helpers.
-- 成本录入/调整/软删即入账(借 5xxx / 贷 2200,负数翻边);科目映射 fin_cost_account;
-- 行对构造 fin_cost_lines(录入/冲销共用)。规格原写"两个 AFTER UPDATE 触发器"
-- (改额/软删),同一 UPDATE 可能双重命中 —— 合并为一个 UPDATE 触发器内分支(软删优先)。
-- 硬 DELETE 不入账(应用只走软删)。PERIOD_LOCKED 从 post_journal_entry 直接抛出。
--
-- NOTE: introduced by db/migrations/2026-07-06-phase3-cut2a-auto-journal.sql.

CREATE OR REPLACE FUNCTION public.fin_cost_account(p_cost_type text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT CASE p_cost_type
        WHEN 'labour'          THEN '5100'
        WHEN 'electricity'     THEN '5110'
        WHEN 'gas'             THEN '5120'
        WHEN 'depreciation'    THEN '5130'
        WHEN 'consumables'     THEN '5140'
        WHEN 'waste_treatment' THEN '5150'
        ELSE '5190'  -- 'other' 及未知值兜底
    END;
$function$;


CREATE OR REPLACE FUNCTION public.fin_cost_lines(p_cost_type text, p_amount numeric, p_reverse boolean)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
    SELECT CASE WHEN (p_amount > 0) <> p_reverse THEN
        jsonb_build_array(
            jsonb_build_object('account_code', fin_cost_account(p_cost_type), 'side', 'debit',  'currency', 'SGD', 'amount_ccy', abs(p_amount)),
            jsonb_build_object('account_code', '2200',                        'side', 'credit', 'currency', 'SGD', 'amount_ccy', abs(p_amount)))
    ELSE
        jsonb_build_array(
            jsonb_build_object('account_code', '2200',                        'side', 'debit',  'currency', 'SGD', 'amount_ccy', abs(p_amount)),
            jsonb_build_object('account_code', fin_cost_account(p_cost_type), 'side', 'credit', 'currency', 'SGD', 'amount_ccy', abs(p_amount)))
    END;
$function$;


CREATE OR REPLACE FUNCTION public.fin_journal_cost_entry()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_run_code text;
    v_lines    jsonb;
BEGIN
    SELECT code INTO v_run_code FROM processing_runs WHERE id = NEW.run_id;

    IF TG_OP = 'INSERT' THEN
        IF NEW.deleted_at IS NOT NULL OR NEW.amount_base = 0 THEN
            RETURN NULL;
        END IF;
        PERFORM post_journal_entry(
            CURRENT_DATE,
            'Cost ' || v_run_code || ' ' || NEW.cost_type,
            'processing_cost', NEW.id,
            fin_cost_lines(NEW.cost_type, NEW.amount_base, false));
        RETURN NULL;
    END IF;

    -- UPDATE:软删 → 冲销现额(优先,忽略同笔 UPDATE 里的其它变化)
    IF OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL THEN
        IF OLD.amount_base <> 0 THEN
            PERFORM post_journal_entry(
                CURRENT_DATE,
                'Cost removed ' || v_run_code,
                'processing_cost', NEW.id,
                fin_cost_lines(OLD.cost_type, OLD.amount_base, true));
        END IF;
        RETURN NULL;
    END IF;
    IF NEW.deleted_at IS NOT NULL THEN
        RETURN NULL;  -- 已软删行的其它变更不入账
    END IF;

    -- 金额/类型变化 → 一张调整分录:冲旧 + 记新(至多 4 行,自平)
    IF NEW.amount_base IS DISTINCT FROM OLD.amount_base
       OR NEW.cost_type IS DISTINCT FROM OLD.cost_type THEN
        v_lines := '[]'::jsonb;
        IF OLD.amount_base <> 0 THEN
            v_lines := v_lines || fin_cost_lines(OLD.cost_type, OLD.amount_base, true);
        END IF;
        IF NEW.amount_base <> 0 THEN
            v_lines := v_lines || fin_cost_lines(NEW.cost_type, NEW.amount_base, false);
        END IF;
        IF jsonb_array_length(v_lines) >= 2 THEN
            PERFORM post_journal_entry(
                CURRENT_DATE,
                'Cost adj ' || v_run_code,
                'processing_cost', NEW.id,
                v_lines);
        END IF;
    END IF;
    RETURN NULL;
END;
$function$;-- (trigger attachments trg_processing_cost_entries_journal_ins / _upd moved to
--  db/tables/processing_cost_entries.sql — 2026-07-31 镜像漂移审计起,每张表的
--  镜像完整描述它自己的触发器,函数文件只放函数)

-- db/functions/inventory_ledger_triggers.sql
-- This file holds the SHARED trigger functions of the inventory ledger. The CREATE
-- TRIGGER attachments live with their tables: db/tables/inbound_batches.sql,
-- db/tables/output_batches.sql, db/tables/inventory_movements.sql.
-- (历史:批次表曾无镜像文件,挂载语句只好写在这里;2026-07-31 镜像漂移审计补齐了
-- 两张批次表的镜像后,挂载语句移了过去 —— 每张表的镜像现在完整描述它自己的触发器。)
--
-- Ledger rule: remaining_qty is a guarded cache; inventory_movements is the truth.
--   (a) emit-on-create        AFTER INSERT  on both batch tables  -> +remaining_qty in
--   (b) writeoff-on-softdelete BEFORE UPDATE on both batch tables -> -remaining_qty out, zero cache
--   (c) quantity guard        BEFORE UPDATE on both batch tables  -> quantity is immutable
--   (d) invariant             deferred constraint trigger on both batch tables + movements
--   immutability              BEFORE UPDATE OR DELETE on inventory_movements (rejects both)
--
-- Context marker: commit_processing_run / rollback_processing_run set
--   set_config('evoltrya.movement_ctx', 'processing:<run>' | 'reversal:<run>', true)
-- so the create/writeoff triggers can tag processing_produce / reversal_void with run_id.
--
-- NOTE: introduced by db/migrations/2026-07-03-phase2-cut1-inventory-ledger.sql.
-- Run AFTER inbound_batches/output_batches/inventory_movements exist. First-run script.

-- immutability: movements can never be updated or deleted (belt-and-braces on top of RLS)
CREATE OR REPLACE FUNCTION public.reject_movement_mutation()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    RAISE EXCEPTION 'MOVEMENT_IMMUTABLE';
END;
$fn$;

-- (a) emit-on-create: new stock in (receipt, or processing_produce under processing ctx)
CREATE OR REPLACE FUNCTION public.emit_batch_receipt_movement()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_ctx text := current_setting('evoltrya.movement_ctx', true);
    v_run uuid;
BEGIN
    IF NEW.remaining_qty IS NULL OR NEW.remaining_qty <= 0 THEN
        RETURN NULL;
    END IF;

    IF TG_TABLE_NAME = 'inbound_batches' THEN
        INSERT INTO public.inventory_movements (inbound_batch_id, movement_type, qty_delta, business_date, created_by)
        VALUES (NEW.id, 'receipt', NEW.remaining_qty, NEW.arrival_date, NEW.created_by);
    ELSE  -- output_batches
        IF v_ctx IS NOT NULL AND split_part(v_ctx, ':', 1) = 'processing' THEN
            v_run := split_part(v_ctx, ':', 2)::uuid;
            INSERT INTO public.inventory_movements (output_batch_id, movement_type, qty_delta, run_id, business_date, created_by)
            VALUES (NEW.id, 'processing_produce', NEW.remaining_qty, v_run, NEW.output_date, NEW.created_by);
        ELSE
            INSERT INTO public.inventory_movements (output_batch_id, movement_type, qty_delta, business_date, created_by)
            VALUES (NEW.id, 'receipt', NEW.remaining_qty, NEW.output_date, NEW.created_by);
        END IF;
    END IF;

    RETURN NULL;
END;
$function$;

-- (b) writeoff-on-softdelete: stock out + zero the cache (reversal_void under reversal ctx)
-- cut 2a (2026-07-06): 注销即入账 —— 已计值批次(进料 unit_price / 产出腿 unit_cost_base)
-- 追加 借 5200 / 贷 1200|1220 分录;reversal_void 不入账(加工产出从未入过 1220)。
CREATE OR REPLACE FUNCTION public.emit_batch_writeoff_movement()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_ctx   text := current_setting('evoltrya.movement_ctx', true);
    v_run   uuid;
    v_value numeric;
    v_acct  text;
    v_amt   numeric;
BEGIN
    IF OLD.remaining_qty > 0 THEN
        IF TG_TABLE_NAME = 'inbound_batches' THEN
            INSERT INTO public.inventory_movements (inbound_batch_id, movement_type, qty_delta, created_by)
            VALUES (OLD.id, 'writeoff', -OLD.remaining_qty, NEW.updated_by);
        ELSE  -- output_batches
            IF v_ctx IS NOT NULL AND split_part(v_ctx, ':', 1) = 'reversal' THEN
                v_run := split_part(v_ctx, ':', 2)::uuid;
                INSERT INTO public.inventory_movements (output_batch_id, movement_type, qty_delta, run_id, created_by)
                VALUES (OLD.id, 'reversal_void', -OLD.remaining_qty, v_run, NEW.updated_by);
            ELSE
                INSERT INTO public.inventory_movements (output_batch_id, movement_type, qty_delta, created_by)
                VALUES (OLD.id, 'writeoff', -OLD.remaining_qty, NEW.updated_by);
            END IF;
        END IF;

        -- cut 2a:注销即入账(仅已计值批次,借 5200 / 贷 1200|1220)。
        -- processing 回滚(reversal_void)不入账:本 cut 不记加工产出/消耗分录,
        -- void 的产出从未入过 1220,无可冲销。未计值批次只出量不入账。
        IF v_ctx IS NULL OR split_part(v_ctx, ':', 1) <> 'reversal' THEN
            IF TG_TABLE_NAME = 'inbound_batches' THEN
                v_value := OLD.unit_price;
                v_acct := '1200';
            ELSE
                SELECT po.unit_cost_base INTO v_value
                FROM public.processing_outputs po
                WHERE po.output_batch_id = OLD.id
                LIMIT 1;
                v_acct := '1220';
            END IF;
            IF v_value IS NOT NULL THEN
                v_amt := round(OLD.remaining_qty * v_value, 2);
                IF v_amt <> 0 THEN
                    PERFORM post_journal_entry(
                        CURRENT_DATE,
                        'Write-off ' || OLD.code,
                        'writeoff', OLD.id,
                        jsonb_build_array(
                            jsonb_build_object('account_code', '5200', 'side', 'debit',  'currency', 'SGD', 'amount_ccy', v_amt),
                            jsonb_build_object('account_code', v_acct, 'side', 'credit', 'currency', 'SGD', 'amount_ccy', v_amt)));
                END IF;
            END IF;
        END IF;

        NEW.remaining_qty := 0;
    END IF;
    RETURN NEW;
END;
$function$;

-- (c) quantity guard: quantity is immutable after creation
CREATE OR REPLACE FUNCTION public.reject_quantity_change()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    RAISE EXCEPTION 'QUANTITY_IMMUTABLE|%', OLD.code;
END;
$fn$;

-- (d) invariant: remaining_qty must equal Σ movements for the affected batch(es)
CREATE OR REPLACE FUNCTION public.check_ledger_invariant()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_inbound uuid;
    v_output  uuid;
    v_code    text;
    v_remaining numeric;
    v_sum     numeric;
BEGIN
    IF TG_TABLE_NAME = 'inbound_batches' THEN
        v_inbound := NEW.id;
    ELSIF TG_TABLE_NAME = 'output_batches' THEN
        v_output := NEW.id;
    ELSE  -- inventory_movements
        v_inbound := NEW.inbound_batch_id;
        v_output  := NEW.output_batch_id;
    END IF;

    IF v_inbound IS NOT NULL THEN
        SELECT code, remaining_qty INTO v_code, v_remaining FROM public.inbound_batches WHERE id = v_inbound;
        SELECT COALESCE(SUM(qty_delta), 0) INTO v_sum FROM public.inventory_movements WHERE inbound_batch_id = v_inbound;
        IF v_remaining IS DISTINCT FROM v_sum THEN
            RAISE EXCEPTION 'LEDGER_INVARIANT|%|%|%', v_code, v_remaining, v_sum;
        END IF;
    END IF;

    IF v_output IS NOT NULL THEN
        SELECT code, remaining_qty INTO v_code, v_remaining FROM public.output_batches WHERE id = v_output;
        SELECT COALESCE(SUM(qty_delta), 0) INTO v_sum FROM public.inventory_movements WHERE output_batch_id = v_output;
        IF v_remaining IS DISTINCT FROM v_sum THEN
            RAISE EXCEPTION 'LEDGER_INVARIANT|%|%|%', v_code, v_remaining, v_sum;
        END IF;
    END IF;

    RETURN NULL;
END;
$function$;

-- (trigger attachments moved to db/tables/inbound_batches.sql and
--  db/tables/output_batches.sql — see header)

CREATE OR REPLACE FUNCTION public.post_stocktake(p_stocktake_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user           uuid := auth.uid();
    v_st             record;
    v_line           record;
    v_code           text;
    v_current        numeric;
    v_deleted        timestamptz;
    v_delta          numeric;
    v_lines_total    integer := 0;
    v_lines_adjusted integer := 0;
    v_total_delta    numeric := 0;
    v_value          numeric;
    v_inv_acct       text;
    v_amt            numeric;
    v_je_lines       jsonb := '[]'::jsonb;
BEGIN
    PERFORM require_permission('module.stocktakes.edit');
    SELECT id, code, status, deleted_at INTO v_st
    FROM stocktakes WHERE id = p_stocktake_id FOR UPDATE;
    IF NOT FOUND OR v_st.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'STOCKTAKE_NOT_FOUND|%', p_stocktake_id;
    END IF;
    IF v_st.status <> 'open' THEN
        RAISE EXCEPTION 'STOCKTAKE_NOT_OPEN|%', v_st.status;
    END IF;

    FOR v_line IN SELECT * FROM stocktake_lines WHERE stocktake_id = p_stocktake_id
    LOOP
        v_lines_total := v_lines_total + 1;

        IF v_line.inbound_batch_id IS NOT NULL THEN
            SELECT code, remaining_qty, deleted_at, unit_price INTO v_code, v_current, v_deleted, v_value
            FROM inbound_batches WHERE id = v_line.inbound_batch_id FOR UPDATE;
            v_inv_acct := '1200';
        ELSE
            SELECT ob.code, ob.remaining_qty, ob.deleted_at, po.unit_cost_base
            INTO v_code, v_current, v_deleted, v_value
            FROM output_batches ob
            LEFT JOIN processing_outputs po ON po.output_batch_id = ob.id
            WHERE ob.id = v_line.output_batch_id
            FOR UPDATE OF ob;
            v_inv_acct := '1220';
        END IF;

        IF v_deleted IS NOT NULL THEN
            RAISE EXCEPTION 'BATCH_DELETED|%', v_code;
        END IF;

        v_delta := v_line.counted_qty - v_current;
        IF v_delta <> 0 THEN
            IF v_line.inbound_batch_id IS NOT NULL THEN
                INSERT INTO inventory_movements (inbound_batch_id, movement_type, qty_delta, business_date, notes, created_by)
                VALUES (v_line.inbound_batch_id, 'adjustment', v_delta, CURRENT_DATE,
                        'stocktake ' || v_st.code || COALESCE(': ' || v_line.notes, ''), v_user);
                UPDATE inbound_batches
                SET remaining_qty = v_line.counted_qty, updated_by = v_user, updated_at = now()
                WHERE id = v_line.inbound_batch_id;
            ELSE
                INSERT INTO inventory_movements (output_batch_id, movement_type, qty_delta, business_date, notes, created_by)
                VALUES (v_line.output_batch_id, 'adjustment', v_delta, CURRENT_DATE,
                        'stocktake ' || v_st.code || COALESCE(': ' || v_line.notes, ''), v_user);
                UPDATE output_batches
                SET remaining_qty = v_line.counted_qty, updated_by = v_user, updated_at = now()
                WHERE id = v_line.output_batch_id;
            END IF;
            v_lines_adjusted := v_lines_adjusted + 1;
            v_total_delta := v_total_delta + v_delta;

            -- cut 2a:有单值的差异行,成对累积分录行(盘盈:借库存 贷 5200;盘亏反向)。
            -- 无值(未计价进料 / 无成本产出)只调量不入账。
            IF v_value IS NOT NULL THEN
                v_amt := round(abs(v_delta) * v_value, 2);
                IF v_amt <> 0 THEN
                    IF v_delta > 0 THEN
                        v_je_lines := v_je_lines
                            || jsonb_build_object('account_code', v_inv_acct, 'side', 'debit',  'currency', 'SGD', 'amount_ccy', v_amt)
                            || jsonb_build_object('account_code', '5200',     'side', 'credit', 'currency', 'SGD', 'amount_ccy', v_amt);
                    ELSE
                        v_je_lines := v_je_lines
                            || jsonb_build_object('account_code', '5200',     'side', 'debit',  'currency', 'SGD', 'amount_ccy', v_amt)
                            || jsonb_build_object('account_code', v_inv_acct, 'side', 'credit', 'currency', 'SGD', 'amount_ccy', v_amt);
                    END IF;
                END IF;
            END IF;
        END IF;
    END LOOP;

    UPDATE stocktakes
    SET status = 'posted', posted_at = now(), updated_by = v_user, updated_at = now()
    WHERE id = p_stocktake_id;

    -- cut 2a:一张分录覆盖全部有值差异行(每行自成一对,天然自平)
    IF jsonb_array_length(v_je_lines) >= 2 THEN
        PERFORM post_journal_entry(
            CURRENT_DATE,
            'Stocktake ' || v_st.code,
            'stocktake', p_stocktake_id,
            v_je_lines);
    END IF;

    RETURN jsonb_build_object(
        'stocktake_id', p_stocktake_id,
        'code', v_st.code,
        'lines_total', v_lines_total,
        'lines_adjusted', v_lines_adjusted,
        'total_delta', v_total_delta
    );
END;
$function$;
CREATE OR REPLACE FUNCTION public.record_expense(p_expense_date date, p_account_code text, p_amount numeric, p_currency text DEFAULT 'SGD'::text, p_fx_rate numeric DEFAULT NULL::numeric, p_payment_status text DEFAULT 'paid'::text, p_bank_account text DEFAULT NULL::text, p_supplier_id uuid DEFAULT NULL::uuid, p_payee_name text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user       uuid := auth.uid();
    v_account    record;
    v_fx         numeric;
    v_amount_base numeric;
    v_bank       text;
    v_expense_id uuid := gen_random_uuid();
    v_year       integer;
    v_seq        integer;
    v_code       text;
    v_je         jsonb;
BEGIN
    PERFORM require_permission('module.finance.edit');
    -- 1. 科目:必须存在、启用,且是 expense 类型(只有 6xxx 是合法开支落点)
    IF p_expense_date IS NULL THEN
        RAISE EXCEPTION 'JE_LINE_INVALID|entry_date';
    END IF;
    SELECT code, is_active, account_type INTO v_account
    FROM accounts WHERE code = p_account_code;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ACCOUNT_NOT_FOUND|%', COALESCE(p_account_code, '?');
    END IF;
    IF NOT v_account.is_active THEN
        RAISE EXCEPTION 'ACCOUNT_INACTIVE|%', v_account.code;
    END IF;
    IF v_account.account_type <> 'expense' THEN
        RAISE EXCEPTION 'ACCOUNT_NOT_EXPENSE|%', v_account.code;
    END IF;

    -- 2. 金额/币种/汇率(FIN-0:SGD 本位免换算,外币按费用日牌价估值)
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'AMOUNT_INVALID';
    END IF;
    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = p_currency) THEN
        RAISE EXCEPTION 'CURRENCY_INVALID|%', COALESCE(p_currency, '?');
    END IF;
    -- FIN-0:本位币 SGD 免换算;外币按【费用日】的行方卖出价(tt_sell)估值 ——
    -- 应付与开销是我们将来要【向银行买】的外币。当日无牌价即拒(FX_RATE_MISSING)。
    -- 汇率不再由调用方递入:牌价属于 fx_rates,不属于表单。
    IF p_fx_rate IS NOT NULL THEN
        RAISE EXCEPTION 'FX_RATE_NOT_ACCEPTED|%', p_currency;
    END IF;
    v_fx := fx_rate_for(p_currency, p_expense_date, 'tt_sell');

    -- 3. 支付状态
    IF p_payment_status IS NULL OR p_payment_status NOT IN ('paid','unpaid') THEN
        RAISE EXCEPTION 'PAYMENT_STATUS_INVALID|%', COALESCE(p_payment_status, '?');
    END IF;

    IF p_payment_status = 'paid' THEN
        -- paid:银行科目显式给了必须合法;不给按币种默认(SGD → 1000,USD → 1010)
        IF p_bank_account IS NOT NULL THEN
            IF p_bank_account NOT IN ('1000','1010') THEN
                RAISE EXCEPTION 'BANK_INVALID|%', p_bank_account;
            END IF;
            v_bank := p_bank_account;
        ELSE
            v_bank := CASE WHEN p_currency = 'SGD' THEN '1000' ELSE '1010' END;
        END IF;
    ELSE
        -- unpaid:必须有在册供应商(它要成为 AP 单据);银行科目必须为空 ——
        -- 传了也直接忽略(挂账时根本没动银行,存下来只会误导)
        IF p_supplier_id IS NULL THEN
            RAISE EXCEPTION 'SUPPLIER_REQUIRED_FOR_UNPAID';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM suppliers WHERE id = p_supplier_id AND deleted_at IS NULL) THEN
            RAISE EXCEPTION 'SUPPLIER_NOT_FOUND|%', p_supplier_id;
        END IF;
        v_bank := NULL;
    END IF;

    -- 4. USD 金额
    v_amount_base := round(p_amount * v_fx, 2);

    -- 5. 无缝编号:咨询锁串行化"取当年最大号+1"(同 JE/收付款编号手法);失败回滚会释放号码。
    v_year := EXTRACT(YEAR FROM p_expense_date)::integer;
    PERFORM pg_advisory_xact_lock(hashtext('expense_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM expenses
    WHERE code LIKE 'EXP-' || v_year::text || '-%';
    v_code := 'EXP-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');

    -- 6. 先过分录(source_id = 预生成的 expense id,无需回填),期间锁在此生效。
    --    paid → 贷银行;unpaid → 贷 2000 应付。行走原币。
    v_je := post_journal_entry(
        p_expense_date,
        'Expense ' || v_code || ' ' || p_account_code,
        'expense', v_expense_id,
        jsonb_build_array(
            jsonb_build_object('account_code', p_account_code, 'side', 'debit',
                               'currency', p_currency, 'amount_ccy', p_amount, 'fx_rate', v_fx),
            jsonb_build_object('account_code', CASE WHEN p_payment_status = 'paid' THEN v_bank ELSE '2000' END,
                               'side', 'credit',
                               'currency', p_currency, 'amount_ccy', p_amount, 'fx_rate', v_fx))
    );

    -- 7. 插入开支单(带着分录链接一次到位;不可变表无后续 UPDATE)
    INSERT INTO expenses (id, code, expense_date, account_code, amount_ccy, currency, fx_rate,
                          amount_base, payment_status, bank_account_code, supplier_id,
                          payee_name, notes, journal_entry_id, created_by)
    VALUES (v_expense_id, v_code, p_expense_date, p_account_code, p_amount, p_currency, v_fx,
            v_amount_base, p_payment_status, v_bank, p_supplier_id,
            p_payee_name, p_notes, (v_je->>'entry_id')::uuid, v_user);

    RETURN jsonb_build_object(
        'expense_id', v_expense_id,
        'code', v_code,
        'amount_base', v_amount_base,
        'journal_code', v_je->>'code',
        'payment_status', p_payment_status
    );
END;
$function$;
CREATE OR REPLACE FUNCTION public.record_output_sale(p_output_batch_id uuid, p_quantity numeric, p_unit_price numeric, p_currency text, p_fx_rate numeric DEFAULT NULL::numeric, p_customer_id uuid DEFAULT NULL::uuid, p_sale_date date DEFAULT NULL::date, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user          uuid := auth.uid();
    v_deleted       timestamptz;
    v_remaining     numeric;
    v_code          text;
    v_new_remaining numeric;
    v_state         text;
    v_fx            numeric;
    v_amount_base    numeric;
    v_movement_id   uuid;
    v_sale_id       uuid;
    v_sale_date     date := COALESCE(p_sale_date, CURRENT_DATE);
    v_unit_cost     numeric;
    v_cogs          numeric;
    v_je1           jsonb;
    v_je2           jsonb;
BEGIN
    PERFORM require_permission('module.output.edit');
    SELECT deleted_at, remaining_qty, code INTO v_deleted, v_remaining, v_code
    FROM output_batches WHERE id = p_output_batch_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', p_output_batch_id;
    END IF;
    IF v_deleted IS NOT NULL THEN
        RAISE EXCEPTION 'OUTPUT_DELETED';
    END IF;
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'SALE_QTY_INVALID';
    END IF;
    IF p_quantity > v_remaining THEN
        RAISE EXCEPTION 'SALE_EXCEEDS_REMAINING|%|%', p_quantity, v_remaining;
    END IF;

    IF p_unit_price IS NULL OR p_unit_price <= 0 THEN
        RAISE EXCEPTION 'SALE_PRICE_INVALID';
    END IF;
    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = p_currency) THEN
        RAISE EXCEPTION 'CURRENCY_INVALID|%', COALESCE(p_currency, '?');
    END IF;
    -- FIN-0:本位币 SGD 免换算;外币按【交易日】的行方买入价(tt_buy)估值 ——
    -- 收入与应收是我们将来要【卖给银行】的外币。当日无牌价即拒(FX_RATE_MISSING),
    -- 不许悄悄用最近一天的。汇率不再由调用方递入:牌价属于 fx_rates,不属于表单。
    IF p_fx_rate IS NOT NULL THEN
        RAISE EXCEPTION 'FX_RATE_NOT_ACCEPTED|%', p_currency;
    END IF;
    v_fx := fx_rate_for(p_currency, v_sale_date, 'tt_buy');
    v_amount_base := round(p_quantity * p_unit_price * v_fx, 2);

    INSERT INTO inventory_movements (output_batch_id, movement_type, qty_delta, business_date, notes, created_by)
    VALUES (p_output_batch_id, 'sale', -p_quantity, v_sale_date, p_notes, v_user)
    RETURNING id INTO v_movement_id;

    -- customer_id 有效性由 FK 把关(可空:批次可能未指定客户)
    INSERT INTO sales_records (output_batch_id, customer_id, quantity, unit_price, currency, fx_rate, amount_base, sale_date, notes, movement_id, created_by)
    VALUES (p_output_batch_id, p_customer_id, p_quantity, p_unit_price, p_currency, v_fx, v_amount_base, v_sale_date, p_notes, v_movement_id, v_user)
    RETURNING id INTO v_sale_id;

    -- cut 2a JE#1:收入 —— 借 1100 / 贷 4000,原币行(amount_ccy = qty × price,
    -- fx 原样),USD 侧由 post_journal_entry 折算,与 amount_base 同式同值。
    v_je1 := post_journal_entry(
        v_sale_date,
        'Sale ' || v_code,
        'sale', v_sale_id,
        jsonb_build_array(
            jsonb_build_object('account_code', '1100', 'side', 'debit',  'currency', p_currency, 'amount_ccy', p_quantity * p_unit_price, 'fx_rate', v_fx),
            jsonb_build_object('account_code', '4000', 'side', 'credit', 'currency', p_currency, 'amount_ccy', p_quantity * p_unit_price, 'fx_rate', v_fx)));

    -- cut 2a JE#2:COGS —— 有产出腿单位成本才挂;没有则只挂收入(cogs_journal 为
    -- null),等 allocate_processing_costs 补挂(见其 COGS catch-up)。
    SELECT po.unit_cost_base INTO v_unit_cost
    FROM processing_outputs po
    WHERE po.output_batch_id = p_output_batch_id
    LIMIT 1;

    IF v_unit_cost IS NOT NULL THEN
        v_cogs := round(p_quantity * v_unit_cost, 2);
        IF v_cogs <> 0 THEN
            v_je2 := post_journal_entry(
                v_sale_date,
                'COGS ' || v_code,
                'sale', v_sale_id,
                jsonb_build_array(
                    jsonb_build_object('account_code', '5000', 'side', 'debit',  'currency', 'SGD', 'amount_ccy', v_cogs),
                    jsonb_build_object('account_code', '1220', 'side', 'credit', 'currency', 'SGD', 'amount_ccy', v_cogs)));
            UPDATE sales_records SET cogs_entry_id = (v_je2->>'entry_id')::uuid WHERE id = v_sale_id;
        END IF;
    END IF;

    v_new_remaining := v_remaining - p_quantity;
    v_state := CASE WHEN v_new_remaining = 0 THEN '已售罄' ELSE '部分售出' END;

    UPDATE output_batches
    SET remaining_qty = v_new_remaining,
        state = v_state,
        updated_by = v_user,
        updated_at = now()
    WHERE id = p_output_batch_id;

    RETURN jsonb_build_object(
        'output_batch_id', p_output_batch_id,
        'sold', p_quantity,
        'remaining_qty', v_new_remaining,
        'state', v_state,
        'sale_id', v_sale_id,
        'amount_base', v_amount_base,
        'revenue_journal', v_je1->>'code',
        'cogs_journal', v_je2->>'code'
    );
END;
$function$;
CREATE OR REPLACE FUNCTION public.record_payment(p_direction text, p_counterparty_id uuid, p_amount numeric, p_currency text, p_fx_rate numeric DEFAULT NULL::numeric, p_bank_account text DEFAULT NULL::text, p_payment_date date DEFAULT NULL::date, p_notes text DEFAULT NULL::text, p_allocations jsonb DEFAULT '[]'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user         uuid := auth.uid();
    v_date         date := COALESCE(p_payment_date, CURRENT_DATE);
    v_fx           numeric;
    v_amount_base   numeric;
    v_bank         text;
    v_payment_id   uuid := gen_random_uuid();
    v_code         text;
    v_alloc        jsonb;
    v_sale_id      uuid;
    v_batch_id     uuid;
    v_expense_id   uuid;
    v_po_id        uuid;
    v_alloc_usd    numeric;
    v_doc          record;
    v_doc_value    numeric;
    v_settled      numeric;
    v_open         numeric;
    v_alloc_total  numeric := 0;
    v_je           jsonb;
    -- 拆账与两遍处理用
    v_key          text;
    v_running      jsonb := '{}'::jsonb;   -- 目标 id → 本笔内已累计核销额
    v_prior        numeric;
    v_valid        jsonb := '[]'::jsonb;   -- ①校验通过的核销行,②之后据此落库
    v_po_usd       numeric := 0;           -- 本笔中指向 PO 的预付合计(USD)
    v_ap_usd       numeric;
    v_po_ccy       numeric;
    v_ap_ccy       numeric;
    v_cap          numeric;
    v_delta        numeric;
    v_found        boolean;
    v_lines        jsonb;
BEGIN
    PERFORM require_permission('module.finance.edit');
    -- 1. 基础校验
    IF p_direction IS NULL OR p_direction NOT IN ('in','out') THEN
        RAISE EXCEPTION 'DIRECTION_INVALID|%', COALESCE(p_direction, '?');
    END IF;

    IF p_direction = 'in' THEN
        IF p_counterparty_id IS NULL OR NOT EXISTS (
            SELECT 1 FROM customers WHERE id = p_counterparty_id AND deleted_at IS NULL
        ) THEN
            RAISE EXCEPTION 'COUNTERPARTY_NOT_FOUND|%', COALESCE(p_counterparty_id::text, '?');
        END IF;
    ELSE
        IF p_counterparty_id IS NULL OR NOT EXISTS (
            SELECT 1 FROM suppliers WHERE id = p_counterparty_id AND deleted_at IS NULL
        ) THEN
            RAISE EXCEPTION 'COUNTERPARTY_NOT_FOUND|%', COALESCE(p_counterparty_id::text, '?');
        END IF;
    END IF;

    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'AMOUNT_INVALID';
    END IF;
    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = p_currency) THEN
        RAISE EXCEPTION 'CURRENCY_INVALID|%', COALESCE(p_currency, '?');
    END IF;
    -- FIN-0 三分支:
    --   SGD(本位)                → 1,无换算;
    --   外币、且走该币种的外币户   → 没有发生兑换,按【付款日】牌价估值:
    --                                收款 tt_buy / 付款 tt_sell,当日无牌价即拒;
    --   外币、但走的不是该币种的户 → 银行【实际做了兑换】,必须递入按银行水单
    --                                实际金额折出的汇率(C4:实际兑换用实际数,
    --                                永远不用牌价);此时 p_fx_rate 必填。
    IF p_currency = 'SGD' THEN
        IF p_fx_rate IS NOT NULL THEN
            RAISE EXCEPTION 'FX_RATE_NOT_ACCEPTED|%', p_currency;
        END IF;
        v_fx := 1;
    ELSIF bank_native_currency(COALESCE(p_bank_account,
              CASE WHEN p_currency = 'SGD' THEN '1000' ELSE '1010' END)) = p_currency THEN
        IF p_fx_rate IS NOT NULL THEN
            RAISE EXCEPTION 'FX_RATE_NOT_ACCEPTED|%', p_currency;
        END IF;
        v_fx := fx_rate_for(p_currency, COALESCE(p_payment_date, CURRENT_DATE),
                            CASE WHEN p_direction = 'in' THEN 'tt_buy' ELSE 'tt_sell' END);
    ELSE
        IF p_fx_rate IS NULL THEN
            RAISE EXCEPTION 'FX_RATE_REQUIRED|%', p_currency;
        END IF;
        IF p_fx_rate <= 0 THEN
            RAISE EXCEPTION 'FX_RATE_INVALID|%', p_fx_rate;
        END IF;
        v_fx := p_fx_rate;
    END IF;

    -- 银行科目:显式给了必须合法;不给按币种默认(SGD → 1000,USD → 1010)
    IF p_bank_account IS NOT NULL THEN
        IF p_bank_account NOT IN ('1000','1010') THEN
            RAISE EXCEPTION 'BANK_INVALID|%', p_bank_account;
        END IF;
        v_bank := p_bank_account;
    ELSE
        v_bank := CASE WHEN p_currency = 'SGD' THEN '1000' ELSE '1010' END;
    END IF;

    -- 2. USD 金额
    v_amount_base := round(p_amount * v_fx, 2);

    IF p_allocations IS NULL OR jsonb_typeof(p_allocations) <> 'array' THEN
        RAISE EXCEPTION 'ALLOC_INVALID|not_an_array';
    END IF;

    -- ========================================================================
    -- ① 核销行:逐条校验,不落库。顺序:存在 → 归属 → 计价 → 敞口。
    --    'in' 只认 sales_record_id;'out' 认 inbound_batch_id / expense_id /
    --    purchase_order_id(预付)。
    -- ========================================================================
    FOR v_alloc IN SELECT * FROM jsonb_array_elements(p_allocations)
    LOOP
        v_sale_id    := (v_alloc->>'sales_record_id')::uuid;
        v_batch_id   := (v_alloc->>'inbound_batch_id')::uuid;
        v_expense_id := (v_alloc->>'expense_id')::uuid;
        v_po_id      := (v_alloc->>'purchase_order_id')::uuid;
        v_alloc_usd  := (v_alloc->>'amount_base')::numeric;

        IF v_alloc_usd IS NULL OR v_alloc_usd <= 0
           OR num_nonnulls(v_sale_id, v_batch_id, v_expense_id, v_po_id) <> 1 THEN
            RAISE EXCEPTION 'ALLOC_INVALID|%', v_alloc::text;
        END IF;

        IF p_direction = 'in' THEN
            IF v_batch_id IS NOT NULL OR v_expense_id IS NOT NULL OR v_po_id IS NOT NULL THEN
                RAISE EXCEPTION 'ALLOC_WRONG_SIDE';
            END IF;
            SELECT sr.id, ob.code AS doc_code, sr.customer_id AS party_id, sr.amount_base AS doc_value
            INTO v_doc
            FROM sales_records sr
            JOIN output_batches ob ON ob.id = sr.output_batch_id
            WHERE sr.id = v_sale_id;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'ALLOC_INVALID|%', v_sale_id;
            END IF;
            IF v_doc.party_id IS DISTINCT FROM p_counterparty_id THEN
                RAISE EXCEPTION 'ALLOC_WRONG_PARTY|%', v_doc.doc_code;
            END IF;
            v_doc_value := v_doc.doc_value;
            v_key := v_sale_id::text;

            SELECT COALESCE(SUM(pa.allocated_base), 0) INTO v_settled
            FROM payment_allocations pa
            JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
            WHERE pa.sales_record_id = v_sale_id;

        ELSIF v_po_id IS NOT NULL THEN
            -- 预付款:PO 上【没有敞口上限】—— 定金不是在还债,那一刻还没有债。
            -- 唯一的栏杆是"累计预付不得超过估算总额 × 1.5",防手滑多打一个零。
            SELECT po.id, po.code AS doc_code, po.supplier_id AS party_id,
                   po.estimated_total_usd, po.status AS po_status
            INTO v_doc
            FROM purchase_orders po
            WHERE po.id = v_po_id AND po.deleted_at IS NULL;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'ALLOC_INVALID|%', v_po_id;
            END IF;
            IF v_doc.po_status = 'cancelled' THEN
                RAISE EXCEPTION 'ALLOC_INVALID|%', v_doc.doc_code;
            END IF;
            IF v_doc.party_id IS DISTINCT FROM p_counterparty_id THEN
                RAISE EXCEPTION 'ALLOC_WRONG_PARTY|%', v_doc.doc_code;
            END IF;
            v_key := v_po_id::text;

            SELECT COALESCE(SUM(pa.allocated_base), 0) INTO v_settled
            FROM payment_allocations pa
            JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
            WHERE pa.purchase_order_id = v_po_id;

            -- 1.5 倍是【刻意留出的余量】:估算按谈价时的行情算,实际化验和金属价格
            -- 波动都会把真实金额顶高,预付超过估算是正常的;超过一半就不正常了。
            v_cap := round(v_doc.estimated_total_usd * 1.5, 2);
            v_prior := COALESCE((v_running->>v_key)::numeric, 0);
            IF round(v_settled + v_prior + v_alloc_usd, 2) > v_cap THEN
                RAISE EXCEPTION 'PREPAY_EXCEEDS_ESTIMATE|%|%|%',
                    v_doc.doc_code, round(v_settled + v_prior + v_alloc_usd, 2), v_cap;
            END IF;

            v_po_usd := round(v_po_usd + v_alloc_usd, 2);
            v_doc_value := NULL;  -- 无敞口上限,跳过下面的 ALLOC_EXCEEDS

        ELSIF v_batch_id IS NOT NULL THEN
            IF v_sale_id IS NOT NULL THEN
                RAISE EXCEPTION 'ALLOC_WRONG_SIDE';
            END IF;
            SELECT ib.id, ib.code AS doc_code, ib.supplier_id AS party_id,
                   ib.unit_price, ib.quantity
            INTO v_doc
            FROM inbound_batches ib
            WHERE ib.id = v_batch_id AND ib.deleted_at IS NULL;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'ALLOC_INVALID|%', v_batch_id;
            END IF;
            IF v_doc.party_id IS DISTINCT FROM p_counterparty_id THEN
                RAISE EXCEPTION 'ALLOC_WRONG_PARTY|%', v_doc.doc_code;
            END IF;
            IF v_doc.unit_price IS NULL THEN
                RAISE EXCEPTION 'ALLOC_UNPRICED|%', v_doc.doc_code;
            END IF;
            -- 应付额永远对着"当前"批次价值(改价即改欠款)
            v_doc_value := round(v_doc.quantity * v_doc.unit_price, 2);
            v_key := v_batch_id::text;

            -- 已结 = 收付款核销 + 预付冲抵(B6 起,预付冲抵也在还这张单的应付)
            SELECT COALESCE(SUM(pa.allocated_base), 0) INTO v_settled
            FROM payment_allocations pa
            JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
            WHERE pa.inbound_batch_id = v_batch_id;
            v_settled := v_settled + COALESCE(
                (SELECT SUM(ppa.amount_base) FROM prepayment_applications ppa
                  WHERE ppa.inbound_batch_id = v_batch_id), 0);

        ELSE
            IF v_sale_id IS NOT NULL THEN
                RAISE EXCEPTION 'ALLOC_WRONG_SIDE';
            END IF;
            -- 挂账开支:必须是 unpaid + posted(不存在/已付/已冲销 → ALLOC_INVALID)
            SELECT e.id, e.code AS doc_code, e.supplier_id AS party_id, e.amount_base AS doc_value
            INTO v_doc
            FROM expenses e
            WHERE e.id = v_expense_id AND e.payment_status = 'unpaid' AND e.status = 'posted';
            IF NOT FOUND THEN
                RAISE EXCEPTION 'ALLOC_INVALID|%', v_expense_id;
            END IF;
            IF v_doc.party_id IS DISTINCT FROM p_counterparty_id THEN
                RAISE EXCEPTION 'ALLOC_WRONG_PARTY|%', v_doc.doc_code;
            END IF;
            v_doc_value := v_doc.doc_value;
            v_key := v_expense_id::text;

            SELECT COALESCE(SUM(pa.allocated_base), 0) INTO v_settled
            FROM payment_allocations pa
            JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
            WHERE pa.expense_id = v_expense_id;
        END IF;

        -- 敞口校验(预付除外:v_doc_value 为 NULL)。v_running 让同一目标在同一笔里
        -- 出现两次时,后一条能看见前一条 —— 原实现靠"边插边查"拿到的就是这个语义。
        IF v_doc_value IS NOT NULL THEN
            v_prior := COALESCE((v_running->>v_key)::numeric, 0);
            v_open := round(v_doc_value - v_settled - v_prior, 2);
            IF v_alloc_usd > v_open THEN
                RAISE EXCEPTION 'ALLOC_EXCEEDS|%|%|%', v_doc.doc_code, v_alloc_usd, v_open;
            END IF;
        END IF;

        v_running := v_running || jsonb_build_object(
            v_key, COALESCE((v_running->>v_key)::numeric, 0) + v_alloc_usd);
        v_valid := v_valid || jsonb_build_array(jsonb_build_object(
            'sales_record_id', v_sale_id, 'inbound_batch_id', v_batch_id,
            'expense_id', v_expense_id, 'purchase_order_id', v_po_id,
            'amount_base', v_alloc_usd));
        v_alloc_total := v_alloc_total + v_alloc_usd;
    END LOOP;

    -- Σ 核销不得超过款额(欠核销 = 挂账余额,允许)
    IF v_alloc_total > v_amount_base THEN
        RAISE EXCEPTION 'ALLOC_EXCEEDS_PAYMENT|%|%', v_alloc_total, v_amount_base;
    END IF;

    -- ========================================================================
    -- ② 分录。'out' 且本笔含 PO 预付时【拆两条借方】:
    --      借 1300 预付款项  = 指向 PO 的部分
    --      借 2000 应付账款  = 其余(含未核销部分 —— 与改动前对全额借 2000 一致)
    --      贷 银行          = 全额
    --    金额:核销额是 USD,分录行按原币记,故 po_ccy = round(po_usd / fx, 2),
    --    ap_ccy = p_amount − po_ccy(【相减而非各自取整】,保证两条借方的原币恰好
    --    合计等于贷方)。USD 侧由 post_journal_entry 用 round(ccy × fx, 2) 反算,
    --    非本位币下双重取整可能差 1 分,故下面在 ±0.02 内挑一个能让 USD 恰好配平的
    --    拆分点(USD 付款 fx=1,偏移恒为 0)。
    -- ========================================================================
    v_code := fin_next_payment_code(CASE WHEN p_direction = 'in' THEN 'RCPT' ELSE 'PMT' END, v_date);

    IF p_direction = 'in' THEN
        v_lines := jsonb_build_array(
            jsonb_build_object('account_code', v_bank, 'side', 'debit',  'currency', p_currency, 'amount_ccy', p_amount, 'fx_rate', v_fx),
            jsonb_build_object('account_code', '1100', 'side', 'credit', 'currency', p_currency, 'amount_ccy', p_amount, 'fx_rate', v_fx));
    ELSIF v_po_usd = 0 THEN
        -- 无预付:与改动前逐字一致
        v_lines := jsonb_build_array(
            jsonb_build_object('account_code', '2000', 'side', 'debit',  'currency', p_currency, 'amount_ccy', p_amount, 'fx_rate', v_fx),
            jsonb_build_object('account_code', v_bank, 'side', 'credit', 'currency', p_currency, 'amount_ccy', p_amount, 'fx_rate', v_fx));
    ELSE
        v_ap_usd := round(v_amount_base - v_po_usd, 2);
        IF v_ap_usd <= 0 THEN
            -- 整笔都是预付:只有一条借方,不能出现 0 元行(post_journal_entry 会拒)
            v_lines := jsonb_build_array(
                jsonb_build_object('account_code', '1300', 'side', 'debit',  'currency', p_currency, 'amount_ccy', p_amount, 'fx_rate', v_fx),
                jsonb_build_object('account_code', v_bank, 'side', 'credit', 'currency', p_currency, 'amount_ccy', p_amount, 'fx_rate', v_fx));
        ELSE
            v_po_ccy := round(v_po_usd / v_fx, 2);
            v_found := false;
            FOREACH v_delta IN ARRAY ARRAY[0, 0.01, -0.01, 0.02, -0.02]::numeric[]
            LOOP
                IF v_po_ccy + v_delta > 0 AND p_amount - (v_po_ccy + v_delta) > 0
                   AND round((v_po_ccy + v_delta) * v_fx, 2)
                       + round((p_amount - v_po_ccy - v_delta) * v_fx, 2) = v_amount_base THEN
                    v_po_ccy := v_po_ccy + v_delta;
                    v_found := true;
                    EXIT;
                END IF;
            END LOOP;
            IF NOT v_found THEN
                RAISE EXCEPTION 'PREPAY_SPLIT_UNBALANCED|%|%|%', v_amount_base, v_po_usd, v_fx;
            END IF;
            v_ap_ccy := p_amount - v_po_ccy;
            v_lines := jsonb_build_array(
                jsonb_build_object('account_code', '1300', 'side', 'debit',  'currency', p_currency, 'amount_ccy', v_po_ccy, 'fx_rate', v_fx, 'line_memo', 'Prepayment'),
                jsonb_build_object('account_code', '2000', 'side', 'debit',  'currency', p_currency, 'amount_ccy', v_ap_ccy, 'fx_rate', v_fx),
                jsonb_build_object('account_code', v_bank, 'side', 'credit', 'currency', p_currency, 'amount_ccy', p_amount, 'fx_rate', v_fx));
        END IF;
    END IF;

    v_je := post_journal_entry(
        v_date,
        CASE WHEN p_direction = 'in' THEN 'Receipt ' ELSE 'Payment ' END || v_code,
        'payment', v_payment_id, v_lines);

    -- ③ 插入收付款单(带着分录链接一次到位;不可变表无后续 UPDATE)
    INSERT INTO payments (id, code, direction, counterparty_type, customer_id, supplier_id,
                          amount_ccy, currency, fx_rate, amount_base, bank_account_code,
                          payment_date, notes, journal_entry_id, created_by)
    VALUES (v_payment_id, v_code, p_direction,
            CASE WHEN p_direction = 'in' THEN 'customer' ELSE 'supplier' END,
            CASE WHEN p_direction = 'in' THEN p_counterparty_id END,
            CASE WHEN p_direction = 'out' THEN p_counterparty_id END,
            p_amount, p_currency, v_fx, v_amount_base, v_bank,
            v_date, p_notes, (v_je->>'entry_id')::uuid, v_user);

    -- ④ 核销行落库(①已全部校验过,这里只写)
    FOR v_alloc IN SELECT * FROM jsonb_array_elements(v_valid)
    LOOP
        INSERT INTO payment_allocations (payment_id, sales_record_id, inbound_batch_id,
                                         expense_id, purchase_order_id, allocated_base)
        VALUES (v_payment_id,
                (v_alloc->>'sales_record_id')::uuid,
                (v_alloc->>'inbound_batch_id')::uuid,
                (v_alloc->>'expense_id')::uuid,
                (v_alloc->>'purchase_order_id')::uuid,
                (v_alloc->>'amount_base')::numeric);
    END LOOP;

    RETURN jsonb_build_object(
        'payment_id', v_payment_id,
        'code', v_code,
        'amount_base', v_amount_base,
        'journal_code', v_je->>'code',
        'allocated_total', v_alloc_total,
        'unallocated', round(v_amount_base - v_alloc_total, 2),
        'prepaid_total', v_po_usd
    );
END;
$function$;
CREATE OR REPLACE FUNCTION public.reverse_expense(p_expense_id uuid, p_memo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_orig        expenses%ROWTYPE;
    v_mirror_id   uuid := gen_random_uuid();
    v_year        integer;
    v_seq         integer;
    v_mirror_code text;
    v_je          jsonb;
BEGIN
    PERFORM require_permission('module.finance.edit');
    SELECT * INTO v_orig FROM expenses WHERE id = p_expense_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'EXPENSE_NOT_FOUND|%', p_expense_id;
    END IF;
    IF v_orig.status <> 'posted' OR v_orig.reversed_by_expense IS NOT NULL THEN
        RAISE EXCEPTION 'EXPENSE_ALREADY_REVERSED|%', v_orig.code;
    END IF;

    -- 冲其分录(冲销日 = 今天;期间锁在 post_journal_entry 内生效)
    v_je := reverse_journal_entry_internal(v_orig.journal_entry_id, CURRENT_DATE, 'Expense reversal ' || v_orig.code);

    -- 镜像开支单(同形状、status 'posted'、挂冲销分录、不带核销行)。
    -- 镜像行只是冲销的记录凭证,不是新的应付单据 —— ap_open_items 里按
    -- "被别的开支单指为 reversed_by_expense" 排除它。
    v_year := EXTRACT(YEAR FROM CURRENT_DATE)::integer;
    PERFORM pg_advisory_xact_lock(hashtext('expense_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM expenses
    WHERE code LIKE 'EXP-' || v_year::text || '-%';
    v_mirror_code := 'EXP-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');

    INSERT INTO expenses (id, code, expense_date, account_code, amount_ccy, currency, fx_rate,
                          amount_base, payment_status, bank_account_code, supplier_id,
                          payee_name, notes, journal_entry_id, created_by)
    VALUES (v_mirror_id, v_mirror_code, CURRENT_DATE, v_orig.account_code,
            v_orig.amount_ccy, v_orig.currency, v_orig.fx_rate, v_orig.amount_base,
            v_orig.payment_status, v_orig.bank_account_code, v_orig.supplier_id,
            v_orig.payee_name,
            'REVERSAL: ' || v_orig.code || COALESCE(' — ' || p_memo, ''),
            (v_je->>'reversal_id')::uuid, auth.uid());

    UPDATE expenses
    SET status = 'reversed', reversed_by_expense = v_mirror_id
    WHERE id = p_expense_id;

    RETURN jsonb_build_object(
        'reversal_expense_id', v_mirror_id,
        'code', v_mirror_code,
        'journal_code', v_je->>'code'
    );
END;
$function$;
CREATE OR REPLACE FUNCTION public.reverse_payment(p_payment_id uuid, p_memo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_orig        payments%ROWTYPE;
    v_mirror_id   uuid := gen_random_uuid();
    v_mirror_code text;
    v_je          jsonb;
BEGIN
    PERFORM require_permission('module.finance.edit');
    SELECT * INTO v_orig FROM payments WHERE id = p_payment_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PAYMENT_NOT_FOUND|%', p_payment_id;
    END IF;
    IF v_orig.status <> 'posted' OR v_orig.reversed_by_payment IS NOT NULL THEN
        RAISE EXCEPTION 'PAYMENT_ALREADY_REVERSED|%', v_orig.code;
    END IF;

    -- 冲其分录(冲销日 = 今天;期间锁在 post_journal_entry 内生效)
    v_je := reverse_journal_entry_internal(v_orig.journal_entry_id, CURRENT_DATE, 'Payment reversal ' || v_orig.code);

    -- 镜像收付款单(现金退回),挂冲销分录,不带核销行
    v_mirror_code := fin_next_payment_code(CASE WHEN v_orig.direction = 'in' THEN 'RCPT' ELSE 'PMT' END, CURRENT_DATE);
    INSERT INTO payments (id, code, direction, counterparty_type, customer_id, supplier_id,
                          amount_ccy, currency, fx_rate, amount_base, bank_account_code,
                          payment_date, notes, journal_entry_id, created_by)
    VALUES (v_mirror_id, v_mirror_code, v_orig.direction, v_orig.counterparty_type,
            v_orig.customer_id, v_orig.supplier_id,
            v_orig.amount_ccy, v_orig.currency, v_orig.fx_rate, v_orig.amount_base,
            v_orig.bank_account_code, CURRENT_DATE,
            'REVERSAL: ' || v_orig.code || COALESCE(' — ' || p_memo, ''),
            (v_je->>'reversal_id')::uuid, auth.uid());

    UPDATE payments
    SET status = 'reversed', reversed_by_payment = v_mirror_id
    WHERE id = p_payment_id;

    RETURN jsonb_build_object(
        'reversal_payment_id', v_mirror_id,
        'code', v_mirror_code,
        'journal_code', v_je->>'code'
    );
END;
$function$;
-- ── 暴露这些列的视图:输出列名跟着改(改名需 DROP 后按依赖序重建)──
DROP VIEW IF EXISTS public.processing_runs_masked;
DROP VIEW IF EXISTS public.processing_outputs_masked;
DROP VIEW IF EXISTS public.processing_cost_entries_masked;
DROP VIEW IF EXISTS public.purchase_order_status;
DROP VIEW IF EXISTS public.po_prepayment_applicable;
DROP VIEW IF EXISTS public.prepayment_applications_masked;
DROP VIEW IF EXISTS public.medical_claim_status;
DROP VIEW IF EXISTS public.ap_open_items;
DROP VIEW IF EXISTS public.ar_open_items;
DROP VIEW IF EXISTS public.sales_records_visible;
DROP VIEW IF EXISTS public.sales_records_masked;
DROP VIEW IF EXISTS public.invoice_status;
DROP VIEW IF EXISTS public.invoice_lines_masked;
DROP VIEW IF EXISTS public.invoices_masked;

CREATE VIEW public.invoices_masked WITH (security_invoker = off) AS
 SELECT id,
    code,
    customer_id,
    issue_date,
    due_date,
    payment_terms_days,
    currency,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN subtotal_base
            ELSE NULL::numeric
        END AS subtotal_base,
    tax_rate_pct,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN tax_base
            ELSE NULL::numeric
        END AS tax_base,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN total_base
            ELSE NULL::numeric
        END AS total_base,
    status,
    void_reason,
    voided_at,
    voided_by,
    notes,
    terms_text,
    bill_to_snapshot,
    created_at,
    created_by
   FROM invoices
  WHERE has_permission('module.finance.view'::text);

CREATE VIEW public.invoice_lines_masked WITH (security_invoker = off) AS
 SELECT id,
    invoice_id,
    sales_record_id,
    line_no,
    description,
    quantity,
    unit,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN unit_price
            ELSE NULL::numeric
        END AS unit_price,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN amount_base
            ELSE NULL::numeric
        END AS amount_base,
    invoice_voided,
    created_at
   FROM invoice_lines
  WHERE has_permission('module.finance.view'::text);

CREATE VIEW public.invoice_status WITH (security_invoker = on) AS
 SELECT i.id AS invoice_id,
    i.code,
    i.customer_id,
    c.legal_name AS customer_name,
    i.issue_date,
    i.due_date,
    i.currency,
    i.total_base,
    round(COALESCE(s.settled, 0::numeric), 2) AS settled_base,
    round(i.total_base - COALESCE(s.settled, 0::numeric), 2) AS open_base,
    GREATEST(CURRENT_DATE - i.due_date, 0) AS days_overdue,
        CASE
            WHEN round(i.total_base - COALESCE(s.settled, 0::numeric), 2) <= 0::numeric THEN 'paid'::text
            WHEN COALESCE(s.settled, 0::numeric) > 0::numeric THEN 'partial'::text
            ELSE 'unpaid'::text
        END AS payment_state,
    CURRENT_DATE > i.due_date AND round(i.total_base - COALESCE(s.settled, 0::numeric), 2) > 0::numeric AS overdue
   FROM invoices_masked i
     JOIN customers c ON c.id = i.customer_id
     LEFT JOIN LATERAL ( SELECT sum(pa.allocated_base) AS settled
           FROM invoice_lines_masked il
             JOIN payment_allocations pa ON pa.sales_record_id = il.sales_record_id
             JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
          WHERE il.invoice_id = i.id) s ON true
  WHERE i.status <> 'void'::text;

CREATE VIEW public.sales_records_masked WITH (security_invoker = off) AS
 SELECT id,
    output_batch_id,
    customer_id,
    quantity,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN unit_price
            ELSE NULL::numeric
        END AS unit_price,
    currency,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN fx_rate
            ELSE NULL::numeric
        END AS fx_rate,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN amount_base
            ELSE NULL::numeric
        END AS amount_base,
    sale_date,
    notes,
    movement_id,
    created_at,
    created_by,
    cogs_entry_id
   FROM sales_records
  WHERE has_permission('module.finance.view'::text);

CREATE VIEW public.sales_records_visible WITH (security_invoker = off) AS
 SELECT sr.id,
    sr.output_batch_id,
    ob.code AS output_batch_code,
    sr.customer_id,
    c.legal_name AS customer_name,
    sr.quantity,
    sr.unit_price,
    sr.currency,
    sr.fx_rate,
    sr.amount_base,
    sr.sale_date,
    sr.notes,
    sr.created_at,
    sr.created_by
   FROM sales_records sr
     LEFT JOIN output_batches ob ON ob.id = sr.output_batch_id
     LEFT JOIN customers c ON c.id = sr.customer_id
  WHERE has_permission('module.output.view'::text) AND has_permission('data.view_sales'::text);

CREATE VIEW public.ar_open_items WITH (security_invoker = on) AS
 SELECT sr.id AS sales_record_id,
    ob.code AS doc_code,
    sr.customer_id,
    c.legal_name AS customer_name,
    sr.sale_date,
    sr.amount_base,
    round(COALESCE(s.settled, 0::numeric), 2) AS settled_base,
    round(sr.amount_base - COALESCE(s.settled, 0::numeric), 2) AS open_base,
    CURRENT_DATE - sr.sale_date AS days_outstanding,
        CASE
            WHEN (CURRENT_DATE - sr.sale_date) <= 30 THEN 'b0_30'::text
            WHEN (CURRENT_DATE - sr.sale_date) <= 60 THEN 'b31_60'::text
            WHEN (CURRENT_DATE - sr.sale_date) <= 90 THEN 'b61_90'::text
            ELSE 'b90_plus'::text
        END AS bucket,
    inv.invoice_id,
    inv.invoice_code
   FROM sales_records_masked sr
     JOIN output_batches ob ON ob.id = sr.output_batch_id
     LEFT JOIN customers c ON c.id = sr.customer_id
     LEFT JOIN LATERAL ( SELECT sum(pa.allocated_base) AS settled
           FROM payment_allocations pa
             JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
          WHERE pa.sales_record_id = sr.id) s ON true
     LEFT JOIN LATERAL ( SELECT i.id AS invoice_id,
            i.code AS invoice_code
           FROM invoice_lines_masked il
             JOIN invoices_masked i ON i.id = il.invoice_id
          WHERE il.sales_record_id = sr.id AND NOT il.invoice_voided
         LIMIT 1) inv ON true
  WHERE round(sr.amount_base - COALESCE(s.settled, 0::numeric), 2) > 0::numeric;

CREATE VIEW public.ap_open_items WITH (security_invoker = on) AS
 SELECT doc_kind,
    doc_id,
    doc_code,
    inbound_batch_id,
    supplier_id,
    supplier_name,
    doc_date,
    doc_value_base,
    settled_base,
    open_base,
    CURRENT_DATE - doc_date AS days_outstanding,
        CASE
            WHEN (CURRENT_DATE - doc_date) <= 30 THEN 'b0_30'::text
            WHEN (CURRENT_DATE - doc_date) <= 60 THEN 'b31_60'::text
            WHEN (CURRENT_DATE - doc_date) <= 90 THEN 'b61_90'::text
            ELSE 'b90_plus'::text
        END AS bucket
   FROM ( SELECT 'inbound'::text AS doc_kind,
            ib.id AS doc_id,
            ib.code AS doc_code,
            ib.id AS inbound_batch_id,
            ib.supplier_id,
            sup.legal_name AS supplier_name,
            COALESCE(ib.arrival_date, ib.created_at::date) AS doc_date,
            round(ib.quantity * ib.unit_price, 2) AS doc_value_base,
            round(COALESCE(s.settled, 0::numeric) + COALESCE(pp.applied, 0::numeric), 2) AS settled_base,
            round(round(ib.quantity * ib.unit_price, 2) - COALESCE(s.settled, 0::numeric) - COALESCE(pp.applied, 0::numeric), 2) AS open_base
           FROM inbound_batches_masked ib
             JOIN suppliers sup ON sup.id = ib.supplier_id
             LEFT JOIN LATERAL ( SELECT sum(pa.allocated_base) AS settled
                   FROM payment_allocations pa
                     JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
                  WHERE pa.inbound_batch_id = ib.id) s ON true
             LEFT JOIN LATERAL ( SELECT sum(ppa.amount_base) AS applied
                   FROM prepayment_applications_masked ppa
                  WHERE ppa.inbound_batch_id = ib.id) pp ON true
          WHERE ib.deleted_at IS NULL AND ib.unit_price IS NOT NULL
        UNION ALL
         SELECT 'expense'::text AS doc_kind,
            e.id AS doc_id,
            e.code AS doc_code,
            NULL::uuid AS inbound_batch_id,
            e.supplier_id,
            sup.legal_name AS supplier_name,
            e.expense_date AS doc_date,
            e.amount_base AS doc_value_base,
            round(COALESCE(s.settled, 0::numeric), 2) AS settled_base,
            round(e.amount_base - COALESCE(s.settled, 0::numeric), 2) AS open_base
           FROM expenses e
             JOIN suppliers sup ON sup.id = e.supplier_id
             LEFT JOIN LATERAL ( SELECT sum(pa.allocated_base) AS settled
                   FROM payment_allocations pa
                     JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
                  WHERE pa.expense_id = e.id) s ON true
          WHERE e.payment_status = 'unpaid'::text AND e.status = 'posted'::text AND NOT (EXISTS ( SELECT 1
                   FROM expenses o
                  WHERE o.reversed_by_expense = e.id))) d
  WHERE open_base > 0::numeric;

CREATE VIEW public.medical_claim_status WITH (security_invoker = off) AS
 SELECT mc.id AS claim_id,
    mc.code,
    mc.employee_id,
    e.code AS employee_code,
    e.legal_name,
    mc.claim_date,
    mc.claim_year,
    mc.amount_sgd,
    mc.description,
    mc.receipt_ref,
    mc.status,
    mc.decided_at,
    mc.expense_id,
    mc.expense_id IS NOT NULL AS linked_to_expense,
    ex.code AS expense_code,
    ex.amount_base AS expense_amount_base,
    COALESCE(pay.settled_base, 0::numeric) AS settled_base,
        CASE
            WHEN mc.status <> 'approved'::text THEN mc.status
            WHEN mc.expense_id IS NULL THEN 'awaiting_payment_run'::text
            WHEN COALESCE(pay.settled_base, 0::numeric) >= ex.amount_base THEN 'paid'::text
            WHEN COALESCE(pay.settled_base, 0::numeric) > 0::numeric THEN 'part_paid'::text
            ELSE 'expense_raised'::text
        END AS settlement_state
   FROM medical_claims mc
     JOIN employees e ON e.id = mc.employee_id
     LEFT JOIN expenses ex ON ex.id = mc.expense_id
     LEFT JOIN LATERAL ( SELECT sum(pa.allocated_base) AS settled_base
           FROM payment_allocations pa
             JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
          WHERE pa.expense_id = ex.id) pay ON true
  WHERE mc.deleted_at IS NULL AND (has_permission('module.hr.view'::text) OR mc.employee_id = current_user_employee());

CREATE VIEW public.prepayment_applications_masked WITH (security_invoker = off) AS
 SELECT id,
    purchase_order_id,
    inbound_batch_id,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN amount_base
            ELSE NULL::numeric
        END AS amount_base,
    notes,
    journal_entry_id,
    created_at,
    created_by
   FROM prepayment_applications
  WHERE has_permission('module.finance.view'::text);

CREATE VIEW public.po_prepayment_applicable WITH (security_invoker = on) AS
 SELECT ib.id AS inbound_batch_id,
    ib.code AS batch_code,
    po.id AS purchase_order_id,
    po.code AS po_code,
    po.supplier_id,
    round(round(ib.quantity * ib.unit_price, 2) - COALESCE(pay.settled, 0::numeric) - COALESCE(app_b.applied, 0::numeric), 2) AS batch_ap_open_base,
    round(COALESCE(pre.prepaid, 0::numeric) - COALESCE(app_po.applied, 0::numeric), 2) AS po_unapplied_prepayment_base,
    GREATEST(LEAST(round(round(ib.quantity * ib.unit_price, 2) - COALESCE(pay.settled, 0::numeric) - COALESCE(app_b.applied, 0::numeric), 2), round(COALESCE(pre.prepaid, 0::numeric) - COALESCE(app_po.applied, 0::numeric), 2)), 0::numeric) AS applicable_base
   FROM inbound_batches_masked ib
     JOIN purchase_orders_masked po ON po.id = ib.purchase_order_id
     LEFT JOIN LATERAL ( SELECT sum(pa.allocated_base) AS settled
           FROM payment_allocations pa
             JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
          WHERE pa.inbound_batch_id = ib.id) pay ON true
     LEFT JOIN LATERAL ( SELECT sum(ppa.amount_base) AS applied
           FROM prepayment_applications_masked ppa
          WHERE ppa.inbound_batch_id = ib.id) app_b ON true
     LEFT JOIN LATERAL ( SELECT sum(pa.allocated_base) AS prepaid
           FROM payment_allocations pa
             JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
          WHERE pa.purchase_order_id = po.id) pre ON true
     LEFT JOIN LATERAL ( SELECT sum(ppa.amount_base) AS applied
           FROM prepayment_applications_masked ppa
          WHERE ppa.purchase_order_id = po.id) app_po ON true
  WHERE ib.deleted_at IS NULL AND ib.unit_price IS NOT NULL AND GREATEST(LEAST(round(round(ib.quantity * ib.unit_price, 2) - COALESCE(pay.settled, 0::numeric) - COALESCE(app_b.applied, 0::numeric), 2), round(COALESCE(pre.prepaid, 0::numeric) - COALESCE(app_po.applied, 0::numeric), 2)), 0::numeric) > 0::numeric;

CREATE VIEW public.purchase_order_status WITH (security_invoker = on) AS
 SELECT po.id AS po_id,
    po.code,
    po.supplier_id,
    sup.legal_name AS supplier_name,
    po.order_date,
    po.expected_delivery_date,
    po.status,
    po.currency,
    po.estimated_total_usd,
    round(COALESCE(pre.prepaid, 0::numeric), 2) AS prepaid_base,
    round(COALESCE(app.applied, 0::numeric), 2) AS prepaid_applied_base,
    round(COALESCE(pre.prepaid, 0::numeric) - COALESCE(app.applied, 0::numeric), 2) AS prepaid_remaining_base,
    COALESCE(rec.batches, 0::bigint) AS received_batches,
    round(COALESCE(rec.qty, 0::numeric), 4) AS received_qty,
    round(COALESCE(ord.qty, 0::numeric), 4) AS ordered_qty,
        CASE
            WHEN COALESCE(ord.qty, 0::numeric) = 0::numeric THEN NULL::numeric
            ELSE round(COALESCE(rec.qty, 0::numeric) / ord.qty * 100::numeric, 2)
        END AS receipt_pct
   FROM purchase_orders_masked po
     JOIN suppliers sup ON sup.id = po.supplier_id
     LEFT JOIN LATERAL ( SELECT sum(pa.allocated_base) AS prepaid
           FROM payment_allocations pa
             JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
          WHERE pa.purchase_order_id = po.id) pre ON true
     LEFT JOIN LATERAL ( SELECT sum(ppa.amount_base) AS applied
           FROM prepayment_applications_masked ppa
          WHERE ppa.purchase_order_id = po.id) app ON true
     LEFT JOIN LATERAL ( SELECT count(*) AS batches,
            sum(ib.quantity) AS qty
           FROM inbound_batches_masked ib
          WHERE ib.purchase_order_id = po.id AND ib.deleted_at IS NULL) rec ON true
     LEFT JOIN LATERAL ( SELECT sum(pol.quantity) AS qty
           FROM purchase_order_lines_masked pol
          WHERE pol.purchase_order_id = po.id) ord ON true
  WHERE po.deleted_at IS NULL AND po.status <> 'cancelled'::text;

CREATE VIEW public.processing_cost_entries_masked WITH (security_invoker = off) AS
 SELECT id,
    run_id,
    cost_type,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN amount_base
            ELSE NULL::numeric
        END AS amount_base,
    is_estimate,
    notes,
    deleted_at,
    created_at,
    created_by,
    updated_at,
    updated_by
   FROM processing_cost_entries
  WHERE has_permission('module.processing.view'::text);

CREATE VIEW public.processing_outputs_masked WITH (security_invoker = off) AS
 SELECT id,
    run_id,
    output_batch_id,
    quantity_produced,
    created_at,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN allocated_cost_base
            ELSE NULL::numeric
        END AS allocated_cost_base,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN unit_cost_base
            ELSE NULL::numeric
        END AS unit_cost_base
   FROM processing_outputs
  WHERE has_permission('module.processing.view'::text);

CREATE VIEW public.processing_runs_masked WITH (security_invoker = off) AS
 SELECT id,
    code,
    process_date,
    total_input,
    total_output,
    loss_qty,
    notes,
    status,
    deleted_at,
    created_at,
    created_by,
    updated_at,
    updated_by,
    allocation_basis,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN material_cost_base
            ELSE NULL::numeric
        END AS material_cost_base,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN process_cost_base
            ELSE NULL::numeric
        END AS process_cost_base,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN total_cost_base
            ELSE NULL::numeric
        END AS total_cost_base,
    allocation_snapshot,
    allocated_at,
    allocated_by,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN capitalized_cost_base
            ELSE NULL::numeric
        END AS capitalized_cost_base,
    capitalization_entry_id
   FROM processing_runs
  WHERE has_permission('module.processing.view'::text);

COMMIT;