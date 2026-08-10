-- SAL-C:无主销售拿到名分 —— 一条说明、一次点名拒绝、一条单向的补挂路径
--
-- 起因(走查):1,100 USD(本位币 1,397)的销售落在了一个限额 1,000 的客户头上
-- 却没有被拦。查明既不是限额没存(存了 1000,留痕在案),也不是比较少算了本单
-- (record_output_sale 第 82 行就是 v_exposure + v_amount_base > v_limit)——
-- 而是【那笔销售根本没有客户】。信用检查开头是 IF p_customer_id IS NOT NULL,
-- 无客户即整段跳过。销售表单上客户是选填的("选择客户(可选)"),于是
-- 管控不是失效,是【从未被问到】。
--
-- 随后 create_invoice 把这笔无主销售开给了 CUS-2026-0003:它只在【销售有客户】时
-- 才校验当事人是否一致(第 81 行),所以发票说客户欠钱,而销售没有记录这件事。
-- 更深一层:敞口按 sales_records.customer_id 汇总,这 1,397 因此对信用管控隐形 ——
-- 客户实际应收 22,083,而管控看见的是 20,686。
--
-- Tim 的答复:无主销售【是正当的】(客户还没登记就卖了货),所以不设硬闸;
-- 但后果要看得见,并且要有一条把事实补记上去的路。三件事:
--
-- 【一】表单上说明白(不禁按钮 —— 见 UI 侧)。
-- 【二】create_invoice 点名拒绝把无主销售开给客户(SALE_NOT_ATTRIBUTED)。
--       开票是【对外声称谁欠钱】,声称之前销售自己得先记下这件事。
-- 【三】补挂路径 attribute_sale_customer —— 本刀的新东西,有一条要写进代码的约束:
--
--   ★【补挂是记录一个本来就成立的事实,不是新的承诺,所以【不做信用检查】★
--     在这里查限额,等于因为"欠得太多"而拒绝把一笔【已经欠下的】债记到账上 ——
--     与因为投入没化验就拒绝一次正当加工是同一种错误(REC-1)。债已经存在,
--     记不记下来只影响我们看不看得见它。补挂之后敞口自然上升;若因此越限,
--     那是看板 credit_over_limit 支该说的话,而不是这条路该拦的事。
--
--   ★【单向:NULL → 某客户。永不改投他人,永不退回 NULL】★
--     把一笔已存在的债改记到另一个人头上是【另一种行为】(涉及双方的账),
--     不该从这条路够得着。sales_records 逐列不可变,所以这里做的是与
--     cogs_entry_id 首挂同形的【精确放宽】,并且带 GUC 上下文:
--     只有 attribute_sale_customer 设过 evoltrya.attribution_ctx 的那次 UPDATE 放行。
--     没有这道 ctx,任何持 module.finance.edit 的人都能直接 PATCH 这一列而【不留痕】,
--     那样留痕就成了自愿项 —— 与 price_ctx / movement_ctx 同一个理由。
-- NOTE: apply with ./db/apply_migration.sh

BEGIN;

-- ════════════════════════════════════════════════════════════════════════════
-- 1. 补挂留痕(只增不改;pricing_formula_history 的形状)
-- ════════════════════════════════════════════════════════════════════════════
CREATE TABLE public.sales_attribution_log (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    sales_record_id  uuid NOT NULL REFERENCES public.sales_records (id),
    customer_id      uuid NOT NULL REFERENCES public.customers (id),
    amount_base      numeric NOT NULL,
    exposure_after   numeric NOT NULL,
    note             text,
    attributed_at    timestamptz NOT NULL DEFAULT now(),
    attributed_by    uuid
);

CREATE INDEX idx_sales_attribution_log_sale
    ON public.sales_attribution_log (sales_record_id, attributed_at DESC);

COMMENT ON TABLE public.sales_attribution_log IS
    '无主销售【补挂客户】的只增不改留痕(SAL-C)。补挂是记录一个已经成立的事实,所以不做信用检查;但谁在什么时候把哪笔债记到了谁头上,必须留下来 —— 补挂当时的敞口一并记下(exposure_after),因为它常常是"越限"的那一刻。';

CREATE OR REPLACE FUNCTION public.guard_sales_attribution_log_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    -- 能被改写的留痕不是留痕。自己报名(FIN-31)。
    IF TG_OP = 'UPDATE' THEN
        RAISE EXCEPTION 'SALES_ATTRIBUTION_APPEND_ONLY|update|%', OLD.id;
    ELSE
        RAISE EXCEPTION 'SALES_ATTRIBUTION_APPEND_ONLY|delete|%', OLD.id;
    END IF;
END;
$function$;

CREATE TRIGGER trg_sales_attribution_log_append_only
    BEFORE UPDATE OR DELETE ON public.sales_attribution_log
    FOR EACH ROW EXECUTE FUNCTION public.guard_sales_attribution_log_append_only();

ALTER TABLE public.sales_attribution_log ENABLE ROW LEVEL SECURITY;
CREATE POLICY "sales_attribution_log select by permission"
    ON public.sales_attribution_log
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));
-- 【没有 INSERT 策略】唯一写入口是 attribute_sale_customer(definer)

-- ════════════════════════════════════════════════════════════════════════════
-- 2. 不可变守卫的【精确单向放宽】(与 cogs_entry_id 首挂同形 + ctx 兜底)
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.reject_sales_record_mutation()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'SALE_IMMUTABLE';
    END IF;
    IF NEW.id              IS DISTINCT FROM OLD.id
       OR NEW.output_batch_id IS DISTINCT FROM OLD.output_batch_id
       OR NEW.quantity        IS DISTINCT FROM OLD.quantity
       OR NEW.unit_price      IS DISTINCT FROM OLD.unit_price
       OR NEW.currency        IS DISTINCT FROM OLD.currency
       OR NEW.fx_rate         IS DISTINCT FROM OLD.fx_rate
       OR NEW.amount_base      IS DISTINCT FROM OLD.amount_base
       OR NEW.sale_date       IS DISTINCT FROM OLD.sale_date
       OR NEW.notes           IS DISTINCT FROM OLD.notes
       OR NEW.movement_id     IS DISTINCT FROM OLD.movement_id
       OR NEW.created_at      IS DISTINCT FROM OLD.created_at
       OR NEW.created_by      IS DISTINCT FROM OLD.created_by
       -- SAL-A:出处两列同样不可变 —— 卖出去之后改口"这是算出来的"与改价同罪
       OR NEW.price_source     IS DISTINCT FROM OLD.price_source
       OR NEW.price_provenance IS DISTINCT FROM OLD.price_provenance
       OR OLD.cogs_entry_id   IS NOT NULL
       OR NEW.cogs_entry_id   IS NULL
       -- SAL-C:customer_id 的【单向】放宽 —— 只允许 NULL → 某客户,且只允许
       -- attribute_sale_customer 那一次(ctx 在场)。改投他人 / 退回 NULL 一律拒:
       -- 把已存在的债改记到另一个人头上是另一种行为,不该从这条路够得着。
       OR (NEW.customer_id IS DISTINCT FROM OLD.customer_id
           AND NOT (OLD.customer_id IS NULL
                    AND NEW.customer_id IS NOT NULL
                    AND current_setting('evoltrya.attribution_ctx', true) = 'attribute_sale_customer'))
    THEN
        RAISE EXCEPTION 'SALE_IMMUTABLE';
    END IF;
    RETURN NEW;
END;
$fn$;

-- ════════════════════════════════════════════════════════════════════════════
-- 3. 补挂本身
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.attribute_sale_customer(p_sales_record_id uuid, p_customer_id uuid, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_sale     record;
    v_cust     record;
    v_prior    text;
    v_exposure numeric;
    v_user     uuid := auth.uid();
BEGIN
    PERFORM require_permission('module.finance.edit');

    SELECT sr.id, sr.customer_id, sr.amount_base, ob.code AS batch_code
    INTO v_sale
    FROM sales_records sr
    JOIN output_batches ob ON ob.id = sr.output_batch_id
    WHERE sr.id = p_sales_record_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SALE_NOT_FOUND|%', COALESCE(p_sales_record_id::text, '?');
    END IF;

    -- 【单向】已经有主的销售不从这条路改 —— 改投他人是另一种行为(动两个人的账)
    IF v_sale.customer_id IS NOT NULL THEN
        SELECT code INTO v_prior FROM customers WHERE id = v_sale.customer_id;
        RAISE EXCEPTION 'SALE_ALREADY_ATTRIBUTED|%|%', v_sale.batch_code, COALESCE(v_prior, '?');
    END IF;

    SELECT id, code INTO v_cust FROM customers
    WHERE id = p_customer_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CUSTOMER_NOT_FOUND|%', COALESCE(p_customer_id::text, '?');
    END IF;

    -- ★【这里【不】查信用限额,也不查冻结】★
    -- 补挂记录的是一个【已经成立】的事实:货已经卖了、钱已经欠着了。在这里因为
    -- "欠得太多"而拒绝,等于拒绝把一笔已经存在的债写进账 —— 债不会因此消失,
    -- 只会继续隐形,而隐形正是这一刀要修的病。与"投入没化验就拒绝加工"同一种错误。
    -- 越限的后果由看板 credit_over_limit 支说;新的销售仍会被 record_output_sale 拦。

    PERFORM set_config('evoltrya.attribution_ctx', 'attribute_sale_customer', true);
    UPDATE sales_records SET customer_id = p_customer_id WHERE id = p_sales_record_id;
    PERFORM set_config('evoltrya.attribution_ctx', '', true);

    v_exposure := customer_ar_exposure_base(p_customer_id);

    INSERT INTO sales_attribution_log
        (sales_record_id, customer_id, amount_base, exposure_after, note, attributed_by)
    VALUES (p_sales_record_id, p_customer_id, v_sale.amount_base, v_exposure, NULLIF(btrim(p_note), ''), v_user);

    RETURN jsonb_build_object(
        'sales_record_id', p_sales_record_id,
        'batch_code', v_sale.batch_code,
        'customer_code', v_cust.code,
        'amount_base', v_sale.amount_base,
        -- 补挂之后的敞口:界面据此当场说出"这一挂把敞口推到了多少"
        'exposure_after', v_exposure,
        'credit_limit_base', (SELECT credit_limit_base FROM customers WHERE id = p_customer_id),
        'over_limit', COALESCE(v_exposure > (SELECT credit_limit_base FROM customers WHERE id = p_customer_id), false)
    );
END;
$function$;

COMMENT ON FUNCTION public.attribute_sale_customer(uuid, uuid, text) IS
    '把一笔【无主】销售补挂到客户名下(SAL-C)。【不做信用检查】—— 补挂记录的是已经成立的事实,不是新的承诺;在这里查限额等于拒绝把一笔已经欠下的债记进账,债不会消失只会继续隐形。【单向】:NULL → 某客户,已有客户一律 SALE_ALREADY_ATTRIBUTED 拒(改投他人是另一种行为,动的是两个人的账)。唯一被允许改 sales_records.customer_id 的路径,靠 evoltrya.attribution_ctx 与不可变守卫配合保证留痕不是自愿项。';

COMMIT;
