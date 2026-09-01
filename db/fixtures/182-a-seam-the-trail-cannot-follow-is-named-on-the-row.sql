-- 182 轨迹跟不动的那一跳,【写在那一行里】,不是写在文档里
--
-- AUDIT-1 · Tim 的 R3:「一份藏起自己接缝的轨迹,比一份把接缝画出来的更坏。」
--
-- 本 fixture 钉三种接缝,三种的坏法不一样:
--   no_purchase_order  —— 【码】线上 16 个未软删进料批里 8 个不带采购单行,
--                          于是"我们当初订的是什么"对一半的批次答不了。
--                          不标出来,读者会以为这个批次天生就没有采购来路。
--   run_voided         —— 一支被软删的加工单有【三份互相不一致的说法】:
--                          processing_inputs 看得见、batch_lineage_all 看不见、
--                          流水两边都看得见。轨迹挑了流水,并且必须说出自己挑了哪一份。
--   polymorphic_source —— 分录只能经 15 种多态 source_type 够到批次,而
--                          source_type 命名的是一个【概念】不是一张【表】
--                          ('purchase' 同时指向 inbound_batches 与 journal_entries)。
--
-- 【故障注入】每一臂先证明那个标记【会随事实变化】—— 一个恒真的标记
-- 与没有标记是同一种坏:它不再是一句关于这一行的断言。
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid; v_mat uuid; v_sup uuid; v_ib uuid; v_ib2 uuid;
    v_po uuid; v_pol uuid; v_run uuid; v_ob uuid; v_je uuid;
    v_seams text[]; n int;
BEGIN
    INSERT INTO auth.users (id) VALUES (v_user);
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-182','f','f',true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZFIX182-S','fixture 182 supplier','SG','active','goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZFIX182-M','fixture 182 material','battery_material',true,'black_mass','end_of_life')
    RETURNING id INTO v_mat;

    -- 甲:【不带】采购单行的批次(线上那一半)
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty,
        arrival_date, unit_price, source_reason_code, source_reason_note)
    VALUES ('ZZFIX182-IB', v_mat, v_sup, 100, 100, DATE '2027-02-01', 10, 'other', 'fixture 182 自带数据') RETURNING id INTO v_ib;

    -- ══════════ A. no_purchase_order 标在收货那一行上 ══════════════════════
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT seams INTO v_seams FROM batch_audit_trail
     WHERE batch_id = v_ib AND event_kind = 'receipt';
    RESET ROLE;
    IF v_seams IS NULL OR NOT ('no_purchase_order' = ANY (v_seams)) THEN
        RAISE EXCEPTION 'FIXTURE 182A 失败:批次不带采购单行,收货那一行却没有标 no_purchase_order —— 「当初订的是什么」答不了这件事被藏起来了。实得:%', COALESCE(v_seams::text,'(没有这一行)');
    END IF;
    RAISE NOTICE '182A 无采购来路 → 收货行标了 no_purchase_order ✓';

    -- A-注入:补上采购单行,标记必须【消失】(否则它是恒真的,等于没说)
    INSERT INTO purchase_orders (code, supplier_id, order_date, status, currency, fx_rate)
    VALUES ('ZZFIX182-PO', v_sup, DATE '2027-01-20', 'confirmed',
            (SELECT code FROM currencies WHERE is_base LIMIT 1), 1) RETURNING id INTO v_po;
    INSERT INTO purchase_order_lines (purchase_order_id, line_no, material_id, quantity, unit)
    VALUES (v_po, 1, v_mat, 100, 'kg') RETURNING id INTO v_pol;
    UPDATE inbound_batches SET purchase_order_id = v_po, purchase_order_line_id = v_pol WHERE id = v_ib;

    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT seams INTO v_seams FROM batch_audit_trail
     WHERE batch_id = v_ib AND event_kind = 'receipt';
    RESET ROLE;
    IF 'no_purchase_order' = ANY (v_seams) THEN
        RAISE EXCEPTION 'FIXTURE 182A 注入失败:接上采购单行之后【仍然】标着 no_purchase_order —— 这个标记是恒真的,它不是一句关于这一行的断言';
    END IF;
    RAISE NOTICE '182A 注入确实改变了结果(接上采购单行 → 标记消失)✓';

    -- ══════════ B. run_voided:被软删的加工单,那一行还在,并且被点名 ═══════
    -- 消耗前必须记过安全状态(guard_processing_input):
    -- "一条都没有"的意思是【没有人记过】,不是"这批货安全"。
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    VALUES (v_ib, 'discharged_verified');
    -- 【走真门】commit_processing_run / rollback_processing_run —— 直接 UPDATE
    -- deleted_at 会被 guard_soft_delete_provenance 拒掉(SOFT_DELETE_NO_DIRECT_UPDATE),
    -- 而那条守卫是对的:一次没有经办人、没有理由的软删,会被读成「没有人为此负责」。
    -- 所以本臂造的"被冲销的加工单"与产线上真的那一支【走的是同一条路】。
    v_run := commit_processing_run(DATE '2027-02-10', 'fixture 182 run', 0,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib, 'quantity_consumed', 50)),
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 40)), 'weight',
        NULL, NULL, 'manual_disassembly');

    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO n FROM batch_audit_trail
     WHERE batch_id = v_ib AND event_kind='run_input' AND 'run_voided' = ANY (seams);
    RESET ROLE;
    IF n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 182B 失败:加工单还没被软删就已经标了 run_voided —— 恒真的标记';
    END IF;

    PERFORM rollback_processing_run(v_run, 'fixture 182 冲销这一支,好让接缝出现');
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO n FROM batch_audit_trail
     WHERE batch_id = v_ib AND event_kind='run_input' AND 'run_voided' = ANY (seams);
    RESET ROLE;
    -- ★ 关键:那一行【不许消失】。省掉它,读者会以为这次消耗从没发生过 ★
    IF n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 182B 失败:加工单被软删之后,那次消耗要么整行不见了、要么没被标成 run_voided —— 两种都是把接缝藏起来(实得 % 行)', n;
    END IF;
    RAISE NOTICE '182B 加工单被冲销:那一行【还在】且被点名 run_voided ✓';

    -- ══════════ C. polymorphic_source:分录经多态解析够到批次 ═══════════════
    INSERT INTO journal_entries (code, entry_date, memo, source_type, source_id, status)
    VALUES ('ZZFIX182-JE', DATE '2027-02-11', 'fixture 182', 'purchase', v_ib, 'posted')
    RETURNING id INTO v_je;
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT seams INTO v_seams FROM batch_audit_trail WHERE source_id = v_je AND batch_id = v_ib;
    RESET ROLE;
    IF v_seams IS NULL OR NOT ('polymorphic_source' = ANY (v_seams)) THEN
        RAISE EXCEPTION 'FIXTURE 182C 失败:分录那一行没有标 polymorphic_source —— 读者会以为批次与分录之间有一条真的外键,而实际上是拿一个【概念名】猜出来的。实得:%', COALESCE(v_seams::text,'(没有这一行)');
    END IF;
    RAISE NOTICE '182C 分录经多态解析到达 → 标了 polymorphic_source ✓';

    RAISE NOTICE 'FIXTURE 182 全部通过';
END $$;
ROLLBACK;
