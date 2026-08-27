CREATE OR REPLACE FUNCTION public.record_collection_chase(p_customer_id uuid, p_chased_on date, p_channel text, p_reached boolean, p_summary text, p_contacted_person text DEFAULT NULL::text, p_documents jsonb DEFAULT '[]'::jsonb, p_promise jsonb DEFAULT NULL::jsonb, p_supersedes uuid DEFAULT NULL::uuid, p_supersede_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_c         customers%ROWTYPE;
    v_old       collection_chases%ROWTYPE;
    v_ctx       jsonb;
    v_code      text;
    v_id        uuid;
    v_promise_id uuid;
    v_doc       jsonb;
    v_ok        boolean;
    v_subj_code text;
    v_amt       numeric;
    v_ccy       text;
    v_date      date;
    v_rate      numeric;
    v_out_id    uuid;
BEGIN
    PERFORM require_permission('module.finance.edit');

    SELECT * INTO v_c FROM customers WHERE id = p_customer_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CUSTOMER_NOT_FOUND|%', COALESCE(p_customer_id::text, '?');
    END IF;

    -- 【日期必填,绝不默认】AGENTS.md:COALESCE(p_date, CURRENT_DATE) 会奖励留空 ——
    -- 填对的那一天可能撞上期间锁而报错,留空的反而滑进开着的月份。
    IF p_chased_on IS NULL THEN
        RAISE EXCEPTION 'CHASE_DATE_REQUIRED';
    END IF;
    IF p_chased_on > CURRENT_DATE THEN
        RAISE EXCEPTION 'CHASE_DATE_FUTURE|%|%', p_chased_on::text, CURRENT_DATE::text;
    END IF;
    IF p_channel IS NULL OR p_channel NOT IN ('phone','email','whatsapp','in_person','letter') THEN
        RAISE EXCEPTION 'CHASE_CHANNEL_INVALID|%', COALESCE(p_channel, '?');
    END IF;
    IF p_reached IS NULL THEN
        RAISE EXCEPTION 'CHASE_REACHED_REQUIRED';
    END IF;
    IF p_summary IS NULL OR btrim(p_summary) = '' THEN
        -- 【对方说了什么,是这条记录存在的理由】一条没有内容的催收记录
        -- 只是一个时间戳,而队列那一条要的正是"对方说了什么"。
        RAISE EXCEPTION 'CHASE_SUMMARY_REQUIRED';
    END IF;
    IF NOT p_reached AND p_contacted_person IS NOT NULL AND btrim(p_contacted_person) <> '' THEN
        RAISE EXCEPTION 'CHASE_CONTACT_WITHOUT_REACH|%', p_contacted_person;
    END IF;

    -- ══ 更正:旧的那一条要还活着,而且理由必填 ══════════════════════════════
    IF p_supersedes IS NOT NULL THEN
        SELECT * INTO v_old FROM collection_chases WHERE id = p_supersedes;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'CHASE_NOT_FOUND|%', p_supersedes::text;
        END IF;
        IF v_old.superseded_at IS NOT NULL THEN
            RAISE EXCEPTION 'CHASE_ALREADY_SUPERSEDED|%|%', v_old.code, v_old.superseded_at::date::text;
        END IF;
        IF p_supersede_reason IS NULL OR btrim(p_supersede_reason) = '' THEN
            RAISE EXCEPTION 'CHASE_SUPERSEDE_REASON_REQUIRED|%', v_old.code;
        END IF;
        -- ★【已经记下结局的承诺,不许被一次"更正"抹掉】★
        -- 一个结局是【关于世界的事实】(钱到了,或者没到)。改正一句记错的话
        -- 不该连带擦掉那件事实 —— 那正是"可改"最坏的那一面。
        SELECT pr.id INTO v_out_id FROM collection_promises pr
         WHERE pr.chase_id = p_supersedes AND pr.outcome IS NOT NULL;
        IF FOUND THEN
            RAISE EXCEPTION 'CHASE_SUPERSEDE_OUTCOME_RECORDED|%|%',
                v_old.code, (SELECT outcome FROM collection_promises WHERE id = v_out_id);
        END IF;
    END IF;

    -- ══ 冻结那一天的欠款 —— 【调对账单那一支函数,不自己算】═══════════════
    v_ctx  := customer_collection_context(p_customer_id, p_chased_on);
    v_code := next_chase_code(p_chased_on);

    INSERT INTO collection_chases (
        code, customer_id, chased_on, channel, reached, contacted_person, summary,
        base_currency, owed_base, on_account_base, net_due_base,
        owed_by_currency, owed_buckets, chased_by)
    VALUES (
        v_code, p_customer_id, p_chased_on, p_channel, p_reached,
        NULLIF(btrim(COALESCE(p_contacted_person, '')), ''), btrim(p_summary),
        v_ctx->>'base_currency',
        (v_ctx->>'owed_base')::numeric,
        (v_ctx->>'on_account_base')::numeric,
        (v_ctx->>'net_due_base')::numeric,
        v_ctx->'by_currency', v_ctx->'buckets', auth.uid())
    RETURNING id INTO v_id;

    -- ══ 谈到的单据(可选的一组)══════════════════════════════════════════
    FOR v_doc IN SELECT * FROM jsonb_array_elements(COALESCE(p_documents, '[]'::jsonb))
    LOOP
        -- 【引用的东西必须存在,而且必须是【这个客户的】】—— 否则一条催收会
        -- 声称谈过一张别人家的单据,而那是一句没人会去核对的假话。
        v_ok := false; v_subj_code := NULL;
        IF v_doc->>'subject_type' = 'sales_record' THEN
            SELECT true, ob.code INTO v_ok, v_subj_code
              FROM sales_records sr JOIN output_batches ob ON ob.id = sr.output_batch_id
             WHERE sr.id = (v_doc->>'subject_id')::uuid AND sr.customer_id = p_customer_id;
        ELSIF v_doc->>'subject_type' = 'invoice' THEN
            SELECT true, i.code INTO v_ok, v_subj_code
              FROM invoices i WHERE i.id = (v_doc->>'subject_id')::uuid
               AND i.customer_id = p_customer_id;
        ELSIF v_doc->>'subject_type' = 'statement' THEN
            SELECT true, s.code INTO v_ok, v_subj_code
              FROM customer_statements s WHERE s.id = (v_doc->>'subject_id')::uuid
               AND s.customer_id = p_customer_id;
        ELSE
            RAISE EXCEPTION 'CHASE_DOCUMENT_KIND_UNKNOWN|%', COALESCE(v_doc->>'subject_type', '?');
        END IF;
        IF NOT COALESCE(v_ok, false) THEN
            RAISE EXCEPTION 'CHASE_DOCUMENT_NOT_THIS_CUSTOMER|%|%',
                v_doc->>'subject_type', COALESCE(v_doc->>'subject_id', '?');
        END IF;
        INSERT INTO collection_chase_documents (chase_id, subject_type, subject_id, subject_code)
        VALUES (v_id, v_doc->>'subject_type', (v_doc->>'subject_id')::uuid, v_subj_code);
    END LOOP;

    -- ══ 承诺(可选,而它是有牙齿的那一半)═══════════════════════════════
    IF p_promise IS NOT NULL AND p_promise <> 'null'::jsonb THEN
        -- 【没联系上人,就不可能有承诺】一条 reached=false 的记录带着承诺,
        -- 说的是"没人接电话,但他答应了付款"—— 那不是一件可能发生的事。
        IF NOT p_reached THEN
            RAISE EXCEPTION 'PROMISE_REQUIRES_CONTACT';
        END IF;
        v_amt  := NULLIF(p_promise->>'amount', '')::numeric;
        v_ccy  := NULLIF(p_promise->>'currency', '');
        v_date := NULLIF(p_promise->>'promised_date', '')::date;
        IF v_amt IS NULL THEN
            RAISE EXCEPTION 'PROMISE_AMOUNT_REQUIRED';
        END IF;
        IF v_amt <= 0 THEN
            RAISE EXCEPTION 'PROMISE_AMOUNT_INVALID|%', v_amt::text;
        END IF;
        IF v_date IS NULL THEN
            RAISE EXCEPTION 'PROMISE_DATE_REQUIRED';
        END IF;
        IF v_date < p_chased_on THEN
            -- 一个"承诺在通话之前付款"的日子,不是承诺,是打错的字
            RAISE EXCEPTION 'PROMISE_DATE_BEFORE_CHASE|%|%', v_date::text, p_chased_on::text;
        END IF;
        IF v_ccy IS NULL OR NOT EXISTS (SELECT 1 FROM currencies WHERE code = v_ccy) THEN
            RAISE EXCEPTION 'PROMISE_CURRENCY_UNKNOWN|%', COALESCE(v_ccy, '?');
        END IF;
        -- ★【按【催收当天】折算,不是按承诺日】★ 承诺日在未来,那天的汇率不存在;
        -- 按它折算 = 每一个承诺都被 FX_RATE_MISSING 拒掉,而随便取一个正是
        -- THE FX RULE 明令禁止的编造。tt_buy —— 客户付给我们,是一笔收款(与
        -- record_payment 同侧;一笔收款按卖出价折算,每一次都是错的)。
        v_rate := fx_rate_for(v_ccy, p_chased_on, 'tt_buy');
        INSERT INTO collection_promises (
            chase_id, promised_amount_ccy, currency, fx_rate, promised_amount_base,
            promised_date, created_by)
        VALUES (v_id, v_amt, v_ccy, v_rate, round(v_amt * v_rate, 2), v_date, auth.uid())
        RETURNING id INTO v_promise_id;
    END IF;

    -- 更正:旧行落标记(【不删】)
    IF p_supersedes IS NOT NULL THEN
        UPDATE collection_chases
           SET superseded_at = now(), superseded_by = v_id,
               superseded_reason = btrim(p_supersede_reason)
         WHERE id = p_supersedes;
    END IF;

    RETURN jsonb_build_object(
        'chase_id', v_id, 'code', v_code,
        'promise_id', v_promise_id,
        'owed_base', (v_ctx->>'owed_base')::numeric,
        'superseded', p_supersedes);
END;
$function$

;
