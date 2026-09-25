-- 221 ROLE-1 Batch 3a · 录过数的人永远不能过账;四个登记的缺口关上(Tim 2026-09-25,Batch 3 grilling Q2–Q5 · Q10–Q12)
--
-- 【它钉的是什么】
--   S  盘点:开单与录数归 action.stocktake_count,过账归 action.stocktake_post,取消仍归 module.stocktakes.edit
--      S1 只持 stocktakes.edit 的人开不了单、录不了数、过不了账 → PERMISSION_DENIED|<码>;取消得了
--      S2 开单人由函数写(auth.uid()),不经客户端
--      S3 ★ 三张表的直连写一律按名拒 STOCKTAKE_THROUGH_FUNCTION_ONLY(状态写成 posted、插行、插"谁数的")
--      S4 ★ 重录【不抹掉】前一个录数的人:stocktake_counts 两行、stocktake_lines 一行(最后的数)
--      S5 ★★ 第一个录数的人(他也持过账码)过不了账 → STOCKTAKE_COUNTER_CANNOT_POST|单号 —— 哪怕别人重录过
--      S6 ★★ 按人认:录数人的【另一个账号】持过账码,也过不了
--      S7 开单人持过账码也过不了 → SELF_APPROVAL_FORBIDDEN|raiser(那条腿先判)
--      S8 另一个人(财务)过得了:posted、adjustment −10、分录 Dr 5200 / Cr 1200 = 100.00(到岸成本 10)
--      S9 过账之后再录数 → STOCKTAKE_NOT_OPEN|posted(此前这一句只在屏幕上)
--      S10 stocktake_counts 只增不改:属主路径 UPDATE / DELETE 也 → STOCKTAKE_COUNT_APPEND_ONLY|单号
--      S11 ★ 故障注入:拿掉 stocktakes 上的直连写守卫,持 stocktakes.edit 的人直连把状态写成 posted
--          就变成【零行、不报错】(SILENT-1 那一族)—— 守卫是承重的
--   G2 ★ is_final 直连改 → ASSAY_FINAL_THROUGH_FUNCTION_ONLY;同一行改备注照旧放行
--   G3 ★ 已定价的收货换供应商 / 采购单 → RECEIPT_PRICED_SOURCE_FROZEN|收货(直连与属主路径都拒);
--      未定价的照旧换得了
--   G4 ★ 提单人之外没人批得动:assert_other_decider 对同一个人的另一个账号按名拒,对别人放行,
--      审批关着时不拒;六支付款申请提交与工资申请提交都调它(目录派生,逐支点名)
--   (到岸成本三个读者的受众在 fixture 163 与 174;工资申请那一句在 fixture 218 E0。)
--
-- 自带数据(README 第 2 条);锁期自己设(README 第 4 条)。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '180s';

CREATE FUNCTION pg_temp.f221_try(p_sql text, p_auth boolean DEFAULT false) RETURNS text
LANGUAGE plpgsql AS $f$
BEGIN
    IF p_auth THEN EXECUTE 'SET LOCAL ROLE authenticated'; END IF;
    EXECUTE p_sql;
    EXECUTE 'RESET ROLE';
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    RETURN SQLERRM;
END;
$f$;

CREATE FUNCTION pg_temp.f221_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', p_user), true)
$f$;

DO $$
DECLARE
    u_wh    uuid := gen_random_uuid();   -- 仓库:开单、录数(还持 stocktakes.edit,与线上同形)
    u_wh2   uuid := gen_random_uuid();   -- 第二个录数的人;在册员工 e_wh2 的主账号
    u_both  uuid := gen_random_uuid();   -- 录数码 + 过账码都持(admin 的形状)
    u_fin   uuid := gen_random_uuid();   -- 财务:过账
    u_fin2  uuid := gen_random_uuid();   -- ★ e_wh2 的另一个账号,持过账码
    u_edit  uuid := gen_random_uuid();   -- 只持 module.stocktakes.edit(+ view)—— 从本刀起只能取消
    u_inb   uuid := gen_random_uuid();   -- module.inbound.edit + view(记录化验、改收货)
    u_l1    uuid := gen_random_uuid();   -- 一级审批
    u_cfo   uuid := gen_random_uuid();   -- 二级审批;在册员工 e_cfo 的主账号
    u_cfo2  uuid := gen_random_uuid();   -- ★ e_cfo 的另一个账号,持财务码
    r_wh uuid; r_both uuid; r_fin uuid; r_edit uuid; r_inb uuid; r_l1 uuid; r_l2 uuid;
    e_wh2 uuid := gen_random_uuid();
    e_cfo uuid := gen_random_uuid();
    v_today date := CURRENT_DATE;
    v_sup uuid; v_sup2 uuid; v_mat uuid; b1 uuid; b_priced uuid; b_unpriced uuid; v_po uuid; v_pol uuid;
    st1 uuid; st2 uuid; st_code text; v_res jsonb; v_msg text; v_n int; v_je int; v_amt numeric;
    v_asy uuid; f text;
BEGIN
    -- ── 布景 ──────────────────────────────────────────────────────────────
    INSERT INTO auth.users (id, email_confirmed_at) VALUES
        (u_wh, now()), (u_wh2, now()), (u_both, now()), (u_fin, now()), (u_fin2, now()),
        (u_edit, now()), (u_inb, now()), (u_l1, now()), (u_cfo, now()), (u_cfo2, now());
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx221-wh','f','f',true)   RETURNING id INTO r_wh;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx221-both','f','f',true) RETURNING id INTO r_both;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx221-fin','f','f',true)  RETURNING id INTO r_fin;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx221-edit','f','f',true) RETURNING id INTO r_edit;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx221-inb','f','f',true)  RETURNING id INTO r_inb;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx221-l1','f','f',true)   RETURNING id INTO r_l1;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx221-l2','f','f',true)   RETURNING id INTO r_l2;
    INSERT INTO role_permissions (role_id, permission_code) VALUES
        (r_wh, 'action.stocktake_count'), (r_wh, 'module.stocktakes.edit'), (r_wh, 'module.stocktakes.view'),
        (r_wh, 'module.inbound.view'),
        (r_both, 'action.stocktake_count'), (r_both, 'action.stocktake_post'), (r_both, 'module.stocktakes.view'),
        (r_fin, 'action.stocktake_post'), (r_fin, 'module.stocktakes.view'),
        (r_fin, 'module.finance.view'), (r_fin, 'module.finance.edit'), (r_fin, 'module.hr.view'), (r_fin, 'module.hr.edit'),
        (r_fin, 'data.view_pay'), (r_fin, 'data.view_prices'), (r_fin, 'data.view_purchase_prices'),
        (r_edit, 'module.stocktakes.edit'), (r_edit, 'module.stocktakes.view'),
        (r_inb, 'module.inbound.edit'), (r_inb, 'module.inbound.view');
    -- 两级审批:每一条链的门都持(否则开关先为别的链变红)
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_l1, code FROM permissions;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_l2, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES
        (u_wh, r_wh), (u_wh2, r_wh), (u_both, r_both), (u_fin, r_fin), (u_fin2, r_fin),
        (u_edit, r_edit), (u_inb, r_inb), (u_l1, r_l1), (u_cfo, r_l2), (u_cfo2, r_fin);

    INSERT INTO employees (id, code, legal_name, employment_type, work_category, hire_date, user_id) VALUES
        (e_wh2, 'FX221-WH2', 'FX221 Counter', 'full_time', 'office', v_today - 400, u_wh2),
        (e_cfo, 'FX221-CFO', 'FX221 CFO',     'full_time', 'office', v_today - 400, u_cfo);
    INSERT INTO employee_accounts (user_id, employee_id) VALUES (u_fin2, e_wh2), (u_cfo2, e_cfo);

    PERFORM set_config('request.jwt.claims', '', true);
    UPDATE finance_settings SET locked_before = NULL;
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approval_level1_role_code = 'fx221-l1', approval_level2_role_code = 'fx221-l2',
                                approval_threshold_base = 1000;
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = true;

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type) VALUES
        ('ZZFIX221-S', 'fixture 221 supplier', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type) VALUES
        ('ZZFIX221-S2', 'fixture 221 supplier 2', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup2;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZFIX221-M', 'fixture 221 material', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO v_mat;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, arrival_date,
                                 source_reason_code, source_reason_note) VALUES
        ('ZZFIX221-IB1', v_mat, v_sup, 100, 100, v_today - 1, 'other', 'fixture 221'),
        ('ZZFIX221-IBP', v_mat, v_sup, 10, 10, v_today - 1, 'other', 'fixture 221'),
        ('ZZFIX221-IBU', v_mat, v_sup, 10, 10, v_today - 1, 'other', 'fixture 221');
    SELECT id INTO b1 FROM inbound_batches WHERE code = 'ZZFIX221-IB1';
    SELECT id INTO b_priced FROM inbound_batches WHERE code = 'ZZFIX221-IBP';
    SELECT id INTO b_unpriced FROM inbound_batches WHERE code = 'ZZFIX221-IBU';
    -- b1 与 b_priced 定过价(属主路径直写,fixture 220 同一个手法);b_unpriced 没有
    PERFORM set_config('evoltrya.price_ctx', 'fixture', true);
    UPDATE inbound_batches SET unit_price = 10 WHERE id IN (b1, b_priced);
    PERFORM set_config('evoltrya.price_ctx', '', true);

    -- ══════════ S1 · 旧码只剩取消 ══════════
    PERFORM pg_temp.f221_as(u_edit);
    v_msg := pg_temp.f221_try('SELECT open_stocktake(NULL)');
    IF v_msg <> 'PERMISSION_DENIED|action.stocktake_count' THEN
        RAISE EXCEPTION 'FIXTURE 221S1 失败:只持 stocktakes.edit 的人开单应当 PERMISSION_DENIED|action.stocktake_count,实得 %', v_msg; END IF;

    -- ══════════ S2 · 开单人由函数写 ══════════
    PERFORM pg_temp.f221_as(u_wh);
    v_res := open_stocktake('fixture 221');
    st1 := (v_res->>'stocktake_id')::uuid; st_code := v_res->>'code';
    IF (SELECT created_by FROM stocktakes WHERE id = st1) IS DISTINCT FROM u_wh THEN
        RAISE EXCEPTION 'FIXTURE 221S2 失败:开单人应当是 auth.uid()'; END IF;
    PERFORM pg_temp.f221_as(u_edit);
    v_msg := pg_temp.f221_try(format('SELECT record_stocktake_count(%L, %L, NULL, 5)', st1, b1));
    IF v_msg <> 'PERMISSION_DENIED|action.stocktake_count' THEN
        RAISE EXCEPTION 'FIXTURE 221S1 失败:只持 stocktakes.edit 的人录数应当 PERMISSION_DENIED|action.stocktake_count,实得 %', v_msg; END IF;
    v_msg := pg_temp.f221_try(format('SELECT post_stocktake(%L)', st1));
    IF v_msg <> 'PERMISSION_DENIED|action.stocktake_post' THEN
        RAISE EXCEPTION 'FIXTURE 221S1 失败:只持 stocktakes.edit 的人过账应当 PERMISSION_DENIED|action.stocktake_post,实得 %', v_msg; END IF;

    -- ══════════ S3 · ★ 直连写一律按名拒 ══════════
    PERFORM pg_temp.f221_as(u_edit);
    v_msg := pg_temp.f221_try(format('UPDATE stocktakes SET status = %L WHERE id = %L', 'posted', st1), true);
    IF v_msg <> 'STOCKTAKE_THROUGH_FUNCTION_ONLY' THEN
        RAISE EXCEPTION 'FIXTURE 221S3 失败:直连把状态写成 posted 应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f221_try(format('UPDATE stocktakes SET created_by = %L WHERE id = %L', u_edit, st1), true);
    IF v_msg <> 'STOCKTAKE_THROUGH_FUNCTION_ONLY' THEN
        RAISE EXCEPTION 'FIXTURE 221S3 失败:直连改写开单人应当按名拒,实得 %', v_msg; END IF;
    PERFORM pg_temp.f221_as(u_wh);
    v_msg := pg_temp.f221_try(format('INSERT INTO stocktakes (notes) VALUES (%L)', 'direct'), true);
    IF v_msg <> 'STOCKTAKE_THROUGH_FUNCTION_ONLY' THEN
        RAISE EXCEPTION 'FIXTURE 221S3 失败:直连开单应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f221_try(format('INSERT INTO stocktake_lines (stocktake_id, inbound_batch_id, book_qty, counted_qty) VALUES (%L, %L, 100, 1)', st1, b1), true);
    IF v_msg <> 'STOCKTAKE_THROUGH_FUNCTION_ONLY' THEN
        RAISE EXCEPTION 'FIXTURE 221S3 失败:直连插盘点行应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f221_try(format('INSERT INTO stocktake_counts (stocktake_id, stocktake_line_id, inbound_batch_id, book_qty, counted_qty, counted_by) VALUES (%L, gen_random_uuid(), %L, 100, 1, %L)', st1, b1, u_fin), true);
    IF v_msg <> 'STOCKTAKE_THROUGH_FUNCTION_ONLY' THEN
        RAISE EXCEPTION 'FIXTURE 221S3 失败:直连插"谁数的"应当按名拒,实得 %', v_msg; END IF;

    -- ══════════ S4 · ★ 重录不抹掉前一个录数的人 ══════════
    PERFORM pg_temp.f221_as(u_both);
    PERFORM record_stocktake_count(st1, b1, NULL, 95, 'first');
    PERFORM pg_temp.f221_as(u_wh2);
    PERFORM record_stocktake_count(st1, b1, NULL, 90, 'recount');
    SELECT count(*) INTO v_n FROM stocktake_counts WHERE stocktake_id = st1;
    IF v_n <> 2 OR NOT EXISTS (SELECT 1 FROM stocktake_counts WHERE stocktake_id = st1 AND counted_by = u_both AND counted_qty = 95)
                OR NOT EXISTS (SELECT 1 FROM stocktake_counts WHERE stocktake_id = st1 AND counted_by = u_wh2 AND counted_qty = 90) THEN
        RAISE EXCEPTION 'FIXTURE 221S4 失败:两次录数应当留下两行"谁数的"(u_both 95 · u_wh2 90),实得 % 行', v_n; END IF;
    IF (SELECT count(*) FROM stocktake_lines WHERE stocktake_id = st1) <> 1
       OR (SELECT counted_qty FROM stocktake_lines WHERE stocktake_id = st1) <> 90
       OR (SELECT created_by FROM stocktake_lines WHERE stocktake_id = st1) IS DISTINCT FROM u_wh2 THEN
        RAISE EXCEPTION 'FIXTURE 221S4 失败:盘点行应当只有一行、实点 90、created_by 是最后录数的 u_wh2'; END IF;
    v_msg := pg_temp.f221_try(format('SELECT record_stocktake_count(%L, %L, NULL, -1)', st1, b1));
    IF v_msg NOT LIKE 'STOCKTAKE_COUNT_QTY_INVALID|%' THEN
        RAISE EXCEPTION 'FIXTURE 221S4 失败:负的实点数应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f221_try(format('SELECT record_stocktake_count(%L, NULL, NULL, 1)', st1));
    IF v_msg NOT LIKE 'STOCKTAKE_COUNT_BATCH_REQUIRED|%' THEN
        RAISE EXCEPTION 'FIXTURE 221S4 失败:不带批次应当按名拒,实得 %', v_msg; END IF;

    -- ══════════ S5 · ★★ 第一个录数的人过不了账(别人重录过也一样)══════════
    PERFORM pg_temp.f221_as(u_both);
    v_msg := pg_temp.f221_try(format('SELECT post_stocktake(%L)', st1));
    IF v_msg <> 'STOCKTAKE_COUNTER_CANNOT_POST|' || st_code THEN
        RAISE EXCEPTION 'FIXTURE 221S5 失败:录过数的人过账应当 STOCKTAKE_COUNTER_CANNOT_POST|%,实得 %', st_code, v_msg; END IF;

    -- ══════════ S6 · ★★ 按人认:录数人的另一个账号也过不了 ══════════
    PERFORM pg_temp.f221_as(u_fin2);
    v_msg := pg_temp.f221_try(format('SELECT post_stocktake(%L)', st1));
    IF v_msg <> 'STOCKTAKE_COUNTER_CANNOT_POST|' || st_code THEN
        RAISE EXCEPTION 'FIXTURE 221S6 失败:录数人(e_wh2)的另一个账号过账应当按人拒,实得 %', v_msg; END IF;

    -- ══════════ S7 · 开单人持过账码也过不了(开单人那条腿先判)══════════
    PERFORM pg_temp.f221_as(u_both);
    st2 := (open_stocktake(NULL)->>'stocktake_id')::uuid;
    v_msg := pg_temp.f221_try(format('SELECT post_stocktake(%L)', st2));
    IF v_msg <> 'SELF_APPROVAL_FORBIDDEN|raiser' THEN
        RAISE EXCEPTION 'FIXTURE 221S7 失败:开单人过账应当 SELF_APPROVAL_FORBIDDEN|raiser,实得 %', v_msg; END IF;
    -- 取消仍归 module.stocktakes.edit
    PERFORM pg_temp.f221_as(u_edit);
    PERFORM cancel_stocktake(st2, 'fixture 221 S7');
    IF (SELECT status FROM stocktakes WHERE id = st2) <> 'cancelled' THEN
        RAISE EXCEPTION 'FIXTURE 221S1 失败:持 stocktakes.edit 的人应当取消得了'; END IF;

    -- ══════════ S8 · 财务过得了;计值照旧 ══════════
    SELECT count(*) INTO v_je FROM journal_entries;
    PERFORM pg_temp.f221_as(u_fin);
    PERFORM post_stocktake(st1);
    IF (SELECT status FROM stocktakes WHERE id = st1) <> 'posted'
       OR (SELECT remaining_qty FROM inbound_batches WHERE id = b1) <> 90
       OR NOT EXISTS (SELECT 1 FROM inventory_movements WHERE inbound_batch_id = b1 AND movement_type = 'adjustment' AND qty_delta = -10) THEN
        RAISE EXCEPTION 'FIXTURE 221S8 失败:财务过账应当 posted、剩余 90、一笔 −10 的 adjustment'; END IF;
    SELECT sum(l.credit) INTO v_amt FROM journal_lines l JOIN accounts a ON a.id = l.account_id
      JOIN journal_entries j ON j.id = l.entry_id
     WHERE j.source_type = 'stocktake' AND j.source_id = st1 AND a.code = '1200';
    IF (SELECT count(*) FROM journal_entries) <> v_je + 1 OR v_amt IS DISTINCT FROM 100.00 THEN
        RAISE EXCEPTION 'FIXTURE 221S8 失败:盘亏 10 × 到岸 10 应当贷 1200 = 100.00,实得 %', COALESCE(v_amt::text, 'NULL'); END IF;

    -- ══════════ S9 · 过账之后再录数 ══════════
    PERFORM pg_temp.f221_as(u_wh);
    v_msg := pg_temp.f221_try(format('SELECT record_stocktake_count(%L, %L, NULL, 1)', st1, b1));
    IF v_msg <> 'STOCKTAKE_NOT_OPEN|posted' THEN
        RAISE EXCEPTION 'FIXTURE 221S9 失败:过账之后录数应当 STOCKTAKE_NOT_OPEN|posted,实得 %', v_msg; END IF;

    -- ══════════ S10 · 只增不改(属主路径也拒)══════════
    v_msg := pg_temp.f221_try(format('UPDATE stocktake_counts SET counted_qty = 0 WHERE stocktake_id = %L', st1));
    IF v_msg <> 'STOCKTAKE_COUNT_APPEND_ONLY|' || st_code THEN
        RAISE EXCEPTION 'FIXTURE 221S10 失败:属主路径改"谁数的"应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f221_try(format('DELETE FROM stocktake_counts WHERE stocktake_id = %L', st1));
    IF v_msg <> 'STOCKTAKE_COUNT_APPEND_ONLY|' || st_code THEN
        RAISE EXCEPTION 'FIXTURE 221S10 失败:属主路径删"谁数的"应当按名拒,实得 %', v_msg; END IF;

    -- ══════════ G2 · ★ is_final 只走函数 ══════════
    INSERT INTO laboratories (code, name_en, name_zh, sort_order) VALUES ('Fixture Lab 221', 'Fixture Lab 221', 'Fixture Lab 221', 99);
    PERFORM pg_temp.f221_as(u_inb);
    v_asy := (record_assay_result(p_assay_date => v_today, p_metals => jsonb_build_array(jsonb_build_object('metal','ni','content_pct',30)),
                                  p_lab_name => 'Fixture Lab 221', p_inbound_batch_id => b_unpriced,
                                  p_weight_basis => 'as_received', p_result_party => 'ours')->>'assay_result_id')::uuid;
    v_msg := pg_temp.f221_try(format('UPDATE assay_results SET is_final = false WHERE id = %L', v_asy), true);
    IF v_msg <> 'ASSAY_FINAL_THROUGH_FUNCTION_ONLY' THEN
        RAISE EXCEPTION 'FIXTURE 221G2 失败:直连改 is_final 应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f221_try(format('UPDATE assay_results SET notes = %L WHERE id = %L', 'fixture 221 note', v_asy), true);
    IF v_msg <> 'OK' OR (SELECT notes FROM assay_results WHERE id = v_asy) IS DISTINCT FROM 'fixture 221 note' THEN
        RAISE EXCEPTION 'FIXTURE 221G2 失败(对照):同一行改备注应当照旧放行,实得 %', v_msg; END IF;

    -- ══════════ G3 · ★ 已定价的收货不换来路 ══════════
    PERFORM pg_temp.f221_as(u_inb);
    v_msg := pg_temp.f221_try(format('UPDATE inbound_batches SET supplier_id = %L WHERE id = %L', v_sup2, b_priced), true);
    IF v_msg <> 'RECEIPT_PRICED_SOURCE_FROZEN|ZZFIX221-IBP' THEN
        RAISE EXCEPTION 'FIXTURE 221G3 失败:已定价的收货直连换供应商应当按名拒,实得 %', v_msg; END IF;
    -- 属主路径也拒(没有一支属主函数改这三列;将来哪一支改了,照样撞上)
    v_msg := pg_temp.f221_try(format('UPDATE inbound_batches SET supplier_id = %L WHERE id = %L', v_sup2, b_priced));
    IF v_msg <> 'RECEIPT_PRICED_SOURCE_FROZEN|ZZFIX221-IBP' THEN
        RAISE EXCEPTION 'FIXTURE 221G3 失败:属主路径换供应商也应当按名拒,实得 %', v_msg; END IF;
    INSERT INTO purchase_orders (code, supplier_id, order_date, status, currency, fx_rate)
    VALUES ('ZZFIX221-PO', v_sup, v_today - 2, 'confirmed', (SELECT code FROM currencies WHERE is_base LIMIT 1), 1) RETURNING id INTO v_po;
    INSERT INTO purchase_order_lines (purchase_order_id, line_no, material_id, quantity, unit)
    VALUES (v_po, 1, v_mat, 10, 'kg') RETURNING id INTO v_pol;
    v_msg := pg_temp.f221_try(format('UPDATE inbound_batches SET purchase_order_id = %L, purchase_order_line_id = %L WHERE id = %L', v_po, v_pol, b_priced));
    IF v_msg <> 'RECEIPT_PRICED_SOURCE_FROZEN|ZZFIX221-IBP' THEN
        RAISE EXCEPTION 'FIXTURE 221G3 失败:已定价的收货挂上采购单应当按名拒,实得 %', v_msg; END IF;
    -- 对照:未定价的照旧换得了
    v_msg := pg_temp.f221_try(format('UPDATE inbound_batches SET supplier_id = %L WHERE id = %L', v_sup2, b_unpriced), true);
    IF v_msg <> 'OK' OR (SELECT supplier_id FROM inbound_batches WHERE id = b_unpriced) IS DISTINCT FROM v_sup2 THEN
        RAISE EXCEPTION 'FIXTURE 221G3 失败(对照):未定价的收货应当换得了供应商,实得 %', v_msg; END IF;

    -- ══════════ G4 · ★ 提单人之外没人批得动 ══════════
    -- 二级此刻只有 u_cfo 一个人;u_cfo2 是同一个人的另一个账号
    PERFORM pg_temp.f221_as(u_cfo2);
    v_msg := pg_temp.f221_try($q$SELECT assert_other_decider('payment_request', 'decide_payment_request', 2::smallint, 'PAYMENT_REQUEST_NO_OTHER_DECIDER')$q$);
    IF v_msg <> 'PAYMENT_REQUEST_NO_OTHER_DECIDER' THEN
        RAISE EXCEPTION 'FIXTURE 221G4 失败:同一个人的另一个账号提付款申请应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f221_try($q$SELECT assert_other_decider('payroll_request', 'decide_payroll_request', 2::smallint, 'PAYROLL_NO_OTHER_DECIDER|X')$q$);
    IF v_msg <> 'PAYROLL_NO_OTHER_DECIDER|X' THEN
        RAISE EXCEPTION 'FIXTURE 221G4 失败:同一个人的另一个账号提工资申请应当按名拒,实得 %', v_msg; END IF;
    PERFORM pg_temp.f221_as(u_fin);
    v_msg := pg_temp.f221_try($q$SELECT assert_other_decider('payment_request', 'decide_payment_request', 2::smallint, 'PAYMENT_REQUEST_NO_OTHER_DECIDER')$q$);
    IF v_msg <> 'OK' THEN
        RAISE EXCEPTION 'FIXTURE 221G4 失败(对照):别人提的,CFO 批得了,不该拒,实得 %', v_msg; END IF;
    -- 目录派生:七支提交函数都调它(逐支点名,哪一支漏了就在这里红)
    FOREACH f IN ARRAY ARRAY['submit_payment_request', 'submit_payment_reversal_request', 'submit_bank_transfer_request',
                             'submit_bank_transfer_reversal_request', 'submit_wht_remittance_request',
                             'submit_wht_remittance_reversal_request'] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = f
                         AND prosrc LIKE '%assert_other_decider(''payment_request'', ''decide_payment_request''%') THEN
            RAISE EXCEPTION 'FIXTURE 221G4 失败:% 没有调 assert_other_decider(payment_request)', f; END IF;
    END LOOP;
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = 'submit_payroll_request'
                     AND prosrc LIKE '%assert_other_decider(''payroll_request'', ''decide_payroll_request''%') THEN
        RAISE EXCEPTION 'FIXTURE 221G4 失败:submit_payroll_request 没有调 assert_other_decider(payroll_request)'; END IF;
    IF has_function_privilege('authenticated', 'public.assert_other_decider(text, text, smallint, text)', 'EXECUTE') THEN
        RAISE EXCEPTION 'FIXTURE 221G4 失败:assert_other_decider 应当从 authenticated 收回'; END IF;
    -- 审批关着时不拒
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = false;
    PERFORM pg_temp.f221_as(u_cfo2);
    v_msg := pg_temp.f221_try($q$SELECT assert_other_decider('payment_request', 'decide_payment_request', 2::smallint, 'PAYMENT_REQUEST_NO_OTHER_DECIDER')$q$);
    IF v_msg <> 'OK' THEN
        RAISE EXCEPTION 'FIXTURE 221G4 失败:审批关着时不该拒,实得 %', v_msg; END IF;

    -- ══════════ S11 · ★ 故障注入:直连写守卫是承重的 ══════════
    PERFORM pg_temp.f221_as(u_wh);
    st2 := (open_stocktake(NULL)->>'stocktake_id')::uuid;
    DROP TRIGGER trg_stocktakes_direct_write ON public.stocktakes;
    PERFORM pg_temp.f221_as(u_edit);
    v_msg := pg_temp.f221_try(format('UPDATE stocktakes SET status = %L WHERE id = %L', 'posted', st2), true);
    IF v_msg <> 'OK' THEN
        RAISE EXCEPTION 'FIXTURE 221S11 注入无效:拿掉守卫之后直连写应当【不报错】(零行),实得 % —— 这一臂在空转', v_msg; END IF;
    IF (SELECT status FROM stocktakes WHERE id = st2) <> 'open' THEN
        RAISE EXCEPTION 'FIXTURE 221S11 失败:没有写策略,直连写应当零行'; END IF;
    RAISE NOTICE 'fixture 221 S11 · 已证:拿掉守卫,直连把状态写成 posted 是一次【零行、不报错】的"成功"—— 守卫是让它按名拒的那一道';

    RAISE NOTICE 'FIXTURE 221 全部通过:S 盘点录数与过账分离(开单 · 直连 · 重录留痕 · 录数人与他的另一个账号 · 开单人 · 财务过账 · 过账后 · 只增不改 · 注入)· G2 is_final · G3 已定价收货的来路 · G4 提单人之外没人批得动';
END $$;
ROLLBACK;
