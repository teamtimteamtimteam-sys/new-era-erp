-- db/functions/decide_receipt_price_request.sql
-- ROLE-1 Batch 4b(2026-09-25):CFO 批准或驳回一张收货定价申请。批准【当场过账】(Tim 的 Q2 (A))。
--
-- 【门】module.inbound.view + data.view_purchase_prices(Tim 的 Q2)—— 收货页的门,加上看得见采购价
-- 的那个码(docs/approvals.md §5:批的人必须看得见他批的那个数)。【不是】action.price_receipts:
-- 那是提单的码。cfo 两个都持(Step 0 以 postgres 读基表)。
-- 【谁能批】require_approver_for(2)—— CFO 批每一张、不分档,从不经 approval_level_for。
-- 【四眼】forbid_self_approval(提单人, NULL, …)—— 收货不是谁的"自己的单据",主角那条腿对谁都不成立;
-- 提单人那条腿按人认:admin@ 提的,tim@ 批不了(同一个人)—— 所以提交时就按名拒
-- RECEIPT_PRICE_NO_OTHER_DECIDER,不让它挂到这里。
--
-- 【批准之前】(Tim 的 Q5 · Q6 · Q4)
--   · 指纹再比一次(receipt_price_fingerprint:数量、供应商、采购单与采购行、单价、含量、承诺、
--     最近一份已应用的化验)→ 不同就 RECEIPT_PRICE_CHANGED_SINCE_REQUEST|申请;
--   · 按批准日的牌价试跑,新货值 < 已付 → RECEIPT_PRICE_BELOW_SETTLED(Q6,按【这一天】的牌价);
--   · 然后真的过账(receipt_price_post_internal):价、price_history、purchase 分录记在今天;
--     化验来源且那份化验 is_final → pricing_status 升为 final(Q3)。
--   · amount_base 改写成实际过账的 |Δ|,approved 那一行留痕记的就是它(Q4)。
-- 驳回从不检查这些:驳回一张坏掉的申请,正是出路。驳回要理由。
-- 审批关着时按名拒(APPROVALS_NOT_ENABLED)—— 所以这条链的在途申请挡关闭(blocks_disable)。
-- NOTE: introduced by db/migrations/2026-09-25-role1b4b-receipt-pricing-waits-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.decide_receipt_price_request(p_request_id uuid, p_approve boolean, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r       receipt_price_requests%ROWTYPE;
    v_b       record;
    v_dry     jsonb;
    v_value   numeric;
    v_settled numeric;
    v_post    jsonb;
    v_je      uuid := NULL;
    v_amount  numeric;
BEGIN
    PERFORM require_permission('module.inbound.view');
    PERFORM require_permission('data.view_purchase_prices');

    SELECT * INTO v_r FROM receipt_price_requests WHERE id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'RECEIPT_PRICE_REQUEST_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;
    IF v_r.status <> 'submitted' THEN
        RAISE EXCEPTION 'RECEIPT_PRICE_REQUEST_NOT_SUBMITTED|%|%', v_r.label, v_r.status;
    END IF;
    IF NOT approvals_enabled() THEN
        RAISE EXCEPTION 'APPROVALS_NOT_ENABLED';
    END IF;

    PERFORM forbid_self_approval(v_r.created_by, NULL, 'receipt_price_request');
    PERFORM require_approver_for(2::smallint);

    IF NOT p_approve THEN
        IF p_notes IS NULL OR btrim(p_notes) = '' THEN
            RAISE EXCEPTION 'RECEIPT_PRICE_REQUEST_REJECT_REASON_REQUIRED|%', v_r.label;
        END IF;
        UPDATE receipt_price_requests
           SET status = 'rejected', decided_at = now(), decided_by = auth.uid(),
               decision_notes = btrim(p_notes)
         WHERE id = p_request_id;
        PERFORM record_approval_decision('receipt_price_request', p_request_id, 'rejected', 2::smallint,
                                         btrim(p_notes));
        RETURN jsonb_build_object('request_id', p_request_id, 'label', v_r.label, 'status', 'rejected');
    END IF;

    SELECT id, code, quantity INTO v_b
      FROM inbound_batches WHERE id = v_r.inbound_batch_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', v_r.inbound_batch_id;
    END IF;
    IF receipt_price_fingerprint(v_b.id) IS DISTINCT FROM v_r.snapshot THEN
        RAISE EXCEPTION 'RECEIPT_PRICE_CHANGED_SINCE_REQUEST|%', v_r.label;
    END IF;

    v_dry := receipt_price_request_dry_run(p_request_id);
    v_value   := round(v_b.quantity * (v_dry->>'new_unit_price')::numeric, 2);
    v_settled := receipt_settled_base(v_b.id);
    IF v_value < v_settled THEN
        RAISE EXCEPTION 'RECEIPT_PRICE_BELOW_SETTLED|%|%|%', v_b.code, v_value, v_settled;
    END IF;

    v_post := receipt_price_post_internal(p_request_id);
    SELECT je.id INTO v_je FROM journal_entries je WHERE je.code = v_post->>'journal_code';
    v_amount := abs(COALESCE((v_post->>'price_delta_usd')::numeric, 0));

    UPDATE receipt_price_requests
       SET status = 'approved', decided_at = now(), decided_by = auth.uid(),
           decision_notes = NULLIF(btrim(COALESCE(p_notes, '')), ''),
           posted_unit_price = (v_post->>'new_unit_price')::numeric,
           result_journal_entry_id = v_je, amount_base = v_amount
     WHERE id = p_request_id;
    PERFORM record_approval_decision('receipt_price_request', p_request_id, 'approved', 2::smallint,
                                     NULLIF(btrim(COALESCE(p_notes, '')), ''));
    RETURN jsonb_build_object('request_id', p_request_id, 'label', v_r.label, 'status', 'approved',
                              'journal_code', v_post->>'journal_code',
                              'new_unit_price', v_post->'new_unit_price',
                              'price_delta_usd', v_post->'price_delta_usd');
END;
$function$
;
