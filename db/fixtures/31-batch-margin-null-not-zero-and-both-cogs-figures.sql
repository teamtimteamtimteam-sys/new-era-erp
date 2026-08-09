-- 31 批次毛利:没有成本时【NULL,不是 100%】;限定词跟着行走;总账与管理两个口径
--    都在;单模块读者照样拿得到这个数
--
-- 【为什么值得常设(OPS-20)】这张视图最可能坏的方式【不报错】:
--   * COALESCE(unit_cost, 0) —— 屏幕上是一个四舍五入到分的 100.0%,完全像个真数;
--     live 上四个有收入的批次里【三个】没有单位成本,所以这一错会同时污染三行。
--   * 以 processing_outputs 为主表 —— 没有加工单的批次【整行消失】,而 live 上那一行
--     恰好是金额最大的一笔(24,000)。少一行比错一个数更难发现。
--   * 单模块谓词 —— 收入在财务、分摊成本在加工,而【没有任何 live 角色同时持有两者】,
--     所以写成 AND 或写成任一单模块,这个数就对它该服务的人隐身。
-- 四条各一臂,全部两头断言。
--
-- 【可见性断言切数据库角色】(README 第 6 条)。视图是属主权限,裁决在
-- has_permission —— 按【调用者】解析,与 fixture 以 postgres 跑无关;切角色是为了
-- 让断言走过与真实读者相同的门(GRANT SELECT TO authenticated 也顺带被验证)。
--
-- 【日期自设】(README 第 4 条)。业务行落在 2027,locked_before 显式清空。
BEGIN;
DO $$
DECLARE
    u_fin  uuid := gen_random_uuid();   -- 只有 module.finance.view + data.view_prices
    u_proc uuid := gen_random_uuid();   -- 只有 module.processing.view + data.view_prices
    u_np   uuid := gen_random_uuid();   -- 两个模块都有,但【没有】data.view_prices
    r_fin uuid; r_proc uuid; r_np uuid;
    v_mat uuid; v_sup uuid; v_cust uuid; v_ccy text;
    ib_a uuid;
    ob_norun uuid; ob_costed uuid; ob_stale uuid;
    run_costed uuid; run_stale uuid;
    sr_norun uuid; sr_costed uuid; sr_stale uuid;
    je_cogs uuid;
    v_rec record;
    n int; n_stale int;
    v_posted numeric; v_current numeric;
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    UPDATE finance_settings SET locked_before = NULL;

    -- ── 三个角色 ────────────────────────────────────────────────────────────
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-31-fin', 'f', 'f', true) RETURNING id INTO r_fin;
    INSERT INTO role_permissions (role_id, permission_code)
    VALUES (r_fin, 'module.finance.view'), (r_fin, 'data.view_prices');
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-31-proc', 'f', 'f', true) RETURNING id INTO r_proc;
    INSERT INTO role_permissions (role_id, permission_code)
    VALUES (r_proc, 'module.processing.view'), (r_proc, 'data.view_prices');
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-31-noprice', 'f', 'f', true) RETURNING id INTO r_np;
    INSERT INTO role_permissions (role_id, permission_code)
    VALUES (r_np, 'module.finance.view'), (r_np, 'module.processing.view');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_fin, r_fin), (u_proc, r_proc), (u_np, r_np);

    INSERT INTO materials (code, name, category)
    VALUES ('ZZFIX31-M', 'fixture 31 material', 'other') RETURNING id INTO v_mat;
    INSERT INTO suppliers (code, legal_name, country)
    VALUES ('ZZFIX31-S', 'fixture 31 supplier', 'SG') RETURNING id INTO v_sup;
    INSERT INTO customers (code, legal_name, country)
    VALUES ('ZZFIX31-C', 'fixture 31 customer', 'SG') RETURNING id INTO v_cust;

    -- ── 批次 1:有收入、【根本没有加工单】────────────────────────────────────
    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, output_date)
    VALUES ('ZZFIX31-OB-NORUN', v_mat, 100, 100, '2027-02-01') RETURNING id INTO ob_norun;
    INSERT INTO sales_records (output_batch_id, customer_id, quantity, unit_price,
        currency, fx_rate, amount_base, sale_date)
    VALUES (ob_norun, v_cust, 100, 10, v_ccy, 1, 1000, '2027-02-10') RETURNING id INTO sr_norun;

    -- ── 批次 2:有加工单、有单位成本 —— 唯一算得出毛利的一个 ──────────────────
    -- 收入 2000,成本 100 × 4 = 400 → 毛利 1600,毛利率 80.0%
    INSERT INTO processing_runs (code, status, allocated_at)
    VALUES ('ZZFIX31-RUN-OK', 'committed', '2027-03-01') RETURNING id INTO run_costed;
    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, output_date)
    VALUES ('ZZFIX31-OB-OK', v_mat, 100, 100, '2027-03-01') RETURNING id INTO ob_costed;
    INSERT INTO processing_outputs (run_id, output_batch_id, quantity_produced,
        allocated_cost_base, unit_cost_base, cost_incomplete)
    VALUES (run_costed, ob_costed, 100, 400, 4, false);
    INSERT INTO sales_records (output_batch_id, customer_id, quantity, unit_price,
        currency, fx_rate, amount_base, sale_date)
    VALUES (ob_costed, v_cust, 100, 20, v_ccy, 1, 2000, '2027-03-10') RETURNING id INTO sr_costed;

    -- ── 批次 3:有单位成本,但分摊【之后】成本又动了 → is_stale ────────────────
    INSERT INTO processing_runs (code, status, allocated_at)
    VALUES ('ZZFIX31-RUN-STALE', 'committed', '2027-04-01') RETURNING id INTO run_stale;
    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, output_date)
    VALUES ('ZZFIX31-OB-STALE', v_mat, 50, 50, '2027-04-01') RETURNING id INTO ob_stale;
    INSERT INTO processing_outputs (run_id, output_batch_id, quantity_produced,
        allocated_cost_base, unit_cost_base, cost_incomplete)
    VALUES (run_stale, ob_stale, 50, 250, 5, true);   -- cost_incomplete 一并置起
    INSERT INTO processing_cost_entries (run_id, cost_type, amount_base, created_at, updated_at)
    VALUES (run_stale, 'electricity', 60, '2027-05-01', '2027-05-01');   -- 晚于 allocated_at
    INSERT INTO sales_records (output_batch_id, customer_id, quantity, unit_price,
        currency, fx_rate, amount_base, sale_date)
    VALUES (ob_stale, v_cust, 50, 30, v_ccy, 1, 1500, '2027-04-10') RETURNING id INTO sr_stale;

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u_fin), true);

    -- ══════════ A. 有收入、无成本 → NULL,【不是】0,更不是 100% ══════════════
    -- 先数总行数:谓词写错(OR 写成 AND)会让本臂的读者一行都看不见,那时下面
    -- 每一条都会以"这一行不见了"报错 —— 诊断就指错了地方。先分开这两种情况。
    SELECT count(*) INTO n FROM batch_margin;
    IF n <> 3 THEN
        RAISE EXCEPTION 'FIXTURE 31A 前置失败:本臂读者(module.finance.view + data.view_prices)应看见 3 行,实得 % —— 0 行几乎总是视图谓词把 OR 写成了 AND(见 D 臂)',
            n;
    END IF;
    SELECT * INTO v_rec FROM batch_margin WHERE batch_code = 'ZZFIX31-OB-NORUN';
    IF v_rec IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 31A 失败:没有加工单的批次【整行不见了】—— 说明主表是 processing_outputs 而不是 output_batches。live 上金额最大的那一笔正是这种批次';
    END IF;
    -- 【三列都要断言】成本列、毛利额、毛利率。只断言毛利额是不够的:一处
    -- COALESCE(unit_cost, 0) 可能只落在其中一列上,漏掉的那一列就是下一个 0 冒充真值的地方。
    -- (写这一臂时的实测:只 COALESCE 了 cost_current_base 的注入【没有】被逮到。)
    IF v_rec.cost_current_base IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 31A 失败:无成本依据时成本列必须为 NULL,实得 % —— 0 会被读成"这批货不花钱"',
            v_rec.cost_current_base;
    END IF;
    IF v_rec.margin_base IS NOT NULL OR v_rec.margin_pct IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 31A 失败:无成本依据时毛利必须为 NULL,实得 margin_base=% margin_pct=% —— 若是 1000 / 100.0 就是把缺失的成本当成了零',
            v_rec.margin_base, v_rec.margin_pct;
    END IF;
    IF v_rec.margin_status <> 'no_run' THEN
        RAISE EXCEPTION 'FIXTURE 31A 失败:算不出来的【原因】应为 no_run,实得 %', v_rec.margin_status;
    END IF;
    IF v_rec.revenue_base <> 1000 THEN
        RAISE EXCEPTION 'FIXTURE 31A 失败:收入应为 1000,实得 % —— 收入没进来的话本臂是空转的', v_rec.revenue_base;
    END IF;

    -- 【这一臂不能靠"反正都是 NULL"通过】能算的那一行必须真的算出数来
    SELECT * INTO v_rec FROM batch_margin WHERE batch_code = 'ZZFIX31-OB-OK';
    IF v_rec.margin_base <> 1600 OR v_rec.margin_pct <> 80.0 THEN
        RAISE EXCEPTION 'FIXTURE 31A 失败:有成本的批次应得毛利 1600 / 80.0%%(收入 2000 − 4×100),实得 % / %',
            v_rec.margin_base, v_rec.margin_pct;
    END IF;
    IF v_rec.margin_status <> 'ok' THEN
        RAISE EXCEPTION 'FIXTURE 31A 失败:有成本的批次 margin_status 应为 ok,实得 %', v_rec.margin_status;
    END IF;

    -- ══════════ B. 限定词跟着行走:is_stale 与 cost_incomplete ════════════════
    SELECT * INTO v_rec FROM batch_margin WHERE batch_code = 'ZZFIX31-OB-STALE';
    IF NOT v_rec.is_stale THEN
        RAISE EXCEPTION 'FIXTURE 31B 失败:分摊(2027-04-01)之后成本又动了(2027-05-01),is_stale 应为 true —— false 意味着屏幕上是一个过期单位成本算出的毛利,而没有任何提示';
    END IF;
    IF NOT v_rec.cost_incomplete THEN
        RAISE EXCEPTION 'FIXTURE 31B 失败:cost_incomplete 应原样带出(有未计价输入按零计入 → 毛利被高估)';
    END IF;
    -- 而未过期那一行【不能】也挂上旗:否则旗恒真,等于没有旗
    SELECT * INTO v_rec FROM batch_margin WHERE batch_code = 'ZZFIX31-OB-OK';
    IF v_rec.is_stale OR v_rec.cost_incomplete THEN
        RAISE EXCEPTION 'FIXTURE 31B 失败:未过期、成本完整的那一行不该挂旗(is_stale=% cost_incomplete=%)—— 恒真的旗与没有旗是一回事',
            v_rec.is_stale, v_rec.cost_incomplete;
    END IF;

    -- ══════════ C. 总账口径与管理口径【两个都在,且确实不同】═══════════════════
    -- 造一笔当时过账的 COGS:400(卖出时的成本),此后重分摊把单位成本改成 6 →
    -- 当前口径 600。两个数都对,视图必须【同时给出】并标出不同。
    INSERT INTO journal_entries (code, entry_date, memo, source_type)
    VALUES ('ZZFIX31-COGS', '2027-03-10', 'fixture 31 cogs at sale', 'sale') RETURNING id INTO je_cogs;
    INSERT INTO journal_lines (entry_id, account_id, debit, credit, currency, amount_ccy, fx_rate)
    SELECT je_cogs, a.id, x.d, x.c, v_ccy, 400, 1
    FROM (VALUES ('5000', 400.0, 0.0), ('1220', 0.0, 400.0)) x(code, d, c)
    JOIN accounts a ON a.code = x.code;
    UPDATE sales_records SET cogs_entry_id = je_cogs WHERE id = sr_costed;
    -- 重分摊:单位成本从 4 变成 6(总账那 400 不动 —— 这正是两个数分岔的机制)
    UPDATE processing_outputs SET unit_cost_base = 6, allocated_cost_base = 600
     WHERE output_batch_id = ob_costed;

    SELECT * INTO v_rec FROM batch_margin WHERE batch_code = 'ZZFIX31-OB-OK';
    v_posted  := v_rec.cogs_posted_base;
    v_current := v_rec.cost_current_base;
    IF v_posted IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 31C 失败:已过账的 COGS 应为 400,实得 NULL —— 总账那一半没接上,屏幕上就只剩一个口径';
    END IF;
    IF v_posted <> 400 THEN
        RAISE EXCEPTION 'FIXTURE 31C 失败:已过账 COGS 应为 400(卖出当时),实得 %', v_posted;
    END IF;
    IF v_current <> 600 THEN
        RAISE EXCEPTION 'FIXTURE 31C 失败:当前口径成本应为 600(重分摊后 6 × 100),实得 %', v_current;
    END IF;
    IF v_posted = v_current THEN
        RAISE EXCEPTION 'FIXTURE 31C 失败:两个口径给出了同一个数(%)—— 这一臂无法区分"都对"和"只算了一遍"', v_posted;
    END IF;
    IF NOT v_rec.cogs_differs THEN
        RAISE EXCEPTION 'FIXTURE 31C 失败:两个数不同(% vs %)时 cogs_differs 必须为 true,否则屏幕上不会说出这件事',
            v_posted, v_current;
    END IF;
    -- 毛利用的是【管理口径】:2000 − 600 = 1400
    IF v_rec.margin_base <> 1400 THEN
        RAISE EXCEPTION 'FIXTURE 31C 失败:毛利应按当前单位成本算得 1400,实得 % —— 若为 1600 就是用了已过账的 COGS', v_rec.margin_base;
    END IF;

    -- ══════════ D. 单模块读者照样拿得到这个数,且限定词不缺 ═══════════════════
    -- 【这一臂是常设决定 2 的行为形态】收入在财务、分摊成本在加工,没有任何 live
    -- 角色同时持有两者。任一单模块读者都必须拿到【全部三行】,并且 is_stale 不能
    -- 因为读不到 processing_run_allocation_status 而退化成 false(那正是 OPS-14 的病)。
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u_fin), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*), count(*) FILTER (WHERE is_stale) INTO n, n_stale FROM batch_margin;
    RESET ROLE;
    IF n <> 3 OR n_stale <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 31D 失败:只有 module.finance.view 的读者应看见 3 行、其中 1 行 is_stale,实得 % 行 / % 行过期 —— 少行是谓词写成了 AND,过期旗少了是 is_stale 借自 processing 模块的视图而静默塌成 false',
            n, n_stale;
    END IF;

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u_proc), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*), count(*) FILTER (WHERE is_stale) INTO n, n_stale FROM batch_margin;
    RESET ROLE;
    IF n <> 3 OR n_stale <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 31D 失败:只有 module.processing.view 的读者应看见 3 行、其中 1 行 is_stale,实得 % 行 / % 行过期',
            n, n_stale;
    END IF;

    -- data.view_prices 是硬前提:毛利本身就是价格信息
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u_np), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO n FROM batch_margin;
    RESET ROLE;
    IF n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 31D 失败:两个模块都有但没有 data.view_prices 的读者应看见 0 行,实得 %', n;
    END IF;

    -- ══════════ E. is_stale 与它的定义出处一致 ═══════════════════════════════
    -- 本视图【就地重算】了过期判定(理由见视图头:processing_run_allocation_status
    -- 挂 module.processing.view,finance 读者从它只能读到零行)。重复的定义会漂,
    -- 所以在这里钉住:对同一个 run,两边必须给同一个答案。
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u_proc), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO n
      FROM batch_margin bm
      JOIN processing_run_allocation_status s ON s.run_id = bm.run_id
     WHERE bm.is_stale IS DISTINCT FROM s.is_stale;
    RESET ROLE;
    IF n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 31E 失败:% 个 run 上 batch_margin.is_stale 与 processing_run_allocation_status.is_stale 不一致 —— 两份定义已经漂了,改一边要改两边', n;
    END IF;
END $$;
ROLLBACK;
