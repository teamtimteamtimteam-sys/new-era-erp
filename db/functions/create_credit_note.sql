CREATE OR REPLACE FUNCTION public.create_credit_note(p_invoice_id uuid, p_note_date date, p_reason text, p_lines jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user     uuid := auth.uid();
    v_inv      invoices%ROWTYPE;
    v_cn_id    uuid := gen_random_uuid();
    v_code     text;
    v_open     numeric;
    v_el       jsonb;
    v_line_id  uuid;
    v_kind     text;
    v_amount   numeric;
    v_total    numeric := 0;
    v_a_total  numeric := 0;
    v_b_total  numeric := 0;
    v_grp      record;
    v_shipped  numeric;
    v_released numeric;
    v_ceiling  numeric;
    v_prior    numeric;
    v_je       jsonb;
    v_jlines   jsonb;
    v_n        int;
BEGIN
    -- 【为什么是 module.finance.edit】它直接改总账与应收 —— 与
    -- create_order_invoice(开票)同一道门。开票认下债,这张把债减回去。
    PERFORM require_permission('module.finance.edit');

    -- 【单据日必填,永不默认】它决定冲销落进哪个期间。补一个 CURRENT_DATE
    -- 会让留空比填对更容易通过:今天的日期永远撞不上 PERIOD_LOCKED。
    IF p_note_date IS NULL THEN
        RAISE EXCEPTION 'CN_NOTE_DATE_REQUIRED';
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'CN_REASON_REQUIRED';
    END IF;

    SELECT * INTO v_inv FROM invoices WHERE id = p_invoice_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CN_INVOICE_NOT_FOUND|%', COALESCE(p_invoice_id::text, '?');
    END IF;
    -- 【这两条守卫【也】在触发器上】这里再问一遍,是为了在算任何天花板之前
    -- 就给出正确的名字 —— 触发器要到 INSERT 那一刻才说话,而那时人已经
    -- 填完整张表单了(CMP-2:禁用与说明要在动作之前)。
    IF v_inv.kind <> 'order' THEN
        RAISE EXCEPTION 'CN_INVOICE_NOT_ORDER_KIND|%|%', v_inv.code, v_inv.kind;
    END IF;
    IF v_inv.status <> 'issued' THEN
        RAISE EXCEPTION 'CN_INVOICE_VOID|%', v_inv.code;
    END IF;

    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'CN_NO_LINES|%', v_inv.code;
    END IF;

    -- ── 天花板 ①:整张凭证 ≤ 这张发票【当下的】开放余额 ─────────────────────
    -- 读的是那一处不带过滤的算术(order_invoice_balance_all)。带过滤的那张
    -- 在 open = 0 时【没有行】,而把"没有行"读成 0 正是本仓库反复修的毛病 ——
    -- 这里要的恰恰是那个 0,并且要为它给出一个【专门的名字】。
    SELECT open_ccy INTO v_open FROM order_invoice_balance_all WHERE invoice_id = p_invoice_id;
    IF v_open IS NULL THEN
        -- issued + order 型必有一行(上面两条已经排除了别的情形)。走到这里
        -- 说明视图的前提变了 —— 当场炸,不要把它当成 0(那会让天花板消失)。
        RAISE EXCEPTION 'CN_BALANCE_MISSING|%', v_inv.code;
    END IF;
    IF v_open <= 0 THEN
        -- 【已经结清的发票不能再贷记】要还的是【现金】,那是一张付款单加一个
        -- 客户贷余概念,而这个系统今天没有客户贷余的落脚点。按名拒,
        -- 而不是让应收变成负数(那会在账龄上凭空消失、在敞口里悄悄抵扣)。
        RAISE EXCEPTION 'CN_INVOICE_FULLY_SETTLED|%', v_inv.code;
    END IF;

    -- ── 逐行校验 ────────────────────────────────────────────────────────────
    FOR v_el IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        v_line_id := NULLIF(v_el->>'invoice_line_id', '')::uuid;
        v_kind    := v_el->>'kind';
        v_amount  := NULLIF(v_el->>'amount', '')::numeric;

        IF v_line_id IS NULL THEN
            RAISE EXCEPTION 'CN_LINE_INVALID|%|%', COALESCE(v_el->>'line_no', '?'), 'invoice_line_id';
        END IF;
        IF v_kind IS NULL OR v_kind NOT IN ('unshipped_cancel','revenue_reduction') THEN
            RAISE EXCEPTION 'CN_LINE_INVALID|%|%', COALESCE(v_el->>'line_no', '?'), 'kind';
        END IF;
        IF v_amount IS NULL OR v_amount <= 0 THEN
            RAISE EXCEPTION 'CN_LINE_INVALID|%|%', COALESCE(v_el->>'line_no', '?'), 'amount';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM invoice_lines WHERE id = v_line_id AND invoice_id = p_invoice_id) THEN
            RAISE EXCEPTION 'CN_LINE_WRONG_INVOICE|%', v_line_id;
        END IF;

        v_total := v_total + v_amount;
        IF v_kind = 'unshipped_cancel' THEN v_a_total := v_a_total + v_amount;
        ELSE                                v_b_total := v_b_total + v_amount; END IF;
    END LOOP;

    IF round(v_total, 2) > round(v_open, 2) THEN
        RAISE EXCEPTION 'CN_EXCEEDS_OPEN|%|%', round(v_total, 2), round(v_open, 2);
    END IF;

    -- ── 天花板 ② / ③:逐【发票行 × 类型】────────────────────────────────────
    -- 【按分组算,不是逐条算】一张凭证可以在同一发票行上放两条同类型的行,
    -- 逐条检查会让两条各自"没超"、合起来超掉。分组之后再与【历史】相加。
    FOR v_grp IN
        SELECT (e->>'invoice_line_id')::uuid AS line_id,
               e->>'kind' AS kind,
               sum((e->>'amount')::numeric) AS want
        FROM jsonb_array_elements(p_lines) e
        GROUP BY 1, 2
    LOOP
        -- 这一行【已发】多少 —— 读 shipment_lines(货真的离开台账的记录,
        -- 与 line_spoken_for 同一个理由)。
        -- 【为什么可以拿发票行的单价去乘】SO-1b 起,坐在在册发票上的订单行
        -- 数量与单价【整个冻住】(SO_AMEND_LINE_INVOICED),所以发票行的单价
        -- 与发货当时用的那个是同一个数。这一条是本段算术的前提,不是巧合。
        SELECT COALESCE(sum(sl.qty), 0) INTO v_shipped
          FROM shipment_lines sl
          JOIN invoice_lines il ON il.sales_order_line_id = sl.sales_order_line_id
         WHERE il.id = v_grp.line_id;
        SELECT round(v_shipped * il.unit_price, 2) INTO v_released
          FROM invoice_lines il WHERE il.id = v_grp.line_id;

        -- 这一行同类型的【历史】贷记额
        SELECT COALESCE(sum(cl.amount), 0) INTO v_prior
          FROM credit_note_lines cl
         WHERE cl.invoice_line_id = v_grp.line_id AND cl.kind = v_grp.kind;

        IF v_grp.kind = 'unshipped_cancel' THEN
            -- 未释放的负债 = 这一行开票额 − 已释放进收入的部分
            SELECT round(il.amount_ccy - v_released, 2) INTO v_ceiling
              FROM invoice_lines il WHERE il.id = v_grp.line_id;
            v_ceiling := round(v_ceiling - v_prior, 2);
            IF round(v_grp.want, 2) > v_ceiling THEN
                RAISE EXCEPTION 'CN_EXCEEDS_UNRELEASED|%|%|%',
                    (SELECT line_no FROM invoice_lines WHERE id = v_grp.line_id),
                    round(v_grp.want, 2), v_ceiling;
            END IF;
        ELSE
            v_ceiling := round(v_released - v_prior, 2);
            IF round(v_grp.want, 2) > v_ceiling THEN
                RAISE EXCEPTION 'CN_EXCEEDS_RELEASED|%|%|%',
                    (SELECT line_no FROM invoice_lines WHERE id = v_grp.line_id),
                    round(v_grp.want, 2), v_ceiling;
            END IF;
        END IF;
    END LOOP;

    -- ── 过账:一张分录 ──────────────────────────────────────────────────────
    -- 【借 2500 未释放的那部分 / 借 4000 已释放的那部分 / 贷 1100 合计】
    -- 单据币种,按【发票存下来的】汇率 —— 见迁移抬头:换个汇率会凭空造出
    -- 一笔看起来完全正常的已实现汇兑,而没有任何钱动过。
    -- 【0 金额的腿一条都不发】post_journal_entry 的 amount_ccy > 0 会拒,
    -- 而且一条 0 的腿在分录上读起来像"这一段发生了但金额为零"。
    v_code := next_credit_note_code(p_note_date);
    v_jlines := '[]'::jsonb;
    IF v_a_total > 0 THEN
        v_jlines := v_jlines || jsonb_build_object('account_code', '2500', 'side', 'debit',
            'currency', v_inv.currency, 'amount_ccy', round(v_a_total, 2), 'fx_rate', v_inv.fx_rate,
            'line_memo', 'unshipped cancelled');
    END IF;
    IF v_b_total > 0 THEN
        v_jlines := v_jlines || jsonb_build_object('account_code', '4000', 'side', 'debit',
            'currency', v_inv.currency, 'amount_ccy', round(v_b_total, 2), 'fx_rate', v_inv.fx_rate,
            'line_memo', 'revenue reduction');
    END IF;
    v_jlines := v_jlines || jsonb_build_object('account_code', '1100', 'side', 'credit',
        'currency', v_inv.currency, 'amount_ccy', round(v_total, 2), 'fx_rate', v_inv.fx_rate);

    v_je := post_journal_entry(
        p_note_date,
        'Credit note ' || v_code || ' · ' || v_inv.code,
        'credit_note', v_cn_id,
        v_jlines);

    -- 【先过账再写单头】entry_id 因此可以是 NOT NULL,不需要"先写空、再回填"
    -- 那种单向放宽(与 create_order_invoice 逐字同一个顺序)。
    INSERT INTO credit_notes (id, code, invoice_id, reason, note_date, entry_id,
                              currency, fx_rate, created_by)
    VALUES (v_cn_id, v_code, p_invoice_id, btrim(p_reason), p_note_date,
            (v_je->>'entry_id')::uuid, v_inv.currency, v_inv.fx_rate, v_user);

    FOR v_el IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        INSERT INTO credit_note_lines (credit_note_id, invoice_line_id, kind, qty, amount)
        VALUES (v_cn_id,
                (v_el->>'invoice_line_id')::uuid,
                v_el->>'kind',
                NULLIF(v_el->>'qty', '')::numeric,
                (v_el->>'amount')::numeric);
    END LOOP;

    -- 【断言,不是假设】行的条数必须等于递进来的条数。将来有人给上面那个循环
    -- 加一个提前 CONTINUE,这里当场炸,而不是留下一张【分录按全部行算过、
    -- 明细却少了几条】的凭证 —— 那种凭证的总额与它自己的行对不上。
    SELECT count(*) INTO v_n FROM credit_note_lines WHERE credit_note_id = v_cn_id;
    IF v_n <> jsonb_array_length(p_lines) THEN
        RAISE EXCEPTION 'CN_LINES_LOST|%|%', jsonb_array_length(p_lines), v_n;
    END IF;

    -- 【订单历史也记一笔】看订单的人问"这张单后来减过账没有",那个问题的答案
    -- 不该要求他先去翻发票列表(与 'invoiced' / 'invoice_voided' 同一条)。
    IF v_inv.sales_order_id IS NOT NULL THEN
        INSERT INTO sales_order_history (sales_order_id, change_type, detail, changed_by)
        VALUES (v_inv.sales_order_id, 'credit_noted',
                v_code || ' · ' || v_inv.currency || ' ' || trim_scale(round(v_total, 2))::text
                || ' · ' || btrim(p_reason), v_user);
    END IF;

    RETURN jsonb_build_object(
        'credit_note_id', v_cn_id,
        'code', v_code,
        'invoice_code', v_inv.code,
        'note_date', p_note_date,
        'currency', v_inv.currency,
        'fx_rate', v_inv.fx_rate,
        'total_ccy', round(v_total, 2),
        'total_base', round(round(v_total, 2) * v_inv.fx_rate, 2),
        'unshipped_cancel_ccy', round(v_a_total, 2),
        'revenue_reduction_ccy', round(v_b_total, 2),
        'line_count', v_n,
        'open_ccy_after', round(v_open - v_total, 2),
        'journal_code', v_je->>'code');
END;
$function$

;
