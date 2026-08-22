-- 25 库存流水的业务日:每条写入路径都写,且写的是【那件事发生在哪一天】
--
-- 为什么值得常设(FIN-32):business_date 与 created_at 是两回事 —— 前者是货那天
-- 到的 / 那天被处理的,后者是有人那天把它敲进系统。补之前 58% 为空,而空得很有
-- 规律:writeoff / reversal_void / reversal_restore 【100% 空】(压根没写),
-- receipt 80% 空(抄的 arrival_date 本身可空)。Phase 2 的出入库单据、状态区分的
-- 库存、库位管理都要靠这一列,而那时表里已经有数据 —— 空值再也补不回真话。
--
-- 【本 fixture 钉住的两件事】
--   ① 每条路径都写,且写的是【记录里的那个日期】,不是 now();
--   ② 冲销/还原写的是【原加工单的加工日】,不是今天 —— 这是一个决定,
--      所以按名断言:回滚不是物理事件(电池处理过了就是处理过了),它在更正一次
--      记错的加工单,于是一错一改在同一天对消,中间那几天的库存历史不会凭空
--      多出或少掉一批货。写成"今天"的实现,本 fixture 当场红。
-- FIN-36:commit_processing_run 多了一个【必填】的分摊基准参数。
-- 这里一律显式传 'metal_value' —— 那正是本 fixture 在 FIN-36 之前从 schema
-- 默认值拿到的值,所以语义一字未变,只是不再有人替它做这个选择。
BEGIN;
DO $$
DECLARE
    v_uid uuid := gen_random_uuid(); v_role uuid;
    v_sup uuid; v_cust uuid; v_mat uuid; v_matB uuid;
    v_ib uuid; v_ib2 uuid; v_ib3 uuid; v_run uuid; v_run2 uuid; v_ob uuid; v_ob2 uuid; v_st uuid;
    v_arrival date := CURRENT_DATE - 20;   -- 货是 20 天前到的
    v_process date := CURRENT_DATE - 10;   -- 10 天前加工
    v_sale    date := CURRENT_DATE - 5;    -- 5 天前卖掉一部分
    v_bd date; v_n integer; v_msg text; v_ok boolean;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-25', 'fixture', 'fixture', true) RETURNING id INTO v_role;
    INSERT INTO role_permissions (role_id, permission_code) SELECT v_role, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_uid, v_role);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_uid), true);
    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO suppliers (code, legal_name, country, counterparty_type) VALUES ('FIXT-S25','Fixture Supplier 25','SG', 'goods_supplier')
        RETURNING id INTO v_sup;
    INSERT INTO customers (code, legal_name, country) VALUES ('FIXT-C25','Fixture Customer 25','SG')
        RETURNING id INTO v_cust;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code) VALUES ('FIXT-M25','Fixture Raw 25', 'battery_material', true, 'black_mass', 'end_of_life')
        RETURNING id INTO v_mat;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code) VALUES ('FIXT-M25B','Fixture Fine 25', 'battery_material', true, 'black_mass', 'end_of_life')
        RETURNING id INTO v_matB;

    -- ════════ A. receipt:抄批次自己的到货日,不是今天 ═══════════════════════
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date)
    VALUES ('FIXT-IB25', v_mat, v_sup, 100, 100, 'kg', v_arrival) RETURNING id INTO v_ib;
    SELECT business_date INTO v_bd FROM inventory_movements
    WHERE inbound_batch_id = v_ib AND movement_type = 'receipt';
    IF v_bd IS DISTINCT FROM v_arrival THEN
        RAISE EXCEPTION 'FIXTURE 25A 失败:收货流水的业务日应为到货日 %,实得 %(= 今天说明抄的是时钟而不是记录)',
            v_arrival, COALESCE(v_bd::text,'NULL');
    END IF;

    -- ════════ B. processing_consume / processing_produce:加工日 ═════════════
    PERFORM reprice_inbound_batch(v_ib, 1, 'SGD', NULL, 'fixture 25 price');
    -- PROC-3:这一支要投料,所以它的电池料批次得带一条【可投料】的安全状态。
    -- 【为什么是一条带 JOIN 的 SELECT,而不是逐个批次写死】本支里哪些批次【吃】
    -- 状态轴,由 material_kinds 回答 —— 实测 ewaste 可加工却【没有】状态轴,
    -- 所以"可加工"并不蕴含"有状态轴"。而没有状态轴的批次插安全状态会被
    -- PROC-2c 的适用性守卫按名拒,所以这个过滤不是优化,是正确性。
    -- 【它出现在每一次投料之前,而不是只在开头一次】批次是各臂【边跑边造】的,
    -- 开头那一次覆盖不到后面才出生的批次。NOT EXISTS 让它重复执行也不撞主键。
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    SELECT ib.id, 'discharged_verified'
      FROM inbound_batches ib
      JOIN materials m       ON m.id   = ib.material_id
      JOIN material_kinds mk ON mk.code = m.kind_code
     WHERE mk.has_condition_axes
       AND NOT EXISTS (SELECT 1 FROM inbound_batch_safety_states s
                        WHERE s.inbound_batch_id = ib.id);
    v_run := commit_processing_run(v_process, 'fixture 25 run', 0,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib, 'quantity_consumed', 100)),
        jsonb_build_array(jsonb_build_object('material_id', v_matB, 'quantity', 100)), 'metal_value');
    SELECT output_batch_id INTO v_ob FROM processing_outputs WHERE run_id = v_run;

    SELECT business_date INTO v_bd FROM inventory_movements
    WHERE inbound_batch_id = v_ib AND movement_type = 'processing_consume';
    IF v_bd IS DISTINCT FROM v_process THEN
        RAISE EXCEPTION 'FIXTURE 25B 失败:消耗流水的业务日应为加工日 %,实得 %', v_process, COALESCE(v_bd::text,'NULL');
    END IF;
    SELECT business_date INTO v_bd FROM inventory_movements
    WHERE output_batch_id = v_ob AND movement_type = 'processing_produce';
    IF v_bd IS DISTINCT FROM v_process THEN
        RAISE EXCEPTION 'FIXTURE 25B 失败:产出流水的业务日应为加工日 %(产出批的 output_date 即加工日),实得 %',
            v_process, COALESCE(v_bd::text,'NULL');
    END IF;

    -- ════════ C. sale:销售日 ════════════════════════════════════════════════
    PERFORM record_output_sale(v_ob, 30, 10, 'SGD', NULL, v_cust, v_sale, NULL);
    SELECT business_date INTO v_bd FROM inventory_movements
    WHERE output_batch_id = v_ob AND movement_type = 'sale';
    IF v_bd IS DISTINCT FROM v_sale THEN
        RAISE EXCEPTION 'FIXTURE 25C 失败:销售流水的业务日应为销售日 %,实得 %', v_sale, COALESCE(v_bd::text,'NULL');
    END IF;

    -- ════════ D. writeoff:注销那天(deleted_at 的日期)══════════════════════
    -- 【真实物理事件】货报废在那一天,而那一天就写在行上 —— 读记录,不是当场编。
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date)
    VALUES ('FIXT-IB25W', v_mat, v_sup, 50, 50, 'kg', v_arrival) RETURNING id INTO v_ib2;
    -- AUDEL-1b:软删只能走门
    PERFORM soft_delete_inbound_batch(v_ib2, 'fixture:AUDEL-1b 之后理由必填');
    SELECT business_date INTO v_bd FROM inventory_movements
    WHERE inbound_batch_id = v_ib2 AND movement_type = 'writeoff';
    IF v_bd IS DISTINCT FROM CURRENT_DATE THEN
        RAISE EXCEPTION 'FIXTURE 25D 失败:注销流水的业务日应为注销当天(deleted_at 的日期)%,实得 % —— 它必须来自行上的 deleted_at,不是留空',
            CURRENT_DATE, COALESCE(v_bd::text,'NULL');
    END IF;

    -- ════════ E. adjustment:盘点过账日 ══════════════════════════════════════
    INSERT INTO stocktakes (code, status, created_by, updated_by)
    VALUES ('FIXT-ST25', 'open', v_uid, v_uid) RETURNING id INTO v_st;
    INSERT INTO stocktake_lines (stocktake_id, output_batch_id, book_qty, counted_qty, created_by)
    VALUES (v_st, v_ob, 70, 65, v_uid);
    PERFORM post_stocktake(v_st);
    SELECT business_date INTO v_bd FROM inventory_movements
    WHERE output_batch_id = v_ob AND movement_type = 'adjustment';
    IF v_bd IS DISTINCT FROM CURRENT_DATE THEN
        RAISE EXCEPTION 'FIXTURE 25E 失败:盘点调整的业务日应为过账日 %,实得 % —— stocktakes 表上没有盘点日字段,这是目前唯一可取的来源(Phase 2 补了盘点日就改这里)',
            CURRENT_DATE, COALESCE(v_bd::text,'NULL');
    END IF;

    -- ════════ F. 冲销/还原:【原加工单的加工日,不是今天】═════════════════════
    -- 这是本切的那个决定,所以按名断言。回滚不是物理事件 —— 电池处理过了就是
    -- 处理过了;它在更正一次记错的加工单。取原加工日,消耗与还原在同一天对消,
    -- 中间那几天的库存历史不会凭空少掉一批实际还在的货。
    -- 写成 CURRENT_DATE 的实现在这里当场红(v_process 是 10 天前)。
    --
    -- 【本臂自带一炉】前面那一炉的产出已经卖掉一部分、又被盘点调过,
    -- rollback 会按 OUTPUT_CONSUMED 拒绝 —— 那是它该拒的。回滚要测的是日期,
    -- 不是那道守卫,所以另起一炉、一样的加工日、不碰它的产出。
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date)
    VALUES ('FIXT-IB25R', v_mat, v_sup, 40, 40, 'kg', v_arrival) RETURNING id INTO v_ib3;
    PERFORM reprice_inbound_batch(v_ib3, 1, 'SGD', NULL, 'fixture 25 rollback price');
    -- PROC-3:同上 —— 这一臂之前又造了新批次,补上可投料的安全状态。
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    SELECT ib.id, 'discharged_verified'
      FROM inbound_batches ib
      JOIN materials m       ON m.id   = ib.material_id
      JOIN material_kinds mk ON mk.code = m.kind_code
     WHERE mk.has_condition_axes
       AND NOT EXISTS (SELECT 1 FROM inbound_batch_safety_states s
                        WHERE s.inbound_batch_id = ib.id);
    v_run2 := commit_processing_run(v_process, 'fixture 25 rollback run', 0,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib3, 'quantity_consumed', 40)),
        jsonb_build_array(jsonb_build_object('material_id', v_matB, 'quantity', 40)), 'metal_value');
    SELECT output_batch_id INTO v_ob2 FROM processing_outputs WHERE run_id = v_run2;

    PERFORM rollback_processing_run(v_run2, 'fixture:AUDEL-1b 之后理由必填');

    SELECT business_date INTO v_bd FROM inventory_movements
    WHERE inbound_batch_id = v_ib3 AND movement_type = 'reversal_restore';
    IF v_bd IS DISTINCT FROM v_process THEN
        RAISE EXCEPTION 'FIXTURE 25F 失败:还原流水的业务日应为【原加工日】%,实得 % —— 写成今天会让中间那 10 天的库存历史凭空少掉这批货',
            v_process, COALESCE(v_bd::text,'NULL');
    END IF;
    SELECT business_date INTO v_bd FROM inventory_movements
    WHERE output_batch_id = v_ob2 AND movement_type = 'reversal_void';
    IF v_bd IS DISTINCT FROM v_process THEN
        RAISE EXCEPTION 'FIXTURE 25F 失败:冲销流水的业务日应为【原加工日】%,实得 % —— 同上,一错一改必须在同一天对消',
            v_process, COALESCE(v_bd::text,'NULL');
    END IF;

    -- ════════ G. 新行必填(NOT VALID 约束对新插入生效)═══════════════════════
    -- 存量空值不回填、原样留着;而【从今往后】少了业务日就插不进来。
    v_ok := false; v_msg := NULL;
    BEGIN
        INSERT INTO inventory_movements (inbound_batch_id, movement_type, qty_delta, created_by)
        VALUES (v_ib, 'adjustment', 1, v_uid);
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        v_ok := v_msg LIKE '%business_date%' OR v_msg LIKE '%inventory_movements_business_date_required%';
    END;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'FIXTURE 25G 失败:不带业务日的新流水应被约束拒绝,实得:%',
            COALESCE(v_msg, '(插进去了 —— 那条 NOT VALID 约束没生效)');
    END IF;

    -- ════════ H. 三个建批次入口:少了日期【按名】拒绝,而不是漏出约束原文 ══════
    -- 【这一臂是一次手走查出来的】(IOD-2-fu1)。G 臂证明了约束会拦住,但拦住
    -- 之后操作员在屏幕上看到的是:
    --     Save failed: new row for relation inventory_movements violates
    --     check constraint inventory_movements_business_date_required
    -- —— 一句数据库约束原文。app 那一层的守卫是好的(它拦得住),可【守卫成对】
    -- 的另一半本该在 RPC 自己身上,而那半边当时是空的:任何不经过表单的调用者
    -- (curl、导入脚本、装着旧 action id 的浏览器)都一路走到 CHECK 上。
    --
    -- 所以这里断言的是【名字】,不是"被拒了"。G 臂管"拦不拦得住",H 臂管
    -- "拦住之后说的是不是人话" —— 两件事,两个臂。
    v_ok := false; v_msg := NULL;
    BEGIN
        PERFORM create_inbound_batch(v_mat, v_sup, 1, 'kg');   -- 不传 p_arrival_date
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        v_ok := v_msg = 'ARRIVAL_DATE_REQUIRED';
    END;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'FIXTURE 25H 失败:create_inbound_batch 少了到货日应当按名拒绝 ARRIVAL_DATE_REQUIRED,实得:%',
            COALESCE(v_msg, '(建出来了)');
    END IF;

    v_ok := false; v_msg := NULL;
    BEGIN
        PERFORM receive_inbound_batch_against_po(v_mat, v_sup, 1);
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        v_ok := v_msg = 'ARRIVAL_DATE_REQUIRED';
    END;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'FIXTURE 25H 失败:receive_inbound_batch_against_po 少了到货日应当按名拒绝,实得:%',
            COALESCE(v_msg, '(建出来了)');
    END IF;

    v_ok := false; v_msg := NULL;
    BEGIN
        PERFORM create_output_batch(v_mat, 1, 'kg');           -- 不传 p_output_date
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        v_ok := v_msg = 'OUTPUT_DATE_REQUIRED';
    END;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'FIXTURE 25H 失败:create_output_batch 少了产出日应当按名拒绝 OUTPUT_DATE_REQUIRED,实得:%',
            COALESCE(v_msg, '(建出来了)');
    END IF;

    -- 而【带上日期】的同一次调用必须仍然做得到 —— 拒的是缺日期,不是这件事本身。
    IF (create_output_batch(v_mat, 1, 'kg', v_sale) ->> 'batch_id') IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 25H 失败:带上产出日之后,正常路径也走不通了';
    END IF;
END $$;
ROLLBACK;
