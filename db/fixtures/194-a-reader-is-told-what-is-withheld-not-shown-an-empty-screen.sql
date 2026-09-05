-- 194 一个读不到的读者拿到的是【一句拒绝】,不是一屏空数据
--
-- FIX-2a(2026-09-05)。FIX-1 修了 Fu Sheng 填不完的那张收货表单;本刀修剩下的 79 处。
--
-- ═══════════════════════════════════════════════════════════════════════════
-- ★★【这一支断言的是【视图】,不是【调用点】—— 而那是 Tim 的裁定(Q6)】★★
--
-- 本刀改了 40 个文件、81 个读点。**按读点写断言会是 85 条,而它们只是同样的
-- 16 条被抄了五遍** —— 一份长到没人读的证明不是证明。
-- Tim 的原话:「Per view。85 条证明是 16 条断言写五遍,而一份读不完的证明不是证明。」
--
-- 所以判据落在【暴露面】上,因为暴露面就住在视图里:
--   A 正对照 —— 只持那个【新加的】码的读者,现在读得到查名视图;
--   B 窄对照 —— 同一个读者读【基表】与【带价的老视图】,仍然是 0;
--   C 反对照 —— 一个零权限账号,每一张查名视图都是 0;
--   D 遮蔽对照 —— ★本刀唯一的不变量★:查名视图只改【行】谓词,
--                 每一【列】原样保留它的 data.* 遮蔽;
--   E 修复对照 —— container_overview:守卫码现在读得到这一页自己的主表;
--   F 结构对照 —— 查名视图【没有】那几列敏感列(问 information_schema,不问数据)。
--
-- 【为什么 D 是最要紧的一条】没有它,"我只改了行谓词"就只是一句话。
-- payroll_period_lookup 带着薪酬合计、inbound_batch_lookup 带着单价 ——
-- 若哪一天有人把那几个 CASE WHEN 拿掉,A/B/C 三条【全都照样绿】。
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    -- 每个读者【只持一个模块码】—— 那正是"这一条放宽是不是必要的"的判据。
    v_log   uuid := gen_random_uuid();   -- 只有 module.logistics.view
    v_fin   uuid := gen_random_uuid();   -- 只有 module.finance.view(没有 view_pay / view_prices)
    v_finp  uuid := gen_random_uuid();   -- module.finance.view + view_pay + view_prices
    v_none  uuid := gen_random_uuid();   -- 零权限
    r_log uuid; r_fin uuid; r_finp uuid; r_none uuid;
    v_mat uuid; v_sup uuid; v_goods uuid; v_ib uuid; v_pp uuid;
    v_kind text;
    n int; n2 int;
    v_price numeric; v_net numeric;
BEGIN
    INSERT INTO auth.users (id) VALUES (v_log), (v_fin), (v_finp), (v_none);

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fx194-log','f','f',true) RETURNING id INTO r_log;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_log, 'module.logistics.view');

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fx194-fin','f','f',true) RETURNING id INTO r_fin;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_fin, 'module.finance.view');

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fx194-finp','f','f',true) RETURNING id INTO r_finp;
    INSERT INTO role_permissions (role_id, permission_code)
    VALUES (r_finp, 'module.finance.view'), (r_finp, 'data.view_pay'), (r_finp, 'data.view_prices');

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fx194-none','f','f',true) RETURNING id INTO r_none;

    INSERT INTO user_roles (user_id, role_id)
    VALUES (v_log, r_log), (v_fin, r_fin), (v_finp, r_finp), (v_none, r_none);

    -- ── 自己造数据(门把 fixture 跑在【从镜像重建的空库】上,不许借线上的行)──
    -- 【种类从字典里现取,不写死一个码】materials_kind_stated 要求 kind_code 与
    -- may_be_processed 都非空;而写死 'ewaste' 会把这支 fixture 绑在一条种子行上。
    -- ★ 挑一个【不带状态轴】的种类:带轴的种类(电池料等)还要说出形态与来源
    --   (guard_material_condition_axes),而这支 fixture 测的不是物料主数据。
    SELECT code INTO v_kind FROM material_kinds
     WHERE is_active AND NOT has_condition_axes AND NOT may_ever_be_processed
     ORDER BY sort_order LIMIT 1;
    IF v_kind IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 194 前置失败:material_kinds 里没有一条【在用、不带状态轴、不可加工】的种类 —— 这支 fixture 没法造物料';
    END IF;
    INSERT INTO materials (code, name, kind_code, may_be_processed)
    VALUES ('ZZFX194-M', 'fixture 194 material', v_kind, false)
    RETURNING id INTO v_mat;
    -- 两家往来户,而这【不是】啰嗦:一张收货单不许挂在货代名下
    -- (guard_inbound_supplier_supplies_goods),而箱子的 forwarder_id 要的正是货代。
    INSERT INTO suppliers (code, legal_name, country, counterparty_type, payment_terms)
    VALUES ('ZZFX194-S', 'fixture 194 forwarder', 'SG', 'forwarder', 'NET30')
    RETURNING id INTO v_sup;
    -- supplies_goods 是【生成列】,由 counterparty_type 推出来 —— 不能直接写
    INSERT INTO suppliers (code, legal_name, country, counterparty_type, payment_terms)
    VALUES ('ZZFX194-G', 'fixture 194 goods vendor', 'SG', 'goods_supplier', 'NET60')
    RETURNING id INTO v_goods;
    -- 两道收货守卫都要满足,而它们【不是这支 fixture 在测的东西】:
    --   arrival_date 必填(IOD-2-fu1:不给默认值,免得留空比填对更容易过);
    --   来源要说出来 —— 要么挂采购行,要么给一个理由(SOURCE-1)。这里给理由。
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty,
                                 unit_price, arrival_date, source_reason_code)
    VALUES ('ZZFX194-IB', v_mat, v_goods, 100, 100, 7.25, date '2026-09-01', 'sample')
    RETURNING id INTO v_ib;
    INSERT INTO payroll_periods (code, period_month, payment_date, fx_rate, net_pay_total, gross_total)
    VALUES ('ZZFX194-PP', date '2026-09-01', date '2026-09-25', 1, 4321.00, 5000.00)
    RETURNING id INTO v_pp;
    -- 箱号有格式约束(CTR-YYYY-NNNN),所以这一行【不能】用 ZZFX194- 前缀。
    -- 9194 这个序号是留给 fixture 的,不与真实箱号相撞。
    INSERT INTO containers (code, departure_date, forwarder_id)
    VALUES ('CTR-2026-9194', date '2026-09-01', v_sup);

    -- ══════════ A. 正对照:只持 logistics.view 的人叫得出那家货代 ═════════
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_log), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO n FROM supplier_lookup WHERE code = 'ZZFX194-S';
    RESET ROLE;
    IF n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 194A 失败:只持 module.logistics.view 的读者在 supplier_lookup 上拿到 % 行,期望 1 —— 货代名单又是空的了', n;
    END IF;
    RAISE NOTICE '194A logistics.view 叫得出货代的名字 ✓';

    -- ══════════ B. 窄对照:同一个人读【基表】仍然是 0 ═══════════════════
    -- 这一条钉死的是"没有把 module.suppliers.view 授给他"这条捷径。
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_log), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO n FROM suppliers WHERE code = 'ZZFX194-S';
    SELECT count(*) INTO n2 FROM inbound_batches WHERE code = 'ZZFX194-IB';
    RESET ROLE;
    IF n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 194B 失败:只持 logistics.view 的读者读到了 suppliers 基表 % 行 —— 整段商务关系泄露了', n;
    END IF;
    IF n2 <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 194B 失败:只持 logistics.view 的读者读到了 inbound_batches 基表 % 行', n2;
    END IF;
    RAISE NOTICE '194B 基表仍然读不到(suppliers 0 / inbound_batches 0)✓';

    -- ══════════ C. 反对照:零权限账号,每一张查名视图都是 0 ═══════════════
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_none), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT (SELECT count(*) FROM supplier_lookup)
         + (SELECT count(*) FROM customer_lookup)
         + (SELECT count(*) FROM material_lookup)
         + (SELECT count(*) FROM inbound_batch_lookup)
         + (SELECT count(*) FROM output_batch_lookup)
         + (SELECT count(*) FROM processing_run_lookup)
         + (SELECT count(*) FROM processing_output_lookup)
         + (SELECT count(*) FROM processing_cost_entry_lookup)
         + (SELECT count(*) FROM work_order_lookup)
         + (SELECT count(*) FROM payroll_period_lookup)
         + (SELECT count(*) FROM employee_lookup)
         + (SELECT count(*) FROM shipment_lookup)
         + (SELECT count(*) FROM freight_document_lookup)
         + (SELECT count(*) FROM tax_code_lookup)
         + (SELECT count(*) FROM finance_settings_lookup)
         + (SELECT count(*) FROM output_batch_metal_lookup)
         + (SELECT count(*) FROM customer_billing_lookup)
         + (SELECT count(*) FROM container_overview)
      INTO n;
    RESET ROLE;
    IF n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 194C 失败:一个零权限账号在 18 张视图上一共拿到 % 行,期望 0 —— 门大开了', n;
    END IF;
    RAISE NOTICE '194C 零权限账号:18 张视图全 0 ✓';

    -- ══════════ D. ★遮蔽对照★:只改行谓词,列的 data.* 遮蔽原样保留 ═══════
    -- D1:没有 data.view_pay 的 finance 读者 —— 读得到薪资期间【这一行】,
    --     而四个合计必须是 NULL。这是本刀"一分钱都没有多给"那句话的全部证据。
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_fin), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*), max(net_pay_total) INTO n, v_net
      FROM payroll_period_lookup WHERE code = 'ZZFX194-PP';
    SELECT max(unit_price) INTO v_price FROM inbound_batch_lookup WHERE code = 'ZZFX194-IB';
    RESET ROLE;
    IF n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 194D1 失败:finance.view 在 payroll_period_lookup 上拿到 % 行,期望 1 —— 关账的人又被告知"这个月没有薪资期间"了', n;
    END IF;
    IF v_net IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 194D1 失败:一个【没有 data.view_pay】的读者读到了 net_pay_total = % —— 查名视图放宽了【列】,而它只许放宽【行】', v_net;
    END IF;
    IF v_price IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 194D2 失败:一个【没有 data.view_prices】的读者读到了 unit_price = % —— 同上', v_price;
    END IF;
    RAISE NOTICE '194D 行放宽、列不放宽:期间读得到,合计与单价是 NULL ✓';

    -- D3:持有那两个 data 码的人【必须】读得到数字 —— 否则上面那条是靠"谁都读不到"通过的
    --     (fixture 26 记过的那种「真空通过」)。
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_finp), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT max(net_pay_total) INTO v_net FROM payroll_period_lookup WHERE code = 'ZZFX194-PP';
    SELECT max(unit_price) INTO v_price FROM inbound_batch_lookup WHERE code = 'ZZFX194-IB';
    RESET ROLE;
    IF v_net IS DISTINCT FROM 4321.00 THEN
        RAISE EXCEPTION 'FIXTURE 194D3 失败:持 data.view_pay 的读者拿到 net_pay_total = %,期望 4321.00 —— D1 是【真空】通过的', v_net;
    END IF;
    IF v_price IS DISTINCT FROM 7.25 THEN
        RAISE EXCEPTION 'FIXTURE 194D3 失败:持 data.view_prices 的读者拿到 unit_price = %,期望 7.25', v_price;
    END IF;
    RAISE NOTICE '194D3 正对照:两个 data 码在手时,数字确实读得到 ✓';

    -- ══════════ E. 修复对照:container_overview 的守卫码 ══════════════════
    -- 读这一页要 module.logistics.view;而这张视图此前只认 module.purchasing.view。
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_log), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO n FROM container_overview WHERE code = 'CTR-2026-9194';
    RESET ROLE;
    IF n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 194E 失败:持 module.logistics.view(= 这一页的守卫码)的读者在 container_overview 上拿到 % 行,期望 1 —— 他又要通过守卫、然后从这一页自己的主表读到零行了', n;
    END IF;
    RAISE NOTICE '194E container_overview:页面守卫码读得到这一页自己的主表 ✓';

    -- ══════════ F. 结构对照:暴露面【就是】列清单 ════════════════════════
    -- 问 information_schema,不问数据 —— 一张今天恰好没有行的表,
    -- 用数据是断言不出"它不出这一列"的(fixture 39 那一课)。
    SELECT count(*) INTO n FROM information_schema.columns
     WHERE table_schema = 'public'
       AND ( (table_name = 'supplier_lookup'   AND column_name IN
                ('payment_terms','incoterm','credit_rating','tax_id','address','tax_residence'))
          OR (table_name = 'employee_lookup'   AND column_name IN
                ('monthly_salary','identity_no','work_pass_no','residency_status','department_id'))
          OR (table_name = 'processing_run_lookup' AND column_name IN
                ('material_cost_base','process_cost_base','total_cost_base','capitalized_cost_base'))
          OR (table_name = 'customer_lookup'   AND column_name IN
                ('payment_terms_days','default_tax_code','credit_limit_base','credit_rating'))
          OR (table_name = 'finance_settings_lookup' AND column_name IN
                ('locked_before','approval_threshold_base','gst_registration_no')) );
    IF n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 194F 失败:查名视图上出现了 % 个不该出现的列 —— 暴露面【就是】这份列清单,加一列等于扩一次权', n;
    END IF;
    RAISE NOTICE '194F 五张查名视图都没有那几列敏感列 ✓';

    -- F2:反过来 —— 那几张视图【真的存在】而且真的有列。
    -- 一个"数出来是 0"必须是一次测量,不是一次缺席(AGENTS.md 的 xmodule 那一课)。
    SELECT count(DISTINCT table_name) INTO n FROM information_schema.columns
     WHERE table_schema = 'public'
       AND table_name IN ('supplier_lookup','employee_lookup','processing_run_lookup',
                          'customer_lookup','finance_settings_lookup');
    IF n <> 5 THEN
        RAISE EXCEPTION 'FIXTURE 194F2 失败:那五张查名视图只找到 % 张 —— 上面那个 0 是【它们不存在】,不是【它们干净】', n;
    END IF;
    RAISE NOTICE '194F2 五张视图都在(所以 F 的那个 0 是一次测量)✓';

    RAISE NOTICE 'FIXTURE 194 全部通过';
END $$;
ROLLBACK;
