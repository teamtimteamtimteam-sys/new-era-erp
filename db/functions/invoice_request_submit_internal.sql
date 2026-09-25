-- db/functions/invoice_request_submit_internal.sql
-- APR-5a(2026-09-25):提一张贷项 / 作废申请 —— submit_credit_note_request 与 submit_invoice_void_request
-- 都落进来的那一支。两扇门各自先问 module.finance.edit;本支不问码。
--
--   1. 发票锁住。理由、贷项的凭证日与行在写入之前就按引擎的原名拒(REASON_REQUIRED ·
--      CN_REASON_REQUIRED · CN_NOTE_DATE_REQUIRED · CN_NO_LINES)—— 否则撞上的是表上的 CHECK,
--      屏幕只能说"意外错误"。
--   2. 这张发票已经挂着一张在等的申请 → INVOICE_REQUEST_OPEN|发票|那一张(唯一索引是第二道)。
--   3. ★ 审批开着时:提单人这个【人】之外,二级还有没有人批得动(assert_other_decider,按人认)。
--      没有 → INVOICE_REQUEST_NO_OTHER_DECIDER|发票(APR-5 brief:「no other decider」对每一种新申请都成立)。
--      线上是 admin@:它与 tim@ 是同一个人,而二级只有 tim@。审批关着时不拦。
--   4. 落一行 submitted;参数原样冻结。
--   5. 按批准那一刻会用的同一支过账试跑(invoice_request_dry_run)—— 超出开放余额、超出逐行天花板、
--      已结清、已发货、有核销、有贷项、期间锁,这里按引擎的原话拒。amount_base 取试跑的结果。
--   6. 审批开着:留痕 submitted,二级。关着:当场过账(invoice_request_post_internal),状态 approved,
--      留痕 auto_approved —— 没有人按过批准,留痕就不许说有人按过。
--
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-25-apr5a-credit-notes-and-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.invoice_request_submit_internal(p_invoice_id uuid, p_kind text, p_doc_date date, p_reason text, p_lines jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_inv   record;
    v_on    boolean := approvals_enabled();
    v_id    uuid := gen_random_uuid();
    v_open  text;
    v_n     integer;
    v_label text;
    v_dry   jsonb;
    v_post  jsonb := NULL;
    v_uc    record;
BEGIN
    SELECT id, code INTO v_inv FROM invoices WHERE id = p_invoice_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INVOICE_NOT_FOUND|%', COALESCE(p_invoice_id::text, '?');
    END IF;
    IF p_kind = 'credit_note' THEN
        IF p_doc_date IS NULL THEN
            RAISE EXCEPTION 'CN_NOTE_DATE_REQUIRED';
        END IF;
        IF p_reason IS NULL OR btrim(p_reason) = '' THEN
            RAISE EXCEPTION 'CN_REASON_REQUIRED';
        END IF;
        IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
            RAISE EXCEPTION 'CN_NO_LINES|%', v_inv.code;
        END IF;
        -- ★ APR-5b(grilling Q1):【未发货取消要说出取消了多少数量】—— 发货的天花板是
        --   开票数量 − Σ 取消的数量 − 已发(ship_order,SO_SHIP_EXCEEDS_RELEASABLE),
        --   而贷项此前只按金额记、数量可空。所以提交时:每一条 unshipped_cancel 必须带 qty > 0,
        --   按发票行合计不许超过 开票数量 − 已发 − 以前取消过的数量(以前没带数量的按 金额 ÷ 单价 折算)。
        --   不属于这张发票的行不在这里判 —— 试跑会按引擎原话拒。
        FOR v_uc IN
            SELECT il.id, il.line_no, il.quantity, il.unit_price, il.sales_order_line_id,
                   bool_or(NULLIF(e->>'qty', '') IS NULL OR (e->>'qty')::numeric <= 0) AS missing,
                   sum(NULLIF(e->>'qty', '')::numeric) AS want
              FROM jsonb_array_elements(p_lines) e
              JOIN invoice_lines il ON il.id = NULLIF(e->>'invoice_line_id', '')::uuid
                                   AND il.invoice_id = v_inv.id
             WHERE e->>'kind' = 'unshipped_cancel'
             GROUP BY il.id, il.line_no, il.quantity, il.unit_price, il.sales_order_line_id
        LOOP
            IF v_uc.missing THEN
                RAISE EXCEPTION 'CN_UNSHIPPED_CANCEL_QTY_REQUIRED|%|%', v_inv.code, v_uc.line_no;
            END IF;
            IF v_uc.want > v_uc.quantity
                 - COALESCE((SELECT sum(sl.qty) FROM shipment_lines sl
                              WHERE sl.sales_order_line_id = v_uc.sales_order_line_id), 0)
                 - COALESCE((SELECT sum(COALESCE(cl.qty, cl.amount / NULLIF(v_uc.unit_price, 0)))
                               FROM credit_note_lines cl
                              WHERE cl.invoice_line_id = v_uc.id AND cl.kind = 'unshipped_cancel'), 0) THEN
                RAISE EXCEPTION 'CN_UNSHIPPED_CANCEL_QTY_EXCEEDS|%|%|%|%', v_inv.code, v_uc.line_no,
                    trim_scale(v_uc.want),
                    trim_scale(GREATEST(v_uc.quantity
                        - COALESCE((SELECT sum(sl.qty) FROM shipment_lines sl
                                     WHERE sl.sales_order_line_id = v_uc.sales_order_line_id), 0)
                        - COALESCE((SELECT sum(COALESCE(cl.qty, cl.amount / NULLIF(v_uc.unit_price, 0)))
                                      FROM credit_note_lines cl
                                     WHERE cl.invoice_line_id = v_uc.id AND cl.kind = 'unshipped_cancel'), 0), 0));
            END IF;
        END LOOP;
    ELSIF p_kind = 'void' THEN
        IF p_reason IS NULL OR btrim(p_reason) = '' THEN
            RAISE EXCEPTION 'REASON_REQUIRED';
        END IF;
    ELSE
        RAISE EXCEPTION 'INVOICE_REQUEST_KIND_UNKNOWN|%|%', v_inv.code, COALESCE(p_kind, '?');
    END IF;

    SELECT q.label INTO v_open FROM invoice_requests q
     WHERE q.invoice_id = v_inv.id AND q.status = 'submitted';
    IF FOUND THEN
        RAISE EXCEPTION 'INVOICE_REQUEST_OPEN|%|%', v_inv.code, v_open;
    END IF;

    PERFORM assert_other_decider('invoice_request', 'decide_invoice_request', 2::smallint,
                                 'INVOICE_REQUEST_NO_OTHER_DECIDER|' || v_inv.code);

    SELECT count(*) + 1 INTO v_n FROM invoice_requests WHERE invoice_id = v_inv.id AND kind = p_kind;
    v_label := v_inv.code || ' · ' || CASE p_kind WHEN 'credit_note' THEN 'credit note' ELSE 'void' END
               || ' #' || v_n::text;

    INSERT INTO invoice_requests (id, invoice_id, kind, status, label, doc_date, reason, lines,
                                  amount_base, created_by)
    VALUES (v_id, v_inv.id, p_kind, 'submitted', v_label, p_doc_date, btrim(p_reason),
            CASE WHEN p_kind = 'credit_note' THEN p_lines END, 0, auth.uid());

    v_dry := invoice_request_dry_run(v_id);
    UPDATE invoice_requests SET amount_base = (v_dry->>'amount_base')::numeric WHERE id = v_id;

    IF v_on THEN
        PERFORM record_approval_decision('invoice_request', v_id, 'submitted', 2::smallint, NULL);
    ELSE
        v_post := invoice_request_post_internal(v_id);
        UPDATE invoice_requests
           SET status = 'approved', amount_base = (v_post->>'amount_base')::numeric,
               result_credit_note_id = (v_post->>'credit_note_id')::uuid,
               result_journal_entry_id = (v_post->>'entry_id')::uuid
         WHERE id = v_id;
        PERFORM record_approval_decision('invoice_request', v_id, 'auto_approved', NULL,
                                         '审批关着时提交:申请生下来就是 approved 并当场过账,没有人按过批准');
    END IF;

    RETURN jsonb_build_object(
        'request_id', v_id,
        'label', v_label,
        'kind', p_kind,
        'status', CASE WHEN v_on THEN 'submitted' ELSE 'approved' END,
        'invoice_code', v_inv.code,
        'amount_base', COALESCE(v_post->'amount_base', v_dry->'amount_base'),
        'credit_note_code', CASE WHEN p_kind = 'credit_note' THEN v_post->>'code' END,
        'credit_note_id', v_post->>'credit_note_id',
        'journal_code', COALESCE(v_post->>'journal_code', v_post->>'reversal_code'));
END;
$function$
;