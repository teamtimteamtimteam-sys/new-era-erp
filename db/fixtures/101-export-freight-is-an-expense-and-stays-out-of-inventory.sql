-- 101 出口运费是【费用】,而且【进不去】存货、进不去材料成本、进不去毛利
--
-- 【这份 fixture 的形状由 LOG-3-SURVEY §3 决定】那份勘察点名了三个陷阱 ——
-- 不是三种"可能出错",是三条【已经铺好、形状恰好接得上】的路径。
-- 每一条在这里有一臂,而且每一臂都断言【那件事没有发生】,不只是断言正确的事发生了。
--
-- 【为什么"断言缺席"是本文件的主要手法】一个把出口运费借进 1200 的实现,
-- 会同时产生一条完全正确的 6300 之外的行 —— 分录照样平、照样不报错。
-- 只断言"有一条 6300 借方"的臂,对它【全绿】。所以 A 臂断言的是
-- 【1200 与 5000 两行都不存在】。资本化的错误藏在存货里,断言也得往那里看。
--
-- 【A 臂】出口运费的分录:借 6300 + 贷方一条,而且【没有】1200、【没有】5000。
-- 【B 臂】batch_freight_base 在出境单据前后【完全相同】—— 而且前值【非零】,
--         否则这一臂是空转:0 = 0 对任何实现都成立。
-- 【C 臂】batch_margin 那一行(单位成本 / 当期成本 / 已过账 COGS / 毛利 / 毛利率)
--         在出境单据前后逐列相同。经【视图】读,不是查科目表 ——
--         "6300 的 account_type 不是 cogs" 是一句关于 chart 的话,
--         而要证的是那个数没动。
--         【这一臂的判别力有边界,写在这里而不是留给人以为它管得更宽】:
--         cogs_posted_base 只汇总【那张销售记录自己的 cogs_entry_id】所指分录里的
--         cogs 行。所以它抓得住"把出口运费挂进那笔销售的 COGS 分录"这一种错,
--         抓不住"另发一张分录借 5000" —— 后者由 A 臂抓。两臂互补,不互相蕴含。
-- 【D 臂】给出境单据挂分摊行 → 按名拒。用【直插】测,不是靠"RPC 没提供那条路":
--         RPC 不提供只是没铺路,守卫才是墙,而这套系统里直插是真实存在的一条路。
-- 【E 臂】非货代对手方按名拒;指向已软删箱子按名拒。
-- 【F 臂】冲销:原分录 + 冲销分录在总账里净额归零;账龄里那一行消失;理由与经手人
--         留痕;而【直接 UPDATE status 被按名拒】—— 冲销从此不是手改得到的。
-- 【G 臂】PAY-FRT 那条核销路径对出境单据【原样成立】(断言,不假设)。
-- 【H 臂】出境单据在 ap_open_items 的运费支里与进境单据【形状相同】(第 2(f) 条)。
--
-- 日期落在 2027,自带数据(README 第 2/4/5 条)。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all  uuid;
    v_ccy  text; v_bank text;
    v_fwd uuid; v_sup uuid; v_mat uuid; v_cust uuid;
    v_p1 uuid; v_p2 uuid; v_lane uuid; v_ctr uuid; v_ctr_code text; v_ctr_dead uuid;
    v_so uuid; v_ship uuid;
    v_ib uuid; v_ob uuid; v_run uuid; v_sr uuid; v_je_cogs uuid;
    v_res jsonb; v_msg text; v_denied boolean;
    v_fd_in uuid; v_fd_out uuid; v_fd_rev uuid; v_fd_pay uuid;
    v_je_out uuid;
    v_n int; v_v numeric;
    v_base_before numeric; v_base_after numeric;
    v_m_before record; v_m_after record;
    v_net numeric; v_open numeric;
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    v_bank := bank_account_for_currency(v_ccy);
    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-101', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_all, code FROM permissions;          -- 自建角色、全部权限(README 权限一节)
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZFIX101-MAT', 'fixture 101 material supplier', 'SG', 'active', 'goods_supplier')
    RETURNING id INTO v_sup;
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZFIX101-FWD', 'fixture 101 forwarder', 'SG', 'active', 'forwarder')
    RETURNING id INTO v_fwd;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZFIX101-M', 'fixture 101 material', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO v_mat;
    INSERT INTO customers (code, legal_name, country)
    VALUES ('ZZFIX101-C', 'fixture 101 customer', 'SG') RETURNING id INTO v_cust;

    -- ── 航段与箱子(走 create_container 那扇门,号段因此是真的)────────────────
    INSERT INTO ports (code, name, country) VALUES ('ZZF101A', 'fixture 101 origin', 'SG')
    RETURNING id INTO v_p1;
    INSERT INTO ports (code, name, country) VALUES ('ZZF101B', 'fixture 101 destination', 'CN')
    RETURNING id INTO v_p2;
    INSERT INTO lanes (origin_port_id, destination_port_id) VALUES (v_p1, v_p2)
    RETURNING id INTO v_lane;
    v_res := create_container(v_lane, DATE '2027-06-01', 'ZZFIX101U0000001', NULL, NULL, v_fwd, NULL, NULL);
    v_ctr := (v_res->>'id')::uuid; v_ctr_code := v_res->>'code';

    -- ── 出货链:销售订单 → 发货单 → 挂在那个箱子上 ───────────────────────────
    -- B 臂要的是"出境单据【确实】连着那批货的箱子",否则"没变"是因为根本没关系。
    INSERT INTO sales_orders (code, customer_id, order_date, status, currency, fx_rate)
    VALUES ('ZZFIX101-SO', v_cust, DATE '2027-05-20', 'confirmed', v_ccy, 1) RETURNING id INTO v_so;
    INSERT INTO shipments (code, sales_order_id, ship_date, container_id)
    VALUES ('ZZFIX101-SHP', v_so, DATE '2027-06-01', v_ctr) RETURNING id INTO v_ship;

    -- ── 进料批 + 一张【进货】运费单 → batch_freight_base 非零 ────────────────
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty,
        arrival_date, unit_price)
    VALUES ('ZZFIX101-IB', v_mat, v_sup, 100, 100, DATE '2027-05-01', 10) RETURNING id INTO v_ib;
    v_res := record_freight_document(DATE '2027-05-05', v_fwd, 700, v_ccy, 'weight',
        'unpaid', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib)),
        'fixture 101 inbound leg', NULL);
    v_fd_in := (v_res->>'freight_document_id')::uuid;

    v_base_before := batch_freight_base(v_ib);
    IF v_base_before <> 700 THEN
        RAISE EXCEPTION 'FIXTURE 101 前提失败:进货运费应让 batch_freight_base = 700,实得 % —— B 臂若从 0 开始就是空转(0 = 0 对任何实现都成立)',
            v_base_before;
    END IF;

    -- ── 产出批 + 已过账 COGS → batch_margin 有一行可读 ───────────────────────
    INSERT INTO processing_runs (code, status, allocated_at, allocation_basis)
    VALUES ('ZZFIX101-RUN', 'committed', '2027-05-10', 'metal_value') RETURNING id INTO v_run;
    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, output_date)
    VALUES ('ZZFIX101-OB', v_mat, 100, 100, '2027-05-10') RETURNING id INTO v_ob;
    INSERT INTO processing_outputs (run_id, output_batch_id, quantity_produced,
        allocated_cost_base, unit_cost_base, cost_incomplete)
    VALUES (v_run, v_ob, 100, 400, 4, false);
    INSERT INTO sales_records (output_batch_id, customer_id, quantity, unit_price,
        currency, fx_rate, amount_base, sale_date)
    VALUES (v_ob, v_cust, 100, 20, v_ccy, 1, 2000, '2027-05-15') RETURNING id INTO v_sr;
    INSERT INTO journal_entries (code, entry_date, memo, source_type)
    VALUES ('ZZFIX101-COGS', '2027-05-15', 'fixture 101 cogs at sale', 'sale') RETURNING id INTO v_je_cogs;
    INSERT INTO journal_lines (entry_id, account_id, debit, credit, currency, amount_ccy, fx_rate)
    SELECT v_je_cogs, a.id, x.d, x.c, v_ccy, 400, 1
    FROM (VALUES ('5000', 400.0, 0.0), ('1220', 0.0, 400.0)) x(code, d, c)
    JOIN accounts a ON a.code = x.code;
    UPDATE sales_records SET cogs_entry_id = v_je_cogs WHERE id = v_sr;

    SELECT unit_cost_base, cost_current_base, cogs_posted_base, margin_base, margin_pct
      INTO v_m_before FROM batch_margin WHERE output_batch_id = v_ob;
    IF v_m_before.cogs_posted_base IS DISTINCT FROM 400 THEN
        RAISE EXCEPTION 'FIXTURE 101 前提失败:batch_margin 的已过账 COGS 应为 400,实得 % —— C 臂需要一个非空的起点',
            COALESCE(v_m_before.cogs_posted_base::text, 'NULL');
    END IF;

    -- ══════════ A. 出口运费的分录 —— 借 6300,而且【没有】1200、【没有】5000 ══
    v_res := record_export_freight_document(DATE '2027-06-05', v_fwd, 1200, v_ccy,
        'unpaid', NULL, v_ctr, 'fixture 101 export leg');
    v_fd_out := (v_res->>'freight_document_id')::uuid;
    v_je_out := (v_res->>'entry_id')::uuid;

    IF (SELECT direction FROM freight_documents WHERE id = v_fd_out) <> 'outbound' THEN
        RAISE EXCEPTION 'FIXTURE 101A 失败:这张单的 direction 应是 outbound';
    END IF;
    -- ── 【断言缺席】先于断言存在 ────────────────────────────────────────
    -- 顺序是有意的:一个把出口运费借进 1200 的实现,可能【同时】留着一条正确的
    -- 6300 行(分录照样平)。那种实现只有缺席这一条抓得住,所以它先跑 ——
    -- 否则注入时先红的永远是"6300 不见了",而缺席这一条从未被证明是承重的。
    SELECT count(*) INTO v_n FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id
     WHERE jl.entry_id = v_je_out AND a.code IN ('1200','5000');
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 101A 失败(陷阱 A):出口运费的分录里出现了 % 条 1200/5000 行 —— 借方写死 1200/5000 是 record_freight_document 的路径,出境臂一步都不该走上去;分录照样是平的,而钱藏进了存货',
            v_n;
    END IF;
    -- 借方恰好一条,而且是 6300
    SELECT count(*) INTO v_n FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id
     WHERE jl.entry_id = v_je_out AND a.code = '6300' AND jl.debit = 1200;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 101A 失败:出口运费应借 6300 恰 1,200,实得 % 行', v_n;
    END IF;
    -- 贷方:未付 → 2000,记在货代名下
    SELECT count(*) INTO v_n FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id
     WHERE jl.entry_id = v_je_out AND a.code = '2000' AND jl.credit = 1200;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 101A 失败:未付出口运费应贷 2000 恰 1,200,实得 % 行', v_n;
    END IF;
    -- 整张分录只有两行 —— 多出来的任何一行都是没被预料到的东西
    SELECT count(*) INTO v_n FROM journal_lines WHERE entry_id = v_je_out;
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 101A 失败:出口运费的分录应恰好两行,实得 % 行', v_n;
    END IF;

    -- ══════════ B. 陷阱 B:材料成本一分不动 ═════════════════════════════════
    v_base_after := batch_freight_base(v_ib);
    IF v_base_after IS DISTINCT FROM v_base_before THEN
        RAISE EXCEPTION 'FIXTURE 101B 失败(陷阱 B):出境单据前后 batch_freight_base 应完全相同(% → %)—— 它一旦变了,allocate_processing_costs 就会把出口运费加进材料成本,穿过加工单进入产出批的单位成本,再抬高【别的订单】的成本',
            v_base_before, v_base_after;
    END IF;
    -- 而且这张出境单据确实【连着】那批货的箱子 —— 否则"没变"只是因为毫无关系
    SELECT count(*) INTO v_n
      FROM freight_documents fd JOIN containers c ON c.id = fd.container_id
      JOIN shipments s ON s.container_id = c.id
     WHERE fd.id = v_fd_out AND s.id = v_ship;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 101B 失败:这一臂要求出境单据经箱子连到那张发货单,实得 % —— 连不上的话"没变"证明不了任何事',
            v_n;
    END IF;

    -- ══════════ C. 陷阱 C:毛利那一行逐列不动(经【视图】读)═════════════════
    SELECT unit_cost_base, cost_current_base, cogs_posted_base, margin_base, margin_pct
      INTO v_m_after FROM batch_margin WHERE output_batch_id = v_ob;
    IF v_m_after IS DISTINCT FROM v_m_before THEN
        RAISE EXCEPTION 'FIXTURE 101C 失败(陷阱 C):出境单据前后 batch_margin 应逐列相同,前 % 后 % —— 6300 落在 expense 而不是 cogs,这个数因此不该动',
            v_m_before::text, v_m_after::text;
    END IF;

    -- ══════════ D. 出境单据【不许有分摊行】—— 直插测,守卫才是墙 ═════════════
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO freight_allocations (freight_document_id, inbound_batch_id,
                                         amount_base, basis_qty, in_stock_ratio)
        VALUES (v_fd_out, v_ib, 100, 100, 1);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR v_msg NOT LIKE 'EXPORT_FREIGHT_HAS_NO_ALLOCATIONS|%' THEN
        RAISE EXCEPTION 'FIXTURE 101D 失败:给出境单据直插分摊行应按名拒 EXPORT_FREIGHT_HAS_NO_ALLOCATIONS,实得 denied=% msg=% —— "RPC 不提供这条路"只是没铺路,而直插是这套系统里真实存在的一条路(containers 那条 code 里装着错误负载的行就是直插留下的)',
            v_denied, COALESCE(v_msg, '(收下了)');
    END IF;
    -- 进境单据的分摊行【照旧可以有】—— 守卫只挡出境,不是把这条路封死
    SELECT count(*) INTO v_n FROM freight_allocations WHERE freight_document_id = v_fd_in;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 101D 失败:进境单据应仍有 1 条分摊行,实得 % —— 守卫写宽了就把进料侧一起挡住了', v_n;
    END IF;

    -- ══════════ E. 对手方与箱子的两条具名拒绝 ═══════════════════════════════
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM record_export_freight_document(DATE '2027-06-06', v_sup, 100, v_ccy,
            'unpaid', NULL, NULL, 'fixture 101 non-forwarder');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR v_msg NOT LIKE 'FREIGHT_SUPPLIER_NOT_A_FORWARDER|%' THEN
        RAISE EXCEPTION 'FIXTURE 101E 失败:非货代对手方应按名拒 FREIGHT_SUPPLIER_NOT_A_FORWARDER,实得 denied=% msg=%',
            v_denied, COALESCE(v_msg, '(收下了)');
    END IF;
    -- 同一条守卫对【进境】单据一样成立(FRT-1 与 LOG-1a 之间的时间差,两侧一起关)
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM record_freight_document(DATE '2027-06-06', v_sup, 100, v_ccy, 'weight',
            'unpaid', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib)),
            'fixture 101 non-forwarder inbound', NULL);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR v_msg NOT LIKE 'FREIGHT_SUPPLIER_NOT_A_FORWARDER|%' THEN
        RAISE EXCEPTION 'FIXTURE 101E 失败:进境单据的非货代对手方也应按名拒,实得 denied=% msg=%',
            v_denied, COALESCE(v_msg, '(收下了)');
    END IF;

    v_res := create_container(v_lane, DATE '2027-06-02', 'ZZFIX101U0000002', NULL, NULL, v_fwd, NULL, NULL);
    v_ctr_dead := (v_res->>'id')::uuid;
    PERFORM soft_delete_container(v_ctr_dead, 'fixture 101:注销用');
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM record_export_freight_document(DATE '2027-06-07', v_fwd, 100, v_ccy,
            'unpaid', NULL, v_ctr_dead, 'fixture 101 dead container');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR v_msg NOT LIKE 'EXPORT_FREIGHT_CONTAINER_NOT_FOUND|%' THEN
        RAISE EXCEPTION 'FIXTURE 101E 失败:指向已软删箱子应按名拒 EXPORT_FREIGHT_CONTAINER_NOT_FOUND,实得 denied=% msg=% —— 一个查不回去的出处比没有出处更坏',
            v_denied, COALESCE(v_msg, '(收下了)');
    END IF;
    -- 【不指箱子是允许的】—— 单据才是钱的对象(Tim 定)。这一条要断言,
    -- 否则一个"container_id 必填"的实现照样通过上面每一条。
    v_res := record_export_freight_document(DATE '2027-06-08', v_fwd, 300, v_ccy,
        'unpaid', NULL, NULL, 'fixture 101 no container');
    IF (SELECT container_id FROM freight_documents WHERE id = (v_res->>'freight_document_id')::uuid) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 101E 失败:不指箱子的出境单据不该被塞一个箱子进去';
    END IF;

    -- ══════════ H. 账龄:出境单据与进境单据形状相同(第 2(f) 条,断言不假设)══
    SELECT open_base INTO v_open FROM ap_open_items
     WHERE doc_kind = 'freight' AND doc_id = v_fd_out;
    IF v_open IS DISTINCT FROM 1200 THEN
        RAISE EXCEPTION 'FIXTURE 101H 失败:未付出口运费应作为一张【货代】名下的应付出现在账龄里(1,200),实得 % —— 运费支不看 direction,这一条必须实测',
            COALESCE(v_open::text, '(没有这一行)');
    END IF;
    SELECT count(*) INTO v_n FROM ap_open_items
     WHERE doc_kind = 'freight' AND doc_id = v_fd_out
       AND supplier_id = v_fwd AND counterparty_kind = 'supplier' AND inbound_batch_id IS NULL;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 101H 失败:出境行应与进境行同形(货代、supplier、inbound_batch_id 为空),实得 % 行', v_n;
    END IF;

    -- ══════════ G. PAY-FRT 那条核销路径对出境单据原样成立 ════════════════════
    v_res := record_export_freight_document(DATE '2027-06-09', v_fwd, 500, v_ccy,
        'unpaid', NULL, v_ctr, 'fixture 101 settle me');
    v_fd_pay := (v_res->>'freight_document_id')::uuid;
    PERFORM record_payment('out', v_fwd, 200, v_ccy, NULL, v_bank, DATE '2027-06-10',
        'fixture 101 partial',
        jsonb_build_array(jsonb_build_object('freight_document_id', v_fd_pay, 'amount_doc', 200)),
        'supplier');
    SELECT open_base INTO v_open FROM ap_open_items WHERE doc_kind = 'freight' AND doc_id = v_fd_pay;
    IF v_open IS DISTINCT FROM 300 THEN
        RAISE EXCEPTION 'FIXTURE 101G 失败:出境单据付掉 200 后敞口应为 300,实得 %',
            COALESCE(v_open::text, '(没有这一行)');
    END IF;
    PERFORM record_payment('out', v_fwd, 300, v_ccy, NULL, v_bank, DATE '2027-06-11',
        'fixture 101 settle',
        jsonb_build_array(jsonb_build_object('freight_document_id', v_fd_pay, 'amount_doc', 300)),
        'supplier');
    SELECT count(*) INTO v_n FROM ap_open_items WHERE doc_kind = 'freight' AND doc_id = v_fd_pay;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 101G 失败:付清之后账龄里不该还有这一行,实得 % 行', v_n;
    END IF;

    -- ══════════ F. 冲销 ═════════════════════════════════════════════════════
    -- F1 直接 UPDATE status 按名拒 —— 冲销从此不是手改得到的
    v_denied := false; v_msg := NULL;
    BEGIN
        UPDATE freight_documents SET status = 'reversed' WHERE id = v_fd_out;
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR v_msg NOT LIKE 'FREIGHT_STATUS_NO_DIRECT_UPDATE|%' THEN
        RAISE EXCEPTION 'FIXTURE 101F 失败:直接 UPDATE status 应按名拒 FREIGHT_STATUS_NO_DIRECT_UPDATE,实得 denied=% msg=% —— 手改得到的状态意味着一次没有分录、没有理由、没有人的冲销',
            v_denied, COALESCE(v_msg, '(收下了)');
    END IF;

    -- F2 理由必填
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM reverse_freight_document(v_fd_out, '   ');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR v_msg NOT LIKE 'FREIGHT_REVERSAL_REASON_REQUIRED|%' THEN
        RAISE EXCEPTION 'FIXTURE 101F 失败:空白理由应按名拒 FREIGHT_REVERSAL_REASON_REQUIRED,实得 denied=% msg=%',
            v_denied, COALESCE(v_msg, '(收下了)');
    END IF;

    -- F3 已被结清的单据不许冲销(冲掉它会让一笔真付过的钱挂在"不欠任何人"的单据上)
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM reverse_freight_document(v_fd_pay, 'fixture 101:试图冲销已结清的');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR v_msg NOT LIKE 'FREIGHT_HAS_SETTLEMENT|%' THEN
        RAISE EXCEPTION 'FIXTURE 101F 失败:已结清的单据应按名拒 FREIGHT_HAS_SETTLEMENT,实得 denied=% msg=%',
            v_denied, COALESCE(v_msg, '(收下了)');
    END IF;

    -- F4 正路:净额归零 + 账龄消失 + 留痕
    v_res := reverse_freight_document(v_fd_out, 'fixture 101:货代开错了船名');
    v_fd_rev := (v_res->>'reversal_entry_id')::uuid;

    -- 【净额归零要按科目逐个看】只看总额,一个"冲了但冲到别的科目"的实现照样是零
    SELECT COALESCE(SUM(jl.debit - jl.credit), 0) INTO v_net
      FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id
     WHERE jl.entry_id IN (v_je_out, v_fd_rev) AND a.code = '6300';
    IF v_net <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 101F 失败:原分录与冲销分录在 6300 上应净额归零,实得 %', v_net;
    END IF;
    SELECT COALESCE(SUM(jl.credit - jl.debit), 0) INTO v_net
      FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id
     WHERE jl.entry_id IN (v_je_out, v_fd_rev) AND a.code = '2000';
    IF v_net <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 101F 失败:原分录与冲销分录在 2000 上应净额归零,实得 %', v_net;
    END IF;

    SELECT count(*) INTO v_n FROM ap_open_items WHERE doc_kind = 'freight' AND doc_id = v_fd_out;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 101F 失败:冲销之后账龄里不该还有这一行,实得 % 行 —— 一张被冲销的单据不欠任何人钱', v_n;
    END IF;

    SELECT count(*) INTO v_n FROM freight_documents
     WHERE id = v_fd_out AND status = 'reversed' AND reversed_by = v_user
       AND reversal_reason = 'fixture 101:货代开错了船名' AND reversed_at IS NOT NULL
       AND reversal_entry_id = v_fd_rev;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 101F 失败:冲销要留下【谁、为什么、哪一张冲销分录】,实得 % 行满足', v_n;
    END IF;

    -- F5 冲销是【一次性】的
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM reverse_freight_document(v_fd_out, 'fixture 101:再冲一次');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR v_msg NOT LIKE 'FREIGHT_ALREADY_REVERSED|%' THEN
        RAISE EXCEPTION 'FIXTURE 101F 失败:重复冲销应按名拒 FREIGHT_ALREADY_REVERSED,实得 denied=% msg=%',
            v_denied, COALESCE(v_msg, '(收下了)');
    END IF;

    -- F6 【进境单据同样冲得掉】—— 一条门,两个方向;镜像的是原分录,所以
    --    进料侧自动冲掉 1200/5000,这个函数一个科目码都不需要知道。
    v_res := reverse_freight_document(v_fd_in, 'fixture 101:进货运费也要冲得掉');
    SELECT COALESCE(SUM(jl.debit - jl.credit), 0) INTO v_net
      FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id
     WHERE jl.entry_id IN ((SELECT journal_entry_id FROM freight_documents WHERE id = v_fd_in),
                           (v_res->>'reversal_entry_id')::uuid)
       AND a.code IN ('1200','5000');
    IF v_net <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 101F 失败:进境单据冲销后 1200/5000 应净额归零,实得 %', v_net;
    END IF;
    -- 冲销之后 batch_freight_base 归零(status <> 'posted' 的单据不计)
    IF batch_freight_base(v_ib) <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 101F 失败:冲销进货运费后 batch_freight_base 应回到 0,实得 %',
            batch_freight_base(v_ib);
    END IF;

    -- ══════════ E'(补). 箱号形状 —— 那条装着错误负载的 code 的教训 ══════════
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO containers (code, lane_id, departure_date)
        VALUES ('{"code":"42501","message":"permission denied for function next_container_code"}',
                v_lane, DATE '2027-06-01');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR v_msg NOT LIKE '%containers_code_format%' THEN
        RAISE EXCEPTION 'FIXTURE 101 失败:把一段错误负载当箱号直插应被 containers_code_format 挡下,实得 denied=% msg=% —— 线上真有这样一行,而它是直插留下的',
            v_denied, COALESCE(v_msg, '(收下了)');
    END IF;
    -- 形状正确的号照样进得去(CHECK 写宽了或写死了,这一条会红)
    INSERT INTO containers (code, lane_id, departure_date)
    VALUES ('CTR-2027-9999', v_lane, DATE '2027-06-01');
END $$;
ROLLBACK;
