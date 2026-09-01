-- 147 CONTRACT-1:一张单据抄下【当时在效】的条款,而合同【之后】还可以改
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【五个点名要躲开的陷阱,逐条写出它是怎么躲的】
--
--  (a) **一条断言之所以过,是因为两份实现碰巧一致。**
--      C 臂不比"两个实现算出同一个数",它比的是【同一个对象在两个时刻】:
--      挂上 → 改合同 → 再读那份副本,断言它**逐字节没变**。
--      一个"读取时回查合同"的实现在这里必定红。
--
--  (b) **一条目录断言命中的是注释里的一次提及。**
--      G 臂查 pg_constraint / pg_policy / pg_proc.prosecdef —— **目录事实**,
--      不 grep 源码。注释里写一万遍 "exactly one" 也不会让那条 CHECK 存在。
--
--  (c) **一支 SECURITY DEFINER 函数没有权限检查。**
--      F 臂**真的换一个没权限的角色去调它**,断言按名拒 ——
--      而不是去源码里找 require_permission 那几个字(那属于陷阱 b)。
--
--  (d) **断言过了,是因为那个集合是空的。**
--      每一处比对之前先断言集合非空、且【正好是预期的行数】。
--      E 臂尤其要紧:品位违反那张视图**只在三样都在时才出行**
--      (挂了合同的单 + 它的入库 + 一份未被取代的化验),所以这一臂
--      **自己把三样都造出来**,并先断言"不违反的那一条不出行"——
--      否则"抓到了违反"可能只是"这张视图什么都往外吐"。
--
--  (e) **一个什么都没注入的注入,长得和一个通过了的注入一模一样。**
--      注入之后断言【定义真的变了】,变不了就当场报"这个注入什么也没删"。
--
-- 【本 fixture 钉住的东西】
--   A 合同恰好属于一边;side 是派生的、写不动
--   B 两条拒绝:对手方对不上、合同不是 active —— 而**日期在合同期外【不拒】**
--   C ★★ 抄不是引用:改合同,已挂单据的副本【逐字节不变】★★
--   D 品位规格:至少一个界、下界不高于上界、同一元素不重复
--   E ★ 违反是【报告】:达标的不出行、不达标的出行,而且比的是【副本】不是现行合同
--   F 权限:definer 按名拒;补回权限就放行(证明那不是死路)
--   G 目录事实
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '180s';
DO $$
DECLARE
    v_user   uuid := gen_random_uuid();
    r_all    uuid;
    v_sup    uuid; v_sup2 uuid;
    v_cust   uuid;
    v_con    uuid; v_con_sell uuid;
    v_po     uuid; v_po2 uuid;
    v_mat    uuid;
    v_ib     uuid;
    v_assay  uuid;
    v_before jsonb; v_after jsonb;
    v_r      jsonb;
    v_n      integer;
    v_denied boolean; v_msg text;
    def_link text; v_inj text;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-147', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);
    UPDATE finance_settings SET locked_before = NULL;
    def_link := pg_get_functiondef('public.link_document_to_contract(text,uuid,uuid)'::regprocedure);

    INSERT INTO suppliers (code, legal_name, country, counterparty_type, default_tax_code)
    VALUES ('ZZ147-S1', 'Fixture 147 Supplier', 'SG', 'goods_supplier', 'TX') RETURNING id INTO v_sup;
    INSERT INTO suppliers (code, legal_name, country, counterparty_type)
    VALUES ('ZZ147-S2', 'Fixture 147 Other Supplier', 'SG', 'goods_supplier') RETURNING id INTO v_sup2;
    INSERT INTO customers (code, legal_name, country, payment_terms_days)
    VALUES ('ZZ147-C1', 'Fixture 147 Customer', 'SG', 30) RETURNING id INTO v_cust;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZ147-M1', 'Fixture 147 material', 'battery_material', true, 'black_mass', 'end_of_life')
    RETURNING id INTO v_mat;

    -- ══════════ A. 恰好一边;side 是派生的 ═════════════════════════════════
    v_denied := false; v_msg := NULL;
    BEGIN INSERT INTO contracts (customer_id, supplier_id, kind, title, effective_from)
          VALUES (v_cust, v_sup, 'supply', 'both sides', '2026-01-01');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 147A 失败:两边都填的合同不该建得出来'; END IF;
    v_denied := false;
    BEGIN INSERT INTO contracts (kind, title, effective_from)
          VALUES ('supply', 'no side', '2026-01-01');
    EXCEPTION WHEN OTHERS THEN v_denied := true; END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 147A 失败:两边都不填的合同不该建得出来'; END IF;

    INSERT INTO contracts (supplier_id, kind, title, effective_from, effective_to,
                           status, currency, incoterm, payment_terms_days)
    VALUES (v_sup, 'supply', 'Fixture 147 supply agreement', '2026-03-01', '2027-02-28',
            'active', 'SGD', 'CIF', 45)
    RETURNING id INTO v_con;
    IF (SELECT side FROM contracts WHERE id = v_con) <> 'buy' THEN
        RAISE EXCEPTION 'FIXTURE 147A 失败:挂供应商的合同 side 应当是 buy'; END IF;
    -- 【派生列写不动】两处都能写就是两个真源
    v_denied := false;
    BEGIN UPDATE contracts SET side = 'sell' WHERE id = v_con;
    EXCEPTION WHEN OTHERS THEN v_denied := true; END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 147A 失败:side 是派生列,不该写得动'; END IF;
    INSERT INTO contracts (customer_id, kind, title, effective_from, status)
    VALUES (v_cust, 'offtake', 'Fixture 147 offtake', '2026-03-01', 'active')
    RETURNING id INTO v_con_sell;
    IF (SELECT side FROM contracts WHERE id = v_con_sell) <> 'sell' THEN
        RAISE EXCEPTION 'FIXTURE 147A 失败:挂客户的合同 side 应当是 sell'; END IF;

    -- ══════════ D. 品位规格的三条形状 ══════════════════════════════════════
    v_denied := false; v_msg := NULL;
    BEGIN INSERT INTO contract_grade_specs (contract_id, metal) VALUES (v_con, 'ni');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 147D 失败:两边都不设限的"规格"不该建得出来 —— 它什么也没规定'; END IF;
    v_denied := false;
    BEGIN INSERT INTO contract_grade_specs (contract_id, metal, min_pct, max_pct)
          VALUES (v_con, 'ni', 30, 10);
    EXCEPTION WHEN OTHERS THEN v_denied := true; END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 147D 失败:下界高于上界不该建得出来 —— 那条规格永远不可能被满足'; END IF;

    -- 真的规格:Ni ≥ 18(只有下界)、Cu ≤ 0.5(只有上界)—— 两种单边都是常态
    INSERT INTO contract_grade_specs (contract_id, metal, min_pct) VALUES (v_con, 'ni', 18);
    INSERT INTO contract_grade_specs (contract_id, metal, max_pct) VALUES (v_con, 'cu', 0.5);
    v_denied := false;
    BEGIN INSERT INTO contract_grade_specs (contract_id, metal, min_pct) VALUES (v_con, 'ni', 20);
    EXCEPTION WHEN OTHERS THEN v_denied := true; END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 147D 失败:同一份合同同一种元素不该规定两次 —— "哪一条说了算"会变成按写入时刻破平局'; END IF;

    -- 保险义务:金额要有币种
    v_denied := false;
    BEGIN INSERT INTO contract_insurance_obligations (contract_id, insured_by, cover_type, min_amount)
          VALUES (v_con, 'counterparty', 'Cargo', 2000000);
    EXCEPTION WHEN OTHERS THEN v_denied := true; END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 147D 失败:有金额没币种不该建得出来 —— 一个没有单位的金额会被读错'; END IF;
    INSERT INTO contract_insurance_obligations (contract_id, insured_by, cover_type, min_amount, currency)
    VALUES (v_con, 'counterparty', 'Cargo', 2000000, 'SGD');

    -- ══════════ 场景:两张采购单 ═══════════════════════════════════════════
    -- 【本位币不需要汇率,而 fx_rates 会按名拒收】—— 这一行原本给 SGD 插一条 1.0
    -- 的牌价,而那道 CHECK 拒得对:本位币的"汇率"是一个没有意义的数。
    v_r := create_purchase_order(v_sup, '2026-06-01', '2026-07-01', 'SGD', NULL, 'CIF', NULL, NULL,
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 100, 'unit', 'kg')));
    v_po := (v_r->>'purchase_order_id')::uuid;
    v_r := create_purchase_order(v_sup2, '2026-06-01', '2026-07-01', 'SGD', NULL, 'CIF', NULL, NULL,
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 100, 'unit', 'kg')));
    v_po2 := (v_r->>'purchase_order_id')::uuid;

    -- ══════════ B. 两条拒绝,以及【刻意不拒】的那一条 ══════════════════════
    -- 对手方对不上
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM link_document_to_contract('purchase_order', v_po2, v_con);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'CONTRACT_COUNTERPARTY_MISMATCH|%' THEN
        RAISE EXCEPTION 'FIXTURE 147B 失败:对手方对不上应当按名拒,实得 %', COALESCE(v_msg,'(挂上了)'); END IF;
    -- 一张采购单挂不上销售合同
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM link_document_to_contract('purchase_order', v_po, v_con_sell);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'CONTRACT_SIDE_MISMATCH|%' THEN
        RAISE EXCEPTION 'FIXTURE 147B 失败:采购单挂销售合同应当按名拒,实得 %', COALESCE(v_msg,'(挂上了)'); END IF;
    -- 合同不是 active
    UPDATE contracts SET status = 'draft' WHERE id = v_con;
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM link_document_to_contract('purchase_order', v_po, v_con);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'CONTRACT_NOT_ACTIVE|%' THEN
        RAISE EXCEPTION 'FIXTURE 147B 失败:草稿合同应当按名拒,实得 %', COALESCE(v_msg,'(挂上了)'); END IF;
    -- 【被拒之后什么都没写下】—— 一次"拒了但已经抄了一半"的实现在这里被抓住
    IF EXISTS (SELECT 1 FROM contract_document_terms WHERE purchase_order_id = v_po) THEN
        RAISE EXCEPTION 'FIXTURE 147B 失败:被拒的挂接留下了一份抄件'; END IF;
    IF (SELECT contract_id FROM purchase_orders WHERE id = v_po) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 147B 失败:被拒的挂接改动了单据'; END IF;
    UPDATE contracts SET status = 'active' WHERE id = v_con;

    -- ★【刻意不拒:单据日期在合同期【之外】仍然挂得上】★
    --   这一臂断言的是一条【没有建】的规矩 —— 它在这里,是为了让下一个想加
    --   "日期必须落在合同期内"的人先读到:那需要一次裁定,不是一句 IF。
    v_r := create_purchase_order(v_sup, '2026-01-15', '2026-02-01', 'SGD', NULL, 'CIF', NULL, NULL,
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 10, 'unit', 'kg')));
    PERFORM link_document_to_contract('purchase_order', (v_r->>'purchase_order_id')::uuid, v_con);
    IF (SELECT contract_id FROM purchase_orders WHERE id = (v_r->>'purchase_order_id')::uuid) IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 147B 失败:早于合同生效日的单据应当【仍然挂得上】—— 回填是正当操作'; END IF;

    -- ══════════ C. ★★ 抄不是引用 ★★ ═══════════════════════════════════════
    v_r := link_document_to_contract('purchase_order', v_po, v_con);
    IF (v_r->>'grade_specs_copied')::int <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 147C 失败:应当抄下 2 条品位规格,实得 %', v_r->>'grade_specs_copied'; END IF;
    -- 陷阱 (d):比对之前先证明它非空
    SELECT jsonb_build_object('code', contract_code, 'title', contract_title,
                              'inco', incoterm, 'ccy', currency, 'terms', payment_terms_days,
                              'specs', grade_specs)
      INTO v_before FROM contract_document_terms WHERE purchase_order_id = v_po;
    IF v_before IS NULL OR jsonb_array_length(v_before->'specs') <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 147C 失败:抄件不是两条规格 —— 下面那句比对会是一句空话'; END IF;

    -- ★ 现在把合同改得面目全非 ★
    UPDATE contracts SET title = 'REWRITTEN BY FIXTURE 147', incoterm = 'FOB',
                         currency = 'USD', payment_terms_days = 7
     WHERE id = v_con;
    UPDATE contract_grade_specs SET min_pct = 99 WHERE contract_id = v_con AND metal = 'ni';
    DELETE FROM contract_grade_specs WHERE contract_id = v_con AND metal = 'cu';

    SELECT jsonb_build_object('code', contract_code, 'title', contract_title,
                              'inco', incoterm, 'ccy', currency, 'terms', payment_terms_days,
                              'specs', grade_specs)
      INTO v_after FROM contract_document_terms WHERE purchase_order_id = v_po;
    IF v_before IS DISTINCT FROM v_after THEN
        RAISE EXCEPTION 'FIXTURE 147C 失败:★ 改了合同之后,已挂单据抄下的条款变了 ★ 之前=% 之后=%',
            v_before, v_after; END IF;
    -- 【而合同确实变了 —— 否则"没变"什么也没证明】
    IF (SELECT title FROM contracts WHERE id = v_con) <> 'REWRITTEN BY FIXTURE 147' THEN
        RAISE EXCEPTION 'FIXTURE 147C 失败:合同没有被改动 —— 这一臂因此证明不了任何事'; END IF;
    IF (SELECT count(*) FROM contract_grade_specs WHERE contract_id = v_con) <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 147C 失败:合同现在应当只剩 1 条规格'; END IF;

    -- 改挂按名拒 —— 改挂等于把一张单据当初依据的条款换掉
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM link_document_to_contract('purchase_order', v_po, v_con);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'DOCUMENT_ALREADY_UNDER_CONTRACT|%' THEN
        RAISE EXCEPTION 'FIXTURE 147C 失败:重复挂接应当按名拒,实得 %', COALESCE(v_msg,'(又挂了一次)'); END IF;

    -- ══════════ E. ★ 违反是【报告】,而且比的是【副本】 ★ ═══════════════════
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty,
                                 arrival_date, unit_price, purchase_order_id, purchase_order_line_id)
    VALUES ('ZZ147-IB1', v_mat, v_sup, 100, 100, DATE '2026-06-10', 10, v_po,
            (SELECT id FROM purchase_order_lines WHERE purchase_order_id = v_po LIMIT 1))
    RETURNING id INTO v_ib;
    -- 【重量基准必填,而那道闸是对的】一份没说明湿基/干基的化验单,
    -- 事后没有任何办法还原它按的是哪一种 —— 与本刀"具名而不留白"是同一条。
    -- 【result_party 也必填】"这份化验是谁出的"事后不可恢复(PROC-6 那一课)。
    INSERT INTO assay_results (code, inbound_batch_id, assay_date, is_final,
                               weight_basis, result_party)
    VALUES ('ZZ147-ASY-1', v_ib, '2026-06-12', true, 'as_received', 'ours')
    RETURNING id INTO v_assay;

    -- 【先放【达标】的值,断言它【不】出行】—— 陷阱 (d):
    -- 否则"抓到了违反"可能只是"这张视图什么都往外吐"
    INSERT INTO assay_result_metals (assay_result_id, metal, content_pct)
    VALUES (v_assay, 'ni', 22), (v_assay, 'cu', 0.3);
    SELECT count(*) INTO v_n FROM contract_grade_breaches WHERE purchase_order_id = v_po;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 147E 失败:Ni 22%% ≥ 18%% 且 Cu 0.3%% ≤ 0.5%%,不该有违反,实得 % 条', v_n; END IF;

    -- 【现在把 Ni 改到不达标】—— 副本里的下界是 18(合同现在写的是 99)
    UPDATE assay_result_metals SET content_pct = 12 WHERE assay_result_id = v_assay AND metal = 'ni';
    SELECT count(*) INTO v_n FROM contract_grade_breaches WHERE purchase_order_id = v_po;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 147E 失败:Ni 12%% < 18%% 应当报 1 条违反,实得 %', v_n; END IF;
    -- ★ 比的是【副本】而不是现行合同:合同现在要求 99,副本要求 18。
    --   如果它读的是现行合同,下界会是 99 —— 而 22% 那一次就该报违反了(它没有)。
    IF (SELECT min_pct FROM contract_grade_breaches WHERE purchase_order_id = v_po) <> 18 THEN
        RAISE EXCEPTION 'FIXTURE 147E 失败:★ 违反判据用的是合同【现在】的规格,不是单据当初抄下的那份 ★';
    END IF;
    IF (SELECT breach_side FROM contract_grade_breaches WHERE purchase_order_id = v_po) <> 'below_min' THEN
        RAISE EXCEPTION 'FIXTURE 147E 失败:低于下限应当报 below_min'; END IF;
    -- 【上界那一侧也要能抓】Cu 抄件里是 ≤0.5,把它改到 0.9
    UPDATE assay_result_metals SET content_pct = 0.9 WHERE assay_result_id = v_assay AND metal = 'cu';
    SELECT count(*) INTO v_n FROM contract_grade_breaches
     WHERE purchase_order_id = v_po AND breach_side = 'above_max';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 147E 失败:Cu 0.9%% > 0.5%% 应当报 above_max,实得 %', v_n; END IF;

    -- 覆盖率:分母必须是【真的】,否则"0 条违反"说不出自己是哪一种 0
    IF (SELECT purchase_orders_under_contract FROM contract_coverage) < 2 THEN
        RAISE EXCEPTION 'FIXTURE 147E 失败:覆盖率里挂了合同的采购单应当至少 2 张'; END IF;
    IF (SELECT purchase_orders_total FROM contract_coverage)
       <= (SELECT purchase_orders_under_contract FROM contract_coverage) THEN
        RAISE EXCEPTION 'FIXTURE 147E 失败:总数应当【大于】挂了合同的数 —— 否则这张覆盖率视图证明不了它要证明的那件事(有单据没挂合同)';
    END IF;

    -- ══════════ F. 权限 —— 真的换一个没权限的角色去调 ═══════════════════════
    DELETE FROM role_permissions WHERE role_id = r_all AND permission_code = 'module.suppliers.edit';
    v_r := create_purchase_order(v_sup, '2026-06-02', '2026-07-02', 'SGD', NULL, 'CIF', NULL, NULL,
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 5, 'unit', 'kg')));
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM link_document_to_contract('purchase_order', (v_r->>'purchase_order_id')::uuid, v_con);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'PERMISSION_DENIED%' THEN
        RAISE EXCEPTION 'FIXTURE 147F 失败:没有 suppliers.edit 不该挂得上,实得 %', COALESCE(v_msg,'(挂上了)'); END IF;
    -- 【补回权限就放行 —— 证明上面那个拒绝不是"函数本来就不工作"】
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_all, 'module.suppliers.edit');
    PERFORM link_document_to_contract('purchase_order', (v_r->>'purchase_order_id')::uuid, v_con);
    IF (SELECT contract_id FROM purchase_orders WHERE id = (v_r->>'purchase_order_id')::uuid) IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 147F 失败:补回权限之后应当挂得上 —— 上面那个拒绝因此不是一次测量'; END IF;

    -- ══════════ G. 目录事实 —— 查 pg_catalog,不 grep 源码(陷阱 b)═════════
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.contracts'::regclass
                     AND conname = 'contracts_exactly_one_counterparty') THEN
        RAISE EXCEPTION 'FIXTURE 147G 失败:恰好一边那条 CHECK 不在目录里'; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conrelid = 'public.contract_grade_specs'::regclass
                      AND conname = 'contract_grade_specs_needs_a_bound') THEN
        RAISE EXCEPTION 'FIXTURE 147G 失败:至少一个界那条 CHECK 不在目录里'; END IF;
    -- contract_document_terms 【没有】写策略:抄写与检查必须同生共死
    SELECT count(*) INTO v_n FROM pg_policy
     WHERE polrelid = 'public.contract_document_terms'::regclass AND polcmd IN ('a','w');
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 147G 失败:抄件表不该有 INSERT/UPDATE 策略,实得 % 条', v_n; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'link_document_to_contract' AND prosecdef) THEN
        RAISE EXCEPTION 'FIXTURE 147G 失败:挂接函数应当是 SECURITY DEFINER'; END IF;
    -- 保险【没有】第二套到期机制:certificate_types 里多了一行,而不是多了一张表
    IF NOT EXISTS (SELECT 1 FROM certificate_types WHERE code = 'insurance') THEN
        RAISE EXCEPTION 'FIXTURE 147G 失败:保险那一行不在 certificate_types 里'; END IF;
    SELECT count(*) INTO v_n FROM information_schema.tables
     WHERE table_schema = 'public' AND table_name ~ 'insurance' AND table_name <> 'contract_insurance_obligations';
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 147G 失败:出现了第二套保险机制(% 张表)—— 保险是一种证书,不是一套新机制', v_n; END IF;

    -- ══════════ 故障注入 —— 先证明"注入真的改了东西"(陷阱 e)═══════════════
    -- 注入:把"抄品位规格"那一步换成永远抄空,断言 E 臂当场瞎掉。
    v_inj := replace(def_link, 'FROM contract_grade_specs g WHERE g.contract_id = v_con.id',
                               'FROM contract_grade_specs g WHERE false');
    IF v_inj = def_link THEN
        RAISE EXCEPTION 'FIXTURE 147 注入 失败:没找到"抄品位规格"那一段 —— 这个注入什么也没删'; END IF;
    EXECUTE v_inj;
    DELETE FROM contract_document_terms WHERE purchase_order_id = v_po;
    UPDATE purchase_orders SET contract_id = NULL WHERE id = v_po;
    PERFORM link_document_to_contract('purchase_order', v_po, v_con);
    SELECT count(*) INTO v_n FROM contract_grade_breaches WHERE purchase_order_id = v_po;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 147 注入 失败:抄空了规格,违反视图却还在报 % 条 —— 说明它读的不是那份抄件', v_n; END IF;
    EXECUTE def_link;   -- 放回去
    DELETE FROM contract_document_terms WHERE purchase_order_id = v_po;
    UPDATE purchase_orders SET contract_id = NULL WHERE id = v_po;
    v_r := link_document_to_contract('purchase_order', v_po, v_con);
    IF (v_r->>'grade_specs_copied')::int <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 147 注入 失败:恢复之后应当又抄得下规格(合同现在只剩 1 条)'; END IF;
END $$;
ROLLBACK;
