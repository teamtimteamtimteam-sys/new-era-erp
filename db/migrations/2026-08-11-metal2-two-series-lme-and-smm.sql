-- METAL-2(2026-08-11):LME 与 SMM 是两条序列 —— 指数成为行情的一个轴,
--                      并且【跟着交易条款走】
--
-- 【本刀防的是什么】Doc 1 里 Tim 的原话是产出按 "LME or SMM" 计价 —— 合同挑指数。
-- 而 metal_prices 每个金属只有一条序列,所以那句话在这个系统里【说不出来】:
-- 一笔按 SMM 谈成的供应商合同,结算时对着表里唯一的那个数字。
--
-- 今天"没有行情"只有一种意思:这个金属压根没有价。两条序列之后,它多出一种,
-- 而且是更坏的一种:**这个金属在【合同约定的那个指数】上没有行情,
-- 而另一个指数上正躺着一条完全好用的数字**。旧的处置是"跳过、计零",
-- 于是那个金属会被算成一文不值 —— 正确答案就在隔壁一行。这是本刀要挡住的失败。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【指数是一个新轴,不是 source 的取值】source 今天 12 行全是 'manual',而且
-- 【没有任何代码读它】—— 它答的是"这个数字怎么来的"(手键 / 将来的抓取)。
-- 指数答的是"这是哪个市场的数字"。两者独立:将来抓 LME 的喂价要同时说
-- 【feed】与【LME】,而手键的 SMM 要同时说【manual】与【SMM】。挤进一列,
-- 两句话都说不成。所以 source 一字未动,指数另起一轴。
--
-- 【为什么是一张表而不是一个 CHECK】与 certificate_types 同一条:加第三个指数
-- (Fastmarkets、Asian Metal)应当是加一行,不是跑一次迁移。RUNTIME CONFIG。
--
-- 【UNIQUE ... NULLS NOT DISTINCT —— 这不是花招,是为了保住原来那条规矩】
-- 原来的 UNIQUE (metal, price_date) 保证"一个金属一天最多一条价"。直接换成
-- (metal, price_date, price_index) 会【恰好在未标注指数的那些行上失效】:
-- PostgreSQL 默认把 NULL 视为互不相同,于是同一个金属同一天可以插进两条
-- price_index 为空的行,而那正是今天全部 11 行所在的位置。NULLS NOT DISTINCT
-- (PG15+,线上 17.6)让空值彼此相等,原规矩因此在老数据上继续成立。
--
-- 【既有 11 行 price_index 为 NULL,不给它们指派】没人在录入时选过指数。
-- 指派一个,就是替 Tim 宣称他 6-25 那条铜价来自 LME —— 与给那条 80,000 编一个
-- "看起来合理"的数字是同一种伪造,而且更坏:结算会照着它算钱。
-- NULL = 【未声明指数】,是第三种状态,与 no_reference、「无检查记录」同形。
--
-- 【匹配规则:声明了指数的条款,看不见未标注的行情】
-- 反过来也一样,未声明指数的条款只看未标注的行情(IS NOT DISTINCT FROM)。
-- 让 LME 的单子去用一条未标注的报价,等于系统替那条报价宣称了出处 —— 那是同一种
-- 伪造晚一步发生。代价是明写的:公式一旦声明 LME,在 LME 报价录进来之前,
-- 结算会【点名拒绝】,而不是悄悄用一个不知出处的数字。那个拒绝就是本刀的产品。
--
-- 【指数是条款,所以承诺时抄下来】(FIN-27)与 price_basis、处理费同级:
-- 公式事后改指数,已成交的那一单仍按当初谈的那个结算。四处机械改动:
-- pricing_formulas 一列、pricing_term_commitments 一列、两个 terms 构造函数
-- 各一个键、commit_pricing_terms 抄一行。条款的形状没有被重构。
--
-- 【三条没有合同的路径】分摊(allocate_processing_costs)、销售的现货预设、
-- 库存页的估值 —— 它们没有对手方、没有条款,无从继承指数。它们用
-- pricing_settings.default_metal_index。**那是一个默认值在替一条缺席的条款站位,
-- 不是正确答案**:分摊的成本不是"按 LME 结算"的,它是"在没有条款可循时按当时的
-- 房屋约定取了价"。这句话写在每一个用它的地方,并且写进 allocation_snapshot
-- (price_index_is_house_default),免得日后有人把快照读成一条谈定的条款。
--
-- 【异常判据跟着改】METAL-1 的判据是"与该金属上一条报价比"。两条序列之后它必须是
-- "与该金属【在同一指数上】的上一条报价比" —— LME 与 SMM 本来就不同价,跨着比会
-- 天天报警,而天天报警的警报等于没有警报,人会学会点掉它。
--
-- 【本刀不抓任何东西】没有喂价、没有定时任务。抓取要什么,写在 §5 的报告里,
-- 而形状已经为它留好:source 说来路、price_index 说市场、唯一键就是幂等键。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 1 · 指数字典(RUNTIME CONFIG)────────────────────────────────────────────
CREATE TABLE public.metal_price_indices (
    code           text PRIMARY KEY,
    name_en        text NOT NULL,
    name_zh        text NOT NULL,
    -- 【报价币种:可以为空,而空是有意义的】见下面 SMM 那一行的理由。
    quote_currency text REFERENCES public.currencies (code),
    is_active      boolean NOT NULL DEFAULT true,
    sort_order     integer NOT NULL DEFAULT 0,
    notes          text,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    updated_by     uuid DEFAULT auth.uid()
);

COMMENT ON COLUMN public.metal_price_indices.quote_currency IS
$$这个指数按什么货币报价。【NULL = 还没有人声明,而不是"未知所以按 USD 算"】。

为什么 SMM 这一行是空的,而且不该被顺手填上:SMM 在市场上以 CNY/吨发布,这一点
可以查到;但【这家公司的 SMM 合同按什么货币结算】是一条交易条款,不是一个市场事实,
而 Tim 没有说过。替他填一个,就是编造一条商务条款 —— 与给那条 80,000 编一个看起来
合理的铜价是同一种伪造(FIN-26:宁可空着,不可编造)。

空着的后果是【明写并且响亮的】:calculate_metal_price_from_terms 在算钱之前拒绝,
报 INDEX_CURRENCY_NOT_STATED|SMM。于是 SMM 这条序列今天就可以录入、可以打标签、
可以在界面上看见,但【在 Tim 回答之前算不出钱】。这正是它该有的样子。

如果答案是 CNY:那是 currencies 里加一行、外加一条换算路径,而换算路径自带
"用哪一天的汇率"这个问题(THE FX RULE 管着它)—— 那是它自己的一刀,
不是在这里顺手改个列名。$$;

ALTER TABLE public.metal_price_indices ENABLE ROW LEVEL SECURITY;
-- 读:人人可读(与 metal_prices 同一条 —— 行情是市场事实,OPS-15)
CREATE POLICY "metal_price_indices select"
    ON public.metal_price_indices AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY "metal_price_indices write by permission"
    ON public.metal_price_indices AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.pricing.edit'))
    WITH CHECK (has_permission('module.pricing.edit'));

INSERT INTO public.metal_price_indices (code, name_en, name_zh, quote_currency, sort_order, notes) VALUES
    ('LME', 'London Metal Exchange', '伦敦金属交易所', 'USD', 1,
     'USD/吨是 LME 的市场惯例 —— 这一条是市场事实,可以直接声明。'),
    ('SMM', 'Shanghai Metals Market', '上海有色网', NULL, 2,
     '报价币种【故意留空】:SMM 在市场上以 CNY/吨发布,但本公司的 SMM 合同按什么货币结算是一条交易条款,Tim 尚未声明。填一个就是编造条款 —— 在他回答之前,按此指数计价会被点名拒绝(INDEX_CURRENCY_NOT_STATED)。理由全文见 metal_price_indices.quote_currency 的列注释。');

-- ── 2 · 房屋约定:没有合同可继承指数时用哪一个 ──────────────────────────────
-- 【默认值在替一条缺席的条款站位,不是正确答案】——留空即沿用未标注的老序列,
-- 与今天的行为完全一致。设成 'LME' 之后,分摊/现货预设/库存估值改看 LME 那条序列。
ALTER TABLE public.pricing_settings
    ADD COLUMN default_metal_index text REFERENCES public.metal_price_indices (code);

COMMENT ON COLUMN public.pricing_settings.default_metal_index IS
    'METAL-2:分摊、现货预设、库存估值这三条【没有合同】的路径取哪条序列的价。它替一条缺席的条款站位,不是"这些数字按某个声明的指数结算了"。NULL = 沿用未标注指数的老序列。';

-- ── 3 · 行情多一个轴 ────────────────────────────────────────────────────────
ALTER TABLE public.metal_prices
    ADD COLUMN price_index text REFERENCES public.metal_price_indices (code);

COMMENT ON COLUMN public.metal_prices.price_index IS
    'METAL-2:这条报价来自哪个市场。【NULL = 未声明指数】—— 既有 11 行都是这样,因为录入时没有人选过,而指派一个就是替它宣称出处。声明了指数的条款看不见这些行,反之亦然。与 source(这个数字怎么来的)是两个轴。';

-- 【为什么要 NULLS NOT DISTINCT】见抬头:不写它,"一个金属一天最多一条价"
-- 这条老规矩会恰好在未标注指数的那些行上失效,而那是今天全部数据所在的位置。
ALTER TABLE public.metal_prices DROP CONSTRAINT metal_prices_metal_price_date_key;
ALTER TABLE public.metal_prices
    ADD CONSTRAINT metal_prices_metal_price_date_index_key
    UNIQUE NULLS NOT DISTINCT (metal, price_date, price_index);

-- ── 4 · 指数是条款 ──────────────────────────────────────────────────────────
ALTER TABLE public.pricing_formulas
    ADD COLUMN price_index text REFERENCES public.metal_price_indices (code);
COMMENT ON COLUMN public.pricing_formulas.price_index IS
    'METAL-2:这份公式在哪个指数上结算 —— 交易条款,与 price_basis 同级,承诺时抄进 pricing_term_commitments。NULL = 未声明,只匹配未标注指数的行情。';

ALTER TABLE public.pricing_term_commitments
    ADD COLUMN price_index text REFERENCES public.metal_price_indices (code);
COMMENT ON COLUMN public.pricing_term_commitments.price_index IS
    'METAL-2:成交那一刻抄下的指数(FIN-27)。公式事后改指数,这一单仍按当初谈的那个结算。';


-- ── 5 · 判据与写入口:签名变了的三个,同一支迁移里先 DROP 再 CREATE ──────────
-- (db/preflight_migration.py 认得这个形状:先 DROP 旧签名再 CREATE 新签名是
--  合法替换,不是重载。顺序不能反。)

DROP FUNCTION IF EXISTS public.upsert_metal_prices(date, jsonb);
DROP FUNCTION IF EXISTS public.metal_price_anomaly(text, numeric, date, uuid);
DROP FUNCTION IF EXISTS public.preview_metal_price_anomalies(date, jsonb);

CREATE OR REPLACE FUNCTION public.metal_price_anomaly(
    p_metal text, p_price numeric, p_price_date date,
    p_price_index text DEFAULT NULL, p_exclude_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_ref_price numeric;
    v_ref_date  date;
    v_side      text;
    v_threshold numeric;
    v_change    numeric;
BEGIN
    IF p_metal IS NULL OR p_price IS NULL OR p_price <= 0 OR p_price_date IS NULL THEN
        RAISE EXCEPTION 'METAL_PRICE_ANOMALY_INPUT|%|%|%', p_metal, p_price, p_price_date;
    END IF;

    SELECT metal_price_change_warn_pct INTO v_threshold FROM pricing_settings WHERE id;
    IF v_threshold IS NULL THEN
        RAISE EXCEPTION 'PRICING_SETTINGS_MISSING';
    END IF;

    -- 【METAL-2:参照必须来自【同一个指数】】LME 与 SMM 本来就不同价,跨着比会
    -- 天天报警 —— 而天天报警的警报等于没有警报,人会学会点掉它,连真的那次一起点掉。
    -- IS NOT DISTINCT FROM:未标注指数的老序列只与老序列比,不与任何新序列比。
    --
    -- 上一条:按 price_date,不按 created_at(补录会让 created_at 说谎 —— ASY-3
    -- 实测:6-25 的行情 7-2 才录进来)
    SELECT price_usd_per_tonne, price_date INTO v_ref_price, v_ref_date
      FROM metal_prices
     WHERE metal = p_metal AND deleted_at IS NULL
       AND price_index IS NOT DISTINCT FROM p_price_index
       AND price_date < p_price_date
       AND (p_exclude_id IS NULL OR id <> p_exclude_id)
     ORDER BY price_date DESC LIMIT 1;
    v_side := 'previous';

    IF v_ref_price IS NULL THEN
        -- 没有更早的一条:回落到最近的更晚一条,并说明用的是哪一侧。
        SELECT price_usd_per_tonne, price_date INTO v_ref_price, v_ref_date
          FROM metal_prices
         WHERE metal = p_metal AND deleted_at IS NULL
           AND price_index IS NOT DISTINCT FROM p_price_index
           AND price_date > p_price_date
           AND (p_exclude_id IS NULL OR id <> p_exclude_id)
         ORDER BY price_date ASC LIMIT 1;
        v_side := 'later';
    END IF;

    IF v_ref_price IS NULL THEN
        -- 【第三种判词,不是 false】这个金属在【这个指数上】还没有别的报价可比。
        -- 两条序列之后这一种会更常见(每个金属在每个新指数上的第一条),
        -- 而它依然不等于"查过、没问题"。补上它需要 per-metal 的绝对区间:
        -- 7 个金属 × 上下界 = 14 个数字,那是一个决定,不是一次实现。
        RETURN jsonb_build_object(
            'verdict', 'no_reference',
            'metal', p_metal,
            'price_index', p_price_index,
            'price_usd_per_tonne', p_price,
            'price_date', p_price_date,
            'threshold_pct', v_threshold,
            'reference_price', NULL,
            'reference_date', NULL,
            'reference_side', NULL,
            'change_pct', NULL,
            'checked_at', now()
        );
    END IF;

    v_change := round(abs(p_price - v_ref_price) / v_ref_price * 100, 2);

    RETURN jsonb_build_object(
        'verdict', CASE WHEN v_change > v_threshold THEN 'outside' ELSE 'inside' END,
        'metal', p_metal,
        'price_index', p_price_index,
        'price_usd_per_tonne', p_price,
        'price_date', p_price_date,
        'threshold_pct', v_threshold,
        'reference_price', v_ref_price,
        'reference_date', v_ref_date,
        'reference_side', v_side,
        'change_pct', v_change,
        'checked_at', now()
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.preview_metal_price_anomalies(
    p_price_date date, p_prices jsonb, p_price_index text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_el     jsonb;
    v_metal  text;
    v_raw    text;
    v_price  numeric;
    v_out    jsonb := '[]'::jsonb;
    v_exists uuid;
BEGIN
    IF p_price_date IS NULL THEN
        RAISE EXCEPTION 'PRICE_DATE_REQUIRED';
    END IF;
    IF p_prices IS NULL OR jsonb_typeof(p_prices) <> 'array' THEN
        RAISE EXCEPTION 'NO_PRICES';
    END IF;

    FOR v_el IN SELECT * FROM jsonb_array_elements(p_prices)
    LOOP
        v_metal := v_el->>'metal';
        v_raw   := v_el->>'price_usd_per_tonne';
        -- 空格子跳过 —— 与 upsert_metal_prices 同一条:每日表单常常只填几个金属
        CONTINUE WHEN v_raw IS NULL OR btrim(v_raw) = '';
        v_price := v_raw::numeric;
        CONTINUE WHEN v_price IS NULL OR v_price <= 0;

        -- 覆盖【同一指数上】已有的同日行时,那一行自己不能当参照
        SELECT id INTO v_exists FROM metal_prices
         WHERE metal = v_metal AND price_date = p_price_date
           AND price_index IS NOT DISTINCT FROM p_price_index
           AND deleted_at IS NULL;

        v_out := v_out || jsonb_build_array(
            metal_price_anomaly(v_metal, v_price, p_price_date, p_price_index, v_exists));
    END LOOP;

    RETURN v_out;
END;
$function$;

CREATE OR REPLACE FUNCTION public.trg_metal_price_anomaly()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- 【只在 metal / 价格 / 行情日 / 指数真的变了时重算】判词是【写入那一刻】的
    -- 记录:改个备注、软删一行都不该覆盖它(后来的报价会让重算得出另一个答案)。
    -- METAL-2:指数也进这个判断 —— 把一行从 LME 改标成 SMM,它的参照就换了一条
    -- 序列,判词必须跟着重算。
    IF TG_OP = 'UPDATE'
       AND NEW.metal = OLD.metal
       AND NEW.price_usd_per_tonne = OLD.price_usd_per_tonne
       AND NEW.price_date = OLD.price_date
       AND NEW.price_index IS NOT DISTINCT FROM OLD.price_index THEN
        NEW.anomaly_check := OLD.anomaly_check;
        RETURN NEW;
    END IF;

    -- 【永不拒】提醒不是拦截:3 倍的真实行情是可能的,而系统分不出哪一种是哪一种。
    NEW.anomaly_check := metal_price_anomaly(
        NEW.metal, NEW.price_usd_per_tonne, NEW.price_date, NEW.price_index, NEW.id);
    RETURN NEW;
END;
$function$;

-- ── 6 · 条款、计价、分摊:定点改写(取自线上定义,只动该动的几处)───────────
CREATE OR REPLACE FUNCTION public.pricing_terms_of_formula(p_formula_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_f   pricing_formulas%ROWTYPE;
    v_pay jsonb;
BEGIN
    SELECT * INTO v_f FROM pricing_formulas
    WHERE id = p_formula_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'FORMULA_NOT_FOUND|%', COALESCE(p_formula_id::text, '?');
    END IF;
    IF NOT v_f.is_active THEN
        RAISE EXCEPTION 'FORMULA_INACTIVE|%', v_f.code;
    END IF;

    SELECT COALESCE(jsonb_object_agg(pfm.metal, pfm.payable_pct), '{}'::jsonb)
    INTO v_pay
    FROM pricing_formula_metals pfm WHERE pfm.formula_id = p_formula_id;

    RETURN jsonb_build_object(
        'terms_source', 'formula',
        'commitment_id', NULL,
        'formula_id', v_f.id,
        'formula_code', v_f.code,
        'formula_name', v_f.name,
        -- METAL-2:结算挂在哪个指数上是【交易条款】,与 price_basis 同级 ——
        -- 所以它跟着条款走,承诺时一并抄下(FIN-27)。
        -- NULL = 【未声明指数】,只匹配同样未标注指数的行情,不是"匹配任意行情":
        -- 拿一条没人说过出处的报价去结一笔说明了指数的单,就是替它宣称了出处。
        'price_index', v_f.price_index,
        'price_basis', v_f.price_basis,
        'average_days', v_f.average_days,
        'treatment_charge_usd_per_tonne', v_f.treatment_charge_usd_per_tonne,
        'flat_discount_pct', v_f.flat_discount_pct,
        'payables', v_pay
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.pricing_terms_of_commitment(p_commitment_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_c   pricing_term_commitments%ROWTYPE;
    v_pay jsonb;
BEGIN
    SELECT * INTO v_c FROM pricing_term_commitments WHERE id = p_commitment_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PRICING_COMMITMENT_NOT_FOUND|%', COALESCE(p_commitment_id::text, '?');
    END IF;

    SELECT COALESCE(jsonb_object_agg(m.metal, m.payable_pct), '{}'::jsonb)
    INTO v_pay
    FROM pricing_term_commitment_metals m WHERE m.commitment_id = p_commitment_id;

    RETURN jsonb_build_object(
        'terms_source', 'commitment',
        'commitment_id', v_c.id,
        'formula_id', v_c.source_formula_id,
        'formula_code', v_c.source_formula_code,
        'formula_name', v_c.source_formula_name,
        -- METAL-2:成交时抄下的指数。公式事后改指数,这一单仍按当初谈的那个结算。
        'price_index', v_c.price_index,
        'price_basis', v_c.price_basis,
        'average_days', v_c.average_days,
        'treatment_charge_usd_per_tonne', v_c.treatment_charge_usd_per_tonne,
        'flat_discount_pct', v_c.flat_discount_pct,
        'payables', v_pay
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.commit_pricing_terms(p_formula_id uuid, p_purchase_order_line_id uuid DEFAULT NULL::uuid, p_inbound_batch_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_terms jsonb;
    v_id    uuid;
BEGIN
    IF num_nonnulls(p_purchase_order_line_id, p_inbound_batch_id) <> 1 THEN
        RAISE EXCEPTION 'COMMITMENT_TARGET_INVALID';
    END IF;
    -- 活公式的检查(不存在/软删/停用)在这里发生,而且【只发生在承诺时】:
    -- 结算时再检查活公式,就又把模板的现状拉回到已成交的交易里了。
    v_terms := pricing_terms_of_formula(p_formula_id);

    INSERT INTO pricing_term_commitments (
        purchase_order_line_id, inbound_batch_id,
        source_formula_id, source_formula_code, source_formula_name,
        price_index, price_basis, average_days, treatment_charge_usd_per_tonne, flat_discount_pct)
    VALUES (
        p_purchase_order_line_id, p_inbound_batch_id,
        (v_terms->>'formula_id')::uuid, v_terms->>'formula_code', v_terms->>'formula_name',
        v_terms->>'price_index', v_terms->>'price_basis', (v_terms->>'average_days')::integer,
        (v_terms->>'treatment_charge_usd_per_tonne')::numeric,
        (v_terms->>'flat_discount_pct')::numeric)
    RETURNING id INTO v_id;

    INSERT INTO pricing_term_commitment_metals (commitment_id, metal, payable_pct)
    SELECT v_id, e.key, e.value::numeric
    FROM jsonb_each_text(v_terms->'payables') e;

    RETURN v_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.calculate_metal_price_from_terms(p_terms jsonb, p_metals jsonb, p_quantity_kg numeric, p_reference_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_ref          date;
    v_index        text;
    v_index_ccy    text;
    v_index_known  boolean;
    v_basis        text;
    v_avg_days     integer;
    v_payables     jsonb;
    v_el           jsonb;
    v_metal        text;
    v_content      numeric;
    v_seen         text[] := ARRAY[]::text[];
    v_payable      numeric;
    v_stated       boolean;   -- ASY-2:本金属在条款里【有没有】被提到
    v_price        numeric;
    v_price_date   date;
    v_from         date;
    v_to           date;
    v_contained    numeric;
    v_payable_kg   numeric;
    v_value        numeric;
    v_lines        jsonb := '[]'::jsonb;
    v_skipped      text[] := ARRAY[]::text[];
    v_unpaid       text[] := ARRAY[]::text[];
    v_gross        numeric := 0;
    v_treatment    numeric;
    v_discount     numeric;
    v_net          numeric;
    v_unit         numeric;
BEGIN
    IF p_reference_date IS NULL THEN
        RAISE EXCEPTION 'REFERENCE_DATE_REQUIRED';
    END IF;
    v_ref := p_reference_date;
    IF p_terms IS NULL OR jsonb_typeof(p_terms) <> 'object' THEN
        RAISE EXCEPTION 'PRICING_TERMS_INVALID';
    END IF;
    -- METAL-2:【报价币种没声明就不许算钱】本函数是 USD 进 USD 出(FIN-15 记过:
    -- 换算属于路径,不属于本函数)。一个指数若没声明它按什么货币报价,把它的数字
    -- 当成 USD 就是替这个市场宣称了一件没人说过的事 —— 那与编造一个汇率是同一件事,
    -- 而 THE FX RULE 对编造汇率的答复是:拒绝,并说出缺的是什么。
    -- 未声明指数(v_index IS NULL)的老序列不走这道闸:它按 USD 记了一整年,
    -- 这一点由 metal_prices.price_usd_per_tonne 这个列名本身承担(见迁移抬头)。
    IF v_index IS NOT NULL THEN
        SELECT i.quote_currency, true INTO v_index_ccy, v_index_known
        FROM metal_price_indices i WHERE i.code = v_index AND i.is_active;
        IF NOT COALESCE(v_index_known, false) THEN
            RAISE EXCEPTION 'PRICE_INDEX_UNKNOWN|%', v_index;
        END IF;
        IF v_index_ccy IS NULL THEN
            RAISE EXCEPTION 'INDEX_CURRENCY_NOT_STATED|%', v_index;
        END IF;
    END IF;
    -- METAL-2:条款声明的指数。NULL = 未声明,只看同样未标注指数的行情。
    v_index    := p_terms->>'price_index';
    v_basis    := p_terms->>'price_basis';
    v_avg_days := (p_terms->>'average_days')::integer;
    v_payables := COALESCE(p_terms->'payables', '{}'::jsonb);

    -- 2. 数量
    IF p_quantity_kg IS NULL OR p_quantity_kg <= 0 THEN
        RAISE EXCEPTION 'QUANTITY_INVALID';
    END IF;

    -- 3. 金属清单
    IF p_metals IS NULL OR jsonb_typeof(p_metals) <> 'array' OR jsonb_array_length(p_metals) = 0 THEN
        RAISE EXCEPTION 'NO_METALS';
    END IF;

    FOR v_el IN SELECT * FROM jsonb_array_elements(p_metals)
    LOOP
        v_metal := v_el->>'metal';
        IF v_metal IS NULL OR v_metal NOT IN ('ni','co','li','mn','cu','al','fe') THEN
            RAISE EXCEPTION 'METAL_INVALID|%', COALESCE(v_metal, '?');
        END IF;
        IF v_metal = ANY (v_seen) THEN
            RAISE EXCEPTION 'DUPLICATE_METAL|%', v_metal;
        END IF;
        v_seen := v_seen || v_metal;

        v_content := (v_el->>'content_pct')::numeric;
        IF v_content IS NULL OR v_content < 0 OR v_content > 100 THEN
            RAISE EXCEPTION 'CONTENT_INVALID|%|%', v_metal, COALESCE((v_el->>'content_pct'), '?');
        END IF;

        -- 4. 商务条款:条款里没有这个金属 = 完全不计价(payable 0),记入 unpaid_metals。
        --    注意与 skipped 的区别:unpaid 是"没谈价",skipped 是"没行情"。
        -- ASY-2:【条款里没有这个金属】与【条款写明 0%】是两件事,不能都印成 0。
        -- v_stated 把这个区别一路带到输出行:未约定的行 payable/payable_kg/value
        -- 一律给 NULL(界面渲染成"—"),0 从此只属于真的谈成了零的条款。
        -- payable_pct 的 CHECK 是 >= 0,所以"明确 0%"是可表示的、正当的一种条款。
        v_stated := v_payables ? v_metal;
        IF v_stated THEN
            v_payable := (v_payables->>v_metal)::numeric;
        ELSE
            v_payable := 0;
            v_unpaid := v_unpaid || v_metal;
        END IF;

        -- 5. 行情:spot 取参考日之前最近一条;average 取窗口内均值(窗口内无行 → NULL)。
        v_price := NULL; v_price_date := NULL; v_from := NULL; v_to := NULL;
        IF v_basis = 'spot' THEN
            SELECT mp.price_usd_per_tonne, mp.price_date
            INTO v_price, v_price_date
            FROM metal_prices mp
            WHERE mp.metal = v_metal AND mp.deleted_at IS NULL AND mp.price_date <= v_ref
              -- METAL-2:只看本条款声明的那个指数。IS NOT DISTINCT FROM 让
              -- 【未声明】只匹配【未标注】,而不是匹配任何一条。
              AND mp.price_index IS NOT DISTINCT FROM v_index
            ORDER BY mp.price_date DESC
            LIMIT 1;
        ELSE
            -- price_from / price_to 报【实际参与均值的行】的日期范围,而不是名义窗口 ——
            -- 结算单据上要能看出这个均价到底由哪几天的行情撑起来。
            SELECT avg(mp.price_usd_per_tonne), min(mp.price_date), max(mp.price_date)
            INTO v_price, v_from, v_to
            FROM metal_prices mp
            WHERE mp.metal = v_metal AND mp.deleted_at IS NULL
              AND mp.price_index IS NOT DISTINCT FROM v_index   -- METAL-2:同上
              AND mp.price_date BETWEEN (v_ref - (v_avg_days - 1)) AND v_ref;
        END IF;

        -- 无可用行情 → 跳过(贡献 0),记入 skipped_metals;沿用 allocate_processing_costs
        -- 的先例:缺行情从来不是硬错误。
        IF v_price IS NULL THEN
            v_skipped := v_skipped || v_metal;
        END IF;

        -- 6. 逐行数量与金额
        v_contained  := round(p_quantity_kg * v_content / 100.0, 4);
        v_payable_kg := round(v_contained * v_payable / 100.0, 4);
        v_value      := CASE WHEN v_price IS NULL THEN 0
                             ELSE round(v_payable_kg / 1000.0 * v_price, 2) END;
        v_gross := v_gross + v_value;

        -- 缺行情/未计价的金属同样出现在 lines 里(金额 0、价格 NULL)——
        -- 结算单据要能逐项交代,不能让它们凭空消失。
        v_lines := v_lines || jsonb_build_object(
            'metal', v_metal,
            'content_pct', v_content,
            -- 未约定 → NULL("未列明"),而不是 0("谈定不付")。金额同理:
            -- 没有条款算不出金额,没有行情也算不出 —— 两种 NULL 都由界面渲染成"—",
            -- 上方的灰字/琥珀提示分别说明是哪一种。汇总仍按 0 累加(贡献确实为零)。
            'payable_pct', CASE WHEN v_stated THEN v_payable END,
            'contained_kg', v_contained,
            'payable_kg', CASE WHEN v_stated THEN v_payable_kg END,
            'price_index', v_index,
            'price_usd_per_tonne', v_price,
            'price_date', v_price_date,
            'price_from', v_from,
            'price_to', v_to,
            'metal_value_usd', CASE WHEN v_stated AND v_price IS NOT NULL THEN v_value END
        );
    END LOOP;

    -- 7. 汇总
    v_gross     := round(v_gross, 2);
    v_treatment := round(p_quantity_kg / 1000.0 * (p_terms->>'treatment_charge_usd_per_tonne')::numeric, 2);
    v_discount  := round(v_gross * (p_terms->>'flat_discount_pct')::numeric / 100.0, 2);
    v_net       := round(v_gross - v_treatment - v_discount, 2);
    v_unit      := round(v_net / p_quantity_kg, 4);

    RETURN jsonb_build_object(
        'formula_id', (p_terms->>'formula_id')::uuid,
        'formula_code', p_terms->>'formula_code',
        'formula_name', p_terms->>'formula_name',
        'price_index', v_index,
        'price_basis', v_basis,
        'average_days', v_avg_days,
        -- FIN-27:这个数按【哪一份条款】算出来的,以及那份条款的费率本身 ——
        -- 出处要能重导出,就不能只给导出后的金额(FIN-26 的同一条道理)。
        'terms_source', p_terms->>'terms_source',
        'commitment_id', p_terms->>'commitment_id',
        'treatment_charge_usd_per_tonne', (p_terms->>'treatment_charge_usd_per_tonne')::numeric,
        'flat_discount_pct', (p_terms->>'flat_discount_pct')::numeric,
        'reference_date', v_ref,
        'quantity_kg', p_quantity_kg,
        'lines', v_lines,
        'gross_value_usd', v_gross,
        'treatment_usd', v_treatment,
        'discount_usd', v_discount,
        'net_value_usd', v_net,
        'unit_price_usd_per_kg', v_unit,
        -- 低品位料确实可能"不值它的处理费";照实返回,由调用方决定接不接这单。
        'negative_value', (v_net < 0),
        'skipped_metals', to_jsonb(v_skipped),
        'unpaid_metals', to_jsonb(v_unpaid)
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.price_output_sale(p_output_batch_id uuid, p_formula_id uuid, p_currency text, p_quantity numeric, p_reference_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    -- 【收钱进来 → tt_buy】。改这一处等于把整个卖方报价换到错误的一边 ——
    -- fixture 38 A 臂在 tt_buy 与 tt_sell 不同的日子上钉着它。
    v_side       constant text := 'tt_buy';
    v_batch      record;
    v_metals     jsonb;
    v_terms      jsonb;
    v_mode       text;
    v_default_index text;
    v_formula_code text;
    v_formula_dir  text;
    v_formula_active boolean;
    v_formula_deleted timestamptz;
    v_result     jsonb;
    v_skipped    text[];
    v_usd_price  numeric;
    v_usd        record;
    v_doc        record;
    v_factor     numeric;
    v_unit_ccy   numeric;
BEGIN
    -- 报价就是价格信息(与 calculate_metal_price 同一道门)
    PERFORM require_permission('data.view_prices');

    IF p_reference_date IS NULL THEN
        RAISE EXCEPTION 'REFERENCE_DATE_REQUIRED';
    END IF;
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'QUANTITY_INVALID';
    END IF;
    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = p_currency) THEN
        RAISE EXCEPTION 'CURRENCY_INVALID|%', COALESCE(p_currency, '?');
    END IF;

    SELECT ob.id, ob.code INTO v_batch
    FROM output_batches ob WHERE ob.id = p_output_batch_id AND ob.deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'OUTPUT_BATCH_NOT_FOUND|%', COALESCE(p_output_batch_id::text, '?');
    END IF;

    -- 金属含量来自产出批自己的化验(output_batch_metals)—— 卖的是这批货的含量
    SELECT COALESCE(jsonb_agg(jsonb_build_object('metal', m.metal, 'content_pct', m.content_pct)), '[]'::jsonb)
    INTO v_metals
    FROM output_batch_metals m WHERE m.output_batch_id = p_output_batch_id;
    IF v_metals = '[]'::jsonb THEN
        RAISE EXCEPTION 'NO_METAL_CONTENT|%', v_batch.code;
    END IF;

    IF p_formula_id IS NOT NULL THEN
        v_mode := 'formula';
        SELECT code, direction, is_active, deleted_at
        INTO v_formula_code, v_formula_dir, v_formula_active, v_formula_deleted
        FROM pricing_formulas WHERE id = p_formula_id;
        IF NOT FOUND OR v_formula_deleted IS NOT NULL THEN
            RAISE EXCEPTION 'FORMULA_NOT_FOUND|%', p_formula_id;
        END IF;
        IF NOT v_formula_active THEN
            RAISE EXCEPTION 'FORMULA_INACTIVE|%', v_formula_code;
        END IF;
        -- 买方公式不能拿来卖:方向是公式自己声明的商务属性
        IF v_formula_dir NOT IN ('sale', 'both') THEN
            RAISE EXCEPTION 'FORMULA_DIRECTION|%|%', v_formula_code, v_formula_dir;
        END IF;
        v_terms := pricing_terms_of_formula(p_formula_id);
    ELSE
        -- ── 现货预设:【填出同一份 terms,走同一台引擎】——————————————————————
        -- 100% 应付、零处理费、零折扣、spot 基准。这不是第四条算术分支:
        -- 下面这份 jsonb 与 pricing_terms_of_formula 的输出同构,进的是同一个
        -- calculate_metal_price_from_terms。fixture 38 B 臂断言它与显式的
        -- 100%/0/0 公式给出同一个数 —— 那正是"预设而非分支"的证明。
        v_mode := 'spot_preset';
        -- METAL-2:现货预设【没有合同可以继承指数】—— 它不是一笔谈定的交易,
        -- 而是"照今天的牌价先算个数"。所以它用 pricing_settings 里的房屋约定。
        -- 【这是一个默认值在替一条缺席的条款站位,不是正确答案】:真正谈成的单子
        -- 会自己声明指数,而这里只是没有人可问。读这个数时要知道它靠的是约定。
        SELECT default_metal_index INTO v_default_index FROM pricing_settings WHERE id;
        SELECT jsonb_build_object(
            'price_index', v_default_index,
            'price_basis', 'spot',
            'average_days', NULL,
            'treatment_charge_usd_per_tonne', 0,
            'flat_discount_pct', 0,
            'payables', COALESCE(jsonb_object_agg(m.metal, 100), '{}'::jsonb))
        INTO v_terms
        FROM output_batch_metals m WHERE m.output_batch_id = p_output_batch_id;
    END IF;

    v_result := calculate_metal_price_from_terms(v_terms, v_metals, p_quantity, p_reference_date);

    -- 报价路径:缺行情即拒(quoting 侧的处置 —— 一份按零价卖出去的报价比停一下更坏;
    -- 分摊侧的"跳过继续"在 allocate_processing_costs,两边注释互指,不要统一)
    SELECT COALESCE(array_agg(x), ARRAY[]::text[]) INTO v_skipped
    FROM jsonb_array_elements_text(COALESCE(v_result->'skipped_metals', '[]'::jsonb)) x;
    IF array_length(v_skipped, 1) > 0 THEN
        -- METAL-2:点名【哪个指数】。两个序列之后,"没有行情"最常见的真相是
        -- "这个金属在【那个】指数上没有行情"—— 另一个指数上很可能正躺着一条好数字,
        -- 而按零计价把它算成不值钱。消息里不写指数,人就会去翻错的那张表。
        RAISE EXCEPTION 'METAL_PRICE_MISSING|%|%|%', array_to_string(v_skipped, ','),
            p_reference_date, COALESCE(v_terms->>'price_index', '(未声明指数)');
    END IF;

    v_usd_price := (v_result->>'unit_price_usd_per_kg')::numeric;

    -- ── USD → 单据币种:与买路径同一扇门(fx_rate_asof),【边】不同 ————————————
    SELECT a.rate, a.as_of INTO v_usd FROM fx_rate_asof('USD', p_reference_date, v_side) a;
    IF v_usd.rate IS NULL THEN
        RAISE EXCEPTION 'FX_RATE_MISSING|USD|%|%', p_reference_date, v_side;
    END IF;
    SELECT a.rate, a.as_of INTO v_doc FROM fx_rate_asof(p_currency, p_reference_date, v_side) a;
    IF v_doc.rate IS NULL THEN
        RAISE EXCEPTION 'FX_RATE_MISSING|%|%|%', p_currency, p_reference_date, v_side;
    END IF;
    v_factor := v_usd.rate / v_doc.rate;
    v_unit_ccy := round(v_usd_price * v_factor, 4);

    RETURN jsonb_build_object(
        'unit_price_ccy', v_unit_ccy,
        'currency', p_currency,
        'quantity_kg', p_quantity,
        'breakdown', v_result,
        -- 出处:足以重导出这个数(FIN-26 的标准:重导不出的出处只是标签)。
        -- price_series 恒为 'metal_prices':每金属只有一条序列,不冒称 LME/SMM。
        'provenance', jsonb_build_object(
            'mode', v_mode,
            'formula_id', CASE WHEN p_formula_id IS NOT NULL THEN p_formula_id::text END,
            'formula_code', v_formula_code,
            'terms', v_terms,
            'metals', v_metals,
            'metal_lines', v_result->'lines',
            'price_series', 'metal_prices',
            'quantity_kg', p_quantity,
            'reference_date', p_reference_date,
            'unit_price_usd_per_kg', v_usd_price,
            'fx', jsonb_build_object(
                'side', v_side,
                'usd_rate', v_usd.rate, 'usd_as_of', v_usd.as_of,
                'doc_rate', v_doc.rate, 'doc_as_of', v_doc.as_of,
                'factor', v_factor)
        )
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.allocate_processing_costs(p_run_id uuid, p_basis text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
-- Cost allocation. Metals with a usable price (deleted_at IS NULL, price_date <= run
-- process_date) contribute to metal value; metals WITHOUT one contribute 0 and are
-- recorded in allocation_snapshot.skipped_metals (the former missing-price hard error is gone).
-- NO_METAL_VALUE still blocks when the total metal value across all legs is 0.
-- (Phase 1 follow-up 1, 2026-07-03.)
-- cut 2a (2026-07-06): 10a 资本化分录(借 1220 / 贷 1200 材料 + 贷 5xxx 费用;
-- 重分摊 = 冲旧 + 重挂);10b 给无 COGS 的既有销售按原 sale_date 补挂 COGS。
DECLARE
    v_user                 uuid := auth.uid();
    v_run                  processing_runs%ROWTYPE;
    v_basis                text;
    v_process_date         date;
    v_material             numeric;
    v_process              numeric;
    v_total                numeric;
    v_inputs_without_price integer;
    v_total_basis          numeric;
    v_total_metal_value    numeric;
    v_bad_code             text;
    v_bad_metal            text;
    v_prices_used          jsonb;
    v_default_index        text;
    v_skipped_metals       jsonb;
    v_outputs              jsonb;
    v_sum_alloc            numeric;
    v_snapshot             jsonb;
    v_ct                   record;
    v_sale                 record;
    v_cap_lines            jsonb;
    v_cap_total            numeric;
    v_cap_je               jsonb;
    v_cap_entry_id         uuid;
    v_cogs                 numeric;
    v_cogs_je              jsonb;
    -- FIN-24:差额法用
    v_prior                jsonb;      -- 分摊前各产出腿的 allocated(差额的"已记录"侧)
    v_rec_src              jsonb;      -- 已记录的各来源(material / 各 cost_type)
    v_rec_total            numeric;
    v_by_source            jsonb;      -- 本次各来源(写进 snapshot,下次的"已记录")
    v_delta                numeric;
    v_leg                  record;
    v_d1220                numeric := 0;
    v_d5000                numeric := 0;
    v_d5200                numeric := 0;
    v_l1220                numeric;
    v_l5000                numeric;
    v_other                numeric;
    v_cred_total           numeric := 0;
    v_deb_total            numeric;
    v_cap_status           text;
    -- FIN-25:再加工
    v_material_in          numeric;   -- 进料批投料(→ 1200)
    v_material_re          numeric;   -- 产出批投料(→ 1220 解除上游)
    v_upstream_incomplete  boolean;
    v_re_without_price     integer;
BEGIN
    PERFORM require_permission('module.processing.edit');
    -- 1. Lock the run; must exist and be a live committed run.
    SELECT * INTO v_run FROM processing_runs WHERE id = p_run_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'RUN_NOT_FOUND|%', p_run_id;
    END IF;
    IF v_run.deleted_at IS NOT NULL OR v_run.status <> 'committed' THEN
        RAISE EXCEPTION 'RUN_NOT_COMMITTED|%', v_run.status;
    END IF;

    -- 2. Resolve + validate basis.
    v_basis := COALESCE(p_basis, v_run.allocation_basis);
    IF v_basis NOT IN ('weight','metal_value') THEN
        RAISE EXCEPTION 'INVALID_BASIS|%', v_basis;
    END IF;
    v_process_date := v_run.process_date;

    -- 3. Unit guard: all math assumes kg.
    SELECT ib.code INTO v_bad_code
    FROM processing_inputs pi
    JOIN inbound_batches ib ON ib.id = pi.inbound_batch_id
    WHERE pi.run_id = p_run_id AND ib.unit <> 'kg'
    LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'UNIT_NOT_KG|%', v_bad_code;
    END IF;

    SELECT ob.code INTO v_bad_code
    FROM processing_outputs po
    JOIN output_batches ob ON ob.id = po.output_batch_id
    WHERE po.run_id = p_run_id AND ob.unit <> 'kg'
    LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'UNIT_NOT_KG|%', v_bad_code;
    END IF;

    -- 4. Material cost(FIN-25 起两路):进料批按 inbound.unit_price;产出批
    --    (再加工)按上游 processing_outputs.unit_cost_base。NULL 价照旧计 0 并
    --    计数 —— 【允许,不拒绝】:车间按天走,财务分摊按月走,拒绝会让车间等
    --    财务。零不静默:cost_incomplete 标记打在本单产出上,逐级传染(见 9c),
    --    上游补分摊后本单过期,重跑即修复。
    SELECT COALESCE(SUM(pi.quantity_consumed * COALESCE(ib.unit_price, 0)), 0),
           COUNT(*) FILTER (WHERE ib.unit_price IS NULL)
      INTO v_material_in, v_inputs_without_price
    FROM processing_inputs pi
    JOIN inbound_batches ib ON ib.id = pi.inbound_batch_id
    WHERE pi.run_id = p_run_id;

    SELECT COALESCE(SUM(pi.quantity_consumed * COALESCE(po_up.unit_cost_base, 0)), 0),
           COUNT(*) FILTER (WHERE po_up.unit_cost_base IS NULL),
           COALESCE(bool_or(po_up.unit_cost_base IS NULL OR po_up.cost_incomplete), false)
      INTO v_material_re, v_re_without_price, v_upstream_incomplete
    FROM processing_inputs pi
    JOIN processing_outputs po_up ON po_up.output_batch_id = pi.output_batch_id
    WHERE pi.run_id = p_run_id;
    v_inputs_without_price := v_inputs_without_price + COALESCE(v_re_without_price, 0);
    v_material := v_material_in + v_material_re;

    -- 5. Process cost = Σ live cost entries.
    SELECT COALESCE(SUM(amount_base), 0) INTO v_process
    FROM processing_cost_entries
    WHERE run_id = p_run_id AND deleted_at IS NULL;

    -- 6. Total.
    v_total := v_material + v_process;

    -- 7. Basis totals. Metals without a usable price contribute 0 (LEFT JOIN + COALESCE)
    --    and are recorded in skipped_metals; only a zero grand total blocks (NO_METAL_VALUE).
    IF v_basis = 'metal_value' THEN
        -- METAL-2:分摊【没有交易可以继承指数】—— 一张加工单不是一笔谈定的买卖,
        -- 没有对手方、没有条款,所以它按 pricing_settings 的房屋约定取价。
        -- 【这是默认值在替一条缺席的条款站位,不是"这批成本按某个声明的指数结算了"】。
        -- 快照里一并记下用的是哪个指数,免得日后有人把它读成一条谈定的条款。
        SELECT default_metal_index INTO v_default_index FROM pricing_settings WHERE id;

        SELECT COALESCE(SUM(
                 po.quantity_produced * obm.content_pct / 100.0 / 1000.0 * COALESCE(pr.price_usd_per_tonne, 0)
               ), 0)
          INTO v_total_metal_value
        FROM processing_outputs po
        JOIN output_batch_metals obm ON obm.output_batch_id = po.output_batch_id
        LEFT JOIN LATERAL (
            SELECT mp.price_usd_per_tonne
            FROM metal_prices mp
            WHERE mp.metal = obm.metal AND mp.deleted_at IS NULL
              AND mp.price_index IS NOT DISTINCT FROM v_default_index   -- METAL-2
              AND mp.price_date <= v_process_date
            ORDER BY mp.price_date DESC
            LIMIT 1
        ) pr ON true
        WHERE po.run_id = p_run_id;

        IF COALESCE(v_total_metal_value, 0) = 0 THEN
            RAISE EXCEPTION 'NO_METAL_VALUE';
        END IF;

        v_total_basis := v_total_metal_value;

        SELECT COALESCE(jsonb_agg(
                   jsonb_build_object('metal', metal,
                                      'price_usd_per_tonne', price_usd_per_tonne,
                                      'price_date', price_date)
                   ORDER BY metal), '[]'::jsonb)
          INTO v_prices_used
        FROM (
            SELECT DISTINCT ON (mp.metal) mp.metal, mp.price_usd_per_tonne, mp.price_date
            FROM metal_prices mp
            WHERE mp.deleted_at IS NULL AND mp.price_date <= v_process_date
              AND mp.price_index IS NOT DISTINCT FROM v_default_index   -- METAL-2
              AND mp.metal IN (
                  SELECT DISTINCT obm.metal
                  FROM processing_outputs po
                  JOIN output_batch_metals obm ON obm.output_batch_id = po.output_batch_id
                  WHERE po.run_id = p_run_id AND obm.content_pct > 0
              )
            ORDER BY mp.metal, mp.price_date DESC
        ) q;

        -- Metals present (content > 0) on this run with NO usable price row: excluded from
        -- value (they contributed 0 above) and reported in the snapshot as skipped.
        SELECT COALESCE(jsonb_agg(m ORDER BY m), '[]'::jsonb)
          INTO v_skipped_metals
        FROM (
            SELECT DISTINCT obm.metal AS m
            FROM processing_outputs po
            JOIN output_batch_metals obm ON obm.output_batch_id = po.output_batch_id
            WHERE po.run_id = p_run_id AND obm.content_pct > 0
              AND NOT EXISTS (
                  SELECT 1 FROM metal_prices mp
                  WHERE mp.metal = obm.metal AND mp.deleted_at IS NULL
                    AND mp.price_date <= v_process_date
              )
        ) s;
    ELSE
        SELECT COALESCE(SUM(quantity_produced), 0) INTO v_total_basis
        FROM processing_outputs WHERE run_id = p_run_id;
        v_total_metal_value := NULL;
        v_prices_used := '[]'::jsonb;
        v_skipped_metals := '[]'::jsonb;
    END IF;

    -- FIN-24:差额法的"已记录"侧 —— 在下面的 UPDATE 改写之前,把各产出腿
    -- 当前的 allocated 拍下来。目标 − 已记录 = 应过账的差额(与重估/折旧同形)。
    SELECT COALESCE(jsonb_object_agg(po.output_batch_id::text,
                    COALESCE(po.allocated_cost_base, 0)), '{}'::jsonb)
      INTO v_prior
    FROM processing_outputs po WHERE po.run_id = p_run_id;

    -- 8 + 9. Allocate (largest-share row absorbs the rounding remainder), persist legs,
    --        and collect the per-output result — all in one statement.
    WITH legs AS (
        SELECT po.id AS leg_id, po.output_batch_id, po.quantity_produced,
               CASE WHEN v_basis = 'weight' THEN po.quantity_produced::numeric
                    ELSE COALESCE((
                        SELECT SUM(po.quantity_produced * obm.content_pct / 100.0 / 1000.0 * COALESCE(pr.price_usd_per_tonne, 0))
                        FROM output_batch_metals obm
                        LEFT JOIN LATERAL (
                            SELECT mp.price_usd_per_tonne
                            FROM metal_prices mp
                            WHERE mp.metal = obm.metal AND mp.deleted_at IS NULL
                              AND mp.price_date <= v_process_date
                            ORDER BY mp.price_date DESC
                            LIMIT 1
                        ) pr ON true
                        WHERE obm.output_batch_id = po.output_batch_id
                    ), 0)
               END AS basis_value
        FROM processing_outputs po
        WHERE po.run_id = p_run_id
    ),
    calc AS (
        SELECT leg_id, output_batch_id, quantity_produced, basis_value,
               round(v_total * basis_value / NULLIF(v_total_basis, 0), 2) AS alloc_raw,
               row_number() OVER (ORDER BY basis_value DESC, leg_id) AS rn
        FROM legs
    ),
    adj AS (
        SELECT c.*, (round(v_total, 2) - SUM(alloc_raw) OVER ()) AS remainder
        FROM calc c
    ),
    final AS (
        SELECT leg_id, output_batch_id, quantity_produced, basis_value,
               alloc_raw + CASE WHEN rn = 1 THEN remainder ELSE 0 END AS allocated
        FROM adj
    ),
    upd AS (
        UPDATE processing_outputs po
        SET allocated_cost_base = f.allocated,
            unit_cost_base = round(f.allocated / f.quantity_produced, 4)
        FROM final f
        WHERE po.id = f.leg_id
        RETURNING f.output_batch_id, f.basis_value, f.allocated, po.unit_cost_base
    )
    SELECT jsonb_agg(
               jsonb_build_object(
                   'output_batch_id', output_batch_id,
                   'share', round(basis_value / NULLIF(v_total_basis, 0), 6),
                   'allocated_cost_base', allocated,
                   'unit_cost_base', unit_cost_base)
               ORDER BY output_batch_id),
           COALESCE(SUM(allocated), 0)
      INTO v_outputs, v_sum_alloc
    FROM upd;

    -- 9b. Snapshot + run header.
    -- FIN-24:by_source = 本次各来源的入账口径(材料 + 逐 cost_type,各 2 位),
    -- 下一次差额跑的"已记录"就从这里读 —— recorded,不再从分录反推。
    v_by_source := jsonb_build_object('material', round(v_material_in, 2));
    IF round(v_material_re, 2) <> 0 THEN
        -- 再加工材料单列一源:首挂贷 1220(解除上游产出),差额与 material 同贷 5000
        v_by_source := v_by_source || jsonb_build_object('material_reprocessed', round(v_material_re, 2));
    END IF;
    FOR v_ct IN
        SELECT cost_type, round(sum(amount_base), 2) AS amt
        FROM processing_cost_entries
        WHERE run_id = p_run_id AND deleted_at IS NULL
        GROUP BY cost_type
    LOOP
        v_by_source := v_by_source || jsonb_build_object(v_ct.cost_type, v_ct.amt);
    END LOOP;

    v_snapshot := jsonb_build_object(
        'capitalized_by_source', v_by_source,
        'basis', v_basis,
        'computed_at', now(),
        'inputs_without_price', v_inputs_without_price,
        'total_output_metal_value_usd',
            CASE WHEN v_basis = 'metal_value' THEN round(v_total_metal_value, 2) ELSE NULL END,
        'prices_used', v_prices_used,
        -- METAL-2:用的是哪个指数,以及它【是房屋约定而不是条款】。
        -- 读快照的人必须能分清这两件事:这批成本不是"按 LME 结算"的,
        -- 它是"在没有条款可循时,按当时的房屋约定取了 LME 的价"。
        'price_index', v_default_index,
        'price_index_is_house_default', true,
        'skipped_metals', v_skipped_metals
    );

    -- 9c(FIN-25):不完整成本标记 —— 任何投料无价、或上游产出自己就带着标记,
    --    本单全部产出打上 cost_incomplete。零永不静默,层层传染;上游补分摊后
    --    本单过期(状态视图第三支),重跑即清。
    UPDATE processing_outputs
    SET cost_incomplete = (v_inputs_without_price > 0 OR v_upstream_incomplete)
    WHERE run_id = p_run_id;

    -- FIN-36c:告诉基准触发器"这次基准变动是【跟着重分摊一起发生的】,不是漂移"。
    -- 与年结用 evoltrya.close_ctx 穿过期间锁是同一个惯用法(post_journal_entry)。
    -- 【为什么不靠时间戳判断】now() 是事务时间:同一个事务里两次分摊拿到相同的
    -- allocated_at,任何"看 allocated_at 变没变"的判据都会失效(fixture 就在一个
    -- 事务里跑)。显式的上下文标记不受事务边界影响。
    PERFORM set_config('evoltrya.alloc_ctx', '1', true);

    UPDATE processing_runs
    SET material_cost_base   = round(v_material, 2),
        process_cost_base    = round(v_process, 2),
        total_cost_base      = round(v_total, 2),
        allocation_basis    = v_basis,
        allocation_snapshot = v_snapshot,
        allocated_at        = now(),
        allocated_by        = v_user,
        updated_at          = now(),
        updated_by          = v_user
    WHERE id = p_run_id;

    -- 标记只覆盖上面那一条 UPDATE:同一事务里【之后】的裸改基准仍算漂移
    PERFORM set_config('evoltrya.alloc_ctx', '', true);

    -- ════════════════════════════════════════════════════════════════════════
    -- 10a.【FIN-24:首挂全额,此后差额 —— 不再全额冲销重挂】
    -- 旧实现重述资本化(1220 按新价整体改写)而已过账 COGS 从不重述:卖掉份额的
    -- 价差留在库存里,卖得越多错得越多;材料价差贷 1200,而 reprice 早把已耗份额
    -- 记进了 5000 —— 两处叠加 = 重复计数 + 1200 变负(实测:100kg@1 全耗、重定价
    -- 到 2、重分摊 → 1220=200 但 5000 多挂 100、1200=−100)。
    -- 差额法(与重估/折旧同形):目标 − 已记录,只过差额,第二次跑为零。
    --   * 每个产出批按【自己】的处置比例拆(Part B:一炉多批、各卖各的):
    --       在库 + 已售未挂COGS → 1220(后者价值仍躺在 1220,10b 随后按新单位成本解除)
    --       已售已挂COGS       → 5000(COGS 补差)
    --       注销/盘亏           → 5200(处置在产出粒度可知,注销总额是运营信号,
    --                              不并进材料成本 —— Tim 的裁定,推翻了与 reprice
    --                              一致性的论证;reprice 在进料粒度分不出注销与
    --                              耗用、整体进 5000 的不精确,另记 known-issues)
    --   * 贷方:材料差额 → 5000(reprice 把已耗价差停在那里;5000 同时是 COGS
    --     科目,已售份额的借方与之同户恰好互抵 —— 这一巧合是本设计的支点);
    --     费用差额 → 各自成本科目(fin_cost_account)。
    --   * 产出批喂回再加工在 schema 上【不可表示】(processing_inputs 只指
    --     inbound_batches)—— 处置只有在库/已售/注销三种。粉线大概率多段加工,
    --     真建了再加工必须先扩这套拆分(known-issues 有账)。
    -- ════════════════════════════════════════════════════════════════════════
    v_rec_total := COALESCE(v_run.capitalized_cost_base, 0);
    IF v_run.capitalization_entry_id IS NOT NULL THEN
        SELECT status INTO v_cap_status FROM journal_entries WHERE id = v_run.capitalization_entry_id;
        IF v_cap_status <> 'posted' THEN
            -- 资本化分录被人工冲销:存量"已记录"与总账已分道,差额法的基准不再可信。
            -- 这是【唯一】剩下的红色情形:人工冲销是人做的决定,修复也该是人工分录。
            RAISE EXCEPTION 'ALLOCATION_LEDGER_DIVERGED|%', v_run.code;
        END IF;
    END IF;

    IF v_run.capitalization_entry_id IS NULL THEN
        -- ── 首挂:全额资本化(原路径)────────────────────────────────────────
        v_cap_lines := '[]'::jsonb;
        v_cap_total := 0;
        IF round(v_material_in, 2) <> 0 THEN
            v_cap_lines := v_cap_lines || jsonb_build_object('account_code', '1200', 'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', round(v_material_in, 2));
            v_cap_total := v_cap_total + round(v_material_in, 2);
        END IF;
        -- FIN-25:再加工材料 —— 解除的是上游产出的 1220,不是原料的 1200。
        -- 同科目 Dr(资本化进本单产出)/Cr(解除上游)两腿并存,净额即增量。
        IF round(v_material_re, 2) <> 0 THEN
            v_cap_lines := v_cap_lines || jsonb_build_object('account_code', '1220', 'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', round(v_material_re, 2), 'line_memo', 're-processed input relieved');
            v_cap_total := v_cap_total + round(v_material_re, 2);
        END IF;
        FOR v_ct IN
            SELECT cost_type, round(sum(amount_base), 2) AS amt
            FROM processing_cost_entries
            WHERE run_id = p_run_id AND deleted_at IS NULL
            GROUP BY cost_type
            ORDER BY cost_type
        LOOP
            IF v_ct.amt > 0 THEN
                v_cap_lines := v_cap_lines || jsonb_build_object('account_code', fin_cost_account(v_ct.cost_type), 'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', v_ct.amt);
                v_cap_total := v_cap_total + v_ct.amt;
            ELSIF v_ct.amt < 0 THEN
                v_cap_lines := v_cap_lines || jsonb_build_object('account_code', fin_cost_account(v_ct.cost_type), 'side', 'debit', 'currency', base_currency_code(), 'amount_ccy', -v_ct.amt);
                v_cap_total := v_cap_total + v_ct.amt;
            END IF;
        END LOOP;

        v_cap_entry_id := NULL;
        IF v_cap_total <> 0 THEN
            v_cap_lines := jsonb_build_array(
                jsonb_build_object('account_code', '1220',
                                   'side', CASE WHEN v_cap_total > 0 THEN 'debit' ELSE 'credit' END,
                                   'currency', base_currency_code(), 'amount_ccy', abs(v_cap_total))
            ) || v_cap_lines;
            v_cap_je := post_journal_entry(
                CURRENT_DATE,
                'Capitalize ' || v_run.code,
                'allocation', p_run_id,
                v_cap_lines);
            v_cap_entry_id := (v_cap_je->>'entry_id')::uuid;
        END IF;

        UPDATE processing_runs
        SET capitalized_cost_base = v_cap_total,
            capitalization_entry_id = v_cap_entry_id
        WHERE id = p_run_id;
    ELSE
        -- ── 差额路径 ─────────────────────────────────────────────────────────
        -- 已记录的各来源:优先 snapshot(FIN-24 起写入);老单从已过账的资本化
        -- 分录行反推 —— 1200 行 = 材料,5xxx 行按 fin_cost_account 的反向映射。
        v_rec_src := v_run.allocation_snapshot->'capitalized_by_source';
        IF v_rec_src IS NULL THEN
            SELECT COALESCE(jsonb_object_agg(q.src, q.amt), '{}'::jsonb) INTO v_rec_src FROM (
                SELECT CASE a.code
                           WHEN '1200' THEN 'material'
                           WHEN '5100' THEN 'labour'
                           WHEN '5110' THEN 'electricity'
                           WHEN '5120' THEN 'gas'
                           WHEN '5130' THEN 'depreciation'
                           WHEN '5140' THEN 'consumables'
                           WHEN '5150' THEN 'waste_treatment'
                           WHEN '5190' THEN 'other'
                       END AS src,
                       round(SUM(jl.credit) - SUM(jl.debit), 2) AS amt
                FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id
                WHERE jl.entry_id = v_run.capitalization_entry_id AND a.code <> '1220'
                GROUP BY a.code) q
            WHERE q.src IS NOT NULL;
        END IF;

        -- 贷方:逐来源差额。材料 → 5000(不是 1200!—— reprice 已把已耗价差记在
        -- 5000,这里把属于未售产出的部分从 5000 拨进 1220,双方不再叠加);
        -- 费用 → 各自成本科目。负差翻借方。
        v_cap_lines := '[]'::jsonb;
        v_cred_total := 0;
        FOR v_ct IN
            SELECT key AS src, (v_by_source->>key)::numeric - COALESCE((v_rec_src->>key)::numeric, 0) AS d
            FROM jsonb_object_keys(v_by_source) AS key
            UNION
            SELECT key, 0 - (v_rec_src->>key)::numeric
            FROM jsonb_object_keys(v_rec_src) AS key
            WHERE v_by_source->>key IS NULL
            ORDER BY 1
        LOOP
            IF v_ct.d <> 0 THEN
                v_cap_lines := v_cap_lines || jsonb_build_object(
                    'account_code', CASE WHEN v_ct.src IN ('material', 'material_reprocessed') THEN '5000' ELSE fin_cost_account(v_ct.src) END,
                    'side', CASE WHEN v_ct.d > 0 THEN 'credit' ELSE 'debit' END,
                    'currency', base_currency_code(), 'amount_ccy', abs(v_ct.d),
                    'line_memo', 'allocation delta: ' || v_ct.src);
                v_cred_total := v_cred_total + v_ct.d;
            END IF;
        END LOOP;

        -- 借方:逐产出批的差额,按该批自己的处置比例拆
        FOR v_leg IN
            SELECT po.output_batch_id, po.quantity_produced AS qty,
                   po.allocated_cost_base AS new_alloc,
                   COALESCE((v_prior->>po.output_batch_id::text)::numeric, 0) AS old_alloc,
                   ob.remaining_qty,
                   COALESCE((SELECT SUM(sr.quantity) FROM sales_records sr
                             WHERE sr.output_batch_id = po.output_batch_id
                               AND sr.cogs_entry_id IS NOT NULL), 0) AS sold_cogs,
                   COALESCE((SELECT SUM(sr.quantity) FROM sales_records sr
                             WHERE sr.output_batch_id = po.output_batch_id
                               AND sr.cogs_entry_id IS NULL), 0) AS sold_nocogs,
                   -- FIN-25 第四处置:被下游加工消耗的份额 → 5000 停车
                   --(与 reprice 对已耗进料完全同构:下游过期后重跑,其材料差额
                   -- 贷 5000 收回停车 —— 传导靠既有过期旗逐级走,不递归)
                   COALESCE((SELECT SUM(pi2.quantity_consumed) FROM processing_inputs pi2
                             WHERE pi2.output_batch_id = po.output_batch_id), 0) AS consumed_proc
            FROM processing_outputs po
            JOIN output_batches ob ON ob.id = po.output_batch_id
            WHERE po.run_id = p_run_id
        LOOP
            v_delta := round(v_leg.new_alloc - v_leg.old_alloc, 2);
            IF v_delta = 0 OR v_leg.qty = 0 THEN CONTINUE; END IF;
            v_other := GREATEST(0, v_leg.qty - v_leg.remaining_qty - v_leg.sold_cogs - v_leg.sold_nocogs - v_leg.consumed_proc);
            v_l1220 := round(v_delta * (v_leg.remaining_qty + v_leg.sold_nocogs) / v_leg.qty, 2);
            v_l5000 := round(v_delta * (v_leg.sold_cogs + v_leg.consumed_proc) / v_leg.qty, 2);
            -- 5200 取残差,保证三桶之和恰等于该批差额
            v_d1220 := v_d1220 + v_l1220;
            v_d5000 := v_d5000 + v_l5000;
            v_d5200 := v_d5200 + (v_delta - v_l1220 - v_l5000);
        END LOOP;

        -- 强制配平:Σ借(三桶)与 Σ贷(逐来源)各自取整后可差一两分 ——
        -- 差额并进 1220 桶(金额最大、且是"目标状态"侧,与 8+9 步的
        -- largest-share-absorbs 同一习惯)。
        v_deb_total := v_d1220 + v_d5000 + v_d5200;
        v_d1220 := v_d1220 + round(v_cred_total - v_deb_total, 2);

        IF v_d1220 <> 0 THEN
            v_cap_lines := jsonb_build_array(jsonb_build_object('account_code', '1220',
                'side', CASE WHEN v_d1220 > 0 THEN 'debit' ELSE 'credit' END,
                'currency', base_currency_code(), 'amount_ccy', abs(v_d1220),
                'line_memo', 'in-stock share')) || v_cap_lines;
        END IF;
        IF v_d5000 <> 0 THEN
            v_cap_lines := jsonb_build_array(jsonb_build_object('account_code', '5000',
                'side', CASE WHEN v_d5000 > 0 THEN 'debit' ELSE 'credit' END,
                'currency', base_currency_code(), 'amount_ccy', abs(v_d5000),
                'line_memo', 'sold/consumed share — COGS catch-up / re-processing park')) || v_cap_lines;
        END IF;
        IF v_d5200 <> 0 THEN
            v_cap_lines := jsonb_build_array(jsonb_build_object('account_code', '5200',
                'side', CASE WHEN v_d5200 > 0 THEN 'debit' ELSE 'credit' END,
                'currency', base_currency_code(), 'amount_ccy', abs(v_d5200),
                'line_memo', 'written-off share')) || v_cap_lines;
        END IF;

        -- 幂等出口:没有任何差额 → 不过账(allocated_at 照常刷新,过期标记消除)
        IF jsonb_array_length(v_cap_lines) > 0 THEN
            v_cap_je := post_journal_entry(
                CURRENT_DATE,
                'Re-allocation delta ' || v_run.code,
                'allocation', p_run_id,
                v_cap_lines);
            -- 差额分录记进 snapshot 的留痕数组;capitalization_entry_id 仍指首挂
            v_snapshot := v_snapshot || jsonb_build_object('delta_entry_ids',
                COALESCE(v_run.allocation_snapshot->'delta_entry_ids', '[]'::jsonb)
                    || to_jsonb((v_cap_je->>'entry_id')::text));
            UPDATE processing_runs SET allocation_snapshot = v_snapshot WHERE id = p_run_id;
        END IF;

        UPDATE processing_runs
        SET capitalized_cost_base = round(v_rec_total + v_cred_total, 2)
        WHERE id = p_run_id;
    END IF;

    -- 10b. cut 2a:COGS 补挂 —— 只补此前无 COGS 分录的销售(cogs_entry_id IS NULL),
    --      用最新 unit_cost_base,按各自原 sale_date(撞期间锁则 PERIOD_LOCKED 直接抛出)。
    --      已挂 COGS 不追溯重述(标准成本式简化;重述属人工冲销决策)。
    FOR v_sale IN
        SELECT sr.id, sr.quantity, sr.sale_date, ob.code AS batch_code, po.unit_cost_base
        FROM sales_records sr
        JOIN processing_outputs po ON po.output_batch_id = sr.output_batch_id AND po.run_id = p_run_id
        JOIN output_batches ob ON ob.id = sr.output_batch_id
        WHERE sr.cogs_entry_id IS NULL
        ORDER BY sr.sale_date, sr.created_at
    LOOP
        v_cogs := round(v_sale.quantity * v_sale.unit_cost_base, 2);
        IF v_cogs <> 0 THEN
            v_cogs_je := post_journal_entry(
                v_sale.sale_date,
                'COGS ' || v_sale.batch_code,
                'sale', v_sale.id,
                jsonb_build_array(
                    jsonb_build_object('account_code', '5000', 'side', 'debit',  'currency', base_currency_code(), 'amount_ccy', v_cogs),
                    jsonb_build_object('account_code', '1220', 'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', v_cogs)));
            UPDATE sales_records SET cogs_entry_id = (v_cogs_je->>'entry_id')::uuid WHERE id = v_sale.id;
        END IF;
    END LOOP;

    -- 10. Return.
    RETURN jsonb_build_object(
        'run_id', p_run_id,
        'basis', v_basis,
        'material_cost_base', round(v_material, 2),
        'process_cost_base', round(v_process, 2),
        'total_cost_base', round(v_total, 2),
        'inputs_without_price', v_inputs_without_price,
        'outputs', COALESCE(v_outputs, '[]'::jsonb)
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.upsert_metal_prices(p_price_date date, p_prices jsonb, p_price_index text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user     uuid := auth.uid();
    v_el       jsonb;
    v_metal    text;
    v_raw      text;
    v_price    numeric;
    v_inserted integer := 0;
    v_updated  integer := 0;
    v_skipped  integer := 0;
    v_was_ins  boolean;
BEGIN
    PERFORM require_permission('module.pricing.edit');
    -- METAL-2:录入的是【哪个指数】的行情。NULL = 未声明(老序列),它是一个
    -- 可表示的状态而不是默认值 —— 界面上是一个必须选的下拉,而不是留空就当某个值。
    IF p_price_index IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM metal_price_indices WHERE code = p_price_index AND is_active) THEN
        RAISE EXCEPTION 'PRICE_INDEX_UNKNOWN|%', p_price_index;
    END IF;
    IF p_price_date IS NULL THEN
        RAISE EXCEPTION 'PRICE_DATE_REQUIRED';
    END IF;
    IF p_prices IS NULL OR jsonb_typeof(p_prices) <> 'array' THEN
        RAISE EXCEPTION 'NO_PRICES';
    END IF;

    FOR v_el IN SELECT * FROM jsonb_array_elements(p_prices)
    LOOP
        v_metal := v_el->>'metal';
        IF v_metal IS NULL OR v_metal NOT IN ('ni','co','li','mn','cu','al','fe') THEN
            RAISE EXCEPTION 'METAL_INVALID|%', COALESCE(v_metal, '?');
        END IF;

        -- 空值跳过而不是报错:UI 的每日录入表单常常只填了其中几个金属。
        v_raw := v_el->>'price_usd_per_tonne';
        IF v_raw IS NULL OR btrim(v_raw) = '' THEN
            v_skipped := v_skipped + 1;
            CONTINUE;
        END IF;

        v_price := v_raw::numeric;
        IF v_price IS NULL OR v_price <= 0 THEN
            RAISE EXCEPTION 'PRICE_INVALID|%|%', v_metal, v_raw;
        END IF;

        -- (metal, price_date) 唯一。软删的行也占着这个位置 —— 撞上就顺手复活它
        -- (deleted_at = NULL)并写入新价,这两种情形都算 updated。
        INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date, price_index, source, created_by, updated_by)
        VALUES (v_metal, v_price, p_price_date, p_price_index, 'manual', v_user, v_user)
        ON CONFLICT (metal, price_date, price_index) DO UPDATE
        SET price_usd_per_tonne = EXCLUDED.price_usd_per_tonne,
            source              = EXCLUDED.source,
            deleted_at          = NULL,
            updated_by          = v_user
        RETURNING (xmax = 0) INTO v_was_ins;

        IF v_was_ins THEN
            v_inserted := v_inserted + 1;
        ELSE
            v_updated := v_updated + 1;
        END IF;
    END LOOP;

    RETURN jsonb_build_object(
        'price_date', p_price_date,
        'price_index', p_price_index,
        'inserted', v_inserted,
        'updated', v_updated,
        'skipped', v_skipped
    );
END;
$function$;

COMMIT;
