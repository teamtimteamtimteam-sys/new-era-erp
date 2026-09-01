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
    u_l2   uuid := gen_random_uuid();   -- 二级审批人(CHAIN-BUILD-1 起:按【角色】,不再具名)
    r_req uuid; r_l1 uuid; r_l2 uuid;
    v_sup uuid; v_mat uuid; v_base text; v_fgn text;
    v_lines jsonb;
    po_small uuid; po_big uuid; po_fx uuid;
    v_res jsonb; v_denied boolean; v_msg text;
    v_ib uuid; v_n int;
BEGIN
    SELECT code INTO v_base FROM currencies WHERE is_base;
    SELECT code INTO v_fgn  FROM currencies WHERE NOT is_base LIMIT 1;
    -- APR-2c:审批默认【不生效】(三态见迁移文件头)。本 fixture 测的是生效之后的
    -- 引擎,所以要打开它 —— 关着的那一态由下面的 F 臂单独测。
    -- 【SOD-1 改了打开的【时机】,不是这一臂的意思】此前这里先打开、稍后再配策略,
    -- 那正是"开着但没配"那一态,而 SOD-1 的 trg_approvals_switch 把它变成了
    -- 【到不了】的状态(理由:那一态会照常生成 pending 的单,而那些单批不了也
    -- 收不了货 —— 搁死单据)。所以这里只做与审批无关的设置,开关留到 E 臂。
    UPDATE finance_settings SET locked_before = NULL, system_start_date = '2027-01-01';

    -- 角色:提单人与一级审批人【不同角色】—— procurement 提单,所以它不能是审批角色
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-35-req', 'f', 'f', true) RETURNING id INTO r_req;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_req, unnest(ARRAY['module.purchasing.edit','module.purchasing.view',
                               'module.inbound.edit','module.inbound.view','module.finance.edit']);
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-35-approver', 'f', 'f', true) RETURNING id INTO r_l1;
    -- CHAIN-BUILD-1(R4):审批角色必须【看得见金额】—— approve_purchase_order 现在
    -- 要 data.view_prices,而开关那道闸也会为看不见金额的角色按名拒。
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_l1, unnest(ARRAY['module.purchasing.view','module.purchasing.edit','data.view_prices']);
    -- CHAIN-BUILD-1(R1):二级也是一个【角色】。**它与一级是两个不同的角色** ——
    -- R2 说得很死:加第二个审批人是【分工】,不是【互为代理】。
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-35-l2', 'f', 'f', true) RETURNING id INTO r_l2;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_l2, unnest(ARRAY['module.purchasing.view','data.view_prices']);
    -- 【SOD-1:一级审批角色必须有【真的登录得了的】持有人】
    -- trg_approvals_switch 数的是 user_roles ⋈ auth.users —— 一个只由幽灵持有的
    -- 角色是一个永远不会有人来批的队列(线上有 66 条认不到人的授权,
    -- 见 docs/known-issues.md 的 ACCOUNTS-STALE 条)。所以这三个人要是真账号。
    -- ★【CHAIN-BUILD-1(R3):持有人判据从「有一行账号记录」改成「真的登录得了」】★
    --   所以这几个账号必须【已确认】。confirmed_at 是生成列(LEAST(email,phone)),
    --   写不进去 —— 要设的是 email_confirmed_at。不设的话,这几个角色在新判据下
    --   都是 0 个真持有人,开关根本开不起来,而这一支 fixture 测的正是开起来之后。
    INSERT INTO auth.users (id, email_confirmed_at)
    VALUES (u_req, now()), (u_l1, now()), (u_l2, now());
    INSERT INTO user_roles (user_id, role_id) VALUES (u_req, r_req), (u_l1, r_l1), (u_l2, r_l2);

    INSERT INTO suppliers (code, legal_name, country, counterparty_type)
    VALUES ('ZZFIX35-S', 'fixture 35 supplier', 'SG', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZFIX35-M', 'fixture 35 material', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO v_mat;
    -- 外币牌价:1 外币 = 1.26 本位币(FIN-35 起外币单必须有真汇率)
    INSERT INTO fx_rates (currency, rate_date, rate_type, rate_sgd_per_unit)
    VALUES (v_fgn, '2027-03-03', 'tt_sell', 1.26);

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u_req), true);

    -- ══════════ E. 【SOD-1 之后这一臂问的是另一个问题,而那是刻意的】════════
    -- 此前:先打开开关、不配策略,然后断言 approve 会以 APPROVAL_THRESHOLD_NOT_SET
    -- 拒绝路由。**那一态现在到不了** —— trg_approvals_switch 拒绝在策略没配齐时
    -- 打开开关,而开着的时候也不许把策略抽走。于是同一条保护挪到了【更早】的时刻:
    -- 不是"路由的时候拒绝",而是"根本开不起来"。
    -- 引擎里那几条 *_NOT_SET 的拒绝【没有删】,它们成了纵深防御(调用方直接调
    -- approval_level_for 仍然会撞上),只是不再能由这个开关造出来。
    -- 【所以这一臂改成断言那道更早的闸】,而不是断言一个再也不会发生的状态。
    v_denied := false;
    BEGIN
        UPDATE finance_settings SET approvals_enabled = true;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied OR v_msg NOT LIKE 'APPROVALS_POLICY_INCOMPLETE|%' THEN
        RAISE EXCEPTION 'FIXTURE 35E 失败:策略没配齐时开关不该开得起来,实得 denied=% msg=%',
            v_denied, COALESCE(v_msg,'(没有报错)');
    END IF;

    -- 配齐,然后打开 —— 三个策略值与开关【一起】设(fresh-install-checklist 的规矩)
    UPDATE finance_settings
    SET approval_threshold_base = 10000,
        approval_level1_role_code = 'fixture-35-approver',
        approval_level2_role_code = 'fixture-35-l2',
        approvals_enabled = true;

    -- ══════════ E(续). 生效之后,单据生为 draft/pending 且留下 submitted ═══════
    v_lines := jsonb_build_array(jsonb_build_object(
        'line_no', 1, 'material_id', v_mat, 'quantity', 10, 'estimated_unit_price', 100));
    po_small := (create_purchase_order(v_sup, '2027-03-03'::date, NULL, v_base, NULL,
                                       NULL, NULL, NULL, v_lines, NULL)->>'purchase_order_id')::uuid;

    -- 【生效时必须生为 draft/pending】—— 这一条要单独断言。少了它,一个"开关打开也
    -- 照样直接盖章"的实现只会以别的错误偶然被逮到,而不是被点名;写这一臂时实测过。
    IF (SELECT status FROM purchase_orders WHERE id = po_small) <> 'draft'
       OR (SELECT approval_status FROM purchase_orders WHERE id = po_small) <> 'pending' THEN
        RAISE EXCEPTION 'FIXTURE 35E 失败:审批生效时采购单应生为 draft/pending,实得 %/% —— 一出生就已批的话,"提单人发起"仍然无处可放,审批只是装饰',
            (SELECT status FROM purchase_orders WHERE id = po_small),
            (SELECT approval_status FROM purchase_orders WHERE id = po_small);
    END IF;
    -- 而留痕应当是 submitted(有人提交),不是 auto_approved(系统盖章)
    SELECT count(*) INTO v_n FROM approval_log
     WHERE subject_type = 'purchase_order' AND subject_id = po_small AND decision = 'submitted';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 35E 失败:生效时提单应留一行 submitted,实得 % 行', v_n;
    END IF;



    -- ══════════ A. 分级边界在【本位币】那一侧 ═══════════════════════════════
    -- 【换成一级审批人来批】此前这一句在被删掉的那段阈值断言里,顺带把 claims
    -- 切到了 u_l1;E 臂重写之后那一段没了,于是这里会以【提单人】u_req 的身份去批,
    -- 撞上 SELF_APPROVAL_FORBIDDEN。**实测撞到了** —— 记在这里,因为它正说明
    -- 四眼规则是活的:换个人就过,不换就不过。
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u_l1), true);
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

    -- 二级【角色】的持有人来批 → 成功,且级别是 2(CHAIN-BUILD-1:不再是那一个具名的人)
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
                                     arrival_date, purchase_order_id, purchase_order_line_id)
        VALUES ('ZZFIX35-IB', v_mat, v_sup, 1, 1, '2027-03-10', po_big,
                (SELECT id FROM purchase_order_lines WHERE purchase_order_id = po_big LIMIT 1));
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
                                 arrival_date, purchase_order_id, purchase_order_line_id)
    VALUES ('ZZFIX35-IB', v_mat, v_sup, 1, 1, '2027-03-10', po_big,
            (SELECT id FROM purchase_order_lines WHERE purchase_order_id = po_big LIMIT 1))
    RETURNING id INTO v_ib;
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
    -- ══════════ F. 审批【未生效】时:直接建成 confirmed/approved,且说得出口 ══════
    -- 【第三种状态,不是"配置漏了"】四眼在只有一个用户的系统里跑不起来,而
    -- "没配就拒绝"会把采购整个停掉 —— 空配置与不能用的系统是同一个结果。
    UPDATE finance_settings SET approvals_enabled = false;

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u_req), true);
    v_lines := jsonb_build_array(jsonb_build_object(
        'line_no', 1, 'material_id', v_mat, 'quantity', 3, 'estimated_unit_price', 100));
    po_small := (create_purchase_order(v_sup, '2027-03-03'::date, NULL, v_base, NULL,
                                       NULL, NULL, NULL, v_lines, NULL)->>'purchase_order_id')::uuid;

    IF (SELECT approval_status FROM purchase_orders WHERE id = po_small) <> 'approved'
       OR (SELECT status FROM purchase_orders WHERE id = po_small) <> 'confirmed' THEN
        RAISE EXCEPTION 'FIXTURE 35F 失败:审批未生效时采购单应直接建成 confirmed/approved,实得 %/%',
            (SELECT status FROM purchase_orders WHERE id = po_small),
            (SELECT approval_status FROM purchase_orders WHERE id = po_small);
    END IF;

    -- 【留痕记 auto_approved,不是 submitted】没有人做过这个决定 —— 与 APR-1 回填
    -- 那三张旧单同一个词、同一个理由:不要把"系统直接盖章"伪装成一次人的决定。
    SELECT count(*) INTO v_n FROM approval_log
     WHERE subject_type = 'purchase_order' AND subject_id = po_small
       AND decision = 'auto_approved';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 35F 失败:审批未生效时应留一行 auto_approved,实得 % 行 —— 记成 submitted 就是说有人提交给某个并不存在的审批人', v_n;
    END IF;

    -- 未生效时"批准"是个没有意义的动作,必须点名拒绝而不是默默成功
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u_l1), true);
    v_denied := false;
    BEGIN
        PERFORM approve_purchase_order(po_small, NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied OR v_msg <> 'APPROVALS_NOT_ENABLED' THEN
        RAISE EXCEPTION 'FIXTURE 35F 失败:未生效时批准应当 APPROVALS_NOT_ENABLED,实得 denied=% msg=% —— 默默成功会让人以为审批流在跑',
            v_denied, v_msg;
    END IF;

    -- 而收货【应当照常】—— 审批不生效不等于采购停摆,这正是三态存在的理由
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u_req), true);
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty,
                                 arrival_date, purchase_order_id, purchase_order_line_id)
    VALUES ('ZZFIX35-IB2', v_mat, v_sup, 1, 1, '2027-03-11', po_small,
            (SELECT id FROM purchase_order_lines WHERE purchase_order_id = po_small LIMIT 1));

    -- 改金额也不该炸:作废触发器在未生效时必须早退,否则会撞 APPROVAL_THRESHOLD_NOT_SET
    UPDATE purchase_orders SET estimated_total_ccy = 999999 WHERE id = po_small;
    IF (SELECT approval_status FROM purchase_orders WHERE id = po_small) <> 'approved' THEN
        RAISE EXCEPTION 'FIXTURE 35F 失败:审批未生效时改金额不该动审批状态';
    END IF;
END $$;
ROLLBACK;
