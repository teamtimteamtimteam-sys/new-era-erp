-- ═══════════════════════════════════════════════════════════════════════════
-- fixture 266 —— 一件备件按落地单价出给一次修理,带着理由退回来;改价时出给保养那一份的价差进 6800
--   (MES-7a-2,2026-10-16;MES-0 Q70 · Q89;MES-7a Step 0 Q2 · Q10–Q17 · Q20–Q23,Tim 照推荐裁定;Q11:6800 Repairs & Maintenance)
-- ═══════════════════════════════════════════════════════════════════════════
-- 臂:
--   REG      6800 是系统科目(expense、启用);分录来源认得 maintenance_part,而且它【不经冲销申请】(source_path);流水类型认得两种新类型;
--            material_kinds 那一行备件的说明改写成"按批收货、挂保养记录出库、不逐件追溯";审计成员(设备是家,进料批与它的分录也看得见);
--            出库表进变更记录,豁免仍是 8;待定值 V21 那一支在
--   PERM     没有 module.inventory.edit 的人出不了、退不了(PERMISSION_DENIED|module.inventory.edit)
--   REFUSE   日期必填 / 不在未来 · 保养记录找不到 · 资本化了的记录 PART_ISSUE_CAPITALISED · 没有明细 · 不是备件 PART_NOT_SPARE_PART ·
--            没定价 SPARE_PART_UNPRICED · 数量 ≤ 0 · 超过可用(单条与按批合计)PART_ISSUE_EXCEEDS_AVAILABLE;拒了什么都没写
--   VOID     保养记录今天【没有作废】(没有作废列、删除被拒)—— 委托书的"未作废"在今天没有主语;有人加一个作废,这一臂就红
--   ISSUE    暂定价(provisional)照出;出 4 件 → 剩余 6、一条 maintenance_issue(可用桶,−4)、一张分录 借 6800 / 贷 1200 = 4 × 落地单价,
--            source_type maintenance_part、source_id = 那一行;一行 maintenance_part_issues(kind issue,movement_ids 对得上)
--   RETURN   没有理由拒 · 多于还没退的拒 · 早于出库日拒 · 引用的不是一行出库拒;退 1 件带理由 → 一条 maintenance_return(+1)、分录 借 1200 / 贷 6800,
--            那一行引用它退的出库;再退 4 件拒(还可退 3)
--   DIRECT   会话里直连插入出库表按名拒;改与删对谁都按名拒(只可追加);属主路径不经函数写两种保养流水也按名拒
--   CAPITAL  一条还挂着件的保养记录不能再资本化(MAINTENANCE_HAS_PARTS)—— 守在表上,将来任何一条翻成资本化的路都过它
--   REPRICE  reprice_split 认得出给保养的那一份(单元算术:在库 / 保养 / 其余三块;两块占满时其余恰好为 0);改价 5 → 6:
--            在库 7 → 1200 借 7,出给保养净 3 → 6800 借 3,5000 一分都没有,应付 2000 贷 10;试算给出同一个保养份额
--   HOLD     一张开着的不合格报告挡出库(QUALITY_HOLD_OPEN|批号|报告),不挡退回
--   ROLL     库存月度滚动多了一列"出给保养"(净额 = −净出库),期末仍等于这些批次的剩余量之和;质量树多了一条去向 maintenance,未解释仍是 0
--   V21      一种收过货、最低库存为空的备件物料列在待定值里;没收过货的不列;填了最低库存就消失
--   RECON    每一步动钱之后:应付清单 = 总账(未解释 0.00),存货控制科目 1200 与明细对得上(未解释 0.00、reconciled)
--
-- 自带数据(README 第 2 条);以 postgres 跑;员工的调用切成 authenticated + JWT(AGENTS.md:RLS 断言必须切角色)。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '300s';

CREATE FUNCTION pg_temp.f266_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims',
                      CASE WHEN p_user IS NULL THEN '' ELSE format('{"sub":"%s","role":"authenticated"}', p_user) END, true)
$f$;

-- 以某人的身份跑一句;返回 'OK' 或那一句的错误(SQLERRM)
CREATE FUNCTION pg_temp.f266_do(p_user uuid, p_sql text) RETURNS text
LANGUAGE plpgsql AS $f$
BEGIN
    PERFORM pg_temp.f266_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql;
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f266_as(NULL);
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f266_as(NULL);
    RETURN SQLERRM;
END;
$f$;

CREATE FUNCTION pg_temp.f266_get(p_user uuid, p_sql text) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v jsonb;
BEGIN
    PERFORM pg_temp.f266_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f266_as(NULL);
    RETURN v;
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f266_as(NULL);
    RAISE;
END;
$f$;

CREATE FUNCTION pg_temp.f266_user(p_label text, p_codes text[]) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE u uuid := gen_random_uuid(); r uuid;
BEGIN
    INSERT INTO auth.users (id, email, email_confirmed_at, created_at) VALUES (u, 'fx266-' || p_label || '@test.local', now(), now());
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx266-' || p_label, 'f', 'f', true) RETURNING id INTO r;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r, c FROM unnest(p_codes) c;
    INSERT INTO user_roles (user_id, role_id) VALUES (u, r);
    RETURN u;
END;
$f$;

CREATE FUNCTION pg_temp.f266_expect(p_arm text, p_got text, p_like text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
    IF p_got IS NULL OR p_got NOT LIKE p_like THEN
        RAISE EXCEPTION 'FIXTURE 266 % expected % got %', p_arm, p_like, COALESCE(p_got, '<null>');
    END IF;
END;
$f$;

-- 每一步动钱之后:应付 / 应收清单 = 总账,存货控制科目对得上(以持 module.finance.view 的人读 —— 两支函数都按读者的码过滤)
CREATE FUNCTION pg_temp.f266_recon(p_user uuid, p_step text) RETURNS void
LANGUAGE plpgsql AS $f$
DECLARE v jsonb; s jsonb;
BEGIN
    v := pg_temp.f266_get(p_user, 'SELECT list_ledger_reconciliation()');
    FOR s IN SELECT * FROM jsonb_array_elements(v -> 'sides') LOOP
        IF (s ->> 'unexplained_base')::numeric <> 0 THEN
            RAISE EXCEPTION 'FIXTURE 266 RECON % % list ≠ ledger: %', p_step, s ->> 'side', s;
        END IF;
    END LOOP;
    v := pg_temp.f266_get(p_user, 'SELECT gl_control_reconciliation(CURRENT_DATE)');
    SELECT x INTO s FROM jsonb_array_elements(v -> 'sides') x WHERE x ->> 'side' = 'inventory_raw';
    IF s IS NULL OR (s ->> 'unexplained_base')::numeric <> 0 OR NOT (s ->> 'reconciled')::boolean THEN
        RAISE EXCEPTION 'FIXTURE 266 RECON % inventory control 1200 not reconciled: %', p_step, s;
    END IF;
END;
$f$;

DO $$
DECLARE
    u_all uuid; u_view uuid; u_inv uuid;
    v_base text;
    v_today date := (now() AT TIME ZONE 'Asia/Singapore')::date;
    d date;
    v_sup uuid; v_sp uuid; v_sp2 uuid; v_bm uuid; fa uuid;
    m_ok uuid; m_cap uuid;
    ib_p uuid; ib_u uuid; ib_bm uuid; ib_h uuid;
    iss uuid; ret uuid; iss_h uuid;
    v_j jsonb; v_j2 jsonb; v_msg text; v_n bigint; v_x numeric; v_je uuid; v_rows int;
BEGIN
    SELECT code INTO v_base FROM currencies WHERE is_base;
    PERFORM pg_temp.f266_as(NULL);
    -- 期间锁自己设(README 第 4 条)
    UPDATE finance_settings SET locked_before = NULL;
    d := v_today - 5;

    u_all  := pg_temp.f266_user('all', ARRAY(SELECT code FROM permissions));
    u_view := pg_temp.f266_user('view', ARRAY['module.processing.view', 'module.inventory.view']);
    u_inv  := pg_temp.f266_user('inv', ARRAY['module.inventory.view', 'module.inventory.edit', 'module.processing.view']);
    -- 一张不合格报告要有一个不是开它的人的决定人(MES-6b-1 的 NCR_NO_OTHER_DECIDER)—— 这里只是让暂扣能开起来
    PERFORM pg_temp.f266_user('qd', ARRAY['action.ncr_decide', 'module.quality.view', 'module.inbound.view', 'module.output.view']);

    -- ══════════════ 布景 ══════════════
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ266-S', 'f266 spares vendor', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, unit)
    VALUES ('ZZ266-SP', 'f266 shredder blade', 'spare_part', false, 'pcs') RETURNING id INTO v_sp;
    INSERT INTO materials (code, name, kind_code, may_be_processed, unit)
    VALUES ('ZZ266-SP2', 'f266 bearing never received', 'spare_part', false, 'pcs') RETURNING id INTO v_sp2;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, unit)
    VALUES ('ZZ266-BM', 'f266 black mass', 'battery_material', true, 'black_mass', 'end_of_life', 'kg') RETURNING id INTO v_bm;
    INSERT INTO fixed_assets (code, description, category, acquisition_date, cost_ccy, currency, fx_rate, cost_base, useful_life_months, residual_base)
    VALUES ('FX266-M', 'fixture 266 shredder', 'equipment', d - 50, 0, v_base, 1, 0, 60, 0) RETURNING id INTO fa;

    PERFORM pg_temp.f266_as(u_all);
    ib_p := (create_inbound_batch(v_sp, v_sup, 10, 'pcs', d, '待加工', p_unit_price => 5, p_currency => v_base,
                                  p_source_reason_code => 'other', p_source_reason_note => 'fixture 266') ->> 'batch_id')::uuid;
    ib_u := (create_inbound_batch(v_sp, v_sup, 5, 'pcs', d, '待加工',
                                  p_source_reason_code => 'other', p_source_reason_note => 'fixture 266 unpriced') ->> 'batch_id')::uuid;
    ib_h := (create_inbound_batch(v_sp, v_sup, 4, 'pcs', d, '待加工', p_unit_price => 2, p_currency => v_base,
                                  p_source_reason_code => 'other', p_source_reason_note => 'fixture 266 to be held') ->> 'batch_id')::uuid;
    ib_bm := (create_inbound_batch(v_bm, v_sup, 100, 'kg', d, '待加工', p_unit_price => 1, p_currency => v_base,
                                   p_safety_states => ARRAY['discharged_verified'],
                                   p_source_reason_code => 'other', p_source_reason_note => 'fixture 266 not a spare') ->> 'batch_id')::uuid;
    PERFORM pg_temp.f266_as(NULL);
    PERFORM pg_temp.f266_recon(u_all, 'after the receipts');

    v_j := pg_temp.f266_get(u_all, format($q$SELECT record_equipment_maintenance(p_equipment_id => %L, p_performed_on => %L, p_kind => 'repair',
                             p_description => 'replace the blade', p_performed_by_name => 'Ali')$q$, fa, d));
    m_ok := (v_j ->> 'maintenance_id')::uuid;
    v_j := pg_temp.f266_get(u_all, format($q$SELECT record_equipment_maintenance(p_equipment_id => %L, p_performed_on => %L, p_kind => 'repair',
                             p_description => 'overhaul', p_performed_by_name => 'Ali', p_capitalised => true,
                             p_capitalisation_reason => 'extends the life')$q$, fa, d));
    m_cap := (v_j ->> 'maintenance_id')::uuid;

    -- ══════════════ REG ══════════════
    RAISE NOTICE 'fixture 266 · REG';
    IF NOT EXISTS (SELECT 1 FROM accounts WHERE code = '6800' AND is_system AND is_active AND account_type = 'expense'
                     AND name_en = 'Repairs & Maintenance') THEN
        RAISE EXCEPTION 'FIXTURE 266 REG 6800 Repairs & Maintenance must be an active system expense account';
    END IF;
    IF pg_get_constraintdef((SELECT oid FROM pg_constraint WHERE conname = 'journal_entries_source_type_check')) NOT LIKE '%maintenance_part%'
       OR pg_get_constraintdef((SELECT oid FROM pg_constraint WHERE conname = 'inventory_movements_movement_type_check')) NOT LIKE '%maintenance_issue%maintenance_return%' THEN
        RAISE EXCEPTION 'FIXTURE 266 REG the source type and the two movement types must be allowed';
    END IF;
    IF (SELECT notes FROM material_kinds WHERE code = 'spare_part') NOT LIKE '%received as lots so stock and cost are counted%'
       OR (SELECT notes FROM material_kinds WHERE code = 'spare_part') NOT LIKE '%issued against a maintenance record%'
       OR (SELECT notes FROM material_kinds WHERE code = 'spare_part') NOT LIKE '%no per-piece traceability%'
       OR (SELECT notes FROM material_kinds WHERE code = 'spare_part') LIKE '%不按批次追溯】%' THEN
        RAISE EXCEPTION 'FIXTURE 266 REG the spare_part note must say: received as lots, issued against a maintenance record, no per-piece traceability';
    END IF;
    IF (SELECT count(*) FROM trail_subject_members() m WHERE m.table_name = 'maintenance_part_issues'
          AND ((m.subject = 'equipment' AND m.parent_table = 'equipment_maintenance' AND m.home)
               OR (m.subject = 'inbound_batch' AND m.parent_table = 'inbound_batches' AND NOT m.home))) <> 2
       OR NOT EXISTS (SELECT 1 FROM trail_subject_members() m WHERE m.subject = 'inbound_batch' AND m.table_name = 'journal_entries'
                        AND m.parent_table = 'maintenance_part_issues' AND m.match ->> 'source_type' = 'maintenance_part') THEN
        RAISE EXCEPTION 'FIXTURE 266 REG part issues must live under equipment (home) and show under the inbound batch with their entries';
    END IF;
    IF EXISTS (SELECT 1 FROM trail_subjects() s WHERE s.root_table = 'maintenance_part_issues') THEN
        RAISE EXCEPTION 'FIXTURE 266 REG part issues have no subject of their own (Q20)';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), '''V21''::text AS value_code', 'g')) THEN
        RAISE EXCEPTION 'FIXTURE 266 REG pending_values must carry a V21 arm';
    END IF;

    -- ══════════════ PERM ══════════════
    RAISE NOTICE 'fixture 266 · PERM';
    v_msg := pg_temp.f266_do(u_view, format($q$SELECT issue_spare_parts(%L, %L, '[{"inbound_batch_id": "%s", "quantity": 1}]'::jsonb)$q$, m_ok, d, ib_p));
    PERFORM pg_temp.f266_expect('PERM issue', v_msg, 'PERMISSION_DENIED|module.inventory.edit%');

    -- ══════════════ REFUSE ══════════════
    RAISE NOTICE 'fixture 266 · REFUSE';
    v_msg := pg_temp.f266_do(u_inv, format($q$SELECT issue_spare_parts(%L, NULL, '[{"inbound_batch_id": "%s", "quantity": 1}]'::jsonb)$q$, m_ok, ib_p));
    PERFORM pg_temp.f266_expect('REFUSE no date', v_msg, 'PART_ISSUE_DATE_REQUIRED%');
    v_msg := pg_temp.f266_do(u_inv, format($q$SELECT issue_spare_parts(%L, %L, '[{"inbound_batch_id": "%s", "quantity": 1}]'::jsonb)$q$, m_ok, v_today + 2, ib_p));
    PERFORM pg_temp.f266_expect('REFUSE future', v_msg, 'PART_ISSUE_DATE_IN_FUTURE|%');
    v_msg := pg_temp.f266_do(u_inv, format($q$SELECT issue_spare_parts(%L, %L, '[{"inbound_batch_id": "%s", "quantity": 1}]'::jsonb)$q$, gen_random_uuid(), d, ib_p));
    PERFORM pg_temp.f266_expect('REFUSE no maintenance', v_msg, 'MAINTENANCE_NOT_FOUND|%');
    v_msg := pg_temp.f266_do(u_inv, format($q$SELECT issue_spare_parts(%L, %L, '[{"inbound_batch_id": "%s", "quantity": 1}]'::jsonb)$q$, m_cap, d, ib_p));
    PERFORM pg_temp.f266_expect('REFUSE capitalised', v_msg, 'PART_ISSUE_CAPITALISED|FX266-M|%');
    v_msg := pg_temp.f266_do(u_inv, format($q$SELECT issue_spare_parts(%L, %L, '[]'::jsonb)$q$, m_ok, d));
    PERFORM pg_temp.f266_expect('REFUSE no lines', v_msg, 'PART_ISSUE_NO_LINES%');
    v_msg := pg_temp.f266_do(u_inv, format($q$SELECT issue_spare_parts(%L, %L, '[{"inbound_batch_id": "%s", "quantity": 1}]'::jsonb)$q$, m_ok, d, ib_bm));
    PERFORM pg_temp.f266_expect('REFUSE not a spare part', v_msg, 'PART_NOT_SPARE_PART|%|battery_material%');
    v_msg := pg_temp.f266_do(u_inv, format($q$SELECT issue_spare_parts(%L, %L, '[{"inbound_batch_id": "%s", "quantity": 1}]'::jsonb)$q$, m_ok, d, ib_u));
    PERFORM pg_temp.f266_expect('REFUSE unpriced', v_msg, 'SPARE_PART_UNPRICED|%');
    v_msg := pg_temp.f266_do(u_inv, format($q$SELECT issue_spare_parts(%L, %L, '[{"inbound_batch_id": "%s", "quantity": 0}]'::jsonb)$q$, m_ok, d, ib_p));
    PERFORM pg_temp.f266_expect('REFUSE qty 0', v_msg, 'PART_QTY_INVALID|%');
    v_msg := pg_temp.f266_do(u_inv, format($q$SELECT issue_spare_parts(%L, %L, '[{"inbound_batch_id": "%s", "quantity": 11}]'::jsonb)$q$, m_ok, d, ib_p));
    PERFORM pg_temp.f266_expect('REFUSE above available', v_msg, 'PART_ISSUE_EXCEEDS_AVAILABLE|%|10|11%');
    v_msg := pg_temp.f266_do(u_inv, format($q$SELECT issue_spare_parts(%L, %L, '[{"inbound_batch_id": "%s", "quantity": 6}, {"inbound_batch_id": "%s", "quantity": 6}]'::jsonb)$q$, m_ok, d, ib_p, ib_p));
    PERFORM pg_temp.f266_expect('REFUSE above available summed', v_msg, 'PART_ISSUE_EXCEEDS_AVAILABLE|%|10|12%');
    IF EXISTS (SELECT 1 FROM maintenance_part_issues) OR (SELECT remaining_qty FROM inbound_batches WHERE id = ib_p) <> 10
       OR EXISTS (SELECT 1 FROM inventory_movements WHERE movement_type IN ('maintenance_issue', 'maintenance_return')) THEN
        RAISE EXCEPTION 'FIXTURE 266 REFUSE a refused issue wrote something';
    END IF;

    -- ══════════════ VOID ══════════════
    RAISE NOTICE 'fixture 266 · VOID';
    -- 保养记录没有作废:没有一列说它作废了 / 删掉了,删除被拒。谁给它加一个作废,这里就红 —— 逼他回 issue_spare_parts 加一道拒绝。
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'equipment_maintenance'
                 AND (column_name LIKE '%void%' OR column_name LIKE '%deleted%' OR column_name LIKE '%cancel%')) THEN
        RAISE EXCEPTION 'FIXTURE 266 VOID equipment_maintenance has gained a void / delete column — issue_spare_parts must refuse a voided record by name';
    END IF;
    v_msg := pg_temp.f266_do(u_all, format($q$DELETE FROM equipment_maintenance WHERE id = %L$q$, m_ok));
    PERFORM pg_temp.f266_expect('VOID delete refused', v_msg, 'EQUIPMENT_THROUGH_FUNCTION_ONLY|equipment_maintenance|delete%');

    -- ══════════════ ISSUE ══════════════
    RAISE NOTICE 'fixture 266 · ISSUE';
    IF (SELECT pricing_status FROM inbound_batches WHERE id = ib_p) <> 'provisional' THEN
        RAISE EXCEPTION 'FIXTURE 266 ISSUE the priced batch should carry a provisional price';
    END IF;
    v_x := inbound_batch_landed_unit_cost_all(ib_p);
    v_j := pg_temp.f266_get(u_inv, format($q$SELECT issue_spare_parts(%L, %L, '[{"inbound_batch_id": "%s", "quantity": 4}]'::jsonb)$q$, m_ok, d, ib_p));
    iss := (v_j -> 'lines' -> 0 ->> 'issue_id')::uuid;
    IF (SELECT remaining_qty FROM inbound_batches WHERE id = ib_p) <> 6 THEN
        RAISE EXCEPTION 'FIXTURE 266 ISSUE remaining should be 6';
    END IF;
    IF (SELECT string_agg(movement_type || ':' || qty_delta || ':' || stock_status, ',') FROM inventory_movements
         WHERE inbound_batch_id = ib_p AND movement_type LIKE 'maintenance%') <> 'maintenance_issue:-4:available' THEN
        RAISE EXCEPTION 'FIXTURE 266 ISSUE expected one maintenance_issue of -4 from available';
    END IF;
    SELECT journal_entry_id INTO v_je FROM maintenance_part_issues WHERE id = iss;
    IF (SELECT string_agg(a.code || ':' || l.debit::numeric(14,2) || ':' || l.credit::numeric(14,2), ',' ORDER BY a.code) FROM journal_lines l JOIN accounts a ON a.id = l.account_id
         WHERE l.entry_id = v_je) IS DISTINCT FROM ('1200:0.00:' || round(4 * v_x, 2) || ',6800:' || round(4 * v_x, 2) || ':0.00')
       OR (SELECT source_type || ':' || source_id FROM journal_entries WHERE id = v_je) IS DISTINCT FROM ('maintenance_part:' || iss) THEN
        RAISE EXCEPTION 'FIXTURE 266 ISSUE expected Dr 6800 / Cr 1200 = 4 × landed % from source maintenance_part, got %', v_x,
            (SELECT string_agg(a.code || ':' || l.debit::numeric(14,2) || ':' || l.credit::numeric(14,2), ',' ORDER BY a.code) FROM journal_lines l JOIN accounts a ON a.id = l.account_id WHERE l.entry_id = v_je);
    END IF;
    IF (SELECT kind || ':' || quantity || ':' || maintenance_id || ':' || (returns_issue_id IS NULL) FROM maintenance_part_issues WHERE id = iss)
         <> ('issue:4:' || m_ok || ':true')
       OR (SELECT movement_ids FROM maintenance_part_issues WHERE id = iss)
          IS DISTINCT FROM (SELECT array_agg(id) FROM inventory_movements WHERE inbound_batch_id = ib_p AND movement_type = 'maintenance_issue') THEN
        RAISE EXCEPTION 'FIXTURE 266 ISSUE the issue row does not say what was issued';
    END IF;
    IF journal_entry_reversal_route(v_je) <> 'source_path' THEN
        RAISE EXCEPTION 'FIXTURE 266 ISSUE a part-issue entry must not be reversible from the journal page';
    END IF;
    PERFORM pg_temp.f266_recon(u_all, 'after the issue');

    -- ══════════════ RETURN ══════════════
    RAISE NOTICE 'fixture 266 · RETURN';
    v_msg := pg_temp.f266_do(u_view, format($q$SELECT return_spare_parts(%L, 1, %L, 'not needed')$q$, iss, d));
    PERFORM pg_temp.f266_expect('PERM return', v_msg, 'PERMISSION_DENIED|module.inventory.edit%');
    v_msg := pg_temp.f266_do(u_inv, format($q$SELECT return_spare_parts(%L, 1, %L, '  ')$q$, iss, d));
    PERFORM pg_temp.f266_expect('RETURN no reason', v_msg, 'PART_RETURN_REASON_REQUIRED%');
    v_msg := pg_temp.f266_do(u_inv, format($q$SELECT return_spare_parts(%L, 1, NULL, 'not needed')$q$, iss));
    PERFORM pg_temp.f266_expect('RETURN no date', v_msg, 'PART_RETURN_DATE_REQUIRED%');
    v_msg := pg_temp.f266_do(u_inv, format($q$SELECT return_spare_parts(%L, 1, %L, 'not needed')$q$, iss, d - 1));
    PERFORM pg_temp.f266_expect('RETURN before issue', v_msg, 'PART_RETURN_BEFORE_ISSUE|%');
    v_msg := pg_temp.f266_do(u_inv, format($q$SELECT return_spare_parts(%L, 5, %L, 'not needed')$q$, iss, d));
    PERFORM pg_temp.f266_expect('RETURN more than issued', v_msg, 'PART_RETURN_EXCEEDS_ISSUED|%|4|5%');
    v_msg := pg_temp.f266_do(u_inv, format($q$SELECT return_spare_parts(%L, 1, %L, 'not needed')$q$, gen_random_uuid(), d));
    PERFORM pg_temp.f266_expect('RETURN no issue', v_msg, 'PART_ISSUE_NOT_FOUND|%');
    v_j := pg_temp.f266_get(u_inv, format($q$SELECT return_spare_parts(%L, 1, %L, 'one blade was not needed')$q$, iss, d));
    ret := (v_j ->> 'return_id')::uuid;
    IF (SELECT remaining_qty FROM inbound_batches WHERE id = ib_p) <> 7 THEN
        RAISE EXCEPTION 'FIXTURE 266 RETURN remaining should be 7';
    END IF;
    IF (SELECT kind || ':' || returns_issue_id || ':' || reason || ':' || quantity FROM maintenance_part_issues WHERE id = ret)
         <> ('return:' || iss || ':one blade was not needed:1')
       OR (SELECT m.movement_type || ':' || m.qty_delta || ':' || m.stock_status FROM inventory_movements m
            WHERE m.id = (SELECT movement_ids[1] FROM maintenance_part_issues WHERE id = ret)) <> 'maintenance_return:1:available' THEN
        RAISE EXCEPTION 'FIXTURE 266 RETURN the return must cite its issue, carry its reason and one +1 maintenance_return';
    END IF;
    SELECT journal_entry_id INTO v_je FROM maintenance_part_issues WHERE id = ret;
    IF (SELECT string_agg(a.code || ':' || l.debit::numeric(14,2) || ':' || l.credit::numeric(14,2), ',' ORDER BY a.code) FROM journal_lines l JOIN accounts a ON a.id = l.account_id
         WHERE l.entry_id = v_je) IS DISTINCT FROM ('1200:' || round(v_x, 2) || ':0.00,6800:0.00:' || round(v_x, 2)) THEN
        RAISE EXCEPTION 'FIXTURE 266 RETURN expected the reverse posting Dr 1200 / Cr 6800';
    END IF;
    v_msg := pg_temp.f266_do(u_inv, format($q$SELECT return_spare_parts(%L, 4, %L, 'too many')$q$, iss, d));
    PERFORM pg_temp.f266_expect('RETURN only what is left', v_msg, 'PART_RETURN_EXCEEDS_ISSUED|%|3|4%');
    v_msg := pg_temp.f266_do(u_inv, format($q$SELECT return_spare_parts(%L, 1, %L, 'a return of a return')$q$, ret, d));
    PERFORM pg_temp.f266_expect('RETURN cites an issue, not a return', v_msg, 'PART_ISSUE_NOT_FOUND|%');
    PERFORM pg_temp.f266_recon(u_all, 'after the return');

    -- ══════════════ DIRECT ══════════════
    RAISE NOTICE 'fixture 266 · DIRECT';
    v_msg := pg_temp.f266_do(u_all, format($q$INSERT INTO maintenance_part_issues (maintenance_id, inbound_batch_id, kind, quantity, business_date, movement_ids)
                                               VALUES (%L, %L, 'issue', 1, %L, ARRAY[gen_random_uuid()])$q$, m_ok, ib_p, d));
    PERFORM pg_temp.f266_expect('DIRECT insert', v_msg, 'PART_ISSUES_THROUGH_FUNCTION_ONLY%');
    v_msg := pg_temp.f266_do(u_all, format($q$UPDATE maintenance_part_issues SET quantity = 9 WHERE id = %L$q$, iss));
    PERFORM pg_temp.f266_expect('DIRECT update', v_msg, 'PART_ISSUE_IMMUTABLE|update%');
    BEGIN
        DELETE FROM maintenance_part_issues WHERE id = ret;
        RAISE EXCEPTION 'FIXTURE 266 DIRECT owner delete passed';
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.f266_expect('DIRECT owner delete', SQLERRM, 'PART_ISSUE_IMMUTABLE|delete%');
    END;
    BEGIN
        PERFORM drain_stock(p_qty => 1, p_movement_type => 'maintenance_issue', p_business_date => d, p_inbound_batch_id => ib_p);
        RAISE EXCEPTION 'FIXTURE 266 DIRECT an owner path wrote a maintenance movement';
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.f266_expect('DIRECT owner movement', SQLERRM, 'MAINTENANCE_MOVEMENT_THROUGH_FUNCTION_ONLY|maintenance_issue%');
    END;

    -- ══════════════ CAPITAL ══════════════
    RAISE NOTICE 'fixture 266 · CAPITAL';
    BEGIN
        UPDATE equipment_maintenance SET capitalised = true, capitalisation_reason = 'late judgement' WHERE id = m_ok;
        RAISE EXCEPTION 'FIXTURE 266 CAPITAL a record with parts was capitalised';
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.f266_expect('CAPITAL flag', SQLERRM, 'MAINTENANCE_HAS_PARTS|FX266-M|%|1%');
    END;
    -- 费用单那条路(record_expense 带 p_maintenance_id)要求那条记录【已经】标了资本化(MAINTENANCE_NOT_CAPITALISED),而标资本化只在
    -- record_equipment_maintenance 记那一次活的时候 —— 一条出过件的记录今天没有一条应用里的路能被资本化。上面这道触发器守的是
    -- 将来任何一条把它翻成资本化的路(两列:capitalised 与 capitalised_expense_id;故障注入两格各拆一列)。

    -- ══════════════ REPRICE ══════════════
    RAISE NOTICE 'fixture 266 · REPRICE';
    -- 单元算术:10 件,在库 5,出给保养 3,价差 10 → 在库 5 · 保养 3 · 其余 2;两块占满(在库 7 + 保养 3)→ 其余恰好 0
    v_j := reprice_split(10, 5, 1, 2, 3);
    IF (v_j ->> 'inventory_share_usd')::numeric <> 5 OR (v_j ->> 'maintenance_share_usd')::numeric <> 3 OR (v_j ->> 'cost_share_usd')::numeric <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 266 REPRICE split %', v_j;
    END IF;
    v_j := reprice_split(3, 1, 0, 0.05, 2);
    IF (v_j ->> 'cost_share_usd')::numeric <> 0 OR (v_j ->> 'inventory_share_usd')::numeric + (v_j ->> 'maintenance_share_usd')::numeric <> 0.15 THEN
        RAISE EXCEPTION 'FIXTURE 266 REPRICE two shares that fill the batch must leave nothing for 5000, got %', v_j;
    END IF;
    IF (reprice_split(10, 4, 1, 2, 0) ->> 'maintenance_share_usd')::numeric <> 0 OR (reprice_split(10, 4, 1, 2, 0) ->> 'cost_share_usd')::numeric <> 6 THEN
        RAISE EXCEPTION 'FIXTURE 266 REPRICE with nothing issued to maintenance the split is the old one';
    END IF;
    v_j := pg_temp.f266_get(u_all, format('SELECT preview_reprice_inbound_batch(%L, 6, %L)', ib_p, v_base));
    IF (v_j ->> 'maintenance_share_usd')::numeric <> 3 OR (v_j ->> 'inventory_share_usd')::numeric <> 7 OR (v_j ->> 'cost_share_usd')::numeric <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 266 REPRICE preview %', v_j;
    END IF;
    v_j := pg_temp.f266_get(u_all, format('SELECT set_inbound_unit_price(%L, 6, %L)', ib_p, v_base));
    SELECT id INTO v_je FROM journal_entries WHERE source_type = 'purchase' AND source_id = ib_p ORDER BY code DESC LIMIT 1;
    IF (SELECT string_agg(a.code || ':' || l.debit::numeric(14,2) || ':' || l.credit::numeric(14,2), ',' ORDER BY a.code) FROM journal_lines l JOIN accounts a ON a.id = l.account_id
         WHERE l.entry_id = v_je) IS DISTINCT FROM '1200:7.00:0.00,2000:0.00:10.00,6800:3.00:0.00' THEN
        RAISE EXCEPTION 'FIXTURE 266 REPRICE expected 1200 Dr 7 · 6800 Dr 3 · 2000 Cr 10 and no 5000, got %',
            (SELECT string_agg(a.code || ':' || l.debit::numeric(14,2) || ':' || l.credit::numeric(14,2), ',' ORDER BY a.code) FROM journal_lines l JOIN accounts a ON a.id = l.account_id WHERE l.entry_id = v_je);
    END IF;
    PERFORM pg_temp.f266_recon(u_all, 'after the reprice');
    -- 改价之后再退 1 件:照今天的落地单价退,1200 仍逐分跟着剩余量走
    PERFORM pg_temp.f266_get(u_inv, format($q$SELECT return_spare_parts(%L, 1, %L, 'second blade back')$q$, iss, d));
    PERFORM pg_temp.f266_recon(u_all, 'after a return at the new price');

    -- ══════════════ HOLD ══════════════
    RAISE NOTICE 'fixture 266 · HOLD';
    v_j := pg_temp.f266_get(u_inv, format($q$SELECT issue_spare_parts(%L, %L, '[{"inbound_batch_id": "%s", "quantity": 2}]'::jsonb)$q$, m_ok, d, ib_h));
    iss_h := (v_j -> 'lines' -> 0 ->> 'issue_id')::uuid;
    PERFORM pg_temp.f266_get(u_all, format($q$SELECT open_ncr('manual', 'chipped blades in the box', p_inbound_batch_id => %L)$q$, ib_h));
    v_msg := pg_temp.f266_do(u_inv, format($q$SELECT issue_spare_parts(%L, %L, '[{"inbound_batch_id": "%s", "quantity": 1}]'::jsonb)$q$, m_ok, d, ib_h));
    PERFORM pg_temp.f266_expect('HOLD blocks issue', v_msg, 'QUALITY_HOLD_OPEN|%|NCR-%');
    v_msg := pg_temp.f266_do(u_inv, format($q$SELECT return_spare_parts(%L, 1, %L, 'returned while on hold')$q$, iss_h, d));
    PERFORM pg_temp.f266_expect('HOLD allows return', v_msg, 'OK');
    PERFORM pg_temp.f266_recon(u_all, 'after the hold');

    -- ══════════════ ROLL ══════════════
    RAISE NOTICE 'fixture 266 · ROLL';
    -- 出给保养的净额(全部 pcs 批):ib_p 出 4 退 2 → 2;ib_h 出 2 退 1 → 1 —— 合计 3
    v_j := pg_temp.f266_get(u_view, $q$SELECT jsonb_build_object('issued', sum(issued_to_maintenance),
                                   'closing', (SELECT closing FROM stock_rollforward_monthly r2 WHERE r2.unit = 'pcs' AND r2.month IS NOT NULL ORDER BY r2.month DESC LIMIT 1))
                                   FROM stock_rollforward_monthly r WHERE r.unit = 'pcs'$q$);
    IF (v_j ->> 'issued')::numeric <> -3
       OR (v_j ->> 'closing')::numeric IS DISTINCT FROM (SELECT sum(remaining_qty) FROM inbound_batches WHERE unit = 'pcs' AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'FIXTURE 266 ROLL issued-to-maintenance must be -3 and closing must tie to stock: % vs %', v_j,
            (SELECT sum(remaining_qty) FROM inbound_batches WHERE unit = 'pcs' AND deleted_at IS NULL);
    END IF;
    v_j := pg_temp.f266_get(u_view, format($q$SELECT jsonb_object_agg(line_key, x) FROM batch_balance_tree t
                                              WHERE t.root_id = %L AND t.node_type = 'fate' AND t.depth = 1$q$, ib_p));
    IF (v_j ->> 'maintenance')::numeric <> 2 OR (v_j ->> 'unexplained')::numeric <> 0 OR (v_j ->> 'on_hand')::numeric <> 8 THEN
        RAISE EXCEPTION 'FIXTURE 266 ROLL the balance tree must show maintenance 2, on hand 8 and nothing unexplained: %', v_j;
    END IF;

    -- ══════════════ V21 ══════════════
    RAISE NOTICE 'fixture 266 · V21';
    v_j := pg_temp.f266_get(u_all, $q$SELECT jsonb_agg(item_code ORDER BY item_code) FROM pending_values WHERE value_code = 'V21' AND item_code LIKE 'ZZ266-%'$q$);
    IF v_j IS DISTINCT FROM '["ZZ266-SP"]'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 266 V21 expected only the received spare part, got %', v_j;
    END IF;
    IF (SELECT count(*) FROM pending_values WHERE value_code = 'V21') <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 266 V21 postgres carries no JWT — the gated view must read empty for it';
    END IF;
    UPDATE materials SET safety_stock_qty = 2 WHERE id = v_sp;
    v_j := pg_temp.f266_get(u_all, $q$SELECT jsonb_agg(item_code) FROM pending_values WHERE value_code = 'V21' AND item_code LIKE 'ZZ266-%'$q$);
    IF v_j IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 266 V21 a spare part with a minimum stock must leave the list, got %', v_j;
    END IF;

    -- ══════════════ TRAIL ══════════════
    RAISE NOTICE 'fixture 266 · TRAIL';
    IF NOT EXISTS (SELECT 1 FROM change_log c WHERE c.table_name = 'maintenance_part_issues' AND c.op = 'INSERT' AND c.new ->> 'id' = ret::text
                     AND c.new ->> 'reason' = 'one blade was not needed') THEN
        RAISE EXCEPTION 'FIXTURE 266 TRAIL the return must be in the change log with its reason';
    END IF;
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 8 THEN
        RAISE EXCEPTION 'FIXTURE 266 TRAIL change-log coverage %', v_j;
    END IF;

    RAISE NOTICE 'FIXTURE 266 全部通过: REG · PERM · REFUSE · VOID · ISSUE · RETURN · DIRECT · CAPITAL · REPRICE · HOLD · ROLL · V21 · RECON · TRAIL';
END $$;

ROLLBACK;
