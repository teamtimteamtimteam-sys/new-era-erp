-- db/migrations/2026-08-15-so3b-fu1-partially-shipped-is-still-live.sql
-- SO-3b 收尾:一张【发了一部分】的订单仍然是活的
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【fixture 68 第一次跑就撞上的】reserve_stock 与 create_order_invoice 都只认
-- status = 'confirmed'。而 SO-3b 之后,第一次发货就把订单推成 partially_shipped
-- —— 于是【任何多行订单在第一次发货之后就再也走不下去】:剩下的行既不能预留、
-- 也不能开票,自然也发不出去。整张单卡死在中间。
--
-- 这不是一个边角情况,它是多行订单的正常路径;之所以没在写的时候被想到,是因为
-- 那两个函数的判据写的是"确认了没有",而新状态回答的是另一个问题(发完了没有)。
-- 判据应当是【这张单还活着吗】,而 confirmed 与 partially_shipped 都活着。
--
-- 【为什么是两个函数一起改】它们是同一条判断的两处落点(要预留、要开票),
-- 分开改就会留下一半能走一半不能走的状态 —— 那比两处都不能走更难查。
--
-- 【破窗】纯放宽,不撤任何东西;旧应用的路径原样可用。
-- 镜像:db/functions/{reserve_stock,create_order_invoice}.sql。
-- 行为断言:fixture 68 的 E 臂(部分发货 → 再预留 → 再发)本身就是它的回归。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION public.reserve_stock(p_sales_order_line_id uuid, p_output_batch_id uuid, p_qty numeric, p_location_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user     uuid := auth.uid();
    v_pair     uuid := gen_random_uuid();
    v_today    date := CURRENT_DATE;
    v_line     record;
    v_batch    record;
    v_avail    numeric;
    v_already  numeric;
    v_res_id   uuid;
BEGIN
    -- 【为什么是 module.sales.edit,而不是 module.inventory.edit】
    -- 预留就是一次销售行为 —— 做它的人是销售。给它挑一个"销售与库存都满足"的
    -- 权限码,只能挑一个比两者都松的,那不是把关、是把关的样子(与
    -- zzz_function_grants 给 drain_stock 写的那条理由同形)。而台账的不变量
    -- 不依赖调用者是谁:成对写入让物理总量按构造不动,check_no_negative_bucket
    -- 是约束触发器,对任何身份一视同仁。
    PERFORM require_permission('module.sales.edit');

    IF p_qty IS NULL OR p_qty <= 0 THEN
        RAISE EXCEPTION 'SO_RESERVE_QTY_INVALID|%', COALESCE(p_qty::text, '?');
    END IF;

    SELECT l.id, l.quantity, l.material_id, l.line_no,
           o.id AS order_id, o.code AS order_code, o.status, o.deleted_at
      INTO v_line
      FROM sales_order_lines l
      JOIN sales_orders o ON o.id = l.sales_order_id
     WHERE l.id = p_sales_order_line_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SO_NOT_FOUND|%', COALESCE(p_sales_order_line_id::text, '?');
    END IF;

    -- 【只有确认了的订单才预留】草稿是还没答应的事,给它扣住货,等于让一张
    -- 随手建的单据把库存冻起来,而没有任何人做过那个承诺。
    -- 【SO-3b:partially_shipped 同样算数】一张发了一部分的单【仍然是活的】——
    -- 剩下的行还要预留、还要发。只认 confirmed 会让任何多行订单在第一次发货
    -- 之后就再也走不下去(fixture 68 第一次跑就撞上了这个)。
    IF v_line.deleted_at IS NOT NULL OR v_line.status NOT IN ('confirmed', 'partially_shipped') THEN
        RAISE EXCEPTION 'SO_RESERVE_ORDER_NOT_CONFIRMED|%|%',
            v_line.order_code, COALESCE(v_line.status, '?');
    END IF;

    -- 【产出批次,且还在】—— 见本表注释:预留一个进料批次会造出永远消耗不掉的
    -- 承诺库存(movement_type='sale' 被 inventory_movements_side 钉在产出侧)。
    SELECT ob.id, ob.code, ob.material_id, ob.unit
      INTO v_batch
      FROM output_batches ob
     WHERE ob.id = p_output_batch_id AND ob.deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SO_RESERVE_OUTPUT_ONLY|%', COALESCE(p_output_batch_id::text, '?');
    END IF;

    IF v_batch.material_id IS DISTINCT FROM v_line.material_id THEN
        RAISE EXCEPTION 'SO_RESERVE_MATERIAL_MISMATCH|%|%|%',
            v_batch.code,
            (SELECT code FROM materials WHERE id = v_batch.material_id),
            (SELECT code FROM materials WHERE id = v_line.material_id);
    END IF;

    -- 【行的天花板】一行订单最多只能许出它自己的数量。超过就是把同一批货
    -- 许给同一行两次 —— 屏幕上看不出来,发货时才炸。
    SELECT COALESCE(sum(r.qty), 0) INTO v_already
      FROM sales_order_reservations r
     WHERE r.sales_order_line_id = p_sales_order_line_id AND r.released_at IS NULL AND r.consumed_at IS NULL;
    IF v_already + p_qty > v_line.quantity THEN
        RAISE EXCEPTION 'SO_RESERVE_EXCEEDS_LINE|%|%|%', p_qty, v_line.quantity, v_already;
    END IF;

    -- 【就地求和,不调 derived_stock_qty】那个函数体里有
    -- require_permission('module.inventory.view'),而 has_permission 解析的是
    -- 【调用者】的 JWT —— DEFINER 换得了行的可见性,换不了函数体内那句对调用者
    -- 的判断。销售的人没有库存的码,调过去当场 PERMISSION_DENIED。
    -- record_output_sale 就地求和,同一个理由。
    SELECT COALESCE(sum(m.qty_delta), 0) INTO v_avail
      FROM inventory_movements m
     WHERE m.output_batch_id = p_output_batch_id
       AND m.inbound_batch_id IS NULL
       AND m.location_id IS NOT DISTINCT FROM p_location_id
       AND m.stock_status = 'available';
    IF p_qty > v_avail THEN
        RAISE EXCEPTION 'SO_RESERVE_EXCEEDS_AVAILABLE|%|%', p_qty, v_avail;
    END IF;

    -- 成对:出 available、进 committed。同批次、同库位。物理总量按构造不动,
    -- remaining_qty 一个字不变,批次的 state 也不变(承诺不是销售)。
    INSERT INTO inventory_movements
        (output_batch_id, location_id, movement_type,
         qty_delta, stock_status, pair_id, business_date, notes, created_by)
    VALUES
        (p_output_batch_id, p_location_id, 'status_change_out',
         -p_qty, 'available', v_pair, v_today,
         'reserved for ' || v_line.order_code || ' line ' || v_line.line_no, v_user),
        (p_output_batch_id, p_location_id, 'status_change_in',
          p_qty, 'committed', v_pair, v_today,
         'reserved for ' || v_line.order_code || ' line ' || v_line.line_no, v_user);

    INSERT INTO sales_order_reservations
        (sales_order_line_id, output_batch_id, location_id, qty, pair_id, created_by)
    VALUES (p_sales_order_line_id, p_output_batch_id, p_location_id, p_qty, v_pair, v_user)
    RETURNING id INTO v_res_id;

    INSERT INTO sales_order_history (sales_order_id, change_type, detail)
    VALUES (v_line.order_id, 'reserved',
            format('line %s · %s %s %s', v_line.line_no, v_batch.code, p_qty, v_batch.unit));

    RETURN jsonb_build_object(
        'reservation_id', v_res_id, 'pair_id', v_pair, 'qty', p_qty,
        'output_batch_id', p_output_batch_id, 'location_id', p_location_id,
        'available_after', v_avail - p_qty,
        'line_reserved_after', v_already + p_qty,
        'line_quantity', v_line.quantity);
END;
$function$;

CREATE OR REPLACE FUNCTION public.create_order_invoice(p_sales_order_id uuid, p_issue_date date, p_payment_terms_days integer DEFAULT NULL::integer, p_notes text DEFAULT NULL::text, p_terms_text text DEFAULT NULL::text, p_line_ids uuid[] DEFAULT NULL::uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_order    sales_orders%ROWTYPE;
    v_cust     customers%ROWTYPE;
    v_terms    integer;
    v_due      date;
    v_invoice_id uuid := gen_random_uuid();
    v_year     integer;
    v_seq      integer;
    v_code     text;
    v_line     record;
    v_no       integer := 0;
    v_sub_ccy  numeric := 0;
    v_sub_base numeric;
    v_gst_on   boolean;
    v_gst_rate numeric;
    v_tax_rate numeric := 0;
    v_tax      numeric := 0;
    v_existing text;
    v_exposure numeric;
    v_lines    jsonb := '[]'::jsonb;
    v_l        jsonb;
    v_je       jsonb;
    v_bad      int;
BEGIN
    -- 【权限:module.finance.edit,与 create_invoice 同一个码 —— 想过 B4(b) 那条路】
    -- "检查正在做的那件事"的规矩会指向 module.sales.edit(开票是订单流的一步);
    -- 但同一种单据(invoices)由两个码把门,是给下一个人埋的判断分叉 —— sale 头
    -- 已经是 finance.edit,而这张票【过账】,比 sale 头更财务而不是更不。
    -- 订单页上的按钮按持码与否显示/受限,不把人骗去撞一次拒绝。
    PERFORM require_permission('module.finance.edit');

    -- 【开票日必填 —— 它决定分录期间】sale 头的默认今天记录在
    -- docs/empty-string-to-rpc-audit.md(那种发票不过账);这张过账,按日期规矩拒。
    IF p_issue_date IS NULL THEN
        RAISE EXCEPTION 'INVOICE_DATE_REQUIRED';
    END IF;

    SELECT * INTO v_order FROM sales_orders WHERE id = p_sales_order_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SO_NOT_FOUND|%', COALESCE(p_sales_order_id::text, '?');
    END IF;
    -- 【只对确认单开票】草稿还不是承诺;作废/关闭的单没有可开的东西。
    -- 【SO-3b:partially_shipped 同样算数】发了一部分的单仍然是活的,剩下的行
    -- 还要开票才发得出去 —— 与 reserve_stock 同一条(fixture 68 撞出来的)。
    IF v_order.status NOT IN ('confirmed', 'partially_shipped') THEN
        RAISE EXCEPTION 'SO_INVOICE_ORDER_NOT_CONFIRMED|%|%', v_order.code, v_order.status;
    END IF;

    -- 【客户是订单的客户,不是参数】—— 让开票替人改收票方,就是 SAL-C 修掉的
    -- 那种归属错位的反向版本。
    SELECT * INTO v_cust FROM customers WHERE id = v_order.customer_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CUSTOMER_NOT_FOUND|%', v_order.customer_id;
    END IF;

    v_terms := COALESCE(p_payment_terms_days, v_cust.payment_terms_days, 30);
    IF v_terms < 0 THEN
        RAISE EXCEPTION 'TERMS_INVALID|%', v_terms;
    END IF;
    v_due := p_issue_date + v_terms;

    -- 【显式子集必须整个属于这张单】—— 混进别的单的行 id,静默跳过等于把
    -- "开了哪些行"变成猜测。
    IF p_line_ids IS NOT NULL THEN
        SELECT count(*) INTO v_bad FROM unnest(p_line_ids) x
         WHERE NOT EXISTS (SELECT 1 FROM sales_order_lines l
                            WHERE l.id = x AND l.sales_order_id = p_sales_order_id);
        IF v_bad > 0 THEN
            RAISE EXCEPTION 'SO_INVOICE_LINE_INVALID|%|%', v_order.code, v_bad;
        END IF;
    END IF;

    FOR v_line IN
        SELECT l.id, l.line_no AS order_line_no, l.quantity, l.unit_price,
               m.code AS mat_code, m.name AS mat_name, m.unit AS mat_unit
        FROM sales_order_lines l
        JOIN materials m ON m.id = l.material_id
        WHERE l.sales_order_id = p_sales_order_id
          AND (p_line_ids IS NULL OR l.id = ANY (p_line_ids))
        ORDER BY l.line_no
    LOOP
        -- 友好检查;硬保证是 uq_invoice_lines_live_order_line(索引管正确性,
        -- 这里管可读性 —— 与销售侧 ALREADY_INVOICED 逐字同一个分工)。
        SELECT i.code INTO v_existing
        FROM invoice_lines il
        JOIN invoices i ON i.id = il.invoice_id
        WHERE il.sales_order_line_id = v_line.id AND NOT il.invoice_voided
        LIMIT 1;
        IF FOUND THEN
            IF p_line_ids IS NULL THEN
                CONTINUE;   -- "全部未开"的口径:已开的行自然跳过
            END IF;
            -- 点名要求开一条已开的行 → 按名拒,说出它在哪张票上
            RAISE EXCEPTION 'SO_LINE_ALREADY_INVOICED|%|%', v_line.order_line_no, v_existing;
        END IF;

        v_no := v_no + 1;
        v_lines := v_lines || jsonb_build_object(
            'sales_order_line_id', v_line.id,
            'line_no', v_no,
            'description', v_line.mat_code || ' — ' || v_line.mat_name,
            'quantity', v_line.quantity,
            'unit', v_line.mat_unit,
            'unit_price', v_line.unit_price,
            'amount_ccy', round(v_line.quantity * v_line.unit_price, 2));
        v_sub_ccy := v_sub_ccy + round(v_line.quantity * v_line.unit_price, 2);
    END LOOP;

    IF v_no = 0 THEN
        RAISE EXCEPTION 'SO_INVOICE_NOTHING_TO_BILL|%', v_order.code;
    END IF;

    -- 【GST:明确不支持,不是悄悄算错】预收发票的销项税时点与科目没人回答过;
    -- 公司未登记(税率恒 0),这条今天不可达 —— 但"不可达"不是"不用拒"。
    SELECT gst_registered, gst_rate_pct INTO v_gst_on, v_gst_rate FROM finance_settings LIMIT 1;
    IF COALESCE(v_gst_on, false) THEN
        v_tax_rate := COALESCE(v_gst_rate, 0);
        v_tax := round(v_sub_ccy * v_tax_rate / 100.0, 2);
    END IF;
    IF v_tax <> 0 THEN
        RAISE EXCEPTION 'INVOICE_ORDER_GST_UNSUPPORTED|%', v_order.code;
    END IF;

    v_sub_ccy := round(v_sub_ccy, 2);
    -- 头上的本位币额与分录同式:round(Σccy × fx)。行的 amount_base 逐行取整,
    -- 是显示口径 —— 头对分录,行对纸面,两者相差不超过几分且各自自洽。
    v_sub_base := round(v_sub_ccy * v_order.fx_rate, 2);

    -- 【信用闸在这里 —— 产生敞口的是开票】确认订单只看 credit_hold(那里的注释
    -- 说了为什么);额度对着"敞口 + 本票"判,敞口含已过账未结清的订单流发票
    -- (customer_ar_exposure_base 的第二项,本刀加的)。消息四个数说全,
    -- 与 record_output_sale 同形。
    IF v_cust.credit_hold THEN
        RAISE EXCEPTION 'CREDIT_HOLD|%', v_cust.code;
    END IF;
    IF v_cust.credit_limit_base IS NOT NULL THEN
        v_exposure := customer_ar_exposure_base(v_cust.id);
        IF v_exposure + v_sub_base > v_cust.credit_limit_base THEN
            RAISE EXCEPTION 'CREDIT_LIMIT_EXCEEDED|%|%|%|%',
                v_cust.code, v_cust.credit_limit_base, v_exposure, v_sub_base;
        END IF;
    END IF;

    -- 【无缝编号,与 create_invoice 同一把锁】真正的互斥点是 advisory key
    -- 'invoice_code_<year>' 这个字符串 —— 两个函数必须逐字同一把;MAX+1 只是推导。
    v_year := EXTRACT(YEAR FROM p_issue_date)::integer;
    PERFORM pg_advisory_xact_lock(hashtext('invoice_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1 INTO v_seq
    FROM invoices WHERE code LIKE 'INV-' || v_year::text || '-%';
    v_code := 'INV-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');

    -- 【过账:借 1100 应收 / 贷 2500 合同负债】单据币种,按订单抄来的汇率。
    -- 期间锁/年结闸由 post_journal_entry 对 p_issue_date 统一执行。
    v_je := post_journal_entry(
        p_issue_date,
        'Invoice ' || v_code || ' · ' || v_order.code,
        'invoice', v_invoice_id,
        jsonb_build_array(
            jsonb_build_object('account_code', '1100', 'side', 'debit',
                'currency', v_order.currency, 'amount_ccy', v_sub_ccy, 'fx_rate', v_order.fx_rate),
            jsonb_build_object('account_code', '2500', 'side', 'credit',
                'currency', v_order.currency, 'amount_ccy', v_sub_ccy, 'fx_rate', v_order.fx_rate)));

    INSERT INTO invoices (id, code, customer_id, issue_date, due_date, payment_terms_days,
                          currency, subtotal_base, tax_rate_pct, tax_base, total_base,
                          notes, terms_text, bill_to_snapshot,
                          kind, sales_order_id, entry_id, fx_rate)
    VALUES (v_invoice_id, v_code, v_cust.id, p_issue_date, v_due, v_terms,
            v_order.currency, v_sub_base, v_tax_rate, 0, v_sub_base,
            p_notes, p_terms_text,
            jsonb_build_object(
                'code', v_cust.code,
                'legal_name', v_cust.legal_name,
                'short_name', v_cust.short_name,
                'country', v_cust.country,
                'tax_id', v_cust.tax_id,
                'address', v_cust.address,
                'payment_terms', v_cust.payment_terms,
                'incoterm', v_cust.incoterm,
                'contact_person', v_cust.contact_person,
                'email', v_cust.email,
                'phone', v_cust.phone),
            'order', p_sales_order_id, (v_je->>'entry_id')::uuid, v_order.fx_rate);

    FOR v_l IN SELECT * FROM jsonb_array_elements(v_lines)
    LOOP
        INSERT INTO invoice_lines (invoice_id, sales_order_line_id, line_no, description,
                                   quantity, unit, unit_price, amount_base)
        VALUES (v_invoice_id,
                (v_l->>'sales_order_line_id')::uuid,
                (v_l->>'line_no')::integer,
                v_l->>'description',
                (v_l->>'quantity')::numeric,
                v_l->>'unit',
                (v_l->>'unit_price')::numeric,
                round((v_l->>'amount_ccy')::numeric * v_order.fx_rate, 2));
    END LOOP;

    -- 开票进订单的历史 —— 订单流先开票后发货,"开过没有"是看订单的人的问题。
    INSERT INTO sales_order_history (sales_order_id, change_type, detail, changed_by)
    VALUES (p_sales_order_id, 'invoiced', v_code, auth.uid());

    RETURN jsonb_build_object(
        'invoice_id', v_invoice_id,
        'code', v_code,
        'issue_date', p_issue_date,
        'due_date', v_due,
        'currency', v_order.currency,
        'fx_rate', v_order.fx_rate,
        'subtotal_ccy', v_sub_ccy,
        'total_base', v_sub_base,
        'line_count', v_no,
        'journal_code', v_je->>'code');
END;
$function$;

COMMIT;
