-- 66 一次销售有几条腿就记几条(SO-2b 之二):单值外键装不下多条腿
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【这份 fixture 钉住的三件事】
--   ① 一次【跨桶】的销售写出【多条】出库流水,而腿表一条不少地记下它们:
--      条数对得上、数量之和【正好】等于销售数量。C 臂。
--      这正是 sales_records.movement_id 十几周里做不到的事 —— 它只装得下
--      排空顺序上碰巧第一的那条,而屏幕上没有任何东西会显得不对。
--   ② 那一列【真的没有了】。B 臂是一条目录断言:有人把它加回来当"主腿",
--      这一条当场红。留着它就是一个永久的半真:两个真相源里有一个是半真的,
--      读的人没有办法知道自己拿到的是哪一个。
--   ③ 腿是台账的一部分:只增不改、客户端写不进、一条流水只能属于一次销售。
--      D/E/F 臂。
--
-- 各臂:
--   A 前提:腿表在;跨桶的货真的摆成了两个桶(否则 C 臂会退化成单桶而空转)
--   B 目录:sales_records 上【没有】 movement_id 这一列
--   C 跨桶销售:N 条腿,∑|qty_delta| = 销售数量,每条都是本批次的 sale 腿
--   D 只增不改:UPDATE / DELETE 按名拒(SALE_LEG_IMMUTABLE)
--   E 客户端写不进:切库角色直插被拒(不切就是空话)
--   F 一条流水只能属于一次销售:重复认领撞 UNIQUE
--   G 注入:把写入者换回"只记第一条腿" → C 臂的等式当场不成立
--
-- 期间锁显式设成 NULL(README 第 5 条)。自带数据(第 2 条)。
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid; v_cust uuid; v_mat uuid; v_ccy text;
    loc_a uuid; loc_b uuid;
    ob1 uuid; ob2 uuid;
    v_sale uuid; v_n int; v_sum numeric; v_ok boolean; v_msg text;
    v_leg uuid; v_mov uuid;
    d date := CURRENT_DATE;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-66', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    UPDATE finance_settings SET locked_before = NULL;
    SELECT code INTO v_ccy FROM currencies WHERE is_base;

    INSERT INTO customers (code, legal_name, country)
    VALUES ('ZZ66-C1', 'fixture 66 customer', 'SG') RETURNING id INTO v_cust;
    INSERT INTO materials (code, name, kind_code, may_be_processed, unit)
    VALUES ('ZZFIX66-M', 'f66 material', 'battery_material', true, 'kg') RETURNING id INTO v_mat;
    INSERT INTO storage_locations (code, name) VALUES ('ZZ66-A', 'f66 A') RETURNING id INTO loc_a;
    INSERT INTO storage_locations (code, name) VALUES ('ZZ66-B', 'f66 B') RETURNING id INTO loc_b;

    -- 【把货摆成两个桶】—— IOD-1 之后这是可构造的:收进 A,再转 40 到 B。
    ob1 := (create_output_batch(v_mat, 100, 'kg', d, '库存中', NULL, NULL, NULL, loc_a) ->> 'batch_id')::uuid;
    PERFORM create_stock_transfer(40, loc_b, NULL, ob1, loc_a, 'available', 'f66 split');

    -- ══════════ A. 前提 ═════════════════════════════════════════════════════
    IF to_regclass('public.sales_record_movements') IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 66A 失败:sales_record_movements 不在';
    END IF;
    -- 【两个桶必须真的存在】否则 C 臂会退化成一次单桶销售,"多条腿"这件事
    -- 一次也没有被走到 —— 而它正是这份 fixture 的全部理由(空转的反面)。
    SELECT count(*) INTO v_n FROM stock_by_status
     WHERE output_batch_id = ob1 AND stock_status = 'available' AND qty > 0;
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 66A 失败:前提是货分在【两个】库位桶里,实得 % 个 —— C 臂会退化成单桶,等于空转', v_n;
    END IF;

    -- ══════════ B. 目录:那一列没有了 ═══════════════════════════════════════
    -- 【一条目录断言,不是一条行为断言】有人把 movement_id 加回来当"主腿",
    -- 所有行为断言仍然会绿 —— 半真的那一列不影响腿表工作,它只是让读的人
    -- 在两个真相源之间没法分辨。所以只有这一条能拦住它。
    IF EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema = 'public' AND table_name = 'sales_records'
                  AND column_name = 'movement_id') THEN
        RAISE EXCEPTION 'FIXTURE 66B 失败:sales_records.movement_id 又回来了 —— 一个单值外键装不下多条腿,留着它就是一个永久的半真';
    END IF;

    -- ══════════ C. 跨桶销售:腿一条不少,数量之和正好 ═════════════════════════
    PERFORM record_output_sale(ob1, 100, 5, v_ccy, NULL, v_cust, d, 'f66 cross-bucket');
    SELECT id INTO v_sale FROM sales_records WHERE output_batch_id = ob1;

    SELECT count(*), COALESCE(sum(abs(m.qty_delta)), 0) INTO v_n, v_sum
      FROM sales_record_movements srm JOIN inventory_movements m ON m.id = srm.movement_id
     WHERE srm.sales_record_id = v_sale;
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 66C 失败:货分在两个桶里,一次卖光应当写出【2 条】腿,实得 %', v_n;
    END IF;
    IF v_sum <> 100 THEN
        RAISE EXCEPTION 'FIXTURE 66C 失败:各条腿的数量之和必须【正好】等于销售数量 100,实得 % —— 差额就是台账上没有主人的那一段出库', v_sum;
    END IF;
    -- 每一条腿都必须是【本批次的 sale 腿】,不是随便一条流水
    SELECT count(*) INTO v_n
      FROM sales_record_movements srm JOIN inventory_movements m ON m.id = srm.movement_id
     WHERE srm.sales_record_id = v_sale
       AND (m.movement_type <> 'sale' OR m.output_batch_id IS DISTINCT FROM ob1);
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 66C 失败:有 % 条腿指向的不是本批次的 sale 流水', v_n;
    END IF;
    -- 反过来也要成立:这批货的每一条 sale 流水都被认领了(没有孤儿腿)
    SELECT count(*) INTO v_n FROM inventory_movements m
     WHERE m.output_batch_id = ob1 AND m.movement_type = 'sale'
       AND NOT EXISTS (SELECT 1 FROM sales_record_movements srm WHERE srm.movement_id = m.id);
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 66C 失败:这批货有 % 条 sale 流水没有被任何销售记录认领', v_n;
    END IF;

    -- ══════════ D. 只增不改 ══════════════════════════════════════════════════
    SELECT srm.id, srm.movement_id INTO v_leg, v_mov
      FROM sales_record_movements srm WHERE srm.sales_record_id = v_sale LIMIT 1;
    BEGIN
        UPDATE sales_record_movements SET movement_id = gen_random_uuid() WHERE id = v_leg;
        RAISE EXCEPTION 'FIXTURE 66D 失败:腿改得动 —— 改一条腿指向别的流水,等于把一笔已经发生的出库改记到另一批货上';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'SALE_LEG_IMMUTABLE%' THEN RAISE; END IF;
    END;
    BEGIN
        DELETE FROM sales_record_movements WHERE id = v_leg;
        RAISE EXCEPTION 'FIXTURE 66D 失败:腿删得掉';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'SALE_LEG_IMMUTABLE%' THEN RAISE; END IF;
    END;

    -- ══════════ E. 客户端写不进(切库角色,否则是空话)══════════════════════
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_ok := false;
    BEGIN
        INSERT INTO sales_record_movements (sales_record_id, movement_id)
        VALUES (v_sale, (SELECT id FROM inventory_movements
                          WHERE output_batch_id = ob1 AND movement_type = 'processing_produce' LIMIT 1));
        v_ok := true;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
    END;
    RESET ROLE;
    IF v_ok THEN
        RAISE EXCEPTION 'FIXTURE 66E 失败:authenticated 直插进了一条腿 —— 那张表存在的全部意义就是它与流水说的是同一件事,而直插的腿不受任何约束';
    END IF;

    -- ══════════ F. 一条流水只能属于一次销售 ══════════════════════════════════
    BEGIN
        INSERT INTO sales_record_movements (sales_record_id, movement_id) VALUES (v_sale, v_mov);
        RAISE EXCEPTION 'FIXTURE 66F 失败:同一条流水被认领了两次 —— "这批货卖了几次"就再也答不上来';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;

    -- ══════════ G. 注入:换回"只记第一条腿" → C 臂的等式当场不成立 ═════════════
    -- 【为什么要这一臂】C 臂断言的是一个【和】。一个只写第一条腿的实现,在
    -- 单桶销售上与正确实现完全一致 —— 这份 fixture 之所以要费力把货摆成两个桶,
    -- 就是为了让这两种实现能被区分开。这一臂把旧行为原样装回来,证明那个和
    -- 真的在挡:不是"反正它总会相等"。
    ob2 := (create_output_batch(v_mat, 100, 'kg', d, '库存中', NULL, NULL, NULL, loc_a) ->> 'batch_id')::uuid;
    PERFORM create_stock_transfer(40, loc_b, NULL, ob2, loc_a, 'available', 'f66 split 2');

    EXECUTE $inj$
        CREATE OR REPLACE FUNCTION public.record_output_sale_legs_first_only(p_output_batch_id uuid, p_qty numeric, p_date date)
         RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
        AS $f$
        DECLARE v_ids uuid[]; v_sale uuid; v_n int;
        BEGIN
            -- 旧行为的最小复刻:排空写出多行,但【只认领第一条】
            v_ids := drain_stock(p_qty => p_qty, p_movement_type => 'sale', p_business_date => p_date,
                                 p_output_batch_id => p_output_batch_id, p_statuses => ARRAY['available']);
            INSERT INTO sales_records (output_batch_id, quantity, unit_price, currency, fx_rate, amount_base, sale_date)
            VALUES (p_output_batch_id, p_qty, 5, base_currency_code(), 1, p_qty * 5, p_date)
            RETURNING id INTO v_sale;
            INSERT INTO sales_record_movements (sales_record_id, movement_id) VALUES (v_sale, v_ids[1]);
            UPDATE output_batches SET remaining_qty = remaining_qty - p_qty WHERE id = p_output_batch_id;
            SELECT count(*) INTO v_n FROM sales_record_movements WHERE sales_record_id = v_sale;
            RETURN v_n;
        END;
        $f$;
    $inj$;
    SELECT record_output_sale_legs_first_only(ob2, 100, d) INTO v_n;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 66G 失败:注入的旧行为应当只写 1 条腿,实得 % —— 那说明这一臂没有复刻出旧缺陷', v_n;
    END IF;
    SELECT COALESCE(sum(abs(m.qty_delta)), 0) INTO v_sum
      FROM sales_record_movements srm JOIN inventory_movements m ON m.id = srm.movement_id
      JOIN sales_records s ON s.id = srm.sales_record_id
     WHERE s.output_batch_id = ob2;
    IF v_sum = 100 THEN
        RAISE EXCEPTION 'FIXTURE 66G 失败:只记第一条腿之后,数量之和【仍然】等于 100 —— 说明 C 臂那个等式一直会相等,它在空转';
    END IF;
    IF v_sum <> 60 THEN
        RAISE EXCEPTION 'FIXTURE 66G 失败:只记第一条腿应当只覆盖 A 桶那 60,实得 %', v_sum;
    END IF;
END $$;
ROLLBACK;
