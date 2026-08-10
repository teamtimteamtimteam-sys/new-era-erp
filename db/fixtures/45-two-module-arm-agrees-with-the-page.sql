-- 45 跨两个模块的看板支:视图裁决"缺席"与页面裁决"受限",对同一个人必须同答案
--
-- 【判别臂是 C:有 prices、两个模块都没有】这正是合成一个新权限码那条路会错的地方,
-- 也是单码支表达不了的地方。live 的 procurement 与 sales 就是这个形状:持有
-- data.view_prices,既无 finance 也无 processing。
--   * 支若只挂 data.view_prices:他们【看得见牌子上的 0】,而真相是"受限"——
--     absence ≠ zero 那条规矩的正面违反;
--   * 支若只挂 module.finance.view:operations(有 processing 无 finance)【看不见】,
--     而 batch_margin 明明愿意回答他。
-- 所以本 fixture 三种读者各断言一次:finance 侧看得见、processing 侧看得见、
-- 只有 prices 的看不见【任何行】(页面据 permission/permission_any 渲染受限)。
-- 注入方式:把 arm_permission_any 改成返回 NULL,C 臂即红。
--
-- 【D:支只收可行动的那一半】no_unit_cost 上牌(分摊一次就清掉);
-- no_run 永不上牌 —— 事后无从补救,放上去就是一盏关不掉的灯。
BEGIN;
DO $$
DECLARE
    u_fin uuid := gen_random_uuid();
    u_proc uuid := gen_random_uuid();
    u_price uuid := gen_random_uuid();
    r_fin uuid; r_proc uuid; r_price uuid;
    v_mat uuid; v_sup uuid; v_cust uuid; ib uuid; ob_alloc uuid; ob_norun uuid;
    v_run uuid; v_base text; v_n int;
BEGIN
    SELECT code INTO v_base FROM currencies WHERE is_base;
    UPDATE finance_settings SET locked_before = NULL;

    -- 三种读者:prices+finance / prices+processing / 只有 prices
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fixture-45-fin','f','f',true) RETURNING id INTO r_fin;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_fin, unnest(ARRAY['data.view_prices','module.finance.view']);
    INSERT INTO user_roles (user_id, role_id) VALUES (u_fin, r_fin);

    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fixture-45-proc','f','f',true) RETURNING id INTO r_proc;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_proc, unnest(ARRAY['data.view_prices','module.processing.view','module.processing.edit','module.inbound.view']);
    INSERT INTO user_roles (user_id, role_id) VALUES (u_proc, r_proc);

    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fixture-45-price','f','f',true) RETURNING id INTO r_price;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_price, 'data.view_prices');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_price, r_price);

    -- 一批:有加工单、成本【未分摊】、且已售出 → margin_status = no_unit_cost
    INSERT INTO materials (code, name, category) VALUES ('ZZFIX45-M','f','other') RETURNING id INTO v_mat;
    INSERT INTO suppliers (code, legal_name, country, status) VALUES ('ZZFIX45-S','f','SG','active') RETURNING id INTO v_sup;
    INSERT INTO customers (code, legal_name, country) VALUES ('ZZFIX45-C','f','SG') RETURNING id INTO v_cust;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, arrival_date, unit_price)
    VALUES ('ZZFIX45-IB', v_mat, v_sup, 100, 100, CURRENT_DATE, 5) RETURNING id INTO ib;

    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_proc), true);
    v_run := commit_processing_run(CURRENT_DATE, 'fixture 45', 0,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', ib, 'quantity_consumed', 100)),
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 80)), 'weight');
    SELECT po.output_batch_id INTO ob_alloc FROM processing_outputs po WHERE po.run_id = v_run;
    -- 【故意不调 allocate_processing_costs】—— 这就是 no_unit_cost

    -- 另一批:没有任何加工单 → no_run(它永远不该上牌)
    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, output_date)
    VALUES ('ZZFIX45-OB-NORUN', v_mat, 50, 50, CURRENT_DATE) RETURNING id INTO ob_norun;

    -- 两批都卖掉一点(batch_margin 只看已售批次)
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_fin), true);
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_fin, unnest(ARRAY['module.output.edit','module.output.view']);
    PERFORM record_output_sale(ob_alloc, 10, 20, v_base, NULL, v_cust, CURRENT_DATE, NULL, 'manual', NULL);
    PERFORM record_output_sale(ob_norun, 10, 20, v_base, NULL, v_cust, CURRENT_DATE, NULL, 'manual', NULL);

    -- ══════════ A. prices + finance:看得见 ═══════════════════════════════════
    SELECT count(*) INTO v_n FROM operations_now
     WHERE item_type = 'margin_cost_not_allocated'
       AND item_code = (SELECT code FROM output_batches WHERE id = ob_alloc);
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 45A 失败:prices + finance 的读者应当看得见这一支,实得 % 行', v_n;
    END IF;

    -- ══════════ B. prices + processing:同样看得见(没有任何 live 角色同时有两个模块)═
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_proc), true);
    SELECT count(*) INTO v_n FROM operations_now
     WHERE item_type = 'margin_cost_not_allocated'
       AND item_code = (SELECT code FROM output_batches WHERE id = ob_alloc);
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 45B 失败:prices + processing 的读者也应当看得见 —— 支若只挂 finance,加工侧就被挡在外面,而 batch_margin 明明愿意回答他,实得 % 行', v_n;
    END IF;

    -- ══════════ C.【判别臂】只有 prices、两个模块都没有:一行都看不见 ═══════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_price), true);
    SELECT count(*) INTO v_n FROM operations_now WHERE item_type = 'margin_cost_not_allocated';
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 45C 失败:只有 data.view_prices 的读者(live 的 procurement / sales 就是这个形状)不该看到任何行,实得 % 行 —— 支只挂单码时他会看见牌子上的 0,而真相是"受限"', v_n;
    END IF;
    -- 而【支自己声明的谓词】必须能被页面读到 —— 页面据它渲染「受限」而不是 0。
    -- 两侧同源就靠这一列(与 fixture 30 对单码支钉的是同一件事)。
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_fin), true);
    IF NOT EXISTS (
        SELECT 1 FROM operations_now
        WHERE item_type = 'margin_cost_not_allocated'
          AND permission = 'data.view_prices'
          AND permission_any @> ARRAY['module.finance.view','module.processing.view']
    ) THEN
        RAISE EXCEPTION 'FIXTURE 45C 失败:支必须把自己的谓词说出来(permission + permission_any),否则首页只能靠猜 —— 猜出来的就是第二份定义';
    END IF;

    -- ══════════ D. 只收可行动的那一半:no_run 永不上牌 ═══════════════════════
    SELECT count(*) INTO v_n FROM operations_now
     WHERE item_type = 'margin_cost_not_allocated' AND item_code = 'ZZFIX45-OB-NORUN';
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 45D 失败:没有加工单的批次事后无从补救,不该上牌 —— 那会是一盏关不掉的灯(REC-1 与 awaiting_assay 的同一条教训),实得 % 行', v_n;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM batch_margin WHERE output_batch_id = ob_norun AND margin_status = 'no_run') THEN
        RAISE EXCEPTION 'FIXTURE 45D 前置失败:该批应当是 no_run —— 否则本臂在断言一个不存在的情形';
    END IF;
END $$;
ROLLBACK;
