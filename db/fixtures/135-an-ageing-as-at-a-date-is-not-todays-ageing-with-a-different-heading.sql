-- 135 【截至某一天】的账龄不是"今天的账龄换个抬头"(AGING-1)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 勘察说"as-at 今天做不到",给了两条理由:CURRENT_DATE 焊在视图体里,
-- 以及结清额是现在的样子。**实测下来是四条,而后两条是勘察没有点出来的那两条,
-- 也正是最容易被实现成"今天的数字配一个过去的日期"的那两条:**
--   ① 视图接不了参数                     → 本刀改成函数
--   ② 结清额按现在算                     → B 臂(付款)+ C 臂(冲销)
--   ③ 单据在那一天【存在不存在】         → E 臂(冲销)+ H 臂(未来单据)
--   ④ 金额在那一天【是多少】             → D 臂(改价 / 那天还没有价)
--
-- ★【每一条臂都自证非空,而且是【按构造】非空】★ 判据不是"跑出来非零",
--   是**臂内自己算出【那个天真实现会给出的答案】,并断言它与正确答案不同**。
--   于是这些臂在一个空场景上【不可能通过】:两个口径相等时它当场报「空转」。
--   形状抄自 fixture 132 的 G 臂与 133 的三条臂。
--
-- 【A 臂是本刀最重要的一条,而它的方向与其余各臂相反】其余各臂证明
-- 「截至过去某天 ≠ 今天」;A 臂证明 **「截至今天 ≡ 今天」——【逐行逐列】**,
-- 两个方向的差集都必须为空。一次悄悄改变了当前数字的重构,是这里能出的最坏结果。
--
-- 【G 臂钉的是"一处定义",不是一个数字】四条档位边界此前在库里写了三遍。
-- 本刀抽成 aging_bucket() 并让五处引用它;G 臂断言那五处【真的都在引用】,
-- 于是下一个人把 CASE 抄回去会当场变红 —— 这正是本仓库反复付账的那个形状。
--
-- 【H 臂记的是一处【刻意的分歧】,不是一个 bug】as-at 函数把
-- 「单据日期晚于 D」的单据排除在外(那是"截至"的应有之义);而今天那张视图
-- 的进料支【没有日期过滤】,于是一张未来到货的批次在视图里【在】、
-- 在函数里【不在】。线上今天不显形(唯一的三张未来单据都是 reversed,两边都不收),
-- 所以它是一处会潜伏的分歧 —— 本臂把它变成一条被断言的行为。
-- 【H 臂必须排在 A 臂之后】:它一造出未来单据,A 臂的全量差集就不再为空。
-- 用例之间不重置(README 第 2 条),所以顺序在这里是判据的一部分。
--
-- 自带数据(README 第 2 条);期间锁、系统起算日、牌价全部自己设(第 4/5 条)。
-- 日期落在 2026 年 6–7 月并且【永远在过去】—— as-at 函数拒绝未来日期,
-- 而一个过去的日期只会越来越过去。
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    v_user   uuid := gen_random_uuid();
    r_all    uuid;
    v_ccy    text;
    v_bank   text;
    v_sup    uuid; v_mat uuid; v_cust uuid;
    v_ib     uuid; v_ib2 uuid; v_ib_future uuid;
    v_ob     uuid; v_sale uuid;
    v_exp    uuid; v_pay uuid;
    d0 date := DATE '2026-06-15';   -- 批次到货,尚未计价
    d1 date := DATE '2026-06-20';   -- 首次计价 P1
    d2 date := DATE '2026-07-10';   -- 改价 P2
    d3 date := DATE '2026-07-20';   -- 部分付款
    P1 numeric := 10;
    P2 numeric := 25;
    QTY numeric := 100;
    PAYAMT numeric := 400;
    v_res jsonb;
    v_denied boolean; v_msg text;
    v_naive numeric; v_right numeric;
    v_open numeric; v_settled numeric;
    v_n int; v_n2 int;
    v_objs text[];
BEGIN
    -- ══════════════════ 布景 ══════════════════
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    v_bank := bank_account_for_currency(v_ccy);

    -- 前提【显式设定】(README 第 5 条),即使默认值恰好合用。
    -- 【GST 也要设】record_expense 在已注册时会要一个税码(TAX_CODE_REQUIRED),
    -- 而本 fixture 测的是账龄、与税一个字的关系都没有 —— 让它继承线上那个开关,
    -- 就是让一份账龄 fixture 的成败取决于一件不相干的运行时状态。
    -- (这一条在【重建库】上成立:那里没有任何带税码的单据,所以 guard_gst_switch
    --  不会拦。fixture 只跑在重建库上 —— 见 README 抬头。)
    UPDATE finance_settings SET locked_before = NULL, system_start_date = NULL,
                                gst_registered = false, gst_registration_no = NULL;

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-135', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ-FIX135-SUP', 'fixture 135 supplier', 'SG', 'active', 'goods_supplier')
    RETURNING id INTO v_sup;
    INSERT INTO customers (code, legal_name, country)
    VALUES ('ZZ-FIX135-CUS', 'fixture 135 customer', 'SG') RETURNING id INTO v_cust;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZ-FIX135-M', 'fixture 135 material', 'battery_material', true,
            'black_mass', 'end_of_life') RETURNING id INTO v_mat;

    -- 【一张到货即【无价】的批次】—— ④ 那条理由的舞台。
    INSERT INTO inbound_batches (material_id, supplier_id, quantity, unit, remaining_qty,
                                 arrival_date, unit_price, pricing_status, status)
    -- 现价直接落在 INSERT 上:改 unit_price 这件事被 trg_inbound_batches_price_guard
    -- 锁死在 set_inbound_unit_price 那一条路上(PRICE_VIA_FUNCTION),
    -- 而那条路会把 created_at 记成此刻 —— 正是本段下面要说的那件事。
    VALUES (v_mat, v_sup, QTY, 'kg', QTY, d0, P2, 'final', 'active')
    RETURNING id INTO v_ib;

    -- 计价与改价各一次 —— 而它【演不出来】,所以布景拆成两半。
    --
    -- price_history 是【只可追加】的(trg_price_history_immutable:UPDATE 与
    -- DELETE 一律 PRICE_HISTORY_IMMUTABLE),而 reprice_inbound_batch 把
    -- created_at 记成【此刻】。于是"两次改价发生在六月和七月"这个剧本,
    -- 没有任何办法用真的写入者演出来。**这不是缺陷,正是那张表该有的样子。**
    --
    --   ① v_ib  —— 本 fixture 按 INSERT 直接构造一段历史(追加是允许的),
    --               价格臂全部演在它身上;
    --   ② v_ib2 —— 真的走两遍 reprice_inbound_batch,并断言它写出来的形状
    --               与 ① 手工构造的那一段【逐列同构】。
    --
    -- **② 的存在就是 ① 的许可证。** 少了它,① 只是在测本 fixture 自己编的数据;
    -- 有了它,写入者哪天不再记历史、或者换了列的含义,这份 fixture 会当场变红,
    -- 而不是继续对着一段与现实脱节的假历史绿下去。

    INSERT INTO price_history (inbound_batch_id, old_unit_price, new_unit_price,
                               currency, original_price, fx_rate, notes, created_at)
    VALUES (v_ib, NULL, P1, v_ccy, P1, 1, 'fixture 135 首次计价', d1 + time '10:00'),
           (v_ib, P1,   P2, v_ccy, P2, 1, 'fixture 135 改价',     d2 + time '10:00');

    -- ② 真写入者的形状,拿一张一次性批次问出来
    INSERT INTO inbound_batches (material_id, supplier_id, quantity, unit, remaining_qty,
                                 arrival_date, unit_price, pricing_status, status)
    VALUES (v_mat, v_sup, 1, 'kg', 1, d0, NULL, 'unpriced', 'active')
    RETURNING id INTO v_ib2;
    PERFORM reprice_inbound_batch(v_ib2, P1, v_ccy, NULL, 'fixture 135 形状探针 1');
    PERFORM reprice_inbound_batch(v_ib2, P2, v_ccy, NULL, 'fixture 135 形状探针 2');

    SELECT count(*) INTO v_n FROM price_history WHERE inbound_batch_id = v_ib2;
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 135 布景失效:reprice_inbound_batch 跑两次应留下 2 行历史,实得 % —— 手工构造的那一段历史因此不再代表真实写入者,价格臂全部作废', v_n;
    END IF;
    SELECT count(*) INTO v_n FROM price_history
     WHERE inbound_batch_id = v_ib2 AND old_unit_price IS NULL AND new_unit_price = P1;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 135 布景失效:首次计价那一行必须是 old_unit_price 空、new_unit_price = % —— "那天还没有价"整条推理靠的就是这个空值', P1;
    END IF;
    SELECT count(*) INTO v_n FROM price_history
     WHERE inbound_batch_id = v_ib2 AND old_unit_price = P1 AND new_unit_price = P2;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 135 布景失效:改价那一行必须是 old = %、new = %', P1, P2;
    END IF;
    SELECT unit_price INTO v_right FROM inbound_batches WHERE id = v_ib2;
    IF v_right IS DISTINCT FROM P2 THEN
        RAISE EXCEPTION 'FIXTURE 135 布景失效:改价之后批次上的现价应为 %,实得 %', P2, v_right;
    END IF;

    -- 一笔应收(AR 侧的舞台)
    INSERT INTO output_batches (material_id, code, quantity, remaining_qty, unit,
                                output_date, state, customer_id)
    VALUES (v_mat, 'ZZ-FIX135-OB', 50, 50, 'kg', d1, '库存中', v_cust) RETURNING id INTO v_ob;
    INSERT INTO sales_records (output_batch_id, customer_id, quantity, unit_price,
                               currency, fx_rate, amount_base, sale_date)
    VALUES (v_ob, v_cust, 50, 20, v_ccy, 1, 1000, d1) RETURNING id INTO v_sale;

    -- ══════════════════════════════════════════════════════════════════════
    -- A 臂 ·【截至今天 ≡ 今天】—— 逐行逐列,两个方向的差集都为空
    -- 这一臂必须排在最前:后面每一臂都会往库里加东西,而 H 臂会【刻意】
    -- 造出一处两边不相等的情形。
    -- ══════════════════════════════════════════════════════════════════════
    SELECT count(*) INTO v_n FROM (
        SELECT e->>'doc_kind' k, e->>'doc_code' c, (e->>'doc_date')::date d,
               (e->>'doc_value_base')::numeric v, (e->>'settled_base')::numeric s,
               (e->>'open_base')::numeric o, (e->>'days_outstanding')::int dd, e->>'bucket' b
          FROM jsonb_array_elements(ap_aging_asof()->'rows') e
        EXCEPT
        SELECT doc_kind, doc_code, doc_date, doc_value_base, settled_base,
               open_base, days_outstanding, bucket FROM ap_open_items) q;
    SELECT count(*) INTO v_n2 FROM (
        SELECT doc_kind, doc_code, doc_date, doc_value_base, settled_base,
               open_base, days_outstanding, bucket FROM ap_open_items
        EXCEPT
        SELECT e->>'doc_kind', e->>'doc_code', (e->>'doc_date')::date,
               (e->>'doc_value_base')::numeric, (e->>'settled_base')::numeric,
               (e->>'open_base')::numeric, (e->>'days_outstanding')::int, e->>'bucket'
          FROM jsonb_array_elements(ap_aging_asof()->'rows') e) q2;
    IF v_n <> 0 OR v_n2 <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 135A 失败:ap_aging_asof(今天) 与 ap_open_items 不是同一份答案 —— 函数多出 % 行、视图多出 % 行。【默认截至今天必须逐行复现今天的行为】', v_n, v_n2;
    END IF;

    SELECT count(*) INTO v_n FROM (
        SELECT e->>'doc_kind' k, e->>'doc_code' c, (e->>'sale_date')::date d,
               (e->>'amount_base')::numeric a, (e->>'settled_base')::numeric s,
               (e->>'credited_base')::numeric cr, (e->>'open_base')::numeric o,
               (e->>'days_outstanding')::int dd, e->>'bucket' b
          FROM jsonb_array_elements(ar_aging_asof()->'rows') e
        EXCEPT
        SELECT doc_kind, doc_code, sale_date, amount_base, settled_base,
               credited_base, open_base, days_outstanding, bucket FROM ar_open_items) q;
    SELECT count(*) INTO v_n2 FROM (
        SELECT doc_kind, doc_code, sale_date, amount_base, settled_base,
               credited_base, open_base, days_outstanding, bucket FROM ar_open_items
        EXCEPT
        SELECT e->>'doc_kind', e->>'doc_code', (e->>'sale_date')::date,
               (e->>'amount_base')::numeric, (e->>'settled_base')::numeric,
               (e->>'credited_base')::numeric, (e->>'open_base')::numeric,
               (e->>'days_outstanding')::int, e->>'bucket'
          FROM jsonb_array_elements(ar_aging_asof()->'rows') e) q2;
    IF v_n <> 0 OR v_n2 <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 135A 失败:ar_aging_asof(今天) 与 ar_open_items 不是同一份答案 —— 函数多出 % 行、视图多出 % 行。', v_n, v_n2;
    END IF;

    -- ★ 自证非空(其一):两张表都得【真的有行】,否则上面比的是两个空集
    IF jsonb_array_length(ap_aging_asof()->'rows') = 0
       OR jsonb_array_length(ar_aging_asof()->'rows') = 0 THEN
        RAISE EXCEPTION 'FIXTURE 135A 失败(空转):账龄为空,两个空集当然相等 —— 本臂什么都没测到';
    END IF;
    -- ★ 自证非空(其二):函数得【真的看那个日期】。d1 与今天的答案必须不同,
    --    否则一个把 p_as_of 整个忽略掉的实现也能通过 A 臂。
    IF (ap_aging_asof(d1)->>'total_open_base')::numeric
       = (ap_aging_asof()->>'total_open_base')::numeric THEN
        RAISE EXCEPTION 'FIXTURE 135A 失败(空转):截至 % 与截至今天的应付合计相等 —— 这个实现可能根本没读 p_as_of', d1;
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- D 臂 · ④ 金额:那天的价,以及【那天还没有价】
    -- 先跑 D,因为它只读不写,后面的付款会改变同一张批次的敞口。
    -- ══════════════════════════════════════════════════════════════════════
    IF P1 = P2 THEN
        RAISE EXCEPTION 'FIXTURE 135D 失败(空转):两次价相等,改价这件事没有发生';
    END IF;

    -- d1(计价当天):必须按 P1
    SELECT (e->>'doc_value_base')::numeric INTO v_right
      FROM jsonb_array_elements(ap_aging_asof(d1)->'rows') e
     WHERE (e->>'doc_id')::uuid = v_ib;
    IF v_right IS DISTINCT FROM round(QTY * P1, 2) THEN
        RAISE EXCEPTION 'FIXTURE 135D 失败:截至 % 应付额应为 %(= % × 首价 %),实得 %',
            d1, round(QTY*P1,2), QTY, P1, COALESCE(v_right::text, '(没有这一行)');
    END IF;
    -- ★ 天真实现(用今天的价)会给出的数,必须与正确答案不同
    IF round(QTY * P1, 2) = round(QTY * P2, 2) THEN
        RAISE EXCEPTION 'FIXTURE 135D 失败(空转):两个口径给出同一个数';
    END IF;

    -- d2(改价当天)与今天:必须按 P2
    SELECT (e->>'doc_value_base')::numeric INTO v_right
      FROM jsonb_array_elements(ap_aging_asof(d2)->'rows') e
     WHERE (e->>'doc_id')::uuid = v_ib;
    IF v_right IS DISTINCT FROM round(QTY * P2, 2) THEN
        RAISE EXCEPTION 'FIXTURE 135D 失败:截至 %(改价当天)应付额应为 %,实得 %',
            d2, round(QTY*P2,2), COALESCE(v_right::text, '(没有这一行)');
    END IF;

    -- d0(到货了、但还没有价):这一行【必须整个缺席】。
    -- 天真实现会在这里印出 % × 今天的价 —— 一笔那天根本不存在的可计量应付。
    SELECT count(*) INTO v_n
      FROM jsonb_array_elements(ap_aging_asof(d0)->'rows') e
     WHERE (e->>'doc_id')::uuid = v_ib;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 135D 失败:截至 %(尚未计价)那张批次必须缺席,实得 % 行 —— 它印出来的是一个 % 才定下来的价',
            d0, v_n, d1;
    END IF;
    -- 而缺席要【说得出数目】,不能与"本来就没有这笔应付"长得一样
    IF (ap_aging_asof(d0)->>'unpriced_excluded')::int < 1 THEN
        RAISE EXCEPTION 'FIXTURE 135D 失败:截至 % 至少有一张批次因【那天还没有价】被挡掉,而 unpriced_excluded 报的是 % —— 一个不报数的缺席与不存在无从分辨',
            d0, (ap_aging_asof(d0)->>'unpriced_excluded');
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- B 臂 · ② 结清:d3 那天付的钱,不许渗回 d3 之前
    -- ══════════════════════════════════════════════════════════════════════
    v_res := record_payment('out', v_sup, PAYAMT, v_ccy, NULL, v_bank, d3,
        'fixture 135 部分付',
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib, 'amount_doc', PAYAMT)),
        'supplier');
    v_pay := (v_res->>'payment_id')::uuid;

    SELECT (e->>'settled_base')::numeric INTO v_naive
      FROM jsonb_array_elements(ap_aging_asof(d3 - 1)->'rows') e
     WHERE (e->>'doc_id')::uuid = v_ib;
    SELECT (e->>'settled_base')::numeric INTO v_right
      FROM jsonb_array_elements(ap_aging_asof(d3)->'rows') e
     WHERE (e->>'doc_id')::uuid = v_ib;
    IF COALESCE(v_naive, -1) <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 135B 失败:截至 %(付款【前】一天)已结额必须是 0,实得 % —— % 付的钱渗回去了',
            d3 - 1, COALESCE(v_naive::text,'(没有这一行)'), d3;
    END IF;
    IF v_right IS DISTINCT FROM PAYAMT THEN
        RAISE EXCEPTION 'FIXTURE 135B 失败:截至 %(付款当天)已结额应为 %,实得 %',
            d3, PAYAMT, COALESCE(v_right::text,'(没有这一行)');
    END IF;
    -- ★ 自证非空:两个日子必须给出【不同】的答案
    IF v_naive = v_right THEN
        RAISE EXCEPTION 'FIXTURE 135B 失败(空转):付款前后已结额相同 —— 这一笔付款没有被任何一侧看见';
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- C 臂 · ② 的另一半:**一笔在 D 之后【才被冲销】的付款,在 D 那天仍然算数**
    --
    -- 【这是线上数据【测不出来】的那一条,所以它必须靠故障注入】实测线上四笔
    -- 冲销付款,冲销日全都不晚于原单日期(有一笔甚至更早),于是"冲销发生在 D
    -- 之后"这个场景在真实数据里一次都没有出现过。而它恰恰是"今天的视图按
    -- status='posted' 过滤"这件事在 as-at 上的落点 —— 不注入就永远不会被验到。
    -- reverse_payment 把镜像单记成 CURRENT_DATE,所以冲销日恒为【今天】> d3。
    -- ══════════════════════════════════════════════════════════════════════
    PERFORM reverse_payment(v_pay, 'fixture 135 冲销');

    SELECT (e->>'settled_base')::numeric INTO v_right
      FROM jsonb_array_elements(ap_aging_asof(d3)->'rows') e
     WHERE (e->>'doc_id')::uuid = v_ib;
    SELECT (e->>'settled_base')::numeric INTO v_naive
      FROM jsonb_array_elements(ap_aging_asof()->'rows') e
     WHERE (e->>'doc_id')::uuid = v_ib;
    IF v_right IS DISTINCT FROM PAYAMT THEN
        RAISE EXCEPTION 'FIXTURE 135C 失败:截至 % 那笔付款【当时是站着的】,已结额应为 %,实得 % —— 一次今天才发生的冲销回溯改写了 % 的历史',
            d3, PAYAMT, COALESCE(v_right::text,'(没有这一行)'), d3;
    END IF;
    IF COALESCE(v_naive, -1) <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 135C 失败:截至今天那笔付款已被冲销,已结额应为 0,实得 %',
            COALESCE(v_naive::text,'(没有这一行)');
    END IF;
    -- ★ 自证非空:冲销必须【真的】把两个日子分开
    IF v_right = v_naive THEN
        RAISE EXCEPTION 'FIXTURE 135C 失败(空转):冲销前后答案相同 —— 冲销的形状变了吗?';
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- E 臂 · ③ 单据存在与否:一张在 D 之后【才被冲销】的费用单,在 D 那天还在
    -- ══════════════════════════════════════════════════════════════════════
    v_res := record_expense(
        p_expense_date := d1, p_account_code := '6120', p_amount := 750,
        p_currency := v_ccy, p_payment_status := 'unpaid',
        p_supplier_id := v_sup, p_notes := 'fixture 135 会被冲销的费用');
    v_exp := (v_res->>'expense_id')::uuid;

    SELECT count(*) INTO v_n
      FROM jsonb_array_elements(ap_aging_asof(d1)->'rows') e WHERE (e->>'doc_id')::uuid = v_exp;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 135E 失败:费用单刚记下来,截至 % 必须在账龄里,实得 % 行', d1, v_n;
    END IF;

    PERFORM reverse_expense(v_exp, 'fixture 135 冲销费用');

    SELECT count(*) INTO v_n
      FROM jsonb_array_elements(ap_aging_asof(d1)->'rows') e WHERE (e->>'doc_id')::uuid = v_exp;
    SELECT count(*) INTO v_n2
      FROM jsonb_array_elements(ap_aging_asof()->'rows') e WHERE (e->>'doc_id')::uuid = v_exp;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 135E 失败:截至 % 那张费用单【当时是站着的】,必须仍在账龄里,实得 % 行 —— 一次今天才发生的冲销回溯抹掉了它', d1, v_n;
    END IF;
    IF v_n2 <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 135E 失败:截至今天那张费用单已被冲销,必须缺席,实得 % 行', v_n2;
    END IF;
    -- ★ 自证非空:两个日子必须分家
    IF v_n = v_n2 THEN
        RAISE EXCEPTION 'FIXTURE 135E 失败(空转):冲销前后在场情况相同';
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- F 臂 · 未来日期【按名】拒,两侧都拒
    -- ══════════════════════════════════════════════════════════════════════
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM ap_aging_asof(CURRENT_DATE + 1);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR position('AGING_AS_OF_FUTURE' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 135F 失败:应付账龄的未来日期必须按名拒(AGING_AS_OF_FUTURE),实得:%',
            COALESCE(v_msg, '(通过了)');
    END IF;
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM ar_aging_asof(CURRENT_DATE + 1);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR position('AGING_AS_OF_FUTURE' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 135F 失败:应收账龄的未来日期必须按名拒(AGING_AS_OF_FUTURE),实得:%',
            COALESCE(v_msg, '(通过了)');
    END IF;
    -- 而【今天】必须【不】被拒 —— 否则一个"什么都拒"的实现也能通过上面两条
    PERFORM ap_aging_asof(CURRENT_DATE);
    PERFORM ar_aging_asof(CURRENT_DATE);

    -- ══════════════════════════════════════════════════════════════════════
    -- G 臂 · 档位边界只有【一处】定义 —— 目录断言,不是数字断言
    -- ══════════════════════════════════════════════════════════════════════
    SELECT array_agg(o ORDER BY o) INTO v_objs FROM (
        SELECT 'ap_open_items'::text AS o WHERE pg_get_viewdef('public.ap_open_items'::regclass, true) LIKE '%aging_bucket%'
        UNION ALL
        SELECT 'ar_open_items' WHERE pg_get_viewdef('public.ar_open_items'::regclass, true) LIKE '%aging_bucket%'
        UNION ALL
        SELECT 'ap_aging_asof' WHERE pg_get_functiondef('public.ap_aging_asof(date)'::regprocedure) LIKE '%aging_bucket%'
        UNION ALL
        SELECT 'ar_aging_asof' WHERE pg_get_functiondef('public.ar_aging_asof(date)'::regprocedure) LIKE '%aging_bucket%'
    ) q;
    IF v_objs IS NULL OR array_length(v_objs, 1) <> 4 THEN
        RAISE EXCEPTION 'FIXTURE 135G 失败:四条档位边界必须【全部】走 aging_bucket(),实际引用它的只有:% —— 有人把 CASE 抄回去了,而抄回去的那一份会与这一份漂开',
            COALESCE(array_to_string(v_objs, ', '), '(一个都没有)');
    END IF;
    -- 而 aging_bucket 本身的四条边界要真的是那四条(否则"一处定义"定的是错的)
    IF aging_bucket(30) <> 'b0_30' OR aging_bucket(31) <> 'b31_60'
       OR aging_bucket(60) <> 'b31_60' OR aging_bucket(61) <> 'b61_90'
       OR aging_bucket(90) <> 'b61_90' OR aging_bucket(91) <> 'b90_plus'
       OR aging_bucket(NULL) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 135G 失败:aging_bucket 的边界不对(30/31/60/61/90/91/NULL 六个端点逐一检查)';
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- J 臂 · 金额口径的【令牌】就是屏幕那侧认识的那两个
    --
    -- 【为什么值得一条臂】amount_basis 是一个机器令牌,措辞按语言挂在
    -- messages/ 上,后缀集合由 app/finance/agingAsOf.ts 的 AMOUNT_BASES 声明,
    -- check-i18n 从那一行现读。**但没有任何东西保证库这一侧吐的就是那两个。**
    -- 库改了令牌名 → 前端 t('finance.agingAsOf.basis.' || 令牌) 找不到键 →
    -- i18n 解析器把【键本身】原样印到屏幕上,而构建与 gate 全绿。
    -- docs/machine-text-reaching-humans.md 记的正是这一类,所以在这里钉住。
    -- ══════════════════════════════════════════════════════════════════════
    IF (ap_aging_asof()->>'amount_basis') <> 'quantity_now_price_asof' THEN
        RAISE EXCEPTION 'FIXTURE 135J 失败:AP 的 amount_basis 应为 quantity_now_price_asof,实得 % —— 改了令牌名就要同时改 app/finance/agingAsOf.ts 的 AMOUNT_BASES 与 messages/ 两个语言,否则屏幕上会印出键本身',
            (ap_aging_asof()->>'amount_basis');
    END IF;
    IF (ar_aging_asof()->>'amount_basis') <> 'amounts_as_recorded' THEN
        RAISE EXCEPTION 'FIXTURE 135J 失败:AR 的 amount_basis 应为 amounts_as_recorded,实得 %',
            (ar_aging_asof()->>'amount_basis');
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- I 臂 · 截止日早于系统起算日时,报表【在自己脸上说出来】(不拒绝)
    -- ══════════════════════════════════════════════════════════════════════
    UPDATE finance_settings SET system_start_date = d2;
    IF (ap_aging_asof(d1)->>'before_system_start')::boolean IS NOT TRUE THEN
        RAISE EXCEPTION 'FIXTURE 135I 失败:截至 % 早于系统起算日 %,before_system_start 必须为真', d1, d2;
    END IF;
    IF (ap_aging_asof(d2)->>'before_system_start')::boolean IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 135I 失败:截至起算日当天,before_system_start 必须为假(边界写在闭区间上 —— FIN-13 那条教训)';
    END IF;
    -- 而它【不拒绝】:早于起算日的那一天照样出得了报表
    IF jsonb_array_length(ap_aging_asof(d1)->'rows') = 0 THEN
        RAISE EXCEPTION 'FIXTURE 135I 失败:早于系统起算日只该【说一句】,不该把报表变空';
    END IF;
    UPDATE finance_settings SET system_start_date = NULL;

    -- ══════════════════════════════════════════════════════════════════════
    -- H 臂 · 一处【刻意的分歧】,排在最后(它会破坏 A 臂的全量差集)
    -- 单据日期晚于 D 的单据,as-at 函数不收;而今天那张视图的进料支没有日期
    -- 过滤,所以它收。两边【不一样】是对的,而这一臂让它成为被断言的行为。
    -- ══════════════════════════════════════════════════════════════════════
    INSERT INTO inbound_batches (material_id, supplier_id, quantity, unit, remaining_qty,
                                 arrival_date, unit_price, pricing_status, status)
    VALUES (v_mat, v_sup, 10, 'kg', 10, CURRENT_DATE + 30, 99, 'final', 'active')
    RETURNING id INTO v_ib_future;

    SELECT count(*) INTO v_n
      FROM jsonb_array_elements(ap_aging_asof()->'rows') e WHERE (e->>'doc_id')::uuid = v_ib_future;
    SELECT count(*) INTO v_n2 FROM ap_open_items WHERE doc_id = v_ib_future;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 135H 失败:一张 30 天后才到货的批次不是今天的应付,as-at 函数必须不收,实得 % 行', v_n;
    END IF;
    IF v_n2 <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 135H 失败:今天那张视图【确实】会收未来到货的批次(它的进料支没有日期过滤),实得 % 行 —— 若这里变成 0,说明视图也加上了日期过滤,那么本臂记的这处分歧已经消失,请连同 ap_aging_asof 的抬头一起改掉这段说明', v_n2;
    END IF;
END $$;
ROLLBACK;
