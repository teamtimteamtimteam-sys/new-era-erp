-- FX-RATES-1 FU1(2026-08-27):record_fx_rate 里 FOUND 被一句 PERFORM 冲掉了。
-- NOTE: apply with ./db/apply_migration.sh
--
-- 【症状】新建一条【并不存在】的牌价,被 FX_RATE_EXISTS 拒绝,
-- 而拒绝信息里的"旧值"是 <NULL> —— 因为那条 v_existing 记录压根是空的。
--
-- 【原因】`SELECT ... INTO v_existing` 之后,代码里隔了一句
-- `PERFORM set_config('evoltrya.fx_ctx', ...)` 才 `IF FOUND`。
-- **FOUND 反映的是【最近执行的那条语句】** —— 而 set_config 返回一行,
-- 于是 FOUND 恒为 true,"已经在册了吗"这个问题永远答是。
--
-- 【判据】问【记录本身】(v_existing.id IS NOT NULL),不要问一个会被后续语句
-- 改写的全局状态。与「一次失败不是一个空集」同源:**问对对象比问得早更重要。**
--
-- 【它是怎么被抓到的】上线前的一次回滚探针,不是靠读代码。
-- 只改这一处判断,其余逐字不动。

BEGIN;

CREATE OR REPLACE FUNCTION public.record_fx_rate(
    p_currency text, p_rate_date date, p_rate_type text,
    p_rate numeric, p_source text DEFAULT 'DBS',
    p_notes text DEFAULT NULL, p_reason text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_base text;
    v_existing record;
    v_id uuid;
    v_action text;
BEGIN
    PERFORM require_permission('module.finance.edit');
    SELECT c.code INTO v_base FROM currencies c WHERE c.is_base;

    IF p_rate_date IS NULL THEN
        RAISE EXCEPTION 'FX_RATE_DATE_REQUIRED';
    END IF;
    -- 【未来日期即拒】—— 见函数头。这一条今天的界面没有,是本刀补的。
    IF p_rate_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'FX_RATE_DATE_IN_FUTURE|%', p_rate_date;
    END IF;
    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = p_currency) THEN
        RAISE EXCEPTION 'FX_CURRENCY_INVALID|%', COALESCE(p_currency, '?');
    END IF;
    IF p_currency = v_base THEN
        RAISE EXCEPTION 'FX_CURRENCY_IS_BASE|%', p_currency;
    END IF;
    IF p_rate_type IS NULL OR p_rate_type NOT IN ('tt_buy', 'tt_sell', 'mid') THEN
        RAISE EXCEPTION 'FX_RATE_TYPE_INVALID|%', COALESCE(p_rate_type, '?');
    END IF;
    IF p_rate IS NULL OR p_rate <= 0 THEN
        RAISE EXCEPTION 'FX_RATE_INVALID|%', COALESCE(p_rate::text, 'null');
    END IF;

    SELECT * INTO v_existing FROM fx_rates
     WHERE currency = p_currency AND rate_date = p_rate_date
       AND rate_type = p_rate_type AND deleted_at IS NULL
     FOR UPDATE;

    PERFORM set_config('evoltrya.fx_ctx', 'record_fx_rate', true);

    -- 【不能用 FOUND】上面那句 PERFORM 会把 FOUND 重置成 true(set_config 返回一行),
    -- 于是"这条牌价已经在册了吗"永远答 true —— 实测:新建一条不存在的牌价被
    -- FX_RATE_EXISTS 挡住,而且参数里的旧值是 <NULL>,因为那条记录根本是空的。
    -- **FOUND 属于【最近一条语句】,不属于你想问的那一条。** 改问记录本身。
    IF v_existing.id IS NOT NULL THEN
        -- 【已经有一条了】没给理由就拒 —— 批量表格走的正是这一支:它只填空,
        -- 不覆盖。要改一条已在册的牌价,得说为什么。
        IF btrim(COALESCE(p_reason, '')) = '' THEN
            RAISE EXCEPTION 'FX_RATE_EXISTS|%|%|%|%',
                p_currency, p_rate_date, p_rate_type, v_existing.rate_sgd_per_unit;
        END IF;
        UPDATE fx_rates
           SET rate_sgd_per_unit = p_rate,
               source = COALESCE(p_source, source),
               notes  = p_notes,
               updated_by = auth.uid()
         WHERE id = v_existing.id;
        v_id := v_existing.id; v_action := 'corrected';
        INSERT INTO fx_rate_history (fx_rate_id, action, currency, rate_date, rate_type,
                                     rate_sgd_per_unit, prev_rate, source, notes, reason)
        VALUES (v_id, 'corrected', p_currency, p_rate_date, p_rate_type,
                p_rate, v_existing.rate_sgd_per_unit, p_source, p_notes, btrim(p_reason));
    ELSE
        INSERT INTO fx_rates (currency, rate_date, rate_type, rate_sgd_per_unit, source, notes)
        VALUES (p_currency, p_rate_date, p_rate_type, p_rate, COALESCE(p_source, 'DBS'), p_notes)
        RETURNING id INTO v_id;
        v_action := 'created';
        INSERT INTO fx_rate_history (fx_rate_id, action, currency, rate_date, rate_type,
                                     rate_sgd_per_unit, prev_rate, source, notes, reason)
        VALUES (v_id, 'created', p_currency, p_rate_date, p_rate_type,
                p_rate, NULL, COALESCE(p_source, 'DBS'), p_notes, NULL);
    END IF;

    PERFORM set_config('evoltrya.fx_ctx', '', true);
    RETURN jsonb_build_object('id', v_id, 'action', v_action,
                              'currency', p_currency, 'rate_date', p_rate_date,
                              'rate_type', p_rate_type, 'rate', p_rate);
END;
$function$;

COMMIT;
