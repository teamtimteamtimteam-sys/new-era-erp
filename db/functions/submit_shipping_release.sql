-- db/functions/submit_shipping_release.sql
-- APR-5b(2026-09-25):cco 请 CFO 放行一张订单已开票的行(APR-5 grilling Q2–Q4 · 5b grilling Q2–Q3)。
--
--   门 action.request_shipping_release(cco · admin)。
--   1. 订单锁住;必须 confirmed / partially_shipped(SHIPPING_RELEASE_ORDER_NOT_SHIPPABLE)。
--   2. 这张订单已经挂着一张 submitted → SHIPPING_RELEASE_OPEN|订单|那一张(唯一索引是第二道)。
--   3. 点名的行:p_invoice_line_ids 为 NULL = 每一条【在册】(订单流、issued、NOT invoice_voided)、
--      还没被覆盖的发票行(5b Q2 的默认);给了就逐条判 ——
--        不是这张订单的在册发票行 → SHIPPING_RELEASE_LINE_NOT_INVOICED|订单|那一条
--        已经被一张 approved 的放行覆盖 → SHIPPING_RELEASE_LINE_ALREADY_RELEASED|订单|行号(5b Q3)
--      一条都没有 → SHIPPING_RELEASE_NO_LINES|订单。
--   4. ★ 审批开着时:提单人这个【人】之外,二级还有没有人批得动(assert_other_decider,按人认)。
--      没有 → SHIPPING_RELEASE_NO_OTHER_DECIDER|订单。线上是 admin@:它与 tim@ 是同一个人。
--   5. 落一行 + 点名的行;amount_base = 点名发票行 amount_base 之和(本位币)。
--   6. 审批开着:留痕 submitted,二级。关着:生下来就是 approved,留痕 auto_approved —— 没有人按过批准,
--      留痕就不许说有人按过(PAY-REQ-1 Q8 同形)。
-- NOTE: introduced by db/migrations/2026-09-25-apr5b-the-cfo-releases-and-the-warehouse-ships.sql.

CREATE OR REPLACE FUNCTION public.submit_shipping_release(p_sales_order_id uuid, p_invoice_line_ids uuid[] DEFAULT NULL::uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_order  record;
    v_on     boolean := approvals_enabled();
    v_id     uuid := gen_random_uuid();
    v_open   text;
    v_bad    uuid;
    v_line   integer;
    v_n      integer;
    v_label  text;
    v_amount numeric;
    v_ids    uuid[];
BEGIN
    PERFORM require_permission('action.request_shipping_release');

    SELECT id, code, status, deleted_at INTO v_order FROM sales_orders WHERE id = p_sales_order_id FOR UPDATE;
    IF NOT FOUND OR v_order.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'SO_NOT_FOUND|%', COALESCE(p_sales_order_id::text, '?');
    END IF;
    IF v_order.status NOT IN ('confirmed', 'partially_shipped') THEN
        RAISE EXCEPTION 'SHIPPING_RELEASE_ORDER_NOT_SHIPPABLE|%|%', v_order.code, v_order.status;
    END IF;

    SELECT r.label INTO v_open FROM shipping_releases r
     WHERE r.sales_order_id = v_order.id AND r.status = 'submitted';
    IF FOUND THEN
        RAISE EXCEPTION 'SHIPPING_RELEASE_OPEN|%|%', v_order.code, v_open;
    END IF;

    -- 这张订单的在册发票行(订单流、issued、未作废),与"已被一张 approved 放行覆盖"这一问 ——
    IF p_invoice_line_ids IS NULL THEN
        SELECT array_agg(c.invoice_line_id ORDER BY c.line_no) INTO v_ids
          FROM (SELECT il.id AS invoice_line_id, sol.line_no,
                       EXISTS (SELECT 1 FROM shipping_release_lines rl
                                 JOIN shipping_releases r ON r.id = rl.release_id
                                WHERE rl.invoice_line_id = il.id AND r.status = 'approved') AS covered
                  FROM invoice_lines il
                  JOIN invoices i ON i.id = il.invoice_id
                  JOIN sales_order_lines sol ON sol.id = il.sales_order_line_id
                 WHERE sol.sales_order_id = v_order.id
                   AND i.kind = 'order' AND i.status = 'issued' AND NOT il.invoice_voided) c
         WHERE NOT c.covered;
    ELSE
        SELECT x INTO v_bad FROM unnest(p_invoice_line_ids) x
         WHERE x IS NULL OR NOT EXISTS (
               SELECT 1 FROM invoice_lines il
                 JOIN invoices i ON i.id = il.invoice_id
                 JOIN sales_order_lines sol ON sol.id = il.sales_order_line_id
                WHERE il.id = x AND sol.sales_order_id = v_order.id
                  AND i.kind = 'order' AND i.status = 'issued' AND NOT il.invoice_voided)
         LIMIT 1;
        IF FOUND THEN
            RAISE EXCEPTION 'SHIPPING_RELEASE_LINE_NOT_INVOICED|%|%', v_order.code, COALESCE(v_bad::text, '?');
        END IF;
        SELECT min(sol.line_no) INTO v_line
          FROM invoice_lines il
          JOIN sales_order_lines sol ON sol.id = il.sales_order_line_id
         WHERE il.id = ANY (p_invoice_line_ids)
           AND EXISTS (SELECT 1 FROM shipping_release_lines rl
                         JOIN shipping_releases r ON r.id = rl.release_id
                        WHERE rl.invoice_line_id = il.id AND r.status = 'approved');
        IF v_line IS NOT NULL THEN
            RAISE EXCEPTION 'SHIPPING_RELEASE_LINE_ALREADY_RELEASED|%|%', v_order.code, v_line;
        END IF;
        SELECT array_agg(DISTINCT x) INTO v_ids FROM unnest(p_invoice_line_ids) x;
    END IF;
    IF v_ids IS NULL OR cardinality(v_ids) = 0 THEN
        RAISE EXCEPTION 'SHIPPING_RELEASE_NO_LINES|%', v_order.code;
    END IF;

    PERFORM assert_other_decider('shipping_release', 'decide_shipping_release', 2::smallint,
                                 'SHIPPING_RELEASE_NO_OTHER_DECIDER|' || v_order.code);

    SELECT count(*) + 1 INTO v_n FROM shipping_releases WHERE sales_order_id = v_order.id;
    v_label := v_order.code || ' · release #' || v_n::text;
    SELECT COALESCE(sum(amount_base), 0) INTO v_amount FROM invoice_lines WHERE id = ANY (v_ids);

    INSERT INTO shipping_releases (id, sales_order_id, status, label, amount_base, created_by)
    VALUES (v_id, v_order.id, CASE WHEN v_on THEN 'submitted' ELSE 'approved' END, v_label, v_amount,
            auth.uid());
    INSERT INTO shipping_release_lines (release_id, invoice_line_id, sales_order_line_id)
    SELECT v_id, il.id, il.sales_order_line_id FROM invoice_lines il WHERE il.id = ANY (v_ids);

    IF v_on THEN
        PERFORM record_approval_decision('shipping_release', v_id, 'submitted', 2::smallint, NULL);
    ELSE
        PERFORM record_approval_decision('shipping_release', v_id, 'auto_approved', NULL,
                                         '审批关着时提交:放行生下来就是 approved,没有人按过批准');
    END IF;

    RETURN jsonb_build_object(
        'release_id', v_id,
        'label', v_label,
        'status', CASE WHEN v_on THEN 'submitted' ELSE 'approved' END,
        'order_code', v_order.code,
        'line_count', cardinality(v_ids));
END;
$function$
;
