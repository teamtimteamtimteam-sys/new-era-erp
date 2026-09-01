-- 172 存货计值:一条【动得开】的勾稽、三种产出状态、关账第五闸,以及两个改不回空的日期
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【这份 fixture 钉六件事】(INV-VAL-1)
--   · ★**存货勾稽动得开**★ —— 往 1200 打一笔手工分录,未解释余额当场不为零(A 臂)。
--   · **四条具名成因真的在解释差额**,而余额仍然是 0(A 臂后半)。
--   · **产出侧三种状态长得不一样** —— 有数 / 0.00 / NULL,后两者【不许相等】(B 臂)。
--   · **读不到价的人拿到具名受限,不是一个更小的合计**(C 臂)。
--   · **已提交未分摊的加工单挡住关账**,而拿掉它之后同一次关账就过(D 臂)。
--   · **到货日与产出日不能被改回空**,而【本来就是空的历史行照样能改】(E 臂)。
--
-- ★★【四个陷阱,逐个躲开】★★
--   ① **空集恒真**:重建库里一张批次都没有,于是"勾稽上了"是恒真的。
--      处置:A 臂在断言之前先证【账面与明细两边都非零】。
--   ② **注入没改变任何东西也能过**:每一臂都先取基线,再注入,再断言【它动了】。
--      D 臂尤其:先证有那张加工单时被拒,再拿掉它证同一次关账能过 ——
--      否则"关账失败"可能是因为试算不平之类完全无关的理由。
--   ③ ★**把「受限」测成「零」**★ —— C 臂【不】断言金额等于 0,
--      而是断言它 **IS NULL** 且 restriction 具名。这两件事在一个把
--      读不到写成 0 的实现里会同时通过前者、失败后者,而那正是要抓的缺陷。
--   ④ **E 臂的历史行**:如果只测"改回空被拒",一个写成 NOT NULL 的实现也会通过,
--      而它会把线上 7 张没有到货日的历史行【锁死】。所以 E 臂必须【同时】证明
--      本来就是空的那一行仍然改得动 —— 那一条才是 R9「不许回填」的机械保证。
--
-- 自带数据(README 第 2 条);期间锁自己设(第 4/5 条)。
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    v_user    uuid := gen_random_uuid();
    v_limited uuid := gen_random_uuid();
    -- 【关账的人不能是过账的人】SOD-1:在本期过过账的人不得关掉本期
    -- (assert_segregated)。第一版让 v_user 两件事都做,当场 SOD_POST_AND_CLOSE
    -- —— 那是对的,而它会把 D 臂的后半段伪装成"闸没放行"。
    v_closer  uuid := gen_random_uuid();
    r_all     uuid; r_lim uuid;
    v_sup     uuid; v_mat uuid;
    v_base    text;
    v_ib      uuid; v_ib2 uuid;
    v_ob_cost uuid; v_ob_none uuid; v_ob_sold uuid;
    v_run     uuid;
    v_res     jsonb; v_recon jsonb; v_side jsonb; v_snap jsonb;
    v_led numeric; v_sub numeric; v_unexp0 numeric; v_unexp1 numeric;
    v_je jsonb;
    v_costed numeric; v_none numeric; v_sold numeric;
    v_msg text; v_denied boolean; v_n int; v_txt text;
    -- 【勾稽问的是"此刻",关账问的是"那个月末" —— 两个日期,不是一个】
    --   存货明细侧【只答得出此刻】(R5:历史时点重建不出来,business_date 不完整),
    --   所以 A/B/C 臂一律用 CURRENT_DATE;
    --   而 close_period 要一个【过去的、可以关的】月末,与勾稽无关 —— D 臂用 d_month。
    --   把两者混成一个日期,A 臂会拿到具名拒绝(subledger 为 NULL)而不是数字。
    d_arr   date := DATE '2026-03-10';
    d_month date := DATE '2026-03-31';
BEGIN
    -- ══════════════════ 布景 ══════════════════
    INSERT INTO auth.users (id) VALUES (v_user), (v_limited), (v_closer);
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-172', 'f172', 'f172', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all), (v_closer, r_all);

    -- 【受限读者】有 module.inventory.view,【没有】data.view_prices ——
    -- 线上 operations 与 warehouse 实测就是这一类,而他们正是这张报表的主要读者。
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-172-limited', 'f172l', 'f172l', true) RETURNING id INTO r_lim;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_lim, code FROM permissions
     WHERE code IN ('module.inventory.view', 'module.inbound.view', 'module.finance.view');
    INSERT INTO user_roles (user_id, role_id) VALUES (v_limited, r_lim);

    -- 【期间锁自己设】(README 第 4 条)它是操作员随月结推进的运行时状态,
    -- 借它会让这份 fixture 在某个月的早上突然变红。GST 开关【不碰】——
    -- 本刀与 GST 无关,而动它会撞上 guard_gst_switch(线上有一张带税发票)。
    UPDATE finance_settings SET locked_before = NULL;
    SELECT code INTO v_base FROM currencies WHERE is_base;

    INSERT INTO suppliers (code, legal_name, country, counterparty_type)
    VALUES ('ZZ172-S', 'f172 supplier', 'SG', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZ172-M', 'f172 feed', 'battery_material', true, 'black_mass', 'end_of_life')
    RETURNING id INTO v_mat;

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    -- 一张有价的进料批:它同时进明细侧(remaining × 到岸成本)与总账 1200,
    -- 于是勾稽两边都非空 —— 躲开陷阱①的前提。
    v_res := create_inbound_batch(v_mat, v_sup, 100, 'kg', d_arr, '待加工');
    v_ib  := (v_res->>'batch_id')::uuid;
    -- 基准币不接受汇率(FX_RATE_NOT_ACCEPTED)—— 不传它。
    PERFORM set_inbound_unit_price(v_ib, 50, v_base);

    -- ══════════════════════════════════════════════════════════════════════
    -- A 臂 · ★**存货勾稽动得开**★(R2:零余额判据,没有兜底桶)
    -- ══════════════════════════════════════════════════════════════════════
    v_recon := gl_control_reconciliation(CURRENT_DATE);
    SELECT s INTO v_side FROM jsonb_array_elements(v_recon->'sides') s
     WHERE s->>'side' = 'inventory_raw';
    IF v_side IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 172A 失败:勾稽里没有 inventory_raw 这条腿';
    END IF;
    v_led    := (v_side->>'ledger_base')::numeric;
    v_sub    := (v_side->>'subledger_base')::numeric;
    v_unexp0 := (v_side->>'unexplained_base')::numeric;

    -- ★ 陷阱①:先证两边都不是空的。空库里"勾稽上了"恒真,证明不了任何事。
    IF v_led = 0 OR v_sub = 0 THEN
        RAISE EXCEPTION 'FIXTURE 172A 失败(空转):账面 1200 = %、明细 = % —— 有一边是零,这条勾稽在空集上恒真',
            v_led, v_sub;
    END IF;
    IF v_unexp0 <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 172A 失败:注入之前未解释余额就已经是 %,基线不干净', v_unexp0;
    END IF;
    IF NOT (v_side->>'reconciled')::boolean THEN
        RAISE EXCEPTION 'FIXTURE 172A 失败:未解释余额是 0 而 reconciled 却不是 true';
    END IF;

    -- ★【注入:一笔手工分录直接打进 1200】★ source_type='manual' 【不】匹配
    --   四条具名成因里的任何一条,于是它必须原样落进未解释余额。
    --   一个给存货侧留了"其他"兜底桶的实现,在这里会报 0,当场红。
    v_je := post_journal_entry(d_arr, 'fixture 172 manual into 1200', 'manual', NULL,
        jsonb_build_array(
            jsonb_build_object('account_code', '1200', 'side', 'debit',
                'currency', v_base, 'amount_ccy', 333),
            jsonb_build_object('account_code', '6900', 'side', 'credit',
                'currency', v_base, 'amount_ccy', 333)));

    v_recon := gl_control_reconciliation(CURRENT_DATE);
    SELECT s INTO v_side FROM jsonb_array_elements(v_recon->'sides') s
     WHERE s->>'side' = 'inventory_raw';
    v_unexp1 := (v_side->>'unexplained_base')::numeric;
    IF v_unexp1 = v_unexp0 THEN
        RAISE EXCEPTION 'FIXTURE 172A 失败:往 1200 打了一笔 333 的手工分录,而未解释余额没有动(仍是 %)—— 这条勾稽是装饰,不是检查',
            v_unexp1;
    END IF;
    -- 明细侧没动,账面侧多了 333 借方 → 差额少 333 → 未解释 = −333。
    IF v_unexp1 <> -333 THEN
        RAISE EXCEPTION 'FIXTURE 172A 失败:未解释余额应当【恰好】等于那笔没有人解释过的分录(−333),实得 %', v_unexp1;
    END IF;
    IF (v_side->>'reconciled')::boolean THEN
        RAISE EXCEPTION 'FIXTURE 172A 失败:未解释余额是 % 而 reconciled 仍然是 true', v_unexp1;
    END IF;
    PERFORM reverse_journal_entry((v_je->>'entry_id')::uuid, d_arr, 'fixture 172 undo');

    -- 冲销之后必须回到 0 —— 否则上面那条"动了"可能只是单向漂移。
    v_recon := gl_control_reconciliation(CURRENT_DATE);
    SELECT s INTO v_side FROM jsonb_array_elements(v_recon->'sides') s
     WHERE s->>'side' = 'inventory_raw';
    IF (v_side->>'unexplained_base')::numeric <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 172A 失败:冲掉注入之后未解释余额应回到 0,实得 %',
            (v_side->>'unexplained_base')::numeric;
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- B 臂 · **产出侧三种状态必须长得不一样**(R6)
    --   有数(分摊过、在库)/ 0.00(分摊过、卖光了)/ NULL(从未分摊)
    -- ══════════════════════════════════════════════════════════════════════
    v_res := create_output_batch(v_mat, 60, 'kg', d_arr);  v_ob_cost := (v_res->>'batch_id')::uuid;
    v_res := create_output_batch(v_mat, 80, 'kg', d_arr);  v_ob_none := (v_res->>'batch_id')::uuid;
    v_res := create_output_batch(v_mat, 40, 'kg', d_arr);  v_ob_sold := (v_res->>'batch_id')::uuid;

    INSERT INTO processing_runs (code, status, allocation_basis, process_date, allocated_at, operation_type_code)
    VALUES ('ZZ172-RUN-COSTED', 'committed', 'weight', d_arr, now(), 'manual_disassembly') RETURNING id INTO v_run;
    -- 分摊过、在库 → 有数
    INSERT INTO processing_outputs (run_id, output_batch_id, quantity_produced, unit_cost_base)
    VALUES (v_run, v_ob_cost, 60, 2.5);
    -- 分摊过、卖光了 → 0.00(remaining 归零,但单位成本【存在】)
    INSERT INTO processing_outputs (run_id, output_batch_id, quantity_produced, unit_cost_base)
    VALUES (v_run, v_ob_sold, 40, 3.0);
    -- 【卖光了要用一笔流水,不是改 remaining_qty】余额是流水的和(STK-1),
    -- 直接改缓存列会当场撞上 check_ledger_invariant —— 而那条不变量是对的:
    -- 一个"库存为 0 而流水说还有 40"的批次,正是这套账最不该出现的东西。
    INSERT INTO inventory_movements (output_batch_id, movement_type, qty_delta,
                                     business_date, created_by)
    VALUES (v_ob_sold, 'sale', -40, d_arr, v_user);
    -- 缓存列跟着流水走(裸 INSERT 不会自己同步它,drain_stock 那条路才会)。
    -- 两件事一起做,不变量才成立:Σ qty_delta = 40 − 40 = 0 = remaining_qty。
    UPDATE output_batches SET remaining_qty = 0 WHERE id = v_ob_sold;
    -- v_ob_none 【故意没有产出腿】→ 从未分摊 → NULL

    SELECT cost_value_base INTO v_costed FROM output_batch_valuation WHERE id = v_ob_cost;
    SELECT cost_value_base INTO v_none   FROM output_batch_valuation WHERE id = v_ob_none;
    SELECT cost_value_base INTO v_sold   FROM output_batch_valuation WHERE id = v_ob_sold;

    IF v_costed IS DISTINCT FROM 150.00 THEN
        RAISE EXCEPTION 'FIXTURE 172B 失败:分摊过且在库的那一批应当是 60 × 2.5 = 150.00,实得 %',
            COALESCE(v_costed::text, 'NULL');
    END IF;
    -- ★ 这一条是本臂的全部要点:【0.00 与 NULL 不许长得一样】
    IF v_sold IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 172B 失败:卖光了的那一批【计过价】,它的价值是 0.00 而不是 NULL —— "值零"与"不适用"被混成了一件事';
    END IF;
    IF v_sold <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 172B 失败:卖光了的那一批应当是 0.00,实得 %', v_sold;
    END IF;
    IF v_none IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 172B 失败:从未分摊过成本的那一批必须是 NULL(渲染成「—」),实得 % —— 一个把它写成 0.00 的实现,会让 3,661kg 从未计过成本的货读起来像是已经计过了',
            v_none;
    END IF;
    IF NOT (SELECT never_costed FROM output_batch_valuation WHERE id = v_ob_none) THEN
        RAISE EXCEPTION 'FIXTURE 172B 失败:从未分摊的那一批 never_costed 应当为 true';
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- C 臂 · ★**读不到价 → 具名受限,不是一个更小的合计**★(STEP 2e)
    -- ══════════════════════════════════════════════════════════════════════
    -- 先以【看得到价】的身份取一次,证明这里本来【有数】—— 否则下面的 NULL
    -- 可能只是因为根本没有货,而不是因为被遮蔽了(陷阱①的另一种形态)。
    v_snap := inventory_valuation_snapshot(CURRENT_DATE);
    IF (v_snap->>'prices_visible')::boolean IS NOT TRUE THEN
        RAISE EXCEPTION 'FIXTURE 172C 失败:全权限用户应当看得到价';
    END IF;
    SELECT SUM((x->>'value_base')::numeric) INTO v_led
      FROM jsonb_array_elements(v_snap->'by_location') x;
    IF COALESCE(v_led, 0) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 172C 失败(空转):全权限下金额合计是 0,后面那条「受限为 NULL」证明不了任何事';
    END IF;

    -- 换成【没有 data.view_prices】的读者
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_limited), true);
    v_snap := inventory_valuation_snapshot(CURRENT_DATE);

    IF (v_snap->>'prices_visible')::boolean IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 172C 失败:受限读者的 prices_visible 应当是 false';
    END IF;
    -- ★ 陷阱③:断言【具名】,不是断言 0。
    IF COALESCE(v_snap->>'restriction', '') NOT LIKE 'PRICE_COMPONENTS_RESTRICTED%' THEN
        RAISE EXCEPTION 'FIXTURE 172C 失败:受限读者必须拿到一条【具名】限制,实得「%」',
            COALESCE(v_snap->>'restriction', '(没有)');
    END IF;
    -- 金额必须是 NULL —— 【不是 0】。一个"读不到就返回 0"的实现在这里当场红。
    SELECT count(*) INTO v_n
      FROM jsonb_array_elements(v_snap->'by_location') x
     WHERE x->>'value_base' IS NOT NULL;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'FIXTURE 172C 失败:受限读者仍看到 % 行有金额 —— 遮蔽漏了', v_n;
    END IF;
    -- 而【数量必须还在】:数量不是价格,没有理由一起扣下。
    SELECT SUM((x->>'qty')::numeric) INTO v_sub
      FROM jsonb_array_elements(v_snap->'by_location') x;
    IF COALESCE(v_sub, 0) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 172C 失败:受限读者应当照常看到数量,实得合计 %', COALESCE(v_sub, 0);
    END IF;
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    -- ══════════════════════════════════════════════════════════════════════
    -- E 臂 · **两个日期改不回空,而本来就是空的历史行照样能改**(R9)
    --   (排在 D 臂之前跑:D 臂会把期间锁上,之后这些 UPDATE 会撞期间锁,
    --    那就变成"因为别的理由被拒" —— 陷阱②的一种。)
    -- ══════════════════════════════════════════════════════════════════════
    v_denied := false; v_msg := NULL;
    BEGIN UPDATE inbound_batches SET arrival_date = NULL WHERE id = v_ib;
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE '%ARRIVAL_DATE_REQUIRED%' THEN
        RAISE EXCEPTION 'FIXTURE 172E 失败:把已有的到货日改回空必须按名拒(ARRIVAL_DATE_REQUIRED),实得 denied=%、msg=「%」',
            v_denied, COALESCE(v_msg, '(通过了)');
    END IF;

    v_denied := false; v_msg := NULL;
    BEGIN UPDATE output_batches SET output_date = NULL WHERE id = v_ob_cost;
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE '%OUTPUT_DATE_REQUIRED%' THEN
        RAISE EXCEPTION 'FIXTURE 172E 失败:把已有的产出日改回空必须按名拒(OUTPUT_DATE_REQUIRED),实得 denied=%、msg=「%」',
            v_denied, COALESCE(v_msg, '(通过了)');
    END IF;

    -- ★ 陷阱④:【历史缺失必须活下来】。R9 明写不许回填,而线上有 7 张这样的行。
    --   一个写成 NOT NULL 的实现会通过上面两条、在这一条上当场红 ——
    --   而它会把那 7 张行锁到连备注都改不了。
    --   这里绕开 RPC 直接建一张没有到货日的历史行(触发器只拦【由有变无】,
    --   所以要先插一张有日期的、再用 NOT NULL 之外的手段造出历史态)。
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, unit,
                                 remaining_qty, arrival_date, stage, status)
    VALUES ('ZZ172-HIST', v_mat, v_sup, 10, 'kg', 10, d_arr, '待加工', 'active')
    RETURNING id INTO v_ib2;
    -- 用触发器【看不见】的路径把它变成历史态:直接改列会被拦,所以
    -- 关掉本表的触发器一次 —— 这模拟的是"这一行是 IOD-2-fu1 之前留下来的"。
    -- 【先把挂着的延迟触发器事件冲掉】否则 ALTER TABLE 报
    -- "cannot ALTER TABLE ... because it has pending trigger events"
    -- —— 前面几臂的插入留下了未决的外键检查。
    SET CONSTRAINTS ALL IMMEDIATE;
    ALTER TABLE inbound_batches DISABLE TRIGGER guard_arrival_date_not_cleared;
    UPDATE inbound_batches SET arrival_date = NULL WHERE id = v_ib2;
    ALTER TABLE inbound_batches ENABLE TRIGGER guard_arrival_date_not_cleared;

    v_denied := false; v_msg := NULL;
    BEGIN UPDATE inbound_batches SET notes = 'f172 history still editable' WHERE id = v_ib2;
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 172E 失败:一张【本来就没有到货日】的历史行必须仍然改得动(R9:不许回填,历史的缺失要活下来),实得拒绝「%」—— 这正是把守卫写成 NOT NULL 会造成的后果',
            v_msg;
    END IF;
    SELECT arrival_date IS NULL INTO v_denied FROM inbound_batches WHERE id = v_ib2;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 172E 失败:那一行的到货日不该被谁悄悄填上';
    END IF;
    -- 【不收场,而且收不了】流水是不可改的(MOVEMENT_IMMUTABLE),
    -- 这一行就留着 —— D 臂测的是 close_period,一张多出来的批次不影响它。
    -- 整份 fixture 结束时 ROLLBACK,库里什么都不会留下。

    -- ══════════════════════════════════════════════════════════════════════
    -- D 臂 · **第五条闸:已提交未分摊的加工单挡住关账**(R8)
    -- ══════════════════════════════════════════════════════════════════════
    -- ★ 陷阱②:先证【有那张单时被拒】,再拿掉它证【同一次关账能过】。
    --   只测前一半的话,"关账失败"可能是试算不平之类完全无关的理由。
    INSERT INTO processing_runs (code, status, allocation_basis, process_date, allocated_at, operation_type_code)
    VALUES ('ZZ172-RUN-UNALLOC', 'committed', 'weight', d_arr, NULL, 'manual_disassembly') RETURNING id INTO v_run;

    -- 换成【没有过账的那个人】来关 —— 否则撞的是 SOD,不是本刀的闸。
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_closer), true);

    v_denied := false; v_msg := NULL;
    BEGIN PERFORM close_period(d_month, 'f172 attempt');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE '%PROCESSING_COSTS_UNALLOCATED%' THEN
        RAISE EXCEPTION 'FIXTURE 172D 失败:一个还挂着已提交未分摊加工单的月份必须按名拒(PROCESSING_COSTS_UNALLOCATED),实得 denied=%、msg=「%」',
            v_denied, COALESCE(v_msg, '(关成功了)');
    END IF;
    -- ★【拒绝必须点名那些加工单】—— 一堵没有门的墙不是闸,是障碍物。
    IF v_msg NOT LIKE '%ZZ172-RUN-UNALLOC%' THEN
        RAISE EXCEPTION 'FIXTURE 172D 失败:拒绝里必须点名挡住关账的加工单(ZZ172-RUN-UNALLOC),否则撞上它的人看不出补救办法。实得「%」', v_msg;
    END IF;
    -- 【名字本身也是判据】按结果命名的闸会宣称一份它并不具备的完整性。
    IF v_msg LIKE '%INVENTORY_NOT_RECONCILED%' THEN
        RAISE EXCEPTION 'FIXTURE 172D 失败:这条闸只检查"有没有分摊",不许用一个宣称存货已勾稽的名字 —— M3/M4/M5/M7 都不在它的射程内';
    END IF;

    -- 拿掉成因 → 同一次关账必须过。这一半才让上一半有意义。
    UPDATE processing_runs SET allocated_at = now() WHERE id = v_run;
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM close_period(d_month, 'f172 after allocating');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 172D 失败:把那张单分摊掉之后,同一次关账应当能过,实得拒绝「%」—— 说明上一半的拒绝并不是这条闸造成的',
            v_msg;
    END IF;
    SELECT count(*) INTO v_n FROM period_closes WHERE period_end = d_month AND reopened_at IS NULL;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 172D 失败:关账应当落下恰好一行,实得 %', v_n;
    END IF;

    RAISE NOTICE 'FIXTURE 172 通过:勾稽动得开(−333)、三态互不相同(150.00 / 0.00 / NULL)、受限具名、第五闸点名加工单、两个日期改不回空而历史缺失活着';
END $$;
ROLLBACK;
