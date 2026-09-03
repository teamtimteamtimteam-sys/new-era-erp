-- 190 采购单携带税:税码在行上、税额存下来、而存下来的数【不随税率漂移】
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【为什么这一份存在】FA-PO-1 查清了 GST-2 把税放在费用/发票那一层,采购单上
-- 一列税都没有 —— 那描述的是【建成了什么】。**Tim 裁定建成的这个是错的。**
-- 采购单是供应商拿到的那张纸,它的总额必须是供应商将要开票的那个数;
-- 承诺出去的现金是含税的那一个,否则差 9%。
-- 证据已经在数据里:PO-2026-0008 的取消理由原文就是 "GST not included"。
--
-- 【每一臂钉什么】
-- A 【本地(TX)供应商】标准税率:gross = net + tax,而 tax = net × 9%。
-- B 【不在范围内(OP)的供应商】零新加坡 GST,而且【单据知道自己带着一条 OP 行】
--   —— PDF 与屏幕靠它决定要不要印那句"进口 GST 付给海关"。
--   ★ 委托书点名这一臂【第一个】做故障注入:错了,Tim 会把一个错的数发给供应商。
-- C 【没有默认税码的供应商】按名拒(TAX_CODE_REQUIRED|supplier),不算成零。
--   这一条与费用那一层【走的是同一支 resolve_tax_code】,不是第二份实现。
-- D 【存下来的税不随税率漂移】在一个整段回滚的事务里把 TX 的现行税率从 9 改成 30,
--   既有单据的税额【一分不动】;而【新开】的单据按新税率算 —— 两句一起断言,
--   否则"没动"可能只是因为根本没在算。
-- E 【屏幕与 PDF 是同一个数】po_document_data(PDF 读的)与
--   purchase_orders_masked / purchase_order_status(屏幕与清单读的)
--   对同一张单的 net/tax/gross 逐分相等 —— **断言,不靠人去看两张纸**。
-- F 【费用那条路与采购单这条路对得上分】同样的净额、同样的税码、同样的日期,
--   record_expense 算出来的税与采购单行上的税【逐分相同】。
--   两边今天都走 tax_amount_for —— 这一臂就是那次提取的验收。
-- G 【既有单据没有凭空长出税】本刀之前开的单 tax_total_ccy 为 NULL(不是 0),
--   而 NULL 与 0 在屏幕上说的是两句不同的话。
--
-- 【注入放在最后】三次,各打一条断言的要害。
-- 【自带数据】重建库里没有业务数据:自己建供应商、物料、采购单。
-- 日期落在 2027(README 第 4 条);税率按【下单日】解析,所以要 2027 年有 TX 税率
-- —— 引导数据里 TX 9% 自 2024-01-01 起 effective_to 为 NULL,覆盖得到。
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid; v_ccy text;
    s_tx uuid; s_op uuid; s_none uuid;
    v_mat uuid; v_res jsonb; v_doc jsonb;
    v_po_tx uuid; v_po_op uuid; v_po_new uuid;
    v_net numeric; v_tax numeric; v_gross numeric;
    v_tax_before numeric; v_line_tax numeric;
    v_msg text; v_denied boolean; v_n integer;
    v_exp jsonb; v_exp_tax numeric;
    v_def_amt text; v_inj text;
    v_v_net numeric; v_v_tax numeric; v_v_gross numeric;
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    UPDATE finance_settings SET locked_before = NULL;
    -- 【GST 必须是开着的】本 fixture 钉的就是携带税那条路。引导库里它可能是关的,
    -- 所以自己打开 —— 整段回滚,不影响任何人。登记号是硬前置(GST-3)。
    UPDATE finance_settings SET gst_registered = true,
        gst_registration_no = COALESCE(gst_registration_no, 'M9-FIX190');

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-190', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    -- 【原样定义在任何注入之前取齐】(fixture 74/75 的教训)
    v_def_amt := pg_get_functiondef('public.tax_amount_for(numeric, numeric)'::regprocedure);

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type, default_tax_code)
    VALUES ('ZZFIX190-TX', 'fixture 190 local supplier', 'SG', 'active', 'goods_supplier', 'TX')
    RETURNING id INTO s_tx;
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type, default_tax_code)
    VALUES ('ZZFIX190-OP', 'fixture 190 overseas supplier', 'CN', 'active', 'goods_supplier', 'OP')
    RETURNING id INTO s_op;
    -- ★【没有默认税码的那一家】—— C 臂。**不看国别**:Tim 的裁定是供应商记录上
    --   那个字段【就是】判据,系统不从 country 推断任何东西。
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type, default_tax_code)
    VALUES ('ZZFIX190-NONE', 'fixture 190 unset supplier', 'SG', 'active', 'goods_supplier', NULL)
    RETURNING id INTO s_none;

    -- 【照 fixture 103 那一行】materials_kind_stated 要求 kind_code 与
    -- may_be_processed 都给;状态轴由 guard_material_condition_axes 判,
    -- 所以 form_code / source_code 一并给齐 —— 本 fixture 要的只是"一个物料"。
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZFIX190-M', 'fixture 190 material', 'battery_material', true,
            'black_mass', 'end_of_life') RETURNING id INTO v_mat;

    -- ══════════ A · 本地供应商:标准税率 ═══════════════════════════════════
    RAISE NOTICE 'fixture 190 · 进入 A';
    v_res := create_purchase_order(s_tx, DATE '2027-03-10', DATE '2027-05-01', v_ccy, NULL,
        NULL, NULL, 'fixture 190 TX order',
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 100,
                                             'estimated_unit_price', 10)));
    v_po_tx := (v_res->>'purchase_order_id')::uuid;
    SELECT estimated_total_ccy, tax_total_ccy FROM purchase_orders WHERE id = v_po_tx
      INTO v_net, v_tax;
    IF v_net <> 1000 THEN
        RAISE EXCEPTION 'FIXTURE 190A 失败:净额应当是 1000(100 × 10),实得 %', v_net;
    END IF;
    -- 9% 是【下单日 2027-03-10 生效的那一个】,由 tax_rate_for 解析,不是写死的
    IF v_tax <> round(v_net * tax_rate_for('TX', DATE '2027-03-10') / 100.0, 2) THEN
        RAISE EXCEPTION 'FIXTURE 190A 失败:税额应当 = 净额 × 下单日的 TX 税率,实得 %(净额 % · 税率 %)',
            v_tax, v_net, tax_rate_for('TX', DATE '2027-03-10');
    END IF;
    IF v_tax <= 0 THEN
        RAISE EXCEPTION 'FIXTURE 190A 失败:本地标准税率的单据税额应当为正,实得 % —— 一个零会让 A 臂变成一次空转', v_tax;
    END IF;
    -- 行上也要存下来:税码 + 税率 + 税额,三件都在
    SELECT tax_code, tax_rate_pct, tax_amount_ccy FROM purchase_order_lines
     WHERE purchase_order_id = v_po_tx INTO v_msg, v_gross, v_line_tax;
    IF v_msg <> 'TX' OR v_gross IS NULL OR v_line_tax IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 190A 失败:行上应当存下 tax_code=TX、税率与税额三件,实得 code=% rate=% amt=%',
            COALESCE(v_msg,'NULL'), COALESCE(v_gross::text,'NULL'), COALESCE(v_line_tax::text,'NULL');
    END IF;

    -- ══════════ B · OP 供应商:零新加坡 GST,而且单据说得出来 ═══════════════
    RAISE NOTICE 'fixture 190 · 进入 B';
    v_res := create_purchase_order(s_op, DATE '2027-03-11', DATE '2027-05-01', v_ccy, NULL,
        NULL, NULL, 'fixture 190 OP order',
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 100,
                                             'estimated_unit_price', 10)));
    v_po_op := (v_res->>'purchase_order_id')::uuid;
    SELECT estimated_total_ccy, tax_total_ccy FROM purchase_orders WHERE id = v_po_op
      INTO v_net, v_tax;
    IF v_tax <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 190B 失败:一张【不在范围内】的单据不该带任何新加坡 GST,实得 % —— 这个数会印在发给供应商的纸上', v_tax;
    END IF;
    IF v_net <> 1000 THEN
        RAISE EXCEPTION 'FIXTURE 190B 失败:净额不该被 OP 影响,实得 %', v_net;
    END IF;
    SELECT tax_code FROM purchase_order_lines WHERE purchase_order_id = v_po_op INTO v_msg;
    IF v_msg <> 'OP' THEN
        RAISE EXCEPTION 'FIXTURE 190B 失败:行上的税码应当从供应商播成 OP,实得 %', COALESCE(v_msg,'NULL');
    END IF;
    -- ★ 单据必须【知道】自己带着一条 OP 行 —— 那句"进口 GST 付给海关"靠它
    v_doc := po_document_data(v_po_op);
    IF (v_doc->>'has_out_of_scope_line') <> 'true' THEN
        RAISE EXCEPTION 'FIXTURE 190B 失败:带 OP 行的单据要报 has_out_of_scope_line=true,实得 % —— 少了它,供应商读到的是一个没有解释的 GST 0.00',
            v_doc->>'has_out_of_scope_line';
    END IF;
    -- 而【不带】OP 行的那一张不该报 true(否则这个标志对谁都为真,等于没有)
    v_doc := po_document_data(v_po_tx);
    IF (v_doc->>'has_out_of_scope_line') <> 'false' THEN
        RAISE EXCEPTION 'FIXTURE 190B 失败:不带 OP 行的单据不该报 has_out_of_scope_line=true —— 一个恒真的标志说明不了任何事';
    END IF;

    -- ══════════ C · 没有默认税码:按名拒,不算成零 ═════════════════════════
    RAISE NOTICE 'fixture 190 · 进入 C';
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM create_purchase_order(s_none, DATE '2027-03-12', DATE '2027-05-01', v_ccy, NULL,
            NULL, NULL, 'fixture 190 unset order',
            jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 100,
                                                 'estimated_unit_price', 10)));
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR v_msg NOT LIKE 'TAX_CODE_REQUIRED|supplier%' THEN
        RAISE EXCEPTION 'FIXTURE 190C 失败:没有默认税码的供应商应当按名拒(TAX_CODE_REQUIRED|supplier),实得 % —— 一个悄悄的零会印在一张要发出去的纸上',
            COALESCE(v_msg, '(收下了)');
    END IF;
    -- 而【本行显式给码】仍然开得出来 —— 拒的是"没有人回答过",不是"这家供应商不能下单"
    v_res := create_purchase_order(s_none, DATE '2027-03-12', DATE '2027-05-01', v_ccy, NULL,
        NULL, NULL, 'fixture 190 unset but line-coded',
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 100,
                                             'estimated_unit_price', 10, 'tax_code', 'ZP')));
    SELECT tax_total_ccy FROM purchase_orders WHERE id = (v_res->>'purchase_order_id')::uuid INTO v_tax;
    IF v_tax <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 190C 失败:ZP(零税率进项)的单据税额应当是 0,实得 %', v_tax;
    END IF;

    -- ══════════ D · 存下来的税不随税率漂移 ═════════════════════════════════
    RAISE NOTICE 'fixture 190 · 进入 D';
    SELECT tax_total_ccy INTO v_tax_before FROM purchase_orders WHERE id = v_po_tx;
    -- 把现行 TX 税率改掉(整段回滚,不影响任何人)
    UPDATE tax_rates SET rate_pct = 30 WHERE tax_code = 'TX' AND effective_to IS NULL;
    SELECT tax_total_ccy INTO v_tax FROM purchase_orders WHERE id = v_po_tx;
    IF v_tax IS DISTINCT FROM v_tax_before THEN
        RAISE EXCEPTION 'FIXTURE 190D 失败:税率改了之后,既有单据存下来的税额应当【一分不动】(% → %)—— 那正是把它存下来的全部理由',
            v_tax_before, v_tax;
    END IF;
    -- 【而新开的单据按新税率算】—— 少了这一句,上面那个"没动"可能只是因为根本没在算
    v_res := create_purchase_order(s_tx, DATE '2027-03-13', DATE '2027-05-01', v_ccy, NULL,
        NULL, NULL, 'fixture 190 after rate change',
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 100,
                                             'estimated_unit_price', 10)));
    v_po_new := (v_res->>'purchase_order_id')::uuid;
    SELECT tax_total_ccy INTO v_tax FROM purchase_orders WHERE id = v_po_new;
    IF v_tax <> 300 THEN
        RAISE EXCEPTION 'FIXTURE 190D 失败:改成 30%% 之后【新】单的税应当是 300(1000 × 30%%),实得 % —— 说明新单也没有在按当日税率算', v_tax;
    END IF;
    UPDATE tax_rates SET rate_pct = 9 WHERE tax_code = 'TX' AND effective_to IS NULL;

    -- ══════════ E · 屏幕与 PDF 是同一个数 ══════════════════════════════════
    RAISE NOTICE 'fixture 190 · 进入 E';
    v_doc := po_document_data(v_po_tx);
    SELECT estimated_total_ccy, tax_total_ccy, gross_total_ccy
      INTO v_v_net, v_v_tax, v_v_gross
      FROM purchase_orders_masked WHERE id = v_po_tx;
    IF (v_doc->>'estimated_total_ccy')::numeric <> v_v_net
       OR (v_doc->>'tax_total_ccy')::numeric <> v_v_tax
       OR (v_doc->>'gross_total_ccy')::numeric <> v_v_gross THEN
        RAISE EXCEPTION 'FIXTURE 190E 失败:PDF 读的 po_document_data 与屏幕读的 purchase_orders_masked 对同一张单必须逐分相等 —— doc(%/%/%) vs view(%/%/%)',
            v_doc->>'estimated_total_ccy', v_doc->>'tax_total_ccy', v_doc->>'gross_total_ccy',
            v_v_net, v_v_tax, v_v_gross;
    END IF;
    -- 清单读的是第三张视图 —— 它也必须给同一个数
    SELECT estimated_total_ccy, tax_total_ccy, gross_total_ccy
      INTO v_v_net, v_v_tax, v_v_gross
      FROM purchase_order_status WHERE po_id = v_po_tx;
    IF (v_doc->>'gross_total_ccy')::numeric <> v_v_gross THEN
        RAISE EXCEPTION 'FIXTURE 190E 失败:清单(purchase_order_status)的含税额与单据的不一致:% vs %',
            v_doc->>'gross_total_ccy', v_v_gross;
    END IF;
    -- 而 gross 真的等于 net + tax(否则上面三处可能一致地错着)
    IF v_v_gross <> v_v_net + v_v_tax THEN
        RAISE EXCEPTION 'FIXTURE 190E 失败:含税额应当 = 净额 + 税额,实得 % ≠ % + %', v_v_gross, v_v_net, v_v_tax;
    END IF;

    -- ══════════ F · 费用那条路与采购单这条路,对得上分 ═════════════════════
    RAISE NOTICE 'fixture 190 · 进入 F';
    -- 同样的净额(1000)、同样的税码(TX)、同样的日期 —— 两条路必须给同一个税
    v_exp := record_expense(DATE '2027-03-10', '6100', 1000, v_ccy, NULL, 'unpaid', NULL,
                            s_tx, NULL, 'fixture 190 parity', NULL, NULL, NULL, 'TX');
    -- 【expenses 只存本位币的税额(tax_base)】而采购单行存的是【单据币种】的。
    -- 本 fixture 全程用本位币开单,所以 fx = 1,两者可比 —— 这一句写下来,
    -- 是因为换成外币单据时这一臂要改口径,而不是"它坏了"。
    SELECT tax_base INTO v_exp_tax FROM expenses WHERE id = (v_exp->>'expense_id')::uuid;
    SELECT tax_amount_ccy INTO v_line_tax FROM purchase_order_lines WHERE purchase_order_id = v_po_tx;
    IF v_exp_tax IS DISTINCT FROM v_line_tax THEN
        RAISE EXCEPTION 'FIXTURE 190F 失败:同样的净额/税码/日期,费用路算出 %,采购单行上是 % —— 两条路必须逐分相同,而它们今天走的是同一支 tax_amount_for',
            COALESCE(v_exp_tax::text,'NULL'), COALESCE(v_line_tax::text,'NULL');
    END IF;

    -- ══════════ G · 既有单据没有凭空长出税 ════════════════════════════════
    RAISE NOTICE 'fixture 190 · 进入 G';
    -- 造一张"本刀之前"的单:直接把三列抹成 NULL(模拟迁移之后的历史行)
    UPDATE purchase_order_lines SET tax_code = NULL, tax_rate_pct = NULL, tax_amount_ccy = NULL
     WHERE purchase_order_id = v_po_new;
    UPDATE purchase_orders SET tax_total_ccy = NULL WHERE id = v_po_new;
    SELECT carries_tax, tax_total_ccy, gross_total_ccy INTO v_denied, v_v_tax, v_v_gross
      FROM purchase_orders_masked WHERE id = v_po_new;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 190G 失败:税额合计为 NULL 的单据 carries_tax 应当是 false —— 屏幕靠它决定印「—」还是印 0.00';
    END IF;
    IF v_v_tax IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 190G 失败:历史单据的税额应当保持 NULL(不是 0),实得 %', v_v_tax;
    END IF;
    SELECT estimated_total_ccy INTO v_v_net FROM purchase_orders_masked WHERE id = v_po_new;
    IF v_v_gross <> v_v_net THEN
        RAISE EXCEPTION 'FIXTURE 190G 失败:没有税的单据,含税额应当等于净额,实得 % vs %', v_v_gross, v_v_net;
    END IF;

    -- ══════════ 注入 1(委托书点名【第一个】做的那一条)═════════════════════
    -- 让 tax_amount_for 恒返回 0 → A 臂必须变红。
    -- 【为什么先注这一条】它守的是"发给供应商的那个数对不对"。
    RAISE NOTICE 'fixture 190 · 注入 1';
    v_inj := replace(v_def_amt,
        'SELECT round(p_amount * p_rate_pct / 100.0, 2)',
        'SELECT 0::numeric');
    IF v_inj = v_def_amt THEN
        RAISE EXCEPTION 'FIXTURE 190 注入1 失败:在 tax_amount_for 里没找到那条算式的原文 —— 这个注入什么也没改';
    END IF;
    EXECUTE v_inj;
    v_res := create_purchase_order(s_tx, DATE '2027-06-10', DATE '2027-08-01', v_ccy, NULL,
        NULL, NULL, 'fixture 190 injection 1',
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 100,
                                             'estimated_unit_price', 10)));
    SELECT tax_total_ccy INTO v_tax FROM purchase_orders
     WHERE id = (v_res->>'purchase_order_id')::uuid;
    IF v_tax <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 190 注入1 失败:把 tax_amount_for 改成恒 0 之后,一张 TX 单的税应当是 0,实得 % —— 说明 A 臂读到的税【不是】这支函数算的,那条断言在守别的东西', v_tax;
    END IF;
    EXECUTE v_def_amt;   -- 还原

    -- ══════════ 注入 2:让 OP 也走标准税率 → B 臂必须变红 ═══════════════════
    RAISE NOTICE 'fixture 190 · 注入 2';
    UPDATE tax_rates SET rate_pct = 9 WHERE tax_code = 'OP' AND effective_to IS NULL;
    v_res := create_purchase_order(s_op, DATE '2027-06-11', DATE '2027-08-01', v_ccy, NULL,
        NULL, NULL, 'fixture 190 injection 2',
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 100,
                                             'estimated_unit_price', 10)));
    SELECT tax_total_ccy INTO v_tax FROM purchase_orders
     WHERE id = (v_res->>'purchase_order_id')::uuid;
    IF v_tax <> 90 THEN
        RAISE EXCEPTION 'FIXTURE 190 注入2 失败:把 OP 的税率改成 9%% 之后,那张单的税应当变成 90,实得 % —— 说明 B 臂的零【不是】从 OP 的税率来的(比如被写死成了零)', v_tax;
    END IF;
    UPDATE tax_rates SET rate_pct = 0 WHERE tax_code = 'OP' AND effective_to IS NULL;

    -- ══════════ 注入 3:给那家没有默认码的供应商设一个码 → C 臂必须变红 ═════
    RAISE NOTICE 'fixture 190 · 注入 3';
    UPDATE suppliers SET default_tax_code = 'TX' WHERE id = s_none;
    v_denied := false;
    BEGIN
        PERFORM create_purchase_order(s_none, DATE '2027-06-12', DATE '2027-08-01', v_ccy, NULL,
            NULL, NULL, 'fixture 190 injection 3',
            jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 100,
                                                 'estimated_unit_price', 10)));
    EXCEPTION WHEN OTHERS THEN v_denied := true;
    END;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 190 注入3 失败:给那家供应商设了默认码之后就【不该】再拒 —— 说明 C 臂拒的不是"没有人回答过这个问题"';
    END IF;
END $$;
ROLLBACK;
