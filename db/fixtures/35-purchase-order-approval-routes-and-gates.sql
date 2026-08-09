-- 35 采购单审批:按【本位币】分级、四眼、未获批就不能收货/收钱、改价越线即作废重路由
--
-- 【判别臂是 A:外币单据的分级边界必须在本位币这一侧】
-- 一张 USD 8,000 的单在【单据币种】里低于 10,000 的阈值,在【本位币】里(×1.26)是
-- 10,080,已经越线。只用本位币单据测,一个"拿单据币种去比阈值"的实现照样全绿 ——
-- 而那正是 FIN-35 那一族缺陷的形状:同一笔真实承诺,因为供应商用哪种货币开票而落进
-- 不同的管控档位。
--
-- 【B:四眼】提单的人不能自己批(与 approve_review 的 SELF_APPROVAL_FORBIDDEN 同名同理)。
-- 【C:未获批就不能收货、不能收预付】—— 没有这一臂,审批就只是一列状态加一块好看的屏幕。
-- 【D:金额被改到需要更高一级 → 原审批作废并重新路由】(决定 4)。
--   今天没有任何真实路径能改采购单金额(见 docs/approvals-scoping.md 的 A 部分),
--   所以这一臂用裸 UPDATE 触发 —— 它测的正是"规则挂在金额上"这件事本身。
-- 【E:没配策略就拒绝路由】—— 未设的管控不等于可以跳过管控。
--
-- 【日期自设】(README 第 4 条)。
BEGIN;
DO $$
DECLARE
    u_req  uuid := gen_random_uuid();   -- 提单人(procurement)
    u_l1   uuid := gen_random_uuid();   -- 一级审批人
    u_l2   uuid := gen_random_uuid();   -- 二级审批人(具名)
    r_req uuid; r_l1 uuid;
    v_sup uuid; v_mat uuid; v_base text; v_fgn text;
    v_lines jsonb;
    po_small uuid; po_big uuid; po_fx uuid;
    v_res jsonb; v_denied boolean; v_msg text;
    v_ib uuid; v_n int;
BEGIN
    SELECT code INTO v_base FROM currencies WHERE is_base;
    SELECT code INTO v_fgn  FROM currencies WHERE NOT is_base LIMIT 1;
    UPDATE finance_settings SET locked_before = NULL, system_start_date = '2027-01-01';

    -- 角色:提单人与一级审批人【不同角色】—— procurement 提单,所以它不能是审批角色
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-35-req', 'f', 'f', true) RETURNING id INTO r_req;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_req, unnest(ARRAY['module.purchasing.edit','module.purchasing.view',
                               'module.inbound.edit','module.inbound.view','module.finance.edit']);
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-35-approver', 'f', 'f', true) RETURNING id INTO r_l1;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_l1, unnest(ARRAY['module.purchasing.view','module.purchasing.edit']);
    INSERT INTO user_roles (user_id, role_id) VALUES (u_req, r_req), (u_l1, r_l1), (u_l2, r_l1);

    INSERT INTO suppliers (code, legal_name, country)
    VALUES ('ZZFIX35-S', 'fixture 35 supplier', 'SG') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, category)
    VALUES ('ZZFIX35-M', 'fixture 35 material', 'other') RETURNING id INTO v_mat;
    -- 外币牌价:1 外币 = 1.26 本位币(FIN-35 起外币单必须有真汇率)
    INSERT INTO fx_rates (currency, rate_date, rate_type, rate_sgd_per_unit)
    VALUES (v_fgn, '2027-03-03', 'tt_sell', 1.26);

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u_req), true);

    -- ══════════ E. 没配策略 → 拒绝路由(先测,因为配置一旦写下就回不去了)═══════
    v_lines := jsonb_build_array(jsonb_build_object(
        'line_no', 1, 'material_id', v_mat, 'quantity', 10, 'estimated_unit_price', 100));
    po_small := (create_purchase_order(v_sup, '2027-03-03'::date, NULL, v_base, NULL,
                                       NULL, NULL, NULL, v_lines, NULL)->>'purchase_order_id')::uuid;

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u_l1), true);
    v_denied := false;
    BEGIN
        PERFORM approve_purchase_order(po_small, NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied OR v_msg <> 'APPROVAL_THRESHOLD_NOT_SET' THEN
        RAISE EXCEPTION 'FIXTURE 35E 失败:阈值没配就应当 APPROVAL_THRESHOLD_NOT_SET 拒绝路由,实得 denied=% msg=% —— 猜一个级别等于把审批变成装饰',
            v_denied, v_msg;
    END IF;

    -- 现在配上策略:阈值 10,000 本位币,一级角色 = 审批角色,二级 = 具名的 u_l2
    UPDATE finance_settings
    SET approval_threshold_base = 10000,
        approval_level1_role_code = 'fixture-35-approver',
        approval_level2_user_id = u_l2;

    -- ══════════ A. 分级边界在【本位币】那一侧 ═══════════════════════════════
    -- 本位币 1,000 的单 → 一级
    v_res := approve_purchase_order(po_small, 'fixture 35 level 1');
    IF (v_res->>'level')::int <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 35A 失败:本位币 1,000 应走一级,实得 %', v_res->>'level';
    END IF;

    -- 【判别用例】外币 8,000 × 1.26 = 10,080 本位币 —— 单据币种里【低于】10,000,
    -- 本位币里【高于】。拿单据币种比阈值的实现会把它判成一级。
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u_req), true);
    v_lines := jsonb_build_array(jsonb_build_object(
        'line_no', 1, 'material_id', v_mat, 'quantity', 8000, 'estimated_unit_price', 1));
    po_fx := (create_purchase_order(v_sup, '2027-03-03'::date, NULL, v_fgn, NULL,
                                    NULL, NULL, NULL, v_lines, NULL)->>'purchase_order_id')::uuid;

    -- 一级审批人来批 → 必须被拒(它其实是二级)
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u_l1), true);
    v_denied := false;
    BEGIN
        PERFORM approve_purchase_order(po_fx, NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 35A 失败:外币 8,000(本位币 10,080,【高于】阈值 10,000)被一级审批人批掉了 —— 说明阈值是拿【单据币种】比的。同一笔承诺不能因为供应商用哪种货币开票而落进不同的管控档位';
    END IF;
    IF v_msg NOT LIKE 'APPROVAL_NOT_AUTHORISED|2|%' THEN
        RAISE EXCEPTION 'FIXTURE 35A 失败:应报"这是二级、你不是那个人",实得「%」', v_msg;
    END IF;

    -- 具名的二级审批人来批 → 成功,且级别是 2
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u_l2), true);
    v_res := approve_purchase_order(po_fx, 'fixture 35 level 2');
    IF (v_res->>'level')::int <> 2 OR (v_res->>'amount_base')::numeric <> 10080 THEN
        RAISE EXCEPTION 'FIXTURE 35A 失败:应为二级、本位币 10,080,实得 level=% base=%',
            v_res->>'level', v_res->>'amount_base';
    END IF;

    -- ══════════ B. 四眼:提单人不能自己批 ═══════════════════════════════════
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u_req), true);
    v_lines := jsonb_build_array(jsonb_build_object(
        'line_no', 1, 'material_id', v_mat, 'quantity', 5, 'estimated_unit_price', 100));
    po_big := (create_purchase_order(v_sup, '2027-03-03'::date, NULL, v_base, NULL,
                                     NULL, NULL, NULL, v_lines, NULL)->>'purchase_order_id')::uuid;
    -- 提单人恰好也持有审批角色时,把关的就只剩四眼这一条 —— 所以要单独测
    INSERT INTO user_roles (user_id, role_id) VALUES (u_req, r_l1);
    v_denied := false;
    BEGIN
        PERFORM approve_purchase_order(po_big, NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied OR v_msg <> 'SELF_APPROVAL_FORBIDDEN' THEN
        RAISE EXCEPTION 'FIXTURE 35B 失败:提单人自己批应当 SELF_APPROVAL_FORBIDDEN,实得 denied=% msg=%',
            v_denied, v_msg;
    END IF;

    -- ══════════ C. 未获批 → 收不了货,也收不了预付 ═══════════════════════════
    -- po_big 此刻仍是 pending
    v_denied := false;
    BEGIN
        INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty,
                                     arrival_date, purchase_order_id)
        VALUES ('ZZFIX35-IB', v_mat, v_sup, 1, 1, '2027-03-10', po_big);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 35C 失败:未获批的采购单收货成功了 —— 审批没有把关任何东西,只是一列状态';
    END IF;
    IF v_msg NOT LIKE 'PO_NOT_APPROVED|%' THEN
        RAISE EXCEPTION 'FIXTURE 35C 失败:收货被拒了,但报的不是 PO_NOT_APPROVED,而是「%」', v_msg;
    END IF;

    -- 批准之后同一笔收货必须成功 —— 否则 C 臂可能只是"这单根本收不了货"
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u_l1), true);
    PERFORM approve_purchase_order(po_big, 'fixture 35 C');
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u_req), true);
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty,
                                 arrival_date, purchase_order_id)
    VALUES ('ZZFIX35-IB', v_mat, v_sup, 1, 1, '2027-03-10', po_big) RETURNING id INTO v_ib;
    IF v_ib IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 35C 失败:批准之后仍然收不了货 —— 本臂无法区分"审批在把关"与"这单本来就收不了"';
    END IF;

    -- ══════════ D. 改价越线 → 原审批作废并重新路由 ══════════════════════════
    -- po_big 现在是 approved,本位币 500(一级)。改成 20,000 → 需要二级。
    UPDATE purchase_orders SET estimated_total_ccy = 20000 WHERE id = po_big;

    IF (SELECT approval_status FROM purchase_orders WHERE id = po_big) <> 'pending' THEN
        RAISE EXCEPTION 'FIXTURE 35D 失败:金额被改到需要更高一级之后,原审批仍然是 approved —— 一次改价就能把二级审批绕过去';
    END IF;
    IF (SELECT approved_at FROM purchase_orders WHERE id = po_big) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 35D 失败:approval_status 退回 pending 了,但 approved_at 还留着旧时点';
    END IF;
    SELECT count(*) INTO v_n FROM approval_log
     WHERE subject_type = 'purchase_order' AND subject_id = po_big AND decision = 'approval_voided';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 35D 失败:作废应当留痕一行 approval_voided,实得 % 行 —— 批过又没批,日志里必须读得出来', v_n;
    END IF;

    -- 【反向】金额【下降】不该作废:已经批过二级的单降到一级,再批一次是空转
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u_l2), true);
    PERFORM approve_purchase_order(po_big, 'fixture 35 D re-approve at level 2');
    UPDATE purchase_orders SET estimated_total_ccy = 100 WHERE id = po_big;
    IF (SELECT approval_status FROM purchase_orders WHERE id = po_big) <> 'approved' THEN
        RAISE EXCEPTION 'FIXTURE 35D 失败:金额【下降】也把审批作废了 —— 规则应当只在需要【更高】一级时触发,否则每次改价都要重批';
    END IF;
END $$;
ROLLBACK;
