-- FIN-13(2026-08-05):汇率可以就近取上一个【发布日】,但有界、有留痕。
-- 中间跨过的每一天都必须是非发布日(周末 / SG 生效假日),夹着工作日即拒绝;
-- 另有 4 个自然日的硬上限。fx_rate_asof 同时返回【实际取自哪一天】。
-- 理由与 4 天的由来见 db/migrations/2026-08-05-fin13-rate-asof-and-business-days.sql。
-- FIN-23(2026-08-06):两处改动 ——
--  ① YEAR_CLOSED 闸(月锁之前):日期落进仍有效年结的一律点名拒;月级 reopen_period
--    退锁穿不透它。② 月锁对 source_type='year_close' + evoltrya.close_ctx 放行 ——
--    年结分录与其冲销必须写进已被月结锁住的年末,别无他路。
-- ASY-1(2026-08-10):上面这两道闸【已搬进 assert_posting_allowed】,本函数改为调用 ——
--    只读试算(preview_reprice_inbound_batch)走同一份,免得预览放行一笔提交会拒的
--    分录。闸的语义没有变,变的是它现在有两个调用方。

-- ── GST-1 追加的一段 ────────────────────────────────────────────────────────
-- 每一行可以带一个税码,过账时原样落进 journal_lines.tax_code —— F5 的每一格
-- 都从那里推导。两条拒绝【都是必要的】,而且都有名字:
--   · 未注册却带税码 → GST_NOT_REGISTERED:关掉 GST 时的行为必须与建 GST 之前
--     一模一样,而"一模一样"要靠拦住写入来保证,不能靠没人去写。
--   · 税码那天没有生效税率 → 由 tax_rate_for 抛 TAX_RATE_NOT_FOUND(不回退)。
--     在过账时就问一次,是为了让它在【写进总账之前】炸,而不是等到出 F5 那天
--     才发现某一季的某几张单据算不出税。


CREATE OR REPLACE FUNCTION public.post_journal_entry(p_entry_date date, p_memo text, p_source_type text, p_source_id uuid, p_lines jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_line         jsonb;
    v_account      record;
    v_side         text;
    v_currency     text;
    v_amount       numeric;
    v_fx           numeric;
    v_usd          numeric;
    v_fx_date      date;
    v_base         text;
    v_total_debit  numeric := 0;
    v_total_credit numeric := 0;
    v_count        integer := 0;
    v_year         integer;
    v_seq          integer;
    v_code         text;
    v_entry_id     uuid;
    v_tax_code     text;
BEGIN
    SELECT c.code INTO v_base FROM currencies c WHERE c.is_base;
    IF p_entry_date IS NULL THEN
        RAISE EXCEPTION 'JE_LINE_INVALID|entry_date';
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- 过账许可:年结闸与期间锁 —— ASY-1 起【搬进 assert_posting_allowed】,
    -- 与只读试算共用一份,预览因此不会放行一笔提交会拒的分录。闸的文字、次序、
    -- close_ctx 例外原样搬走,这里只剩调用。
    PERFORM assert_posting_allowed(p_entry_date, p_source_type);

    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' THEN
        RAISE EXCEPTION 'JE_LINE_INVALID|lines';
    END IF;

    -- 无缝编号:咨询锁串行化"取当年最大号+1";失败回滚会释放号码。
    PERFORM pg_advisory_xact_lock(hashtext('je_code')::bigint);
    v_year := EXTRACT(YEAR FROM p_entry_date)::integer;
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM journal_entries
    WHERE code LIKE 'JE-' || v_year::text || '-%';
    v_code := 'JE-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');

    INSERT INTO journal_entries (code, entry_date, memo, source_type, source_id)
    VALUES (v_code, p_entry_date, p_memo, p_source_type, p_source_id)
    RETURNING id INTO v_entry_id;

    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        v_count := v_count + 1;

        SELECT id, code, is_active INTO v_account
        FROM accounts WHERE code = v_line->>'account_code';
        IF NOT FOUND THEN
            RAISE EXCEPTION 'ACCOUNT_NOT_FOUND|%', COALESCE(v_line->>'account_code', '?');
        END IF;
        IF NOT v_account.is_active THEN
            RAISE EXCEPTION 'ACCOUNT_INACTIVE|%', v_account.code;
        END IF;

        v_side := v_line->>'side';
        -- GST-1:这一行在 GST 上算什么。**绝大多数行没有税码,那是对的。**
        v_tax_code := NULLIF(v_line->>'tax_code', '');
        IF v_tax_code IS NOT NULL THEN
            -- 【没注册就不许盖税码】这一句把"开关关着 = 与今天一模一样"从一句
            -- 断言变成一条【写不进去】的规矩:未注册时根本产生不了带税码的行。
            IF NOT gst_registered() THEN
                RAISE EXCEPTION 'GST_NOT_REGISTERED|%', v_tax_code;
            END IF;
            IF NOT EXISTS (SELECT 1 FROM tax_codes WHERE code = v_tax_code AND is_active) THEN
                RAISE EXCEPTION 'TAX_CODE_UNKNOWN|%', v_tax_code;
            END IF;
            -- 【解析一次税率,只为了让"那一天没有税率"当场被拒】
            -- 不存下来:税额本身由分录行自己表达,存第二份就是两处陈述同一件事。
            PERFORM tax_rate_for(v_tax_code, p_entry_date);
        END IF;
        IF v_side IS NULL OR v_side NOT IN ('debit', 'credit') THEN
            RAISE EXCEPTION 'JE_LINE_INVALID|side';
        END IF;

        v_amount := (v_line->>'amount_ccy')::numeric;
        IF v_amount IS NULL OR v_amount <= 0 THEN
            RAISE EXCEPTION 'JE_LINE_INVALID|amount_ccy';
        END IF;

        v_currency := v_line->>'currency';
        IF v_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = v_currency) THEN
            RAISE EXCEPTION 'CURRENCY_INVALID|%', COALESCE(v_currency, '?');
        END IF;

        v_fx_date := NULLIF(v_line->>'fx_rate_date', '')::date;
        IF v_currency = v_base THEN
            v_fx := 1;
            v_fx_date := NULL;  -- 本位币没有取自哪天这回事  -- 本位币(FIN-0 起为 SGD)强制 1,忽略传入值
        ELSE
            v_fx := (v_line->>'fx_rate')::numeric;
            IF v_fx IS NULL THEN
                RAISE EXCEPTION 'FX_RATE_REQUIRED|%', v_currency;
            END IF;
            IF v_fx <= 0 THEN
                RAISE EXCEPTION 'JE_LINE_INVALID|fx_rate';
            END IF;
        END IF;

        v_usd := round(v_amount * v_fx, 2);

        INSERT INTO journal_lines (entry_id, account_id, debit, credit, currency, amount_ccy, fx_rate, fx_rate_date, line_memo, tax_code)
        VALUES (
            v_entry_id,
            v_account.id,
            CASE WHEN v_side = 'debit'  THEN v_usd ELSE 0 END,
            CASE WHEN v_side = 'credit' THEN v_usd ELSE 0 END,
            v_currency,
            v_amount,
            v_fx,
            v_fx_date,
            v_line->>'line_memo',
            v_tax_code
        );

        IF v_side = 'debit' THEN
            v_total_debit := v_total_debit + v_usd;
        ELSE
            v_total_credit := v_total_credit + v_usd;
        END IF;
    END LOOP;

    -- 空数组/单行:延迟触发器只在有行插入时排队,这里提前拦掉(否则空分录溜过)
    IF v_count < 2 THEN
        RAISE EXCEPTION 'JOURNAL_UNBALANCED|%|%|%', v_code, v_total_debit, v_total_credit;
    END IF;

    -- Σdebit = Σcredit 由 DEFERRED 触发器在提交时强制
    RETURN jsonb_build_object(
        'entry_id', v_entry_id,
        'code', v_code,
        'total_debit', v_total_debit,
        'total_credit', v_total_credit
    );
END;
$function$;