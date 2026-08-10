-- ASY-1:化验预览【在提交会拒的地方也拒】—— 并且不再少乘一次汇率
--
-- 起因:化验页的 FIN-27 拒绝(PRICING_TERMS_NOT_COMMITTED)横幅写得很好,但
-- "记录并应用"仍是蓝色主按钮,而它必定失败 —— 违反"不得提供服务端保证会拒的控件"。
-- 查这一类时发现预览与提交的差距不止一个按钮:
--
-- 【一】预览【根本不换汇】,提交换。apply_assay_result 走
--     reprice_inbound_batch(…, 'USD', …);FIN-0 把本位币翻成 SGD 之后,USD 成了
--     外币,提交按【定价日的 tt_sell】折算入账,而 preview_reprice_inbound_batch
--     里写着 `v_usd := round(p_new_unit_price, 4)`,注释还留着翻本位币之前的
--     "(USD 时 fx = 1)"。线上实测(已回滚):同一个 10 USD/kg,
--     预览说新单价 10.0000、总调整 500.00,提交存 12.8000、过账 780.00 —— 差 56%。
--     而且屏幕上"当前单价"读的是批次里的【本位币】价,与那个 USD 新价并排显示,
--     两行根本不同口径。这是 FIN-12 那个"翻本位币后留下的常量"的又一株,也是
--     AGENTS.md 记的"预览重实现记账规则"的第四次 —— 这次连预览函数自己都算错。
--
-- 【二】提交会拒而预览不拒的两个闸:缺 USD 牌价(FX_RATE_MISSING)与期间锁/
--     年结(PERIOD_LOCKED / YEAR_CLOSED,价差不为零时提交要过账)。预览一声不吭,
--     按钮照给。
--
-- 修法是同一条:【让预览走提交那条路的同一段算术和同一批闸】,于是任何"提交会拒"
-- 都变成预览的 error,页面已有的红横幅照原样说明,按钮只需跟着横幅走。
--
--   * assert_posting_allowed(日期, source_type):把 post_journal_entry 里的年结闸
--     与期间锁闸【原样搬出来】,过账与试算共用一份(reprice_split / fx_rate_asof
--     的先例)。post_journal_entry 改为调它 —— 一份实现两个调用方,不是两份。
--   * preview_reprice_inbound_batch 收 p_currency(签名变了,所以同文件先 DROP
--     后 CREATE),换汇与舍入与 reprice_inbound_batch 逐行同构,缺牌价时用同一个
--     fx_rate_for 抛出同一份 FX_RATE_MISSING;价差不为零时同样过 assert_posting_allowed。
--   * 两个预览调用方显式传 'USD' —— 币种是数据,不靠默认(FX 规则)。
--
-- 【不属于本类的两件事,写下来免得下次又被当成拒绝】
--   * 缺金属行情【不拒】:calculate_metal_price_from_terms 跳过该金属(计 0)并
--     记进 skipped_metals,沿用 allocate_processing_costs 的先例。所以它不该禁按钮。
--   * 净值 ≤ 0【不拒】:apply_assay_result 照常落含量、跳过定价并记 note。
--     页面那条琥珀色提示是【警告不是拒绝】,按钮保持可用 —— 含量本身要落地。
--
-- fixture 40 双向钉:预览报错 ⇔ 提交被拒(三种闸各一臂),以及预览的数 = 提交后
-- 真正存进批次的数(汇率那一乘不能只在一边)。
-- NOTE: apply with ./db/apply_migration.sh

BEGIN;

-- ════════════════════════════════════════════════════════════════════════════
-- 1. 过账许可闸:从 post_journal_entry 原样搬出,过账与试算共用
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.assert_posting_allowed(p_entry_date date, p_source_type text)
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_locked      date;
    v_year_closed date;
BEGIN
    -- 【FIN-23:已结年度守卫 —— 与月锁无关的第二道闸,排在月锁之前】
    -- locked_before 是一条会动的线:reopen_period(月级、合法、留痕)会把它退回
    -- 已结年度之内 —— 回填分录进去,损益科目再动,留存收益就悄悄错了。这道闸
    -- 不跟着锁退:日期落进【仍有效】年结(year_closes.reopened_at IS NULL)的
    -- 一律点名拒绝。两道都命中时报 YEAR_CLOSED —— 年是更强的事实。
    -- 年结自己的分录凭 evoltrya.close_ctx 过(close_financial_year /
    -- reopen_financial_year 在同一事务内设置,用毕即清 —— movement_ctx 同款);
    -- 结转分录在 year_closes 行落库之前过账,本闸对它本就无感,ctx 是给
    -- 重开的冲销分录用的(先过账、后一次性盖章)。
    IF NOT (p_source_type = 'year_close'
            AND current_setting('evoltrya.close_ctx', true) = 'year_close') THEN
        SELECT MAX(yc.year_end) INTO v_year_closed
        FROM year_closes yc
        WHERE yc.reopened_at IS NULL AND p_entry_date <= yc.year_end;
        IF v_year_closed IS NOT NULL THEN
            RAISE EXCEPTION 'YEAR_CLOSED|%|%', p_entry_date, v_year_closed;
        END IF;
    END IF;

    -- 期间锁:早于 locked_before 的日期拒绝。
    -- 例外(FIN-23):年结分录及其冲销必须写进已被月结锁住的年末 ——
    -- 仅当 source_type='year_close' 且 close_ctx 在场时放行,别无他路。
    SELECT locked_before INTO v_locked FROM finance_settings WHERE id;
    IF v_locked IS NOT NULL AND p_entry_date < v_locked
       AND NOT (p_source_type = 'year_close'
                AND current_setting('evoltrya.close_ctx', true) = 'year_close') THEN
        RAISE EXCEPTION 'PERIOD_LOCKED|%|%', p_entry_date, v_locked;
    END IF;
END;
$function$;

COMMENT ON FUNCTION public.assert_posting_allowed(date, text) IS
    '过账许可闸(ASY-1):年结闸 + 期间锁,自 post_journal_entry 原样搬出。【一份实现两个调用方】—— 真过账与只读试算共用,免得预览放行一笔提交会拒的分录(reprice_split 的先例)。命中即点名抛 YEAR_CLOSED / PERIOD_LOCKED。';

-- ════════════════════════════════════════════════════════════════════════════
-- 2. post_journal_entry 改调那份闸(签名不变;闸的文字与次序原样)
-- ════════════════════════════════════════════════════════════════════════════
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

        INSERT INTO journal_lines (entry_id, account_id, debit, credit, currency, amount_ccy, fx_rate, fx_rate_date, line_memo)
        VALUES (
            v_entry_id,
            v_account.id,
            CASE WHEN v_side = 'debit'  THEN v_usd ELSE 0 END,
            CASE WHEN v_side = 'credit' THEN v_usd ELSE 0 END,
            v_currency,
            v_amount,
            v_fx,
            v_fx_date,
            v_line->>'line_memo'
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

-- ════════════════════════════════════════════════════════════════════════════
-- 3. 试算走提交那条路的同一段算术与同一批闸(签名变了 → 先 DROP 后 CREATE)
-- ════════════════════════════════════════════════════════════════════════════
DROP FUNCTION IF EXISTS public.preview_reprice_inbound_batch(uuid, numeric);

CREATE OR REPLACE FUNCTION public.preview_reprice_inbound_batch(p_inbound_batch_id uuid, p_new_unit_price numeric, p_currency text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_old       numeric;
    v_qty       numeric;
    v_remaining numeric;
    v_fx        numeric;
    v_fx_asof   date;
    v_base      numeric;
    v_split     jsonb;
    v_delta     numeric;
BEGIN
    PERFORM require_permission('data.view_prices');
    SELECT unit_price, quantity, remaining_qty
    INTO v_old, v_qty, v_remaining
    FROM inbound_batches
    WHERE id = p_inbound_batch_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', COALESCE(p_inbound_batch_id::text, '?');
    END IF;
    IF p_new_unit_price IS NULL OR p_new_unit_price <= 0 THEN
        RAISE EXCEPTION 'PRICE_INVALID';
    END IF;
    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = p_currency) THEN
        RAISE EXCEPTION 'CURRENCY_INVALID|%', COALESCE(p_currency, '?');
    END IF;

    -- 【与 reprice_inbound_batch 逐行同构】本位币免换算;外币按【定价日】(即
    -- 提交时的 CURRENT_DATE)的 tt_sell 折算,缺牌价时用同一个 fx_rate_for 抛出
    -- 同一份 FX_RATE_MISSING|币种|日期|侧。少乘这一次就是 ASY-1 之前那个 56% 的差。
    SELECT a.rate, a.as_of INTO v_fx, v_fx_asof
    FROM fx_rate_asof(p_currency, CURRENT_DATE, 'tt_sell') a;
    IF v_fx IS NULL THEN
        PERFORM fx_rate_for(p_currency, CURRENT_DATE, 'tt_sell');
    END IF;

    v_base  := round(p_new_unit_price * v_fx, 4);
    v_split := reprice_split(v_qty, v_remaining, v_old, v_base);
    v_delta := (v_split->>'delta_usd')::numeric;

    -- 价差不为零时提交要过账 —— 过账过不去的日子,试算也不许说"可以"
    IF v_delta <> 0 THEN
        PERFORM assert_posting_allowed(CURRENT_DATE, 'purchase');
    END IF;

    RETURN jsonb_build_object(
        'old_unit_price', v_old,
        'new_unit_price', v_base,
        'delta_usd', v_delta,
        'in_stock_ratio', (v_split->>'in_stock_ratio')::numeric,
        'inventory_share_usd', (v_split->>'inventory_share_usd')::numeric,
        'cost_share_usd', (v_split->>'cost_share_usd')::numeric,
        -- 折算用的牌价与它取自哪天:屏幕上的数是怎么来的,要指得出来(FIN-21)
        'fx_rate', v_fx,
        'rate_as_of', v_fx_asof,
        'currency', p_currency
    );
END;
$function$;

COMMENT ON FUNCTION public.preview_reprice_inbound_batch(uuid, numeric, text) IS
    '重计价的只读试算(ASY-1 起收币种)。与 reprice_inbound_batch【同一份拆账算术(reprice_split)、同一次换汇(tt_sell @ CURRENT_DATE)、同一批过账闸(assert_posting_allowed)】—— 提交会拒的地方试算也拒,提交存下的数试算也说得出来。fixture 40 双向钉。';

-- ════════════════════════════════════════════════════════════════════════════
-- 4. 两个预览调用方显式传币种(币种是数据,不靠默认)
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.preview_assay_price(p_inbound_batch_id uuid, p_metals jsonb, p_reference_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_batch  record;
    v_commit uuid;
    v_live   uuid;
    v_calc   jsonb;
    v_unit   numeric;
    v_impact jsonb := NULL;
BEGIN
    PERFORM require_permission('module.inbound.edit');
    IF p_reference_date IS NULL THEN
        RAISE EXCEPTION 'REFERENCE_DATE_REQUIRED';
    END IF;

    SELECT id, code, quantity, pricing_formula_id, purchase_order_line_id
    INTO v_batch FROM inbound_batches
    WHERE id = p_inbound_batch_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', COALESCE(p_inbound_batch_id::text, '?');
    END IF;

    v_commit := resolve_pricing_commitment(v_batch.id);
    IF v_commit IS NULL THEN
        v_live := COALESCE(v_batch.pricing_formula_id,
                           (SELECT pol.pricing_formula_id FROM purchase_order_lines pol
                             WHERE pol.id = v_batch.purchase_order_line_id));
        IF v_live IS NOT NULL THEN
            RAISE EXCEPTION 'PRICING_TERMS_NOT_COMMITTED|%|%', v_batch.code,
                COALESCE((SELECT pf.code FROM pricing_formulas pf WHERE pf.id = v_live), '?');
        END IF;
        RETURN jsonb_build_object('calc', NULL, 'impact', NULL);
    END IF;

    v_calc := calculate_metal_price_from_terms(
        pricing_terms_of_commitment(v_commit), p_metals, v_batch.quantity, p_reference_date);
    v_unit := (v_calc->>'unit_price_usd_per_kg')::numeric;
    -- 净值 ≤ 0 时不试算:apply_assay_result 那时也不定价(落含量、记 note),
    -- 【这是警告不是拒绝】—— 页面的琥珀提示照旧,按钮保持可用。
    IF v_unit > 0 THEN
        -- 计价口径是 USD/kg(行情与处理费都按 USD/吨),提交也是按 USD 递给
        -- reprice_inbound_batch 的 —— 币种在这里说出来,两边才对得上。
        v_impact := preview_reprice_inbound_batch(p_inbound_batch_id, v_unit, 'USD');
    END IF;
    RETURN jsonb_build_object('calc', v_calc, 'impact', v_impact);
END;
$function$;

CREATE OR REPLACE FUNCTION public.preview_reprice_from_committed_terms(p_inbound_batch_id uuid, p_reference_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_calc   jsonb;
    v_unit   numeric;
    v_impact jsonb := NULL;
BEGIN
    PERFORM require_permission('module.inbound.edit');
    v_calc := committed_terms_price(p_inbound_batch_id, p_reference_date);
    v_unit := (v_calc->>'unit_price_usd_per_kg')::numeric;
    -- 单价 ≤ 0 时不试算拆账(它会 PRICE_INVALID),但明细照给 —— 那种料
    -- apply_assay_result 本来也不会给它定价,摆一个"调整 −X 元"反而是误导。
    IF v_unit > 0 THEN
        -- 币种显式:提交路径 reprice_from_committed_terms 也是按 USD 递进去的
        v_impact := preview_reprice_inbound_batch(p_inbound_batch_id, v_unit, 'USD');
    END IF;
    RETURN jsonb_build_object('calc', v_calc, 'impact', v_impact);
END;
$function$;

COMMIT;
