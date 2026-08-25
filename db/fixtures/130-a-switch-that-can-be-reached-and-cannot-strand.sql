-- 130 一个够得着、又搁不死东西的开关(GST-3)
--
-- 【这份 fixture 钉住的四件事】
--   (R) 打开的前置:**登记号必须在册**。IRAS 要求税务发票上印它,而发票 PDF
--       在号码为空时那一行【整条消失】—— 于是"已注册但没有号"会开出一张
--       带 9% 税、却一个登记号都不带的发票。空白字符串与 NULL 同罪。
--   (S) 关闭的两条拒绝,**两个不同的理由**:
--       带税码的费用单(机械:关掉之后冲销不了)、在册的带税发票(判断:
--       留下的账面状态自相矛盾)。两条各有各的码,不合并。
--   (T) 拒绝【给得出路】:把挡路的单据处理掉之后,开关关得掉。
--       一个只会拒、永远关不掉的开关是一个陷阱,不是一道闸。
--   (U) 关掉之后,那条结构性保证【原样回来】:税码任何地方都写不进去。
--
-- 自带数据(README 第 2 条)。不继承 locked_before —— 自己设(README 第 4 条)。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_fin uuid;
    v_maxyc date; v_d date;
    v_mat uuid; v_cust uuid; v_sup uuid; ob uuid;
    v_base text; v_exp_acct text;
    v_sale jsonb; v_inv jsonb; v_inv_id uuid; v_exp jsonb;
    v_denied boolean; v_msg text;
    rep jsonb := '{}'::jsonb;
BEGIN
    -- ══════════ 布景 ══════════
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fixture-130','f','f',true)
      RETURNING id INTO r_fin;
    INSERT INTO role_permissions (role_id,permission_code)
      SELECT r_fin, unnest(ARRAY['module.finance.view','module.finance.edit',
                                 'module.output.view','module.output.edit',
                                 'module.customers.view','data.view_prices']);
    INSERT INTO user_roles (user_id,role_id) VALUES (v_user,r_fin);

    SELECT code INTO v_base FROM currencies WHERE is_base;
    SELECT COALESCE(MAX(year_end), DATE '2000-12-31') INTO v_maxyc
      FROM year_closes WHERE reopened_at IS NULL;
    v_d := GREATEST(DATE '2025-02-10', v_maxyc + 400);
    SELECT code INTO v_exp_acct FROM accounts WHERE account_type='expense' AND is_active ORDER BY code LIMIT 1;

    UPDATE finance_settings SET locked_before = NULL,
                                gst_registered = false, gst_registration_no = NULL;

    INSERT INTO materials (code,name,kind_code,may_be_processed,form_code,source_code)
    VALUES ('ZZFIX130-M','fixture 130 material','battery_material',true,'black_mass','end_of_life')
      RETURNING id INTO v_mat;
    INSERT INTO output_batches (code,material_id,quantity,remaining_qty,output_date)
    VALUES ('ZZFIX130-OB', v_mat, 10000, 10000, v_d) RETURNING id INTO ob;
    INSERT INTO customers (code,legal_name,country,default_tax_code)
    VALUES ('ZZFIX130-C','fixture 130 customer','SG','SR') RETURNING id INTO v_cust;
    INSERT INTO suppliers (code,legal_name,country,counterparty_type,default_tax_code)
    VALUES ('ZZFIX130-S','fixture 130 supplier','SG','service_vendor','TX') RETURNING id INTO v_sup;

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    -- ══════════ R1 · 登记号为空 → 开不了 ══════════
    v_denied := false; v_msg := NULL;   -- 【每一臂自带干净的 v_msg】残留上一臂的消息会让失败文本把人送去查错地方
    BEGIN UPDATE finance_settings SET gst_registered = true WHERE id;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
        v_denied := (SQLERRM LIKE 'GST_REGISTRATION_NO_REQUIRED%'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 130 R1 失败:没有登记号就打开 GST 必须按名拒 —— 否则会开出一张带税、却不带登记号的发票寄给客户。实得 %',
            COALESCE(v_msg,'(开成功了)');
    END IF;

    -- ══════════ R2 · 【一串空白】与 NULL 同罪 ══════════
    -- 判据必须与【印出来的结果】一致,不是与列的可空性一致:
    -- 一段空白在数据库里"有值",在发票上与 NULL 一样什么都不印。
    v_denied := false; v_msg := NULL;   -- 【每一臂自带干净的 v_msg】残留上一臂的消息会让失败文本把人送去查错地方
    BEGIN UPDATE finance_settings SET gst_registered = true, gst_registration_no = '   ' WHERE id;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
        v_denied := (SQLERRM LIKE 'GST_REGISTRATION_NO_REQUIRED%'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 130 R2 失败:一串空白登记号应当与空同罪,实得 %',
            COALESCE(v_msg,'(开成功了)');
    END IF;
    rep := rep || jsonb_build_object('R_registration_no_is_a_precondition', true);

    -- ══════════ R3 · 号码与开关【同一条语句】落地 → 成功 ══════════
    UPDATE finance_settings SET gst_registered = true, gst_registration_no = 'M9-FIX130-0' WHERE id;
    IF NOT gst_registered() THEN
        RAISE EXCEPTION 'FIXTURE 130 R3 失败:带上登记号之后应当打得开';
    END IF;
    rep := rep || jsonb_build_object('R3_switch_on_with_number_succeeds', true);

    -- ══════════ S1 · 带税码的费用单挡住关闭(机械) ══════════
    v_exp := record_expense(v_d, v_exp_acct, 200, v_base, NULL, 'paid', NULL,
                            v_sup, NULL, NULL, NULL, NULL, NULL, NULL);
    v_denied := false; v_msg := NULL;   -- 【每一臂自带干净的 v_msg】残留上一臂的消息会让失败文本把人送去查错地方
    BEGIN UPDATE finance_settings SET gst_registered = false WHERE id;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
        v_denied := (SQLERRM LIKE 'GST_CANNOT_DISABLE_WITH_CODED_EXPENSES|%'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 130 S1 失败:带税码的费用单在册时不许关 GST —— 关掉之后它【再也冲销不了】。实得 %',
            COALESCE(v_msg,'(关掉了)');
    END IF;
    -- 【拒绝要点名】不点名的拒绝等于一堵墙:人不知道该去处理哪一张。
    IF v_msg NOT LIKE '%' || (v_exp->>'code') || '%' THEN
        RAISE EXCEPTION 'FIXTURE 130 S1 失败:拒绝必须点名挡路的那张费用单(%),实得 %',
            v_exp->>'code', v_msg;
    END IF;
    rep := rep || jsonb_build_object('S1_coded_expense_blocks_switch_off', v_msg);

    -- ══════════ S2 · 冲销掉之后,那条拒绝让开 ══════════
    -- 【顺序只有一个方向成立】冲销必须在开关【还开着】的时候做 —— 这正是
    -- 那条拒绝的 HINT 说的话,这一臂把它钉下来。
    PERFORM reverse_expense((v_exp->>'expense_id')::uuid, 'fixture 130');
    v_denied := false; v_msg := NULL;   -- 【每一臂自带干净的 v_msg】残留上一臂的消息会让失败文本把人送去查错地方
    BEGIN UPDATE finance_settings SET gst_registered = false WHERE id;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 130 S2 失败:费用单冲销之后应当关得掉 —— 一个只会拒、永远关不掉的开关是陷阱不是闸。实得 %', v_msg;
    END IF;
    IF gst_registered() THEN
        RAISE EXCEPTION 'FIXTURE 130 S2 失败:开关应当已经关掉了';
    END IF;
    rep := rep || jsonb_build_object('S2_refusal_gives_a_way_out', true);

    -- ══════════ S3 · 在册的带税发票挡住关闭(判断,另一个码) ══════════
    UPDATE finance_settings SET gst_registered = true, gst_registration_no = 'M9-FIX130-0' WHERE id;
    v_sale := record_output_sale(ob, 100, 10, v_base, NULL, v_cust, v_d, NULL, 'manual', NULL);
    v_inv  := create_invoice(v_cust, ARRAY[(v_sale->>'sale_id')::uuid], v_d);
    v_inv_id := (v_inv->>'invoice_id')::uuid;
    v_denied := false; v_msg := NULL;   -- 【每一臂自带干净的 v_msg】残留上一臂的消息会让失败文本把人送去查错地方
    BEGIN UPDATE finance_settings SET gst_registered = false WHERE id;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
        v_denied := (SQLERRM LIKE 'GST_CANNOT_DISABLE_WITH_TAXED_INVOICES|%'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 130 S3 失败:在册的带税发票在时不许关 GST —— 否则申报表报着供应额,而公司声称那一季未注册。实得 %',
            COALESCE(v_msg,'(关掉了)');
    END IF;
    -- 【两条拒绝【不是】同一条】这一臂此刻不该撞上费用单那一条 ——
    -- 机械的那一半与判断的那一半各有各的码,合并会让前者被后者稀释。
    IF v_msg LIKE 'GST_CANNOT_DISABLE_WITH_CODED_EXPENSES|%' THEN
        RAISE EXCEPTION 'FIXTURE 130 S3 失败:此刻挡路的是【发票】,拒绝却报成了费用单那一条';
    END IF;
    rep := rep || jsonb_build_object('S3_taxed_invoice_blocks_with_its_own_code', v_msg);

    -- ══════════ T · 作废之后关得掉 ══════════
    PERFORM void_invoice(v_inv_id, 'fixture 130 teardown', v_d);
    UPDATE finance_settings SET gst_registered = false WHERE id;
    IF gst_registered() THEN
        RAISE EXCEPTION 'FIXTURE 130 T 失败:发票作废之后开关应当关得掉';
    END IF;
    rep := rep || jsonb_build_object('T_switch_off_succeeds_once_cleared', true);

    -- ══════════ U · 关掉之后,结构性保证【原样回来】 ══════════
    -- 这一臂与 fixture 129 的 F1 同源,但问的是【关回去之后】那条保证还在不在 ——
    -- 一个开关如果只在"从未打开过"时才守得住不变量,那它守的不是不变量。
    v_denied := false; v_msg := NULL;   -- 【每一臂自带干净的 v_msg】残留上一臂的消息会让失败文本把人送去查错地方
    BEGIN
        PERFORM post_journal_entry(v_d, 'f130', 'manual', NULL, jsonb_build_array(
            jsonb_build_object('account_code', v_exp_acct, 'side','debit','currency',v_base,'amount_ccy',10,'tax_code','TX'),
            jsonb_build_object('account_code','1000','side','credit','currency',v_base,'amount_ccy',10)));
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM LIKE 'GST_NOT_REGISTERED|%'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 130 U 失败:关回去之后,带税码的分录行必须重新写不进去,实得 %',
            COALESCE(v_msg,'(写进去了)');
    END IF;
    rep := rep || jsonb_build_object('U_guarantee_returns_after_switch_off', true);

    -- 【成功不抛异常】gate 用 ON_ERROR_STOP=1 跑本目录;报告用 NOTICE,
    -- 回滚由文件末尾的 ROLLBACK 做(fixture 127 / 129 抬头同一段话)。
    RAISE NOTICE 'FIXTURE 130 全部通过 %', rep::text;
END $$;
ROLLBACK;
