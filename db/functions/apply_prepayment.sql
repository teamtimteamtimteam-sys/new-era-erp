CREATE OR REPLACE FUNCTION public.apply_prepayment(p_purchase_order_id uuid, p_inbound_batch_id uuid, p_amount numeric, p_notes text DEFAULT NULL::text, p_expense_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user        uuid := auth.uid();
    v_base        text := base_currency_code();
    v_po          record;
    v_batch       record;
    v_exp         record;
    v_prepaid     numeric;   -- Σ 已付到该单的预付,本位币
    v_prepaid_ccy numeric;   -- Σ 同上,按【采购单币种】
    v_applied     numeric;   -- Σ 已冲抵,本位币
    v_available   numeric;
    v_dep_ccy     text;      -- 定金的币种 = 采购单的币种
    v_dep_rate    numeric;   -- 定金的加权平均汇率
    v_pay_ccy     text;      -- 被解除应付的计价币种
    v_pay_rate    numeric;   -- 被解除应付的【入账】汇率
    v_value       numeric;
    v_settled     numeric;
    v_open        numeric;
    v_dep_ccy_amt numeric;   -- 本次消耗的定金,按定金币种
    v_dep_base    numeric;   -- 本次消耗的定金,本位币(= 落库的 amount_base)
    v_pay_base    numeric;   -- 本次解除的应付,本位币
    v_realised    numeric;
    v_dest_code   text;      -- 目的地单据的编号(分录摘要用)
    v_lines       jsonb;
    v_app_id      uuid := gen_random_uuid();
    v_je          jsonb;
BEGIN
    PERFORM require_permission('module.finance.edit');

    -- 目的地【恰好一个】。表上那条 CHECK 是兜底(直插也逃不掉);这里按名拒绝,
    -- 因为本仓库的规矩是"拒绝要有名字,屏幕上不出现裸的约束违例"。
    IF num_nonnulls(p_inbound_batch_id, p_expense_id) <> 1 THEN
        RAISE EXCEPTION 'PREPAY_DESTINATION_INVALID|%',
            num_nonnulls(p_inbound_batch_id, p_expense_id)
          USING HINT = '一次冲抵恰好冲一个目的地:一张进料批次,或一张费用单';
    END IF;

    SELECT po.id, po.code, po.supplier_id, po.status, po.approval_status, po.currency
    INTO v_po
    FROM purchase_orders po
    WHERE po.id = p_purchase_order_id AND po.deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PO_NOT_FOUND|%', COALESCE(p_purchase_order_id::text, '?');
    END IF;
    IF v_po.status = 'cancelled' THEN
        RAISE EXCEPTION 'PO_CANCELLED|%', v_po.code;
    END IF;
    -- APR-2:未获批的采购单不能动钱
    IF v_po.approval_status <> 'approved' THEN
        RAISE EXCEPTION 'PO_NOT_APPROVED|%|%', v_po.code, v_po.approval_status;
    END IF;
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'AMOUNT_INVALID';
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- 定金那一侧。
    -- 【币种】1300 由 record_payment 按【单据(= 采购单)币种】归集(FIN-16 的
    -- v_pre 逐币种发行控制科目行),所以定金的币种就是采购单的币种。
    -- 【汇率】复用 FIN-16 已经记下来的结果,不重算:
    --     加权平均 = Σ allocated_base / Σ allocated_ccy
    -- ════════════════════════════════════════════════════════════════════════
    v_dep_ccy := v_po.currency;

    SELECT COALESCE(SUM(pa.allocated_base), 0), COALESCE(SUM(pa.allocated_ccy), 0)
    INTO v_prepaid, v_prepaid_ccy
    FROM payment_allocations pa
    JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
    WHERE pa.purchase_order_id = p_purchase_order_id;

    -- ════════════════════════════════════════════════════════════════════════
    -- 【可用预付这条守卫留在本位币空间 —— 这是刻意的,不要"顺手"改成币种空间】
    -- amount_ccy 在那一条 2026-07-31 的历史行上是 NULL(FIN-0 翻转之前记的,
    -- 刻意不回填)。一旦改成 Σ amount_ccy,那一行会被【静默跳过】,于是
    -- PO-2026-0001 上一笔【已经全额冲抵完】的 30,000 定金会读成"还有 30,000 可用",
    -- 冲第二次而没有任何东西反对。amount_base 在那一行上是有值的,所以本位币
    -- 空间数得对。币种是【记下来、过账用】的,不用来决定还剩多少。
    -- fixture 103b 的 H 臂把这一条钉死了。
    -- ════════════════════════════════════════════════════════════════════════
    SELECT COALESCE(SUM(ppa.amount_base), 0) INTO v_applied
    FROM prepayment_applications ppa
    WHERE ppa.purchase_order_id = p_purchase_order_id;

    v_available := round(v_prepaid - v_applied, 2);
    IF v_prepaid_ccy > 0 THEN
        v_dep_rate := v_prepaid / v_prepaid_ccy;
    END IF;
    IF v_dep_rate IS NULL OR v_dep_rate <= 0 THEN
        RAISE EXCEPTION 'PREPAY_INSUFFICIENT|%|%', 0, p_amount;
    END IF;

    -- ── 目的地:两种单据,各自解出【计价币种】、【入账汇率】与【敞口】───────
    IF p_inbound_batch_id IS NOT NULL THEN
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

        -- 【进料应付恒以本位币计价】reprice_inbound_batch(set_inbound_unit_price
        -- 只是它的转发)按 base_currency_code() 过账 2000,ap_open_items 的进料支
        -- 也把 currency 取成 currencies.is_base。线上 9 条 source_type='purchase'
        -- 的 2000 行,fx_rate 无一例外是 1 —— 即当日的本位币。
        v_pay_ccy  := v_base;
        v_pay_rate := 1;

        v_value := round(v_batch.quantity * v_batch.unit_price, 2);
        SELECT COALESCE(SUM(pa.allocated_base), 0) INTO v_settled
        FROM payment_allocations pa
        JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
        WHERE pa.inbound_batch_id = p_inbound_batch_id;
        v_settled := v_settled + COALESCE(
            (SELECT SUM(ppa.amount_base) FROM prepayment_applications ppa
              WHERE ppa.inbound_batch_id = p_inbound_batch_id), 0);
        v_open := round(v_value - v_settled, 2);
        v_dest_code := v_batch.code;
    ELSE
        SELECT e.id, e.code, e.currency, e.fx_rate, e.amount_ccy,
               e.supplier_id, e.status, e.payment_status
        INTO v_exp
        FROM expenses e WHERE e.id = p_expense_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'EXPENSE_NOT_FOUND|%', COALESCE(p_expense_id::text, '?');
        END IF;
        IF v_exp.status <> 'posted' THEN
            RAISE EXCEPTION 'EXPENSE_NOT_POSTED|%|%', v_exp.code, v_exp.status;
        END IF;
        -- 已付的费用单没有应付可解除 —— 那笔钱当时就走了银行。
        IF v_exp.payment_status <> 'unpaid' THEN
            RAISE EXCEPTION 'EXPENSE_NOT_PAYABLE|%', v_exp.code
              USING HINT = '只有挂账(unpaid)的费用单才有应付可以让定金去冲';
        END IF;
        -- 冲销镜像单只是记录凭证,不是新的应付单据(ap_open_items 也把它排除)。
        IF EXISTS (SELECT 1 FROM expenses o WHERE o.reversed_by_expense = v_exp.id) THEN
            RAISE EXCEPTION 'EXPENSE_IS_REVERSAL_MIRROR|%', v_exp.code;
        END IF;
        IF v_exp.supplier_id IS DISTINCT FROM v_po.supplier_id THEN
            RAISE EXCEPTION 'SUPPLIER_MISMATCH|%|%', v_po.code, v_exp.code;
        END IF;

        -- 费用单的应付以【单据自己的币种】计价(record_expense 按 p_currency 贷 2000),
        -- 入账汇率就是单据上冻住的那一个。敞口因此在单据币种空间递减 ——
        -- 与 ap_open_items 的费用支同一个口径。
        v_pay_ccy  := v_exp.currency;
        v_pay_rate := v_exp.fx_rate;

        SELECT COALESCE(SUM(pa.allocated_ccy), 0) INTO v_settled
        FROM payment_allocations pa
        JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
        WHERE pa.expense_id = p_expense_id;
        v_settled := v_settled + COALESCE(
            (SELECT SUM(ppa.amount_ccy) FROM prepayment_applications ppa
              WHERE ppa.expense_id = p_expense_id), 0);
        v_open := round(v_exp.amount_ccy - v_settled, 2);
        v_dest_code := v_exp.code;
    END IF;

    -- p_amount 以【被解除应付的币种】陈述(进料支即本位币,与本刀之前逐字一致)
    IF p_amount > v_open THEN
        RAISE EXCEPTION 'EXCEEDS_OPEN|%|%', v_open, p_amount;
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- R1 / R2 / R3 —— 判据是【定金币种】与【应付币种】的关系。
    -- 两条支路都【不读任何当日牌价】:两条腿都是历史入账,没有钱在动,
    -- 也就没有一次兑换需要定价。
    -- ════════════════════════════════════════════════════════════════════════
    IF v_pay_ccy = v_dep_ccy THEN
        -- R1 单位对齐:付了 10,000 USD、欠 50,000 USD 的人,现在欠 40,000 USD。
        -- 已实现汇兑 = 同样这 A 个单位,按应付的入账汇率与按定金的加权汇率,
        -- 两个【历史】本位币值之差。
        v_dep_ccy_amt := p_amount;
        v_dep_base    := round(p_amount * v_dep_rate, 2);
        v_pay_base    := round(p_amount * v_pay_rate, 2);
    ELSIF v_pay_ccy = v_base OR v_dep_ccy = v_base THEN
        -- R2 价值对齐:两者恰有一个是本位币。按定金【自己的】汇率折出等值的
        -- 定金数量,于是两侧本位币值恒等,7100 恒为零。
        -- 【那个零是构造出来的,不是漏算的】1300 是 is_monetary = false:预付按
        -- 付款那天的汇率计量,此后永不重译。按它自己的汇率消耗它,不可能产生损益。
        v_pay_base    := round(p_amount * v_pay_rate, 2);
        v_dep_base    := v_pay_base;
        v_dep_ccy_amt := round(v_pay_base / v_dep_rate, 2);
    ELSE
        -- R3 两边都是外币且不同 —— 这才需要一次真正的换算,而这盘生意里它不存在。
        RAISE EXCEPTION 'PREPAY_TWO_FOREIGN_CURRENCIES|%|%', v_dep_ccy, v_pay_ccy
          USING HINT = '定金与应付是两种不同的外币 —— 请让其中一方以本位币开票';
    END IF;

    IF v_dep_ccy_amt IS NULL OR v_dep_ccy_amt <= 0 THEN
        RAISE EXCEPTION 'AMOUNT_INVALID';
    END IF;
    IF v_dep_base > v_available THEN
        RAISE EXCEPTION 'PREPAY_INSUFFICIENT|%|%', v_available, v_dep_base;
    END IF;

    v_realised := round(v_pay_base - v_dep_base, 2);

    -- 分录:钱早就出去了,这里只是科目之间的搬运。
    -- 【汇率逐行给成 base/ccy 的商】与 record_payment 同一个手法 —— 这样
    -- post_journal_entry 折出来的本位币值与上面算的逐分相等,分录不会因为
    -- 一次四舍五入而不平,R2 的"恒为零"也才真的是零。
    v_lines := jsonb_build_array(
        jsonb_build_object('account_code', '2000', 'side', 'debit',
                           'currency', v_pay_ccy, 'amount_ccy', p_amount,
                           'fx_rate', v_pay_base / p_amount),
        jsonb_build_object('account_code', '1300', 'side', 'credit',
                           'currency', v_dep_ccy, 'amount_ccy', v_dep_ccy_amt,
                           'fx_rate', v_dep_base / v_dep_ccy_amt,
                           'line_memo', 'Prepayment applied'));
    -- 借方合计 − 贷方合计:>0 说明按旧率解除得多 → 贷 7100(益);<0 → 借 7100(损)。
    -- 与 record_payment 的方向约定逐字一致。
    IF v_realised > 0 THEN
        v_lines := v_lines || jsonb_build_object('account_code', '7100', 'side', 'credit',
            'currency', v_base, 'amount_ccy', v_realised, 'fx_rate', 1);
    ELSIF v_realised < 0 THEN
        v_lines := v_lines || jsonb_build_object('account_code', '7100', 'side', 'debit',
            'currency', v_base, 'amount_ccy', -v_realised, 'fx_rate', 1);
    END IF;

    v_je := post_journal_entry(
        CURRENT_DATE,
        -- 【不要写 COALESCE(v_batch.code, v_exp.code)】没走到的那一支里,那个
        -- record 变量【从未被赋值】,读它的字段是一个错误(record ... is not
        -- assigned yet),不是 NULL —— COALESCE 救不了。实测撞过。
        'Prepayment applied ' || v_po.code || ' → ' || v_dest_code,
        'prepayment', v_app_id, v_lines);

    INSERT INTO prepayment_applications (id, purchase_order_id, inbound_batch_id, expense_id,
                                         amount_base, currency, amount_ccy,
                                         notes, journal_entry_id, created_by)
    VALUES (v_app_id, p_purchase_order_id, p_inbound_batch_id, p_expense_id,
            v_dep_base, v_pay_ccy, p_amount,
            p_notes, (v_je->>'entry_id')::uuid, v_user);

    RETURN jsonb_build_object(
        'application_id', v_app_id,
        'purchase_order_id', p_purchase_order_id,
        'inbound_batch_id', p_inbound_batch_id,
        'expense_id', p_expense_id,
        'currency', v_pay_ccy,
        'amount_ccy', p_amount,
        'amount_base', v_dep_base,
        'deposit_currency', v_dep_ccy,
        'deposit_amount_ccy', v_dep_ccy_amt,
        'deposit_rate', v_dep_rate,
        'realised_fx', v_realised,
        'journal_code', v_je->>'code',
        'prepaid_remaining', round(v_available - v_dep_base, 2)
    );
END;
$function$


