-- db/migrations/2026-07-31-phase4-cut4c-po-receiving.sql
-- Phase 4 cut 4c: receive against purchase orders, apply prepayments, close & reopen (DB).
--
-- 闭环:下单 → 定金 → 收货 → 计价 → 抵扣预付 → 清尾款。本切补上收货与关单两环:
--   B1. 首次收货自动把 'confirmed' 推到 'receiving'(机械、无歧义);
--       挂到已取消/已结束的单上则直接拒绝(PO_NOT_RECEIVABLE)。
--   B2. close_purchase_order / reopen_purchase_order —— 【结束是判断,不是机械动作】
--       (收够没收够、尾差认不认,只有人知道),所以关单永远手动;
--       还有未抵扣预付时必须写明处理方式(钱在 1300 上躺着,不能无声搁浅)。
--   B3. 视图 po_receivable_lines:收货表单一把查齐(可收的单、行、剩余量)。
--   B4. 视图 po_prepayment_applicable:批次页"抵扣预付"的资格与建议额,
--       与 apply_prepayment 同一口径 —— 页面与函数不可能各说各话。

BEGIN;

-- ============================================================================
-- B1. 收货与采购单状态的联动
-- ============================================================================
-- 【拒绝】挂到不可收货的单上:cancelled / closed 的单不接受新批次 ——
-- 'closed' 不会因为又来了一车货就悄悄复活,要收就先 reopen(那是人的决定)。
-- BEFORE INSERT + UPDATE OF purchase_order_id:改挂到别的单上时同样把关。
CREATE OR REPLACE FUNCTION public.guard_inbound_po_receivable()
RETURNS trigger LANGUAGE plpgsql AS $fn$
DECLARE
    v_po record;
BEGIN
    IF NEW.purchase_order_id IS NULL THEN
        RETURN NEW;
    END IF;
    -- UPDATE 时只在换单时把关(同单上改行号之类不重复检查)
    IF TG_OP = 'UPDATE' AND NEW.purchase_order_id IS NOT DISTINCT FROM OLD.purchase_order_id THEN
        RETURN NEW;
    END IF;
    SELECT code, status INTO v_po FROM purchase_orders WHERE id = NEW.purchase_order_id;
    IF FOUND AND v_po.status IN ('cancelled', 'closed') THEN
        RAISE EXCEPTION 'PO_NOT_RECEIVABLE|%|%', v_po.code, v_po.status;
    END IF;
    RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_inbound_batches_po_receivable
    BEFORE INSERT OR UPDATE OF purchase_order_id ON public.inbound_batches
    FOR EACH ROW EXECUTE FUNCTION public.guard_inbound_po_receivable();

-- 【自动推进】首次收货:'confirmed' → 'receiving'。只动这一个迁移 ——
-- 它是机械且无歧义的(货真的到了);而 'receiving' → 'closed' 是判断
-- (收够没收够、尾差认不认),永远手动(close_purchase_order)。
CREATE OR REPLACE FUNCTION public.advance_po_on_receipt()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF NEW.purchase_order_id IS NOT NULL THEN
        UPDATE purchase_orders
        SET status = 'receiving', updated_by = auth.uid()
        WHERE id = NEW.purchase_order_id AND status = 'confirmed';
    END IF;
    RETURN NULL;
END;
$fn$;

CREATE TRIGGER trg_inbound_batches_advance_po
    AFTER INSERT ON public.inbound_batches
    FOR EACH ROW EXECUTE FUNCTION public.advance_po_on_receipt();

-- ============================================================================
-- B2. close / reopen
-- ============================================================================
CREATE OR REPLACE FUNCTION public.close_purchase_order(p_purchase_order_id uuid, p_notes text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
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
    SELECT COALESCE(SUM(pa.allocated_usd), 0) INTO v_prepaid
    FROM payment_allocations pa
    JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
    WHERE pa.purchase_order_id = p_purchase_order_id;
    SELECT COALESCE(SUM(ppa.amount_usd), 0) INTO v_applied
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

CREATE OR REPLACE FUNCTION public.reopen_purchase_order(p_purchase_order_id uuid, p_reason text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
AS $function$
DECLARE
    v_user   uuid := auth.uid();
    v_po     record;
    v_status text;
BEGIN
    SELECT id, code, status INTO v_po
    FROM purchase_orders
    WHERE id = p_purchase_order_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PO_NOT_FOUND|%', COALESCE(p_purchase_order_id::text, '?');
    END IF;
    IF v_po.status <> 'closed' THEN
        RAISE EXCEPTION 'PO_NOT_CLOSED|%', v_po.code;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'REASON_REQUIRED';
    END IF;

    -- 已经收过货的回到 'receiving',一车没收过的回到 'confirmed'
    SELECT CASE WHEN EXISTS (
        SELECT 1 FROM inbound_batches ib
        WHERE ib.purchase_order_id = p_purchase_order_id AND ib.deleted_at IS NULL
    ) THEN 'receiving' ELSE 'confirmed' END INTO v_status;

    UPDATE purchase_orders
    SET status = v_status,
        closed_at = NULL,
        notes = COALESCE(notes || E'\n', '')
                || '[' || to_char(now(), 'YYYY-MM-DD HH24:MI') || ' reopened] ' || btrim(p_reason),
        updated_by = v_user
    WHERE id = p_purchase_order_id;

    RETURN jsonb_build_object(
        'purchase_order_id', p_purchase_order_id,
        'code', v_po.code,
        'status', v_status
    );
END;
$function$;

-- ============================================================================
-- B3. po_receivable_lines:收货表单的一把查
-- 每张【可收货】(confirmed / receiving)采购单的每一行:下单量、已收量
-- (Σ 挂在【该行】上的在册批次)、剩余量(下不封顶收货是常态,故剩余量地板 0)。
-- ============================================================================
CREATE OR REPLACE VIEW public.po_receivable_lines
WITH (security_invoker = on) AS
 SELECT po.id AS po_id,
    po.code AS po_code,
    po.supplier_id,
    sup.legal_name AS supplier_name,
    po.order_date,
    pol.id AS line_id,
    pol.line_no,
    pol.material_id,
    m.name AS material_name,
    pol.quantity AS ordered_qty,
    pol.unit,
    round(COALESCE(rec.qty, 0::numeric), 4) AS received_qty,
    round(GREATEST(pol.quantity - COALESCE(rec.qty, 0::numeric), 0::numeric), 4) AS remaining_qty,
    pol.pricing_formula_id,
    pol.estimated_unit_price,
    pol.expected_assay
   FROM purchase_orders po
     JOIN suppliers sup ON sup.id = po.supplier_id
     JOIN purchase_order_lines pol ON pol.purchase_order_id = po.id
     JOIN materials m ON m.id = pol.material_id
     LEFT JOIN LATERAL ( SELECT sum(ib.quantity) AS qty
           FROM inbound_batches ib
          WHERE ib.purchase_order_line_id = pol.id AND ib.deleted_at IS NULL) rec ON true
  WHERE po.deleted_at IS NULL AND po.status IN ('confirmed', 'receiving');

-- ============================================================================
-- B4. po_prepayment_applicable:"抵扣预付"的资格与建议额
-- 每个【在册、已计价、挂在还有未抵扣预付的采购单上】的批次一行。
-- applicable = min(批次未结应付, 该单未抵扣预付),地板 0,只留 > 0 的行。
-- 【页面的资格判断与建议金额都只从这里读】—— 与 apply_prepayment 的校验同一口径,
-- 界面与函数不可能对"能抵多少"各说各话。
-- ============================================================================
CREATE OR REPLACE VIEW public.po_prepayment_applicable
WITH (security_invoker = on) AS
 SELECT ib.id AS inbound_batch_id,
    ib.code AS batch_code,
    po.id AS purchase_order_id,
    po.code AS po_code,
    po.supplier_id,
    round(round(ib.quantity * ib.unit_price, 2)
          - COALESCE(pay.settled, 0::numeric)
          - COALESCE(app_b.applied, 0::numeric), 2) AS batch_ap_open_usd,
    round(COALESCE(pre.prepaid, 0::numeric) - COALESCE(app_po.applied, 0::numeric), 2) AS po_unapplied_prepayment_usd,
    GREATEST(LEAST(
        round(round(ib.quantity * ib.unit_price, 2)
              - COALESCE(pay.settled, 0::numeric)
              - COALESCE(app_b.applied, 0::numeric), 2),
        round(COALESCE(pre.prepaid, 0::numeric) - COALESCE(app_po.applied, 0::numeric), 2)
    ), 0::numeric) AS applicable_usd
   FROM inbound_batches ib
     JOIN purchase_orders po ON po.id = ib.purchase_order_id
     LEFT JOIN LATERAL ( SELECT sum(pa.allocated_usd) AS settled
           FROM payment_allocations pa
             JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
          WHERE pa.inbound_batch_id = ib.id) pay ON true
     LEFT JOIN LATERAL ( SELECT sum(ppa.amount_usd) AS applied
           FROM prepayment_applications ppa
          WHERE ppa.inbound_batch_id = ib.id) app_b ON true
     LEFT JOIN LATERAL ( SELECT sum(pa.allocated_usd) AS prepaid
           FROM payment_allocations pa
             JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
          WHERE pa.purchase_order_id = po.id) pre ON true
     LEFT JOIN LATERAL ( SELECT sum(ppa.amount_usd) AS applied
           FROM prepayment_applications ppa
          WHERE ppa.purchase_order_id = po.id) app_po ON true
  WHERE ib.deleted_at IS NULL AND ib.unit_price IS NOT NULL
    AND GREATEST(LEAST(
        round(round(ib.quantity * ib.unit_price, 2)
              - COALESCE(pay.settled, 0::numeric)
              - COALESCE(app_b.applied, 0::numeric), 2),
        round(COALESCE(pre.prepaid, 0::numeric) - COALESCE(app_po.applied, 0::numeric), 2)
    ), 0::numeric) > 0::numeric;

COMMIT;
