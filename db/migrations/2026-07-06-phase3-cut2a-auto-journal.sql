-- ============================================================
-- Phase 3 / Cut 2a — auto-journal engine
-- Date: 2026-07-06
-- Precondition: fresh verified pg_dump backup exists.
--
-- 业务事件在同一事务里自动生成会计分录。全部走既有 post_journal_entry
-- (期间锁 / 平衡 / 无缝编号统一生效)。B1 决定:不建 fin_post_je 包装 ——
-- post_journal_entry 本身可以从函数/触发器里直接 PERFORM,包装无增益。
--
-- 入账事件(本 cut):
--   * 进料计价/改价(set_inbound_unit_price)→ purchase:1200/2000,
--     金额 = 整批数量 × 价差(负债在收货整批上成立,非剩余量),记于定价日
--     CURRENT_DATE(到货日尚无金额,刻意如此)
--   * 加工成本录入/调整/移除(processing_cost_entries 触发器)→ processing_cost:
--     借 5xxx / 贷 2200(负数金额翻边;调整 = 冲旧 + 记新一张分录;软删 = 冲现额)
--   * 成本分摊(allocate_processing_costs)→ allocation 资本化:借 1220,
--     贷 1200(材料)+ 贷 5xxx(已费用化的加工成本转入存货);重分摊 = 冲销旧
--     资本化分录 + 重挂全新分录(净效果即差额,且各科目精确 —— 相比只挂总额
--     差额,能正确处理材料/费用构成变化;记 CURRENT_DATE)。另补挂 COGS 给
--     此前无成本的销售(按各自原 sale_date;已挂 COGS 不追溯 —— 标准成本式
--     简化,重述属人工冲销决策)
--   * 销售(record_output_sale)→ sale:借 1100 / 贷 4000(原币行,USD 侧
--     自动折算);有产出腿单位成本时再挂 借 5000 / 贷 1220;无成本时只挂收入,
--     cogs_journal 返回 null,由 allocate 事后补挂
--   * 盘点过账(post_stocktake)→ stocktake:每条有值差异行 5200 对 1200/1220
--     成对入账(进料按 unit_price,产出按产出腿 unit_cost_usd;无值行只调量不入账)
--   * 批次注销(emit_batch_writeoff_movement)→ writeoff:借 5200 / 贷 1200/1220
--     (仅已计值批次;processing 回滚 reversal_void 不入账 —— 本 cut 不记加工
--     产出/消耗分录,void 的产出从未入过 1220,无可冲销)
-- 不入账(本 cut):
--   * 加工消耗/产出本身 —— 材料价值停在 1200,直到 allocation 资本化转入 1220
--   * 未计值批次的盘点差异/注销(qty-only)
--   * 金属市价波动(仅参考,不 mark-to-market)
-- 口径一致性:1200 进(计价)/出(资本化材料、盘亏、注销);1220 进(资本化)/
-- 出(COGS、盘亏、注销);分摊后该 run 的 5xxx 归零(先费用化后资本化转出),
-- 销售时 5000 承担混合成本;未分摊 run 的成本留在 5xxx 作期间费用。
-- 舍入:资本化分录的 1220 侧取各对方行四舍五入后的合计(round(总) ≠ Σround(部分)
-- 的边角防护);其余分录均为单对行,天然自平。
-- 错误:不新增错误码。自动分录撞上期间锁时 PERIOD_LOCKED 直接抛出 ——
-- 锁定期间业务事件本身就该被拦(B7)。
-- ============================================================
BEGIN;

-- ============================================================
-- B0. 新列:COGS 分录链接 + 资本化跟踪
-- ============================================================
ALTER TABLE public.sales_records
    ADD COLUMN cogs_entry_id uuid REFERENCES public.journal_entries (id);

ALTER TABLE public.processing_runs
    ADD COLUMN capitalized_cost_usd numeric,
    ADD COLUMN capitalization_entry_id uuid REFERENCES public.journal_entries (id);

-- sales_records 不可变守卫放宽一个精确迁移:cogs_entry_id 首挂(NULL → 非 NULL),
-- 其余列仍逐列锁死。配套加窄用途 UPDATE 策略(此前无 UPDATE 策略会把
-- record_output_sale / allocate(SECURITY INVOKER)的补链接挡在 RLS 外)。
CREATE OR REPLACE FUNCTION public.reject_sales_record_mutation()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'SALE_IMMUTABLE';
    END IF;
    IF NEW.id              IS DISTINCT FROM OLD.id
       OR NEW.output_batch_id IS DISTINCT FROM OLD.output_batch_id
       OR NEW.customer_id     IS DISTINCT FROM OLD.customer_id
       OR NEW.quantity        IS DISTINCT FROM OLD.quantity
       OR NEW.unit_price      IS DISTINCT FROM OLD.unit_price
       OR NEW.currency        IS DISTINCT FROM OLD.currency
       OR NEW.fx_rate         IS DISTINCT FROM OLD.fx_rate
       OR NEW.amount_usd      IS DISTINCT FROM OLD.amount_usd
       OR NEW.sale_date       IS DISTINCT FROM OLD.sale_date
       OR NEW.notes           IS DISTINCT FROM OLD.notes
       OR NEW.movement_id     IS DISTINCT FROM OLD.movement_id
       OR NEW.created_at      IS DISTINCT FROM OLD.created_at
       OR NEW.created_by      IS DISTINCT FROM OLD.created_by
       OR OLD.cogs_entry_id   IS NOT NULL
       OR NEW.cogs_entry_id   IS NULL
    THEN
        RAISE EXCEPTION 'SALE_IMMUTABLE';
    END IF;
    RETURN NEW;
END;
$fn$;

CREATE POLICY "authenticated update on sales_records"
    ON public.sales_records FOR UPDATE TO authenticated
    USING (true) WITH CHECK (true);

-- ============================================================
-- B1. 助手:成本类型 → 科目;成本分录行对(录入/冲销共用)
-- ============================================================
CREATE OR REPLACE FUNCTION public.fin_cost_account(p_cost_type text)
RETURNS text LANGUAGE sql IMMUTABLE AS $fn$
    SELECT CASE p_cost_type
        WHEN 'labour'          THEN '5100'
        WHEN 'electricity'     THEN '5110'
        WHEN 'gas'             THEN '5120'
        WHEN 'depreciation'    THEN '5130'
        WHEN 'consumables'     THEN '5140'
        WHEN 'waste_treatment' THEN '5150'
        ELSE '5190'  -- 'other' 及未知值兜底
    END;
$fn$;

-- 一对成本行:正常 = 借 5xxx / 贷 2200;金额为负翻边(冲减成本);p_reverse 再翻一次。
CREATE OR REPLACE FUNCTION public.fin_cost_lines(p_cost_type text, p_amount numeric, p_reverse boolean)
RETURNS jsonb LANGUAGE sql STABLE AS $fn$
    SELECT CASE WHEN (p_amount > 0) <> p_reverse THEN
        jsonb_build_array(
            jsonb_build_object('account_code', fin_cost_account(p_cost_type), 'side', 'debit',  'currency', 'USD', 'amount_ccy', abs(p_amount)),
            jsonb_build_object('account_code', '2200',                        'side', 'credit', 'currency', 'USD', 'amount_ccy', abs(p_amount)))
    ELSE
        jsonb_build_array(
            jsonb_build_object('account_code', '2200',                        'side', 'debit',  'currency', 'USD', 'amount_ccy', abs(p_amount)),
            jsonb_build_object('account_code', fin_cost_account(p_cost_type), 'side', 'credit', 'currency', 'USD', 'amount_ccy', abs(p_amount)))
    END;
$fn$;

-- ============================================================
-- B2. 计价即入账 — set_inbound_unit_price 扩展(最小改动)
-- ============================================================
CREATE OR REPLACE FUNCTION public.set_inbound_unit_price(
    p_inbound_batch_id uuid,
    p_unit_price       numeric,
    p_currency         text DEFAULT 'USD',
    p_fx_rate          numeric DEFAULT NULL,
    p_notes            text DEFAULT NULL
) RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_user    uuid := auth.uid();
    v_old     numeric;
    v_deleted timestamptz;
    v_qty     numeric;
    v_code    text;
    v_fx      numeric;
    v_usd     numeric;
    v_delta   numeric;
BEGIN
    SELECT unit_price, deleted_at, quantity, code
    INTO v_old, v_deleted, v_qty, v_code
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
    IF p_currency = 'USD' THEN
        v_fx := 1;
    ELSE
        IF p_fx_rate IS NULL THEN
            RAISE EXCEPTION 'FX_RATE_REQUIRED|%', p_currency;
        END IF;
        IF p_fx_rate <= 0 THEN
            RAISE EXCEPTION 'FX_RATE_INVALID|%', p_fx_rate;
        END IF;
        v_fx := p_fx_rate;
    END IF;

    v_usd := round(p_unit_price * v_fx, 4);  -- 单价 4 位小数,与 unit_cost_usd 精度一致

    -- GUC 放行本函数内的 unit_price 更新(guard_inbound_price_change),用毕即清,
    -- 免得同事务内后续的直改被误放行(同 movement_ctx 模式)。
    PERFORM set_config('evoltrya.price_ctx', 'set_inbound_unit_price', true);
    UPDATE inbound_batches
    SET unit_price = v_usd, updated_by = v_user, updated_at = now()
    WHERE id = p_inbound_batch_id;
    PERFORM set_config('evoltrya.price_ctx', '', true);

    INSERT INTO price_history (inbound_batch_id, old_unit_price, new_unit_price, currency, original_price, fx_rate, notes, created_by)
    VALUES (p_inbound_batch_id, v_old, v_usd, p_currency, p_unit_price, v_fx, p_notes, v_user);

    -- cut 2a:计价即入账 —— 整批数量 × 价差(负债在收货整批上成立,非剩余量)。
    -- 记于定价日 CURRENT_DATE(到货日尚无金额,刻意如此);USD 口径(原币在 price_history)。
    v_delta := round(v_qty * (v_usd - COALESCE(v_old, 0)), 2);
    IF v_delta <> 0 THEN
        PERFORM post_journal_entry(
            CURRENT_DATE,
            'Pricing ' || v_code,
            'purchase',
            p_inbound_batch_id,
            CASE WHEN v_delta > 0 THEN
                jsonb_build_array(
                    jsonb_build_object('account_code', '1200', 'side', 'debit',  'currency', 'USD', 'amount_ccy', v_delta),
                    jsonb_build_object('account_code', '2000', 'side', 'credit', 'currency', 'USD', 'amount_ccy', v_delta))
            ELSE
                jsonb_build_array(
                    jsonb_build_object('account_code', '2000', 'side', 'debit',  'currency', 'USD', 'amount_ccy', -v_delta),
                    jsonb_build_object('account_code', '1200', 'side', 'credit', 'currency', 'USD', 'amount_ccy', -v_delta))
            END
        );
    END IF;

    RETURN jsonb_build_object(
        'batch_id', p_inbound_batch_id,
        'unit_price_usd', v_usd
    );
END;
$function$;

-- ============================================================
-- B3. 成本即入账 — processing_cost_entries 触发器
-- 说明:规格写"两个 AFTER UPDATE 触发器"(改额/软删),但同一 UPDATE 可能同时
-- 命中两者造成双重入账 —— 合并为一个 UPDATE 触发器函数内分支(软删优先)。
-- 硬 DELETE 不入账:应用层只走软删(RLS 虽允许,约定如此;注销分录只认软删)。
-- ============================================================
CREATE OR REPLACE FUNCTION public.fin_journal_cost_entry()
RETURNS trigger LANGUAGE plpgsql AS $fn$
DECLARE
    v_run_code text;
    v_lines    jsonb;
BEGIN
    SELECT code INTO v_run_code FROM processing_runs WHERE id = NEW.run_id;

    IF TG_OP = 'INSERT' THEN
        IF NEW.deleted_at IS NOT NULL OR NEW.amount_usd = 0 THEN
            RETURN NULL;
        END IF;
        PERFORM post_journal_entry(
            CURRENT_DATE,
            'Cost ' || v_run_code || ' ' || NEW.cost_type,
            'processing_cost', NEW.id,
            fin_cost_lines(NEW.cost_type, NEW.amount_usd, false));
        RETURN NULL;
    END IF;

    -- UPDATE:软删 → 冲销现额(优先,忽略同笔 UPDATE 里的其它变化)
    IF OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL THEN
        IF OLD.amount_usd <> 0 THEN
            PERFORM post_journal_entry(
                CURRENT_DATE,
                'Cost removed ' || v_run_code,
                'processing_cost', NEW.id,
                fin_cost_lines(OLD.cost_type, OLD.amount_usd, true));
        END IF;
        RETURN NULL;
    END IF;
    IF NEW.deleted_at IS NOT NULL THEN
        RETURN NULL;  -- 已软删行的其它变更不入账
    END IF;

    -- 金额/类型变化 → 一张调整分录:冲旧 + 记新(至多 4 行,自平)
    IF NEW.amount_usd IS DISTINCT FROM OLD.amount_usd
       OR NEW.cost_type IS DISTINCT FROM OLD.cost_type THEN
        v_lines := '[]'::jsonb;
        IF OLD.amount_usd <> 0 THEN
            v_lines := v_lines || fin_cost_lines(OLD.cost_type, OLD.amount_usd, true);
        END IF;
        IF NEW.amount_usd <> 0 THEN
            v_lines := v_lines || fin_cost_lines(NEW.cost_type, NEW.amount_usd, false);
        END IF;
        IF jsonb_array_length(v_lines) >= 2 THEN
            PERFORM post_journal_entry(
                CURRENT_DATE,
                'Cost adj ' || v_run_code,
                'processing_cost', NEW.id,
                v_lines);
        END IF;
    END IF;
    RETURN NULL;
END;
$fn$;

CREATE TRIGGER trg_processing_cost_entries_journal_ins
    AFTER INSERT ON public.processing_cost_entries
    FOR EACH ROW EXECUTE FUNCTION public.fin_journal_cost_entry();

CREATE TRIGGER trg_processing_cost_entries_journal_upd
    AFTER UPDATE ON public.processing_cost_entries
    FOR EACH ROW EXECUTE FUNCTION public.fin_journal_cost_entry();

-- ============================================================
-- B4. 销售即入账 — record_output_sale 扩展(最小改动)
-- ============================================================
CREATE OR REPLACE FUNCTION public.record_output_sale(
    p_output_batch_id uuid,
    p_quantity        numeric,
    p_unit_price      numeric,
    p_currency        text,
    p_fx_rate         numeric DEFAULT NULL,
    p_customer_id     uuid DEFAULT NULL,
    p_sale_date       date DEFAULT NULL,
    p_notes           text DEFAULT NULL
) RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_user          uuid := auth.uid();
    v_deleted       timestamptz;
    v_remaining     numeric;
    v_code          text;
    v_new_remaining numeric;
    v_state         text;
    v_fx            numeric;
    v_amount_usd    numeric;
    v_movement_id   uuid;
    v_sale_id       uuid;
    v_sale_date     date := COALESCE(p_sale_date, CURRENT_DATE);
    v_unit_cost     numeric;
    v_cogs          numeric;
    v_je1           jsonb;
    v_je2           jsonb;
BEGIN
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
    IF p_quantity > v_remaining THEN
        RAISE EXCEPTION 'SALE_EXCEEDS_REMAINING|%|%', p_quantity, v_remaining;
    END IF;

    IF p_unit_price IS NULL OR p_unit_price <= 0 THEN
        RAISE EXCEPTION 'SALE_PRICE_INVALID';
    END IF;
    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = p_currency) THEN
        RAISE EXCEPTION 'CURRENCY_INVALID|%', COALESCE(p_currency, '?');
    END IF;
    IF p_currency = 'USD' THEN
        v_fx := 1;  -- 本位币强制 1,忽略传入值
    ELSE
        IF p_fx_rate IS NULL THEN
            RAISE EXCEPTION 'FX_RATE_REQUIRED|%', p_currency;
        END IF;
        IF p_fx_rate <= 0 THEN
            RAISE EXCEPTION 'FX_RATE_INVALID|%', p_fx_rate;
        END IF;
        v_fx := p_fx_rate;
    END IF;
    v_amount_usd := round(p_quantity * p_unit_price * v_fx, 2);

    INSERT INTO inventory_movements (output_batch_id, movement_type, qty_delta, business_date, notes, created_by)
    VALUES (p_output_batch_id, 'sale', -p_quantity, v_sale_date, p_notes, v_user)
    RETURNING id INTO v_movement_id;

    -- customer_id 有效性由 FK 把关(可空:批次可能未指定客户)
    INSERT INTO sales_records (output_batch_id, customer_id, quantity, unit_price, currency, fx_rate, amount_usd, sale_date, notes, movement_id, created_by)
    VALUES (p_output_batch_id, p_customer_id, p_quantity, p_unit_price, p_currency, v_fx, v_amount_usd, v_sale_date, p_notes, v_movement_id, v_user)
    RETURNING id INTO v_sale_id;

    -- cut 2a JE#1:收入 —— 借 1100 / 贷 4000,原币行(amount_ccy = qty × price,
    -- fx 原样),USD 侧由 post_journal_entry 折算,与 amount_usd 同式同值。
    v_je1 := post_journal_entry(
        v_sale_date,
        'Sale ' || v_code,
        'sale', v_sale_id,
        jsonb_build_array(
            jsonb_build_object('account_code', '1100', 'side', 'debit',  'currency', p_currency, 'amount_ccy', p_quantity * p_unit_price, 'fx_rate', v_fx),
            jsonb_build_object('account_code', '4000', 'side', 'credit', 'currency', p_currency, 'amount_ccy', p_quantity * p_unit_price, 'fx_rate', v_fx)));

    -- cut 2a JE#2:COGS —— 有产出腿单位成本才挂;没有则只挂收入(cogs_journal 为
    -- null),等 allocate_processing_costs 补挂(见其 COGS catch-up)。
    SELECT po.unit_cost_usd INTO v_unit_cost
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
                    jsonb_build_object('account_code', '5000', 'side', 'debit',  'currency', 'USD', 'amount_ccy', v_cogs),
                    jsonb_build_object('account_code', '1220', 'side', 'credit', 'currency', 'USD', 'amount_ccy', v_cogs)));
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
        'amount_usd', v_amount_usd,
        'revenue_journal', v_je1->>'code',
        'cogs_journal', v_je2->>'code'
    );
END;
$function$;

-- ============================================================
-- B5. 资本化 + COGS 补挂 — allocate_processing_costs 扩展(最小改动:
--     第 9b 步之后追加 10a 资本化 / 10b COGS catch-up,其余原样)
-- ============================================================
CREATE OR REPLACE FUNCTION public.allocate_processing_costs(p_run_id uuid, p_basis text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
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
BEGIN
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

    -- 4. Material cost = Σ input legs quantity_consumed × inbound.unit_price (NULL price = 0).
    SELECT COALESCE(SUM(pi.quantity_consumed * COALESCE(ib.unit_price, 0)), 0),
           COUNT(*) FILTER (WHERE ib.unit_price IS NULL)
      INTO v_material, v_inputs_without_price
    FROM processing_inputs pi
    JOIN inbound_batches ib ON ib.id = pi.inbound_batch_id
    WHERE pi.run_id = p_run_id;

    -- 5. Process cost = Σ live cost entries.
    SELECT COALESCE(SUM(amount_usd), 0) INTO v_process
    FROM processing_cost_entries
    WHERE run_id = p_run_id AND deleted_at IS NULL;

    -- 6. Total.
    v_total := v_material + v_process;

    -- 7. Basis totals. Metals without a usable price contribute 0 (LEFT JOIN + COALESCE)
    --    and are recorded in skipped_metals; only a zero grand total blocks (NO_METAL_VALUE).
    IF v_basis = 'metal_value' THEN
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
        SET allocated_cost_usd = f.allocated,
            unit_cost_usd = round(f.allocated / f.quantity_produced, 4)
        FROM final f
        WHERE po.id = f.leg_id
        RETURNING f.output_batch_id, f.basis_value, f.allocated, po.unit_cost_usd
    )
    SELECT jsonb_agg(
               jsonb_build_object(
                   'output_batch_id', output_batch_id,
                   'share', round(basis_value / NULLIF(v_total_basis, 0), 6),
                   'allocated_cost_usd', allocated,
                   'unit_cost_usd', unit_cost_usd)
               ORDER BY output_batch_id),
           COALESCE(SUM(allocated), 0)
      INTO v_outputs, v_sum_alloc
    FROM upd;

    -- 9b. Snapshot + run header.
    v_snapshot := jsonb_build_object(
        'basis', v_basis,
        'computed_at', now(),
        'inputs_without_price', v_inputs_without_price,
        'total_output_metal_value_usd',
            CASE WHEN v_basis = 'metal_value' THEN round(v_total_metal_value, 2) ELSE NULL END,
        'prices_used', v_prices_used,
        'skipped_metals', v_skipped_metals
    );

    UPDATE processing_runs
    SET material_cost_usd   = round(v_material, 2),
        process_cost_usd    = round(v_process, 2),
        total_cost_usd      = round(v_total, 2),
        allocation_basis    = v_basis,
        allocation_snapshot = v_snapshot,
        allocated_at        = now(),
        allocated_by        = v_user,
        updated_at          = now(),
        updated_by          = v_user
    WHERE id = p_run_id;

    -- 10a. cut 2a:资本化分录。重分摊 = 先冲销旧资本化分录再重挂(净效果即差额,
    --      且材料/费用构成变化时各科目仍精确;两张均记 CURRENT_DATE)。
    --      借方 1220 取各对方行四舍五入后的合计,保证分录自平
    --      (round(总) ≠ Σround(部分) 的边角防护;capitalized_cost_usd 存该合计)。
    IF v_run.capitalization_entry_id IS NOT NULL
       AND (SELECT status FROM journal_entries WHERE id = v_run.capitalization_entry_id) = 'posted' THEN
        -- 已被人工冲销过的旧资本化分录不再重复冲(status <> 'posted' 直接跳过)
        PERFORM reverse_journal_entry(v_run.capitalization_entry_id, CURRENT_DATE, 'Re-allocation ' || v_run.code);
    END IF;

    v_cap_lines := '[]'::jsonb;
    v_cap_total := 0;
    IF round(v_material, 2) <> 0 THEN
        v_cap_lines := v_cap_lines || jsonb_build_object('account_code', '1200', 'side', 'credit', 'currency', 'USD', 'amount_ccy', round(v_material, 2));
        v_cap_total := v_cap_total + round(v_material, 2);
    END IF;
    FOR v_ct IN
        SELECT cost_type, round(sum(amount_usd), 2) AS amt
        FROM processing_cost_entries
        WHERE run_id = p_run_id AND deleted_at IS NULL
        GROUP BY cost_type
        ORDER BY cost_type
    LOOP
        IF v_ct.amt > 0 THEN
            v_cap_lines := v_cap_lines || jsonb_build_object('account_code', fin_cost_account(v_ct.cost_type), 'side', 'credit', 'currency', 'USD', 'amount_ccy', v_ct.amt);
            v_cap_total := v_cap_total + v_ct.amt;
        ELSIF v_ct.amt < 0 THEN
            -- 负净额(冲减类成本):翻到借方,保持各行 amount_ccy > 0
            v_cap_lines := v_cap_lines || jsonb_build_object('account_code', fin_cost_account(v_ct.cost_type), 'side', 'debit', 'currency', 'USD', 'amount_ccy', -v_ct.amt);
            v_cap_total := v_cap_total + v_ct.amt;
        END IF;
    END LOOP;

    v_cap_entry_id := NULL;
    IF v_cap_total <> 0 THEN
        v_cap_lines := jsonb_build_array(
            jsonb_build_object('account_code', '1220',
                               'side', CASE WHEN v_cap_total > 0 THEN 'debit' ELSE 'credit' END,
                               'currency', 'USD', 'amount_ccy', abs(v_cap_total))
        ) || v_cap_lines;
        v_cap_je := post_journal_entry(
            CURRENT_DATE,
            'Capitalize ' || v_run.code,
            'allocation', p_run_id,
            v_cap_lines);
        v_cap_entry_id := (v_cap_je->>'entry_id')::uuid;
    END IF;

    UPDATE processing_runs
    SET capitalized_cost_usd = v_cap_total,
        capitalization_entry_id = v_cap_entry_id
    WHERE id = p_run_id;

    -- 10b. cut 2a:COGS 补挂 —— 只补此前无 COGS 分录的销售(cogs_entry_id IS NULL),
    --      用最新 unit_cost_usd,按各自原 sale_date(撞期间锁则 PERIOD_LOCKED 直接抛出)。
    --      已挂 COGS 不追溯重述(标准成本式简化;重述属人工冲销决策)。
    FOR v_sale IN
        SELECT sr.id, sr.quantity, sr.sale_date, ob.code AS batch_code, po.unit_cost_usd
        FROM sales_records sr
        JOIN processing_outputs po ON po.output_batch_id = sr.output_batch_id AND po.run_id = p_run_id
        JOIN output_batches ob ON ob.id = sr.output_batch_id
        WHERE sr.cogs_entry_id IS NULL
        ORDER BY sr.sale_date, sr.created_at
    LOOP
        v_cogs := round(v_sale.quantity * v_sale.unit_cost_usd, 2);
        IF v_cogs <> 0 THEN
            v_cogs_je := post_journal_entry(
                v_sale.sale_date,
                'COGS ' || v_sale.batch_code,
                'sale', v_sale.id,
                jsonb_build_array(
                    jsonb_build_object('account_code', '5000', 'side', 'debit',  'currency', 'USD', 'amount_ccy', v_cogs),
                    jsonb_build_object('account_code', '1220', 'side', 'credit', 'currency', 'USD', 'amount_ccy', v_cogs)));
            UPDATE sales_records SET cogs_entry_id = (v_cogs_je->>'entry_id')::uuid WHERE id = v_sale.id;
        END IF;
    END LOOP;

    -- 10. Return.
    RETURN jsonb_build_object(
        'run_id', p_run_id,
        'basis', v_basis,
        'material_cost_usd', round(v_material, 2),
        'process_cost_usd', round(v_process, 2),
        'total_cost_usd', round(v_total, 2),
        'inputs_without_price', v_inputs_without_price,
        'outputs', COALESCE(v_outputs, '[]'::jsonb)
    );
END;
$function$;

-- ============================================================
-- B6a. 盘点估值入账 — post_stocktake 扩展(最小改动:循环内收集分录行,
--      循环后一张多行分录;无值批次只调量不入账)
-- ============================================================
CREATE OR REPLACE FUNCTION public.post_stocktake(p_stocktake_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_user           uuid := auth.uid();
    v_st             record;
    v_line           record;
    v_code           text;
    v_current        numeric;
    v_deleted        timestamptz;
    v_delta          numeric;
    v_lines_total    integer := 0;
    v_lines_adjusted integer := 0;
    v_total_delta    numeric := 0;
    v_value          numeric;
    v_inv_acct       text;
    v_amt            numeric;
    v_je_lines       jsonb := '[]'::jsonb;
BEGIN
    SELECT id, code, status, deleted_at INTO v_st
    FROM stocktakes WHERE id = p_stocktake_id FOR UPDATE;
    IF NOT FOUND OR v_st.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'STOCKTAKE_NOT_FOUND|%', p_stocktake_id;
    END IF;
    IF v_st.status <> 'open' THEN
        RAISE EXCEPTION 'STOCKTAKE_NOT_OPEN|%', v_st.status;
    END IF;

    FOR v_line IN SELECT * FROM stocktake_lines WHERE stocktake_id = p_stocktake_id
    LOOP
        v_lines_total := v_lines_total + 1;

        IF v_line.inbound_batch_id IS NOT NULL THEN
            SELECT code, remaining_qty, deleted_at, unit_price INTO v_code, v_current, v_deleted, v_value
            FROM inbound_batches WHERE id = v_line.inbound_batch_id FOR UPDATE;
            v_inv_acct := '1200';
        ELSE
            SELECT ob.code, ob.remaining_qty, ob.deleted_at, po.unit_cost_usd
            INTO v_code, v_current, v_deleted, v_value
            FROM output_batches ob
            LEFT JOIN processing_outputs po ON po.output_batch_id = ob.id
            WHERE ob.id = v_line.output_batch_id
            FOR UPDATE OF ob;
            v_inv_acct := '1220';
        END IF;

        IF v_deleted IS NOT NULL THEN
            RAISE EXCEPTION 'BATCH_DELETED|%', v_code;
        END IF;

        v_delta := v_line.counted_qty - v_current;
        IF v_delta <> 0 THEN
            IF v_line.inbound_batch_id IS NOT NULL THEN
                INSERT INTO inventory_movements (inbound_batch_id, movement_type, qty_delta, business_date, notes, created_by)
                VALUES (v_line.inbound_batch_id, 'adjustment', v_delta, CURRENT_DATE,
                        'stocktake ' || v_st.code || COALESCE(': ' || v_line.notes, ''), v_user);
                UPDATE inbound_batches
                SET remaining_qty = v_line.counted_qty, updated_by = v_user, updated_at = now()
                WHERE id = v_line.inbound_batch_id;
            ELSE
                INSERT INTO inventory_movements (output_batch_id, movement_type, qty_delta, business_date, notes, created_by)
                VALUES (v_line.output_batch_id, 'adjustment', v_delta, CURRENT_DATE,
                        'stocktake ' || v_st.code || COALESCE(': ' || v_line.notes, ''), v_user);
                UPDATE output_batches
                SET remaining_qty = v_line.counted_qty, updated_by = v_user, updated_at = now()
                WHERE id = v_line.output_batch_id;
            END IF;
            v_lines_adjusted := v_lines_adjusted + 1;
            v_total_delta := v_total_delta + v_delta;

            -- cut 2a:有单值的差异行,成对累积分录行(盘盈:借库存 贷 5200;盘亏反向)。
            -- 无值(未计价进料 / 无成本产出)只调量不入账。
            IF v_value IS NOT NULL THEN
                v_amt := round(abs(v_delta) * v_value, 2);
                IF v_amt <> 0 THEN
                    IF v_delta > 0 THEN
                        v_je_lines := v_je_lines
                            || jsonb_build_object('account_code', v_inv_acct, 'side', 'debit',  'currency', 'USD', 'amount_ccy', v_amt)
                            || jsonb_build_object('account_code', '5200',     'side', 'credit', 'currency', 'USD', 'amount_ccy', v_amt);
                    ELSE
                        v_je_lines := v_je_lines
                            || jsonb_build_object('account_code', '5200',     'side', 'debit',  'currency', 'USD', 'amount_ccy', v_amt)
                            || jsonb_build_object('account_code', v_inv_acct, 'side', 'credit', 'currency', 'USD', 'amount_ccy', v_amt);
                    END IF;
                END IF;
            END IF;
        END IF;
    END LOOP;

    UPDATE stocktakes
    SET status = 'posted', posted_at = now(), updated_by = v_user, updated_at = now()
    WHERE id = p_stocktake_id;

    -- cut 2a:一张分录覆盖全部有值差异行(每行自成一对,天然自平)
    IF jsonb_array_length(v_je_lines) >= 2 THEN
        PERFORM post_journal_entry(
            CURRENT_DATE,
            'Stocktake ' || v_st.code,
            'stocktake', p_stocktake_id,
            v_je_lines);
    END IF;

    RETURN jsonb_build_object(
        'stocktake_id', p_stocktake_id,
        'code', v_st.code,
        'lines_total', v_lines_total,
        'lines_adjusted', v_lines_adjusted,
        'total_delta', v_total_delta
    );
END;
$function$;

-- ============================================================
-- B6b. 注销估值入账 — emit_batch_writeoff_movement 扩展(最小改动)
-- 触发器 WHEN (deleted_at NULL → NOT NULL) 不变,只替换函数体。
-- ============================================================
CREATE OR REPLACE FUNCTION public.emit_batch_writeoff_movement()
RETURNS trigger LANGUAGE plpgsql AS $function$
DECLARE
    v_ctx   text := current_setting('evoltrya.movement_ctx', true);
    v_run   uuid;
    v_value numeric;
    v_acct  text;
    v_amt   numeric;
BEGIN
    IF OLD.remaining_qty > 0 THEN
        IF TG_TABLE_NAME = 'inbound_batches' THEN
            INSERT INTO public.inventory_movements (inbound_batch_id, movement_type, qty_delta, created_by)
            VALUES (OLD.id, 'writeoff', -OLD.remaining_qty, NEW.updated_by);
        ELSE  -- output_batches
            IF v_ctx IS NOT NULL AND split_part(v_ctx, ':', 1) = 'reversal' THEN
                v_run := split_part(v_ctx, ':', 2)::uuid;
                INSERT INTO public.inventory_movements (output_batch_id, movement_type, qty_delta, run_id, created_by)
                VALUES (OLD.id, 'reversal_void', -OLD.remaining_qty, v_run, NEW.updated_by);
            ELSE
                INSERT INTO public.inventory_movements (output_batch_id, movement_type, qty_delta, created_by)
                VALUES (OLD.id, 'writeoff', -OLD.remaining_qty, NEW.updated_by);
            END IF;
        END IF;

        -- cut 2a:注销即入账(仅已计值批次,借 5200 / 贷 1200|1220)。
        -- processing 回滚(reversal_void)不入账:本 cut 不记加工产出/消耗分录,
        -- void 的产出从未入过 1220,无可冲销。未计值批次只出量不入账。
        IF v_ctx IS NULL OR split_part(v_ctx, ':', 1) <> 'reversal' THEN
            IF TG_TABLE_NAME = 'inbound_batches' THEN
                v_value := OLD.unit_price;
                v_acct := '1200';
            ELSE
                SELECT po.unit_cost_usd INTO v_value
                FROM public.processing_outputs po
                WHERE po.output_batch_id = OLD.id
                LIMIT 1;
                v_acct := '1220';
            END IF;
            IF v_value IS NOT NULL THEN
                v_amt := round(OLD.remaining_qty * v_value, 2);
                IF v_amt <> 0 THEN
                    PERFORM post_journal_entry(
                        CURRENT_DATE,
                        'Write-off ' || OLD.code,
                        'writeoff', OLD.id,
                        jsonb_build_array(
                            jsonb_build_object('account_code', '5200', 'side', 'debit',  'currency', 'USD', 'amount_ccy', v_amt),
                            jsonb_build_object('account_code', v_acct, 'side', 'credit', 'currency', 'USD', 'amount_ccy', v_amt)));
                END IF;
            END IF;
        END IF;

        NEW.remaining_qty := 0;
    END IF;
    RETURN NEW;
END;
$function$;

COMMIT;
