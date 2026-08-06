-- db/migrations/2026-08-06-fin21-price-history-records-rate-date-and-side.sql
--
-- FIN-21:计价留痕带上【牌价取自哪一天、哪一侧】。
--
-- 走查发现:计价历史只显示 "4.24 USD @ 1.22" —— 没有日期、没有侧。FIN-19b 给
-- 重估预览和收付款核销行都加了 as-of 标记,这块屏没跟上;而定价恰恰按
-- fx_rate_for(币种, CURRENT_DATE, 'tt_sell') 解析 —— FIN-20 之前 CURRENT_DATE
-- 还错过一整个窗口。一个折算出来的价格必须能查回它用的牌价(FIN-13 第 5 条)。
--
-- 【为什么是加列,不是显示时再查】与 FIN-18 同理(derived-vs-recorded):
-- 定价那一刻用的 as-of 日期,事后从牌价表【推不回来】—— 牌价日后被订正,
-- 历史留痕跟着变,那是错的。所以定价函数把它记下来。
-- 旧行回填【不做】:那几行当时用的 as-of 没人记得,补出来的痕迹是假的
-- (与 processing_cost_entry_history 不补造历史行同一条规矩)。NULL = FIN-21
-- 之前的行,界面留白。
--
-- 【perm2b 连带】price_history 是列清单授权的遮蔽表:新列必须【同迁移】进
-- SELECT 授权清单 + _masked 视图,否则应用写得进读不出(42501,FIN-6 的坑)。
-- 两列都不敏感(日期与侧,不是价格)→ 直接授,masked 视图原样透出。
-- gate 的 colgrant 行会两侧断言。

BEGIN;

-- ── 1. 加列 ──────────────────────────────────────────────────────────────
ALTER TABLE public.price_history ADD COLUMN rate_as_of date;
ALTER TABLE public.price_history ADD COLUMN rate_type text
    CHECK (rate_type IN ('tt_buy', 'tt_sell', 'mid'));

COMMENT ON COLUMN public.price_history.rate_as_of IS
    '所用牌价【取自哪一天】(fx_rate_asof 的 as_of,FIN-21)。与定价日不同 = 回溯(FIN-19 规则内);NULL = FIN-21 之前的行,当时没记,不补造。';
COMMENT ON COLUMN public.price_history.rate_type IS
    '所用牌价的侧(tt_buy / tt_sell / mid,FIN-21)。采购计价恒为 tt_sell —— 这批货将来要向银行买外币去付。NULL = FIN-21 之前的行。';

-- ── 2. 列清单授权补上新列(表级 SELECT 已收回,清单是冻结的 —— perm2b)────
GRANT SELECT (rate_as_of, rate_type) ON public.price_history TO authenticated;

-- ── 3. 遮蔽视图带上新列(不敏感,原样透出)───────────────────────────────
CREATE OR REPLACE VIEW public.price_history_masked WITH (security_invoker = off) AS
 SELECT id,
    inbound_batch_id,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN old_unit_price
            ELSE NULL::numeric
        END AS old_unit_price,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN new_unit_price
            ELSE NULL::numeric
        END AS new_unit_price,
    currency,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN original_price
            ELSE NULL::numeric
        END AS original_price,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN fx_rate
            ELSE NULL::numeric
        END AS fx_rate,
    notes,
    created_at,
    created_by,
    rate_as_of,
    rate_type
   FROM price_history
  WHERE has_permission('module.inbound.view'::text);

-- ── 4. reprice_inbound_batch:问 fx_rate_asof(要 as_of),拒绝口径不变 ────
-- 缺牌价时 fx_rate_asof 返回空行;【再调一次 fx_rate_for】让它抛出唯一的那份
-- FX_RATE_MISSING|币种|日期|侧 —— 重估写入侧(revalue_foreign_balances)的同一
-- 模式,错误文案不写第二遍。
CREATE OR REPLACE FUNCTION public.reprice_inbound_batch(p_inbound_batch_id uuid, p_unit_price numeric, p_currency text DEFAULT 'USD'::text, p_fx_rate numeric DEFAULT NULL::numeric, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user      uuid := auth.uid();
    v_old       numeric;
    v_deleted   timestamptz;
    v_qty       numeric;
    v_remaining numeric;
    v_code      text;
    v_fx        numeric;
    v_fx_asof date;   -- FIN-21:牌价取自哪一天(fx_rate_asof 的 as_of)
    v_usd       numeric;
    v_split     jsonb;
    v_delta     numeric;
    v_ratio     numeric;
    v_inv       numeric := 0;
    v_cost      numeric := 0;
    v_lines     jsonb;
    v_je        jsonb := NULL;
BEGIN
    PERFORM require_permission('module.inbound.edit');
    SELECT unit_price, deleted_at, quantity, remaining_qty, code
    INTO v_old, v_deleted, v_qty, v_remaining, v_code
    FROM inbound_batches WHERE id = p_inbound_batch_id FOR UPDATE;
    IF NOT FOUND OR v_deleted IS NOT NULL THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', p_inbound_batch_id;
    END IF;
    IF p_unit_price IS NULL OR p_unit_price <= 0 THEN
        RAISE EXCEPTION 'PRICE_INVALID';
    END IF;
    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = p_currency) THEN
        RAISE EXCEPTION 'CURRENCY_INVALID|%', COALESCE(p_currency, '?');
    END IF;
    -- FIN-0:本位币 SGD 免换算;外币按【定价日】的行方卖出价(tt_sell)估值 ——
    -- 这批货将来要向银行买外币去付。当日无牌价即拒(FX_RATE_MISSING);
    -- 汇率不再由调用方递入(p_fx_rate 必须为空),原币与所用汇率仍进 price_history。
    IF p_fx_rate IS NOT NULL THEN
        RAISE EXCEPTION 'FX_RATE_NOT_ACCEPTED|%', p_currency;
    END IF;
    -- FIN-21:问 fx_rate_asof —— 同一条解析规则,多拿一个【取自哪一天】。
    -- 缺牌价时它返回空行;再调一次 fx_rate_for 让它抛出唯一的那份
    -- FX_RATE_MISSING|币种|日期|侧(重估写入侧同一模式,错误文案不写第二遍)。
    SELECT a.rate, a.as_of INTO v_fx, v_fx_asof
    FROM fx_rate_asof(p_currency, CURRENT_DATE, 'tt_sell') a;
    IF v_fx IS NULL THEN
        PERFORM fx_rate_for(p_currency, CURRENT_DATE, 'tt_sell');
    END IF;

    v_usd := round(p_unit_price * v_fx, 4);  -- 单价 4 位小数(FIN-0 起为 SGD 本位价;列名沿用 _usd,重命名与生产重建同批)

    -- GUC 放行本函数内的 unit_price 更新(guard_inbound_price_change),用毕即清,
    -- 免得同事务内后续的直改被误放行(同 movement_ctx 模式)。
    PERFORM set_config('evoltrya.price_ctx', 'set_inbound_unit_price', true);
    UPDATE inbound_batches
    SET unit_price = v_usd, updated_by = v_user, updated_at = now()
    WHERE id = p_inbound_batch_id;
    PERFORM set_config('evoltrya.price_ctx', '', true);

    INSERT INTO price_history (inbound_batch_id, old_unit_price, new_unit_price, currency, original_price, fx_rate,
                               rate_as_of, rate_type, notes, created_by)
    VALUES (p_inbound_batch_id, v_old, v_usd, p_currency, p_unit_price, v_fx,
            v_fx_asof, 'tt_sell', p_notes, v_user);

    -- cut 2a:计价即入账 —— 整批数量 × 价差(负债在收货整批上成立,非剩余量)。
    -- 记于定价日 CURRENT_DATE(到货日尚无金额,刻意如此);USD 口径(原币在 price_history)。
    -- 拆分算术来自 reprice_split —— 与 preview_reprice_inbound_batch 共用同一份。
    v_split := reprice_split(v_qty, v_remaining, v_old, v_usd);
    v_delta := (v_split->>'delta_usd')::numeric;
    v_ratio := (v_split->>'in_stock_ratio')::numeric;

    IF v_delta <> 0 THEN
        -- 拆账:在库份额进 1200,已消耗份额进 5000;贷方(负差时借方)恒 2000
        v_inv  := (v_split->>'inventory_share_usd')::numeric;
        v_cost := (v_split->>'cost_share_usd')::numeric;

        v_lines := '[]'::jsonb;
        IF abs(v_inv) > 0 THEN
            v_lines := v_lines || jsonb_build_object(
                'account_code', '1200',
                'side', CASE WHEN v_delta > 0 THEN 'debit' ELSE 'credit' END,
                'currency', 'SGD', 'amount_ccy', abs(v_inv),
                'line_memo', 'in-stock share');
        END IF;
        IF abs(v_cost) > 0 THEN
            v_lines := v_lines || jsonb_build_object(
                'account_code', '5000',
                'side', CASE WHEN v_delta > 0 THEN 'debit' ELSE 'credit' END,
                'currency', 'SGD', 'amount_ccy', abs(v_cost),
                'line_memo', 'consumed share');
        END IF;
        v_lines := v_lines || jsonb_build_object(
            'account_code', '2000',
            'side', CASE WHEN v_delta > 0 THEN 'credit' ELSE 'debit' END,
            'currency', 'SGD', 'amount_ccy', abs(v_delta));

        v_je := post_journal_entry(
            CURRENT_DATE,
            'Pricing ' || v_code,
            'purchase',
            p_inbound_batch_id,
            v_lines
        );
    END IF;

    RETURN jsonb_build_object(
        -- 旧返回键原样保留(既有调用方靠它们)
        'batch_id', p_inbound_batch_id,
        'unit_price_usd', v_usd,
        -- cut 5a 起的完整分解(界面与对账都要能逐项交代)
        'batch_code', v_code,
        'old_unit_price', v_old,
        'new_unit_price', v_usd,
        'price_delta_usd', v_delta,
        'in_stock_ratio', v_ratio,
        'inventory_share_usd', v_inv,
        'cost_share_usd', v_cost,
        'journal_code', v_je->>'code'
    );
END;
$function$;

COMMIT;
