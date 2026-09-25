-- db/functions/receipt_price_submit_internal.sql
-- ROLE-1 Batch 4b(2026-09-25):提一张收货定价申请 —— 四扇门(定价面板 · 按已承诺条款改价 ·
-- 收货台带价建单 · 应用化验)都落进来的那一支。每扇门自己先问自己的码;本支不问码。
--
--   1. 收货锁住、未注销;价格 > 0、币种存在(引擎还会再说一次,这里在写入之前就按名拒)。
--   2. 这张收货已经挂着一张在等的申请 → RECEIPT_PRICE_REQUEST_OPEN|收货|那一张(Tim 的 Q5;
--      唯一索引是第二道)。
--   3. ★ 审批开着时:除了提单人这个【人】之外,二级还有没有人批得动(approval_deciders,按人认)。
--      没有 → RECEIPT_PRICE_NO_OTHER_DECIDER|收货(Tim 的 Q1)。admin@ 与 tim@ 是同一个人,
--      而二级今天只有 tim@ —— 不拦的话,admin@ 提的申请会挂在那里没人批得了,还挡住关审批。
--      审批关着时不拦:申请生下来就是 approved,没有人要去批它。
--   4. 落一行 submitted,snapshot = receipt_price_fingerprint(Tim 的 Q5)。
--   5. 按批准那一刻会用的同一支过账试跑(receipt_price_request_dry_run,Tim 的 Q2)——
--      缺牌价、非法币种、期间锁,这里按引擎的原话拒。
--   6. ★ 低于已付 → RECEIPT_PRICE_BELOW_SETTLED|收货|新货值|已付(Tim 的 Q6 · Q12):
--      新货值 = round(数量 × 试跑出的新本位币单价, 2),按【今天】的牌价(Q4)。
--   7. amount_base = |试跑出的价差|(Q4:提交那一行留痕按提交日的牌价)。
--   8. 审批开着:留痕 submitted,二级。关着:当场过账(receipt_price_post_internal),状态 approved,
--      留痕 auto_approved —— 没有人按过批准,留痕就不许说有人按过。
--
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-25-role1b4b-receipt-pricing-waits-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.receipt_price_submit_internal(p_inbound_batch_id uuid, p_unit_price numeric, p_currency text, p_source text, p_assay_result_id uuid, p_commitment_id uuid, p_notes text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_b       record;
    v_on      boolean := approvals_enabled();
    v_id      uuid := gen_random_uuid();
    v_open    text;
    v_l1      text;
    v_l2      text;
    v_n       integer;
    v_label   text;
    v_dry     jsonb;
    v_value   numeric;
    v_settled numeric;
    v_amount  numeric;
    v_post    jsonb := NULL;
    v_je      uuid := NULL;
BEGIN
    SELECT id, code, quantity, unit_price INTO v_b
      FROM inbound_batches
     WHERE id = p_inbound_batch_id AND deleted_at IS NULL
     FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', COALESCE(p_inbound_batch_id::text, '?');
    END IF;
    IF p_unit_price IS NULL OR p_unit_price <= 0 THEN
        RAISE EXCEPTION 'PRICE_INVALID';
    END IF;
    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = p_currency) THEN
        RAISE EXCEPTION 'CURRENCY_INVALID|%', COALESCE(p_currency, '?');
    END IF;

    v_open := receipt_price_open(v_b.id);
    IF v_open IS NOT NULL THEN
        RAISE EXCEPTION 'RECEIPT_PRICE_REQUEST_OPEN|%|%', v_b.code, v_open;
    END IF;

    IF v_on THEN
        SELECT approval_level1_role_code, approval_level2_role_code
          INTO v_l1, v_l2 FROM finance_settings LIMIT 1;
        IF NOT EXISTS (SELECT 1 FROM approval_deciders('receipt_price_request',
                                                       'decide_receipt_price_request',
                                                       2::smallint, auth.uid(), NULL, v_l1, v_l2)) THEN
            RAISE EXCEPTION 'RECEIPT_PRICE_NO_OTHER_DECIDER|%', v_b.code;
        END IF;
    END IF;

    SELECT count(*) + 1 INTO v_n FROM receipt_price_requests WHERE inbound_batch_id = v_b.id;
    v_label := v_b.code || ' · price #' || v_n::text;

    INSERT INTO receipt_price_requests (id, inbound_batch_id, source, assay_result_id, commitment_id,
                                        status, label, unit_price_ccy, currency, snapshot,
                                        old_unit_price, amount_base, notes, created_by)
    VALUES (v_id, v_b.id, p_source, p_assay_result_id, p_commitment_id,
            'submitted', v_label, p_unit_price, p_currency, receipt_price_fingerprint(v_b.id),
            v_b.unit_price, 0, NULLIF(btrim(COALESCE(p_notes, '')), ''), auth.uid());

    v_dry := receipt_price_request_dry_run(v_id);
    v_value   := round(v_b.quantity * (v_dry->>'new_unit_price')::numeric, 2);
    v_settled := receipt_settled_base(v_b.id);
    IF v_value < v_settled THEN
        RAISE EXCEPTION 'RECEIPT_PRICE_BELOW_SETTLED|%|%|%', v_b.code, v_value, v_settled;
    END IF;
    v_amount := abs(COALESCE((v_dry->>'price_delta_usd')::numeric, 0));
    UPDATE receipt_price_requests SET amount_base = v_amount WHERE id = v_id;

    IF v_on THEN
        PERFORM record_approval_decision('receipt_price_request', v_id, 'submitted', 2::smallint, NULL);
    ELSE
        v_post := receipt_price_post_internal(v_id);
        SELECT je.id INTO v_je FROM journal_entries je WHERE je.code = v_post->>'journal_code';
        v_amount := abs(COALESCE((v_post->>'price_delta_usd')::numeric, 0));
        UPDATE receipt_price_requests
           SET status = 'approved', posted_unit_price = (v_post->>'new_unit_price')::numeric,
               result_journal_entry_id = v_je, amount_base = v_amount
         WHERE id = v_id;
        PERFORM record_approval_decision('receipt_price_request', v_id, 'auto_approved', NULL,
                                         '审批关着时提交:申请生下来就是 approved 并当场过账,没有人按过批准');
    END IF;

    RETURN jsonb_build_object(
        'request_id', v_id,
        'label', v_label,
        'status', CASE WHEN v_on THEN 'submitted' ELSE 'approved' END,
        'batch_code', v_b.code,
        'unit_price_ccy', p_unit_price,
        'currency', p_currency,
        'old_unit_price', v_b.unit_price,
        'new_unit_price', v_dry->'new_unit_price',
        'price_delta_usd', v_dry->'price_delta_usd',
        'amount_base', v_amount,
        'journal_code', v_post->>'journal_code');
END;
$function$
;
