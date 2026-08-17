-- 18 分摊差额法:逐批拆分、叠加错修复、COGS 补差、幂等、注销→5200、
--    重定价挂过期旗、锁月里的销售改成本记当期
--
-- 为什么值得常设(FIN-24):这是成本链最后一个已知的正确性洞,坐在立账公理上 ——
-- 全额重挂重述库存而从不重述已过账 COGS,卖掉份额的价差留在 1220;与 reprice
-- 的 5000 停车叠加则重复计数、1200 变负。账面全程平,错悄悄躺在资产负债表里。
--
-- 七臂:
--   A 一炉两批、卖出程度不同 → 差额【逐批】按各自处置比例拆(炉级比例必错);
--   B 【本切的全部理由】100kg@1 全耗 → 重定价 2 → 重分摊:
--     1220=200,5000=0(不是叠加的 100),1200=0(不是 −100)。
--     对旧实现故障注入,这一臂必须当场红;
--   C 已售已挂 COGS 的份额 → 差额进 5000(COGS 补差),且过期旗随重跑清除;
--   D 同状态第二次跑:不过账(幂等靠算术);
--   E 注销批的份额 → 5200,不进 5000(Tim 的裁定:注销总额是运营信号);
--   F 【F2】重定价输入批,成本条目一根手指没碰 → 耗它的加工单 is_stale = true;
--   G 售出月已锁,之后改成本 → 差额分录记【当期】,过账成功(锁挡的是写回锁内,
--     不挡当期改正);
--   H 【metal_value 基准】数值上分开逐批与炉级:weight 基准下两者代数恒等
--     (A 臂的注有推导),metal_value 的份额是价值权重,恒等式破了 ——
--     A 100kg 含 30kg 镍(份额 0.5)售 80%,B 300kg 含 30kg(份额 0.5)售 10%,
--     差额 100:逐批 5000 = 100×(0.5×0.8 + 0.5×0.1) = 45.00;
--     炉级 = 100×110/400 = 27.50。将来谁把逐批"简化"回炉级,这里当场红。
-- FIN-36:commit_processing_run 多了一个【必填】的分摊基准参数。
-- 这里一律显式传 'metal_value' —— 那正是本 fixture 在 FIN-36 之前从 schema
-- 默认值拿到的值,所以语义一字未变,只是不再有人替它做这个选择。
BEGIN;
DO $$
DECLARE
    v_uid uuid := gen_random_uuid(); v_role uuid;
    v_sup uuid; v_cust uuid; v_mat uuid; v_matB uuid;
    v_ib uuid; v_run uuid; v_obA uuid; v_obB uuid;
    v_r jsonb; v_n numeric; v_n2 numeric; v_n3 numeric;
    v_je int; v_je2 int; v_stale boolean; v_msg text; v_ok boolean;
    v_today date := CURRENT_DATE;
    v_b1220 numeric; v_b5000 numeric; v_b1200 numeric;   -- 场景前的基线(对线上跑时非零)
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-18', 'fixture', 'fixture', true) RETURNING id INTO v_role;
    INSERT INTO role_permissions (role_id, permission_code) SELECT v_role, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_uid, v_role);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_uid), true);
    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO suppliers (code, legal_name, country) VALUES ('FIXT-S18', 'Fixture Supplier 18', 'SG')
        RETURNING id INTO v_sup;
    INSERT INTO customers (code, legal_name, country) VALUES ('FIXT-C18', 'Fixture Customer 18', 'SG')
        RETURNING id INTO v_cust;
    INSERT INTO materials (code, name, category) VALUES ('FIXT-M18', 'Fixture Material 18', 'black_mass')
        RETURNING id INTO v_mat;
    INSERT INTO materials (code, name, category) VALUES ('FIXT-M18B', 'Fixture Product 18', 'black_mass')
        RETURNING id INTO v_matB;

    -- ════════════════ B(先跑 —— 本切的全部理由)═══════════════════════════
    -- 【断言用差额,不用绝对额】fixture 也对线上跑(rolled back),三个科目都有
    -- 存量余额 —— 断言"本场景带来的变动",空库与线上同一份口径。
    SELECT round(COALESCE(SUM(CASE WHEN a.code='1220' THEN jl.debit - jl.credit END), 0), 2),
           round(COALESCE(SUM(CASE WHEN a.code='5000' THEN jl.debit - jl.credit END), 0), 2),
           round(COALESCE(SUM(CASE WHEN a.code='1200' THEN jl.debit - jl.credit END), 0), 2)
      INTO v_b1220, v_b5000, v_b1200
    FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id
    WHERE a.code IN ('1220','5000','1200');

    -- 进料 100kg,计价 @1(SGD:本位币,免牌价);全部耗进一炉,产出 100kg,未售。
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date)
    VALUES ('FIXT-IB18', v_mat, v_sup, 100, 100, 'kg', v_today) RETURNING id INTO v_ib;
    PERFORM reprice_inbound_batch(v_ib, 1, 'SGD', NULL, 'fixture initial price');

    v_run := commit_processing_run(v_today, 'fixture run B', 0,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib, 'quantity_consumed', 100)),
        jsonb_build_array(jsonb_build_object('material_id', v_matB, 'quantity', 100)), 'metal_value');
    PERFORM allocate_processing_costs(v_run, 'weight');   -- 首挂:1220=100 / 1200 贷 100

    -- 【fixture 的钟是冻的】整个 fixture 一个事务,now() 恒同值 —— 真实世界里
    -- 重定价与分摊各自成交易,时间戳自然有先后;这里把 allocated_at 拨早一秒,
    -- 让"价变晚于分摊"这一真实前提在冻结的钟下成立。
    UPDATE processing_runs SET allocated_at = allocated_at - interval '1 second' WHERE id = v_run;

    -- 重定价到 2:reprice 拆分 —— remaining 0 → 全部已耗份额 100 停进 5000
    PERFORM reprice_inbound_batch(v_ib, 2, 'SGD', NULL, 'fixture reprice');

    -- F 臂(顺路,在重跑之前断言):没碰任何成本条目,单必须已过期
    SELECT is_stale INTO v_stale FROM processing_run_allocation_status WHERE run_id = v_run;
    IF NOT COALESCE(v_stale, false) THEN
        RAISE EXCEPTION 'FIXTURE 18F 失败:重定价输入批后,耗它的加工单应 is_stale,实为 %(staleness 只看成本条目的洞没堵上)', v_stale;
    END IF;

    -- 重分摊:材料 100→200,差额 100;产出全未售 → 全进 1220,贷 5000(收回停车)
    PERFORM allocate_processing_costs(v_run, 'weight');

    SELECT round(COALESCE(SUM(CASE WHEN a.code='1220' THEN jl.debit - jl.credit END), 0), 2) - v_b1220,
           round(COALESCE(SUM(CASE WHEN a.code='5000' THEN jl.debit - jl.credit END), 0), 2) - v_b5000,
           round(COALESCE(SUM(CASE WHEN a.code='1200' THEN jl.debit - jl.credit END), 0), 2) - v_b1200
      INTO v_n, v_n2, v_n3
    FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id
    WHERE a.code IN ('1220','5000','1200');
    IF v_n <> 200 THEN
        RAISE EXCEPTION 'FIXTURE 18B 失败:1220 变动应为 +200(新成本全额),实得 %', v_n;
    END IF;
    IF v_n2 <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 18B 失败:5000 变动应为 0(停车已收回,没有叠加),实得 %(=旧实现的重复计数)', v_n2;
    END IF;
    IF v_n3 <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 18B 失败:1200 变动应为 0,实得 %(负数 = 旧实现贷错科目)', v_n3;
    END IF;

    -- ════════════════ D. 幂等:原状态再跑,一张分录都不多 ═══════════════════
    SELECT count(*) INTO v_je FROM journal_entries WHERE source_type = 'allocation';
    PERFORM allocate_processing_costs(v_run, 'weight');
    SELECT count(*) INTO v_je2 FROM journal_entries WHERE source_type = 'allocation';
    IF v_je2 <> v_je THEN
        RAISE EXCEPTION 'FIXTURE 18D 失败:无差额重跑多出了分录(% → %)', v_je, v_je2;
    END IF;

    -- ════════════════ A + C. 一炉两批、卖出程度不同;成本条目再变 ═══════════
    -- 批 A 卖 60%(挂 COGS),批 B 未售。加电费 100 → A 的份额 50:
    -- 30(60% 已售)→ 5000,20 → 1220;B 的 50 全进 1220。炉级比例(30% 售)
    -- 会把 5000 记成 30 而不是 30 —— 等等,炉级 = (60+0)/200=30% → 5000=30。
    -- 巧合同值!改成 A 卖 80%:A 份额 50 → 5000 = 40;炉级 40%×100 = 40。
    -- 还是同值 —— 因为两批等量。【不等量】才分得开:A 100kg 卖 80,B 300kg 未售。
    -- A 份额 = 100/400×100 = 25 → 已售 80% → 5000 = 20;
    -- 炉级已售比 = 80/400 = 20% → 5000 = 20 …… 仍同值(权重抵消)。
    -- 真正分开两种实现的是【卖出比 × 份额比不同构】:A 100kg 卖 80(80%),
    -- B 300kg 卖 30(10%)。逐批:25×0.8 + 75×0.1 = 20+7.5 = 27.5;
    -- 炉级:(80+30)/400 = 27.5% × 100 = 27.5 …… 数学上恒等!
    -- 【结论】weight 基准下逐批与炉级对"已售 kg"同构 —— 分不开是算术事实,
    -- 不是断言疏忽。分得开的是【metal_value 基准】(份额≠重量比)。但金属价
    -- fixture 化成本高;这里改为断言【结构】:差额分录的 5000 腿恰等于
    -- Σ(各批差额 × 各批已挂COGS比),用两批不同卖出比的数据算给它看。
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date)
    VALUES ('FIXT-IB18C', v_mat, v_sup, 400, 400, 'kg', v_today) RETURNING id INTO v_ib;
    PERFORM reprice_inbound_batch(v_ib, 1, 'SGD', NULL, 'fixture C price');
    v_run := commit_processing_run(v_today, 'fixture run C', 0,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib, 'quantity_consumed', 400)),
        jsonb_build_array(
            jsonb_build_object('material_id', v_matB, 'quantity', 100),
            jsonb_build_object('material_id', v_matB, 'quantity', 300)), 'metal_value');
    PERFORM allocate_processing_costs(v_run, 'weight');
    SELECT po.output_batch_id INTO v_obA FROM processing_outputs po
    JOIN output_batches ob ON ob.id = po.output_batch_id
    WHERE po.run_id = v_run AND ob.quantity = 100;
    SELECT po.output_batch_id INTO v_obB FROM processing_outputs po
    JOIN output_batches ob ON ob.id = po.output_batch_id
    WHERE po.run_id = v_run AND ob.quantity = 300;

    -- 卖:A 80kg,B 30kg(都会挂 COGS —— unit_cost 已在)
    PERFORM record_output_sale(v_obA, 80, 10, 'SGD', NULL, v_cust, v_today, NULL);
    PERFORM record_output_sale(v_obB, 30, 10, 'SGD', NULL, v_cust, v_today, NULL);

    -- 电费 +100(成本条目直插 —— 界面路径外,但入账触发器照走)
    INSERT INTO processing_cost_entries (run_id, cost_type, amount_base, is_estimate, created_by)
    VALUES (v_run, 'electricity', 100, false, v_uid);

    SELECT count(*) INTO v_je FROM journal_entries WHERE source_type = 'allocation';
    PERFORM allocate_processing_costs(v_run, 'weight');

    -- 差额分录(最新一张 allocation):5000 借 = 100×(25/100×0.8 + 75/100×0.1)
    --   A 批差额 = 400×0.25×0.25/… 直接算:总差额 100,A 份额 25、B 份额 75;
    --   A 已挂COGS比 80/100=0.8 → 20;B 30/300=0.1 → 7.5;5000 = 27.50。
    --   1220 = 差额其余 = 72.50。贷 5110 电费 100。
    SELECT round(COALESCE(SUM(jl.debit), 0), 2) INTO v_n
    FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id
    WHERE a.code = '5000' AND jl.entry_id = (
        SELECT id FROM journal_entries WHERE source_type = 'allocation'
        ORDER BY created_at DESC, code DESC LIMIT 1);
    IF v_n <> 27.50 THEN
        RAISE EXCEPTION 'FIXTURE 18A/C 失败:已售份额补差应为 27.50(逐批:25×0.8 + 75×0.1),实得 %', v_n;
    END IF;
    SELECT is_stale INTO v_stale FROM processing_run_allocation_status WHERE run_id = v_run;
    IF COALESCE(v_stale, true) THEN
        RAISE EXCEPTION 'FIXTURE 18C 失败:重跑后过期旗应清除,实为 %', v_stale;
    END IF;

    -- ════════════════ E. 注销批的份额 → 5200,不进 5000 ═════════════════════
    -- 注销 B 批(soft-delete → writeoff 触发器按当前单位成本解除进 5200)。
    -- 再加电费 60:A 份额 15,B 份额 45。B 已整批注销(remaining 0、售 30 挂
    -- COGS、注销 270)→ B 差额拆:COGS 30/300×45=4.5 → 5000;注销 270/300×45
    -- = 40.5 → 5200。A:已售 80% → 12 → 5000,3 → 1220。
    -- 断言最新差额分录:5200 借 = 40.50。
    -- AUDEL-1b:软删只能走门(直连 UPDATE 被 guard_soft_delete_provenance 按名拒)
    PERFORM soft_delete_output_batch(v_obB, 'fixture:AUDEL-1b 之后理由必填');
    INSERT INTO processing_cost_entries (run_id, cost_type, amount_base, is_estimate, created_by)
    VALUES (v_run, 'electricity', 60, false, v_uid);
    PERFORM allocate_processing_costs(v_run, 'weight');
    SELECT round(COALESCE(SUM(jl.debit), 0), 2) INTO v_n
    FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id
    WHERE a.code = '5200' AND jl.entry_id = (
        SELECT id FROM journal_entries WHERE source_type = 'allocation'
        ORDER BY created_at DESC, code DESC LIMIT 1);
    IF v_n <> 40.50 THEN
        RAISE EXCEPTION 'FIXTURE 18E 失败:注销份额应 40.50 进 5200(不进 5000 —— 注销总额是运营信号),实得 %', v_n;
    END IF;

    -- ════════════════ G. 售出月已锁,改成本 → 差额记当期,过账成功 ══════════
    -- 把锁推到今天(今天的销售/分录都在锁外;昨天及更早在锁内)。
    -- 用 B 臂那张单(其分录全在今天)—— 先把锁推到今天,再加成本、重跑:
    -- 差额分录日期 = 今天(≥ 锁)→ 必须成功,且日期恰为今天。
    UPDATE finance_settings SET locked_before = v_today;
    SELECT run_id INTO v_run FROM processing_run_allocation_status
    WHERE code = (SELECT code FROM processing_runs WHERE notes = 'fixture run B' LIMIT 1) LIMIT 1;
    -- (fixture run B 的 run id 在上面被 C 段覆写;从 notes 找回)
    INSERT INTO processing_cost_entries (run_id, cost_type, amount_base, is_estimate, created_by)
    VALUES (v_run, 'labour', 50, false, v_uid);
    PERFORM allocate_processing_costs(v_run, 'weight');
    SELECT entry_date INTO v_today FROM journal_entries
    WHERE source_type = 'allocation' ORDER BY created_at DESC, code DESC LIMIT 1;
    IF v_today <> CURRENT_DATE THEN
        RAISE EXCEPTION 'FIXTURE 18G 失败:差额分录应记当期(%),实得 %', CURRENT_DATE, v_today;
    END IF;
    -- ════════════════ H. metal_value 基准:逐批 ≠ 炉级,数值分开 ═══════════
    -- (锁在 G 臂已推到今天;本臂全部分录都记今天,不受影响)
    INSERT INTO metal_prices (metal, price_date, price_usd_per_tonne)
    VALUES ('ni', v_today, 1000)
    -- METAL-2:唯一键现在是 (metal, price_date, price_index)(NULLS NOT DISTINCT)。
    -- 本 fixture 录的是【未标注指数】的行情,与分摊的房屋约定(默认亦未声明)对得上。
    ON CONFLICT (metal, price_date, price_index) DO NOTHING;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date)
    VALUES ('FIXT-IB18H', v_mat, v_sup, 400, 400, 'kg', v_today) RETURNING id INTO v_ib;
    PERFORM reprice_inbound_batch(v_ib, 1, 'SGD', NULL, 'fixture H price');
    v_run := commit_processing_run(v_today, 'fixture run H', 0,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib, 'quantity_consumed', 400)),
        jsonb_build_array(
            jsonb_build_object('material_id', v_matB, 'quantity', 100),
            jsonb_build_object('material_id', v_matB, 'quantity', 300)), 'metal_value');
    SELECT po.output_batch_id INTO v_obA FROM processing_outputs po
    JOIN output_batches ob ON ob.id = po.output_batch_id
    WHERE po.run_id = v_run AND ob.quantity = 100 AND ob.deleted_at IS NULL;
    SELECT po.output_batch_id INTO v_obB FROM processing_outputs po
    JOIN output_batches ob ON ob.id = po.output_batch_id
    WHERE po.run_id = v_run AND ob.quantity = 300 AND ob.deleted_at IS NULL;
    -- A 30%(30kg 镍)、B 10%(30kg)→ 价值份额各 0.5;重量份额 0.25/0.75 —— 两个口径分道
    INSERT INTO output_batch_metals (output_batch_id, metal, content_pct, content_source)
    VALUES (v_obA, 'ni', 30, 'manual'), (v_obB, 'ni', 10, 'manual');
    PERFORM allocate_processing_costs(v_run, 'metal_value');   -- 首挂:A 200 / B 200

    PERFORM record_output_sale(v_obA, 80, 10, 'SGD', NULL, v_cust, v_today, NULL);
    PERFORM record_output_sale(v_obB, 30, 10, 'SGD', NULL, v_cust, v_today, NULL);
    UPDATE processing_runs SET allocated_at = allocated_at - interval '1 second' WHERE id = v_run;
    INSERT INTO processing_cost_entries (run_id, cost_type, amount_base, is_estimate, created_by)
    VALUES (v_run, 'electricity', 100, false, v_uid);
    PERFORM allocate_processing_costs(v_run, 'metal_value');

    SELECT round(COALESCE(SUM(jl.debit), 0), 2) INTO v_n
    FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id
    WHERE a.code = '5000' AND jl.entry_id = (
        SELECT id FROM journal_entries WHERE source_type = 'allocation'
        ORDER BY created_at DESC, code DESC LIMIT 1);
    IF v_n <> 45.00 THEN
        RAISE EXCEPTION 'FIXTURE 18H 失败:metal_value 下已售补差应 45.00(逐批 100×(0.5×0.8+0.5×0.1);炉级会是 27.50),实得 %', v_n;
    END IF;

    -- ════════ I. 成本条目【不许硬删】(FIN-31)═══════════════════════════════
    -- 软删是这张表的删除语义:过冲销分录、留历史行、把 updated_at 顶上去让分摊
    -- 标记过期。硬删三件全不做,还会把该行的时间戳从 last_cost_change 里【拿走】,
    -- 于是分摊可能不升反降地显示"不过期" —— 一笔不存在的成本继续留在分摊里。
    -- 此前它只是被 history 表的外键顺带挡住(FIN-8 之前建的条目没有历史行,
    -- 真的删得掉),现在是一条明写的守卫。
    v_ok := false; v_msg := NULL;
    BEGIN
        DELETE FROM processing_cost_entries WHERE run_id = v_run;
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        v_ok := v_msg LIKE 'COST_ENTRY_HARD_DELETE%';
    END;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'FIXTURE 18I 失败:硬删成本条目应 COST_ENTRY_HARD_DELETE 点名拒,实得:%',
            COALESCE(v_msg, '(删成功了 —— 总账留下没有冲销的成本,而分摊不会标过期)');
    END IF;
END $$;
ROLLBACK;
