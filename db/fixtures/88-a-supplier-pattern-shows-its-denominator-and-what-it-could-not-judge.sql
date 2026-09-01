-- 88 供应商的模式【摆得出分母】,也说得出【它没能评判的那些】
--
-- 【它守的是什么】GRN-2 要回答"这家是不是一直短交"。这个问题有一种特别便宜、
-- 特别像对的答错法:**把没能评判的收货算成没问题的收货**。于是一家有 1 次可比对
-- 收货、9 次比不了的供应商,看起来和一家 10 次全都合规的供应商一模一样。
-- 这份 fixture 的每一臂都在钉住"三个计数是三件事":
--   comparable_receipts 是【分母】;
--   excluded_receipts   是【没法评判】,不是合规;
--   undated_receipts    是【放不进时间】,又是另一回事。
--
-- 【为什么 1/5 与 4/5 两家都要建】brief 要的是"两家都渲染出原始计数"。
-- 而这一条同时排除掉一种实现:任何一个把计数压成 boolean 或百分比的实现,
-- 都会让这两家在某个阈值的两侧变成"一样"或"完全不同"—— 而原始计数下,
-- 它们的区别是 1 与 4,人一眼看得出来。**这张视图没有资格替采购员定那个阈值。**
--
-- 【窗口边界必须两边各钉一天】窗口是 `arrival_date >= CURRENT_DATE - window_days`。
-- 这个不等号有两种错法:方向反了(任何粗糙用例都抓得到),以及【差一天】——
-- 后者只在边界那一天上表现出来。所以取三点:窗口内一天、边界当天、窗口外一天。
-- 边界当天【必须在内】(谓词是 >=),那正是最容易被"顺手改对"成 > 的地方。
--
-- 【本 fixture 以 postgres 跑;权限臂靠 has_permission,不切数据库角色】
-- supplier_receipt_pattern 是属主权限视图,它的门是体内那句 has_permission(),
-- 而 has_permission() 是 SECURITY DEFINER、按 request.jwt.claims 里的 sub 解析,
-- 与当前数据库角色无关(README 第 6 条点名的正是这个区别)。换 claims 才测得到它。
--
-- 【故障注入:这张视图是单层的,所以每一条结论都注过】
-- 它从不拒绝,说错话就是它唯一的失败模式。注入记录在切次报告里,基线先跑过。
BEGIN;
DO $$
DECLARE
    v_all uuid := gen_random_uuid();    -- 全部权限
    v_hr  uuid := gen_random_uuid();    -- 只有 module.hr.view —— 【另一个模块】
    r_all uuid; r_hr uuid;
    sup_1of5 uuid; sup_4of5 uuid; sup_none uuid; sup_win uuid; sup_x uuid;
    mat uuid; po_1 uuid; po_4 uuid; po_win uuid;
    l uuid; b uuid;
    v_win int;
    v_msg text;
    rec record; n int; q numeric;
BEGIN
    -- ══════════ 前提 ══════════════════════════════════════════════════════════
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-88-all', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-88-hr', 'f', 'f', true) RETURNING id INTO r_hr;
    -- 【给另一个模块,不是"什么都不给"】要证明的是模块边界,
    -- 而"没有任何权限的人看不见"什么也证明不了。
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_hr, 'module.hr.view');
    INSERT INTO user_roles (user_id, role_id) VALUES (v_all, r_all), (v_hr, r_hr);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_all), true);

    -- 【前提显式设定】(README 第 5 条)。5% 短交门槛:订 1000 → 门槛 950。
    UPDATE receiving_settings
       SET grn_short_pct = 5, grn_over_pct = 5, grn_assay_tolerance_pct = 10;

    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('FX88-M', 'fixture 88 material', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO mat;

    -- ══════════════════════════════════════════════════════════════════════════
    -- A. 5 次里 1 次短 —— 原始计数,不是一个布尔量
    -- ══════════════════════════════════════════════════════════════════════════
    INSERT INTO suppliers (code, legal_name, country, counterparty_type)
    VALUES ('FX88-S1', 'fixture 88 supplier 1of5', 'SG', 'goods_supplier') RETURNING id INTO sup_1of5;

    -- 窗口取视图自己返回的那个数 —— 【不在 fixture 里写第二个 180】。
    -- 写死一份就是第二个定义,而视图哪天改了窗口,这份 fixture 会因为一个
    -- 与被测规则无关的理由红掉(或者更坏:绿掉)。
    --
    -- 【为什么这一句必须在建出第一家供应商【之后】】第一版把它放在最前面,于是
    -- 它在【线上】跑得好好的(线上有 3 家供应商),在【重建库】上返回 NULL ——
    -- 视图从 suppliers 左连接出发,空库里一家供应商都没有,自然一行都没有。
    -- 那次 gate 判词【行为断言】退 4 并点名了这份 fixture,而它抓到的正是
    -- README 第 2 条:**每个用例自带数据,不许向线上借**。借来的东西在重建库里
    -- 不存在,而重建库才是生产的样子。
    SELECT DISTINCT window_days INTO v_win FROM supplier_receipt_pattern;
    IF v_win IS NULL OR v_win < 2 THEN
        RAISE EXCEPTION 'FIXTURE 88 无效:视图没有返回可用的 window_days(实得 %)', v_win;
    END IF;

    INSERT INTO purchase_orders (code, supplier_id, order_date, currency, fx_rate, status, approval_status)
    VALUES ('FX88-PO1', sup_1of5, CURRENT_DATE, 'USD', 1.3, 'receiving', 'approved') RETURNING id INTO po_1;

    FOR n IN 1..5 LOOP
        INSERT INTO purchase_order_lines (purchase_order_id, line_no, material_id, quantity, unit)
        VALUES (po_1, n, mat, 1000, 'kg') RETURNING id INTO l;
        -- 第 1 条短(800/1000 = −20% < −5%),其余 4 条足量
        INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, unit, remaining_qty,
                                     arrival_date, purchase_order_id, purchase_order_line_id)
        VALUES ('FX88-A' || n, mat, sup_1of5, CASE WHEN n = 1 THEN 800 ELSE 1000 END, 'kg',
                CASE WHEN n = 1 THEN 800 ELSE 1000 END, CURRENT_DATE - 1, po_1, l);
    END LOOP;
    -- short 只在关单之后报 —— 这是 GRN-1a 的规矩,这里把前提摆对
    PERFORM set_config('evoltrya.po_status_ctx', '1', true);
    UPDATE purchase_orders SET status = 'closed' WHERE id = po_1;
    PERFORM set_config('evoltrya.po_status_ctx', '', true);

    SELECT * INTO rec FROM supplier_receipt_pattern WHERE supplier_id = sup_1of5;
    IF rec.comparable_receipts <> 5 THEN
        RAISE EXCEPTION 'FIXTURE 88A 分母必须是 5(五条都比对得了),实得 %', rec.comparable_receipts;
    END IF;
    IF rec.short_receipts <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 88A 五条里一条短 —— short_receipts 必须是 1,实得 %', rec.short_receipts;
    END IF;
    IF rec.short_qty <> -200 THEN
        RAISE EXCEPTION 'FIXTURE 88A 短了 200(800 对 1000),实得 %', rec.short_qty;
    END IF;
    RAISE NOTICE '88A 5 次里 1 次短:分母 5、短 1、短量 −200 ✓';

    -- ══════════════════════════════════════════════════════════════════════════
    -- B. 5 次里 4 次短 —— 与 A 同一套断言,答案完全不同。
    --    【两家并存正是这一臂的意义】任何把计数压成布尔量的实现,都会让
    --    A 与 B 在某个阈值两侧变成"一样"或"截然不同";原始计数下它们是 1 与 4。
    -- ══════════════════════════════════════════════════════════════════════════
    INSERT INTO suppliers (code, legal_name, country, counterparty_type)
    VALUES ('FX88-S4', 'fixture 88 supplier 4of5', 'SG', 'goods_supplier') RETURNING id INTO sup_4of5;
    INSERT INTO purchase_orders (code, supplier_id, order_date, currency, fx_rate, status, approval_status)
    VALUES ('FX88-PO4', sup_4of5, CURRENT_DATE, 'USD', 1.3, 'receiving', 'approved') RETURNING id INTO po_4;

    FOR n IN 1..5 LOOP
        INSERT INTO purchase_order_lines (purchase_order_id, line_no, material_id, quantity, unit)
        VALUES (po_4, n, mat, 1000, 'kg') RETURNING id INTO l;
        INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, unit, remaining_qty,
                                     arrival_date, purchase_order_id, purchase_order_line_id)
        VALUES ('FX88-B' || n, mat, sup_4of5, CASE WHEN n <= 4 THEN 800 ELSE 1000 END, 'kg',
                CASE WHEN n <= 4 THEN 800 ELSE 1000 END, CURRENT_DATE - 1, po_4, l);
    END LOOP;
    PERFORM set_config('evoltrya.po_status_ctx', '1', true);
    UPDATE purchase_orders SET status = 'closed' WHERE id = po_4;
    PERFORM set_config('evoltrya.po_status_ctx', '', true);

    SELECT * INTO rec FROM supplier_receipt_pattern WHERE supplier_id = sup_4of5;
    IF rec.comparable_receipts <> 5 OR rec.short_receipts <> 4 THEN
        RAISE EXCEPTION 'FIXTURE 88B 必须是 5 次里 4 次短,实得 % 次里 % 次', rec.comparable_receipts, rec.short_receipts;
    END IF;
    IF rec.short_qty <> -800 THEN
        RAISE EXCEPTION 'FIXTURE 88B 四条各短 200 = −800,实得 %', rec.short_qty;
    END IF;
    -- 【两家的分母一样,分子不一样】—— 这一句才是"摆得出分母"的全部意义
    IF (SELECT short_receipts FROM supplier_receipt_pattern WHERE supplier_id = sup_1of5)
       = (SELECT short_receipts FROM supplier_receipt_pattern WHERE supplier_id = sup_4of5) THEN
        RAISE EXCEPTION 'FIXTURE 88B 1/5 与 4/5 两家的 short_receipts 不该相等 —— 计数被压平了';
    END IF;
    RAISE NOTICE '88B 5 次里 4 次短:分母同为 5,分子 1 vs 4,原始计数分得开 ✓';

    -- ══════════════════════════════════════════════════════════════════════════
    -- C. 没挂采购行的收货【被排除,并且被数出来】—— 绝不折进分母当合规
    -- ══════════════════════════════════════════════════════════════════════════
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, unit, remaining_qty, arrival_date, source_reason_code, source_reason_note)
    VALUES ('FX88-AEXCL', mat, sup_1of5, 9999, 'kg', 9999, CURRENT_DATE - 1, 'other', 'fixture 88 自带数据') RETURNING id INTO b;

    SELECT * INTO rec FROM supplier_receipt_pattern WHERE supplier_id = sup_1of5;
    IF rec.excluded_receipts <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 88C 一条没挂采购行的收货必须【数进 excluded】,实得 %', rec.excluded_receipts;
    END IF;
    -- 【最要紧的一句:它没有把分母顶大】
    IF rec.comparable_receipts <> 5 THEN
        RAISE EXCEPTION 'FIXTURE 88C 比不了的收货不许进分母 —— 分母仍应是 5,实得 %。把"没法评判"算成"没问题"正是这一刀要消灭的。', rec.comparable_receipts;
    END IF;
    IF rec.short_receipts <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 88C 分子也不许被它动到,实得 %', rec.short_receipts;
    END IF;
    RAISE NOTICE '88C 比不了的收货:excluded=1,分母仍是 5、分子仍是 1 ✓';

    -- ══════════════════════════════════════════════════════════════════════════
    -- D. 没有到货日的收货是【第三类】—— 既不进分母,也不算 excluded,
    --    而且【带差异的那些要单独数出来】(它回答"补上日期会不会改变结论")
    -- ══════════════════════════════════════════════════════════════════════════
    -- 【无日期的收货是怎么可能存在的 —— 查过了,不是想当然】
    -- `inbound_batches.arrival_date` 上【没有任何 CHECK 约束】(实测:该表的
    -- check 约束只有 pricing_status / remaining_qty / stage 三条)。FIN-32 那条
    -- `NOT VALID` 的约束住在 **inventory_movements.business_date** 上。
    -- 于是拦截是【间接】的:收货触发器把 arrival_date 抄成流水的 business_date,
    -- 所以【带货的】收货没有日期就会被那条约束挡下 —— 而
    -- **remaining_qty = 0 的收货不产生流水**(emit_batch_receipt_movement 提前返回),
    -- 于是它可以没有日期。线上那些历史无日期行正是这个形状。
    --
    -- 【第一版这里写错了】它说"FIN-32 的 CHECK 对 inbound_batches 的新插入仍然生效"。
    -- 那句话是错的,而它【碰巧通过了】—— 因为带货的那条确实被拒了,只是拒它的
    -- 是另一张表上的约束。一条断言对了结果、说错了原因的注释,下一个人会照着它
    -- 去找一条并不存在的约束。
    --
    -- ★【INV-VAL-1(2026-08-31)改了拒它的【是谁】,而且改对了】★
    --   从前拦截是【间接】的:收货触发器把 arrival_date 抄成流水的 business_date,
    --   于是【带货的】无日期收货撞上流水那条 NOT VALID 约束。
    --   **那个拦截是个巧合,而且漏了一半** —— remaining_qty = 0 的收货不产生流水
    --   (emit_batch_receipt_movement 提前返回),于是它畅通无阻。
    --   D2 造的正是这一半;**线上那 7 张历史无日期行也正是这么来的**。
    --
    --   R9 把"到货日必填"变成一条【直接的、具名的】规矩:
    --   guard_arrival_date_not_cleared 在 BEFORE INSERT 上拒,不管带不带货。
    --   于是这里的判据从"拒绝来自 business_date"改成"拒绝是 ARRIVAL_DATE_REQUIRED"
    --   —— 它是 raise_exception,不再是 check_violation,所以异常分支也跟着改。
    v_msg := NULL;
    BEGIN
        INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, unit, remaining_qty, arrival_date, source_reason_code, source_reason_note)
        VALUES ('FX88-NODATE', mat, sup_1of5, 10, 'kg', 10, NULL, 'other', 'fixture 88 自带数据');
        RAISE EXCEPTION 'FIXTURE 88D1 无日期收货本应被 ARRIVAL_DATE_REQUIRED 拒,却插进去了';
    EXCEPTION WHEN raise_exception THEN
        v_msg := SQLERRM;
    END;
    IF v_msg IS NULL OR position('ARRIVAL_DATE_REQUIRED' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 88D1 拒绝应当是 ARRIVAL_DATE_REQUIRED(R9 的直接守卫),实得:%', COALESCE(v_msg, '(没有拒绝)');
    END IF;
    -- 【零货的那一半现在也拒】—— 这一条是新的,从前它是漏的。
    v_msg := NULL;
    BEGIN
        INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, unit, remaining_qty, arrival_date, source_reason_code, source_reason_note)
        VALUES ('FX88-NODATE0', mat, sup_1of5, 10, 'kg', 0, NULL, 'other', 'fixture 88 自带数据');
        RAISE EXCEPTION 'FIXTURE 88D1 零货的无日期收货【也】应被拒 —— 从前它靠"不产生流水"绕过去,那正是历史无日期行的来源';
    EXCEPTION WHEN raise_exception THEN
        v_msg := SQLERRM;
    END;
    IF v_msg IS NULL OR position('ARRIVAL_DATE_REQUIRED' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 88D1 零货那一条的拒绝也应当是 ARRIVAL_DATE_REQUIRED,实得:%', COALESCE(v_msg, '(没有拒绝)');
    END IF;

    -- D2:【自带数据】造两条无日期收货(remaining_qty = 0,所以不产生流水),
    -- 一条挂采购行【且短交】,一条不挂 —— 然后断言三分类各就各位。
    -- 绝不向线上那些历史行借:重建库里没有它们(README 第 2 条,而这份 fixture
    -- 第一版就是在这里向线上借了,被 gate 抓了个正着)。
    INSERT INTO purchase_order_lines (purchase_order_id, line_no, material_id, quantity, unit)
    VALUES (po_1, 7, mat, 1000, 'kg') RETURNING id INTO l;
    PERFORM set_config('evoltrya.po_status_ctx', '1', true);
    UPDATE purchase_orders SET status = 'receiving' WHERE id = po_1;
    PERFORM set_config('evoltrya.po_status_ctx', '', true);
    -- 无日期 + 挂采购行 + 只收到 100/1000(短 90%)→ 它【带着差异】
    -- ★【这两行是【历史行】,而 R9 之后只能这么造出来】★
    --   到货日现在是【建的时候必填】(ARRIVAL_DATE_REQUIRED,见 D1),所以
    --   一条【新的】无日期收货再也进不来。但线上有 7 张这样的历史行(全部早于
    --   IOD-2-fu1),而 R9 明写【不许回填】—— 它们会一直在。
    --   supplier_receipt_pattern 因此仍然必须把它们分类对,这一臂测的就是那件事。
    --   造法:关掉那条守卫插进去 —— 模拟"这一行比这条规矩还老"。
    --   (守卫只拦【建】与【由有变无】,不拦已经是 NULL 的行继续存在。)
    SET CONSTRAINTS ALL IMMEDIATE;
    ALTER TABLE inbound_batches DISABLE TRIGGER guard_arrival_date_not_cleared;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, unit, remaining_qty,
                                 arrival_date, purchase_order_id, purchase_order_line_id)
    VALUES ('FX88-UND1', mat, sup_1of5, 100, 'kg', 0, NULL, po_1, l);
    -- 无日期 + 不挂采购行 → 它没有差异可言
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, unit, remaining_qty, arrival_date, source_reason_code, source_reason_note)
    VALUES ('FX88-UND2', mat, sup_1of5, 50, 'kg', 0, NULL, 'other', 'fixture 88 自带数据');
    ALTER TABLE inbound_batches ENABLE TRIGGER guard_arrival_date_not_cleared;
    PERFORM set_config('evoltrya.po_status_ctx', '1', true);
    UPDATE purchase_orders SET status = 'closed' WHERE id = po_1;
    PERFORM set_config('evoltrya.po_status_ctx', '', true);

    SELECT * INTO rec FROM supplier_receipt_pattern WHERE supplier_id = sup_1of5;
    IF rec.undated_receipts <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 88D2 两条无日期收货都要数进 undated,实得 %', rec.undated_receipts;
    END IF;
    -- 【最要紧的一句】它们既不进分母,也不算 excluded —— 是第三类
    IF rec.comparable_receipts <> 5 THEN
        RAISE EXCEPTION 'FIXTURE 88D2 无日期的收货不许进分母 —— 分母仍应是 5,实得 %', rec.comparable_receipts;
    END IF;
    IF rec.excluded_receipts <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 88D2 无日期的收货也不算 excluded(那是"有日期但没订量可比")—— 应仍是 C 臂那 1 条,实得 %', rec.excluded_receipts;
    END IF;
    -- 【补上日期会不会改变结论】两条里只有一条带差异
    IF rec.undated_with_discrepancy <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 88D2 两条无日期里只有一条带差异,undated_with_discrepancy 应为 1,实得 %。这个数回答的是"把日期补上会不会改变结论"。', rec.undated_with_discrepancy;
    END IF;
    RAISE NOTICE '88D 无日期收货被 ARRIVAL_DATE_REQUIRED 拒(带货与零货【两半都拒】,R9);历史的两条进 undated(不进分母、不算 excluded),其中 1 条带差异 ✓';

    -- ══════════════════════════════════════════════════════════════════════════
    -- E. 窗口边界:两边各钉一天,【边界当天必须在内】(谓词是 >=)
    -- ══════════════════════════════════════════════════════════════════════════
    INSERT INTO suppliers (code, legal_name, country, counterparty_type)
    VALUES ('FX88-SW', 'fixture 88 supplier window', 'SG', 'goods_supplier') RETURNING id INTO sup_win;
    INSERT INTO purchase_orders (code, supplier_id, order_date, currency, fx_rate, status, approval_status)
    VALUES ('FX88-POW', sup_win, CURRENT_DATE - v_win - 5, 'USD', 1.3, 'receiving', 'approved')
    RETURNING id INTO po_win;

    -- 三条:窗口内一天 / 边界当天 / 窗口外一天,各自一条采购行
    INSERT INTO purchase_order_lines (purchase_order_id, line_no, material_id, quantity, unit)
    VALUES (po_win, 1, mat, 1000, 'kg') RETURNING id INTO l;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, unit, remaining_qty,
                                 arrival_date, purchase_order_id, purchase_order_line_id)
    VALUES ('FX88-WIN', mat, sup_win, 1000, 'kg', 1000, CURRENT_DATE - v_win + 1, po_win, l);

    INSERT INTO purchase_order_lines (purchase_order_id, line_no, material_id, quantity, unit)
    VALUES (po_win, 2, mat, 1000, 'kg') RETURNING id INTO l;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, unit, remaining_qty,
                                 arrival_date, purchase_order_id, purchase_order_line_id)
    VALUES ('FX88-EDGE', mat, sup_win, 1000, 'kg', 1000, CURRENT_DATE - v_win, po_win, l);

    INSERT INTO purchase_order_lines (purchase_order_id, line_no, material_id, quantity, unit)
    VALUES (po_win, 3, mat, 1000, 'kg') RETURNING id INTO l;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, unit, remaining_qty,
                                 arrival_date, purchase_order_id, purchase_order_line_id)
    VALUES ('FX88-OUT', mat, sup_win, 1000, 'kg', 1000, CURRENT_DATE - v_win - 1, po_win, l);

    SELECT * INTO rec FROM supplier_receipt_pattern WHERE supplier_id = sup_win;
    -- 窗口内那条 + 边界当天那条 = 2;窗口外那条不算
    IF rec.comparable_receipts <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 88E 窗口应收下【窗口内】与【边界当天】两条(谓词是 >=),把边界写成 > 会得 1、把窗口外也收进来会得 3。实得 %', rec.comparable_receipts;
    END IF;
    IF rec.window_from <> CURRENT_DATE - v_win THEN
        RAISE EXCEPTION 'FIXTURE 88E window_from 必须等于 CURRENT_DATE − window_days,实得 %', rec.window_from;
    END IF;
    -- 窗口外那条既不在分母里,也【不该】被算成 excluded(它有订量,只是太老了)
    IF rec.excluded_receipts <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 88E 窗口【外】的收货不是"比不了",不许算进 excluded,实得 %', rec.excluded_receipts;
    END IF;
    RAISE NOTICE '88E 窗口边界 −(w−1) / −w / −(w+1) —— 收/收/不收,边界当天在内 ✓';

    -- ══════════════════════════════════════════════════════════════════════════
    -- F. 三个阈值【现读 receiving_settings】—— 事务内改一次,结论必须翻面
    -- ══════════════════════════════════════════════════════════════════════════
    -- A 家的那四条足量收货是 1000/1000。把短交门槛放到 150%(门槛 = 订量 ×
    -- (1 − 1.5) 为负 → 不可能短),再收到一个会让【足量】也算短的值:
    -- 用 grn_short_pct = 0.0001 时门槛≈订量,1000 不小于门槛 → 仍不短。
    -- 所以改用超收那一列做翻面(方向更干净):把 grn_over_pct 收到极小,
    -- A 家那四条 1000/1000 仍等于订量,不会超 —— 换成对 B 家的短交门槛做:
    -- B 家 800/1000 = −20%。把 grn_short_pct 从 5 提到 25 → 门槛 750,
    -- 800 不小于 750 → 【不再算短】。这就是翻面。
    UPDATE receiving_settings SET grn_short_pct = 25;
    SELECT * INTO rec FROM supplier_receipt_pattern WHERE supplier_id = sup_4of5;
    IF rec.short_receipts <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 88F 阈值提到 25%% 之后(门槛 750),800/1000 不再算短 —— short_receipts 应为 0,实得 %。没翻面说明阈值不是现读的。', rec.short_receipts;
    END IF;
    -- 【返回的阈值也要跟着动】屏幕显示的必须就是判出这些计数的那个数
    IF rec.grn_short_pct <> 25 THEN
        RAISE EXCEPTION 'FIXTURE 88F 视图返回的 grn_short_pct 必须是当前值 25,实得 %', rec.grn_short_pct;
    END IF;
    UPDATE receiving_settings SET grn_short_pct = 5;
    SELECT * INTO rec FROM supplier_receipt_pattern WHERE supplier_id = sup_4of5;
    IF rec.short_receipts <> 4 THEN
        RAISE EXCEPTION 'FIXTURE 88F 阈值改回 5%% 之后必须回到 4 次,实得 %', rec.short_receipts;
    END IF;
    RAISE NOTICE '88F 阈值现读:5%%→25%% 让 4 次短变 0 次,改回来又是 4 次;返回值同步 ✓';

    -- ══════════════════════════════════════════════════════════════════════════
    -- G. 没有可比对收货的供应商【仍然出现,值为 0】——
    --    否则页面分不出"没有可比对的收货"与"查不到这家供应商"
    -- ══════════════════════════════════════════════════════════════════════════
    INSERT INTO suppliers (code, legal_name, country, counterparty_type)
    VALUES ('FX88-SN', 'fixture 88 supplier no receipts', 'SG', 'goods_supplier') RETURNING id INTO sup_none;
    SELECT count(*) INTO n FROM supplier_receipt_pattern WHERE supplier_id = sup_none;
    IF n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 88G 一家没有任何收货的供应商必须【出现】(一行,全 0),实得 % 行 —— 整行缺席会让页面把它和"查不到这家供应商"混为一谈', n;
    END IF;
    SELECT * INTO rec FROM supplier_receipt_pattern WHERE supplier_id = sup_none;
    IF rec.comparable_receipts <> 0 OR rec.excluded_receipts <> 0 OR rec.undated_receipts <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 88G 这一行三个计数都应是 0,实得 % / % / %',
            rec.comparable_receipts, rec.excluded_receipts, rec.undated_receipts;
    END IF;
    RAISE NOTICE '88G 没有收货的供应商:出现,且三个计数都是 0(不是整行缺席)✓';

    -- ══════════════════════════════════════════════════════════════════════════
    -- H. 权限:持 purchasing.view 看得见;另一个模块的读者读到【缺席】
    -- ══════════════════════════════════════════════════════════════════════════
    SELECT count(*) INTO n FROM supplier_receipt_pattern;
    IF n < 3 THEN
        RAISE EXCEPTION 'FIXTURE 88H 无效:全权读者只看到 % 行,基线太小,证明不了另一个读者的 0 行是权限', n;
    END IF;
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_hr), true);
    SELECT count(*) INTO n FROM supplier_receipt_pattern;
    IF n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 88H 只持 module.hr.view 的读者必须读到 0 行(订量在采购那道门后面),实得 % 行', n;
    END IF;
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_all), true);
    SELECT count(*) INTO n FROM supplier_receipt_pattern;
    IF n < 3 THEN
        RAISE EXCEPTION 'FIXTURE 88H 换回全权读者应当又看得见,实得 % 行', n;
    END IF;
    RAISE NOTICE '88H 权限:全权可见 % 行,另一个模块读到 0 行(缺席,不是零差异)✓', n;

    -- ══════════════════════════════════════════════════════════════════════════
    -- I. 【数量按采购行汇总,不按收货】—— 一条采购行两次收货,差额只许算一次
    --
    --    【这一臂是写故障注入时才补上的,记下来因为它是一类漏洞的样本】
    --    A 到 H 每一条采购行都只挂【一次】收货 —— 于是"按收货求和"与"按行求和"
    --    给出完全相同的答案,而地面勘察里最要紧的那个陷阱(line_delta_qty 是行级
    --    事实、挂在该行每一条收货上)在这份 fixture 里【无从表现】。注入一个
    --    重复计算的实现,A–H 全绿。**一份把每种情况各测一遍、却让所有情况共享
    --    同一个形状的 fixture,测不到那个形状本身。**
    --    线上已经有一条采购行挂着 2 次收货,所以这不是假想。
    -- ══════════════════════════════════════════════════════════════════════════
    INSERT INTO purchase_order_lines (purchase_order_id, line_no, material_id, quantity, unit)
    VALUES (po_1, 6, mat, 1000, 'kg') RETURNING id INTO l;
    -- 同一条行两次到货:300 + 300 = 600,累计短 400(−40% < −5%)
    PERFORM set_config('evoltrya.po_status_ctx', '1', true);
    UPDATE purchase_orders SET status = 'receiving' WHERE id = po_1;
    PERFORM set_config('evoltrya.po_status_ctx', '', true);
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, unit, remaining_qty,
                                 arrival_date, purchase_order_id, purchase_order_line_id)
    VALUES ('FX88-I1', mat, sup_1of5, 300, 'kg', 300, CURRENT_DATE - 1, po_1, l);
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, unit, remaining_qty,
                                 arrival_date, purchase_order_id, purchase_order_line_id)
    VALUES ('FX88-I2', mat, sup_1of5, 300, 'kg', 300, CURRENT_DATE - 1, po_1, l);
    PERFORM set_config('evoltrya.po_status_ctx', '1', true);
    UPDATE purchase_orders SET status = 'closed' WHERE id = po_1;
    PERFORM set_config('evoltrya.po_status_ctx', '', true);

    SELECT * INTO rec FROM supplier_receipt_pattern WHERE supplier_id = sup_1of5;
    -- 次数按【收货】:原来 1 条短,加上这条行的 2 条收货 = 3
    IF rec.short_receipts <> 3 THEN
        RAISE EXCEPTION 'FIXTURE 88I 次数按收货算:1 + 2 = 3,实得 %', rec.short_receipts;
    END IF;
    -- 行数按【采购行】:原来 1 行短,加这一行 = 2
    IF rec.short_lines <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 88I 行数按采购行算:1 + 1 = 2,实得 %', rec.short_lines;
    END IF;
    -- 【数量:−200 + −400 = −600,不是 −200 + −800 = −1000】
    -- 按收货求和会把这条行的 −400 算两遍,得 −1000。这一个数就是判据。
    IF rec.short_qty <> -600 THEN
        RAISE EXCEPTION 'FIXTURE 88I 数量必须按【采购行】汇总:−200 +(−400)= −600。按收货求和会把两次收货的那条行算两遍得 −1000。实得 %', rec.short_qty;
    END IF;
    RAISE NOTICE '88I 一行两次收货:次数 3、行数 2、数量 −600(不是 −1000)✓';

    -- ══════════════════════════════════════════════════════════════════════════
    -- J. 【分母为 0,而"没能评判的"不为 0】—— 线上 Staff Reimbursements 的形状
    --
    --    【为什么 G 臂不够】G 建的供应商一条收货都没有,三个计数全是 0。
    --    而这一臂建的供应商【有收货】,只是一条也比对不了 —— 于是
    --    comparable_receipts = 0 与 excluded_receipts = 1 【同时成立】。
    --    这正是最容易被读成"记录干净"的那一种:屏幕上没有任何差异,
    --    而真相是"没有任何一条能被检验"。页面据此渲染具名空状态,
    --    所以这两个数必须能同时出现、并且各自正确。
    --    (线上 Staff Reimbursements 就是 0 / 1 / 0,这不是假想的形状。)
    -- ══════════════════════════════════════════════════════════════════════════
    INSERT INTO suppliers (code, legal_name, country, counterparty_type)
    VALUES ('FX88-SX', 'fixture 88 supplier uncheckable', 'SG', 'goods_supplier') RETURNING id INTO sup_x;
    -- 唯一一条收货:有日期、在窗口内、【没挂采购行】
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, unit, remaining_qty, arrival_date, source_reason_code, source_reason_note)
    VALUES ('FX88-XONLY', mat, sup_x, 500, 'kg', 500, CURRENT_DATE - 1, 'other', 'fixture 88 自带数据');

    SELECT count(*) INTO n FROM supplier_receipt_pattern WHERE supplier_id = sup_x;
    IF n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 88J 这家供应商必须出现(一行),实得 % 行', n;
    END IF;
    SELECT * INTO rec FROM supplier_receipt_pattern WHERE supplier_id = sup_x;
    IF rec.comparable_receipts <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 88J 一条也比对不了 —— 分母必须是 0,实得 %', rec.comparable_receipts;
    END IF;
    IF rec.excluded_receipts <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 88J 那一条收货必须【被数进 excluded】,实得 % —— 分母 0 配 excluded 0 会让页面把"没人能检验"渲染成"记录干净"', rec.excluded_receipts;
    END IF;
    -- 【两个 0 不是同一个 0】没有差异,是因为没有可比对的东西 —— 不是因为都合规
    IF rec.receipts_with_any_discrepancy <> 0 OR rec.short_receipts <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 88J 没有可比对的收货就不该有任何差异计数,实得 any=% short=%',
            rec.receipts_with_any_discrepancy, rec.short_receipts;
    END IF;
    RAISE NOTICE '88J 分母 0 而 excluded 1(线上 Staff Reimbursements 的形状):两者同时成立且各自正确 ✓';

    RAISE NOTICE 'FIXTURE 88 全部通过';
END $$;
ROLLBACK;
