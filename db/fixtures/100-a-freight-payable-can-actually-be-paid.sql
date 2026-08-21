-- 100 未付运费单【结得掉】—— 而且门是【新开的那一扇】,不是把旧的那扇拓宽
--
-- 【这份 fixture 存在的理由】FRT-1 之后,payment_allocations 的 CHECK 是六选一
-- (含 freight_document_id)、ap_open_items 的运费支按 pa.freight_document_id 去减
-- 已结清额 —— 而 record_payment 停在五选一,全函数搜 freight 零命中。
-- 于是一张未付运费单【进得了账龄、出不了门】:这套系统里没有任何一条路能把它结清。
-- 线上看不出来,只因为运费单一张都没有 —— 一个只在有数据时才现形的洞。
--
-- 【A 臂:部分付、再付清 —— 敞口每一步都对,而且超付按名拒】
-- 只断言"付得进去"是不够的:一个不做敞口校验的实现照样让两笔都过,
-- 而多付出去的钱会变成一张【负数敞口】或干脆消失。所以本臂三件事一起钉:
-- 部分付之后敞口降到剩余额、超出剩余额的第二笔【按名】拒、付清之后账龄里没有这一行。
--
-- 【B 臂:不能被核销的单据,三种,全部按名拒】
-- 筛选条件与 ap_open_items 的运费支逐字一致(unpaid + posted + 未软删)。
-- 少任何一条,画面上能选到的单据与这里能核销的单据就会分家。
-- 【三种状态各自单独一臂,不合并】:一个只判 status、不判 payment_status 的实现
-- 能通过"已冲销"那一半,而对一张已付的单据再付一次 —— 那是凭空多出来的一笔付款。
-- (freight_documents 的 status 只有 'posted'/'reversed' 两个取值,没有 'draft';
--  所以"草稿"这一格由【已付】与【已软删】两种同类状态代替,见本刀的报告。)
--
-- 【C 臂:门【移动】了,不是【拓宽】了 —— 本 fixture 的头号断言】
-- 旧路径把运费单的 uuid 当成 inbound_batch_id 送下来。它今天被 ALLOC_INVALID 拒,
-- 而【那次拒绝指着错的东西】(说"这个进料批不合法",人选的是一张运费单)。
-- 本臂对【同一张单】依次走两条路:旧路径必须【仍然】拒,新路径必须成功。
-- 【只断言新路径成功的实现,可以是把 inbound_batch_id 也放行来实现的】——
-- 那不是开了一扇门,那是把墙拆了:一个进料批的 uuid 从此也能冒充别的东西。
--
-- 日期落在 2027,自带数据(README 第 2/4/5 条)。
BEGIN;
DO $$
DECLARE
    v_user  uuid := gen_random_uuid();
    r_all   uuid;
    v_ccy   text;
    v_bank  text;
    v_fwd   uuid; v_sup uuid; v_mat uuid;
    v_b1 uuid; v_b2 uuid; v_b3 uuid; v_b4 uuid; v_b5 uuid;
    v_fd1 uuid; v_fd2 uuid; v_fd3 uuid; v_fd4 uuid; v_fd5 uuid;
    v_c1 text;  v_c2 text;  v_c3 text;  v_c4 text;  v_c5 text;
    v_res   jsonb;
    v_msg   text; v_denied boolean;
    v_n     int; v_open numeric; v_settled numeric;
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    v_bank := bank_account_for_currency(v_ccy);
    -- 前提显式设定(README 第 5 条):期间锁不能挡住 2027 的分录
    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-100', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_all, unnest(ARRAY['module.finance.edit','module.finance.view',
        'module.inbound.view','module.inbound.edit','data.view_prices']);
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZFIX100-MAT', 'fixture 100 material supplier', 'SG', 'active', 'goods_supplier')
    RETURNING id INTO v_sup;
    -- 【货代】—— 运费的贷方记在它名下,付款的对手方也是它
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZFIX100-FWD', 'fixture 100 forwarder', 'SG', 'active', 'forwarder')
    RETURNING id INTO v_fwd;
    INSERT INTO materials (code, name, kind_code, may_be_processed)
    VALUES ('ZZFIX100-M', 'fixture 100 material', 'battery_material', true) RETURNING id INTO v_mat;

    -- ══════════ A. 部分付 → 敞口下降 → 超付按名拒 → 付清 → 账龄里没有了 ══════
    -- 每一臂自带批次与运费单(README 第 2 条:用例之间不共享可变状态 ——
    -- 共享一张运费单的第二个用例会因为第一个把额度用光而"被拒",与被测规则无关)。
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty,
        arrival_date, unit_price)
    VALUES ('ZZFIX100-IB1', v_mat, v_sup, 100, 100, DATE '2027-03-01', 10) RETURNING id INTO v_b1;

    v_res := record_freight_document(DATE '2027-03-05', v_fwd, 1000, v_ccy, 'weight',
        'unpaid', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', v_b1)),
        'fixture 100 A', NULL);
    v_fd1 := (v_res->>'freight_document_id')::uuid;
    v_c1  := v_res->>'code';

    SELECT COALESCE(open_base, -1) INTO v_open FROM ap_open_items
     WHERE doc_kind = 'freight' AND doc_id = v_fd1;
    IF v_open IS DISTINCT FROM 1000 THEN
        RAISE EXCEPTION 'FIXTURE 100A 失败:刚开出的未付运费单 % 敞口应为 1,000,实得 % —— 前提不成立,后面每一条断言都无从谈起',
            v_c1, COALESCE(v_open::text, '(没有这一行)');
    END IF;

    -- ── 第一笔:部分付 400 ──────────────────────────────────────────────────
    v_res := record_payment('out', v_fwd, 400, v_ccy, NULL, v_bank, DATE '2027-03-10',
        'fixture 100 A partial',
        jsonb_build_array(jsonb_build_object('freight_document_id', v_fd1, 'amount_doc', 400)),
        'supplier');

    SELECT COALESCE(open_base, -1) INTO v_open FROM ap_open_items
     WHERE doc_kind = 'freight' AND doc_id = v_fd1;
    IF v_open IS DISTINCT FROM 600 THEN
        RAISE EXCEPTION 'FIXTURE 100A 失败:付掉 400 之后敞口应为 600,实得 % —— 账龄的运费支按 pa.freight_document_id 减已结清额,核销行没落到那一列上就会算不动',
            COALESCE(v_open::text, '(这一行整个不见了)');
    END IF;
    SELECT COALESCE(SUM(pa.allocated_ccy), 0) INTO v_settled
      FROM payment_allocations pa JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
     WHERE pa.freight_document_id = v_fd1;
    IF v_settled <> 400 THEN
        RAISE EXCEPTION 'FIXTURE 100A 失败:核销行应记在 freight_document_id 上(400),实得 % —— 记到别的列上账是平的,而这张单永远结不掉',
            v_settled;
    END IF;

    -- ── 第二笔:要付 700,只剩 600 → 按名拒 ────────────────────────────────
    -- 【这一条是本臂的判别力所在】不做敞口校验的实现让它过,而多付出去的钱
    -- 会变成一张负敞口 —— 账龄表上那一行直接消失,没有任何错误。
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM record_payment('out', v_fwd, 700, v_ccy, NULL, v_bank, DATE '2027-03-12',
            'fixture 100 A overshoot',
            jsonb_build_array(jsonb_build_object('freight_document_id', v_fd1, 'amount_doc', 700)),
            'supplier');
    EXCEPTION WHEN OTHERS THEN
        v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR v_msg NOT LIKE 'ALLOC_EXCEEDS|%' THEN
        RAISE EXCEPTION 'FIXTURE 100A 失败:超出剩余敞口(700 > 600)应按名拒 ALLOC_EXCEEDS,实得 denied=% msg=% —— 超付不报错,就是把钱付进一个不存在的债',
            v_denied, COALESCE(v_msg, '(收下了)');
    END IF;
    -- 被拒之后什么都没变(拒绝必须是"一个字节都没写",不是"写了再回滚一半")
    SELECT COALESCE(open_base, -1) INTO v_open FROM ap_open_items
     WHERE doc_kind = 'freight' AND doc_id = v_fd1;
    IF v_open IS DISTINCT FROM 600 THEN
        RAISE EXCEPTION 'FIXTURE 100A 失败:被拒的那一笔不该动任何东西,敞口应仍是 600,实得 %', COALESCE(v_open::text, 'NULL');
    END IF;

    -- ── 第三笔:付清剩下的 600 → 账龄里没有这一行了 ────────────────────────
    PERFORM record_payment('out', v_fwd, 600, v_ccy, NULL, v_bank, DATE '2027-03-15',
        'fixture 100 A settle',
        jsonb_build_array(jsonb_build_object('freight_document_id', v_fd1, 'amount_doc', 600)),
        'supplier');

    SELECT count(*) INTO v_n FROM ap_open_items WHERE doc_kind = 'freight' AND doc_id = v_fd1;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 100A 失败:付清之后账龄里不该还有这一行(视图的存在判据是 open_ccy > 0),实得 % 行', v_n;
    END IF;
    SELECT COALESCE(SUM(pa.allocated_ccy), 0) INTO v_settled
      FROM payment_allocations pa JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
     WHERE pa.freight_document_id = v_fd1;
    IF v_settled <> 1000 THEN
        RAISE EXCEPTION 'FIXTURE 100A 失败:两笔核销合计应恰好等于单据金额 1,000,实得 % —— "行不见了"与"结清了"不是一回事,所以两边都要断言',
            v_settled;
    END IF;

    -- ══════════ B. 不能被核销的三种状态,全部按名拒 ═════════════════════════
    -- B1 已冲销(status = 'reversed')
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty,
        arrival_date, unit_price)
    VALUES ('ZZFIX100-IB2', v_mat, v_sup, 100, 100, DATE '2027-04-01', 10) RETURNING id INTO v_b2;
    v_res := record_freight_document(DATE '2027-04-05', v_fwd, 500, v_ccy, 'weight',
        'unpaid', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', v_b2)),
        'fixture 100 B1', NULL);
    v_fd2 := (v_res->>'freight_document_id')::uuid;
    v_c2  := v_res->>'code';
    -- 【LOG-4a 起走正门】此前这里是一句直接 UPDATE,并在旁边记着"因为这个仓库
    -- 没有 reverse_freight_document"。那个缺口已经补上,而且补的同时立了一条守卫:
    -- 直接 UPDATE status 现在【按名被拒】(FREIGHT_STATUS_NO_DIRECT_UPDATE)。
    -- 所以这一句改走正门 —— 本臂要的仍然只是"status 是 reversed 时会怎样"。
    PERFORM reverse_freight_document(v_fd2, 'fixture 100 B1:把它冲掉,好测已冲销的单据');

    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM record_payment('out', v_fwd, 100, v_ccy, NULL, v_bank, DATE '2027-04-10',
            'fixture 100 B1',
            jsonb_build_array(jsonb_build_object('freight_document_id', v_fd2, 'amount_doc', 100)),
            'supplier');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR v_msg NOT LIKE 'ALLOC_INVALID|%' THEN
        RAISE EXCEPTION 'FIXTURE 100B1 失败:已冲销的运费单 % 应按名拒 ALLOC_INVALID,实得 denied=% msg=% —— 一张被冲销的单据不欠任何人钱',
            v_c2, v_denied, COALESCE(v_msg, '(收下了)');
    END IF;

    -- B2 已付(payment_status = 'paid')—— 它从来没有进过应付,再付一次是凭空多一笔
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty,
        arrival_date, unit_price)
    VALUES ('ZZFIX100-IB3', v_mat, v_sup, 100, 100, DATE '2027-04-01', 10) RETURNING id INTO v_b3;
    v_res := record_freight_document(DATE '2027-04-06', v_fwd, 500, v_ccy, 'weight',
        'paid', v_bank, jsonb_build_array(jsonb_build_object('inbound_batch_id', v_b3)),
        'fixture 100 B2', NULL);
    v_fd3 := (v_res->>'freight_document_id')::uuid;
    v_c3  := v_res->>'code';

    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM record_payment('out', v_fwd, 100, v_ccy, NULL, v_bank, DATE '2027-04-11',
            'fixture 100 B2',
            jsonb_build_array(jsonb_build_object('freight_document_id', v_fd3, 'amount_doc', 100)),
            'supplier');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR v_msg NOT LIKE 'ALLOC_INVALID|%' THEN
        RAISE EXCEPTION 'FIXTURE 100B2 失败:【当场付掉】的运费单 % 应按名拒 ALLOC_INVALID,实得 denied=% msg=% —— 只判 status 不判 payment_status 的实现在这里放行,而那是凭空多出来的一笔付款',
            v_c3, v_denied, COALESCE(v_msg, '(收下了)');
    END IF;

    -- B3 已软删 —— 与 ap_open_items 的运费支第三个条件对上
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty,
        arrival_date, unit_price)
    VALUES ('ZZFIX100-IB4', v_mat, v_sup, 100, 100, DATE '2027-04-01', 10) RETURNING id INTO v_b4;
    v_res := record_freight_document(DATE '2027-04-07', v_fwd, 500, v_ccy, 'weight',
        'unpaid', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', v_b4)),
        'fixture 100 B3', NULL);
    v_fd4 := (v_res->>'freight_document_id')::uuid;
    v_c4  := v_res->>'code';
    UPDATE freight_documents SET deleted_at = now() WHERE id = v_fd4;

    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM record_payment('out', v_fwd, 100, v_ccy, NULL, v_bank, DATE '2027-04-12',
            'fixture 100 B3',
            jsonb_build_array(jsonb_build_object('freight_document_id', v_fd4, 'amount_doc', 100)),
            'supplier');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR v_msg NOT LIKE 'ALLOC_INVALID|%' THEN
        RAISE EXCEPTION 'FIXTURE 100B3 失败:已软删的运费单 % 应按名拒 ALLOC_INVALID,实得 denied=% msg=% —— 筛选条件必须与 ap_open_items 的运费支逐字一致,少一条就是"选得到、核销不了"或"核销得了、看不见"',
            v_c4, v_denied, COALESCE(v_msg, '(收下了)');
    END IF;

    -- ══════════ C. 门【移动】了,不是【拓宽】了 ═════════════════════════════
    -- 同一张单,依次走两条路。
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty,
        arrival_date, unit_price)
    VALUES ('ZZFIX100-IB5', v_mat, v_sup, 100, 100, DATE '2027-05-01', 10) RETURNING id INTO v_b5;
    v_res := record_freight_document(DATE '2027-05-05', v_fwd, 800, v_ccy, 'weight',
        'unpaid', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', v_b5)),
        'fixture 100 C', NULL);
    v_fd5 := (v_res->>'freight_document_id')::uuid;
    v_c5  := v_res->>'code';

    -- C1 旧路径:运费单的 uuid 当成 inbound_batch_id —— 必须【仍然】被拒
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM record_payment('out', v_fwd, 800, v_ccy, NULL, v_bank, DATE '2027-05-10',
            'fixture 100 C old path',
            jsonb_build_array(jsonb_build_object('inbound_batch_id', v_fd5, 'amount_doc', 800)),
            'supplier');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR v_msg NOT LIKE 'ALLOC_INVALID|%' THEN
        RAISE EXCEPTION 'FIXTURE 100C 失败:把运费单的 uuid 当成 inbound_batch_id 送下来,必须【仍然】按名拒 ALLOC_INVALID,实得 denied=% msg=% —— 放行它不是开门,是拆墙:一个 uuid 从此可以冒充另一种单据',
            v_denied, COALESCE(v_msg, '(收下了)');
    END IF;

    -- C2 新路径:同一张单,走 freight_document_id —— 必须成功
    -- 【两半合起来才是"门移动了"】只有 C2 的实现,可以是"把 inbound 那一支放宽"
    -- 做出来的;只有 C1 的实现,就是今天这个洞本身。
    PERFORM record_payment('out', v_fwd, 800, v_ccy, NULL, v_bank, DATE '2027-05-11',
        'fixture 100 C new path',
        jsonb_build_array(jsonb_build_object('freight_document_id', v_fd5, 'amount_doc', 800)),
        'supplier');

    SELECT count(*) INTO v_n FROM ap_open_items WHERE doc_kind = 'freight' AND doc_id = v_fd5;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 100C 失败:同一张单走新路径应当付清并离开账龄,实得 % 行', v_n;
    END IF;
    SELECT COALESCE(SUM(pa.allocated_ccy), 0) INTO v_settled
      FROM payment_allocations pa JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
     WHERE pa.freight_document_id = v_fd5;
    IF v_settled <> 800 THEN
        RAISE EXCEPTION 'FIXTURE 100C 失败:新路径的核销额应恰为 800,实得 %', v_settled;
    END IF;
    -- 而且【没有】任何一条核销行落在 inbound_batch_id 上(拆墙的实现会在这里露馅)
    SELECT count(*) INTO v_n FROM payment_allocations WHERE inbound_batch_id = v_fd5;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 100C 失败:不该有任何核销行把运费单的 uuid 写进 inbound_batch_id,实得 % 行', v_n;
    END IF;
END $$;
ROLLBACK;
