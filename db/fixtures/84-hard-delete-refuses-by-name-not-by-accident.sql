-- 84 硬删被【按名】拒绝 —— 而且不是靠外键顺带挡住的
--
-- 【它守的是什么】AUDEL-0 用回滚型探针量出三个洞,全部实测过:
--   * 盘点单【两步】硬删成功(先删行、再删头),不留任何痕迹;
--   * 从未动过的进料批/产出批硬删成功,并 CASCADE 带走化验含量;
--   * 零明细采购单硬删成功;有明细时拦住它的是一句看不懂的外键报错
--     ("insert or update on table purchase_order_history violates foreign key…"),
--     既没说是哪张单,也没说规矩是什么。
--
-- 【本 fixture 的关键一条:证明守卫【独立于外键】】(LOC-1 F 臂的形状)
-- 每一臂删的都是一行【没有任何子行】的记录 —— 外键在这里本来就不会拦。
-- 所以拒绝只可能来自守卫本身;而且断言的是【那句话】,不是"删失败了"。
-- 一条靠外键顺带挡住的路,与一条明写规矩的路,在"删不掉"这个结果上一模一样,
-- 区别只在拒绝时说了什么 —— 而那正是这一刀要买的东西。
--
-- 【一个被故障注入逼出来的写法:每次尝试前把 v_msg 清空】
-- 第一版没清。于是"这一次【没有】抛异常"时,断言把【上一臂】留下的那句消息
-- 原样报了出来 —— 屏幕上写着"实得 STOCKTAKE_NO_HARD_DELETE|FX84-ST",
-- 而真相是根本没有任何拒绝发生。**它红得对,却说错了原因**,
-- 与本仓库反复点名的那一类(一条声称在检查 X、实际检查 Y 的判据)同源。
--
-- 【策略拿掉之后,守卫是单层的,所以每一处都做了故障注入】
-- 注入记录在切次报告里;基线在任何注入之前先跑过。
--
-- 【本 fixture 以 postgres 跑,而这【正是】要测的那条路】盘点那两张表的
-- DELETE 策略已经删掉,普通登录用户根本走不到触发器(RLS 先滤成 0 行)。
-- 守卫挡的是服务角色/属主这条路 —— 也就是 postgres 这条路。所以不切角色是对的,
-- 而且是必须的:切成 authenticated 之后盘点那两臂会变成"0 行"而不是具名拒绝,
-- 那测的就不是这个守卫了。批次与采购单两处策略仍在,两条路都到得了守卫。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid; sup uuid; mat uuid;
    st uuid; st_line uuid; ib uuid; ob uuid; po uuid;
    ib_stocked uuid;   -- G 臂专用:【有货】的批次,软删才写得出 writeoff
    v_msg text; v_denied boolean; n int;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-84', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    INSERT INTO suppliers (code, legal_name, country, counterparty_type)
    VALUES ('FX84-SUP', 'fixture 84 supplier', 'SG', 'goods_supplier') RETURNING id INTO sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('FX84-M', 'fixture 84 material', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO mat;

    -- ── 全部【没有子行】:外键在这里不会拦,拒绝只可能来自守卫 ────────────────
    -- 批次:remaining_qty = 0 且【零条台账行】—— 恒等式成立(0 = Σ∅),
    -- 而这正是 AUDEL-0 实测删得掉的那个形状。
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, unit, remaining_qty, arrival_date, source_reason_code, source_reason_note)
    VALUES ('FX84-IN', mat, sup, 5, 'kg', 0, '2026-05-01', 'other', 'fixture 84 自带数据') RETURNING id INTO ib;
    INSERT INTO output_batches (code, material_id, quantity, unit, remaining_qty, output_date)
    VALUES ('FX84-OUT', mat, 3, 'kg', 0, '2026-05-01') RETURNING id INTO ob;
    -- 采购单:【零明细】—— AUDEL-0 实测正是这一形状删得掉(1 行)
    INSERT INTO purchase_orders (code, supplier_id, order_date, currency, fx_rate, status, approval_status)
    VALUES ('FX84-PO', sup, '2026-05-01', 'USD', 1.3, 'draft', 'pending') RETURNING id INTO po;
    -- G 臂专用:一个【有货】的进料批 + 配套台账行。
    -- 【为什么不能复用上面那个】上面那个 remaining_qty = 0,而 writeoff 写的是
    -- OLD.remaining_qty —— 零数量的流水行会撞上 qty_delta <> 0 那条 CHECK,
    -- 所以触发器【正确地】不写。空批次注销没有可注销的东西,那不是缺陷。
    -- (第一版这一臂就是栽在这里:断言"软删必然写 writeoff",而它对空批次不成立。)
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, unit, remaining_qty, arrival_date, source_reason_code, source_reason_note)
    VALUES ('FX84-IN-STOCKED', mat, sup, 10, 'kg', 10, '2026-05-01', 'other', 'fixture 84 自带数据') RETURNING id INTO ib_stocked;
    INSERT INTO inventory_movements (inbound_batch_id, movement_type, qty_delta, business_date)
    VALUES (ib_stocked, 'receipt', 10, '2026-05-01');

    -- 盘点单:先建一张【带一行】的,两步臂要用
    INSERT INTO stocktakes (code, status) VALUES ('FX84-ST', 'open') RETURNING id INTO st;
    INSERT INTO stocktake_lines (stocktake_id, inbound_batch_id, book_qty, counted_qty)
    VALUES (st, ib, 0, 0) RETURNING id INTO st_line;

    -- ══════════ A. 进料批:按名拒,且【没有子行】═══════════════════════════════
    IF EXISTS (SELECT 1 FROM inventory_movements m WHERE m.inbound_batch_id = ib) THEN
        RAISE EXCEPTION 'FIXTURE 84A 无效:这个批次有台账行,外键会先拦住它 —— 那样测不出守卫';
    END IF;
    v_denied := false; v_msg := NULL;
    BEGIN DELETE FROM inbound_batches WHERE id = ib;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 84A 失败:从未动过的进料批仍然硬删得掉 —— 化验含量会被 CASCADE 带走';
    END IF;
    IF v_msg NOT LIKE 'BATCH_NO_HARD_DELETE|FX84-IN%' THEN
        RAISE EXCEPTION 'FIXTURE 84A 失败:拒绝应当按名并点出批号(BATCH_NO_HARD_DELETE|FX84-IN),实得 % —— 一句外键报错说不出是哪一批、也说不出规矩',
            COALESCE(v_msg, '(没有抛异常 —— 删成功了)');
    END IF;

    -- ══════════ B. 产出批:同一条 ═════════════════════════════════════════════
    v_denied := false; v_msg := NULL;
    BEGIN DELETE FROM output_batches WHERE id = ob;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'BATCH_NO_HARD_DELETE|FX84-OUT%' THEN
        RAISE EXCEPTION 'FIXTURE 84B 失败:产出批应报 BATCH_NO_HARD_DELETE|FX84-OUT,实得 %',
            COALESCE(v_msg, '(没有抛异常 —— 删成功了)');
    END IF;

    -- ══════════ C. 采购单:零明细,靠守卫而不是靠历史外键 ═════════════════════
    IF EXISTS (SELECT 1 FROM purchase_order_lines l WHERE l.purchase_order_id = po) THEN
        RAISE EXCEPTION 'FIXTURE 84C 无效:这张采购单有明细,那句外键报错会先出现 —— 测不出守卫';
    END IF;
    v_denied := false; v_msg := NULL;
    BEGIN DELETE FROM purchase_orders WHERE id = po;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 84C 失败:零明细采购单仍然硬删得掉';
    END IF;
    IF v_msg NOT LIKE 'PO_NO_HARD_DELETE|FX84-PO%' THEN
        RAISE EXCEPTION 'FIXTURE 84C 失败:应报 PO_NO_HARD_DELETE|FX84-PO,实得 % —— 若是 purchase_order_history 的外键报错,那就是又回到了"靠顺带挡住"',
            COALESCE(v_msg, '(没有抛异常 —— 删成功了)');
    END IF;

    -- ══════════ D. 盘点:表头 ═════════════════════════════════════════════════
    v_denied := false; v_msg := NULL;
    BEGIN DELETE FROM stocktakes WHERE id = st;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'STOCKTAKE_NO_HARD_DELETE|FX84-ST%' THEN
        RAISE EXCEPTION 'FIXTURE 84D 失败:盘点单表头应报 STOCKTAKE_NO_HARD_DELETE|FX84-ST,实得 %',
            COALESCE(v_msg, '(没有抛异常 —— 删成功了)');
    END IF;

    -- ══════════ E. 盘点:明细行,而且【报父单的号】═════════════════════════════
    -- 行没有自己的单号;读到这句话的人要去找的是那张盘点单。
    v_denied := false; v_msg := NULL;
    BEGIN DELETE FROM stocktake_lines WHERE id = st_line;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'STOCKTAKE_NO_HARD_DELETE|FX84-ST%' THEN
        RAISE EXCEPTION 'FIXTURE 84E 失败:盘点明细行应报 STOCKTAKE_NO_HARD_DELETE|FX84-ST(父单号),实得 %',
            COALESCE(v_msg, '(没有抛异常 —— 删成功了)');
    END IF;

    -- ══════════ F. 【两步路】—— 这一臂才是那个洞本身 ═════════════════════════
    -- AUDEL-0 实测:先删行(RESTRICT 管不着行本身)、再删头,两步都成功。
    -- 现在第一步就该被拦住;而且【即便有人绕过了第一步】,第二步仍然要拦。
    -- 所以这一臂把行的守卫【临时停用】,把那条老路完整走一遍。
    ALTER TABLE stocktake_lines DISABLE TRIGGER trg_stocktake_lines_no_hard_delete;
    DELETE FROM stocktake_lines WHERE id = st_line;
    GET DIAGNOSTICS n = ROW_COUNT;
    ALTER TABLE stocktake_lines ENABLE TRIGGER trg_stocktake_lines_no_hard_delete;
    IF n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 84F 无效:临时停用守卫之后应当删掉 1 行(以复现那条老路),实得 %', n;
    END IF;
    -- 现在表头【没有任何子行】了 —— RESTRICT 彻底不参与。它仍然必须按名拒。
    IF EXISTS (SELECT 1 FROM stocktake_lines l WHERE l.stocktake_id = st) THEN
        RAISE EXCEPTION 'FIXTURE 84F 无效:行没删干净,RESTRICT 还会参与';
    END IF;
    v_denied := false; v_msg := NULL;
    BEGIN DELETE FROM stocktakes WHERE id = st;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 84F 失败:【两步路】仍然通得过 —— 把行删走之后表头照样删得掉,而那正是 AUDEL-0 量出来的那个洞';
    END IF;
    IF v_msg NOT LIKE 'STOCKTAKE_NO_HARD_DELETE|FX84-ST%' THEN
        RAISE EXCEPTION 'FIXTURE 84F 失败:两步路的第二步应按名拒,实得 %', COALESCE(v_msg, '(没有抛异常)');
    END IF;

    -- ══════════ G. 软删【没有被误伤】—— 守卫只挡 DELETE ═══════════════════════
    -- 【这一臂是必须的】撤销一个录错的批次靠的就是软删(它还会写一条 writeoff
    -- 流水)。一个把 UPDATE 也挡掉的守卫会让"撤销"这件事没有任何合法做法,
    -- 而那时人只会去找别的路。
    -- AUDEL-1b:软删只能走门;这一臂要测的仍然是【硬删守卫不误伤软删】
    PERFORM soft_delete_inbound_batch(ib_stocked, 'fixture:AUDEL-1b 之后理由必填');
    GET DIAGNOSTICS n = ROW_COUNT;
    IF n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 84G 失败:软删(UPDATE deleted_at)被守卫误伤了,影响 % 行', n;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM inventory_movements m
                    WHERE m.inbound_batch_id = ib_stocked AND m.movement_type = 'writeoff') THEN
        RAISE EXCEPTION 'FIXTURE 84G 失败:软删之后没有 writeoff 流水 —— 撤销必须在台账上留下痕迹';
    END IF;
END $$;
ROLLBACK;
