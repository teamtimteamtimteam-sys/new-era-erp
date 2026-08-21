-- 85 一次删除记下【谁】和【为什么】—— 而光有两列是不够的
--
-- 【它守的是什么】AUDEL-0 量出:全库【没有 deleted_by 这一列】,软删只记 when。
-- AUDEL-1b 加了 deleted_by + delete_reason,但加列本身挡不住任何事:软删今天是
-- 一次【直连 UPDATE】,调用方照样可以只置 deleted_at、把两列留空。
-- 所以真正被测的是那道【门】:
--   ① 走门而不给理由 → DELETE_REASON_REQUIRED(按名);
--   ② 给了理由 → 两列都落下,而且 deleted_by 就是【会话里的那个人】;
--   ③ 不走门(直连 UPDATE)→ SOFT_DELETE_NO_DIRECT_UPDATE(按名)。
-- 第三条是这一刀的全部要害:没有它,前两条都可以绕过去。
--
-- 【每一处单层守卫都做了注入】记录在切次报告里;基线在任何注入之前先跑过。
--
-- 【本 fixture 以 postgres 跑,而 auth.uid() 来自 request.jwt.claims】
-- 门里的 deleted_by 取 auth.uid(),它按 claims 解析、与数据库角色无关 ——
-- 所以"记下的人是不是会话里那个人"这一条断言在这里是真的,不是空转。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid; sup uuid; mat uuid;
    ib uuid; ib2 uuid; ob uuid; po uuid; st uuid; run uuid;
    v_msg text; v_denied boolean; n int;
    v_by uuid; v_reason text;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-85', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    INSERT INTO suppliers (code, legal_name, country, counterparty_type)
    VALUES ('FX85-SUP', 'fixture 85 supplier', 'SG', 'goods_supplier') RETURNING id INTO sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed)
    VALUES ('FX85-M', 'fixture 85 material', 'battery_material', true) RETURNING id INTO mat;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, unit, remaining_qty, arrival_date)
    VALUES ('FX85-IN', mat, sup, 10, 'kg', 10, '2026-05-01') RETURNING id INTO ib;
    INSERT INTO inventory_movements (inbound_batch_id, movement_type, qty_delta, business_date)
    VALUES (ib, 'receipt', 10, '2026-05-01');
    INSERT INTO output_batches (code, material_id, quantity, unit, remaining_qty, output_date)
    VALUES ('FX85-OUT', mat, 4, 'kg', 4, '2026-05-01') RETURNING id INTO ob;
    INSERT INTO inventory_movements (output_batch_id, movement_type, qty_delta, business_date)
    VALUES (ob, 'processing_produce', 4, '2026-05-01');
    INSERT INTO purchase_orders (code, supplier_id, order_date, currency, fx_rate, status, approval_status)
    VALUES ('FX85-PO', sup, '2026-05-01', 'USD', 1.3, 'draft', 'pending') RETURNING id INTO po;
    INSERT INTO stocktakes (code, status) VALUES ('FX85-ST', 'open') RETURNING id INTO st;

    -- ══════════ A. 没有理由 → 按名拒(门里那一条)═══════════════════════════
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM soft_delete_inbound_batch(ib, '   ');   -- 全空白也算没给
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'DELETE_REASON_REQUIRED|inbound_batches|FX85-IN%' THEN
        RAISE EXCEPTION 'FIXTURE 85A 失败:空白理由应报 DELETE_REASON_REQUIRED|inbound_batches|FX85-IN,实得 %',
            COALESCE(v_msg, '(通过了)');
    END IF;
    -- 【被拒 = 什么都没写】校验在任何写之前
    IF (SELECT deleted_at FROM inbound_batches WHERE id = ib) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 85A 失败:被拒之后批次却已经是删除状态';
    END IF;

    -- ══════════ B. 给了理由 → 两列都落下,而且【人是会话里那个人】═══════════
    PERFORM soft_delete_inbound_batch(ib, '  录错了供应商,重新收货  ');
    SELECT deleted_by, delete_reason INTO v_by, v_reason FROM inbound_batches WHERE id = ib;
    IF v_by IS DISTINCT FROM v_user THEN
        RAISE EXCEPTION 'FIXTURE 85B 失败:deleted_by 应当是会话里那个人(%),实得 % —— 一个记错了人的审计字段比没有更坏',
            v_user, v_by;
    END IF;
    -- 【首尾空白被 btrim 掉,而中间原样保留】理由是人写的话,不是标识符
    IF v_reason <> '录错了供应商,重新收货' THEN
        RAISE EXCEPTION 'FIXTURE 85B 失败:理由应被 btrim 后原样存下,实得 [%]', v_reason;
    END IF;
    -- 台账那一条注销流水,记的人也该是【删的那个人】(AUDEL-1b 把它从 updated_by 换过来)
    SELECT created_by INTO v_by FROM inventory_movements
     WHERE inbound_batch_id = ib AND movement_type = 'writeoff';
    IF v_by IS DISTINCT FROM v_user THEN
        RAISE EXCEPTION 'FIXTURE 85B 失败:注销流水的 created_by 应当是删的那个人,实得 %', v_by;
    END IF;

    -- ══════════ C. 直连 UPDATE → 按名拒(这一条是全刀的要害)═══════════════
    -- 【连"两列都填好了"的直连 UPDATE 也要拒】否则任何人都能自己编一个 deleted_by。
    v_denied := false; v_msg := NULL;
    BEGIN
        UPDATE output_batches
           SET deleted_at = now(), deleted_by = v_user, delete_reason = '我自己写的'
         WHERE id = ob;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'SOFT_DELETE_NO_DIRECT_UPDATE|output_batches|FX85-OUT%' THEN
        RAISE EXCEPTION 'FIXTURE 85C 失败:直连 UPDATE 应报 SOFT_DELETE_NO_DIRECT_UPDATE|output_batches|FX85-OUT,实得 % —— 这条路不堵住,前面两臂都可以绕过去',
            COALESCE(v_msg, '(通过了)');
    END IF;

    -- ══════════ C2. 【带着标记、却不填那两列】—— 守卫的第二条 ════════════════
    -- 【为什么要单独造这一臂】守卫有两条:①必须走门 ②门里也不许留空。
    -- 正常路径下②【够不着】—— 门总是把两列填好,而直连那条路在①就被拒了。
    -- 故障注入证明了这一点:把②整条拿掉,fixture 照样全绿。
    -- 所以这里【手动设标记】,模拟"将来有人建了第二扇门、却忘了填两列"——
    -- 那正是②唯一要防的情形,也是它唯一能被观察到的地方。
    PERFORM set_config('evoltrya.soft_delete_ctx', '1', true);
    v_denied := false; v_msg := NULL;
    BEGIN
        UPDATE output_batches SET deleted_at = now() WHERE id = ob;   -- 两列都不填
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    PERFORM set_config('evoltrya.soft_delete_ctx', '', true);
    IF NOT v_denied OR v_msg NOT LIKE 'DELETE_REASON_REQUIRED|output_batches|FX85-OUT%' THEN
        RAISE EXCEPTION 'FIXTURE 85C2 失败:带标记但两列为空,应报 DELETE_REASON_REQUIRED|output_batches|FX85-OUT,实得 % —— 一扇忘了填的门与没有门一样坏',
            COALESCE(v_msg, '(通过了)');
    END IF;

    -- ══════════ D. 门里走得通(同一张表,证明 C 拒的是【路】不是【表】)═══════
    PERFORM soft_delete_output_batch(ob, '产出记错,回滚重做');
    IF (SELECT delete_reason FROM output_batches WHERE id = ob) <> '产出记错,回滚重做' THEN
        RAISE EXCEPTION 'FIXTURE 85D 失败:门里的软删没有把理由写下来';
    END IF;

    -- ══════════ E. 采购单取消:理由必填 + 谁 + 历史行 ═══════════════════════
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM cancel_purchase_order(po, NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'PO_CANCEL_REASON_REQUIRED|FX85-PO%' THEN
        RAISE EXCEPTION 'FIXTURE 85E 失败:空理由应报 PO_CANCEL_REASON_REQUIRED|FX85-PO,实得 %',
            COALESCE(v_msg, '(通过了)');
    END IF;
    PERFORM cancel_purchase_order(po, '供应商涨价,不做了');
    SELECT cancelled_by, cancel_reason INTO v_by, v_reason FROM purchase_orders WHERE id = po;
    IF v_by IS DISTINCT FROM v_user OR v_reason <> '供应商涨价,不做了' THEN
        RAISE EXCEPTION 'FIXTURE 85E 失败:取消应记下 cancelled_by 与 cancel_reason,实得 % / %', v_by, v_reason;
    END IF;
    -- 【历史行】此前取消【不写历史】,而另外四个族都写
    SELECT count(*) INTO n FROM purchase_order_history
     WHERE purchase_order_id = po AND change_type = 'cancelled';
    IF n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 85E 失败:取消应写恰好 1 行 change_type=cancelled 的历史,实得 %', n;
    END IF;
    SELECT changed_by, amend_reason INTO v_by, v_reason FROM purchase_order_history
     WHERE purchase_order_id = po AND change_type = 'cancelled';
    IF v_by IS DISTINCT FROM v_user OR v_reason <> '供应商涨价,不做了' THEN
        RAISE EXCEPTION 'FIXTURE 85E 失败:历史行应带上人与理由,实得 % / %', v_by, v_reason;
    END IF;

    -- ══════════ F. 盘点取消:理由必填 ═══════════════════════════════════════
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM cancel_stocktake(st, '');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'STOCKTAKE_CANCEL_REASON_REQUIRED|FX85-ST%' THEN
        RAISE EXCEPTION 'FIXTURE 85F 失败:空理由应报 STOCKTAKE_CANCEL_REASON_REQUIRED|FX85-ST,实得 %',
            COALESCE(v_msg, '(通过了)');
    END IF;
    PERFORM cancel_stocktake(st, '数错了,重新盘');
    SELECT cancelled_by, cancel_reason INTO v_by, v_reason FROM stocktakes WHERE id = st;
    IF v_by IS DISTINCT FROM v_user OR v_reason <> '数错了,重新盘' THEN
        RAISE EXCEPTION 'FIXTURE 85F 失败:盘点取消应记下人与理由,实得 % / %', v_by, v_reason;
    END IF;

    -- ══════════ G. 加工单回滚:理由必填,且理由随产出批一起落下 ═══════════════
    -- 【自己的投入批】不能复用 ib —— 它在 B 臂已经被软删了,而回滚要把料还回去,
    -- 还给一个已删的批次是另一件事。这一臂要测的是"理由记下来了没有"。
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, unit, remaining_qty, arrival_date)
    VALUES ('FX85-IN2', mat, sup, 10, 'kg', 9, '2026-05-01') RETURNING id INTO ib2;
    INSERT INTO processing_runs (code, status, process_date, allocation_basis)
    VALUES ('FX85-RUN', 'committed', '2026-05-02', 'weight') RETURNING id INTO run;
    -- 台账要配套:收 10、被这张单耗掉 1 —— 否则回滚还料时对不上(IOD_RESTORE_MISMATCH)
    INSERT INTO inventory_movements (inbound_batch_id, movement_type, qty_delta, business_date, run_id)
    VALUES (ib2, 'receipt', 10, '2026-05-01', NULL),
           (ib2, 'processing_consume', -1, '2026-05-02', run);
    INSERT INTO processing_inputs (run_id, inbound_batch_id, quantity_consumed) VALUES (run, ib2, 1);
    INSERT INTO output_batches (code, material_id, quantity, unit, remaining_qty, output_date)
    VALUES ('FX85-OUT2', mat, 1, 'kg', 1, '2026-05-02') RETURNING id INTO ob;
    INSERT INTO inventory_movements (output_batch_id, movement_type, qty_delta, business_date)
    VALUES (ob, 'processing_produce', 1, '2026-05-02');
    INSERT INTO processing_outputs (run_id, output_batch_id, quantity_produced) VALUES (run, ob, 1);

    v_denied := false; v_msg := NULL;
    BEGIN PERFORM rollback_processing_run(run, '   ');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'ROLLBACK_REASON_REQUIRED|FX85-RUN%' THEN
        RAISE EXCEPTION 'FIXTURE 85G 失败:空理由应报 ROLLBACK_REASON_REQUIRED|FX85-RUN,实得 %',
            COALESCE(v_msg, '(通过了)');
    END IF;
    -- 【被拒 = 什么都没发生】校验在任何写之前
    IF (SELECT status FROM processing_runs WHERE id = run) <> 'committed' THEN
        RAISE EXCEPTION 'FIXTURE 85G 失败:被拒之后加工单状态却已经变了';
    END IF;

    PERFORM rollback_processing_run(run, '投入批次搞混了');
    SELECT delete_reason INTO v_reason FROM processing_runs WHERE id = run;
    IF v_reason <> '投入批次搞混了' THEN
        RAISE EXCEPTION 'FIXTURE 85G 失败:回滚的理由应记在加工单上,实得 %', COALESCE(v_reason, '(空)');
    END IF;
    -- 【回滚带走的产出批,理由就是这次回滚的理由】它们不是被单独注销的。
    SELECT delete_reason, deleted_by INTO v_reason, v_by FROM output_batches WHERE id = ob;
    IF v_reason <> '投入批次搞混了' OR v_by IS DISTINCT FROM v_user THEN
        RAISE EXCEPTION 'FIXTURE 85G 失败:被回滚带走的产出批应带上同一个理由与人,实得 % / %',
            COALESCE(v_reason, '(空)'), v_by;
    END IF;

    -- ══════════ H. 权限:门要 module.*.edit ═══════════════════════════════════
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', gen_random_uuid()), true);
    v_denied := false;
    BEGIN PERFORM soft_delete_output_batch(ob, '随便写一个');
    EXCEPTION WHEN OTHERS THEN v_denied := true; END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 85H 失败:没有 module.output.edit 的主体软删掉了批次';
    END IF;
END $$;
ROLLBACK;
