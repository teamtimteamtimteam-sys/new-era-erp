-- 149 SETTLE-1:结算口径 —— **不声明重量基准就拒**,而**湿基与干基结算出不同的钱**
--
-- ═══════════════════════════════════════════════════════════════════════════
-- ★★【一件必须先说的事:这一支走的路,线上【没有数据】】★★
--   实测(2026-08-30):`assay_results` 4 行**全部挂在进料批次上**,
--   **产出批次上一份化验都没有**。而销售结算走的正是产出批次那一侧 ——
--   所以**这条路今天只被 fixture 走过,一次线上数据都没有走过**。
--   **这一支全绿,不说明线上那条路是通的。** 与 WHT-1 那个空的主语类、
--   PRICE-1 那本空日历同一种形状:**说出来,它就是可接受的;不说,它就是假绿。**
--
-- 【五个点名要躲开的陷阱,逐条写出这一支是怎么躲的】
--  (a) **两份实现碰巧一致。** A 臂**把湿基与干基两个金额都算出来**并断言它们
--      **不相等**;同时断言**含金属两边一模一样**(那是换算对了的证据)。
--      一个"不换算"的实现会让含金属两边不同 —— 当场红。
--  (b) **目录断言命中注释里的一次提及。** H 臂查 information_schema /
--      pg_constraint / pg_trigger / pg_class.relrowsecurity —— **目录事实**;
--      而且**先断言该有的在**,再断言不该有的不在。
--  (c) **SECURITY DEFINER 没有权限检查。** G 臂**真的换角色**去调 definer 那一支,
--      断言按名拒;并断言补回权限之后它放行(否则那不是一次测量)。
--  (d) **集合是空的所以过了。** 每一处比对之前先造一个**会成功的基线**并断言
--      出具体数字(11542.50 / 11567.50 / 含金属 1800 kg)。
--  (e) **一个什么都没注入的注入。** 末尾注入先断言【定义真的变了】。
--
-- 【本 fixture 钉住的东西】
--   A ★★ 不声明基准 → 拒;而湿基与干基**含金属相同、金额不同** ★★
--   B 【没有声明】与【声明了"没有"】是两个事实(精炼费 / 惩罚)
--   C 谁的化验说了算;仲裁结果总是可结算;**选择被记下来,不是被推导**
--   D 两方不一致:没声明容差 → 拒;超过容差 → 拒;容差内 → 放行
--   E 要换算基准却没有水分 → 拒
--   F 结算记录不可改(只有 superseded_by 动得了)
--   G 权限按名拒,补回就放行
--   H 目录事实(含那个刻意的缺席:它不过账)
--   I 抄不是引用
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '240s';
DO $$
DECLARE
    v_user  uuid := gen_random_uuid();
    r_all   uuid;
    v_cust  uuid; v_mat uuid;
    v_con_d uuid; v_con_w uuid; v_con_np uuid;
    v_so_d  uuid; v_so_w uuid; v_so_np uuid;
    v_ob    uuid;
    v_a_ours uuid; v_a_cp uuid; v_a_ump uuid;
    v_r     jsonb; v_r2 jsonb;
    v_amt_d numeric; v_amt_w numeric;
    v_con_d_kg numeric; v_con_w_kg numeric;
    v_denied boolean; v_msg text;
    v_n     integer; v_sid uuid;
    v_before jsonb; v_after jsonb;
    def_c   text; v_inj text;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-149','f','f',true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);
    UPDATE finance_settings SET locked_before = NULL;
    def_c := pg_get_functiondef('public.sale_settlement_compute(uuid,uuid,uuid)'::regprocedure);

    -- ── 行情与日历:让 PRICE-1 那一支算得出 10000 USD/t ────────────────────
    -- 【调它,不另写一份】结算的价格项走 index_period_average,而不是本 fixture
    -- 自己编一个价 —— 那样这一支就证明不了"四条条款是同一条公式"。
    INSERT INTO index_market_calendar (index_code, calendar_date, is_trading_day, note)
    SELECT 'LME', d::date, EXTRACT(ISODOW FROM d) < 6, 'fixture 149'
      FROM generate_series(DATE '2026-09-01', DATE '2026-09-30', interval '1 day') d;
    INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date, source, price_index)
    SELECT m, 10000, c.calendar_date, 'published_index', 'LME'
      FROM index_market_calendar c CROSS JOIN (VALUES ('ni'),('cu')) AS x(m)
     WHERE c.index_code='LME' AND c.is_trading_day;

    -- 【实验室是字典,不是自由文本】G17 已经落地:assay_results.lab_name 是
    -- laboratories(code) 的外键。所以这一支自己造三家,而不是借线上那一家 ——
    -- 一家实验室既当我方又当仲裁方,会让 D 臂看起来通过而其实什么都没分开。
    INSERT INTO laboratories (code, name_en, name_zh, is_active, sort_order) VALUES
        ('ZZ149-OURS','Fixture 149 our lab','示例我方实验室',true,900),
        ('ZZ149-BUY','Fixture 149 buyer lab','示例买方实验室',true,901),
        ('ZZ149-UMP','Fixture 149 umpire lab','示例仲裁实验室',true,902);
    INSERT INTO customers (code, legal_name, country, payment_terms_days)
    VALUES ('ZZ149-C1','Fixture 149 Customer','SG',30) RETURNING id INTO v_cust;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZ149-M1','Fixture 149 material','battery_material',true,'black_mass','end_of_life')
    RETURNING id INTO v_mat;
    -- 【output_date 必填,而那道闸是对的】FIN-32:产出批次会派生一条库存移动,
    -- 而移动的 business_date 是【事情发生的那一天】,不是键入的那一天。
    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, output_date)
    VALUES ('ZZ149-OB1', v_mat, 10000, 10000, DATE '2026-09-14') RETURNING id INTO v_ob;

    -- 化验:干基,水分 10%,Ni 20%,Cu 2.5%
    INSERT INTO assay_results (code, output_batch_id, assay_date, is_final,
                               weight_basis, moisture_pct, result_party, lab_name)
    VALUES ('ZZ149-AS-OURS', v_ob, DATE '2026-09-15', true, 'dry', 10, 'ours', 'ZZ149-OURS')
    RETURNING id INTO v_a_ours;
    INSERT INTO assay_result_metals (assay_result_id, metal, content_pct)
    VALUES (v_a_ours,'ni',20), (v_a_ours,'cu',2.5);

    -- ── 两份合同:一份按干基结算,一份按湿基,其余条款【逐字相同】───────────
    -- 【为什么是两份合同而不是改一份】条款在**挂接那一刻**冻结(CONTRACT-1/PRICE-1
    -- 的语义),所以要比两种基准,就要两份各自冻好的副本 —— 这本身也证明了
    -- 副本是副本:改合同不会回头改写已挂单据。
    INSERT INTO contracts (customer_id, kind, title, effective_from, status)
    VALUES (v_cust,'offtake','Fixture 149 dry', DATE '2026-01-01','active') RETURNING id INTO v_con_d;
    INSERT INTO contracts (customer_id, kind, title, effective_from, status)
    VALUES (v_cust,'offtake','Fixture 149 wet', DATE '2026-01-01','active') RETURNING id INTO v_con_w;
    FOREACH v_msg IN ARRAY ARRAY['d','w'] LOOP
        DECLARE v_c uuid := CASE WHEN v_msg='d' THEN v_con_d ELSE v_con_w END;
        BEGIN
            INSERT INTO contract_pricing_terms (contract_id, metal, base_event, qp_months, index_code, payable_pct)
            VALUES (v_c,'ni','assay_complete',0,'LME',70), (v_c,'cu','assay_complete',0,'LME',1);
            INSERT INTO contract_settlement_terms (contract_id, sale_weight_basis, settling_party,
                        sample_retention_required, refining_charge_basis, penalty_basis)
            VALUES (v_c, CASE WHEN v_msg='d' THEN 'dry' ELSE 'as_received' END,
                    'ours', true, 'per_metal', 'per_element');
            INSERT INTO contract_refining_charges (contract_id, metal, usd_per_tonne_of_metal)
            VALUES (v_c,'ni',100), (v_c,'cu',0);
            INSERT INTO contract_penalty_elements (contract_id, substance, threshold_pct, usd_per_tonne_per_pct_over)
            VALUES (v_c,'cu',0.5,50);
        END;
    END LOOP;

    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES ('ZZ149-SO-D', v_cust, DATE '2026-06-10','SGD',1) RETURNING id INTO v_so_d;
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES ('ZZ149-SO-W', v_cust, DATE '2026-06-10','SGD',1) RETURNING id INTO v_so_w;
    PERFORM link_document_to_contract('sales_order', v_so_d, v_con_d);
    PERFORM link_document_to_contract('sales_order', v_so_w, v_con_w);

    -- ══════════ A. ★★ 湿基与干基:含金属【相同】,金额【不同】★★ ═══════════
    v_r  := sale_settlement_compute(v_so_d, v_ob, v_a_ours);
    v_r2 := sale_settlement_compute(v_so_w, v_ob, v_a_ours);
    v_amt_d := (v_r->>'amount_usd')::numeric;
    v_amt_w := (v_r2->>'amount_usd')::numeric;
    SELECT (e->>'contained_kg')::numeric INTO v_con_d_kg
      FROM jsonb_array_elements(v_r->'breakdown'->'metals') e WHERE e->>'metal'='ni';
    SELECT (e->>'contained_kg')::numeric INTO v_con_w_kg
      FROM jsonb_array_elements(v_r2->'breakdown'->'metals') e WHERE e->>'metal'='ni';
    -- 【陷阱 d】先钉住具体数字,而不是"它没报错"
    IF (v_r->>'settlement_weight_kg')::numeric <> 9000 THEN
        RAISE EXCEPTION 'FIXTURE 149A 失败:干基结算重量应当是 9000kg(10000 扣 10%% 水),实得 %', v_r->>'settlement_weight_kg'; END IF;
    IF (v_r2->>'settlement_weight_kg')::numeric <> 10000 THEN
        RAISE EXCEPTION 'FIXTURE 149A 失败:湿基结算重量应当是毛重 10000kg,实得 %', v_r2->>'settlement_weight_kg'; END IF;
    -- ★ 含金属是不变量 —— 这是"换算对了"的证据;不换算的实现在这里必定红 ★
    IF v_con_d_kg <> 1800 OR v_con_w_kg <> 1800 THEN
        RAISE EXCEPTION 'FIXTURE 149A 失败:★ 含镍两种基准下都应当是 1800kg —— 换算对了它就是不变量 ★ 干基=% 湿基=%', v_con_d_kg, v_con_w_kg; END IF;
    -- ★ 而金额【不同】—— 惩罚按结算重量收,水是随货一起进来的 ★
    IF v_amt_d = v_amt_w THEN
        RAISE EXCEPTION 'FIXTURE 149A 失败:★ 湿基与干基结算出了【同一个金额】(%)—— 那说明重量基准根本没有参与计算,而 GO-3 点名的正是这件事 ★', v_amt_d; END IF;
    IF v_amt_d <> 11542.50 OR v_amt_w <> 11567.50 THEN
        RAISE EXCEPTION 'FIXTURE 149A 失败:手算是 干基 11542.50 / 湿基 11567.50,实得 % / %', v_amt_d, v_amt_w; END IF;

    -- ★ 不声明基准 → 拒 ★
    UPDATE assay_results SET weight_basis = NULL WHERE id = v_a_ours;
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM sale_settlement_compute(v_so_d, v_ob, v_a_ours);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'ASSAY_WEIGHT_BASIS_NOT_STATED|ZZ149-AS-OURS%' THEN
        RAISE EXCEPTION 'FIXTURE 149A 失败:★ 没有声明重量基准就结算,应当按名拒 —— 留空是【没有人说过】,不是"按惯例是干基" ★ 实得 %', COALESCE(v_msg,'(算出来了)'); END IF;
    UPDATE assay_results SET weight_basis = 'dry' WHERE id = v_a_ours;

    -- ══════════ E. 要换算却没有水分 → 拒 ═══════════════════════════════════
    UPDATE assay_results SET moisture_pct = NULL WHERE id = v_a_ours;
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM sale_settlement_compute(v_so_w, v_ob, v_a_ours);   -- 干基化验 → 湿基结算
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'SETTLEMENT_MOISTURE_NOT_STATED|%' THEN
        RAISE EXCEPTION 'FIXTURE 149E 失败:化验按干基、合同按湿基,换算要水分而它没有 —— 应当按名拒,实得 %', COALESCE(v_msg,'(算出来了)'); END IF;
    -- 【同一份化验、同一个缺失,按干基结算却【应当照样算得出】—— 那证明这条拒绝
    --   针对的是"换算"这件事,不是"水分"这个字段】
    IF (sale_settlement_compute(v_so_d, v_ob, v_a_ours)->>'settlement_weight_kg')::numeric <> 10000 THEN
        RAISE EXCEPTION 'FIXTURE 149E 失败:没有水分时按干基结算应当把毛重当作结算重量'; END IF;
    UPDATE assay_results SET moisture_pct = 10 WHERE id = v_a_ours;

    -- ══════════ B. 【没有声明】与【声明了"没有"】是两个事实 ════════════════
    INSERT INTO contracts (customer_id, kind, title, effective_from, status)
    VALUES (v_cust,'offtake','Fixture 149 none-agreed', DATE '2026-01-01','active') RETURNING id INTO v_con_np;
    INSERT INTO contract_pricing_terms (contract_id, metal, base_event, qp_months, index_code, payable_pct)
    VALUES (v_con_np,'ni','assay_complete',0,'LME',70), (v_con_np,'cu','assay_complete',0,'LME',1);
    INSERT INTO contract_settlement_terms (contract_id, sale_weight_basis, settling_party,
                sample_retention_required, refining_charge_basis, penalty_basis)
    VALUES (v_con_np,'dry','ours',false,'none_agreed','none_agreed');
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES ('ZZ149-SO-NP', v_cust, DATE '2026-06-10','SGD',1) RETURNING id INTO v_so_np;
    PERFORM link_document_to_contract('sales_order', v_so_np, v_con_np);
    v_r := sale_settlement_compute(v_so_np, v_ob, v_a_ours);
    -- 【声明了"没有"】→ 算得出,而且精炼费与惩罚都是 0(一次被记录的决定)
    IF (v_r->>'refining_charge_usd')::numeric <> 0 OR (v_r->>'penalty_usd')::numeric <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 149B 失败:声明了 none_agreed,精炼费与惩罚都应当是 0,实得 % / %',
            v_r->>'refining_charge_usd', v_r->>'penalty_usd'; END IF;
    -- 【陷阱 d】而它必须真的算出了钱 —— 否则"两个 0"可能只是因为它什么都没算
    IF (v_r->>'amount_usd')::numeric <= 0 THEN
        RAISE EXCEPTION 'FIXTURE 149B 失败:声明了 none_agreed 的合同应当仍然结算得出正金额,实得 %', v_r->>'amount_usd'; END IF;
    -- 【声明了"有"、却没填】→ 拒
    UPDATE contract_settlement_terms SET refining_charge_basis='per_metal' WHERE contract_id=v_con_np;
    DELETE FROM contract_document_terms WHERE sales_order_id=v_so_np;
    UPDATE sales_orders SET contract_id=NULL WHERE id=v_so_np;
    PERFORM link_document_to_contract('sales_order', v_so_np, v_con_np);
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM sale_settlement_compute(v_so_np, v_ob, v_a_ours);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'REFINING_CHARGE_NOT_FILED|%' THEN
        RAISE EXCEPTION 'FIXTURE 149B 失败:★ 声明了按金属收精炼费却没填费率,应当按名拒 —— 【声明了有】与【填了多少】是两件事 ★ 实得 %', COALESCE(v_msg,'(算出来了)'); END IF;

    -- ══════════ C. 谁的化验说了算;选择被【记下来】═════════════════════════
    INSERT INTO assay_results (code, output_batch_id, assay_date, is_final,
                               weight_basis, moisture_pct, result_party, lab_name)
    VALUES ('ZZ149-AS-CP', v_ob, DATE '2026-09-15', true, 'dry', 10, 'counterparty', 'ZZ149-BUY')
    RETURNING id INTO v_a_cp;
    INSERT INTO assay_result_metals (assay_result_id, metal, content_pct)
    VALUES (v_a_cp,'ni',20), (v_a_cp,'cu',2.5);          -- 先与我方【一致】,D 臂再改
    UPDATE contract_settlement_terms SET settling_party='counterparty' WHERE contract_id=v_con_d;
    DELETE FROM contract_document_terms WHERE sales_order_id=v_so_d;
    UPDATE sales_orders SET contract_id=NULL WHERE id=v_so_d;
    PERFORM link_document_to_contract('sales_order', v_so_d, v_con_d);
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM sale_settlement_compute(v_so_d, v_ob, v_a_ours);   -- 选了我方的
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'ASSAY_PARTY_NOT_THE_SETTLING_PARTY|%' THEN
        RAISE EXCEPTION 'FIXTURE 149C 失败:合同说按对手方的化验结算,选我方的应当按名拒,实得 %', COALESCE(v_msg,'(算出来了)'); END IF;
    -- 选对手方的 → 放行(证明上面那个拒绝不是一条死路)
    v_r := sale_settlement_compute(v_so_d, v_ob, v_a_cp);
    IF v_r->>'settling_party_used' <> 'counterparty' THEN
        RAISE EXCEPTION 'FIXTURE 149C 失败:用了对手方的化验,记下来的却是 %', v_r->>'settling_party_used'; END IF;
    -- ★ 选择被【记下来】,不是被推导 ★
    v_r := record_sale_settlement(v_so_d, v_ob, v_a_cp);
    v_sid := (v_r->>'settlement_id')::uuid;
    SELECT count(*) INTO v_n FROM sales_settlements WHERE id=v_sid AND assay_result_id=v_a_cp;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 149C 失败:结算记录上没有记下【用了哪一份化验】—— 而 applied_at 是一个成分事实,不是一次结算决定'; END IF;
    IF (v_r->>'posted_to_ledger')::boolean THEN
        RAISE EXCEPTION 'FIXTURE 149C 失败:本刀【不过账】,而返回值说它过了'; END IF;

    -- ══════════ D. 两方不一致 ══════════════════════════════════════════════
    UPDATE assay_result_metals SET content_pct = 18 WHERE assay_result_id=v_a_cp AND metal='ni';
    -- 【陷阱 d】先证明两份结果**真的不一样**,否则这一臂比的是空
    IF (SELECT content_pct FROM assay_result_metals WHERE assay_result_id=v_a_ours AND metal='ni')
     = (SELECT content_pct FROM assay_result_metals WHERE assay_result_id=v_a_cp   AND metal='ni') THEN
        RAISE EXCEPTION 'FIXTURE 149D 失败:两份结果一样 —— 这一臂证明不了任何事'; END IF;
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM sale_settlement_compute(v_so_d, v_ob, v_a_cp);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'RESULTS_IN_DISPUTE|%' THEN
        RAISE EXCEPTION 'FIXTURE 149D 失败:★ 两方结果不一致而没有声明容差,系统【不许自己选】—— 应当按名拒 ★ 实得 %', COALESCE(v_msg,'(算出来了)'); END IF;
    -- 声明一个【容差之内】的容差 → 放行
    UPDATE contract_settlement_terms SET splitting_limit_pct = 5 WHERE contract_id=v_con_d;
    DELETE FROM contract_document_terms WHERE sales_order_id=v_so_d;
    UPDATE sales_orders SET contract_id=NULL WHERE id=v_so_d;
    PERFORM link_document_to_contract('sales_order', v_so_d, v_con_d);
    IF (sale_settlement_compute(v_so_d, v_ob, v_a_cp)->>'amount_usd')::numeric <= 0 THEN
        RAISE EXCEPTION 'FIXTURE 149D 失败:差距 2%% 在 5%% 的容差之内,应当结算得出'; END IF;
    -- 容差收紧到差距之下 → 拒,并指向仲裁
    UPDATE contract_settlement_terms SET splitting_limit_pct = 1 WHERE contract_id=v_con_d;
    DELETE FROM contract_document_terms WHERE sales_order_id=v_so_d;
    UPDATE sales_orders SET contract_id=NULL WHERE id=v_so_d;
    PERFORM link_document_to_contract('sales_order', v_so_d, v_con_d);
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM sale_settlement_compute(v_so_d, v_ob, v_a_cp);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'RESULTS_EXCEED_SPLITTING_LIMIT|%' THEN
        RAISE EXCEPTION 'FIXTURE 149D 失败:差距超过声明的容差,应当按名拒并指向仲裁,实得 %', COALESCE(v_msg,'(算出来了)'); END IF;
    -- ★ 仲裁结果是【第三行】,不是对任何一方那一行的编辑 ★
    INSERT INTO assay_results (code, output_batch_id, assay_date, is_final,
                               weight_basis, moisture_pct, result_party, lab_name)
    VALUES ('ZZ149-AS-UMP', v_ob, DATE '2026-09-15', true, 'dry', 10, 'umpire', 'ZZ149-UMP')
    RETURNING id INTO v_a_ump;
    INSERT INTO assay_result_metals (assay_result_id, metal, content_pct)
    VALUES (v_a_ump,'ni',19), (v_a_ump,'cu',2.5);
    IF (SELECT count(*) FROM assay_results WHERE output_batch_id=v_ob AND deleted_at IS NULL) <> 3 THEN
        RAISE EXCEPTION 'FIXTURE 149D 失败:同一批货应当有【三行】化验(我方/对方/仲裁),而不是被互相覆盖'; END IF;
    IF (SELECT count(*) FROM assay_results WHERE output_batch_id=v_ob AND superseded_by IS NOT NULL) <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 149D 失败:三方结果之间【不许】用 supersession 表示 —— F6 明说那会销毁我们自己的数'; END IF;
    -- 仲裁结果总是可结算,即便它不是合同约定的那一方
    IF (sale_settlement_compute(v_so_d, v_ob, v_a_ump)->>'settling_party_used') <> 'umpire' THEN
        RAISE EXCEPTION 'FIXTURE 149D 失败:仲裁结果应当可以结算,并被记成 umpire'; END IF;

    -- ══════════ F. 结算记录不可改 ═══════════════════════════════════════════
    v_denied := false;
    BEGIN UPDATE sales_settlements SET amount_usd = 1 WHERE id = v_sid;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'SETTLEMENT_IMMUTABLE|update%' THEN
        RAISE EXCEPTION 'FIXTURE 149F 失败:结算记录的金额被就地改掉了 —— 那会毁掉"当初要的是什么"'; END IF;
    v_denied := false;
    BEGIN DELETE FROM sales_settlements WHERE id = v_sid;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'SETTLEMENT_IMMUTABLE|delete%' THEN
        RAISE EXCEPTION 'FIXTURE 149F 失败:结算记录被删掉了'; END IF;
    -- 【而 superseded_by 动得了 —— 否则"改正的办法是再写一行"就是一句空话】
    UPDATE sales_settlements SET superseded_by = v_sid WHERE id = v_sid AND false;  -- 不自指
    v_r2 := record_sale_settlement(v_so_w, v_ob, v_a_ump);
    UPDATE sales_settlements SET superseded_by = (v_r2->>'settlement_id')::uuid WHERE id = v_sid;
    IF (SELECT superseded_by FROM sales_settlements WHERE id=v_sid) IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 149F 失败:superseded_by 应当改得动 —— 否则改正的办法不存在'; END IF;

    -- ══════════ G. 权限【按名】拒,补回就放行 ═══════════════════════════════
    DELETE FROM role_permissions WHERE role_id=r_all AND permission_code='module.customers.edit';
    v_denied := false; v_msg := NULL;
    BEGIN
        EXECUTE 'SET LOCAL ROLE authenticated';
        PERFORM record_sale_settlement(v_so_np, v_ob, v_a_ours);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    EXECUTE 'RESET ROLE';
    IF NOT v_denied OR v_msg NOT LIKE 'SETTLEMENT_PERMISSION_DENIED|module.customers.edit%' THEN
        RAISE EXCEPTION 'FIXTURE 149G 失败:definer 那一支没有权限检查 —— 而那正是本仓库点名过的陷阱。实得 %', COALESCE(v_msg,'(写进去了)'); END IF;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_all,'module.customers.edit');

    -- ══════════ H. 目录事实(不 grep 源码)══════════════════════════════════
    SELECT count(*) INTO v_n FROM information_schema.columns
     WHERE table_schema='public' AND table_name='sales_settlements'
       AND column_name IN ('assay_result_id','weight_basis_used','settling_party_used','terms_snapshot');
    IF v_n <> 4 THEN
        RAISE EXCEPTION 'FIXTURE 149H 失败:sales_settlements 应当有那四列,实得 % —— 下面那句"它不过账"会是一句空话', v_n; END IF;
    -- ★ 刻意的缺席:它【不过账】,所以没有任何一列指向分录 ★
    SELECT count(*) INTO v_n FROM information_schema.columns
     WHERE table_schema='public' AND table_name='sales_settlements'
       AND column_name ~* 'journal|entry_id|posted_at|ledger';
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 149H 失败:结算表上出现了指向总账的列(% 条)—— 本刀刻意不过账(会计政策 5.7 标着 NOT BUILT)', v_n; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname='trg_sales_settlements_immutable'
                     AND tgrelid='public.sales_settlements'::regclass AND NOT tgisinternal) THEN
        RAISE EXCEPTION 'FIXTURE 149H 失败:不可改那道守卫不在目录里'; END IF;
    SELECT count(*) INTO v_n FROM pg_class
     WHERE oid IN ('public.contract_settlement_terms'::regclass,'public.contract_refining_charges'::regclass,
                   'public.contract_penalty_elements'::regclass,'public.sales_settlements'::regclass)
       AND NOT relrowsecurity;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 149H 失败:% 张新表没有开 RLS', v_n; END IF;

    -- ══════════ I. 抄不是引用 ═══════════════════════════════════════════════
    SELECT settlement_terms INTO v_before FROM contract_document_terms WHERE sales_order_id=v_so_w;
    IF v_before IS NULL OR v_before='{}'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 149I 失败:抄件是空的 —— 下面那句比对会是一句空话'; END IF;
    UPDATE contract_settlement_terms SET sale_weight_basis='dry', refining_charge_basis='none_agreed'
     WHERE contract_id=v_con_w;
    UPDATE contract_refining_charges SET usd_per_tonne_of_metal=9999 WHERE contract_id=v_con_w;
    SELECT settlement_terms INTO v_after FROM contract_document_terms WHERE sales_order_id=v_so_w;
    IF v_before IS DISTINCT FROM v_after THEN
        RAISE EXCEPTION 'FIXTURE 149I 失败:★ 改了合同之后,已挂单据抄下的结算口径变了 ★'; END IF;
    IF (SELECT sale_weight_basis FROM contract_settlement_terms WHERE contract_id=v_con_w) <> 'dry' THEN
        RAISE EXCEPTION 'FIXTURE 149I 失败:合同没有被改动 —— 这一臂因此证明不了任何事'; END IF;

    -- ══════════ 故障注入(陷阱 e)════════════════════════════════════════════
    -- 短路掉"化验必须声明重量基准"那条拒绝,断言 A 臂当场瞎掉。
    v_inj := replace(def_c, 'IF v_assay.weight_basis IS NULL THEN
        RAISE EXCEPTION ''ASSAY_WEIGHT_BASIS_NOT_STATED', 'IF false THEN
        RAISE EXCEPTION ''ASSAY_WEIGHT_BASIS_NOT_STATED');
    IF v_inj = def_c THEN
        RAISE EXCEPTION 'FIXTURE 149 注入 失败:没找到重量基准那条拒绝 —— 这个注入什么也没删'; END IF;
    -- 【拿【仲裁】那一份来注入,而这个选择本身有理由】
    --   前两版分别指向 so_np 与"我方"化验,而两次都拒在【别的规矩】上
    --   (一次是 REFINING_CHARGE_NOT_FILED,一次是 RESULTS_IN_DISPUTE)——
    --   B 臂与 D 臂已经把那两份合同/化验改成会拒的样子了。
    --   **一个在别处也会拒的场景,证明不了这条拒绝有没有被短路。**
    --   仲裁那一份【绕开对手方与争议两条规矩】,所以剩下的唯一变量就是重量基准。
    --
    -- ① 先在基准【声明着】的时候取一个正确答案,而不是把它写死在这里 ——
    --    写死的数字会在别的臂动了数据之后变成一次假红。
    v_amt_d := (sale_settlement_compute(v_so_w, v_ob, v_a_ump)->>'amount_usd')::numeric;
    IF v_amt_d <= 0 THEN
        RAISE EXCEPTION 'FIXTURE 149 注入 失败:基线本身就算不出正金额,后面的比较没有意义'; END IF;

    -- ② 短路掉那条拒绝
    EXECUTE v_inj;
    UPDATE assay_results SET weight_basis = NULL WHERE id = v_a_ump;
    v_denied := false; v_msg := NULL;
    BEGIN v_r := sale_settlement_compute(v_so_w, v_ob, v_a_ump);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 149 注入 失败:短路掉那条拒绝之后它仍然拒(%)—— 说明这一臂守的不是我以为的那件事', v_msg; END IF;
    -- ③ ★ 而且它算出来的是一个【错的】数字,不是"碰巧还对" ★
    --    基准不声明时换算落到 ELSE 分支,含量被当成湿基往干基折(÷0.9),
    --    于是含金属被**高估** —— 正是 GO-3 点名的那个钱的错误。
    IF (v_r->>'amount_usd')::numeric = v_amt_d THEN
        RAISE EXCEPTION 'FIXTURE 149 注入 失败:短路之后算出的仍是正确答案(%)—— 那这条拒绝守的东西没有被证明', v_amt_d; END IF;
    IF (v_r->>'amount_usd')::numeric <= v_amt_d THEN
        RAISE EXCEPTION 'FIXTURE 149 注入 失败:不声明基准应当把含金属【高估】,实得 % 不大于正确答案 %',
            v_r->>'amount_usd', v_amt_d; END IF;

    -- ④ 放回去,而且必须又拒 —— 否则"放回去了"只是一句话
    EXECUTE def_c;
    v_denied := false;
    BEGIN PERFORM sale_settlement_compute(v_so_w, v_ob, v_a_ump);
    EXCEPTION WHEN OTHERS THEN v_denied := true; END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 149 注入 失败:恢复定义之后应当又按名拒'; END IF;
END $$;
ROLLBACK;
