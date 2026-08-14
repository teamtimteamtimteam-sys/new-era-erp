-- db/migrations/2026-08-14-so2b-1-sales-record-movements.sql
-- SO-2b 之二:销售的【腿表】—— 一次销售可能有几条流水,而列只装得下一条
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【这一列一直在说半句真话】IOD-1 让销售走 drain_stock:一次销售可以跨几个
-- 库位桶,于是写出【多行】流水。但 sales_records.movement_id 是一个单值外键,
-- 当时的取舍写在 record_output_sale 的注释里 ——「取第一行是有意的取舍,不是
-- 疏忽……真要一一对应,该做的是给 sales_records 建一张腿表,那是另一刀」。
-- 就是这一刀。
--
-- 【为什么把列 DROP 掉,而不是留着当"主腿"】留着它就是一个【永久的半真】:
-- 那一列会一直看起来像"这次销售的流水",而它只是其中一条 —— 而且是按排空
-- 顺序碰巧排在第一的那条,不是任何业务意义上的"主"。两个真相源里有一个是
-- 半真的,读的人没有任何办法知道自己拿到的是哪一个。一处真相,或者不做。
--
-- 【survey:谁在读它】(动手之前逐个查过,而不是估计)
--   * db/views/sales_records_masked.sql —— 选了它。唯一的结构性读者。
--   * db/tables/sales_records.sql —— 列本身、不可变守卫里的一行、以及
--     perm2b 的列清单 SELECT 授权。
--   * lib/database.types.ts —— 生成的。
--   * 【app/ lib/ scripts/ 里一个读者都没有】—— 没有页面、没有报表、没有查询
--     引用过它。所以"重新指向腿表"这一步是空的:没有东西需要被指过去。
-- 于是 DROP 的代价只有一条:masked 视图要 DROP + CREATE(改不了列集),
-- 而跟着它的 ar_open_items 与 operations_now 也要一起重建。三张视图的定义
-- 【逐字取自镜像文件】(脚本生成,不是手抄),所以重建之后线上与镜像仍然逐字相同。
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【回填的前提是【断言】出来的,不是假定的】(fixtures README 第 5 条的同一条)
-- 要回填"每条销售一条腿",就必须先证明线上确实如此。下面的 DO 块逐条查:
--   ① 没有 movement_id 为空的销售记录;
--   ② movement_id 互不相同(两条销售不共用一条腿);
--   ③ 每条 movement_id 指向的流水确实是同一批次的 sale 腿,而且
--      |qty_delta| 恰好等于销售数量 —— 【这一条才是"单腿"的真正判据】:
--      数量对得上,才说明那一条腿装下了整笔销售。
-- 三条任一不成立就整支迁移中止(单事务,库分毫不动),而不是回填一半。
--
-- 【查出来的一件事,顺手记下来而不是顺手回填】线上有 9 条 sale 流水、7 条销售
-- 记录,其中【2 条流水没有任何销售记录认领】(OUT-2026-0003 −10 与
-- OUT-2026-0004 −200,都在 2026-07-03,即台账落地那天,早于 record_output_sale)。
-- 它们不是"漏了腿的销售",是【根本没有销售记录的出库】—— 腿表映射的是
-- 销售→流水,没有销售的那一侧不归它管。**刻意不给它们造销售记录**:
-- 那需要编一个单价、一个币种、一个客户,而没有人知道那三样是什么。
-- 进 docs/known-wrong-until-cutover.md。
--
-- 镜像:db/tables/{sales_record_movements(新),sales_records}.sql、
--       db/functions/{guard_sales_record_movements_append_only(新),
--       record_output_sale,reject_sales_record_mutation(在 sales_records.sql 内)}.sql、
--       db/views/{sales_records_masked,ar_open_items,operations_now}.sql。
-- 行为断言:fixture 66。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

-- ═══ 1 · 腿表 ═══════════════════════════════════════════════════════════════
CREATE TABLE public.sales_record_movements (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    sales_record_id  uuid NOT NULL REFERENCES public.sales_records (id) ON DELETE RESTRICT,
    -- 【UNIQUE:一条流水只能属于一次销售】没有它,同一条出库腿可以被两条销售
    -- 记录同时认领,而"这批货卖了几次"就再也答不上来。
    movement_id      uuid NOT NULL UNIQUE REFERENCES public.inventory_movements (id) ON DELETE RESTRICT,
    created_at       timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.sales_record_movements IS
    'SO-2b:一次销售【实际写出的每一条出库流水】,一条一行。起因:IOD-1 之后销售走 drain_stock,一次销售可以跨几个库位桶而写出多行流水,但 sales_records.movement_id 是单值外键,只装得下排空顺序上碰巧第一的那条 —— 一个永久的半真。那一列已经 DROP,腿只在这里。movement_id 上的 UNIQUE 是判据的一半:一条出库腿只能属于一次销售,否则"这批货卖了几次"再也答不上来。只增不改(guard_sales_record_movements_append_only),没有面向客户端的写策略 —— 唯一写入口是 record_output_sale。';

CREATE INDEX idx_sales_record_movements_sale ON public.sales_record_movements (sales_record_id);

CREATE OR REPLACE FUNCTION public.guard_sales_record_movements_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    -- 腿是台账的一部分,而台账只增不改。改一条腿指向别的流水,等于把一笔已经
    -- 发生的出库改记到另一批货上 —— 那与改销售记录本身同罪(SALE_IMMUTABLE)。
    RAISE EXCEPTION 'SALE_LEG_IMMUTABLE|%', TG_OP;
END;
$function$;

CREATE TRIGGER trg_sales_record_movements_append_only
    BEFORE UPDATE OR DELETE ON public.sales_record_movements
    FOR EACH ROW EXECUTE FUNCTION public.guard_sales_record_movements_append_only();

ALTER TABLE public.sales_record_movements ENABLE ROW LEVEL SECURITY;

-- 【没有 INSERT / UPDATE / DELETE 策略,这是前提而不是遗漏】唯一写入口是
-- record_output_sale(DEFINER)。留一条客户端能直插的路,等于让人写出一条与
-- 台账对不上的腿,而这张表存在的全部意义就是它与流水说的是同一件事。
CREATE POLICY "sales_record_movements select by permission" ON public.sales_record_movements
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

-- ═══ 2 · 回填 —— 前提先断言,再动手 ═════════════════════════════════════════
DO $backfill$
DECLARE
    v_sales int; v_null int; v_dup int; v_bad int; v_legs int;
BEGIN
    SELECT count(*), count(*) FILTER (WHERE movement_id IS NULL) INTO v_sales, v_null FROM sales_records;
    IF v_null > 0 THEN
        RAISE EXCEPTION 'SO2B_PREMISE|% 条销售记录的 movement_id 为空 —— "每条销售恰好一条腿"不成立,不回填', v_null;
    END IF;

    SELECT count(*) INTO v_dup FROM (
        SELECT movement_id FROM sales_records GROUP BY movement_id HAVING count(*) > 1) x;
    IF v_dup > 0 THEN
        RAISE EXCEPTION 'SO2B_PREMISE|% 条流水被多于一条销售记录引用 —— 腿表的 UNIQUE 会拒,不回填', v_dup;
    END IF;

    -- 【真正的单腿判据:数量对得上】指向一条 sale 腿还不够 —— 那条腿必须
    -- 装下了整笔销售,否则它只是多腿里的第一条,而剩下的腿会被这次回填漏掉。
    SELECT count(*) INTO v_bad
      FROM sales_records s JOIN inventory_movements m ON m.id = s.movement_id
     WHERE m.movement_type <> 'sale'
        OR m.output_batch_id IS DISTINCT FROM s.output_batch_id
        OR abs(m.qty_delta) <> s.quantity;
    IF v_bad > 0 THEN
        RAISE EXCEPTION 'SO2B_PREMISE|% 条销售记录的 movement_id 不是"装下整笔销售的同批次 sale 腿" —— 不回填,先人工核对', v_bad;
    END IF;

    INSERT INTO sales_record_movements (sales_record_id, movement_id)
    SELECT id, movement_id FROM sales_records;
    GET DIAGNOSTICS v_legs = ROW_COUNT;
    IF v_legs <> v_sales THEN
        RAISE EXCEPTION 'SO2B_PREMISE|回填了 % 条腿,而销售记录有 % 条', v_legs, v_sales;
    END IF;
    RAISE NOTICE 'SO-2b 回填:% 条销售记录 → % 条腿(前提三条均已断言)', v_sales, v_legs;
END
$backfill$;

-- ═══ 3 · 写入者:一次销售,一条腿一行 ═══════════════════════════════════════
CREATE OR REPLACE FUNCTION public.record_output_sale(p_output_batch_id uuid, p_quantity numeric, p_unit_price numeric, p_currency text, p_fx_rate numeric DEFAULT NULL::numeric, p_customer_id uuid DEFAULT NULL::uuid, p_sale_date date DEFAULT NULL::date, p_notes text DEFAULT NULL::text, p_price_source text DEFAULT NULL::text, p_price_provenance jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user          uuid := auth.uid();
    v_deleted       timestamptz;
    v_remaining     numeric;
    v_code          text;
    v_new_remaining numeric;
    v_state         text;
    v_fx            numeric;
    v_amount_base    numeric;
    v_movement_ids  uuid[];
    v_available     numeric;
    v_held          numeric;
    v_committed     numeric;
    v_sale_id       uuid;
    v_sale_date     date;
    v_unit_cost     numeric;
    v_cogs          numeric;
    v_je1           jsonb;
    v_je2           jsonb;
BEGIN
    PERFORM require_permission('module.output.edit');
    IF p_sale_date IS NULL THEN
        RAISE EXCEPTION 'SALE_DATE_REQUIRED';
    END IF;
    v_sale_date := p_sale_date;
    SELECT deleted_at, remaining_qty, code INTO v_deleted, v_remaining, v_code
    FROM output_batches WHERE id = p_output_batch_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', p_output_batch_id;
    END IF;
    IF v_deleted IS NOT NULL THEN
        RAISE EXCEPTION 'OUTPUT_DELETED';
    END IF;
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'SALE_QTY_INVALID';
    END IF;
    -- IOD-1:【可卖的是"可用",不是"物理剩余"】。被扣住的货仍在这批里,
    -- 但它不可动用 —— 所以拒绝必须同时说出两个数,否则人看着 remaining 够
    -- 却卖不掉,屏幕上没有任何东西解释为什么。
    -- SO-2:第三个桶,同一条理由 —— 【一个说不出 committed 的拒绝,会让人
    -- 看着"可用 0、暂扣 0"却卖不掉】,而真正的答案是"它许给了某张订单"。
    -- 消息里因此有三个数;哪一张订单由订单页与批次面板的预留清单回答。
    -- 【这一刀不从 committed 里卖】:发货消耗归 cut 4,它会带着订单行一起来。
    v_available := COALESCE((SELECT sum(qty_delta) FROM inventory_movements
                             WHERE output_batch_id = p_output_batch_id
                               AND stock_status = 'available'), 0);
    v_held := COALESCE((SELECT sum(qty_delta) FROM inventory_movements
                        WHERE output_batch_id = p_output_batch_id
                          AND stock_status = 'on_hold'), 0);
    v_committed := COALESCE((SELECT sum(qty_delta) FROM inventory_movements
                             WHERE output_batch_id = p_output_batch_id
                               AND stock_status = 'committed'), 0);
    IF p_quantity > v_available THEN
        RAISE EXCEPTION 'IOD_SALE_EXCEEDS_AVAILABLE|%|%|%|%',
            p_quantity, v_available, v_held, v_committed;
    END IF;

    IF p_unit_price IS NULL OR p_unit_price <= 0 THEN
        RAISE EXCEPTION 'SALE_PRICE_INVALID';
    END IF;
    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = p_currency) THEN
        RAISE EXCEPTION 'CURRENCY_INVALID|%', COALESCE(p_currency, '?');
    END IF;
    -- FIN-0:本位币 SGD 免换算;外币按【交易日】的行方买入价(tt_buy)估值 ——
    -- 收入与应收是我们将来要【卖给银行】的外币。当日无牌价即拒(FX_RATE_MISSING),
    -- 不许悄悄用最近一天的。汇率不再由调用方递入:牌价属于 fx_rates,不属于表单。
    IF p_fx_rate IS NOT NULL THEN
        RAISE EXCEPTION 'FX_RATE_NOT_ACCEPTED|%', p_currency;
    END IF;
    v_fx := fx_rate_for(p_currency, v_sale_date, 'tt_buy');
    v_amount_base := round(p_quantity * p_unit_price * v_fx, 2);

    -- ── SAL-B:信用管控 —— 拦截【暂放在这里】,等销售订单存在就搬到下单处 ──────
    -- (docs/sales-scoping.md §6/§8:quote 无处挂、order 未建、发货是今天唯一的
    -- 咽喉。搬,不要在订单上再加第二道检查 —— 两道检查就是两份会漂的实现。)
    IF p_customer_id IS NOT NULL THEN
        DECLARE
            v_hold  boolean;
            v_limit numeric;
            v_cust_code text;
            v_exposure numeric;
        BEGIN
            SELECT credit_hold, credit_limit_base, code
            INTO v_hold, v_limit, v_cust_code
            FROM customers WHERE id = p_customer_id;
            -- 人工冻结:无论敞口多少都停发(争议发票时停货不是算术条件)
            IF v_hold THEN
                RAISE EXCEPTION 'CREDIT_HOLD|%', v_cust_code;
            END IF;
            -- 【NULL = 没设限额(放行);0 = 现款现货(任何赊销都拒)—— 相反,不是相近】
            -- 把 NULL 当 0 用会拒掉全部既有客户的销售;fixture 39A 两头钉死。
            IF v_limit IS NOT NULL THEN
                v_exposure := customer_ar_exposure_base(p_customer_id);
                -- 【本位币比较】,与审批阈值同理:单据币种比较会让 USD 客户越过
                -- SGD 客户越不过的限额(fixture 39B 用同一个判别形状钉住)
                IF v_exposure + v_amount_base > v_limit THEN
                    -- 【把数字说全】:限额、当前敞口、这一单 —— 只说"超限"等于
                    -- 让人去手算系统已经知道的三个数
                    RAISE EXCEPTION 'CREDIT_LIMIT_EXCEEDED|%|%|%|%',
                        v_cust_code, v_limit, v_exposure, v_amount_base;
                END IF;
            END IF;
        END;
    END IF;

    -- IOD-1:出货走 drain_stock —— 一次销售可能跨几个库位桶,于是写出【多行】流水。
    -- 顺序与规则收在 drain_stock 一处(见其函数头),销售这一层只说"拿这么多出来"。
    -- 【SO-2b:腿在 sales_record_movements 里,一条一行】此前这里把 v_movement_ids[1]
    -- 记进单值外键 sales_records.movement_id —— 一个列装不下多条腿,于是那一列一直
    -- 在说半句真话(而且"第一条"只是排空顺序上碰巧排在前面的那条,没有任何业务
    -- 含义)。那一列已经 DROP;下面按 drain_stock 返回的每一个 uuid 写一行腿。
    v_movement_ids := drain_stock(
        p_qty => p_quantity, p_movement_type => 'sale', p_business_date => v_sale_date,
        p_output_batch_id => p_output_batch_id, p_statuses => ARRAY['available'],
        p_notes => p_notes, p_created_by => v_user);

    -- customer_id 有效性由 FK 把关(可空:批次可能未指定客户)
    -- SAL-A(FIN-26 的卖方半边):出处是【记录】,不是从公式在不在推断。
    -- computed 必带依据;manual/NULL 不留依据 —— 空白好过编造。
    IF p_price_source IS NOT NULL AND p_price_source NOT IN ('computed', 'manual') THEN
        RAISE EXCEPTION 'PRICE_SOURCE_INVALID|%', p_price_source;
    END IF;
    IF p_price_source = 'computed' AND (p_price_provenance IS NULL OR jsonb_typeof(p_price_provenance) <> 'object') THEN
        RAISE EXCEPTION 'PROVENANCE_REQUIRED';
    END IF;

    INSERT INTO sales_records (output_batch_id, customer_id, quantity, unit_price, currency, fx_rate, amount_base, sale_date, notes, created_by, price_source, price_provenance)
    VALUES (p_output_batch_id, p_customer_id, p_quantity, p_unit_price, p_currency, v_fx, v_amount_base, v_sale_date, p_notes, v_user,
            p_price_source,
            CASE WHEN p_price_source = 'computed' THEN p_price_provenance END)
    RETURNING id INTO v_sale_id;

    -- SO-2b:【一条腿一行】—— drain_stock 返回几个 uuid 就写几行。
    INSERT INTO sales_record_movements (sales_record_id, movement_id)
    SELECT v_sale_id, x FROM unnest(v_movement_ids) x;
    -- 【断言,不是假设】腿的条数必须等于 drain 返回的条数。一条都不能少:
    -- 少一条,这笔销售在台账上就有一段出库没有主人,而屏幕上什么都不会变
    -- (那正是被 DROP 掉的那一列十几周里一直在做的事)。
    IF (SELECT count(*) FROM sales_record_movements WHERE sales_record_id = v_sale_id)
       <> array_length(v_movement_ids, 1) THEN
        RAISE EXCEPTION 'SALE_LEGS_LOST|%|%', array_length(v_movement_ids, 1),
            (SELECT count(*) FROM sales_record_movements WHERE sales_record_id = v_sale_id);
    END IF;

    -- cut 2a JE#1:收入 —— 借 1100 / 贷 4000,原币行(amount_ccy = qty × price,
    -- fx 原样),USD 侧由 post_journal_entry 折算,与 amount_base 同式同值。
    v_je1 := post_journal_entry(
        v_sale_date,
        'Sale ' || v_code,
        'sale', v_sale_id,
        jsonb_build_array(
            jsonb_build_object('account_code', '1100', 'side', 'debit',  'currency', p_currency, 'amount_ccy', p_quantity * p_unit_price, 'fx_rate', v_fx),
            jsonb_build_object('account_code', '4000', 'side', 'credit', 'currency', p_currency, 'amount_ccy', p_quantity * p_unit_price, 'fx_rate', v_fx)));

    -- cut 2a JE#2:COGS —— 有产出腿单位成本才挂;没有则只挂收入(cogs_journal 为
    -- null),等 allocate_processing_costs 补挂(见其 COGS catch-up)。
    SELECT po.unit_cost_base INTO v_unit_cost
    FROM processing_outputs po
    WHERE po.output_batch_id = p_output_batch_id
    LIMIT 1;

    IF v_unit_cost IS NOT NULL THEN
        v_cogs := round(p_quantity * v_unit_cost, 2);
        IF v_cogs <> 0 THEN
            v_je2 := post_journal_entry(
                v_sale_date,
                'COGS ' || v_code,
                'sale', v_sale_id,
                jsonb_build_array(
                    jsonb_build_object('account_code', '5000', 'side', 'debit',  'currency', base_currency_code(), 'amount_ccy', v_cogs),
                    jsonb_build_object('account_code', '1220', 'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', v_cogs)));
            UPDATE sales_records SET cogs_entry_id = (v_je2->>'entry_id')::uuid WHERE id = v_sale_id;
        END IF;
    END IF;

    v_new_remaining := v_remaining - p_quantity;
    v_state := CASE WHEN v_new_remaining = 0 THEN '已售罄' ELSE '部分售出' END;

    UPDATE output_batches
    SET remaining_qty = v_new_remaining,
        state = v_state,
        updated_by = v_user,
        updated_at = now()
    WHERE id = p_output_batch_id;

    RETURN jsonb_build_object(
        'output_batch_id', p_output_batch_id,
        'sold', p_quantity,
        'remaining_qty', v_new_remaining,
        'state', v_state,
        'sale_id', v_sale_id,
        'amount_base', v_amount_base,
        'revenue_journal', v_je1->>'code',
        'cogs_journal', v_je2->>'code'
    );
END;
$function$;

-- ═══ 4 · 不可变守卫少一行(那一列不在了)═══════════════════════════════════
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
       OR NEW.created_at      IS DISTINCT FROM OLD.created_at
       OR NEW.created_by      IS DISTINCT FROM OLD.created_by
       -- SAL-A:出处两列同样不可变 —— 卖出去之后改口"这是算出来的"与改价同罪
       OR NEW.price_source     IS DISTINCT FROM OLD.price_source
       OR NEW.price_provenance IS DISTINCT FROM OLD.price_provenance
       -- cut 2a:cogs_entry_id 首挂(NULL → 非 NULL),挂上之后不许再动
       OR (NEW.cogs_entry_id IS DISTINCT FROM OLD.cogs_entry_id
           AND NOT (OLD.cogs_entry_id IS NULL AND NEW.cogs_entry_id IS NOT NULL))
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

-- ═══ 5 · 把那一列拿掉 —— 三张视图先让开,再原样建回来 ══════════════════════
-- 【DROP + CREATE,不是 CREATE OR REPLACE】后者改不了列集。依赖链是
--     sales_records_masked ← ar_open_items ← operations_now
-- 三张的定义【逐字取自各自的镜像文件】(本迁移由脚本生成),所以建回来之后
-- 线上与镜像仍然逐字相同 —— 手抄一遍会在某个注释的空格上留下一处永久漂移。
-- 【不写 CASCADE】级联会悄悄带走别的东西。逐张点名,漏一张就当场报错。
-- 【授权不必重发】public 架构上有 ALTER DEFAULT PRIVILEGES(见
-- db/platform-prelude.sql),postgres 建出来的关系自动带上 anon/authenticated/
-- service_role 的授权 —— 线上与重建走的是同一条路,已核实 pg_default_acl。
DROP VIEW public.operations_now;
DROP VIEW public.ar_open_items;
DROP VIEW public.sales_records_masked;

ALTER TABLE public.sales_records DROP COLUMN movement_id;

-- ── sales_records_masked(逐字取自 db/views/sales_records_masked.sql)──
CREATE VIEW public.sales_records_masked WITH (security_invoker = off) AS
 SELECT id,
    output_batch_id,
    customer_id,
    quantity,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN unit_price
            ELSE NULL::numeric
        END AS unit_price,
    currency,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN fx_rate
            ELSE NULL::numeric
        END AS fx_rate,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN amount_base
            ELSE NULL::numeric
        END AS amount_base,
    sale_date,
    notes,
    created_at,
    created_by,
    cogs_entry_id,
    price_source,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN price_provenance
            ELSE NULL::jsonb
        END AS price_provenance
   FROM sales_records
  WHERE has_permission('module.finance.view'::text);

-- ── ar_open_items(逐字取自 db/views/ar_open_items.sql)──
CREATE VIEW public.ar_open_items WITH (security_invoker = off) AS
 SELECT sr.id AS sales_record_id,
    ob.code AS doc_code,
    sr.customer_id,
    c.legal_name AS customer_name,
    sr.sale_date,
    sr.amount_base,
    sr.currency,
    round(sr.quantity * sr.unit_price, 2) AS amount_ccy,
    round(COALESCE(s.settled, 0::numeric), 2) AS settled_ccy,
    round(sr.quantity * sr.unit_price - COALESCE(s.settled, 0::numeric), 2) AS open_ccy,
    round((sr.quantity * sr.unit_price - COALESCE(s.settled, 0::numeric)) * sr.fx_rate, 2) AS open_base,
    CURRENT_DATE - sr.sale_date AS days_outstanding,
        CASE
            WHEN (CURRENT_DATE - sr.sale_date) <= 30 THEN 'b0_30'::text
            WHEN (CURRENT_DATE - sr.sale_date) <= 60 THEN 'b31_60'::text
            WHEN (CURRENT_DATE - sr.sale_date) <= 90 THEN 'b61_90'::text
            ELSE 'b90_plus'::text
        END AS bucket,
    inv.invoice_id,
    inv.invoice_code
   FROM sales_records_masked sr
     JOIN output_batches ob ON ob.id = sr.output_batch_id
     LEFT JOIN customers c ON c.id = sr.customer_id
     LEFT JOIN LATERAL ( SELECT sum(pa.allocated_ccy) AS settled
           FROM payment_allocations pa
             JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
          WHERE pa.sales_record_id = sr.id) s ON true
     LEFT JOIN LATERAL ( SELECT i.id AS invoice_id,
            i.code AS invoice_code
           FROM invoice_lines_masked il
             JOIN invoices_masked i ON i.id = il.invoice_id
          WHERE il.sales_record_id = sr.id AND NOT il.invoice_voided
         LIMIT 1) inv ON true
  WHERE round(sr.quantity * sr.unit_price - COALESCE(s.settled, 0::numeric), 2) > 0::numeric
    AND has_permission('module.finance.view'::text);

-- ── operations_now(逐字取自 db/views/operations_now.sql)──
CREATE VIEW public.operations_now WITH (security_invoker = off) AS
 SELECT item_type,
    permission,
    arm_permission_any(item_type) AS permission_any,
    item_id,
    doc_kind,
    item_code,
    subject,
    item_date,
    CURRENT_DATE - item_date AS days_waiting
   FROM ( SELECT 'awaiting_assay'::text AS item_type,
            'module.inbound.view'::text AS permission,
            ib.id AS item_id,
            NULL::text AS doc_kind,
            b.batch_code AS item_code,
            b.supplier_name AS subject,
            COALESCE(ib.arrival_date, ib.created_at::date) AS item_date
           FROM batch_assay_status b
             JOIN inbound_batches ib ON ib.id = b.inbound_batch_id
          WHERE b.assay_count = 0
        UNION ALL
         SELECT 'assay_unapplied'::text AS item_type,
            'module.inbound.view'::text AS permission,
            ib.id AS item_id,
            NULL::text AS doc_kind,
            b.batch_code AS item_code,
            b.latest_assay_code AS subject,
            COALESCE(ib.arrival_date, ib.created_at::date) AS item_date
           FROM batch_assay_status b
             JOIN inbound_batches ib ON ib.id = b.inbound_batch_id
          WHERE b.has_unapplied_assay
        UNION ALL
         SELECT 'batch_unpriced'::text AS item_type,
            'module.inbound.view'::text AS permission,
            ib.id AS item_id,
            NULL::text AS doc_kind,
            b.batch_code AS item_code,
            b.supplier_name AS subject,
            COALESCE(ib.arrival_date, ib.created_at::date) AS item_date
           FROM batch_assay_status b
             JOIN inbound_batches ib ON ib.id = b.inbound_batch_id
          WHERE b.pricing_status = 'unpriced'::text
        UNION ALL
         SELECT 'allocation_stale'::text AS item_type,
            'module.processing.view'::text AS permission,
            s.run_id AS item_id,
            NULL::text AS doc_kind,
            s.code AS item_code,
            NULL::text AS subject,
            s.last_cost_change::date AS item_date
           FROM processing_run_allocation_status s
          WHERE s.is_stale OR s.allocated_at IS NULL AND s.last_cost_change IS NOT NULL
        UNION ALL
         SELECT 'po_awaiting_receipt'::text AS item_type,
            'module.purchasing.view'::text AS permission,
            po.id AS item_id,
            NULL::text AS doc_kind,
            po.code AS item_code,
            po.status AS subject,
            po.order_date AS item_date
           FROM purchase_orders po
          WHERE po.deleted_at IS NULL AND (po.status = ANY (ARRAY['confirmed'::text, 'receiving'::text]))
        UNION ALL
         SELECT 'stocktake_open'::text AS item_type,
            'module.stocktakes.view'::text AS permission,
            st.id AS item_id,
            NULL::text AS doc_kind,
            st.code AS item_code,
            NULL::text AS subject,
            st.started_at::date AS item_date
           FROM stocktakes st
          WHERE st.deleted_at IS NULL AND st.status = 'open'::text
        UNION ALL
         SELECT 'qualification_expiring'::text AS item_type,
            'module.suppliers.view'::text AS permission,
            s_1.id AS item_id,
            NULL::text AS doc_kind,
            s_1.code AS item_code,
            (ct.name_en || ' — '::text) || s_1.legal_name AS subject,
            sc.valid_until AS item_date
           FROM supplier_compliance sc
             JOIN certificate_types ct ON ct.code = sc.cert_type_code
             JOIN suppliers s_1 ON s_1.id = sc.supplier_id
          WHERE sc.deleted_at IS NULL AND s_1.deleted_at IS NULL AND ct.disposition <> 'ignore'::text AND sc.valid_until IS NOT NULL AND sc.valid_until <= (CURRENT_DATE + ct.warn_lead_days)
        UNION ALL
         SELECT 'qualification_missing'::text AS item_type,
            'module.suppliers.view'::text AS permission,
            s_2.id AS item_id,
            NULL::text AS doc_kind,
            s_2.code AS item_code,
            s_2.legal_name AS subject,
            s_2.created_at::date AS item_date
           FROM suppliers s_2
          WHERE s_2.deleted_at IS NULL AND s_2.status = 'active'::supplier_status AND NOT (EXISTS ( SELECT 1
                   FROM supplier_compliance sc2
                  WHERE sc2.supplier_id = s_2.id AND sc2.deleted_at IS NULL))
        UNION ALL
         SELECT 'credit_over_limit'::text AS item_type,
            'module.customers.view'::text AS permission,
            c_1.id AS item_id,
            NULL::text AS doc_kind,
            c_1.code AS item_code,
            c_1.legal_name AS subject,
            COALESCE(( SELECT min(sr.sale_date) AS min
                   FROM sales_records sr
                  WHERE sr.customer_id = c_1.id), CURRENT_DATE) AS item_date
           FROM customers c_1
          WHERE c_1.deleted_at IS NULL AND c_1.credit_limit_base IS NOT NULL AND customer_ar_exposure_visible(c_1.id) >= c_1.credit_limit_base
        UNION ALL
         SELECT 'output_unsold_aging'::text AS item_type,
            'module.output.view'::text AS permission,
            ob.id AS item_id,
            NULL::text AS doc_kind,
            ob.code AS item_code,
            ob.state AS subject,
            COALESCE(ob.output_date, ob.created_at::date) AS item_date
           FROM output_batches ob
          WHERE ob.deleted_at IS NULL AND ob.remaining_qty > 0::numeric AND (CURRENT_DATE - COALESCE(ob.output_date, ob.created_at::date)) >= 60
        UNION ALL
         SELECT 'safety_stock_below'::text AS item_type,
            'module.inventory.view'::text AS permission,
            msa.material_id AS item_id,
            NULL::text AS doc_kind,
            msa.code AS item_code,
            (((((trim_scale(msa.available_qty)::text || ' / '::text) || trim_scale(msa.safety_stock_qty)::text) || ' '::text) || COALESCE(msa.unit, ''::text)) || ' — short '::text) || trim_scale(msa.safety_stock_qty - msa.available_qty)::text AS subject,
            COALESCE(msa.last_movement_date, CURRENT_DATE) AS item_date
           FROM material_stock_available msa
          WHERE msa.safety_stock_qty IS NOT NULL AND msa.available_qty < msa.safety_stock_qty
        UNION ALL
         SELECT 'leave_pending'::text AS item_type,
            'module.hr.view'::text AS permission,
            lr.id AS item_id,
            NULL::text AS doc_kind,
            lr.code AS item_code,
            e.legal_name AS subject,
            lr.created_at::date AS item_date
           FROM leave_requests lr
             JOIN employees e ON e.id = lr.employee_id
          WHERE lr.status = 'pending'::text AND lr.deleted_at IS NULL
        UNION ALL
         SELECT 'claim_pending'::text AS item_type,
            'module.hr.view'::text AS permission,
            mc.id AS item_id,
            NULL::text AS doc_kind,
            mc.code AS item_code,
            e.legal_name AS subject,
            mc.created_at::date AS item_date
           FROM medical_claims mc
             JOIN employees e ON e.id = mc.employee_id
          WHERE mc.status = 'submitted'::text AND mc.deleted_at IS NULL
        UNION ALL
         SELECT 'review_submitted'::text AS item_type,
            'module.hr.view'::text AS permission,
            r.id AS item_id,
            NULL::text AS doc_kind,
            e.code AS item_code,
            e.legal_name AS subject,
            COALESCE(r.submitted_at::date, r.created_at::date) AS item_date
           FROM performance_reviews r
             JOIN employees e ON e.id = r.employee_id
          WHERE r.status = 'submitted'::text
        UNION ALL
         SELECT 'invoice_overdue'::text AS item_type,
            'module.finance.view'::text AS permission,
            i.invoice_id AS item_id,
            NULL::text AS doc_kind,
            i.code AS item_code,
            i.customer_name AS subject,
            i.due_date AS item_date
           FROM invoice_status i
          WHERE i.overdue
        UNION ALL
         SELECT 'ar_over_90'::text AS item_type,
            'module.finance.view'::text AS permission,
            ar.sales_record_id AS item_id,
            NULL::text AS doc_kind,
            ar.doc_code AS item_code,
            ar.customer_name AS subject,
            ar.sale_date AS item_date
           FROM ar_open_items ar
          WHERE ar.bucket = 'b90_plus'::text
        UNION ALL
         SELECT 'ap_over_90'::text AS item_type,
            'module.finance.view'::text AS permission,
            ap.doc_id AS item_id,
            ap.doc_kind,
            ap.doc_code AS item_code,
            ap.supplier_name AS subject,
            ap.doc_date AS item_date
           FROM ap_open_items ap
          WHERE ap.bucket = 'b90_plus'::text
        UNION ALL
         SELECT 'fx_rate_gap'::text AS item_type,
            'module.finance.view'::text AS permission,
            NULL::uuid AS item_id,
            NULL::text AS doc_kind,
            g.currency AS item_code,
            array_to_string(g.missing_types, ', '::text) AS subject,
            g.rate_date AS item_date
           FROM fx_rate_gaps g
          WHERE g.rate_date >= (CURRENT_DATE - 45)
        UNION ALL
         SELECT 'bank_unmatched'::text AS item_type,
            'module.finance.view'::text AS permission,
            s.id AS item_id,
            NULL::text AS doc_kind,
            s.bank_account_code AS item_code,
            s.code AS subject,
            l.line_date AS item_date
           FROM bank_statement_lines l
             JOIN bank_statements s ON s.id = l.statement_id
          WHERE l.match_status = 'unmatched'::text AND s.deleted_at IS NULL
        UNION ALL
         SELECT 'margin_cost_not_allocated'::text AS item_type,
            'data.view_prices'::text AS permission,
            bm.run_id AS item_id,
            NULL::text AS doc_kind,
            bm.batch_code AS item_code,
            bm.material_name AS subject,
            ob.output_date AS item_date
           FROM batch_margin bm
             JOIN output_batches ob ON ob.id = bm.output_batch_id
          WHERE bm.margin_status = 'no_unit_cost'::text) a
  WHERE has_permission(permission) AND (arm_permission_any(item_type) IS NULL OR has_any_permission(arm_permission_any(item_type)));

GRANT SELECT ON public.operations_now TO authenticated;

COMMIT;
