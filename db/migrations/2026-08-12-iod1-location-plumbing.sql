-- db/migrations/2026-08-12-iod1-location-plumbing.sql
-- IOD-1:库位管线 —— 转移单、收货库位、消耗自动排空
--
-- 这一刀之后:每一行流水都知道自己的库位(或明确地"未指定"),转移存在,
-- 而【一次转移不再能把消耗打坏】。
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【为什么这三件事必须同刀落地 —— survey 实测过的那个交互】
-- STK-1 的"桶不许为负"用 IS NOT DISTINCT FROM 分组,所以【未指定库位自成一桶】。
-- 于是只要有一次转移把货挪到真库位,NULL 桶就空了;而当时所有消耗写入者
-- (销售/投料/注销)都不带库位、一律写 NULL 桶 —— 下一次销售当场撞
-- STK_NEGATIVE_BUCKET。在本地重建上实测过,一字不差:
--     收 100(NULL)→ 转移 100 到 SG-A1 → 卖 10(不带库位)
--     ERROR: STK_NEGATIVE_BUCKET|OUT-2026-0001|available|-10
--     同一笔卖 10、但点名 SG-A1 → 成功
-- 所以"加转移单"与"让消耗认识库位"不是两刀,是一刀。fixture 57 把这个场景
-- 原样钉住,免得它以后被拆开。
--
-- 【本刀【不】做 allowed_classes 拦截 —— 那是 IOD-2】
-- storage_location_allowed_classes 至今只是记录:没有任何一次移动会因为
-- "这个库位不许放这类物料"而被拒。落地那一刀要一并回答 survey 撞到的第三态:
-- 物料【未分类】(waste_classification_code IS NULL)落在一个已配置的库位上,
-- 天真的谓词会让它掉进 refuse —— 而未分类不是"被排除",它是没人分过类。
-- 镜像与函数头都写着这句,别让下一个人以为拦截已经在了。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

-- ═══ 0 · pair_id:任何成对流水的连结 ════════════════════════════════════════
ALTER TABLE public.inventory_movements RENAME COLUMN status_pair_id TO pair_id;

ALTER TABLE public.inventory_movements DROP CONSTRAINT inventory_movements_status_pair;

ALTER TABLE public.inventory_movements
    DROP CONSTRAINT inventory_movements_movement_type_check;
ALTER TABLE public.inventory_movements
    ADD CONSTRAINT inventory_movements_movement_type_check CHECK (movement_type IN
        ('receipt','processing_consume','processing_produce','reversal_restore',
         'reversal_void','sale','writeoff','adjustment',
         'status_change_out','status_change_in','transfer_out','transfer_in'));

ALTER TABLE public.inventory_movements DROP CONSTRAINT inventory_movements_sign;
ALTER TABLE public.inventory_movements
    ADD CONSTRAINT inventory_movements_sign CHECK (CASE movement_type
        WHEN 'receipt' THEN qty_delta > 0
        WHEN 'processing_produce' THEN qty_delta > 0
        WHEN 'reversal_restore' THEN qty_delta > 0
        WHEN 'processing_consume' THEN qty_delta < 0
        WHEN 'reversal_void' THEN qty_delta < 0
        WHEN 'sale' THEN qty_delta < 0
        WHEN 'writeoff' THEN qty_delta < 0
        WHEN 'status_change_out' THEN qty_delta < 0
        WHEN 'status_change_in' THEN qty_delta > 0
        WHEN 'transfer_out' THEN qty_delta < 0
        WHEN 'transfer_in' THEN qty_delta > 0
        ELSE true END);

-- 四种成对类型【当且仅当】带 pair_id
ALTER TABLE public.inventory_movements
    ADD CONSTRAINT inventory_movements_pair CHECK (
        (movement_type IN ('status_change_out','status_change_in','transfer_out','transfer_in'))
        = (pair_id IS NOT NULL));

COMMENT ON COLUMN public.inventory_movements.pair_id IS
    'IOD-1(STK-1 起名为 status_pair_id):把一次【成对流水】的两条腿连起来。今天有两种成对:状态变更(出一个状态桶、进另一个,同批次同库位)与转移(出一个库位、进另一个,同批次同状态)。两者形状相同 —— 一出一进、数量相反,所以物理总量按构造不动,不需要任何人记得。四种成对类型当且仅当带 pair_id,由 inventory_movements_pair 双向强制。';

-- ═══ 1 · 派生桶取数已在 STK-1(derived_stock_qty)—— 转移与排空共用它 ═══════

CREATE OR REPLACE FUNCTION public.create_stock_transfer(
    p_qty numeric,
    p_to_location_id uuid,
    p_inbound_batch_id uuid DEFAULT NULL::uuid,
    p_output_batch_id uuid DEFAULT NULL::uuid,
    p_from_location_id uuid DEFAULT NULL::uuid,
    p_stock_status text DEFAULT 'available'::text,
    p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_pair uuid := gen_random_uuid();
    v_have numeric;
    v_today date := CURRENT_DATE;
BEGIN
    PERFORM require_permission('module.inventory.edit');

    IF num_nonnulls(p_inbound_batch_id, p_output_batch_id) <> 1 THEN
        RAISE EXCEPTION 'STK_ONE_BATCH';
    END IF;
    IF p_qty IS NULL OR p_qty <= 0 THEN
        RAISE EXCEPTION 'STK_QTY_INVALID|%', COALESCE(p_qty::text, '?');
    END IF;
    IF p_stock_status IS NULL OR p_stock_status NOT IN ('available','on_hold') THEN
        RAISE EXCEPTION 'STK_QTY_INVALID|%', COALESCE(p_stock_status, '?');
    END IF;
    -- 【源与目的相同】不是一次无害的空操作:它会写下两行互相抵消的流水,
    -- 把台账弄脏,而且几乎总是意味着操作的人选错了一边。
    IF p_from_location_id IS NOT DISTINCT FROM p_to_location_id THEN
        RAISE EXCEPTION 'IOD_TRANSFER_SAME_LOCATION';
    END IF;
    -- 目的地必须是一个【在用】的库位。停用的库位不该再收货(LOC-1 的停用语义)。
    IF p_to_location_id IS NULL
       OR NOT EXISTS (SELECT 1 FROM storage_locations WHERE id = p_to_location_id AND is_active) THEN
        RAISE EXCEPTION 'IOD_TRANSFER_TO_INACTIVE|%', COALESCE(p_to_location_id::text, '?');
    END IF;

    -- 【同一粒度】对着派生桶比,与 STK-1 的暂扣/释放一模一样:
    -- remaining_qty 没有库位轴,在这个粒度上现算是唯一可能的来源。
    v_have := derived_stock_qty(p_inbound_batch_id, p_output_batch_id, p_from_location_id, p_stock_status);
    IF p_qty > v_have THEN
        RAISE EXCEPTION 'IOD_TRANSFER_EXCEEDS_BUCKET|%|%', p_qty, v_have;
    END IF;

    -- 成对:出源库位、进目的库位。【状态原样带过去】—— 转移搬的是位置,
    -- 不是状态;一批被扣住的货换个货架仍然是被扣住的。
    INSERT INTO inventory_movements
        (inbound_batch_id, output_batch_id, location_id, movement_type,
         qty_delta, stock_status, pair_id, business_date, notes, created_by)
    VALUES
        (p_inbound_batch_id, p_output_batch_id, p_from_location_id, 'transfer_out',
         -p_qty, p_stock_status, v_pair, v_today, NULLIF(btrim(COALESCE(p_note,'')),''), v_user),
        (p_inbound_batch_id, p_output_batch_id, p_to_location_id, 'transfer_in',
          p_qty, p_stock_status, v_pair, v_today, NULLIF(btrim(COALESCE(p_note,'')),''), v_user);

    RETURN jsonb_build_object('pair_id', v_pair, 'qty', p_qty, 'stock_status', p_stock_status);
END;
$function$;

-- ═══ 2 · drain_stock:消耗侧唯一的出货口 ════════════════════════════════════
CREATE OR REPLACE FUNCTION public.drain_stock(
    p_qty numeric,
    p_movement_type text,
    p_business_date date,
    p_inbound_batch_id uuid DEFAULT NULL::uuid,
    p_output_batch_id uuid DEFAULT NULL::uuid,
    p_statuses text[] DEFAULT ARRAY['available']::text[],
    p_run_id uuid DEFAULT NULL::uuid,
    p_notes text DEFAULT NULL::text,
    p_created_by uuid DEFAULT NULL::uuid)
 RETURNS uuid[]
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_left numeric := p_qty;
    v_take numeric;
    v_row  record;
    v_ids  uuid[] := ARRAY[]::uuid[];
    v_id   uuid;
BEGIN
    -- ═══════════════════════════════════════════════════════════════════════
    -- 【排空顺序是一条 POLICY,不是一条自然律】
    --   ① 先 NULL 桶(未指定库位),② 再按库位 code 升序。
    --   每碰一个桶写一行流水;所有行加起来【正好】等于 p_qty。
    --
    -- 为什么是这个顺序:未指定库位的货是"还没有人安置过"的货,先把它用掉,
    -- 库存就会自然朝"每一笔都有库位"收敛,而不是让 NULL 桶永远挂在那里。
    -- 库位之间按 code 升序,只是因为它【确定】—— 两次同样的消耗必须给出
    -- 同样的结果,否则台账不可复现。
    --
    -- 【要改这条顺序(例如改成按转移日期 FIFO)需要动什么】改这个函数体一处,
    -- 外加 fixture 57 的排空顺序臂 —— 消耗的三个调用方(销售、投料、注销)
    -- 都不知道顺序,它们只说"拿 N 出来"。这是把顺序收在一处的全部理由:
    -- 换策略是改一个地方,不是改三个地方并祈祷它们一致。
    -- ═══════════════════════════════════════════════════════════════════════
    IF p_qty IS NULL OR p_qty <= 0 THEN
        RAISE EXCEPTION 'STK_QTY_INVALID|%', COALESCE(p_qty::text, '?');
    END IF;

    FOR v_row IN
        SELECT m.location_id, m.stock_status, sum(m.qty_delta) AS qty
        FROM inventory_movements m
        WHERE m.inbound_batch_id IS NOT DISTINCT FROM p_inbound_batch_id
          AND m.output_batch_id  IS NOT DISTINCT FROM p_output_batch_id
          AND m.stock_status = ANY (p_statuses)
        GROUP BY m.location_id, m.stock_status
        HAVING sum(m.qty_delta) > 0
        ORDER BY (m.location_id IS NOT NULL),                       -- NULL 桶在前
                 (SELECT l.code FROM storage_locations l WHERE l.id = m.location_id),
                 m.stock_status
    LOOP
        EXIT WHEN v_left <= 0;
        v_take := LEAST(v_left, v_row.qty);
        INSERT INTO inventory_movements
            (inbound_batch_id, output_batch_id, location_id, movement_type,
             qty_delta, stock_status, run_id, business_date, notes, created_by)
        VALUES (p_inbound_batch_id, p_output_batch_id, v_row.location_id, p_movement_type,
                -v_take, v_row.stock_status, p_run_id, p_business_date, p_notes, p_created_by)
        RETURNING id INTO v_id;
        v_ids := v_ids || v_id;
        v_left := v_left - v_take;
    END LOOP;

    -- 桶里凑不够 —— 调用方【应当】在调用之前就按自己的口径拒绝并说人话
    -- (销售说"可用不够"、投料说"这批投不了这么多")。走到这里说明那一层漏了,
    -- 所以这里点名报错,而不是少写几行了事:少写的那几行会让台账与缓存对不上。
    IF v_left > 0 THEN
        RAISE EXCEPTION 'IOD_DRAIN_INSUFFICIENT|%|%', p_qty, p_qty - v_left;
    END IF;

    RETURN v_ids;
END;
$function$;

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
    v_movement_id   uuid;
    v_movement_ids  uuid[];
    v_available     numeric;
    v_held          numeric;
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
    v_available := COALESCE((SELECT sum(qty_delta) FROM inventory_movements
                             WHERE output_batch_id = p_output_batch_id
                               AND stock_status = 'available'), 0);
    v_held := COALESCE((SELECT sum(qty_delta) FROM inventory_movements
                        WHERE output_batch_id = p_output_batch_id
                          AND stock_status = 'on_hold'), 0);
    IF p_quantity > v_available THEN
        RAISE EXCEPTION 'IOD_SALE_EXCEEDS_AVAILABLE|%|%|%', p_quantity, v_available, v_held;
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
    -- 【sales_records.movement_id 记第一行】:那一列是单值外键,而一次销售现在
    -- 可能对应多行。取第一行是有意的取舍,不是疏忽 —— 完整的行集合按
    -- (output_batch_id, movement_type='sale', business_date) 可取回;
    -- 真要一一对应,该做的是给 sales_records 建一张腿表,那是另一刀。
    v_movement_ids := drain_stock(
        p_qty => p_quantity, p_movement_type => 'sale', p_business_date => v_sale_date,
        p_output_batch_id => p_output_batch_id, p_statuses => ARRAY['available'],
        p_notes => p_notes, p_created_by => v_user);
    v_movement_id := v_movement_ids[1];

    -- customer_id 有效性由 FK 把关(可空:批次可能未指定客户)
    -- SAL-A(FIN-26 的卖方半边):出处是【记录】,不是从公式在不在推断。
    -- computed 必带依据;manual/NULL 不留依据 —— 空白好过编造。
    IF p_price_source IS NOT NULL AND p_price_source NOT IN ('computed', 'manual') THEN
        RAISE EXCEPTION 'PRICE_SOURCE_INVALID|%', p_price_source;
    END IF;
    IF p_price_source = 'computed' AND (p_price_provenance IS NULL OR jsonb_typeof(p_price_provenance) <> 'object') THEN
        RAISE EXCEPTION 'PROVENANCE_REQUIRED';
    END IF;

    INSERT INTO sales_records (output_batch_id, customer_id, quantity, unit_price, currency, fx_rate, amount_base, sale_date, notes, movement_id, created_by, price_source, price_provenance)
    VALUES (p_output_batch_id, p_customer_id, p_quantity, p_unit_price, p_currency, v_fx, v_amount_base, v_sale_date, p_notes, v_movement_id, v_user,
            p_price_source,
            CASE WHEN p_price_source = 'computed' THEN p_price_provenance END)
    RETURNING id INTO v_sale_id;

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
CREATE OR REPLACE FUNCTION public.commit_processing_run(p_process_date date, p_notes text, p_loss_qty numeric, p_inputs jsonb, p_outputs jsonb, p_allocation_basis text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user_id      uuid := auth.uid();
    v_process_date date;
    v_run_id       uuid;
    v_total_input  numeric := 0;
    v_total_output numeric := 0;
    v_input        jsonb;
    v_output       jsonb;
    v_inbound_id   uuid;
    v_output_id    uuid;   -- FIN-25:再加工投料(产出批为源)
    v_consumed     numeric;
    v_remaining    numeric;
    v_available     numeric;
    v_held          numeric;
    v_new_remaining numeric;
    v_material_id  uuid;
    v_qty          numeric;
    v_unit         text;
    v_purity       text;
    v_new_output_id uuid;
BEGIN
    PERFORM require_permission('module.processing.edit');
    IF p_process_date IS NULL THEN
        RAISE EXCEPTION 'PROCESS_DATE_REQUIRED';
    END IF;

    -- FIN-36:分摊基准【必填】。不在这里回退到 finance_settings 的公司默认值 ——
    -- 那只会把"没人选过"从 schema 挪进函数,同一个病换一层楼。表单永远带着值来
    -- (预选自 finance_settings.default_allocation_basis),所以必填没有代价。
    IF p_allocation_basis IS NULL THEN
        RAISE EXCEPTION 'ALLOCATION_BASIS_REQUIRED';
    END IF;
    IF p_allocation_basis NOT IN ('weight','metal_value') THEN
        RAISE EXCEPTION 'INVALID_BASIS|%', p_allocation_basis;
    END IF;

    v_process_date := p_process_date;
    -- 0. 基本校验
    IF p_inputs IS NULL OR jsonb_array_length(p_inputs) = 0 THEN
        RAISE EXCEPTION 'NO_INPUTS';
    END IF;
    IF p_outputs IS NULL OR jsonb_array_length(p_outputs) = 0 THEN
        RAISE EXCEPTION 'NO_OUTPUTS';
    END IF;
    IF p_loss_qty IS NOT NULL AND p_loss_qty < 0 THEN
        RAISE EXCEPTION 'LOSS_NEGATIVE';
    END IF;

    -- 0b. 同一批次(不论来源)不能重复添加。FIN-25:投料可为进料批或产出批,
    --     恰一非空;两个都给或都不给 → INPUT_PARENT_INVALID。
    IF EXISTS (
        SELECT 1 FROM jsonb_array_elements(p_inputs) elem
        WHERE num_nonnulls(elem->>'inbound_batch_id', elem->>'output_batch_id') <> 1
    ) THEN
        RAISE EXCEPTION 'INPUT_PARENT_INVALID';
    END IF;
    IF (SELECT count(DISTINCT COALESCE(elem->>'inbound_batch_id', elem->>'output_batch_id'))
        FROM jsonb_array_elements(p_inputs) elem) <> jsonb_array_length(p_inputs) THEN
        RAISE EXCEPTION 'DUPLICATE_INPUT';
    END IF;

    -- 1. 遍历投入:校验库存(并锁行)+ 累计投入合计
    FOR v_input IN SELECT * FROM jsonb_array_elements(p_inputs)
    LOOP
        v_inbound_id := (v_input->>'inbound_batch_id')::uuid;
        v_output_id  := (v_input->>'output_batch_id')::uuid;
        v_consumed   := (v_input->>'quantity_consumed')::numeric;

        IF v_consumed IS NULL OR v_consumed <= 0 THEN
            RAISE EXCEPTION 'INPUT_QTY_INVALID';
        END IF;

        IF v_inbound_id IS NOT NULL THEN
            SELECT remaining_qty INTO v_remaining
            FROM inbound_batches
            WHERE id = v_inbound_id AND deleted_at IS NULL
            FOR UPDATE;
            IF v_remaining IS NULL THEN
                RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', v_inbound_id;
            END IF;
        ELSE
            -- FIN-25:产出批投料 —— 同一套校验、同一把锁。库存机器本就共用
            -- (inventory_movements 两侧 XOR,remaining_qty 两表同义)。
            SELECT remaining_qty INTO v_remaining
            FROM output_batches
            WHERE id = v_output_id AND deleted_at IS NULL
            FOR UPDATE;
            IF v_remaining IS NULL THEN
                RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', v_output_id;
            END IF;
        END IF;
        -- IOD-1:投得进去的是【可用】,不是【物理剩余】—— 被扣住的货还在批次里,
        -- 但它不可动用。拒绝同时说出可用与暂扣两个数,否则人看着 remaining 够
        -- 却投不进去,屏幕上没有任何解释。
        v_available := COALESCE((SELECT sum(qty_delta) FROM inventory_movements m
                                 WHERE m.inbound_batch_id IS NOT DISTINCT FROM v_inbound_id
                                   AND m.output_batch_id IS NOT DISTINCT FROM v_output_id
                                   AND m.stock_status = 'available'), 0);
        v_held := COALESCE((SELECT sum(qty_delta) FROM inventory_movements m
                            WHERE m.inbound_batch_id IS NOT DISTINCT FROM v_inbound_id
                              AND m.output_batch_id IS NOT DISTINCT FROM v_output_id
                              AND m.stock_status = 'on_hold'), 0);
        IF v_consumed > v_available THEN
            RAISE EXCEPTION 'IOD_CONSUME_EXCEEDS_AVAILABLE|%|%|%', v_consumed, v_available, v_held;
        END IF;

        v_total_input := v_total_input + v_consumed;
    END LOOP;

    -- 2. 遍历产出:校验 + 累计产出合计
    FOR v_output IN SELECT * FROM jsonb_array_elements(p_outputs)
    LOOP
        v_qty := (v_output->>'quantity')::numeric;
        IF v_qty IS NULL OR v_qty <= 0 THEN
            RAISE EXCEPTION 'OUTPUT_QTY_INVALID';
        END IF;
        IF (v_output->>'material_id') IS NULL THEN
            RAISE EXCEPTION 'OUTPUT_NO_MATERIAL';
        END IF;
        v_total_output := v_total_output + v_qty;
    END LOOP;

    -- 3. 质量守恒:产出不能大于投入
    IF v_total_output > v_total_input THEN
        RAISE EXCEPTION 'OUTPUT_EXCEEDS_INPUT|%|%', v_total_output, v_total_input;
    END IF;

    -- 4. 建加工单表头(code 由触发器生成)
    INSERT INTO processing_runs (
        process_date, total_input, total_output, loss_qty, notes, status,
        allocation_basis, created_by, updated_by
    ) VALUES (
        v_process_date, v_total_input, v_total_output,
        COALESCE(p_loss_qty, v_total_input - v_total_output),
        p_notes, 'committed', p_allocation_basis, v_user_id, v_user_id
    )
    RETURNING id INTO v_run_id;

    -- 5. 再遍历投入:扣库存 + 更新阶段 + 建投入腿 + 记库存流水(消耗)
    --    FIN-25:ctx 提前到这里 —— 投入腿的守卫触发器(guard_processing_input)
    --    只放行函数上下文;原来 ctx 在第 6 步(产出)才设,投入腿就会被自己拒掉。
    PERFORM set_config('evoltrya.movement_ctx', 'processing:' || v_run_id::text, true);
    FOR v_input IN SELECT * FROM jsonb_array_elements(p_inputs)
    LOOP
        v_inbound_id := (v_input->>'inbound_batch_id')::uuid;
        v_output_id  := (v_input->>'output_batch_id')::uuid;
        v_consumed   := (v_input->>'quantity_consumed')::numeric;

        IF v_inbound_id IS NOT NULL THEN
            SELECT remaining_qty INTO v_remaining
            FROM inbound_batches WHERE id = v_inbound_id;
            v_new_remaining := v_remaining - v_consumed;

            UPDATE inbound_batches
            SET remaining_qty = v_new_remaining,
                stage = CASE WHEN v_new_remaining <= 0 THEN '已加工完' ELSE '加工中' END,
                updated_by = v_user_id,
                updated_at = now()
            WHERE id = v_inbound_id;

            -- IOD-1:投料走 drain_stock —— 可能跨几个库位桶,于是写出多行(规则见其函数头)
            PERFORM drain_stock(
                p_qty => v_consumed, p_movement_type => 'processing_consume',
                p_business_date => v_process_date, p_inbound_batch_id => v_inbound_id,
                p_statuses => ARRAY['available'], p_run_id => v_run_id, p_created_by => v_user_id);

            INSERT INTO processing_inputs (run_id, inbound_batch_id, quantity_consumed)
            VALUES (v_run_id, v_inbound_id, v_consumed);
        ELSE
            -- FIN-25:产出批投料。state 是【销售状态】(表注),消耗不碰它 ——
            -- 只扣 remaining_qty,流水挂 output_batch_id(XOR 的另一侧)。
            SELECT remaining_qty INTO v_remaining
            FROM output_batches WHERE id = v_output_id;
            v_new_remaining := v_remaining - v_consumed;

            UPDATE output_batches
            SET remaining_qty = v_new_remaining,
                updated_by = v_user_id,
                updated_at = now()
            WHERE id = v_output_id;

            PERFORM drain_stock(
                p_qty => v_consumed, p_movement_type => 'processing_consume',
                p_business_date => v_process_date, p_output_batch_id => v_output_id,
                p_statuses => ARRAY['available'], p_run_id => v_run_id, p_created_by => v_user_id);

            INSERT INTO processing_inputs (run_id, output_batch_id, quantity_consumed)
            VALUES (v_run_id, v_output_id, v_consumed);
        END IF;
    END LOOP;

    -- 6. 遍历产出:建产出批次 + 建产出腿
    --    产出的入库流水由 AFTER INSERT 触发器发出;先设置上下文标记本批产出属于本加工单。
    PERFORM set_config('evoltrya.movement_ctx', 'processing:' || v_run_id::text, true);
    FOR v_output IN SELECT * FROM jsonb_array_elements(p_outputs)
    LOOP
        v_material_id := (v_output->>'material_id')::uuid;
        v_qty         := (v_output->>'quantity')::numeric;
        v_unit        := COALESCE(NULLIF(v_output->>'unit', ''), 'kg');
        v_purity      := NULLIF(v_output->>'purity', '');

        INSERT INTO output_batches (
            material_id, quantity, unit, remaining_qty, output_date, state, purity,
            created_by, updated_by
        ) VALUES (
            v_material_id, v_qty, v_unit, v_qty, v_process_date, '库存中', v_purity,
            v_user_id, v_user_id
        )
        RETURNING id INTO v_new_output_id;

        INSERT INTO processing_outputs (run_id, output_batch_id, quantity_produced)
        VALUES (v_run_id, v_new_output_id, v_qty);
    END LOOP;

    -- 用毕即清(price_ctx 同一条理由:免得同事务内后续的直改被误放行 ——
    -- fixture 19F 实测:不清,守卫触发器对残留 ctx 放行裸 INSERT)
    PERFORM set_config('evoltrya.movement_ctx', '', true);

    RETURN v_run_id;
END;
$function$;

-- FIN-25(2026-08-06):产出批投料同样还原(上游批已删则跳过 —— 其自身加工单
-- 已冲销的情形)。
-- FIN-25c:movement_ctx 用毕即清(残留 ctx 会让投入腿守卫放行同事务内的裸 INSERT)。

CREATE OR REPLACE FUNCTION public.rollback_processing_run(p_run_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user_id uuid := auth.uid();
    v_run_deleted_at timestamptz;
    v_process_date date;     -- FIN-32:还原流水的业务日 = 原加工单的加工日
    v_bad_output record;
    v_input record;
    v_old_remaining numeric;
    v_new_remaining numeric;
    v_quantity numeric;
BEGIN
    PERFORM require_permission('module.processing.edit');
    -- 1. 锁定加工单，校验存在且未删除
    SELECT process_date INTO v_process_date FROM processing_runs WHERE id = p_run_id;
    SELECT deleted_at INTO v_run_deleted_at
    FROM processing_runs
    WHERE id = p_run_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'RUN_NOT_FOUND|%', p_run_id;
    END IF;

    IF v_run_deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'RUN_ALREADY_DELETED';
    END IF;

    -- 标记本次为回滚上下文,供产出批次软删触发器发出 reversal_void。
    PERFORM set_config('evoltrya.movement_ctx', 'reversal:' || p_run_id::text, true);

    -- 2. 安全检查：任何一个产出批次动过就拒绝
    SELECT ob.code, ob.state, ob.quantity, ob.remaining_qty
    INTO v_bad_output
    FROM processing_outputs po
    JOIN output_batches ob ON ob.id = po.output_batch_id
    WHERE po.run_id = p_run_id
      AND ob.deleted_at IS NULL
      AND (ob.state <> '库存中' OR ob.remaining_qty <> ob.quantity)
    LIMIT 1;

    IF FOUND THEN
        RAISE EXCEPTION 'OUTPUT_CONSUMED|%|%|%|%',
            v_bad_output.code, v_bad_output.state, v_bad_output.remaining_qty, v_bad_output.quantity;
    END IF;

    -- 3. 还原进料：加回 remaining_qty，重判 stage，记 reversal_restore 流水。
    --    FIN-25:产出批投料同样还原(不碰 state —— 那是销售状态)。
    FOR v_input IN
        SELECT pi.inbound_batch_id, pi.output_batch_id, pi.quantity_consumed
        FROM processing_inputs pi
        WHERE pi.run_id = p_run_id
    LOOP
        IF v_input.inbound_batch_id IS NOT NULL THEN
            SELECT quantity, remaining_qty INTO v_quantity, v_old_remaining
            FROM inbound_batches
            WHERE id = v_input.inbound_batch_id
            FOR UPDATE;

            IF NOT FOUND THEN
                CONTINUE;  -- 进料批次已被删，跳过
            END IF;

            v_new_remaining := LEAST(
                COALESCE(v_old_remaining, 0) + v_input.quantity_consumed,
                v_quantity
            );

            UPDATE inbound_batches
            SET remaining_qty = v_new_remaining,
                stage = CASE WHEN v_new_remaining >= v_quantity THEN '待加工' ELSE '加工中' END,
                updated_by = v_user_id,
                updated_at = now()
            WHERE id = v_input.inbound_batch_id;

            IF v_new_remaining - COALESCE(v_old_remaining, 0) > 0 THEN
                -- FIN-32:还原不是物理事件,是在更正一次记错的加工单 —— 业务日取
                -- 【原加工单的 process_date】,于是消耗与还原在同一天对消,
                -- 中间那几天的库存历史不会凭空少掉一批实际还在的货。
                --
                -- 【IOD-1:逐行镜像原始流水,不按规则重新分配】投料现在可能跨几个
                -- 库位桶写出多行;还原必须把货放回【它原来所在的那些桶】,而不是
                -- 按 drain 的顺序倒着来一遍 —— 那两者在一般情形下并不相等,
                -- 差额会安静地把库存挪到别的库位上。所以这里读原始的
                -- processing_consume 行,逐行取反。
                PERFORM mirror_consume_restore(p_run_id, v_input.inbound_batch_id, NULL,
                                                 v_new_remaining - COALESCE(v_old_remaining, 0),
                                                 v_process_date, v_user_id);
            END IF;
        ELSE
            SELECT quantity, remaining_qty INTO v_quantity, v_old_remaining
            FROM output_batches
            WHERE id = v_input.output_batch_id AND deleted_at IS NULL
            FOR UPDATE;

            IF NOT FOUND THEN
                CONTINUE;  -- 上游产出批已被删（如其自身加工单已冲销），跳过
            END IF;

            v_new_remaining := LEAST(
                COALESCE(v_old_remaining, 0) + v_input.quantity_consumed,
                v_quantity
            );

            UPDATE output_batches
            SET remaining_qty = v_new_remaining,
                updated_by = v_user_id,
                updated_at = now()
            WHERE id = v_input.output_batch_id;

            IF v_new_remaining - COALESCE(v_old_remaining, 0) > 0 THEN
                -- FIN-32:同上 —— 产出批投料的还原(FIN-25 那条边)业务日一样取原加工日
                PERFORM mirror_consume_restore(p_run_id, NULL, v_input.output_batch_id,
                                                 v_new_remaining - COALESCE(v_old_remaining, 0),
                                                 v_process_date, v_user_id);
            END IF;
        END IF;
    END LOOP;

    -- 4. 软删这张单生成的产出批次(void 流水 + 归零由 BEFORE UPDATE 触发器处理)
    UPDATE output_batches
    SET deleted_at = now(),
        updated_by = v_user_id,
        updated_at = now()
    WHERE id IN (
        SELECT output_batch_id FROM processing_outputs WHERE run_id = p_run_id
    )
    AND deleted_at IS NULL;

    -- 5. 软删加工单本身（腿表保留作审计）
    UPDATE processing_runs
    SET status = 'reversed',
        deleted_at = now(),
        updated_by = v_user_id,
        updated_at = now()
    WHERE id = p_run_id;

    PERFORM set_config('evoltrya.movement_ctx', '', true);   -- 用毕即清(同 commit)
END;
$function$;

-- ═══ 3 · 还原的镜像器:按【原始流水行】逐行取反 ═════════════════════════════
CREATE OR REPLACE FUNCTION public.mirror_consume_restore(
    p_run_id uuid, p_inbound_batch_id uuid, p_output_batch_id uuid,
    p_expected_total numeric, p_business_date date, p_created_by uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_row record;
    v_sum numeric := 0;
BEGIN
    -- 【为什么必须逐行镜像,而不是按 drain 顺序倒推】
    -- 投料按"NULL 桶优先、再按库位 code"排空;还原若也按某条规则重新分配,
    -- 两者在一般情形下【并不相等】(中间可能发生过转移、暂扣、别的消耗)。
    -- 差额不会报错,它只会安静地把货放回错的库位。所以还原读的是事实:
    -- 这张加工单当初到底从哪几个桶里各拿走了多少。
    FOR v_row IN
        SELECT m.location_id, m.stock_status, -m.qty_delta AS qty
        FROM inventory_movements m
        WHERE m.run_id = p_run_id
          AND m.movement_type = 'processing_consume'
          AND m.inbound_batch_id IS NOT DISTINCT FROM p_inbound_batch_id
          AND m.output_batch_id  IS NOT DISTINCT FROM p_output_batch_id
        ORDER BY m.created_at, m.id
    LOOP
        INSERT INTO inventory_movements
            (inbound_batch_id, output_batch_id, location_id, movement_type,
             qty_delta, stock_status, run_id, business_date, created_by)
        VALUES (p_inbound_batch_id, p_output_batch_id, v_row.location_id, 'reversal_restore',
                v_row.qty, v_row.stock_status, p_run_id, p_business_date, p_created_by);
        v_sum := v_sum + v_row.qty;
    END LOOP;

    -- 【对不上就点名,不悄悄少写几行】还原总额与 remaining_qty 的回补必须一致,
    -- 否则台账与缓存当场分家(check_ledger_invariant 会在提交时抓到,但那时
    -- 报出来的是一句关于不变量的话,不是"还原对不上原始投料")。
    IF v_sum <> p_expected_total THEN
        RAISE EXCEPTION 'IOD_RESTORE_MISMATCH|%|%', p_expected_total, v_sum;
    END IF;
END;
$function$;

-- ═══ 4 · 收货带库位:走既有的 ctx 机制,不给批次表加列 ═══════════════════════
-- 【为什么不加列】库位是【流水】的属性(一批货可以分散在几个库位),批次上放
-- 一个 location_id 会立刻和这件事矛盾 —— 那是 STK-1 已经决定过的形状。
-- 收货只是"第一行流水落在哪儿",所以它是一次性的上下文,不是批次的字段。
-- 机制沿用 commit_processing_run 早就在用的那一套(set_config + 触发器读)。
CREATE OR REPLACE FUNCTION public.emit_batch_receipt_movement()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_ctx text := current_setting('evoltrya.movement_ctx', true);
    v_loc text := current_setting('evoltrya.location_ctx', true);
    v_run uuid;
    v_location uuid;
BEGIN
    IF NEW.remaining_qty IS NULL OR NEW.remaining_qty <= 0 THEN
        RETURN NULL;
    END IF;

    -- 空串与未设置都当作【未指定库位】—— 表单不选就是不选,那是一个合法答案
    -- (LOC-1/STK-1 的"未指定库位"是一等状态,不是缺失)。
    IF v_loc IS NOT NULL AND btrim(v_loc) <> '' THEN
        v_location := v_loc::uuid;
    END IF;

    IF TG_TABLE_NAME = 'inbound_batches' THEN
        INSERT INTO public.inventory_movements (inbound_batch_id, movement_type, qty_delta, location_id, business_date, created_by)
        VALUES (NEW.id, 'receipt', NEW.remaining_qty, v_location, NEW.arrival_date, NEW.created_by);
    ELSE  -- output_batches
        IF v_ctx IS NOT NULL AND split_part(v_ctx, ':', 1) = 'processing' THEN
            v_run := split_part(v_ctx, ':', 2)::uuid;
            -- 【加工产出一律落在"未指定库位"】—— 上架是一次转移,不是产出的副作用。
            -- 产线上刚下来的货还没被搬到任何货架上,系统不该替人假设它在哪。
            INSERT INTO public.inventory_movements (output_batch_id, movement_type, qty_delta, run_id, business_date, created_by)
            VALUES (NEW.id, 'processing_produce', NEW.remaining_qty, v_run, NEW.output_date, NEW.created_by);
        ELSE
            INSERT INTO public.inventory_movements (output_batch_id, movement_type, qty_delta, location_id, business_date, created_by)
            VALUES (NEW.id, 'receipt', NEW.remaining_qty, v_location, NEW.output_date, NEW.created_by);
        END IF;
    END IF;

    RETURN NULL;
END;
$function$;

-- ═══ 5 · 注销/冲销:排空所有桶 ═══════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.emit_batch_writeoff_movement()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_ctx   text := current_setting('evoltrya.movement_ctx', true);
    v_run   uuid;
    v_value numeric;
    v_acct  text;
    v_amt   numeric;
    v_bd    date;      -- FIN-32:这条流水的【业务日】
BEGIN
    IF OLD.remaining_qty > 0 THEN
        -- ════════════════════════════════════════════════════════════════════
        -- FIN-32:business_date =【这件事在业务上发生在哪一天】,与它被记进系统的
        -- 时刻是两回事。两类事,两个答案,不能共用一个:
        --
        --   * 注销(writeoff)是【真实发生的物理事件】—— 货报废了。发生在有人
        --     按下注销的那天,而那天就写在行上:deleted_at。取它的日期部分,
        --     是【读记录】而不是 CURRENT_DATE 那种【当场编一个】。
        --     (触发器只在 deleted_at 由空变非空时触发,所以它必然有值。)
        --
        --   * 冲销(reversal_void)【不是物理事件】—— 电池处理过了就处理过了,
        --     回滚是在更正一次【记错的加工单】。所以它的业务日是【原加工单的
        --     process_date】,不是今天:那样一错一改在同一天对消,中间那几天的
        --     库存历史不会凭空多出一批实际并不存在的货。
        --     会计侧的先例同向:reverse_journal_entry 把冲销日做成【显式入参】,
        --     从不假定 —— 这里没有入参可传,但答案同样来自记录(run.process_date),
        --     不来自时钟。
        --
        -- 【两个账会给出两个日期,这是知情的选择,不是疏漏】(FIN-32-fu1)
        -- 同一次更正:分录侧的冲销按【显式传入的冲销日】入账(它必须如此 ——
        -- 期间锁不许往已关闭的月份里塞东西),而这里的流水按【原加工日】。
        -- 于是一次更正在两个账里带着两个日期。这是两种账的性质不同:
        --   * 分录是【价值账,带锁】—— 它记的是"这笔更正在哪个会计期发生";
        --   * 流水是【数量账,无锁】—— 它记的是"那批货实际在不在库里"。
        -- 按日期把两个账对起来的人一定会撞上这处差异,所以写在这里:
        -- 撞上时该问的是"这两个日期各自回答的是哪个问题",不是"哪个错了"。
        -- ════════════════════════════════════════════════════════════════════
        IF TG_TABLE_NAME = 'inbound_batches' THEN
            -- IOD-1:注销排空【所有】桶,两种状态都算 —— 报废一批货,不会因为其中
            -- 一部分被扣住就留在账上。这也是三个消耗方里唯一一个必须动 on_hold 的。
            PERFORM drain_stock(
                p_qty => OLD.remaining_qty, p_movement_type => 'writeoff',
                p_business_date => NEW.deleted_at::date, p_inbound_batch_id => OLD.id,
                p_statuses => ARRAY['available','on_hold'], p_created_by => NEW.updated_by);
        ELSE  -- output_batches
            IF v_ctx IS NOT NULL AND split_part(v_ctx, ':', 1) = 'reversal' THEN
                v_run := split_part(v_ctx, ':', 2)::uuid;
                SELECT process_date INTO v_bd FROM processing_runs WHERE id = v_run;
                PERFORM drain_stock(
                    p_qty => OLD.remaining_qty, p_movement_type => 'reversal_void',
                    p_business_date => v_bd, p_output_batch_id => OLD.id,
                    p_statuses => ARRAY['available','on_hold'], p_run_id => v_run,
                    p_created_by => NEW.updated_by);
            ELSE
                PERFORM drain_stock(
                    p_qty => OLD.remaining_qty, p_movement_type => 'writeoff',
                    p_business_date => NEW.deleted_at::date, p_output_batch_id => OLD.id,
                    p_statuses => ARRAY['available','on_hold'], p_created_by => NEW.updated_by);
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
                SELECT po.unit_cost_base INTO v_value
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
                            jsonb_build_object('account_code', '5200', 'side', 'debit',  'currency', base_currency_code(), 'amount_ccy', v_amt),
                            jsonb_build_object('account_code', v_acct, 'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', v_amt)));
                END IF;
            END IF;
        END IF;

        NEW.remaining_qty := 0;
    END IF;
    RETURN NEW;
END;
$function$;

COMMIT;
