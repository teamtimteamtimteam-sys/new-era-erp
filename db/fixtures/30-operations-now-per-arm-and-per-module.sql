-- 30 operations_now:条件成立时那一支【有】这一行,解除后【没有】;
--    只持一个模块的读者,恰好只看见那个模块的支
--
-- OPS-19:十五支;EXEC-1a 起【十七支】(metal_quote_stale / orders_unfulfilled)。
-- 支的规格(含被排除的候选)在 docs/dashboard-arm-inventory.md;【谁要看哪一支】
-- 在 docs/exec-views-plan.md —— 两份文件的分工写在它们各自的结尾。
--
-- 【行情陈旧那一支的边界是【>】不是【>=】,C 臂正面钉住它】解除时把报价日推到
-- 恰好等于阈值(14 天),那一支必须【消失】—— 一个写成 >= 的实现会让它赖着不走,
-- 而"刚好到期"与"已经过期"差一天,在一个六周录两次的序列上就是差一次维护。
--
-- 【为什么值得常设(OPS-18)】首页看板的每个数字都出自这张视图的一支。一支的条件
-- 写错,屏幕上是一个像模像样的数字,不是错误 —— 少算的样子与"处理完了"一模一样,
-- 多算的样子与"还有活"一模一样,两个方向都无声。所以每支都要两头断言:
-- 条件成立【在】,条件解除【不在】。只断言一头,一个恒真或恒假的条件照样通过。
--
-- 【可见性断言必须切数据库角色】(README 第 6 条)。本视图是属主权限,行的裁决在
-- WHERE has_permission(permission) —— has_permission 读 request.jwt.claims,按调用者
-- 解析。fixture 以 postgres 跑,不切角色也能拿到"像是对的"结果;切了角色,断言才
-- 走过与真实读者相同的门(GRANT SELECT TO authenticated 也因此被顺带验证)。
--
-- 【日期自设,不继承】(README 第 4 条)。全部业务行落在 2027,与引导数据、
-- locked_before 之类随月末移动的状态无关;locked_before 在开头显式清空 ——
-- 成本条目的自动应计触发器会过账,不能让它撞上某个未来月份的锁。
BEGIN;
DO $$
DECLARE
    v_all uuid := gen_random_uuid();   -- 持全部六个模块 view 码
    v_inb uuid := gen_random_uuid();   -- 只持 module.inbound.view
    r_all uuid; r_inb uuid;
    v_sup uuid; v_mat uuid; v_ib uuid; v_ar uuid;
    v_mat_asy uuid;   -- ASY-P1:awaiting_assay 专用的物料(只有它声明化验要求)
    v_run uuid; v_po uuid; v_st uuid; v_emp1 uuid; v_emp2 uuid;
    v_lr uuid; v_mc uuid; v_pr uuid; v_bs uuid; v_bl uuid;
    v_je uuid;
    v_ib2 uuid; v_ib3 uuid; v_ib4 uuid; v_ar3 uuid;
    v_ob uuid; v_ob2 uuid; v_cust uuid; v_sr uuid; v_inv uuid;
    v_ccy text;
    v_mp uuid; v_cust2 uuid; v_so uuid; v_mat2 uuid;   -- EXEC-1a:两支新臂自带的数据
    v_sup2 uuid; v_sup3 uuid; v_sc uuid; v_wo uuid; v_wo2 uuid; v_ibw uuid;  -- EXEC-3a:四支
    v_res_wo jsonb; v_detail text; v_runwo uuid;
    v_types text[];
    v_n int;
    -- EXEC-1a 起十七支;EXEC-3a 起【二十一支】(资质两支 + 工单两支)
    v_expected text[] := ARRAY['allocation_stale','ap_over_90','ar_over_90',
        'assay_unapplied','awaiting_assay','bank_unmatched','batch_unpriced',
        'claim_pending','fx_rate_gap','invoice_overdue','leave_pending','metal_quote_stale',
        'orders_unfulfilled','output_unsold_aging','po_awaiting_receipt',
        'qualification_expiring','qualification_missing','review_submitted',
        'stocktake_open','work_order_overdue','work_order_variance_beyond'];
    -- 只持 module.inbound.view 的读者应看见的三支(同源 batch_assay_status,互斥)
    v_inbound_only text[] := ARRAY['assay_unapplied','awaiting_assay','batch_unpriced'];
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    -- 成本条目会触发自动应计过账 —— 锁不能挡住 fixture 自己的日期(回滚,无副作用)
    UPDATE finance_settings SET locked_before = NULL;

    -- ── 角色 ────────────────────────────────────────────────────────────────
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-30-all', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code)
    -- 【为什么带 data.view_prices】invoice_overdue / ar_over_90 / ap_over_90 三支的
    -- 行【存在性】挂在被它遮蔽的金额列上(见 docs/dashboard-arm-inventory.md 的隐患一节):
    -- 没有它,这三支会静默少报而不是显示「受限」。live 上任何持 finance 的角色都同时
    -- 持它(常设决定 1),所以这里照着现实配。
    -- PUR-2:C 臂改走 close_purchase_order 解除 po_awaiting_receipt(状态不再能经
    -- 直连 UPDATE 改动),而关单要 module.purchasing.edit —— 加这个码不影响任何一支
    -- (支挂的都是 .view),arm B 用的也是另一个角色。
    SELECT r_all, unnest(ARRAY['module.inbound.view','module.processing.view',
        'module.purchasing.view','module.purchasing.edit','module.stocktakes.view','module.hr.view',
        'module.output.view','module.finance.view','data.view_prices',
        -- EXEC-1a:两支新臂各自的门
        'module.pricing.view','module.sales.view',
        -- EXEC-3a:资质两支挂 suppliers,工单两支挂 processing
        'module.suppliers.view','module.processing.edit',
        -- reprice_inbound_batch 要 inbound.edit(给投料批定价是进料侧的动作)
        'module.inbound.edit',
        -- set_sales_order_status 要 module.sales.edit(确认订单是一次销售行为)——
        -- 与上面 purchasing.edit 同一种情形:加这个码不影响任何一支(支挂的都是 .view)
        'module.sales.edit']);
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-30-inb', 'f', 'f', true) RETURNING id INTO r_inb;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_inb, 'module.inbound.view');
    INSERT INTO user_roles (user_id, role_id) VALUES (v_all, r_all), (v_inb, r_inb);

    -- 【PROC-WIRE-1B-ii:建数据这一段也要有身份】sales_records 的可售性断言
    -- 现在【看不见就按名拒】(SALE_CANNOT_ESTABLISH_SALEABILITY)。此前这一段
    -- 以 postgres、且【一个 claim 都没设】跑,于是 has_permission 一律为假。
    -- **各臂随后仍然各自 set_config,这一句只管建数据那一段。**
    -- (r_all 持 module.sales.edit —— 白名单三把钥匙之一。)
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_all), true);

    -- ── 九支的数据,每支一个等待中的条件 ─────────────────────────────────────
    INSERT INTO suppliers (code, legal_name, country, counterparty_type)
    VALUES ('ZZFIX30-S', 'fixture 30 supplier', 'SG', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZFIX30-M', 'fixture 30 material', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO v_mat;
    -- 【ASY-P1:awaiting_assay 从"零化验"改成"要求的金属没验齐"】
    -- 那一支现在只在【物料声明了化验要求】时才可能亮。所以给它一个【专用】物料:
    -- v_mat 上不声明任何要求 —— 否则 IB / IB3 / IB4 那几个批次会一起点亮这一支,
    -- 而本 fixture 的契约是"每支恰好一件"。
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZFIX30-M-ASY', 'fixture 30 material (assay required)', 'battery_material', true, 'black_mass', 'end_of_life')
    RETURNING id INTO v_mat_asy;
    INSERT INTO material_required_metals (material_id, metal) VALUES (v_mat_asy, 'cu');

    -- 1 assay_unapplied:化验已录、applied_at 为空
    -- arrival_date 必填不是本支的条件,是 FIN-32:进料触发器把它抄成收货台账行的
    -- business_date,而新台账行的 business_date 有 CHECK(空着整个 INSERT 被拒)。
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, arrival_date, source_reason_code, source_reason_note)
    VALUES ('ZZFIX30-IB', v_mat, v_sup, 10, 10, '2027-01-08', 'other', 'fixture 30 自带数据') RETURNING id INTO v_ib;
    INSERT INTO assay_results (code, inbound_batch_id, assay_date, weight_basis, result_party)
    VALUES ('ZZFIX30-AR', v_ib, '2027-01-10', 'as_received', 'ours') RETURNING id INTO v_ar;

    -- 2 allocation_stale:分摊时点(2027-01-01)早于成本变动时点(2027-02-01)
    -- FIN-36:allocation_basis 不再有 schema 默认值 —— 直插就得自己选。
    -- 'metal_value' 是这些 fixture 在 FIN-36 之前拿到的那个值,语义不变。
    -- 【PROC-SUPPORT-1:工序必填,于是【直插】的加工单也要说出工序】
    -- 表上那条 NOT VALID 的 CHECK 对【任何写入者】都成立,包括这一句。
    -- 选 manual_disassembly 是因为它是转化型:本臂测的是分摊与看板臂,
    -- 换一道状态改变型工序会顺带改变这张单的语义。
    INSERT INTO processing_runs (code, status, allocated_at, allocation_basis, operation_type_code)
    VALUES ('ZZFIX30-RUN', 'committed', '2027-01-01', 'metal_value', 'manual_disassembly') RETURNING id INTO v_run;
    INSERT INTO processing_cost_entries (run_id, cost_type, amount_base, created_at, updated_at)
    VALUES (v_run, 'electricity', 100, '2027-02-01', '2027-02-01');

    -- 3 po_awaiting_receipt:已确认
    -- FIN-35:fx_rate 不再有默认值 —— 直插就得自己给。本位币恒 1(fx_rate_asof
    -- 对本位币直接返回 1,不查牌价表),所以这里显式写 1 是【记录事实】,不是兜底。
    INSERT INTO purchase_orders (code, supplier_id, order_date, currency, fx_rate, status)
    VALUES ('ZZFIX30-PO', v_sup, '2027-01-15', v_ccy, 1, 'confirmed') RETURNING id INTO v_po;

    -- 4 stocktake_open:默认即 open
    INSERT INTO stocktakes (code) VALUES ('ZZFIX30-ST') RETURNING id INTO v_st;

    -- 5/6/7 HR 三支
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date)
    VALUES ('ZZFIX30-E1', 'fixture 30 employee', 'full_time', 'office', '2027-01-01')
    RETURNING id INTO v_emp1;
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date)
    VALUES ('ZZFIX30-E2', 'fixture 30 reviewer', 'full_time', 'office', '2027-01-01')
    RETURNING id INTO v_emp2;
    INSERT INTO leave_requests (code, employee_id, leave_type_code, start_date, end_date, days)
    VALUES ('ZZFIX30-LR', v_emp1, 'sick', '2027-06-01', '2027-06-01', 1) RETURNING id INTO v_lr;
    INSERT INTO medical_claims (code, employee_id, claim_date, claim_year, amount_sgd)
    VALUES ('ZZFIX30-MC', v_emp1, '2027-04-10', 2027, 50) RETURNING id INTO v_mc;
    -- 试用期评估(annual 要挂 cycle_id —— cycle_shape);submitted 要求评级 + 评语 +
    -- 试用期结论(submitted_shape / probation_outcome_shape 的闸门都在这一档)
    INSERT INTO performance_reviews (employee_id, reviewer_employee_id, review_type,
        period_start, period_end, status, submitted_at, rating_code, summary_text, probation_outcome)
    VALUES (v_emp1, v_emp2, 'probation', '2027-01-01', '2027-06-30', 'submitted', '2027-07-05',
            'MEETS', 'fixture 30', 'confirm')
    RETURNING id INTO v_pr;

    -- 8 fx_rate_gap:2027-03-03(周三,工作日)有 USD 过账、无任何一侧牌价。
    -- 【未来日期是有意的】本支限 rate_date >= CURRENT_DATE - 45,未来日期恒在界内,
    -- fixture 便不依赖"跑在哪一天"。
    INSERT INTO journal_entries (code, entry_date, memo, source_type)
    VALUES ('ZZFIX30-JE', '2027-03-03', 'fixture 30 fx gap', 'manual') RETURNING id INTO v_je;
    INSERT INTO journal_lines (entry_id, account_id, debit, credit, currency, amount_ccy, fx_rate)
    SELECT v_je, a.id, x.d, x.c, 'USD', 100, 1.3
    FROM (VALUES ('1010', 130.0, 0.0), ('4000', 0.0, 130.0)) x(code, d, c)
    JOIN accounts a ON a.code = x.code;

    -- 9 bank_unmatched:导入的报表行,未匹配
    INSERT INTO bank_statements (code, bank_account_code, currency, period_start, period_end,
        opening_balance, closing_balance)
    VALUES ('ZZFIX30-BS', '1000', v_ccy, '2027-05-01', '2027-05-31', 0, 10) RETURNING id INTO v_bs;
    INSERT INTO bank_statement_lines (statement_id, line_no, line_date, amount)
    VALUES (v_bs, 1, '2027-05-05', 10) RETURNING id INTO v_bl;

    -- ── OPS-19 追加的六支 ────────────────────────────────────────────────────
    -- 【这几支的日期必须相对 CURRENT_DATE】账龄档与 60 天阈值都是拿 CURRENT_DATE 减出来的,
    -- 2027 那些【未来】日期会落进 b0_30 而不是 b90_plus。相对日期同时满足 README 第 4 条:
    -- 不继承任何时点状态,自己声明"多久以前"。

    -- 10 awaiting_assay:物料要求 cu、而这个批次一份化验都没有(与 assay_unapplied 互斥)
    -- ASY-P1 起用的是【声明了要求的那个物料】v_mat_asy;remaining_qty > 0,
    -- 否则它取不到样、按设计退出这一支。
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, arrival_date, source_reason_code, source_reason_note)
    VALUES ('ZZFIX30-IB2', v_mat_asy, v_sup, 10, 10, '2027-01-09', 'other', 'fixture 30 自带数据') RETURNING id INTO v_ib2;

    -- 11 batch_unpriced:未计价,且化验【已执行】—— 于是只落进 batch_unpriced 这一支
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty,
        arrival_date, pricing_status, source_reason_code, source_reason_note)
    VALUES ('ZZFIX30-IB3', v_mat, v_sup, 10, 10, '2027-01-11', 'unpriced', 'other', 'fixture 30 自带数据') RETURNING id INTO v_ib3;
    INSERT INTO assay_results (code, inbound_batch_id, assay_date, applied_at, weight_basis, result_party)
    VALUES ('ZZFIX30-AR3', v_ib3, '2027-01-12', now(), 'as_received', 'ours') RETURNING id INTO v_ar3;

    -- 12 ap_over_90:有单价的进料单,到货 200 天前(化验已执行,不污染进料三支)
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty,
        arrival_date, unit_price, source_reason_code, source_reason_note)
    VALUES ('ZZFIX30-IB4', v_mat, v_sup, 10, 10, CURRENT_DATE - 200, 100, 'other', 'fixture 30 自带数据') RETURNING id INTO v_ib4;
    INSERT INTO assay_results (code, inbound_batch_id, assay_date, applied_at, weight_basis, result_party)
    VALUES ('ZZFIX30-AR4', v_ib4, CURRENT_DATE - 200, now(), 'as_received', 'ours');

    -- 13 ar_over_90 + 14 invoice_overdue:一笔 200 天前的销售,未收款;
    -- 发票引用同一条销售记录 —— 两支同源不同粒度(单据 vs 销售事实),都该亮。
    INSERT INTO customers (code, legal_name, country)
    VALUES ('ZZFIX30-C', 'fixture 30 customer', 'SG') RETURNING id INTO v_cust;
    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, output_date)
    VALUES ('ZZFIX30-OB', v_mat, 100, 100, CURRENT_DATE - 10) RETURNING id INTO v_ob;
    INSERT INTO sales_records (output_batch_id, customer_id, quantity, unit_price,
        currency, fx_rate, amount_base, sale_date)
    VALUES (v_ob, v_cust, 10, 50, v_ccy, 1, 500, CURRENT_DATE - 200) RETURNING id INTO v_sr;
    INSERT INTO invoices (code, customer_id, issue_date, due_date, payment_terms_days,
        currency, subtotal_base, total_base, bill_to_snapshot)
    VALUES ('ZZFIX30-INV', v_cust, CURRENT_DATE - 200, CURRENT_DATE - 170, 30,
        v_ccy, 500, 500, '{}'::jsonb) RETURNING id INTO v_inv;
    INSERT INTO invoice_lines (invoice_id, sales_record_id, line_no, description,
        quantity, unit, unit_price, amount_base)
    VALUES (v_inv, v_sr, 1, 'fixture 30 line', 10, 'kg', 50, 500);

    -- 15 output_unsold_aging:成品压了 90 天还没卖完(阈值 60 —— 提议值,见规格文件)
    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, output_date)
    VALUES ('ZZFIX30-OB2', v_mat, 40, 40, CURRENT_DATE - 90) RETURNING id INTO v_ob2;

    -- ── EXEC-1a:两支新臂的条件 ──────────────────────────────────────────────
    -- 【行情陈旧】阈值现读 pricing_settings。这里把阈值显式设成 14(README 第 5 条:
    -- 前提要自己设,哪怕默认值恰好合用 —— 它是运营改得动的一列)。
    -- 报价日期落在【阈值 + 1 天】之前 —— 也就是刚刚越过线。
    UPDATE pricing_settings SET metal_quote_stale_days = 14;
    -- 【这一支读的是【共享的】参考数据,所以前提必须自己设,不能继承】
    -- metal_prices 是引导/运营数据,线上七个金属的最新报价都停在 2026-07-30 ——
    -- 也就是说【不动它,这一支在这份 fixture 里天然就是亮的】,而本 fixture 的契约
    -- 是"每支恰好一件、数据各自拥有"。所以先把所有金属推到今天(= 不旧),
    -- 再让【一个】金属越线。这正是 README 第 5 条:要什么就自己设,不要继承。
    -- (整个事务回滚,线上的报价一个字不动。)
    -- 软删掉既有的全部报价(唯一约束是 (metal, price_date, price_index),
    -- 把它们全推到同一天会撞上它;而这一支的判据本来就只看未删的行)。
    UPDATE metal_prices SET deleted_at = now() WHERE deleted_at IS NULL;
    -- 除了要越线的那个金属,其余每个金属给一条【今天】的报价 —— 于是它们都不旧。
    INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date, source)
    SELECT m, 1000, CURRENT_DATE, 'broker_quote'
      FROM unnest(ARRAY['co','li','mn','cu','al','fe']) m;
    INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date, source)
    VALUES ('ni', 18000, CURRENT_DATE - 15, 'broker_quote') RETURNING id INTO v_mp;

    -- 【未履约订单】一张 confirmed 的单 —— 答应了,一件没发。
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code) VALUES ('FIXT-M30WO','f30 wo material', 'battery_material', true, 'black_mass', 'end_of_life')
        RETURNING id INTO v_mat2;
    INSERT INTO customers (code, legal_name, country)
    VALUES ('FIXT-C30WO', 'fixture 30 order customer', 'SG') RETURNING id INTO v_cust2;
    -- 【先 draft、加行、再确认】—— SO-1b 的冻结守卫拒绝往已确认的订单上直插行
    -- (guard_sales_order_line_confirmed_immutable)。走真实顺序,而不是绕过守卫:
    -- 绕过去也造得出这一行,但那样造出来的单据在现实里不存在。
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES (next_sales_order_code(DATE '2027-03-05'), v_cust2, DATE '2027-03-05', 'USD', 1.25)
    RETURNING id INTO v_so;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (v_so, 1, v_mat2, 10, 10);
    -- 【必须走 set_sales_order_status,直改会被 SO-1b 的守卫拒】
    -- guard_sales_order_confirmed_immutable 只认那条真路径 —— 实测直改当场被拒,
    -- 而那是对的:确认是一次状态转换,不是一个可以顺手写的字段。
    -- 它 require_permission('module.sales.edit'),所以这里先认人(下面那行 claims)。
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_all), true);
    PERFORM set_sales_order_status(v_so, 'confirmed');

    -- ── EXEC-3a:四支的条件 ──────────────────────────────────────────────────
    -- 【资质两支要先接管共享数据】线上已经有供应商与证书,而本 fixture 的契约是
    -- "每支恰好一件、数据各自拥有"(README 第 5 条)。先把既有的软删掉,
    -- 再造【恰好一家没有证的】与【恰好一张快到期的】。整个事务回滚,线上不动。
    UPDATE supplier_compliance SET deleted_at = now() WHERE deleted_at IS NULL;
    UPDATE suppliers SET deleted_at = now() WHERE deleted_at IS NULL;

    -- 一家有证、而证快到期(basel 的提前量是 90 天 → 80 天后到期即命中)
    INSERT INTO suppliers (code, legal_name, country, counterparty_type)
    VALUES ('FIXT-S30A', 'fixture 30 expiring', 'SG', 'goods_supplier') RETURNING id INTO v_sup2;
    INSERT INTO supplier_compliance (supplier_id, cert_type_code, cert_no, valid_from, valid_until)
    VALUES (v_sup2, 'basel', 'F30-A', CURRENT_DATE - 400, CURRENT_DATE + 80)
    RETURNING id INTO v_sc;
    -- 一家【一张证都没有】
    -- 【status 显式设 active】CMP-2 的 qualification_missing 谓词里有
    -- `s.status = 'active'` —— 不设就落到列默认值上,那一支静默不响,
    -- 而"没响"与"这一支坏了"在屏幕上一模一样(README 第 5 条:前提要自己设)。
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('FIXT-S30B', 'fixture 30 no cert', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup3;
    -- 上面那家有证的,不该同时命中"缺席"那一支 —— 两支互斥,A 臂的"每支恰好一件"
    -- 就是这一点的断言。

    -- 工单:一张逾期的(放行 + 排产日在昨天),一张差异超阈的
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code) VALUES ('FIXT-M30WO2','f30 wo raw', 'battery_material', true, 'black_mass', 'end_of_life')
        RETURNING id INTO v_mat2;
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_all), true);
    v_types := NULL;  -- (占位,避免下面 SELECT INTO 前的未初始化告警)
    INSERT INTO work_orders (code, status, scheduled_date, notes)
    VALUES (next_work_order_code(CURRENT_DATE), 'released', CURRENT_DATE - 1, 'f30 overdue')
    RETURNING id INTO v_wo;
    INSERT INTO work_order_lines (work_order_id, material_id, planned_qty)
    VALUES (v_wo, v_mat2, 100);

    -- 差异那一支:另一张单,吃掉 200 / 计划 100(阈值 10% → 线在 110)
    UPDATE processing_settings SET wo_input_overrun_pct = 10, wo_output_shortfall_pct = 10;
    -- 【这一家要有证,而且是远期的】否则它会同时命中 qualification_missing,
    -- 那一支就变成两行,而本 fixture 的契约是"每支恰好一件"。
    -- 证的到期日推到窗口之外(basel 提前量 90 天),所以也不命中到期那一支。
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('FIXT-S30C', 'fixture 30 wo supplier', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup3;
    INSERT INTO supplier_compliance (supplier_id, cert_type_code, cert_no, valid_from, valid_until)
    VALUES (v_sup3, 'basel', 'F30-C', CURRENT_DATE - 10, CURRENT_DATE + 300);
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note)
    VALUES ('FIXT-IB30WO', v_mat2, v_sup3, 500, 500, 'kg', CURRENT_DATE, 'other', 'fixture 30 自带数据') RETURNING id INTO v_ibw;
    PERFORM reprice_inbound_batch(v_ibw, 1, 'SGD', NULL, 'f30 price');
    -- 【这一批要把别人的支让开】本 fixture 的契约是"每支恰好一件",而一张新的
    -- 进料批天然会点亮 awaiting_assay(没有化验)。所以给它一份【已应用】的化验:
    -- 它既不欠化验、也没有未应用的化验。
    -- 实测教训:第一版没有这几行,gate 报 23 行而不是 21,多出来的正是
    -- allocation_stale 与 awaiting_assay —— **自带数据的意思不只是"自己造",
    -- 还包括"造出来的东西不要点亮别人的灯"。**
    INSERT INTO assay_results (code, inbound_batch_id, assay_date, applied_at, weight_basis, result_party)
    VALUES ('ZZFIX30-ARWO', v_ibw, CURRENT_DATE, now(), 'as_received', 'ours');
    UPDATE inbound_batches SET pricing_status = 'final' WHERE id = v_ibw;
    v_res_wo := create_work_order(
        jsonb_build_array(jsonb_build_object('material_id', v_mat2, 'planned_qty', 100)),
        NULL, CURRENT_DATE + 5, 'f30 variance');
    v_wo2 := (v_res_wo->>'work_order_id')::uuid;
    PERFORM release_work_order(v_wo2);
    -- PROC-3:这一支要投料,所以它的电池料批次得带一条【可投料】的安全状态。
    -- 【为什么是一条带 JOIN 的 SELECT,而不是逐个批次写死】本支里哪些批次【吃】
    -- 状态轴,由 material_kinds 回答 —— 实测 ewaste 可加工却【没有】状态轴,
    -- 所以"可加工"并不蕴含"有状态轴"。而没有状态轴的批次插安全状态会被
    -- PROC-2c 的适用性守卫按名拒,所以这个过滤不是优化,是正确性。
    -- 【它出现在每一次投料之前,而不是只在开头一次】批次是各臂【边跑边造】的,
    -- 开头那一次覆盖不到后面才出生的批次。NOT EXISTS 让它重复执行也不撞主键。
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    SELECT ib.id, 'discharged_verified'
      FROM inbound_batches ib
      JOIN materials m       ON m.id   = ib.material_id
      JOIN material_kinds mk ON mk.code = m.kind_code
     WHERE mk.has_condition_axes
       AND NOT EXISTS (SELECT 1 FROM inbound_batch_safety_states s
                        WHERE s.inbound_batch_id = ib.id);
    v_runwo := commit_processing_run(CURRENT_DATE, 'f30 overrun', 20,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ibw, 'quantity_consumed', 200)),
        jsonb_build_array(jsonb_build_object('material_id', v_mat2, 'quantity', 180)), 'weight', v_wo2, NULL, 'manual_disassembly');
    -- 同一条理由:一张【从没分摊过】的加工单会点亮 allocation_stale。
    -- 这一支要测的是工单差异,不是分摊欠账 —— 所以把分摊时点盖上,让那盏灯归位。
    UPDATE processing_runs SET allocated_at = now() WHERE id = v_runwo;

    -- ══════════ A. 条件成立:十五支【每支都在】══════════════════════════════
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_all), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT COALESCE(array_agg(DISTINCT item_type ORDER BY item_type), '{}') INTO v_types
      FROM operations_now;
    RESET ROLE;

    IF v_types <> v_expected THEN
        RAISE EXCEPTION 'FIXTURE 30A 失败:二十一支条件全部成立,应恰好看见 %,实得 % —— 少一支是条件恒假(那块牌子永远 0),多一支是支列表变了而 fixture 没跟上(规格见 docs/dashboard-arm-inventory.md)',
            v_expected::text, v_types::text;
    END IF;

    -- 每支恰好一件(本 fixture 的库里只有自己的数据 —— fixtures 各自回滚,互不遗留)
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_all), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM operations_now;
    RESET ROLE;
    IF v_n <> 21 THEN
        -- 【把【哪一支】多了直接说出来】原来这句只说"某支数了两遍",于是每次
        -- 都要再跑一轮去找是哪一支 —— 而在慢链路上那一轮要八分钟。
        -- 一条说得出主语的失败信息,值它自己那几行代码。
        PERFORM set_config('request.jwt.claims',
            format('{"sub":"%s","role":"authenticated"}', v_all), true);
        EXECUTE 'SET LOCAL ROLE authenticated';
        SELECT string_agg(item_type || '=' || c, ' ' ORDER BY item_type) INTO v_detail
          FROM (SELECT item_type, count(*) c FROM operations_now GROUP BY 1 HAVING count(*) > 1) q;
        RESET ROLE;
        RAISE EXCEPTION 'FIXTURE 30A 失败:应恰好 21 行(每支 1 件),实得 % 行 —— 多出来的是:%(进料三支互斥、AR 与发票同源不同粒度)',
            v_n, COALESCE(v_detail, '(没有任何一支超过一行 —— 那么是支数对不上,看上一条断言)');
    END IF;

    -- ══════════ B. 只持 inbound 的读者:恰好只看见 inbound 的三支 ════════════
    -- 其余十二支此刻条件【全部成立】—— 缺席只能来自权限,不能来自碰巧没数据。
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_inb), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT COALESCE(array_agg(DISTINCT item_type ORDER BY item_type), '{}') INTO v_types
      FROM operations_now;
    RESET ROLE;

    IF v_types <> v_inbound_only THEN
        RAISE EXCEPTION 'FIXTURE 30B 失败:只持 module.inbound.view 应恰好看见 %,实得 % —— 多的支是权限裁决漏了(0 会冒充成一个真数字),少的支是把自己模块的也裁掉了',
            v_inbound_only::text, v_types::text;
    END IF;

    -- ══════════ C. 条件逐支解除:九支【每支都不在】═══════════════════════════
    -- EXEC-3a:四支的解除。
    -- 资质到期 → 把证书续到窗口之外(80 天 → 200 天,basel 的提前量是 90)
    UPDATE supplier_compliance SET valid_until = CURRENT_DATE + 200 WHERE id = v_sc;
    -- 一张证都没有 → 给那两家各补一张(缺席那一支的条件是"一张都没有")
    INSERT INTO supplier_compliance (supplier_id, cert_type_code, cert_no, valid_from, valid_until)
    SELECT s.id, 'basel', 'F30-FILL', CURRENT_DATE - 10, CURRENT_DATE + 200
      FROM suppliers s
     WHERE s.deleted_at IS NULL
       AND NOT EXISTS (SELECT 1 FROM supplier_compliance sc
                        WHERE sc.supplier_id = s.id AND sc.deleted_at IS NULL);
    -- 工单逾期 → 把排产日推到将来(【不是】清空:清空也会让它消失,但那测的是
    -- 另一条规则,而这一支要解除的是"过期了"这件事)
    UPDATE work_orders SET scheduled_date = CURRENT_DATE + 30 WHERE id = v_wo;
    -- 差异超阈 → 把阈值抬高到 200%(数据不动,只动配置 —— 顺带再证一次它是现读的)
    UPDATE processing_settings SET wo_input_overrun_pct = 200, wo_output_shortfall_pct = 200;
    -- EXEC-1a:两支的解除。
    -- 【行情陈旧:把报价日期推到阈值【之内】—— 恰好 14 天,而判据是 > 14】
    -- 这一改同时验了边界:14 天不算旧,15 天算。一个写成 >= 的实现在这里当场红。
    UPDATE metal_prices SET price_date = CURRENT_DATE - 14 WHERE id = v_mp;
    UPDATE assay_results SET applied_at = now() WHERE id = v_ar;
    UPDATE processing_runs SET allocated_at = '2027-03-01' WHERE id = v_run;  -- 晚于成本变动
    -- 【claims 要先切回全权限那个人】B 臂把它换成了只持 inbound 的读者,
    -- 而 close_purchase_order 要 module.purchasing.edit —— 不切回来就是
    -- PERMISSION_DENIED,而那与本臂要测的东西毫无关系。
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_all), true);
    -- PUR-2:状态不再能经一条直连的 UPDATE 改动(guard_po_amendable)。
    -- 【改成走真正的那条路】—— 现实里这一支就是被"关单"清掉的,
    -- 用 close_purchase_order 反而比原来更贴近它要模拟的事。
    -- 【未履约订单的解除:取消这张单】—— 放在 claims 切回来【之后】,
    -- 与 close_purchase_order 同一个理由:它也要 module.sales.edit。
    -- 【不能直改状态】SO-1b 的守卫只认 set_sales_order_status,而它也【不接受】
    -- confirmed → shipped(实测 SO_STATUS_NOT_EDITABLE|confirmed|shipped):
    -- 发货不是一次手动的状态转换,它是 ship_order 的后果。这一支要测的是
    -- "这张单还欠不欠货",取消同样让它不再欠 —— 而且走的是真路径。
    PERFORM set_sales_order_status(v_so, 'cancelled', 'fixture 30 解除未履约');
    PERFORM close_purchase_order(v_po, 'fixture 30:解除 po_awaiting_receipt');
    UPDATE stocktakes SET status = 'cancelled' WHERE id = v_st;
    UPDATE leave_requests SET status = 'approved' WHERE id = v_lr;
    UPDATE medical_claims SET status = 'approved' WHERE id = v_mc;
    UPDATE performance_reviews SET status = 'approved' WHERE id = v_pr;
    INSERT INTO fx_rates (currency, rate_date, rate_type, rate_sgd_per_unit)
    SELECT 'USD', '2027-03-03', t, 1.3 FROM unnest(ARRAY['tt_buy','tt_sell','mid']) t;
    UPDATE bank_statement_lines SET match_status = 'ignored' WHERE id = v_bl;
    -- OPS-19 六支的解除。销售记录【不可改也不可删】(SALE_IMMUTABLE),所以 AR 与
    -- 发票只能靠【收款核销】清掉 —— 那本来就是它们在现实里消失的唯一方式,一笔全额
    -- 收款同时结清 ar_over_90 与 invoice_overdue(发票的已结额就是从销售记录推的)。
    -- ASY-P1:解除的条件不再是"有一份化验",而是【要求的那种金属被覆盖了】——
    -- 所以这份化验必须真的带着 cu 那一行,否则它解除不了(这正是新那一支的重点:
    -- 一份不含所需金属的化验,不算把那件事做完)。
    INSERT INTO assay_results (code, inbound_batch_id, assay_date, applied_at, weight_basis, result_party)
    VALUES ('ZZFIX30-AR2', v_ib2, '2027-01-20', now(), 'as_received', 'ours') RETURNING id INTO v_ar;
    INSERT INTO assay_result_metals (assay_result_id, metal, content_pct)
    VALUES (v_ar, 'cu', 10);                                          -- awaiting_assay 解除
    UPDATE inbound_batches SET pricing_status = 'final' WHERE id = v_ib3;   -- batch_unpriced
    UPDATE output_batches SET output_date = CURRENT_DATE - 1 WHERE id = v_ob2;  -- 不再滞销
    -- payments_counterparty_shape:in 必须带 customer_id,out 必须带 supplier_id
    INSERT INTO payments (code, direction, counterparty_type, customer_id, amount_ccy, currency,
        fx_rate, amount_base, bank_account_code, payment_date)
    VALUES ('ZZFIX30-PAY-IN', 'in', 'customer', v_cust, 500, v_ccy, 1, 500, '1000', CURRENT_DATE)
    RETURNING id INTO v_je;
    INSERT INTO payment_allocations (payment_id, sales_record_id, allocated_base, allocated_ccy, allocated_pay)
    VALUES (v_je, v_sr, 500, 500, 500);                              -- ar_over_90 + invoice_overdue
    INSERT INTO payments (code, direction, counterparty_type, supplier_id, amount_ccy, currency,
        fx_rate, amount_base, bank_account_code, payment_date)
    VALUES ('ZZFIX30-PAY-OUT', 'out', 'supplier', v_sup, 1000, v_ccy, 1, 1000, '1000', CURRENT_DATE)
    RETURNING id INTO v_je;
    INSERT INTO payment_allocations (payment_id, inbound_batch_id, allocated_base, allocated_ccy, allocated_pay)
    VALUES (v_je, v_ib4, 1000, 1000, 1000);                          -- ap_over_90

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_all), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM operations_now;
    RESET ROLE;

    IF v_n <> 0 THEN
        PERFORM set_config('request.jwt.claims',
            format('{"sub":"%s","role":"authenticated"}', v_all), true);
        EXECUTE 'SET LOCAL ROLE authenticated';
        SELECT COALESCE(array_agg(DISTINCT item_type ORDER BY item_type), '{}') INTO v_types
          FROM operations_now;
        RESET ROLE;
        RAISE EXCEPTION 'FIXTURE 30C 失败:二十一个条件都已解除,应 0 行,实得 % 行(%)—— 赖着不走的支就是"处理完了牌子还亮着"的那一支',
            v_n, v_types::text;
    END IF;
END $$;
ROLLBACK;
