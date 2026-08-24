-- 129 供应报在【开票】那一期,而 F5 的销项侧从单据推导(GST-2)
--
-- 【这份 fixture 要钉住的六件事】
--   (A) 单据【携带】税:税码与税率在开票那一刻【冻在行上】,按发票自己的
--       开票日解析 —— 不是今天的设置,也不是一个标量;
--   (B) ★【裁定本身】★ 供应报在【开票】那一期。销售落在上一季、发票落在下一季时,
--       box1 出现在【发票】那一季,而上一季是零。**这一臂就是 Tim 2026-08-25
--       那句裁定的全部内容** —— 它红了,就说明接错了税点;
--   (C) 勾稽【三处说法、两条比较】,而两条都真的会分开:
--       单据 vs 法令(改一个冻住的税额)、单据 vs 总账(手工动一笔 2100);
--   (D) 进项侧:可抵(TX)与不可抵(BL)走两条不同的路 —— 都进 box5,
--       只有可抵的进 box7;不可抵的那笔税进开支本身;
--   (E) 税码【不猜】:没有默认也没有指定 = 按名拒;挂反了侧 = 按名拒;
--   (F) ★【开关关着 = 与建 GST 之前一模一样】★ 而这【不是一句断言】:
--       未注册时带税码的行在【三张单据表 + 总账】上都写不进去。
--
-- 自带数据(README 第 2 条)。不继承 locked_before —— 自己设(README 第 4 条)。
-- 日期算出来、不写死:要落在既有年结之后(fixture 122 / 128 的先例)。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_fin uuid;
    v_maxyc date;
    v_q1s date; v_q1e date; v_q2s date; v_q2e date;
    v_sale_date date; v_inv_date date;
    v_mat uuid; v_cust uuid; v_cust2 uuid; v_sup uuid; ob uuid; ob2 uuid;
    v_base text; v_exp_acct text;
    v_sale jsonb; v_sale2 jsonb; v_inv jsonb; v_inv_id uuid; v_inv2 jsonb;
    v_exp jsonb; v_exp2 jsonb;
    v_r jsonb; v_boxes jsonb; v_ties jsonb;
    v_denied boolean; v_msg text;
    v_n numeric; v_v numeric; v_cnt int;
    v_line_id uuid; v_a2100 uuid; v_a1400 uuid;
    so1 uuid; L1 uuid; L2 uuid; v_oinv jsonb; v_oinv_id uuid; v_cn jsonb;
    v_row record;
    rep jsonb := '{}'::jsonb;
BEGIN
    -- ══════════ 布景 ══════════
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fixture-129','f','f',true)
      RETURNING id INTO r_fin;
    INSERT INTO role_permissions (role_id,permission_code)
      SELECT r_fin, unnest(ARRAY['module.finance.view','module.finance.edit',
                                 'module.output.view','module.output.edit',
                                 'module.sales.view','module.sales.edit',
                                 'module.customers.view','data.view_prices']);
    INSERT INTO user_roles (user_id,role_id) VALUES (v_user,r_fin);

    SELECT code INTO v_base FROM currencies WHERE is_base;
    SELECT COALESCE(MAX(year_end), DATE '2000-12-31') INTO v_maxyc
      FROM year_closes WHERE reopened_at IS NULL;

    -- 【两个【相邻】的整季】—— B 臂的全部判别力在这里:销售在 Q1,发票在 Q2。
    v_q1s := date_trunc('quarter', GREATEST(DATE '2025-01-01', v_maxyc + 400))::date;
    v_q1e := (v_q1s + interval '3 months - 1 day')::date;
    v_q2s := (v_q1s + interval '3 months')::date;
    v_q2e := (v_q2s + interval '3 months - 1 day')::date;
    v_sale_date := v_q1s + 20;   -- 销售:第一季
    v_inv_date  := v_q2s + 20;   -- 开票:第二季 ← 供应应当报在这一季

    SELECT id INTO v_a2100 FROM accounts WHERE code='2100';
    SELECT id INTO v_a1400 FROM accounts WHERE code='1400';
    IF v_a2100 IS NULL OR v_a1400 IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 129 前提失败:1400 / 2100 两个税科目必须在册';
    END IF;
    SELECT code INTO v_exp_acct FROM accounts WHERE account_type='expense' AND is_active ORDER BY code LIMIT 1;

    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO materials (code,name,kind_code,may_be_processed,form_code,source_code)
    VALUES ('ZZFIX129-M','fixture 129 material','battery_material',true,'black_mass','end_of_life')
      RETURNING id INTO v_mat;
    INSERT INTO output_batches (code,material_id,quantity,remaining_qty,output_date)
    VALUES ('ZZFIX129-OB', v_mat, 10000, 10000, v_q1s) RETURNING id INTO ob;
    INSERT INTO output_batches (code,material_id,quantity,remaining_qty,output_date)
    VALUES ('ZZFIX129-OB2', v_mat, 10000, 10000, v_q1s) RETURNING id INTO ob2;

    -- 【客户带默认税码,另一个【不带】】E 臂要用后者。
    INSERT INTO customers (code,legal_name,country,default_tax_code)
    VALUES ('ZZFIX129-C','fixture 129 customer','SG','SR') RETURNING id INTO v_cust;
    INSERT INTO customers (code,legal_name,country)
    VALUES ('ZZFIX129-C2','fixture 129 customer no default','SG') RETURNING id INTO v_cust2;
    INSERT INTO suppliers (code,legal_name,country,counterparty_type,default_tax_code)
    VALUES ('ZZFIX129-S','fixture 129 supplier','SG','service_vendor','TX') RETURNING id INTO v_sup;

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    -- ════════════════════════════════════════════════════════════════════════
    -- F1 · ★【开关关着的时候,带税码的行在【每一条】路上都写不进去】★
    --      这一臂放在最前面,因为它证明的是"停在这里不会错记任何一分税"。
    --      **它断言的不是"没有发生",是"做不到"** —— 四条路各撞一次。
    -- ════════════════════════════════════════════════════════════════════════
    UPDATE finance_settings SET gst_registered = false;

    -- (a) 开票时递一个税码 → 按名拒
    v_sale := record_output_sale(ob, 100, 10, v_base, NULL, v_cust,
                                 v_sale_date, NULL, 'manual', NULL);
    v_denied := false;
    BEGIN
        PERFORM create_invoice(v_cust, ARRAY[(v_sale->>'sale_id')::uuid],
                               v_inv_date, NULL, NULL, NULL, 'SR');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM LIKE 'GST_NOT_REGISTERED|%'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 129 F1a 失败:未注册却递了税码,应当按名拒 GST_NOT_REGISTERED,实得 %',
            COALESCE(v_msg,'(通过了)');
    END IF;

    -- (b) 直接往发票行上插一个税码 → 触发器拒
    --     【这一条是 GST-2 新加的那道闸】GST-1 只守 post_journal_entry,
    --     而 box1 从此不经过总账 —— 只守旧路径的闸在新路径开通那一刻就不是闸了。
    v_inv := create_invoice(v_cust, ARRAY[(v_sale->>'sale_id')::uuid], v_inv_date);
    v_inv_id := (v_inv->>'invoice_id')::uuid;
    SELECT id INTO v_line_id FROM invoice_lines WHERE invoice_id = v_inv_id LIMIT 1;
    v_denied := false;
    BEGIN
        UPDATE invoice_lines SET tax_code = 'SR' WHERE id = v_line_id;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM LIKE 'GST_NOT_REGISTERED|%'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 129 F1b 失败:未注册却把税码写进了发票行,实得 %',
            COALESCE(v_msg,'(写进去了)');
    END IF;

    -- (c) 未注册开出来的发票【不过任何分录】,与建 GST 之前逐字一样
    SELECT entry_id, tax_base, tax_rate_pct INTO v_row FROM invoices WHERE id = v_inv_id;
    IF v_row.entry_id IS NOT NULL OR v_row.tax_base <> 0 OR v_row.tax_rate_pct <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 129 F1c 失败:未注册时 sale 型发票必须不过分录、税恒零,实得 entry=% tax=% rate=%',
            v_row.entry_id, v_row.tax_base, v_row.tax_rate_pct;
    END IF;

    -- (d) 总账那道旧闸仍然在(GST-1 建的那一条,没有被这一刀弄坏)
    v_denied := false;
    BEGIN
        PERFORM post_journal_entry(v_inv_date, 'f129', 'manual', NULL, jsonb_build_array(
            jsonb_build_object('account_code', v_exp_acct, 'side','debit','currency',v_base,'amount_ccy',10,'tax_code','TX'),
            jsonb_build_object('account_code','1000','side','credit','currency',v_base,'amount_ccy',10)));
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM LIKE 'GST_NOT_REGISTERED|%'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 129 F1d 失败:未注册却把税码写进了分录行,实得 %',
            COALESCE(v_msg,'(写进去了)');
    END IF;

    -- (e) 费用单那一条路同样堵死
    v_denied := false;
    BEGIN
        PERFORM record_expense(v_inv_date, v_exp_acct, 100, v_base, NULL, 'paid', NULL,
                               NULL, NULL, NULL, NULL, NULL, NULL, 'TX');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM LIKE 'GST_NOT_REGISTERED|%'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 129 F1e 失败:未注册却给费用单递了税码,实得 %',
            COALESCE(v_msg,'(通过了)');
    END IF;

    -- 【那一季的 F5 必须【每一格】都是零】—— 这是"一模一样"的可观测形式
    v_r := f5_return(v_q2s, v_q2e);
    SELECT COALESCE(SUM((b->>'value')::numeric),0) INTO v_n
      FROM jsonb_array_elements(v_r->'boxes') b;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 129 F1 失败:未注册时 F5 的各格之和必须是 0,实得 %', v_n;
    END IF;
    rep := rep || jsonb_build_object('F1_gst_off_is_unwritable', true);

    -- 把这张未注册的发票作废掉,免得它混进后面的臂
    PERFORM void_invoice(v_inv_id, 'fixture 129 teardown');

    -- ════════════════════════════════════════════════════════════════════════
    -- 打开开关。以下所有臂都在【已注册】之下。
    -- ════════════════════════════════════════════════════════════════════════
    UPDATE finance_settings SET gst_registered = true, gst_registration_no = 'M9-FIX129-9';

    -- ════════════════════════════════════════════════════════════════════════
    -- A · 单据携带税,税码与税率【冻在行上】,按【发票自己的开票日】解析
    -- ════════════════════════════════════════════════════════════════════════
    v_sale2 := record_output_sale(ob2, 100, 10, v_base, NULL, v_cust,
                                  v_sale_date, NULL, 'manual', NULL);
    v_inv2  := create_invoice(v_cust, ARRAY[(v_sale2->>'sale_id')::uuid], v_inv_date);
    v_inv_id := (v_inv2->>'invoice_id')::uuid;

    -- 1,000.00 × 9% = 90.00
    SELECT tax_code, tax_rate_pct, tax_base, amount_base INTO v_row
      FROM invoice_lines WHERE invoice_id = v_inv_id;
    IF v_row.tax_code <> 'SR' THEN
        RAISE EXCEPTION 'FIXTURE 129 A 失败:税码应当从客户的默认解析出 SR,实得 %', COALESCE(v_row.tax_code,'(空)');
    END IF;
    IF v_row.tax_rate_pct <> 9.000 THEN
        RAISE EXCEPTION 'FIXTURE 129 A 失败:税率应当按开票日解析为 9%%,实得 %', v_row.tax_rate_pct;
    END IF;
    IF v_row.tax_base <> 90.00 THEN
        RAISE EXCEPTION 'FIXTURE 129 A 失败:1,000.00 × 9%% 应当是 90.00,实得 %', v_row.tax_base;
    END IF;
    -- 表头 = Σ 行,且【总额确实含税】—— 这句话此前只写在列上,从没兑现过
    SELECT tax_base, total_base, subtotal_base, entry_id INTO v_row FROM invoices WHERE id = v_inv_id;
    IF v_row.tax_base <> 90.00 OR v_row.total_base <> 1090.00 THEN
        RAISE EXCEPTION 'FIXTURE 129 A 失败:表头应当是 税 90.00 / 总额 1,090.00,实得 % / %',
            v_row.tax_base, v_row.total_base;
    END IF;
    -- 【那张只过税的分录】借 1100 / 贷 2100,各 90.00
    IF v_row.entry_id IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 129 A 失败:带税的 sale 型发票必须过一张分录,实得没有';
    END IF;
    SELECT COALESCE(SUM(credit-debit),0) INTO v_n
      FROM journal_lines WHERE entry_id = v_row.entry_id AND account_id = v_a2100;
    IF v_n <> 90.00 THEN
        RAISE EXCEPTION 'FIXTURE 129 A 失败:2100 上应当是 90.00 贷方,实得 %', v_n;
    END IF;
    rep := rep || jsonb_build_object('A_invoice_carries_frozen_tax', true);

    -- ── A2 · 【冻住】的意思:法定税率此后变了,已开的票不变 ────────────────
    -- 【注入方向】把税率史动一下,再读同一张票 —— 它必须纹丝不动。
    --   一个"按今天的设置现算"的实现会在这里变红。
    INSERT INTO tax_rates (tax_code, rate_pct, effective_from, note)
    VALUES ('SR', 13.000, v_inv_date + 1, 'fixture 129: a later statutory change');
    UPDATE tax_rates SET effective_to = v_inv_date
     WHERE tax_code='SR' AND effective_to IS NULL AND effective_from <= v_inv_date;
    SELECT tax_rate_pct, tax_base INTO v_row FROM invoice_lines WHERE invoice_id = v_inv_id;
    IF v_row.tax_rate_pct <> 9.000 OR v_row.tax_base <> 90.00 THEN
        RAISE EXCEPTION 'FIXTURE 129 A2 失败:已开出的发票不得随税率史改动 —— 实得 税率 % / 税额 %',
            v_row.tax_rate_pct, v_row.tax_base;
    END IF;
    rep := rep || jsonb_build_object('A2_issued_invoice_never_reprices', true);

    -- ════════════════════════════════════════════════════════════════════════
    -- B · ★【裁定本身】★ 供应报在【开票】那一期,不是销售那一期
    --     销售在 Q1、开票在 Q2 ⇒ box1 在 Q2,而 Q1 是零。
    --     **这一臂红了,就是税点接错了。**
    -- ════════════════════════════════════════════════════════════════════════
    v_r := f5_return(v_q1s, v_q1e);
    SELECT (b->>'value')::numeric INTO v_n
      FROM jsonb_array_elements(v_r->'boxes') b WHERE b->>'box'='box1';
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 129 B 失败:销售那一季(%→%)的 box1 必须是 0 —— 供应报在开票那一期,实得 %',
            v_q1s, v_q1e, v_n;
    END IF;
    -- 而【收入】确实落在销售那一季 —— 两者不同,这正是选项 A 的代价,要断言下来
    SELECT (b->>'value')::numeric INTO v_v
      FROM jsonb_array_elements(v_r->'boxes') b WHERE b->>'box'='box13';
    IF v_v <= 0 THEN
        RAISE EXCEPTION 'FIXTURE 129 B 前置失败:销售那一季的 box13 营业收入应当 > 0(否则本臂空转),实得 %', v_v;
    END IF;

    v_r := f5_return(v_q2s, v_q2e);
    SELECT (b->>'value')::numeric INTO v_n
      FROM jsonb_array_elements(v_r->'boxes') b WHERE b->>'box'='box1';
    IF v_n <> 1000.00 THEN
        RAISE EXCEPTION 'FIXTURE 129 B 失败:开票那一季(%→%)的 box1 应当是 1,000.00,实得 %',
            v_q2s, v_q2e, v_n;
    END IF;
    SELECT (b->>'value')::numeric INTO v_n
      FROM jsonb_array_elements(v_r->'boxes') b WHERE b->>'box'='box6';
    IF v_n <> 90.00 THEN
        RAISE EXCEPTION 'FIXTURE 129 B 失败:开票那一季的 box6 应当是 90.00,实得 %', v_n;
    END IF;
    rep := rep || jsonb_build_object('B_supply_lands_in_the_invoice_quarter', true);

    -- 【每一格的来源要说得出来】—— 屏幕上逐格印的就是这个字段
    SELECT b->>'source' INTO v_msg
      FROM jsonb_array_elements(v_r->'boxes') b WHERE b->>'box'='box1';
    IF v_msg <> 'invoices' THEN
        RAISE EXCEPTION 'FIXTURE 129 B 失败:box1 的来源应当自报为 invoices,实得 %', COALESCE(v_msg,'(空)');
    END IF;
    SELECT b->>'source' INTO v_msg
      FROM jsonb_array_elements(v_r->'boxes') b WHERE b->>'box'='box7';
    IF v_msg <> 'ledger' THEN
        RAISE EXCEPTION 'FIXTURE 129 B 失败:box7 的来源应当自报为 ledger,实得 %', COALESCE(v_msg,'(空)');
    END IF;
    rep := rep || jsonb_build_object('B2_each_box_states_its_source', true);

    -- ════════════════════════════════════════════════════════════════════════
    -- D · 进项侧:可抵与不可抵走两条【不同】的路
    -- ════════════════════════════════════════════════════════════════════════
    -- (a) TX 可抵:净额 200 进 box5,税 18 进 box7
    v_exp := record_expense(v_inv_date, v_exp_acct, 200, v_base, NULL, 'paid', NULL,
                            v_sup, NULL, NULL, NULL, NULL, NULL, NULL);   -- 税码走供应商默认 TX
    SELECT tax_code, tax_rate_pct, tax_base, amount_ccy INTO v_row
      FROM expenses WHERE id = (v_exp->>'expense_id')::uuid;
    IF v_row.tax_code <> 'TX' OR v_row.tax_base <> 18.00 OR v_row.amount_ccy <> 200 THEN
        RAISE EXCEPTION 'FIXTURE 129 Da 失败:应当是 TX / 税 18.00 / 净额 200,实得 % / % / %',
            COALESCE(v_row.tax_code,'(空)'), v_row.tax_base, v_row.amount_ccy;
    END IF;

    -- (b) BL 不可抵:净额 100 【照样】进 box5,税 9 【不】进 box7,而是进开支本身
    v_exp2 := record_expense(v_inv_date, v_exp_acct, 100, v_base, NULL, 'paid', NULL,
                             v_sup, NULL, NULL, NULL, NULL, NULL, 'BL');
    v_r := f5_return(v_q2s, v_q2e);
    SELECT (b->>'value')::numeric INTO v_n
      FROM jsonb_array_elements(v_r->'boxes') b WHERE b->>'box'='box5';
    IF v_n <> 300.00 THEN
        RAISE EXCEPTION 'FIXTURE 129 Db 失败:box5 应当是 300.00(200 可抵 + 100 不可抵,都报采购额),实得 % —— 不可抵的采购【也要报】,只是税不抵',
            v_n;
    END IF;
    SELECT (b->>'value')::numeric INTO v_n
      FROM jsonb_array_elements(v_r->'boxes') b WHERE b->>'box'='box7';
    IF v_n <> 18.00 THEN
        RAISE EXCEPTION 'FIXTURE 129 Db 失败:box7 应当【只】是 18.00(BL 那 9.00 要不回来),实得 % —— 若是 27.00,说明不可抵的税被当成可抵的抵掉了',
            v_n;
    END IF;
    rep := rep || jsonb_build_object('D_blocked_input_tax_is_reported_not_claimed', true);

    -- ════════════════════════════════════════════════════════════════════════
    -- C · 勾稽:三处说法、两条比较,而【两条都真的会分开】
    -- ════════════════════════════════════════════════════════════════════════
    v_ties := f5_return(v_q2s, v_q2e) -> 'ties';
    IF NOT (v_ties->>'agrees')::boolean THEN
        RAISE EXCEPTION 'FIXTURE 129 C 前置失败:干净的一季必须勾稽得上,实得 单据=% 法令=% 总账=%',
            v_ties->>'box6_from_documents', v_ties->>'box6_recomputed_from_statute',
            v_ties->>'box6_from_tax_account';
    END IF;

    -- ── C1 · 单据 vs 法令:把冻在行上的税额改掉(法令那一路不读它)──────────
    --    【这一步用的是 SET LOCAL session_replication_role,不是普通 UPDATE】
    --    发票行是不可变的;要证明勾稽会响,必须真的把两边弄分开一次。
    SET LOCAL session_replication_role = replica;
    UPDATE invoice_lines SET tax_base = 95.00 WHERE invoice_id = v_inv_id;
    SET LOCAL session_replication_role = origin;
    v_ties := f5_return(v_q2s, v_q2e) -> 'ties';
    IF (v_ties->>'agrees_documents_vs_statute')::boolean THEN
        RAISE EXCEPTION 'FIXTURE 129 C1 失败:发票上的税被改成 95.00 而法令算出 90.00,勾稽必须报分开 —— 它却说一致(单据=% 法令=%)',
            v_ties->>'box6_from_documents', v_ties->>'box6_recomputed_from_statute';
    END IF;
    IF (v_ties->>'agrees')::boolean THEN
        RAISE EXCEPTION 'FIXTURE 129 C1 失败:两条比较有一条不成立时,总判词 agrees 必须是 false';
    END IF;
    -- 复原
    SET LOCAL session_replication_role = replica;
    UPDATE invoice_lines SET tax_base = 90.00 WHERE invoice_id = v_inv_id;
    SET LOCAL session_replication_role = origin;

    -- ── C2 · 单据 vs 总账:手工往 2100 上过一笔 ──────────────────────────────
    PERFORM post_journal_entry(v_inv_date, 'fixture 129 stray tax entry', 'manual', NULL,
        jsonb_build_array(
            jsonb_build_object('account_code','2100','side','credit','currency',v_base,'amount_ccy',4),
            jsonb_build_object('account_code','1100','side','debit','currency',v_base,'amount_ccy',4)));
    v_ties := f5_return(v_q2s, v_q2e) -> 'ties';
    IF (v_ties->>'agrees_documents_vs_ledger')::boolean THEN
        RAISE EXCEPTION 'FIXTURE 129 C2 失败:2100 上多了一笔 4.00 而单据侧没有,勾稽必须报分开 —— 它却说一致(单据=% 总账=%)',
            v_ties->>'box6_from_documents', v_ties->>'box6_from_tax_account';
    END IF;
    -- 【而另一条【仍然成立】】—— 这证明两条比较各查各的,不是同一条写了两遍
    IF NOT (v_ties->>'agrees_documents_vs_statute')::boolean THEN
        RAISE EXCEPTION 'FIXTURE 129 C2 失败:手工动总账不应当影响"单据 vs 法令"那一条 —— 两条比较必须互相独立';
    END IF;
    -- 【把那笔手工的税冲掉,勾稽回到一致】—— 一个只会变红、再也回不了绿的检查,
    -- 与一个永远为真的检查一样没有判别力(fixture 128 的 F2b 收尾同一条)。
    -- 【而且后面的臂要在一个干净的季度上继续断言】留着它,K 臂会因为
    -- 这一笔而不是因为它自己要测的东西变红 —— 那种红比绿更坏,它会把
    -- 下一个人送去查一个根本没坏的地方。
    PERFORM post_journal_entry(v_inv_date, 'fixture 129 冲掉 stray 那一笔', 'manual', NULL,
        jsonb_build_array(
            jsonb_build_object('account_code','2100','side','debit','currency',v_base,'amount_ccy',4),
            jsonb_build_object('account_code','1100','side','credit','currency',v_base,'amount_ccy',4)));
    v_ties := f5_return(v_q2s, v_q2e) -> 'ties';
    IF NOT (v_ties->>'agrees')::boolean THEN
        RAISE EXCEPTION 'FIXTURE 129 C 收尾失败:冲掉之后勾稽应当回到一致,实得 单据=% 法令=% 总账=%',
            v_ties->>'box6_from_documents', v_ties->>'box6_recomputed_from_statute',
            v_ties->>'box6_from_tax_account';
    END IF;
    rep := rep || jsonb_build_object('C_both_ties_separate_independently', true);

    -- ════════════════════════════════════════════════════════════════════════
    -- E · 税码【不猜】
    -- ════════════════════════════════════════════════════════════════════════
    -- (a) 没有默认、也没有指定 → 按名拒(而不是悄悄当成 SR,也不是悄悄当成 0)
    v_sale := record_output_sale(ob, 50, 10, v_base, NULL, v_cust2,
                                 v_sale_date, NULL, 'manual', NULL);
    v_denied := false;
    BEGIN
        PERFORM create_invoice(v_cust2, ARRAY[(v_sale->>'sale_id')::uuid], v_inv_date);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM LIKE 'TAX_CODE_REQUIRED|%'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 129 Ea 失败:客户没有默认税码时必须按名拒 TAX_CODE_REQUIRED,实得 % —— 一个悄悄默认的税码是穿着默认值外衣的错答案',
            COALESCE(v_msg,'(通过了)');
    END IF;

    -- (b) 挂反了侧 → 按名拒(进项码开不出销项发票)
    v_denied := false;
    BEGIN
        PERFORM create_invoice(v_cust2, ARRAY[(v_sale->>'sale_id')::uuid],
                               v_inv_date, NULL, NULL, NULL, 'TX');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM LIKE 'TAX_CODE_WRONG_SIDE|%'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 129 Eb 失败:拿进项码 TX 开销项发票必须按名拒 TAX_CODE_WRONG_SIDE,实得 %',
            COALESCE(v_msg,'(通过了)');
    END IF;

    -- (c) 默认也挂不反 —— 表上那道闸
    v_denied := false;
    BEGIN
        UPDATE customers SET default_tax_code = 'TX' WHERE id = v_cust2;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM LIKE 'TAX_CODE_WRONG_SIDE|%'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 129 Ec 失败:把进项码挂到客户上必须按名拒,实得 %', COALESCE(v_msg,'(写进去了)');
    END IF;
    rep := rep || jsonb_build_object('E_the_code_is_never_guessed', true);

    -- ════════════════════════════════════════════════════════════════════════
    -- G · 钻回单据 —— 销项钻到【发票】,进项钻到【分录】,合计格【说自己钻不进去】
    -- ════════════════════════════════════════════════════════════════════════
    SELECT count(*) INTO v_cnt FROM f5_box_detail(v_q2s, v_q2e, 'box1') d
     WHERE d.doc_kind = 'invoice';
    IF v_cnt < 1 THEN
        RAISE EXCEPTION 'FIXTURE 129 G 失败:box1 必须钻得回发票,实得 % 行', v_cnt;
    END IF;
    SELECT count(*) INTO v_cnt FROM f5_box_detail(v_q2s, v_q2e, 'box5') d
     WHERE d.doc_kind = 'journal_entry';
    IF v_cnt < 1 THEN
        RAISE EXCEPTION 'FIXTURE 129 G 失败:box5 必须钻得回分录,实得 % 行', v_cnt;
    END IF;
    -- 【钻不进去要说出来,不能返回空集】
    FOREACH v_msg IN ARRAY ARRAY['box4','box8','box9','box13']
    LOOP
        v_denied := false;
        BEGIN PERFORM * FROM f5_box_detail(v_q2s, v_q2e, v_msg);
        EXCEPTION WHEN OTHERS THEN v_denied := (SQLERRM LIKE 'GST_BOX_NOT_DRILLABLE|%'); END;
        IF NOT v_denied THEN
            RAISE EXCEPTION 'FIXTURE 129 G 失败:% 钻不进去这件事必须按名说出来,而不是返回空集', v_msg;
        END IF;
    END LOOP;
    -- 【钻进去的和加起来的必须是同一个数】否则钻回去的是另一份账
    SELECT COALESCE(SUM(d.amount_base),0) INTO v_n FROM f5_box_detail(v_q2s, v_q2e, 'box1') d;
    SELECT (b->>'value')::numeric INTO v_v
      FROM jsonb_array_elements(f5_return(v_q2s,v_q2e)->'boxes') b WHERE b->>'box'='box1';
    IF v_n <> v_v THEN
        RAISE EXCEPTION 'FIXTURE 129 G 失败:box1 钻进去的合计 % 与格子上的 % 对不上', v_n, v_v;
    END IF;
    rep := rep || jsonb_build_object('G_every_box_drills_or_says_it_cannot', true);

    -- ════════════════════════════════════════════════════════════════════════
    -- H · 收款那一条腿:已注册时,挂不上单据的客户款【按名拒】
    --     "孰早"有两半,只做一半不许当做完了 —— 拒绝是那半的可见形式。
    -- ════════════════════════════════════════════════════════════════════════
    v_denied := false;
    BEGIN
        PERFORM record_payment('in', v_cust, 500, v_base, NULL, '1000', v_inv_date,
                               NULL, '[]'::jsonb, 'customer');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
        v_denied := (SQLERRM LIKE 'GST_UNALLOCATED_RECEIPT_UNSUPPORTED|%'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 129 H 失败:已注册时一笔挂不上单据的客户收款必须按名拒 —— 它是一个【实现不了】的税点,不能无声地当成没有税。实得 %',
            COALESCE(v_msg,'(收下了)');
    END IF;
    rep := rep || jsonb_build_object('H_the_payment_leg_is_refused_by_name', true);

    -- ════════════════════════════════════════════════════════════════════════
    -- I · 作废带税的发票 = 那张只过税的分录被冲掉,而两条勾稽跟着一起走
    -- ════════════════════════════════════════════════════════════════════════
    -- 【日期必填】GST-2 之前 sale 型收到日期是要拒的;带税之后它要求日期。
    v_denied := false;
    BEGIN PERFORM void_invoice(v_inv_id, 'fixture 129 void with tax');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM LIKE 'REVERSAL_DATE_REQUIRED%'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 129 I 失败:作废一张带税的发票必须要求冲销日(它决定冲销落进哪个期间),实得 %',
            COALESCE(v_msg,'(不要日期就作废了)');
    END IF;

    PERFORM void_invoice(v_inv_id, 'fixture 129 void with tax', v_inv_date);
    v_r := f5_return(v_q2s, v_q2e);
    SELECT (b->>'value')::numeric INTO v_n
      FROM jsonb_array_elements(v_r->'boxes') b WHERE b->>'box'='box1';
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 129 I 失败:作废之后 box1 应当回到 0,实得 %', v_n;
    END IF;
    -- 【不按 status 过滤 —— 这一句本身就是 fu2 那条修复的断言】
    -- 冲销是【一笔新分录】,不是一次删除:原件被标成 'reversed'、冲销件是
    -- 'posted'。按 status='posted' 过滤会丢掉原件、留下冲销件,把一对本该
    -- 抵为 0 的分录算成 **-90**。这一臂第一次跑出来的就是 -90.00,
    -- 而它抓到的是 GST-1 从第一天就带着的缺陷(见 fu2 迁移抬头与 OPS-17)。
    SELECT COALESCE(SUM(jl.credit-jl.debit),0) INTO v_n
      FROM journal_lines jl JOIN journal_entries je ON je.id=jl.entry_id
     WHERE jl.account_id = v_a2100 AND je.entry_date BETWEEN v_q2s AND v_q2e
       AND je.memo NOT LIKE '%stray%';   -- 那一对(注入 + 冲销)自己已经净为 0
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 129 I 失败:作废必须把 2100 上那 90.00 冲回去,实得 % —— 否则单据侧已经排除了这张票,而总账还留着它的税',
            v_n;
    END IF;
    -- 【而 F5 那一格【也】必须回到零 —— 断言报表,不只断言总账】
    -- 上面查的是科目余额;这里查的是【报出去的那个数】。两者都要回零:
    -- 只查科目余额,一个把作废票仍然算进销项税的 F5 照样全绿。
    v_ties := f5_return(v_q2s, v_q2e) -> 'ties';
    IF (v_ties->>'box6_from_documents')::numeric <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 129 I 失败:作废之后单据侧的 box6 应当是 0,实得 %',
            v_ties->>'box6_from_documents';
    END IF;
    rep := rep || jsonb_build_object('I_voiding_a_taxed_invoice_reverses_its_tax', true);

    -- ════════════════════════════════════════════════════════════════════════
    -- J · 冲销一笔进项:税码要跟着翻过去,否则采购永远留在 box5
    -- ════════════════════════════════════════════════════════════════════════
    -- 【断言的是"翻边抄不抄 tax_code",而不是某一期的 box5】
    -- reverse_expense 的冲销分录过在 CURRENT_DATE(不一定落在本季),而且
    -- reverse_journal_entry_internal 把 source_id 设成【原分录的 id】而不是原单据的 id
    -- —— 两件事都会让"按期间/按单据去数 box5"问错问题。
    -- 要钉的那一条很窄:**冲销行必须带着原行的税码**。不带,box5 上那笔采购
    -- 就永远冲不掉,而总账本身是平的、借贷相等、没有任何东西看起来不对。
    DECLARE v_orig_je uuid; v_rev_je uuid; v_tx_debit numeric; v_tx_credit numeric;
    BEGIN
        SELECT journal_entry_id INTO v_orig_je FROM expenses WHERE id = (v_exp->>'expense_id')::uuid;
        PERFORM reverse_expense((v_exp->>'expense_id')::uuid, 'fixture 129');
        SELECT reversed_by INTO v_rev_je FROM journal_entries WHERE id = v_orig_je;
        IF v_rev_je IS NULL THEN
            RAISE EXCEPTION 'FIXTURE 129 J 前提失败:冲销之后原分录应当挂上 reversed_by';
        END IF;
        SELECT COALESCE(SUM(debit),0), COALESCE(SUM(credit),0)
          INTO v_tx_debit, v_tx_credit
          FROM journal_lines WHERE entry_id = v_rev_je AND tax_code = 'TX';
        -- 原件是【借】200 带 TX;冲销件必须是【贷】200 且【同样带 TX】。
        IF v_tx_credit <> 200.00 OR v_tx_debit <> 0 THEN
            RAISE EXCEPTION 'FIXTURE 129 J 失败:冲销行必须带着原行的税码 TX(应当是贷 200.00),实得 借 % / 贷 % —— 不带税码时,那笔采购会永远留在 box5,而总账本身是平的',
                v_tx_debit, v_tx_credit;
        END IF;
        -- 【两条腿加起来净掉】原件 +200 与冲销件 −200 在同一个税码下相消。
        SELECT COALESCE(SUM(jl.debit - jl.credit),0) INTO v_n
          FROM journal_lines jl
         WHERE jl.entry_id IN (v_orig_je, v_rev_je) AND jl.tax_code = 'TX';
        IF v_n <> 0 THEN
            RAISE EXCEPTION 'FIXTURE 129 J 失败:原件与冲销件在 TX 上应当净为 0,实得 %', v_n;
        END IF;
    END;
    rep := rep || jsonb_build_object('J_a_reversal_carries_the_tax_code', true);

    -- 【成功不抛异常】db/gate.py 用 ON_ERROR_STOP=1 跑本目录,任何异常 = 这一支失败。
    -- 报告用 NOTICE,回滚由文件末尾的 ROLLBACK 做。
    -- (`RAISE EXCEPTION 'FIXTURE_REPORT …'` 是【Management API 探针】的写法 ——
    --  那条路上必须靠异常把报告带回来并回滚。两条路两种写法,别混。
    --  这一份第一次就是那么写的,而 gate 把它读成了一次失败。fixture 127 的
    --  同一段注释救了它 —— 所以这段话留在这里,给下一个人。)
    -- ════════════════════════════════════════════════════════════════════════
    -- K · 订单流发票:那条"明确不支持"的拒绝退休了,而它退休得【对】
    --     ★【外币,而且汇率是挑过的】★ 1.005 会让"逐行取整再相加"与
    --     "先加再取整"差【一分钱】—— 而 F5 的单据侧读前者、总账记后者。
    --     不处理这一分钱,一张**完全正确**的外币发票会让勾稽报 false,
    --     而一条每逢外币就误报的勾稽,一个季度之后就没有人看了
    --     —— 那正是 Tim 拒绝选项 B 的那条理由,从后门放回来。
    -- ════════════════════════════════════════════════════════════════════════
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES (next_sales_order_code(v_inv_date), v_cust, v_inv_date, 'USD', 1.005)
      RETURNING id INTO so1;
    -- 两行各 33.33 USD:每行税 round(33.33 × 9%) = 3.00,合计 6.00 USD。
    -- 本位币:逐行 round(3.00 × 1.005) = 3.02,两行 6.04;
    --         先加再取整 round(6.00 × 1.005) = 6.03。**差一分。**
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (so1, 1, v_mat, 1, 33.33) RETURNING id INTO L1;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (so1, 2, v_mat, 1, 33.33) RETURNING id INTO L2;
    PERFORM set_sales_order_status(so1, 'confirmed');

    v_oinv := create_order_invoice(so1, v_inv_date);
    v_oinv_id := (v_oinv->>'invoice_id')::uuid;

    IF (v_oinv->>'tax_code') <> 'SR' THEN
        RAISE EXCEPTION 'FIXTURE 129 K 失败:订单流发票也要携带税码,实得 %',
            COALESCE(v_oinv->>'tax_code','(空)');
    END IF;
    IF (v_oinv->>'tax_ccy')::numeric <> 6.00 THEN
        RAISE EXCEPTION 'FIXTURE 129 K 失败:单据币种的税应当是 6.00 USD,实得 %', v_oinv->>'tax_ccy';
    END IF;
    IF (v_oinv->>'tax_base')::numeric <> 6.04 THEN
        RAISE EXCEPTION 'FIXTURE 129 K 失败:本位币税应当是 6.04(逐行取整再相加),实得 %',
            v_oinv->>'tax_base';
    END IF;
    -- ★【这一句就是 fu3】★ 总账上 2100 收到的必须【也是 6.04】,不是 6.03。
    SELECT COALESCE(SUM(jl.credit-jl.debit),0) INTO v_n
      FROM journal_lines jl
     WHERE jl.entry_id = (SELECT entry_id FROM invoices WHERE id = v_oinv_id)
       AND jl.account_id = v_a2100;
    IF v_n <> 6.04 THEN
        RAISE EXCEPTION 'FIXTURE 129 K 失败:2100 上应当是 6.04 —— 与发票行加起来的那个数【一分不差】,实得 % —— 若是 6.03,说明税腿按单据汇率过账,而 F5 的单据侧读的是逐行取整的合计:一张完全正确的外币发票会因此让勾稽报 false',
            v_n;
    END IF;
    -- 而勾稽【三处两条】都必须成立 —— 这才是上面那一分钱真正要保住的东西
    v_ties := f5_return(v_q2s, v_q2e) -> 'ties';
    IF NOT (v_ties->>'agrees')::boolean THEN
        RAISE EXCEPTION 'FIXTURE 129 K 失败:一张正确的外币发票不该让勾稽报分开,实得 单据=% 法令=% 总账=%',
            v_ties->>'box6_from_documents', v_ties->>'box6_recomputed_from_statute',
            v_ties->>'box6_from_tax_account';
    END IF;
    rep := rep || jsonb_build_object('K_order_invoice_carries_tax_to_the_cent', true);

    -- ── K2 · 贷项凭证是一笔【负的供应】,税从【被冲的那一行】抄税率 ────────────
    SELECT (b->>'value')::numeric INTO v_v
      FROM jsonb_array_elements(f5_return(v_q2s,v_q2e)->'boxes') b WHERE b->>'box'='box1';
    v_cn := create_credit_note(v_oinv_id, v_inv_date, 'fixture 129:少发了一行',
        jsonb_build_array(jsonb_build_object(
            'invoice_line_id', (SELECT id FROM invoice_lines WHERE invoice_id=v_oinv_id AND line_no=1),
            'kind', 'unshipped_cancel', 'amount', 33.33)));
    SELECT (b->>'value')::numeric INTO v_n
      FROM jsonb_array_elements(f5_return(v_q2s,v_q2e)->'boxes') b WHERE b->>'box'='box1';
    IF v_n >= v_v THEN
        RAISE EXCEPTION 'FIXTURE 129 K2 失败:一张贷项凭证必须把 box1 减下去(冲前 %,冲后 %)—— 它是一笔【负的供应】',
            v_v, v_n;
    END IF;
    IF (SELECT tax_code FROM credit_note_lines WHERE credit_note_id=(v_cn->>'credit_note_id')::uuid) <> 'SR' THEN
        RAISE EXCEPTION 'FIXTURE 129 K2 失败:贷项凭证行必须抄下被冲那一行的税码';
    END IF;
    v_ties := f5_return(v_q2s, v_q2e) -> 'ties';
    IF NOT (v_ties->>'agrees')::boolean THEN
        RAISE EXCEPTION 'FIXTURE 129 K2 失败:开票 + 贷记之后勾稽仍应成立,实得 单据=% 法令=% 总账=%',
            v_ties->>'box6_from_documents', v_ties->>'box6_recomputed_from_statute',
            v_ties->>'box6_from_tax_account';
    END IF;
    rep := rep || jsonb_build_object('K2_a_credit_note_is_a_negative_supply', true);

    RAISE NOTICE 'FIXTURE 129 全部通过 %', rep::text;
END $$;
ROLLBACK;
