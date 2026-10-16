-- db/functions/supplier_statement_data.sql
-- MES-8a(2026-10-16,MES-0 Q79 · MES-8 Step 0 Q7 · Q8,Tim):【一家供应商一段期间的对账单 —— 现算】(签发之前的预览;issue_supplier_statement 调的就是它)。
--   门 module.finance.view(对账单就是应付总账,决定 1);价格那一侧要 data.view_purchase_prices —— 没有它,进料批次的金额是遮蔽的,
--   拿一张残缺的清单去对总账会得到一个自信的假差额,所以按名拒(SUPPLIER_STATEMENT_PRICES_RESTRICTED;list_ledger_reconciliation 的同一条);
--   收货还要 module.inbound.view(inbound_batches_masked 的行门)—— 没有它同样残缺,按名拒 SUPPLIER_STATEMENT_RECEIPTS_RESTRICTED。
--   期间必填、不倒置、不在未来(SUPPLIER_STATEMENT_PERIOD_*;与 customer_statement_data 同一组)。
--
--   【两份独立推导,勾稽在它们之间】(OPS-17:两边要能分开,检查才是检查)
--   ① 总账那一边 —— 总账 2000 上【归到这一家】的每一条分录行(贷 − 借 = 我们欠他的增加)。归属按分录的来源,原分录优先
--      (冲销件的 source_id 指的是原分录,不是单据 —— AGENTS.md「source_id 在冲销件上指的是原分录」):
--        purchase   → inbound_batches.supplier_id     (收货的计价与改价)
--        expense    → expenses.supplier_id            (员工的报销【永远】不归任何供应商 —— Q8)
--        freight    → freight_documents.supplier_id
--        payment    → payments.supplier_id
--        prepayment → prepayment_applications → purchase_orders.supplier_id
--      别的来源(重估、年结……)不按供应商记,不归到任何一家 —— 清单按单据入账汇率计、不重估,所以不归它们正是两边可比的前提。
--      期初 = 期间开始之前的累计;期末 = 截至期末的累计;期间里的每一行都是一条【明细】(lines),并按种类合成
--      发生(收货 · 费用 · 运费记上的)· 贷记(它们的冲销与改价调低)· 付款 · 预付冲抵。期初 + 发生 − 贷记 − 付款 − 预付冲抵 = 期末(恒等式)。
--   ② 单据那一边 —— ap_aging_asof(期末) 里这一家的未结单据(list_base),减去截至期末挂在账上的付款(on_account:付了而没核销到任何单据上的,
--      冲销对两边都不算 —— list_ledger_reconciliation 的式子),减去 list_ledger_residue 里这一家单据登记的残留(residue)。
--   ties ⇔ ① 的期末 = ② 的结果,差 0.00。对不上 → issue_supplier_statement 按名拒 SUPPLIER_STATEMENT_DOES_NOT_TIE。
--
--   【暂定价与没有价】(Q8):暂定价的收货照它的暂定价记、逐行标 provisional;期末那天还没有价的收货【不计金额】,列在 unpriced
--      ("received, not yet priced")—— 只有单号、到货日、物料、数量与单位。
-- NOTE: introduced by db/migrations/2026-10-16-mes8a-supplier-scorecards-and-statements.sql.
CREATE OR REPLACE FUNCTION public.supplier_statement_data(p_supplier_id uuid, p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_s          suppliers%ROWTYPE;
    v_base       text;
    v_opening    numeric;
    v_closing    numeric;
    v_charges    numeric;
    v_credits    numeric;
    v_payments   numeric;
    v_prepay     numeric;
    v_gl         jsonb;
    v_lines      jsonb;
    v_aging      jsonb;
    v_list       numeric;
    v_open_items jsonb;
    v_onacc      numeric;
    v_onacc_rows jsonb;
    v_res        numeric;
    v_res_rows   jsonb;
    v_unpriced   jsonb;
    v_byccy      jsonb;
    v_diff       numeric;
BEGIN
    PERFORM require_permission('module.finance.view');
    SELECT * INTO v_s FROM suppliers WHERE id = p_supplier_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SUPPLIER_NOT_FOUND|%', COALESCE(p_supplier_id::text, '?');
    END IF;
    IF p_from IS NULL OR p_to IS NULL THEN
        RAISE EXCEPTION 'SUPPLIER_STATEMENT_PERIOD_REQUIRED';
    END IF;
    IF p_to < p_from THEN
        RAISE EXCEPTION 'SUPPLIER_STATEMENT_PERIOD_INVALID|%|%', p_from::text, p_to::text;
    END IF;
    IF p_to > CURRENT_DATE THEN
        RAISE EXCEPTION 'SUPPLIER_STATEMENT_PERIOD_FUTURE|%|%', p_to::text, CURRENT_DATE::text;
    END IF;
    IF NOT has_permission('data.view_purchase_prices') THEN
        RAISE EXCEPTION 'SUPPLIER_STATEMENT_PRICES_RESTRICTED';
    END IF;
    -- 收货那一支经 inbound_batches_masked(门 module.inbound.view)读 —— 没有它,未结单据里一张收货都没有,清单整张残缺。同一个理由,按名拒。
    IF NOT has_permission('module.inbound.view') THEN
        RAISE EXCEPTION 'SUPPLIER_STATEMENT_RECEIPTS_RESTRICTED';
    END IF;

    SELECT code INTO v_base FROM currencies WHERE is_base;

    -- ══ ① 总账 2000,归到这一家的分录行(一次读进一份 jsonb,下面三处都从它算 —— 不读两遍)══════════════════════
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'date', g.entry_date, 'entry_code', g.entry_code, 'st', g.st, 'kind', g.kind, 'doc_code', g.doc_code,
               'amount_base', g.amt, 'currency', g.currency, 'amount_ccy', g.amount_ccy,
               'provisional', g.provisional, 'reversal', g.reversal)
             ORDER BY g.entry_date, g.entry_code, g.doc_code, g.amt), '[]'::jsonb)
      INTO v_gl
      FROM (
        SELECT l.entry_date, l.entry_code, l.st, l.amt, l.currency, l.amount_ccy, l.reversal,
               CASE l.st WHEN 'purchase' THEN 'receipt' ELSE l.st END AS kind,
               CASE l.st WHEN 'purchase'   THEN (SELECT b.code FROM inbound_batches b WHERE b.id = l.sid AND b.supplier_id = p_supplier_id)
                         WHEN 'expense'    THEN (SELECT e.code FROM expenses e WHERE e.id = l.sid AND e.supplier_id = p_supplier_id)
                         WHEN 'freight'    THEN (SELECT f.code FROM freight_documents f WHERE f.id = l.sid AND f.supplier_id = p_supplier_id)
                         WHEN 'payment'    THEN (SELECT p.code FROM payments p WHERE p.id = l.sid AND p.supplier_id = p_supplier_id)
                         WHEN 'prepayment' THEN (SELECT po.code FROM prepayment_applications pa JOIN purchase_orders po ON po.id = pa.purchase_order_id
                                                  WHERE pa.id = l.sid AND po.supplier_id = p_supplier_id)
               END AS doc_code,
               CASE WHEN l.st = 'purchase'
                    THEN COALESCE((SELECT b.pricing_status = 'provisional' FROM inbound_batches b WHERE b.id = l.sid), false)
                    ELSE false END AS provisional
          FROM (SELECT je.entry_date, je.code AS entry_code,
                       COALESCE(o.source_type, je.source_type) AS st, COALESCE(o.source_id, je.source_id) AS sid,
                       round(jl.credit - jl.debit, 2) AS amt, jl.currency,
                       CASE WHEN jl.credit > 0 THEN jl.amount_ccy ELSE -jl.amount_ccy END AS amount_ccy,
                       (o.id IS NOT NULL) AS reversal
                  FROM journal_lines jl
                  JOIN accounts a ON a.id = jl.account_id AND a.code = '2000'
                  JOIN journal_entries je ON je.id = jl.entry_id
                  LEFT JOIN journal_entries o ON o.reversed_by = je.id
                 WHERE je.entry_date <= p_to
                   AND COALESCE(o.source_type, je.source_type) IN ('purchase', 'expense', 'freight', 'payment', 'prepayment')) l
      ) g
     WHERE g.doc_code IS NOT NULL;   -- 归不到这一家的行(别家的单据)不要

    SELECT COALESCE(round(sum((x ->> 'amount_base')::numeric) FILTER (WHERE (x ->> 'date')::date < p_from), 2), 0),
           COALESCE(round(sum((x ->> 'amount_base')::numeric), 2), 0),
           COALESCE(round(sum((x ->> 'amount_base')::numeric) FILTER (WHERE (x ->> 'date')::date >= p_from
                          AND x ->> 'st' IN ('purchase', 'expense', 'freight') AND (x ->> 'amount_base')::numeric > 0), 2), 0),
           COALESCE(round(-sum((x ->> 'amount_base')::numeric) FILTER (WHERE (x ->> 'date')::date >= p_from
                          AND x ->> 'st' IN ('purchase', 'expense', 'freight') AND (x ->> 'amount_base')::numeric < 0), 2), 0),
           COALESCE(round(-sum((x ->> 'amount_base')::numeric) FILTER (WHERE (x ->> 'date')::date >= p_from AND x ->> 'st' = 'payment'), 2), 0),
           COALESCE(round(-sum((x ->> 'amount_base')::numeric) FILTER (WHERE (x ->> 'date')::date >= p_from AND x ->> 'st' = 'prepayment'), 2), 0)
      INTO v_opening, v_closing, v_charges, v_credits, v_payments, v_prepay
      FROM jsonb_array_elements(v_gl) x;

    SELECT COALESCE(jsonb_agg(x - 'st' ORDER BY ord), '[]'::jsonb)
      INTO v_lines
      FROM jsonb_array_elements(v_gl) WITH ORDINALITY AS e(x, ord)
     WHERE (x ->> 'date')::date >= p_from;

    -- ══ ② 单据那一边:期末未结单据 − 挂账的付款 − 登记的残留 ═══════════════════════════
    v_aging := ap_aging_asof(p_to);
    SELECT COALESCE(round(sum((e ->> 'open_base')::numeric), 2), 0),
           COALESCE(jsonb_agg(jsonb_build_object(
               'doc_kind', e ->> 'doc_kind', 'doc_code', e ->> 'doc_code', 'doc_date', e ->> 'doc_date',
               'currency', e ->> 'currency', 'doc_value_base', (e ->> 'doc_value_base')::numeric,
               'open_ccy', (e ->> 'open_ccy')::numeric, 'open_base', (e ->> 'open_base')::numeric,
               'days_outstanding', (e ->> 'days_outstanding')::int,
               'provisional', COALESCE((SELECT b.pricing_status = 'provisional' FROM inbound_batches b
                                         WHERE e ->> 'doc_kind' = 'inbound' AND b.id = (e ->> 'doc_id')::uuid), false))
             ORDER BY e ->> 'doc_date', e ->> 'doc_code'), '[]'::jsonb)
      INTO v_list, v_open_items
      FROM jsonb_array_elements(v_aging -> 'rows') e
     WHERE e ->> 'counterparty_kind' = 'supplier' AND e ->> 'counterparty_id' = p_supplier_id::text;

    SELECT COALESCE(round(sum(u.base), 2), 0),
           COALESCE(jsonb_agg(jsonb_build_object('code', u.code, 'payment_date', u.payment_date, 'currency', u.currency,
                                                 'unapplied_ccy', u.unapplied_ccy, 'amount_base', u.base)
                              ORDER BY u.payment_date, u.code), '[]'::jsonb)
      INTO v_onacc, v_onacc_rows
      FROM (SELECT p.code, p.payment_date, p.currency,
                   round(p.amount_ccy - COALESCE(al.applied, 0), 2) AS unapplied_ccy,
                   round(round(p.amount_ccy - COALESCE(al.applied, 0), 2) * p.fx_rate, 2) AS base
              FROM payments p
              LEFT JOIN payments rev ON rev.id = p.reversed_by_payment
              LEFT JOIN LATERAL (SELECT sum(pa.allocated_pay - pa.withheld_pay) AS applied
                                   FROM payment_allocations pa WHERE pa.payment_id = p.id) al ON true
             WHERE p.direction = 'out' AND p.supplier_id = p_supplier_id
               AND p.payment_date <= p_to
               AND (p.status = 'posted' OR (p.status = 'reversed' AND rev.payment_date > p_to))
               AND NOT EXISTS (SELECT 1 FROM payments o WHERE o.reversed_by_payment = p.id)) u
     WHERE u.base <> 0;

    SELECT COALESCE(round(sum(r.amount_base), 2), 0),
           COALESCE(jsonb_agg(jsonb_build_object('doc_code', r.doc_code, 'amount_base', r.amount_base,
                                                 'residue_class', r.residue_class, 'reason', r.reason) ORDER BY r.doc_code), '[]'::jsonb)
      INTO v_res, v_res_rows
      FROM list_ledger_residue r
     WHERE r.side = 'ap'
       AND (r.doc_code IN (SELECT b.code FROM inbound_batches b WHERE b.supplier_id = p_supplier_id)
            OR r.doc_code IN (SELECT e.code FROM expenses e WHERE e.supplier_id = p_supplier_id)
            OR r.doc_code IN (SELECT f.code FROM freight_documents f WHERE f.supplier_id = p_supplier_id));

    -- 已收到、期末那天还没有价的收货:只有数量
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'doc_code', b.code, 'arrival_date', COALESCE(b.arrival_date, b.created_at::date),
               'material_code', m.code, 'quantity', b.quantity, 'unit', b.unit)
             ORDER BY COALESCE(b.arrival_date, b.created_at::date), b.code), '[]'::jsonb)
      INTO v_unpriced
      FROM inbound_batches b
      LEFT JOIN materials m ON m.id = b.material_id
     WHERE b.supplier_id = p_supplier_id
       AND (b.deleted_at IS NULL OR b.deleted_at::date > p_to)
       AND COALESCE(b.arrival_date, b.created_at::date) <= p_to
       AND inbound_unit_price_asof(b.id, p_to) IS NULL;

    -- 每币种一段:期末未结(原币)
    SELECT COALESCE(jsonb_agg(jsonb_build_object('currency', x.currency, 'open_ccy', x.open_ccy, 'open_base', x.open_base)
                              ORDER BY x.currency), '[]'::jsonb)
      INTO v_byccy
      FROM (SELECT o ->> 'currency' AS currency, round(sum((o ->> 'open_ccy')::numeric), 2) AS open_ccy,
                   round(sum((o ->> 'open_base')::numeric), 2) AS open_base
              FROM jsonb_array_elements(v_open_items) o GROUP BY o ->> 'currency') x;

    v_diff := round(v_list - v_onacc - v_res - v_closing, 2);

    RETURN jsonb_build_object(
        'supplier_id',      p_supplier_id,
        'supplier_code',    v_s.code,
        'supplier_name',    v_s.legal_name,
        'period_start',     p_from,
        'period_end',       p_to,
        'base_currency',    v_base,
        'opening_base',     v_opening,
        'charges_base',     v_charges,
        'credits_base',     v_credits,
        'payments_base',    v_payments,
        'prepayments_base', v_prepay,
        'closing_base',     v_closing,
        'list_base',        v_list,
        'on_account_base',  v_onacc,
        'residue_base',     v_res,
        'tie_difference',   v_diff,
        'ties',             (v_diff = 0),
        'no_movement',      (jsonb_array_length(v_lines) = 0),
        'lines',            v_lines,
        'open_items',       v_open_items,
        'on_account',       v_onacc_rows,
        'residue',          v_res_rows,
        'unpriced',         v_unpriced,
        'by_currency',      v_byccy);
END;
$function$
