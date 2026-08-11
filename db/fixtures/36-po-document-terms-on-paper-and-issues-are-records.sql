-- 36 采购单单据:条款印在纸上、签发是档案不是视图、单据币种之外什么都不带
--
-- 【为什么值得常设(PUR-1)】供应商手里那份纸与数据库里的承诺必须是同一件事。
-- 三处最容易坏而且坏了不响:
--   * 逐行定价状态的裁决(po_document_data)—— 把"公式挂着但条款没抄下来"印成
--     公式今天的条款,就是替 FIN-27 专门防止的那种编造背书;
--   * 签发档被覆盖 —— 供应商手里那份是某个具体版本,重签发必须是【新的一行】;
--   * 本位币数字漏进单据 —— 内部口径上了对外的纸(D 部分)。
--
-- 【单据数据在 SQL 里推导正是为了这份 fixture】PDF 是 TSX,fixture 够不着;
-- 但 PDF 与本 fixture 读的是【同一个】po_document_data —— 钉住它就钉住了纸上说什么。
-- (与 fixture 27 钉 current_user_permissions 而不钉导航条是同一个格局。)
BEGIN;
DO $$
DECLARE
    u uuid := gen_random_uuid();
    r uuid;
    v_sup uuid; v_mat uuid; v_base text;
    v_formula uuid;
    v_po uuid; v_res jsonb; v_doc jsonb;
    v_line jsonb;
    v_issue jsonb;
    v_n int; v_denied boolean; v_msg text;
    v_sha text := repeat('a', 64);
    v_line_id uuid;
BEGIN
    SELECT code INTO v_base FROM currencies WHERE is_base;
    UPDATE finance_settings SET locked_before = NULL;
    -- 审批保持默认【关】:本 fixture 测单据,不测审批流(那是 fixture 35)。
    -- 关着时新单生为 approved,签发门槛自然满足;C 臂再手动造一个 pending 来测拒绝。

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-36', 'f', 'f', true) RETURNING id INTO r;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r, unnest(ARRAY['module.purchasing.edit','module.purchasing.view',
                           'module.pricing.view','data.view_prices']);
    INSERT INTO user_roles (user_id, role_id) VALUES (u, r);

    INSERT INTO suppliers (code, legal_name, country, address, tax_id)
    VALUES ('ZZFIX36-S', 'fixture 36 supplier', 'SG', '1 Test Way', 'T36') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, category)
    VALUES ('ZZFIX36-M', 'fixture 36 material', 'other') RETURNING id INTO v_mat;

    -- 一张公式:spot、TC 120 USD/t、折扣 2.5%、Ni 应付 81%
    INSERT INTO pricing_formulas (code, name, direction, price_basis,
                                  treatment_charge_usd_per_tonne, flat_discount_pct)
    VALUES ('ZZFIX36-PF', 'fixture 36 formula', 'purchase', 'spot', 120, 2.5)
    RETURNING id INTO v_formula;
    INSERT INTO pricing_formula_metals (formula_id, metal, payable_pct)
    VALUES (v_formula, 'ni', 81);

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u), true);

    -- 三条线:公式行(手填估价 → FIN-26 的判别用例)、固定价行、无价无公式行
    v_res := create_purchase_order(v_sup, '2027-04-01'::date, '2027-05-01'::date, v_base, NULL,
        'DDP', 'fixture 36 terms text', NULL,
        jsonb_build_array(
            jsonb_build_object('line_no', 1, 'material_id', v_mat, 'quantity', 100,
                'estimated_unit_price', 7, 'pricing_formula_id', v_formula,
                'price_source', 'manual'),
            jsonb_build_object('line_no', 2, 'material_id', v_mat, 'quantity', 50,
                'estimated_unit_price', 3),
            jsonb_build_object('line_no', 3, 'material_id', v_mat, 'quantity', 10)
        ), NULL);
    v_po := (v_res->>'purchase_order_id')::uuid;

    v_doc := po_document_data(v_po);

    -- ══════════ A. 逐行定价状态,四种形状各归各位 ═══════════════════════════
    -- 行 1:公式 + 手填估价 → provisional_committed,条款【逐项】等于承诺副本,
    -- 且 price_is_manual_estimate = true(FIN-26 那次误读的终结:数字是手填的,
    -- 结算规则是公式 —— 纸上两件事都要说)
    SELECT x INTO v_line FROM jsonb_array_elements(v_doc->'lines') x WHERE (x->>'line_no')::int = 1;
    IF v_line->>'pricing_status' <> 'provisional_committed' THEN
        RAISE EXCEPTION 'FIXTURE 36A 失败:公式行应为 provisional_committed,实得 %', v_line->>'pricing_status';
    END IF;
    IF NOT (v_line->>'price_is_manual_estimate')::boolean THEN
        RAISE EXCEPTION 'FIXTURE 36A 失败:price_source=manual 的公式行应标 price_is_manual_estimate —— 不标的话,读者又会把手填的估算当成算出来的价(FIN-26 那次误读原样重演)';
    END IF;
    IF (v_line->'committed_terms'->>'treatment_charge_usd_per_tonne')::numeric <> 120
       OR (v_line->'committed_terms'->>'flat_discount_pct')::numeric <> 2.5
       OR v_line->'committed_terms'->>'price_basis' <> 'spot'
       OR v_line->'committed_terms'->>'source_formula_code' <> 'ZZFIX36-PF' THEN
        RAISE EXCEPTION 'FIXTURE 36A 失败:承诺条款没有逐项上纸,实得 %', v_line->'committed_terms';
    END IF;
    IF (SELECT (m->>'payable_pct')::numeric FROM jsonb_array_elements(v_line->'committed_terms'->'metals') m
         WHERE m->>'metal' = 'ni') <> 81 THEN
        RAISE EXCEPTION 'FIXTURE 36A 失败:逐金属应付比例(ni 81%%)没有上纸';
    END IF;

    -- 行 2:有价无公式 → fixed
    SELECT x INTO v_line FROM jsonb_array_elements(v_doc->'lines') x WHERE (x->>'line_no')::int = 2;
    IF v_line->>'pricing_status' <> 'fixed' OR v_line->'committed_terms' IS DISTINCT FROM 'null'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 36A 失败:固定价行应为 fixed 且不带条款块,实得 % / %',
            v_line->>'pricing_status', v_line->'committed_terms';
    END IF;

    -- 行 3:无价无公式 → not_priced(纸上印 PRICE NOT STATED,绝不印 0.00 —— 0 读作"免费")
    SELECT x INTO v_line FROM jsonb_array_elements(v_doc->'lines') x WHERE (x->>'line_no')::int = 3;
    IF v_line->>'pricing_status' <> 'not_priced' THEN
        RAISE EXCEPTION 'FIXTURE 36A 失败:无价无公式行应为 not_priced,实得 %', v_line->>'pricing_status';
    END IF;

    -- 公式挂着、条款没抄(FIN-27 之前的旧行形状,直插构造)→ provisional_uncommitted,
    -- 【不带条款块】—— 印公式今天的条款就是编造一份当时没做过的承诺
    INSERT INTO purchase_order_lines (purchase_order_id, line_no, material_id, quantity,
                                      unit, pricing_formula_id, estimated_amount_ccy)
    VALUES (v_po, 4, v_mat, 5, 'kg', v_formula, 0) RETURNING id INTO v_line_id;
    v_doc := po_document_data(v_po);
    SELECT x INTO v_line FROM jsonb_array_elements(v_doc->'lines') x WHERE (x->>'line_no')::int = 4;
    IF v_line->>'pricing_status' <> 'provisional_uncommitted'
       OR v_line->'committed_terms' IS DISTINCT FROM 'null'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 36A 失败:有公式无承诺的旧行应为 provisional_uncommitted 且【不带】条款块(印今天的条款 = 编造当时的承诺),实得 % / %',
            v_line->>'pricing_status', v_line->'committed_terms';
    END IF;

    -- ══════════ B. 单据币种之外什么都不带(D 部分)═══════════════════════════
    IF v_doc ? 'fx_rate' OR v_doc ? 'amount_base' OR v_doc ? 'estimated_total_base' THEN
        RAISE EXCEPTION 'FIXTURE 36B 失败:单据数据带上了内部口径(fx_rate / 本位币金额)—— 供应商的纸上只该有单据币种';
    END IF;
    IF v_doc->>'currency' <> v_base THEN
        RAISE EXCEPTION 'FIXTURE 36B 前置失败:本单币种应为 %', v_base;
    END IF;

    -- ══════════ C. 签发是档案:谁、何时、第几版;重签发是新行 ════════════════
    v_issue := record_po_issue(v_po, 'fixture/36-v1.pdf', v_sha);
    IF (v_issue->>'version')::int <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 36C 失败:首次签发应为 v1,实得 %', v_issue->>'version';
    END IF;
    IF (SELECT issued_by FROM po_issues WHERE purchase_order_id = v_po AND version = 1) IS DISTINCT FROM u THEN
        RAISE EXCEPTION 'FIXTURE 36C 失败:签发档没有记下【谁】签发的';
    END IF;
    IF (SELECT issued_at FROM po_issues WHERE purchase_order_id = v_po AND version = 1) IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 36C 失败:签发档没有记下【何时】';
    END IF;

    -- 数据变了之后重签发 → 【新的一行 v2】,v1 原样在(供应商手里那份就是 v1)
    UPDATE purchase_orders SET notes = 'amended after v1' WHERE id = v_po;
    v_issue := record_po_issue(v_po, 'fixture/36-v2.pdf', repeat('b', 64));
    IF (v_issue->>'version')::int <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 36C 失败:重签发应为 v2,实得 %', v_issue->>'version';
    END IF;
    SELECT count(*) INTO v_n FROM po_issues WHERE purchase_order_id = v_po;
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 36C 失败:两次签发应是【两行】,实得 % 行 —— 1 行意味着 v2 把 v1 覆盖了,而 v1 正是供应商手里那份', v_n;
    END IF;
    IF (SELECT file_path FROM po_issues WHERE purchase_order_id = v_po AND version = 1) <> 'fixture/36-v1.pdf' THEN
        RAISE EXCEPTION 'FIXTURE 36C 失败:v1 的对象键被改动了';
    END IF;

    -- 档案只增不改:UPDATE / DELETE 各自点名拒绝
    v_denied := false;
    BEGIN
        UPDATE po_issues SET sha256 = repeat('c', 64) WHERE purchase_order_id = v_po AND version = 1;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'PO_ISSUE_APPEND_ONLY|update%' THEN
            RAISE EXCEPTION 'FIXTURE 36C 失败:UPDATE 被拒但报的不是自己的名字:「%」', SQLERRM;
        END IF;
        v_denied := true;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 36C 失败:签发档被 UPDATE 成功 —— 能改写的档案证明不了供应商手里是什么';
    END IF;
    v_denied := false;
    BEGIN
        DELETE FROM po_issues WHERE purchase_order_id = v_po AND version = 1;
    EXCEPTION WHEN OTHERS THEN v_denied := true;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 36C 失败:签发档被 DELETE 成功';
    END IF;

    -- ══════════ D. 未获批的单不能签发 ═══════════════════════════════════════
    -- 发出去 = 在审批之前完成承诺 —— APR-2 A4 点名的缺口,动作存在了就要把关
    -- PUR-2:审批状态不再能经一条直连的 UPDATE 改动(guard_po_amendable)——
    -- 一个能把 approval_status 设成 approved 的路径就是一条不经审批的审批路径。
    -- 【本 fixture 是在【摆前提】而不是在走业务路径】:它要的是"一张待批的单",
    -- 而系统里没有"取消批准"这个动作。所以显式声明一次上下文,与那六个状态转换
    -- 函数用的是同一个标记 —— 声明是明写的,不是绕过。
    PERFORM set_config('evoltrya.po_status_ctx', '1', true);
    UPDATE purchase_orders SET approval_status = 'pending' WHERE id = v_po;
    PERFORM set_config('evoltrya.po_status_ctx', '', true);
    v_denied := false;
    BEGIN
        PERFORM record_po_issue(v_po, 'fixture/36-v3.pdf', repeat('d', 64));
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied OR v_msg NOT LIKE 'PO_NOT_APPROVED|%' THEN
        RAISE EXCEPTION 'FIXTURE 36D 失败:待批的单签发应当 PO_NOT_APPROVED,实得 denied=% msg=%', v_denied, v_msg;
    END IF;
END $$;
ROLLBACK;
