-- FIN-27(2026-08-07):被交易引用的计价公式,不得在它脚下改变。
--
-- 【问题】pricing_formulas / pricing_formula_metals 是普通 UPDATE 改的(界面上就是
-- 一个表单,app/pricing/formulas/actions.ts 直接 PostgREST update),没有版本、没有
-- 守卫。而采购行上的 pricing_formula_id 是一份【关于将来怎么结算的承诺】:供应商
-- 已经按那套条款签了单,公式随后被改,库里没有任何东西记得当时它说的是什么。
-- 这是合同风险,不是不整洁。
--
-- 【方向】承诺时抄下条款,结算时读副本 —— 这个仓库已经答过两次同一道题:
--   * apply_payment_term_template 把模板行【抄】到 purchase_order_payment_terms,
--     不留回指,副本就是记录;
--   * FIN-26 把估算的依据冻结在行上,而不是回头去解析公式。
-- 给公式表加版本是更重的做法,而且买不到副本没给的任何东西。
--
-- 【本迁移做四件事】
--   B 副本:pricing_term_commitments(+_metals)—— 抄下逐金属可付比、计价基准与
--     窗口、处理费、折扣;承诺时刻 = 采购单创建(create_purchase_order 直接落
--     'confirmed',没有第二个确认动作可挂),或结算时才指名公式的现场收货批次。
--   C 结算读副本:apply_assay_result 与新的 reprice_from_committed_terms 一律走
--     pricing_terms_of_commitment;【没有副本就点名拒】(PRICING_TERMS_NOT_COMMITTED),
--     绝不悄悄退回去读活公式 —— 那正是本切要拆掉的行为。
--     计价算术只此一份:calculate_metal_price_from_terms(条款 → 价),
--     报价侧(calculate_metal_price_internal)喂它【活公式】的条款,
--     结算侧喂它【副本】的条款。同一份算术,两个调用方,两种条款来源。
--   D 存量引用保持"未知":不回填。把今天的公式抄到一张旧单上,记下的是它【现在】
--     说的话,未必是当时谈的 —— 编造的承诺比缺失的承诺更坏(同 FIN-26 的灰色
--     "出处未知"、processing_cost_entry_history 的空白前史)。
--   E 模板仍可改,但不再无声:pricing_formula_history —— 谁、什么时候、从什么改到
--     什么(employment_history 的形状)。副本落下之后,改公式对既有交易【结构上】
--     无害,所以不需要不可变守卫;但它仍然改变此后每一次报价算出来的数。
--     金属子表【同样需要】:可付比是结算数字上最大的一根杠杆,而界面表达"这个金属
--     不再计价"的方式是【删掉那一行】—— 只记表头的历史对最激烈的一种编辑一言不发,
--     而沉默读起来正好等于"什么都没改"。
--
-- 应用:./db/apply_migration.sh db/migrations/2026-08-07-fin27-pricing-terms-commitment.sql

BEGIN;

-- ════════════════════════════════════════════════════════════════════════════
-- B. 承诺副本
-- ════════════════════════════════════════════════════════════════════════════

CREATE TABLE public.pricing_term_commitments (
    id                             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    -- 承诺挂在【被承诺的那条记录】上,二者其一(UNIQUE:一条记录只承诺一次)
    purchase_order_line_id         uuid UNIQUE REFERENCES public.purchase_order_lines (id),
    inbound_batch_id               uuid UNIQUE REFERENCES public.inbound_batches (id),
    -- 【抄下来的,不是指过去的】source_formula_id 【没有外键、永不 JOIN 回去】:
    -- 它记录副本抄自哪张模板,与 apply_payment_term_template 不留回指同一个意思。
    -- code/name 一并抄成文本 —— 公式改名或软删都不该动到已成交的这份记录。
    source_formula_id              uuid,
    source_formula_code            text NOT NULL,
    source_formula_name            text,
    -- 条款本体(与 pricing_formulas 同名同义,便于逐字对照)
    price_basis                    text NOT NULL
                                   CHECK (price_basis IN ('spot','average')),
    average_days                   integer CHECK (average_days IS NULL OR average_days BETWEEN 1 AND 365),
    treatment_charge_usd_per_tonne numeric NOT NULL
                                   CHECK (treatment_charge_usd_per_tonne >= 0),
    flat_discount_pct              numeric NOT NULL
                                   CHECK (flat_discount_pct >= 0 AND flat_discount_pct <= 100),
    committed_at                   timestamptz NOT NULL DEFAULT now(),
    committed_by                   uuid DEFAULT auth.uid(),
    CONSTRAINT pricing_term_commitments_one_target CHECK (
        num_nonnulls(purchase_order_line_id, inbound_batch_id) = 1
    ),
    CONSTRAINT pricing_term_commitments_average_days_required CHECK (
        price_basis <> 'average' OR average_days IS NOT NULL
    )
);

COMMENT ON TABLE public.pricing_term_commitments IS
    '承诺时抄下的结算条款(FIN-27)。副本就是记录 —— 结算只读它,从不读活公式。';
COMMENT ON COLUMN public.pricing_term_commitments.source_formula_id IS
    '抄自哪张公式。【记录,不是引用】:没有外键,任何代码路径都不许 JOIN 回 pricing_formulas 去取条款。';

CREATE TABLE public.pricing_term_commitment_metals (
    commitment_id uuid NOT NULL REFERENCES public.pricing_term_commitments (id),
    metal         text NOT NULL CHECK (metal IN ('ni','co','li','mn','cu','al','fe')),
    payable_pct   numeric NOT NULL CHECK (payable_pct >= 0 AND payable_pct <= 100),
    PRIMARY KEY (commitment_id, metal)
);

COMMENT ON TABLE public.pricing_term_commitment_metals IS
    '承诺副本的逐金属可付比(FIN-27)。不在本表里的金属 = 承诺时就不计价(payable 0),与 pricing_formula_metals 同义。';

-- 副本不可变:写错了不靠改历史,靠重新承诺(而"重新承诺"本身是一次商务动作,
-- 不能由一次 UPDATE 悄悄完成)。形状取自 employment_history。
CREATE OR REPLACE FUNCTION public.guard_pricing_commitment_immutable()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    RAISE EXCEPTION 'PRICING_COMMITMENT_IMMUTABLE';
END;
$fn$;

CREATE TRIGGER trg_pricing_term_commitments_immutable
    BEFORE UPDATE OR DELETE ON public.pricing_term_commitments
    FOR EACH ROW EXECUTE FUNCTION public.guard_pricing_commitment_immutable();

CREATE TRIGGER trg_pricing_term_commitment_metals_immutable
    BEFORE UPDATE OR DELETE ON public.pricing_term_commitment_metals
    FOR EACH ROW EXECUTE FUNCTION public.guard_pricing_commitment_immutable();

ALTER TABLE public.pricing_term_commitments ENABLE ROW LEVEL SECURITY;
CREATE POLICY "pricing_term_commitments select by permission"
    ON public.pricing_term_commitments
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.purchasing.view'::text)
        OR has_permission('module.inbound.view'::text));

ALTER TABLE public.pricing_term_commitment_metals ENABLE ROW LEVEL SECURITY;
CREATE POLICY "pricing_term_commitment_metals select by permission"
    ON public.pricing_term_commitment_metals
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.purchasing.view'::text)
        OR has_permission('module.inbound.view'::text));

-- 写入只经函数(DEFINER),所以没有 INSERT 策略 —— 承诺不是能手写的东西。

-- 字段级遮蔽(cut 2b 的规矩):处理费/折扣/可付比与 pricing_formulas 同口径,
-- 归 data.view_prices。表级 SELECT 授权蕴含所有列,故先整表收回再逐列授回;
-- 敏感列只经 _masked 视图读。【加列必改这一行】——列清单授权不会自动延伸。
REVOKE SELECT ON public.pricing_term_commitments FROM authenticated, anon;
GRANT SELECT (id, purchase_order_line_id, inbound_batch_id, source_formula_id,
              source_formula_code, source_formula_name, price_basis, average_days,
              committed_at, committed_by)
    ON public.pricing_term_commitments TO authenticated;

REVOKE SELECT ON public.pricing_term_commitment_metals FROM authenticated, anon;
GRANT SELECT (commitment_id, metal)
    ON public.pricing_term_commitment_metals TO authenticated;

CREATE VIEW public.pricing_term_commitments_masked WITH (security_invoker = off) AS
 SELECT id,
    purchase_order_line_id,
    inbound_batch_id,
    source_formula_id,
    source_formula_code,
    source_formula_name,
    price_basis,
    average_days,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN treatment_charge_usd_per_tonne
            ELSE NULL::numeric
        END AS treatment_charge_usd_per_tonne,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN flat_discount_pct
            ELSE NULL::numeric
        END AS flat_discount_pct,
    committed_at,
    committed_by
   FROM pricing_term_commitments
  WHERE has_permission('module.purchasing.view'::text)
     OR has_permission('module.inbound.view'::text);

CREATE VIEW public.pricing_term_commitment_metals_masked WITH (security_invoker = off) AS
 SELECT commitment_id,
    metal,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN payable_pct
            ELSE NULL::numeric
        END AS payable_pct
   FROM pricing_term_commitment_metals
  WHERE has_permission('module.purchasing.view'::text)
     OR has_permission('module.inbound.view'::text);

-- ════════════════════════════════════════════════════════════════════════════
-- E. 公式编辑史(只增不改)
-- ════════════════════════════════════════════════════════════════════════════

CREATE TABLE public.pricing_formula_history (
    id                                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    formula_id                         uuid NOT NULL REFERENCES public.pricing_formulas (id),
    change_type                        text NOT NULL CHECK (change_type IN
                                       ('create','update','delete','restore','metal_set','metal_clear')),
    metal                              text CHECK (metal IS NULL OR metal IN ('ni','co','li','mn','cu','al','fe')),
    old_payable_pct                    numeric,   -- RESTRICTED
    new_payable_pct                    numeric,   -- RESTRICTED
    old_name                           text,
    new_name                           text,
    old_direction                      text,
    new_direction                      text,
    old_price_basis                    text,
    new_price_basis                    text,
    old_average_days                   integer,
    new_average_days                   integer,
    old_treatment_charge_usd_per_tonne numeric,   -- RESTRICTED
    new_treatment_charge_usd_per_tonne numeric,   -- RESTRICTED
    old_flat_discount_pct              numeric,   -- RESTRICTED
    new_flat_discount_pct              numeric,   -- RESTRICTED
    old_is_active                      boolean,
    new_is_active                      boolean,
    changed_at                         timestamptz NOT NULL DEFAULT now(),
    changed_by                         uuid,
    CONSTRAINT pricing_formula_history_metal_shape CHECK (
        (change_type IN ('metal_set','metal_clear')) = (metal IS NOT NULL)
    )
);

CREATE INDEX idx_pricing_formula_history_formula
    ON public.pricing_formula_history (formula_id, changed_at DESC);

COMMENT ON TABLE public.pricing_formula_history IS
    '计价公式的只增不改编辑史(FIN-27,employment_history 的形状)。谁、什么时候、从什么改到什么。触发器写入 —— 编辑路径是普通 UPDATE,没有 RPC 可以挂,应用侧留痕会是可跳过的。触发器之前的编辑没有行:空白好过编造。';

CREATE OR REPLACE FUNCTION public.guard_pricing_formula_history_append_only()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    RAISE EXCEPTION 'HISTORY_APPEND_ONLY';
END;
$fn$;

CREATE TRIGGER trg_pricing_formula_history_append_only
    BEFORE UPDATE OR DELETE ON public.pricing_formula_history
    FOR EACH ROW EXECUTE FUNCTION public.guard_pricing_formula_history_append_only();

ALTER TABLE public.pricing_formula_history ENABLE ROW LEVEL SECURITY;
CREATE POLICY "pricing_formula_history select by permission"
    ON public.pricing_formula_history
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.pricing.view'::text));

-- 【加列必改这一行】列清单 SELECT 授权不会自动延伸到 ALTER 加的新列。
REVOKE SELECT ON public.pricing_formula_history FROM authenticated, anon;
GRANT SELECT (id, formula_id, change_type, metal, old_name, new_name,
              old_direction, new_direction, old_price_basis, new_price_basis,
              old_average_days, new_average_days, old_is_active, new_is_active,
              changed_at, changed_by)
    ON public.pricing_formula_history TO authenticated;

CREATE VIEW public.pricing_formula_history_masked WITH (security_invoker = off) AS
 SELECT id,
    formula_id,
    change_type,
    metal,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN old_payable_pct
            ELSE NULL::numeric
        END AS old_payable_pct,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN new_payable_pct
            ELSE NULL::numeric
        END AS new_payable_pct,
    old_name,
    new_name,
    old_direction,
    new_direction,
    old_price_basis,
    new_price_basis,
    old_average_days,
    new_average_days,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN old_treatment_charge_usd_per_tonne
            ELSE NULL::numeric
        END AS old_treatment_charge_usd_per_tonne,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN new_treatment_charge_usd_per_tonne
            ELSE NULL::numeric
        END AS new_treatment_charge_usd_per_tonne,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN old_flat_discount_pct
            ELSE NULL::numeric
        END AS old_flat_discount_pct,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN new_flat_discount_pct
            ELSE NULL::numeric
        END AS new_flat_discount_pct,
    old_is_active,
    new_is_active,
    changed_at,
    changed_by
   FROM pricing_formula_history
  WHERE has_permission('module.pricing.view'::text);

-- 表头的编辑
CREATE OR REPLACE FUNCTION public.log_pricing_formula_change()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp' AS $fn$
DECLARE
    v_type text;
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO pricing_formula_history (
            formula_id, change_type,
            new_name, new_direction, new_price_basis, new_average_days,
            new_treatment_charge_usd_per_tonne, new_flat_discount_pct, new_is_active,
            changed_by)
        VALUES (NEW.id, 'create',
            NEW.name, NEW.direction, NEW.price_basis, NEW.average_days,
            NEW.treatment_charge_usd_per_tonne, NEW.flat_discount_pct, NEW.is_active,
            auth.uid());
        RETURN NULL;
    END IF;

    IF OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL THEN
        v_type := 'delete';
    ELSIF OLD.deleted_at IS NOT NULL AND NEW.deleted_at IS NULL THEN
        v_type := 'restore';
    ELSIF (OLD.name, OLD.direction, OLD.price_basis, OLD.average_days,
           OLD.treatment_charge_usd_per_tonne, OLD.flat_discount_pct, OLD.is_active,
           OLD.supplier_id, OLD.customer_id, OLD.notes)
          IS DISTINCT FROM
          (NEW.name, NEW.direction, NEW.price_basis, NEW.average_days,
           NEW.treatment_charge_usd_per_tonne, NEW.flat_discount_pct, NEW.is_active,
           NEW.supplier_id, NEW.customer_id, NEW.notes) THEN
        v_type := 'update';
    ELSE
        -- 只碰了 updated_at/updated_by:不是一次编辑,不留行(否则历史会被噪音淹掉)
        RETURN NULL;
    END IF;

    INSERT INTO pricing_formula_history (
        formula_id, change_type,
        old_name, new_name, old_direction, new_direction,
        old_price_basis, new_price_basis, old_average_days, new_average_days,
        old_treatment_charge_usd_per_tonne, new_treatment_charge_usd_per_tonne,
        old_flat_discount_pct, new_flat_discount_pct,
        old_is_active, new_is_active, changed_by)
    VALUES (NEW.id, v_type,
        OLD.name, NEW.name, OLD.direction, NEW.direction,
        OLD.price_basis, NEW.price_basis, OLD.average_days, NEW.average_days,
        OLD.treatment_charge_usd_per_tonne, NEW.treatment_charge_usd_per_tonne,
        OLD.flat_discount_pct, NEW.flat_discount_pct,
        OLD.is_active, NEW.is_active, auth.uid());
    RETURN NULL;
END;
$fn$;

CREATE TRIGGER trg_pricing_formulas_history
    AFTER INSERT OR UPDATE ON public.pricing_formulas
    FOR EACH ROW EXECUTE FUNCTION public.log_pricing_formula_change();

-- 金属子表的编辑。【为什么它也要】界面表达"这个金属不再计价"的方式是 DELETE
-- 那一行(app/pricing/formulas/actions.ts 的 clears),而 pricing_formula_metals
-- 没有软删 —— 只记表头的历史对最激烈的一种编辑一言不发。
CREATE OR REPLACE FUNCTION public.log_pricing_formula_metal_change()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp' AS $fn$
BEGIN
    IF TG_OP = 'DELETE' THEN
        INSERT INTO pricing_formula_history (formula_id, change_type, metal,
                                             old_payable_pct, changed_by)
        VALUES (OLD.formula_id, 'metal_clear', OLD.metal, OLD.payable_pct, auth.uid());
        RETURN NULL;
    ELSIF TG_OP = 'INSERT' THEN
        INSERT INTO pricing_formula_history (formula_id, change_type, metal,
                                             new_payable_pct, changed_by)
        VALUES (NEW.formula_id, 'metal_set', NEW.metal, NEW.payable_pct, auth.uid());
        RETURN NULL;
    END IF;
    IF NEW.payable_pct IS NOT DISTINCT FROM OLD.payable_pct THEN
        RETURN NULL;
    END IF;
    INSERT INTO pricing_formula_history (formula_id, change_type, metal,
                                         old_payable_pct, new_payable_pct, changed_by)
    VALUES (NEW.formula_id, 'metal_set', NEW.metal, OLD.payable_pct, NEW.payable_pct, auth.uid());
    RETURN NULL;
END;
$fn$;

CREATE TRIGGER trg_pricing_formula_metals_history
    AFTER INSERT OR UPDATE OR DELETE ON public.pricing_formula_metals
    FOR EACH ROW EXECUTE FUNCTION public.log_pricing_formula_metal_change();

-- ════════════════════════════════════════════════════════════════════════════
-- 条款 → 价:【算术只此一份】,条款来源有两个
-- ════════════════════════════════════════════════════════════════════════════

-- 活公式的条款(报价侧:新报价当然用新条款)
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
        'price_basis', v_f.price_basis,
        'average_days', v_f.average_days,
        'treatment_charge_usd_per_tonne', v_f.treatment_charge_usd_per_tonne,
        'flat_discount_pct', v_f.flat_discount_pct,
        'payables', v_pay
    );
END;
$function$;

-- 承诺副本的条款(结算侧)。【没有 is_active / deleted_at 检查,这正是要点】——
-- 副本一旦落下,模板此后被停用或软删都碰不到它。
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
        'price_basis', v_c.price_basis,
        'average_days', v_c.average_days,
        'treatment_charge_usd_per_tonne', v_c.treatment_charge_usd_per_tonne,
        'flat_discount_pct', v_c.flat_discount_pct,
        'payables', v_pay
    );
END;
$function$;

-- 计价算术。原 calculate_metal_price_internal 的第 2 步起【原样搬过来】,
-- 只把"公式从哪来"换成一份显式条款 —— 于是报价与结算不可能各算各的
-- (reprice_split 之于 reprice / preview_reprice 的同一条关系)。
CREATE OR REPLACE FUNCTION public.calculate_metal_price_from_terms(p_terms jsonb, p_metals jsonb, p_quantity_kg numeric, p_reference_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_ref          date;
    v_basis        text;
    v_avg_days     integer;
    v_payables     jsonb;
    v_el           jsonb;
    v_metal        text;
    v_content      numeric;
    v_seen         text[] := ARRAY[]::text[];
    v_payable      numeric;
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
        IF v_payables ? v_metal THEN
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
            ORDER BY mp.price_date DESC
            LIMIT 1;
        ELSE
            -- price_from / price_to 报【实际参与均值的行】的日期范围,而不是名义窗口 ——
            -- 结算单据上要能看出这个均价到底由哪几天的行情撑起来。
            SELECT avg(mp.price_usd_per_tonne), min(mp.price_date), max(mp.price_date)
            INTO v_price, v_from, v_to
            FROM metal_prices mp
            WHERE mp.metal = v_metal AND mp.deleted_at IS NULL
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
            'payable_pct', v_payable,
            'contained_kg', v_contained,
            'payable_kg', v_payable_kg,
            'price_usd_per_tonne', v_price,
            'price_date', v_price_date,
            'price_from', v_from,
            'price_to', v_to,
            'metal_value_usd', v_value
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

-- 报价入口:仍然读【活公式】—— 新报价当然按新条款算。签下来的那一刻才抄副本。
CREATE OR REPLACE FUNCTION public.calculate_metal_price_internal(p_formula_id uuid, p_metals jsonb, p_quantity_kg numeric, p_reference_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- 报错次序与 FIN-27 之前一致:先日期,再公式,再数量/金属。
    IF p_reference_date IS NULL THEN
        RAISE EXCEPTION 'REFERENCE_DATE_REQUIRED';
    END IF;
    RETURN calculate_metal_price_from_terms(
        pricing_terms_of_formula(p_formula_id), p_metals, p_quantity_kg, p_reference_date);
END;
$function$;

-- ════════════════════════════════════════════════════════════════════════════
-- 承诺与解析
-- ════════════════════════════════════════════════════════════════════════════

-- 抄副本。【调用这个函数的那一刻就是承诺时刻】—— 它抄的是公式此刻的样子。
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
        price_basis, average_days, treatment_charge_usd_per_tonne, flat_discount_pct)
    VALUES (
        p_purchase_order_line_id, p_inbound_batch_id,
        (v_terms->>'formula_id')::uuid, v_terms->>'formula_code', v_terms->>'formula_name',
        v_terms->>'price_basis', (v_terms->>'average_days')::integer,
        (v_terms->>'treatment_charge_usd_per_tonne')::numeric,
        (v_terms->>'flat_discount_pct')::numeric)
    RETURNING id INTO v_id;

    INSERT INTO pricing_term_commitment_metals (commitment_id, metal, payable_pct)
    SELECT v_id, e.key, e.value::numeric
    FROM jsonb_each_text(v_terms->'payables') e;

    RETURN v_id;
END;
$function$;

-- 一个批次该按哪一份承诺结算:批次自己的 → 它那条采购行的。
-- (与 FIN-27 之前解析【公式】的次序同构 —— 换的是解析到什么,不是怎么解析。)
CREATE OR REPLACE FUNCTION public.resolve_pricing_commitment(p_inbound_batch_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    RETURN COALESCE(
        (SELECT c.id FROM pricing_term_commitments c
          WHERE c.inbound_batch_id = p_inbound_batch_id),
        (SELECT c.id FROM pricing_term_commitments c
           JOIN inbound_batches b ON b.purchase_order_line_id = c.purchase_order_line_id
          WHERE b.id = p_inbound_batch_id)
    );
END;
$function$;

-- 【内层函数,连 authenticated 也不给】它们是 DEFINER 且不查调用者,靠的就是调不到
-- (calculate_metal_price_internal / reverse_journal_entry_internal 的同一条规矩;
-- 默认 EXECUTE 授给的是 PUBLIC,只收 authenticated/anon 不够 —— OPS-3 实测)。
-- 镜像里的对应处:db/views/zzz_function_grants.sql。
REVOKE EXECUTE ON FUNCTION public.pricing_terms_of_formula(uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.pricing_terms_of_commitment(uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.calculate_metal_price_from_terms(jsonb, jsonb, numeric, date) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.commit_pricing_terms(uuid, uuid, uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.resolve_pricing_commitment(uuid) FROM PUBLIC, anon, authenticated;

-- ════════════════════════════════════════════════════════════════════════════
-- C. 结算读副本
-- ════════════════════════════════════════════════════════════════════════════

-- 化验应用:公式解析 → 【承诺解析】。没有副本就点名拒,不退回去读活公式。
CREATE OR REPLACE FUNCTION public.apply_assay_result(p_assay_result_id uuid, p_pricing_formula_id uuid DEFAULT NULL::uuid, p_reference_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user     uuid := auth.uid();
    v_assay    record;
    v_batch    record;
    v_commit   uuid;
    v_csrc     uuid;
    v_ccode    text;
    v_live     uuid;
    v_formula  uuid;
    v_fcode    text;
    v_metals   jsonb;
    v_calc     jsonb;
    v_unit     numeric;
    v_rep      jsonb := NULL;
    v_priced   boolean := false;
    v_status   text;
    v_prior    uuid;
    v_note     text := NULL;
BEGIN
    PERFORM require_permission('module.inbound.edit');
    SELECT * INTO v_assay FROM assay_results
    WHERE id = p_assay_result_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ASSAY_NOT_FOUND|%', COALESCE(p_assay_result_id::text, '?');
    END IF;
    IF v_assay.applied_at IS NOT NULL THEN
        RAISE EXCEPTION 'ASSAY_ALREADY_APPLIED|%', v_assay.code;
    END IF;

    SELECT * INTO v_batch FROM inbound_batches
    WHERE id = v_assay.inbound_batch_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', v_assay.inbound_batch_id;
    END IF;

    -- 1. 批次含量 = 本化验的含量(删后重插)。分摊、估值、回收率读的都是
    --    inbound_batch_metals —— 它必须始终是"当前最可信的真相";化验行本身留作历史。
    DELETE FROM inbound_batch_metals WHERE inbound_batch_id = v_batch.id;
    INSERT INTO inbound_batch_metals (inbound_batch_id, metal, content_pct, created_by, updated_by)
    SELECT v_batch.id, arm.metal, arm.content_pct, v_user, v_user
    FROM assay_result_metals arm
    WHERE arm.assay_result_id = p_assay_result_id;

    SELECT jsonb_agg(jsonb_build_object('metal', arm.metal, 'content_pct', arm.content_pct))
    INTO v_metals
    FROM assay_result_metals arm
    WHERE arm.assay_result_id = p_assay_result_id;

    -- 2. 【结算条款 = 承诺时抄下的副本】(FIN-27)。解析次序与从前解析公式同构:
    --    批次自己的承诺 → 它那条采购行的承诺。活公式在这里【一次都不读】。
    v_commit := resolve_pricing_commitment(v_batch.id);

    IF p_pricing_formula_id IS NOT NULL THEN
        -- 结算时才指名公式(无采购单的现场收货):那一刻【就是】承诺时刻,现在抄。
        -- 已经有副本了就不许被顶掉 —— 副本一旦落下,它就是记录。
        IF v_commit IS NULL THEN
            v_commit := commit_pricing_terms(p_pricing_formula_id, NULL, v_batch.id);
        ELSE
            SELECT c.source_formula_id, c.source_formula_code INTO v_csrc, v_ccode
            FROM pricing_term_commitments c WHERE c.id = v_commit;
            IF v_csrc IS DISTINCT FROM p_pricing_formula_id THEN
                RAISE EXCEPTION 'PRICING_TERMS_ALREADY_COMMITTED|%|%', v_batch.code, v_ccode;
            END IF;
        END IF;
    END IF;

    IF v_commit IS NOT NULL THEN
        -- 3. 与计价器同一份算术(calculate_metal_price_from_terms),条款来自副本;
        --    再走与手工计价【同一条】重计价路径(reprice_inbound_batch)—— 价差分录、
        --    price_history、1200/5000 拆账三件事只存在一份实现。
        --    参考日默认化验日:结算价随行情,行情看化验那天。
        SELECT c.source_formula_id, c.source_formula_code INTO v_formula, v_fcode
        FROM pricing_term_commitments c WHERE c.id = v_commit;

        v_calc := calculate_metal_price_from_terms(
            pricing_terms_of_commitment(v_commit), v_metals, v_batch.quantity,
            COALESCE(p_reference_date, v_assay.assay_date));
        v_unit := (v_calc->>'unit_price_usd_per_kg')::numeric;

        IF v_unit > 0 THEN
            v_rep := reprice_inbound_batch(v_batch.id, v_unit, 'USD', NULL,
                                           'Assay ' || v_assay.code || ' applied');
            v_priced := true;
        ELSE
            -- 低品位料可能"不值它的处理费"(净值 ≤ 0)。负价不入价格机器 ——
            -- 含量照常落地,价格留给人决断。
            v_note := 'computed price not positive: ' || COALESCE(v_unit::text, '?');
        END IF;
    ELSE
        -- 4. 没有副本。有活公式引用【却没有副本】= FIN-27 之前留下的承诺,当时没记
        --    条款 —— 点名拒。悄悄退回去读活公式正是本切要拆掉的行为,而把今天的
        --    公式当成当时谈定的条款,是编造一份承诺(D:不回填)。
        --    完全没有公式引用的批次照旧:手工定价的采购本来就由人定价,不是错误。
        v_live := COALESCE(v_batch.pricing_formula_id,
                           (SELECT pol.pricing_formula_id FROM purchase_order_lines pol
                             WHERE pol.id = v_batch.purchase_order_line_id));
        IF v_live IS NOT NULL THEN
            RAISE EXCEPTION 'PRICING_TERMS_NOT_COMMITTED|%|%', v_batch.code,
                COALESCE((SELECT pf.code FROM pricing_formulas pf WHERE pf.id = v_live), '?');
        END IF;
        v_note := 'no pricing formula resolved';
    END IF;

    -- 5. 批次的定价状态:只有真的重了价才谈得上 final
    v_status := CASE WHEN v_priced AND v_assay.is_final THEN 'final'
                     ELSE v_batch.pricing_status END;
    UPDATE inbound_batches
    SET pricing_formula_id = COALESCE(v_formula, pricing_formula_id),
        pricing_status = v_status,
        updated_by = v_user
    WHERE id = v_batch.id;

    -- 6. 取代链:此前已执行且未被取代的化验,superseded_by 指向本次
    -- code 作平局裁决:applied_at 在同一事务里可能相同(now() 冻结),
    -- 而编号无缝且单调 —— 排序必须确定
    SELECT id INTO v_prior FROM assay_results
    WHERE inbound_batch_id = v_batch.id AND id <> p_assay_result_id
      AND applied_at IS NOT NULL AND superseded_by IS NULL AND deleted_at IS NULL
    ORDER BY applied_at DESC, code DESC LIMIT 1;
    IF v_prior IS NOT NULL THEN
        UPDATE assay_results SET superseded_by = p_assay_result_id, updated_by = v_user
        WHERE id = v_prior;
    END IF;

    UPDATE assay_results
    SET applied_at = now(), applied_by = v_user, updated_by = v_user
    WHERE id = p_assay_result_id;

    -- 完整分解:界面展示的、向供应商/审计师解释调整的,就是这一份 —— 每个数都留
    RETURN jsonb_build_object(
        'assay_result_id', p_assay_result_id,
        'code', v_assay.code,
        'inbound_batch_id', v_batch.id,
        'batch_code', v_batch.code,
        'priced', v_priced,
        'formula_code', v_fcode,
        -- FIN-27:结算按【哪一份承诺】算的 —— 供应商问起来要指得出那份副本
        'commitment_id', v_commit,
        'old_unit_price', v_rep->'old_unit_price',
        'new_unit_price', v_rep->'new_unit_price',
        'price_delta_usd', v_rep->'price_delta_usd',
        'in_stock_ratio', v_rep->'in_stock_ratio',
        'inventory_share_usd', v_rep->'inventory_share_usd',
        'cost_share_usd', v_rep->'cost_share_usd',
        'journal_code', v_rep->'journal_code',
        'pricing_status', v_status,
        'note', v_note
    );
END;
$function$;

-- 手工重计价(没有化验单、按批次当前含量重算)。
-- 【为什么它现在是一个数据库函数】FIN-27 之前这条路住在
-- app/inbound/[id]/assays/actions.ts:repriceFromCurrentContent 里:它在 TypeScript
-- 里【重写了一遍】公式解析次序,再拿活公式算价交给 set_inbound_unit_price。
-- 那是同一个洞的第三个入口,也是"预览/页面不得重实现记账规则"那条规矩的又一次
-- 违反。解析与算术回到库里,页面只问结果。
CREATE OR REPLACE FUNCTION public.reprice_from_committed_terms(p_inbound_batch_id uuid, p_reference_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user    uuid := auth.uid();
    v_batch   record;
    v_commit  uuid;
    v_live    uuid;
    v_formula uuid;
    v_metals  jsonb;
    v_calc    jsonb;
    v_unit    numeric;
    v_rep     jsonb;
BEGIN
    PERFORM require_permission('module.inbound.edit');
    IF p_reference_date IS NULL THEN
        RAISE EXCEPTION 'REFERENCE_DATE_REQUIRED';
    END IF;

    SELECT id, code, quantity, pricing_formula_id, purchase_order_line_id
    INTO v_batch FROM inbound_batches
    WHERE id = p_inbound_batch_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', COALESCE(p_inbound_batch_id::text, '?');
    END IF;

    v_commit := resolve_pricing_commitment(v_batch.id);
    IF v_commit IS NULL THEN
        v_live := COALESCE(v_batch.pricing_formula_id,
                           (SELECT pol.pricing_formula_id FROM purchase_order_lines pol
                             WHERE pol.id = v_batch.purchase_order_line_id));
        RAISE EXCEPTION 'PRICING_TERMS_NOT_COMMITTED|%|%', v_batch.code,
            COALESCE((SELECT pf.code FROM pricing_formulas pf WHERE pf.id = v_live), '?');
    END IF;

    SELECT jsonb_agg(jsonb_build_object('metal', ibm.metal, 'content_pct', ibm.content_pct))
    INTO v_metals
    FROM inbound_batch_metals ibm WHERE ibm.inbound_batch_id = v_batch.id;
    IF v_metals IS NULL THEN
        RAISE EXCEPTION 'NO_METALS';
    END IF;

    v_calc := calculate_metal_price_from_terms(
        pricing_terms_of_commitment(v_commit), v_metals, v_batch.quantity, p_reference_date);
    v_unit := (v_calc->>'unit_price_usd_per_kg')::numeric;
    IF v_unit IS NULL OR v_unit <= 0 THEN
        -- 净值 ≤ 0 的料不进价格机器(与 apply_assay_result 同一判断),但这里是人
        -- 主动按的按钮,所以点名说清楚,而不是默默什么都不做。
        RAISE EXCEPTION 'PRICE_NOT_POSITIVE|%', COALESCE(v_unit::text, '?');
    END IF;

    v_rep := reprice_inbound_batch(v_batch.id, v_unit, 'USD', NULL,
                                   'Repriced from committed terms');

    -- 批次上记下这张公式,界面据此显示"这批货归哪张公式管"(结算仍只读副本)
    SELECT c.source_formula_id INTO v_formula
    FROM pricing_term_commitments c WHERE c.id = v_commit;
    IF v_batch.pricing_formula_id IS NULL AND v_formula IS NOT NULL THEN
        UPDATE inbound_batches SET pricing_formula_id = v_formula, updated_by = v_user
        WHERE id = v_batch.id;
    END IF;

    RETURN jsonb_build_object(
        'inbound_batch_id', v_batch.id,
        'batch_code', v_batch.code,
        'commitment_id', v_commit,
        'unit_price_usd_per_kg', v_unit,
        'calc', v_calc,
        'old_unit_price', v_rep->'old_unit_price',
        'new_unit_price', v_rep->'new_unit_price',
        'price_delta_usd', v_rep->'price_delta_usd',
        'journal_code', v_rep->'journal_code'
    );
END;
$function$;

-- ════════════════════════════════════════════════════════════════════════════
-- B(承诺时刻):采购单创建。create_purchase_order 直接落 'confirmed'/'approved',
-- 没有第二个确认动作可挂,而采购行也【没有任何编辑路径】(全仓库只有这里写
-- purchase_order_lines)—— 所以下单这一刻就是采购承诺成立的一刻。
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.create_purchase_order(p_supplier_id uuid, p_order_date date, p_expected_delivery date, p_currency text, p_fx_rate numeric, p_incoterm text, p_terms_text text, p_notes text, p_lines jsonb, p_payment_terms jsonb DEFAULT '[]'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user       uuid := auth.uid();
    v_date       date;
    v_fx         numeric;
    v_po_id      uuid := gen_random_uuid();
    v_code       text;
    v_line       jsonb;
    v_line_no    integer;
    v_line_id    uuid;      -- FIN-27:承诺挂在行上,需要它的 id
    v_qty        numeric;
    v_price      numeric;
    v_src          text;      -- FIN-26:computed / manual / NULL(旧调用方)
    v_prov         jsonb;     -- FIN-26:computed 行的重导出依据
    v_amount     numeric;
    v_material   uuid;
    v_formula    uuid;
    v_f          record;
    v_total      numeric := 0;
    v_count      integer := 0;
    v_committed  integer := 0;  -- FIN-27:抄下条款的行数
    v_term       jsonb;
    v_seq        integer;
    v_expect     integer := 0;
    v_pct_total  numeric := 0;
    v_term_count integer := 0;
BEGIN
    PERFORM require_permission('module.purchasing.edit');
    IF p_order_date IS NULL THEN
        RAISE EXCEPTION 'ORDER_DATE_REQUIRED';
    END IF;
    v_date := p_order_date;
    IF p_supplier_id IS NULL OR NOT EXISTS (
        SELECT 1 FROM suppliers WHERE id = p_supplier_id AND deleted_at IS NULL
    ) THEN
        RAISE EXCEPTION 'SUPPLIER_NOT_FOUND|%', COALESCE(p_supplier_id::text, '?');
    END IF;

    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = p_currency) THEN
        RAISE EXCEPTION 'CURRENCY_INVALID|%', COALESCE(p_currency, '?');
    END IF;
    -- FIN-0:本位币 SGD 免换算;外币按【下单日】的行方卖出价(tt_sell)估值。
    -- 当日无牌价即拒 —— 这也逼着牌价当天录入(隔天可能就查不到了)。
    IF p_fx_rate IS NOT NULL THEN
        RAISE EXCEPTION 'FX_RATE_NOT_ACCEPTED|%', p_currency;
    END IF;
    v_fx := fx_rate_for(p_currency, p_order_date, 'tt_sell');

    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'NO_LINES';
    END IF;

    v_code := next_purchase_order_code(v_date);

    INSERT INTO purchase_orders (id, code, supplier_id, order_date, expected_delivery_date,
                                 currency, fx_rate, estimated_total_usd, status,
                                 approval_status, approved_at, approved_by,
                                 incoterm, terms_text, notes, created_by, updated_by)
    VALUES (v_po_id, v_code, p_supplier_id, v_date, p_expected_delivery,
            p_currency, v_fx, 0, 'confirmed',
            -- 两级审批留到权限切次:这里直接盖章,结构在、流程不在(见 B1 注释)
            'approved', now(), v_user,
            p_incoterm, p_terms_text, p_notes, v_user, v_user);

    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        v_count := v_count + 1;
        v_line_no := COALESCE((v_line->>'line_no')::integer, v_count);
        v_material := (v_line->>'material_id')::uuid;
        v_qty := (v_line->>'quantity')::numeric;
        v_price := (v_line->>'estimated_unit_price')::numeric;
        v_formula := (v_line->>'pricing_formula_id')::uuid;

        IF v_material IS NULL OR NOT EXISTS (
            SELECT 1 FROM materials WHERE id = v_material AND deleted_at IS NULL
        ) THEN
            RAISE EXCEPTION 'MATERIAL_NOT_FOUND|%', COALESCE(v_material::text, '?');
        END IF;
        IF v_qty IS NULL OR v_qty <= 0 THEN
            RAISE EXCEPTION 'LINE_QTY_INVALID|%', v_line_no;
        END IF;
        IF v_formula IS NOT NULL THEN
            SELECT id, code, is_active, deleted_at INTO v_f
            FROM pricing_formulas WHERE id = v_formula;
            IF NOT FOUND OR v_f.deleted_at IS NOT NULL THEN
                RAISE EXCEPTION 'FORMULA_NOT_FOUND|%', v_formula;
            END IF;
            IF NOT v_f.is_active THEN
                RAISE EXCEPTION 'FORMULA_INACTIVE|%', v_f.code;
            END IF;
        END IF;

        -- 没给估价就是 0:PO 是承诺,估算金额可以留白(公式定价的料常常如此)
        v_amount := CASE WHEN v_price IS NULL THEN 0 ELSE round(v_qty * v_price, 2) END;
        v_total := v_total + v_amount;

        -- ── FIN-26:价格出处 ─────────────────────────────────────────────────
        -- computed / manual 是【记录】,不是从 expected_assay 是否为空【推断】——
        -- 推断在谁改了一个字段没改另一个的那一刻就失真。computed 必带 provenance
        -- (够重新导出这个数:化验、逐金属行情与日期、汇率与取自哪天、公式当时的
        -- 参数快照 —— 公式是可编辑的,行上引用的 id 指不住当时的样子)。
        v_src  := v_line->>'price_source';
        v_prov := v_line->'price_provenance';
        IF v_src IS NOT NULL AND v_src NOT IN ('computed', 'manual') THEN
            RAISE EXCEPTION 'PRICE_SOURCE_INVALID|%|%', v_line_no, v_src;
        END IF;
        IF v_src = 'computed' AND (v_prov IS NULL OR jsonb_typeof(v_prov) <> 'object') THEN
            RAISE EXCEPTION 'PROVENANCE_REQUIRED|%', v_line_no;
        END IF;
        IF v_src IS DISTINCT FROM 'computed' THEN
            v_prov := NULL;   -- 手填/未声明的行不留出处 —— 空白好过编造(B3)
        END IF;
        IF v_price IS NULL THEN
            v_src := NULL; v_prov := NULL;   -- 没有价就没有出处
        END IF;

        INSERT INTO purchase_order_lines (purchase_order_id, line_no, material_id, quantity,
                                          unit, pricing_formula_id, estimated_unit_price,
                                          estimated_amount_usd, expected_assay, notes, created_by,
                                          price_source, price_provenance)
        VALUES (v_po_id, v_line_no, v_material, v_qty,
                COALESCE(v_line->>'unit', 'kg'), v_formula, v_price,
                v_amount, v_line->'expected_assay', v_line->>'notes', v_user,
                v_src, v_prov)
        RETURNING id INTO v_line_id;

        -- ── FIN-27:承诺时抄下结算条款 ───────────────────────────────────────
        -- 【与估价无关】公式定价的行下单时常常没有单价,而条款照样是谈定的 ——
        -- 有公式就抄,不看 estimated_unit_price。抄下之后,公式此后怎么改、
        -- 被停用还是被软删,都碰不到这一行的结算。
        IF v_formula IS NOT NULL THEN
            PERFORM commit_pricing_terms(v_formula, v_line_id, NULL);
            v_committed := v_committed + 1;
        END IF;
    END LOOP;

    UPDATE purchase_orders SET estimated_total_usd = v_total, updated_by = v_user
    WHERE id = v_po_id;

    -- 付款计划是【可选的】:有些采购就是到货即付,没有分期可言。
    IF p_payment_terms IS NOT NULL AND jsonb_typeof(p_payment_terms) = 'array'
       AND jsonb_array_length(p_payment_terms) > 0 THEN
        FOR v_term IN SELECT * FROM jsonb_array_elements(p_payment_terms)
        LOOP
            v_expect := v_expect + 1;
            v_seq := (v_term->>'seq')::integer;
            IF v_seq IS DISTINCT FROM v_expect THEN
                RAISE EXCEPTION 'TERMS_SEQ_INVALID';
            END IF;
            v_pct_total := v_pct_total + COALESCE((v_term->>'percentage')::numeric, 0);

            INSERT INTO purchase_order_payment_terms (purchase_order_id, seq, label, percentage,
                                                      fixed_amount_usd, trigger_event, due_date, notes)
            VALUES (v_po_id, v_seq, v_term->>'label',
                    (v_term->>'percentage')::numeric,
                    (v_term->>'fixed_amount_usd')::numeric,
                    v_term->>'trigger_event',
                    (v_term->>'due_date')::date,
                    v_term->>'notes');
            v_term_count := v_term_count + 1;
        END LOOP;

        IF v_pct_total > 100 THEN
            RAISE EXCEPTION 'TERMS_PCT_EXCEEDS|%', v_pct_total;
        END IF;
    END IF;

    RETURN jsonb_build_object(
        'purchase_order_id', v_po_id,
        'code', v_code,
        'estimated_total_usd', v_total,
        'line_count', v_count,
        'committed_line_count', v_committed,
        'term_count', v_term_count
    );
END;
$function$;

COMMIT;
