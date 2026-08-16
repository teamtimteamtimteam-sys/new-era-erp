-- 80 一个报表数字背后的那些行,合计【就是】那个数字 —— 两个口径都要成立
--
-- 【它守的是什么】FIN-DRILL 把损益表与资产负债表共用的那段推导(三表连接、
-- 刻意不过滤 status、一条符号规则)提到 journal_activity_lines,再让第三个读者
-- account_ledger 读它。于是"明细合计 = 报表数字"这件事【是构造出来的】,
-- 而不是碰巧的 —— 这份 fixture 钉住的正是那个构造。
--
-- 【那它不是在拿一个数跟它自己比吗?—— 不是,而这一句必须写清楚】
-- (AGENTS.md/OPS-17:两个数只有能分开动,才算一个对账。)
-- 算术确实只有一份,所以【算术错】这一类它抓不到,本文件不假装抓得到。
-- 它抓的是另外三类,每一类都能让两边分开动,而且每一类都在下面有一条注入:
--   ① 两个开关配错(年结口径拿反 / 日期形状拿反)—— C、D 臂;
--   ② 推导本身被"顺手修平"(加回 status 过滤)—— F 臂,两边【同时】错,
--      但错法不同:报表少一笔、明细也少一笔,而【手算出来的那个数】不动,
--      所以断言字面量的 A 臂会响。这就是 A 臂必须断言手算值而不是只断言
--      "两边相等"的原因 —— 只断言相等,①抓得到,②抓不到。
--   ③ 科目不存在被当成"没有分录"—— E 臂。
--
-- 【断言的数怎么来的】全部由本 fixture 自己插入的金额算出,写在赋值处;
-- 不引用任何引导数据的余额(README 第 1、4 条)。
--
-- 【为什么必须有【冲销对】】这是这段推导存在的头号理由:被冲销的原分录
-- status='reversed',冲销分录 status='posted' 且等额反向。只留 posted 会
-- 丢掉原分录、留下冲销分录,净额刚好错成 −原分录。所以本 fixture 造一对,
-- 并让手算值把它们【一起】算进去(净额为零)。
--
-- 【权限臂:另一个模块看到的是"没有",不是一张空表】(第 6 条那一族)
-- account_ledger 是 SECURITY DEFINER + require_permission,读的是
-- request.jwt.claims —— 与数据库角色无关,所以这一臂不切 SET LOCAL ROLE 也有效。
-- 换成一个只持【别的模块】权限的主体,必须被拒绝,而不是拿到零行。
BEGIN;
DO $$
DECLARE
    v_fin  uuid := gen_random_uuid();   -- module.finance.view
    v_ops  uuid := gen_random_uuid();   -- 只有 module.processing.view
    r_fin uuid; r_ops uuid;
    a_cash uuid; a_rev uuid; a_cogs uuid; a_eq uuid;
    e_sale uuid; e_cogs uuid; e_close uuid; e_orig uuid; e_rev uuid;
    v_ccy text;

    -- ── 本 fixture 自己的金额,断言值全部由它们算出 ─────────────────────────
    v_rev_amt   numeric := 8000.00;   -- 一笔销售:借 1000 / 贷 4000
    v_cogs_amt  numeric := 3000.00;   -- 对应成本:借 5000 / 贷 1000
    v_oops_amt  numeric := 1500.00;   -- 一笔【记错又冲销】的收入:借 1000 / 贷 4000
    v_net       numeric;              -- = v_rev_amt − v_cogs_amt
    -- 4000 是收入(贷正)。手算:正常销售 +8000,记错的那笔 +1500,冲销 −1500。
    -- 冲销对净额为零 —— 而"只留 posted"会给出 −1500,"只留原分录"会给出 +1500。
    v_rev_expect  numeric;
    -- 1000 是资产(借正)。手算:销售收现 +8000,付成本 −3000,记错 +1500,冲销 −1500。
    v_cash_expect numeric;

    led jsonb; p jsonb; b jsonb;
    v_fig numeric; v_denied boolean;
BEGIN
    v_net         := v_rev_amt - v_cogs_amt;
    v_rev_expect  := v_rev_amt + v_oops_amt - v_oops_amt;   -- = 8000.00
    v_cash_expect := v_rev_amt - v_cogs_amt + v_oops_amt - v_oops_amt;  -- = 5000.00

    SELECT code INTO v_ccy FROM currencies WHERE is_base;   -- 币种是数据,不是常量
    SELECT id INTO a_cash FROM accounts WHERE code = '1000';
    SELECT id INTO a_rev  FROM accounts WHERE code = '4000';
    SELECT id INTO a_cogs FROM accounts WHERE code = '5000';
    SELECT id INTO a_eq   FROM accounts WHERE code = '3100';
    IF a_cash IS NULL OR a_rev IS NULL OR a_cogs IS NULL OR a_eq IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 80 前置失败:科目表缺 1000/3100/4000/5000 之一 —— 四个都是 is_system 的引导科目';
    END IF;

    -- ── 角色:自建,不借引导角色(README「权限」一节)────────────────────────
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-80-fin', 'f', 'f', true) RETURNING id INTO r_fin;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_fin, 'module.finance.view');
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-80-ops', 'f', 'f', true) RETURNING id INTO r_ops;
    -- 【只持别的模块】—— 不是"什么都没有"。权限臂要证明的是【模块边界】,
    -- 而一个空角色只能证明"没有权限的人被拒",那是一句更弱的话。
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_ops, 'module.processing.view');
    INSERT INTO user_roles (user_id, role_id) VALUES (v_fin, r_fin), (v_ops, r_ops);

    -- ── 数据:2028 年整年,本 fixture 自己的五张分录 ────────────────────────
    -- 用 2028 是为了与任何引导数据、以及 fixture 28 的 2027 都不相干。
    INSERT INTO journal_entries (code, entry_date, memo, source_type)
    VALUES ('FIX80-SALE', '2028-05-20', 'fixture 80 sale', 'sale') RETURNING id INTO e_sale;
    INSERT INTO journal_lines (entry_id, account_id, debit, credit, currency, amount_ccy, fx_rate)
    VALUES (e_sale, a_cash, v_rev_amt, 0, v_ccy, v_rev_amt, 1),
           (e_sale, a_rev,  0, v_rev_amt, v_ccy, v_rev_amt, 1);

    INSERT INTO journal_entries (code, entry_date, memo, source_type)
    VALUES ('FIX80-COGS', '2028-05-21', 'fixture 80 cost', 'processing_cost') RETURNING id INTO e_cogs;
    INSERT INTO journal_lines (entry_id, account_id, debit, credit, currency, amount_ccy, fx_rate)
    VALUES (e_cogs, a_cogs, v_cogs_amt, 0, v_ccy, v_cogs_amt, 1),
           (e_cogs, a_cash, 0, v_cogs_amt, v_ccy, v_cogs_amt, 1);

    -- ── 冲销对:原分录 reversed,冲销分录 posted、等额反向 ───────────────────
    -- 直接写 status,不走 reverse_journal_entry —— 本 fixture 要的是这两行的
    -- 【形状】,不是冲销那条路的行为(那是别处的事)。
    INSERT INTO journal_entries (code, entry_date, memo, source_type, status)
    VALUES ('FIX80-OOPS', '2028-06-10', 'fixture 80 mis-keyed sale', 'sale', 'posted')
    RETURNING id INTO e_orig;
    INSERT INTO journal_lines (entry_id, account_id, debit, credit, currency, amount_ccy, fx_rate)
    VALUES (e_orig, a_cash, v_oops_amt, 0, v_ccy, v_oops_amt, 1),
           (e_orig, a_rev,  0, v_oops_amt, v_ccy, v_oops_amt, 1);

    INSERT INTO journal_entries (code, entry_date, memo, source_type, status)
    VALUES ('FIX80-OOPS-R', '2028-06-11', 'fixture 80 reversal', 'sale', 'posted')
    RETURNING id INTO e_rev;
    INSERT INTO journal_lines (entry_id, account_id, debit, credit, currency, amount_ccy, fx_rate)
    VALUES (e_rev, a_rev,  v_oops_amt, 0, v_ccy, v_oops_amt, 1),
           (e_rev, a_cash, 0, v_oops_amt, v_ccy, v_oops_amt, 1);

    UPDATE journal_entries SET status = 'reversed', reversed_by = e_rev WHERE id = e_orig;

    -- 年结:把损益科目冲平,净额落到 3100,落在财年末日。
    INSERT INTO journal_entries (code, entry_date, memo, source_type)
    VALUES ('FIX80-CLOSE', '2028-12-31', 'fixture 80 year close', 'year_close') RETURNING id INTO e_close;
    INSERT INTO journal_lines (entry_id, account_id, debit, credit, currency, amount_ccy, fx_rate)
    VALUES (e_close, a_rev,  v_rev_expect, 0, v_ccy, v_rev_expect, 1),
           (e_close, a_cogs, 0, v_cogs_amt, v_ccy, v_cogs_amt, 1),
           (e_close, a_eq,   0, v_rev_expect - v_cogs_amt, v_ccy, v_rev_expect - v_cogs_amt, 1);

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_fin), true);

    -- ══════════ A. 期间口径(损益表下钻):明细合计 = 手算值 = 报表数字 ═══════
    -- 【先断言手算值,再断言与报表相等】—— 顺序是有意的:只断言"两边相等",
    -- 一次把两边【同时】改错的改动(例如给共享推导加回 status 过滤)会照样通过。
    led := account_ledger('4000', '2028-01-01', '2028-12-31', false);
    p   := pnl_statement('2028-01-01', '2028-12-31');

    IF (led->>'total')::numeric <> v_rev_expect THEN
        RAISE EXCEPTION 'FIXTURE 80A 失败:4000 的明细合计应为 %(= % 正常销售 + % 记错 − % 冲销),实得 % —— 若为 % 就是只数了冲销分录(status 过滤回来了);若为 % 就是只数了原分录',
            v_rev_expect, v_rev_amt, v_oops_amt, v_oops_amt, led->>'total',
            v_rev_amt - v_oops_amt, v_rev_amt + v_oops_amt;
    END IF;
    IF (led->>'line_count')::int <> 3 THEN
        RAISE EXCEPTION 'FIXTURE 80A 失败:4000 在该期间应有 3 行(销售、记错、冲销;年结被剔除),实得 %',
            led->>'line_count';
    END IF;

    SELECT (x->>'amount')::numeric INTO v_fig
      FROM jsonb_array_elements(p->'revenue'->'rows') x WHERE x->>'code' = '4000';
    IF v_fig IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 80A 失败:损益表在该期间没有报 4000 这一行 —— 明细有 3 行,报表却不报它';
    END IF;
    IF v_fig <> (led->>'total')::numeric THEN
        RAISE EXCEPTION 'FIXTURE 80A 失败:损益表报 %,明细合计 % —— 下钻与它要对账的那张报表对不上',
            v_fig, led->>'total';
    END IF;

    -- ══════════ B. 累计口径(资产负债表下钻):同一条断言,另一个形状 ═════════
    -- 【两个口径都要单独断言】—— 一个只对了期间形状的实现,B 臂会响;
    -- 一个只对了累计形状的实现,A 臂会响。合起来才说明两个开关都接对了。
    led := account_ledger('1000', NULL, '2028-12-31', true);
    b   := balance_sheet('2028-12-31');

    IF (led->>'total')::numeric <> v_cash_expect THEN
        RAISE EXCEPTION 'FIXTURE 80B 失败:1000 的累计明细合计应为 %(= % 收现 − % 付成本 + % 记错 − % 冲销),实得 %',
            v_cash_expect, v_rev_amt, v_cogs_amt, v_oops_amt, v_oops_amt, led->>'total';
    END IF;

    SELECT (x->>'net')::numeric INTO v_fig
      FROM jsonb_array_elements(b->'asset'->'rows') x WHERE x->>'code' = '1000';
    IF v_fig IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 80B 失败:资产负债表没有报 1000 这一行';
    END IF;
    IF v_fig <> (led->>'total')::numeric THEN
        RAISE EXCEPTION 'FIXTURE 80B 失败:资产负债表报 %,明细合计 % —— 累计口径的下钻对不上',
            v_fig, led->>'total';
    END IF;

    -- 明细里必须【确实】看得见那对冲销(否则 A/B 两臂可能只是碰巧相等)
    IF NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(led->'rows') x
        WHERE x->>'entry_status' = 'reversed')
    THEN
        RAISE EXCEPTION 'FIXTURE 80B 失败:明细里没有任何 status=reversed 的行 —— 被冲销的原分录被丢掉了,而它必须在(丢掉它,合计会错成 −原分录)';
    END IF;

    -- ══════════ C. 年结开关是【load-bearing】的,不是装饰 ═════════════════════
    -- 同一个科目、同一个截止日,只把开关翻一下,答案【必须】不同。
    -- 若相同,说明开关根本没接上去 —— 而那时 A、B 两臂照样绿。
    IF (account_ledger('4000', NULL, '2028-12-31', true )->>'total')::numeric
     = (account_ledger('4000', NULL, '2028-12-31', false)->>'total')::numeric THEN
        RAISE EXCEPTION 'FIXTURE 80C 失败:4000 含年结与剔除年结给出同一个合计 —— 那个开关没有接上';
    END IF;
    -- 而且方向要对:含年结时 4000 被冲平(结转把它借回去),合计应为 0。
    IF (account_ledger('4000', NULL, '2028-12-31', true)->>'total')::numeric <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 80C 失败:含年结时 4000 应被结转冲平为 0,实得 %',
            (account_ledger('4000', NULL, '2028-12-31', true)->>'total')::numeric;
    END IF;

    -- ══════════ D. 日期形状也是 load-bearing 的 ═══════════════════════════════
    -- 累计(不设起点)与期间(设了起点)必须不同 —— 本 fixture 的 1000 在
    -- 2028-06-01 之前就有行,所以掐掉起点会少算。
    IF (account_ledger('1000', NULL,         '2028-12-31', true)->>'total')::numeric
     = (account_ledger('1000', '2028-06-01', '2028-12-31', true)->>'total')::numeric THEN
        RAISE EXCEPTION 'FIXTURE 80D 失败:累计口径与掐了起点的期间口径给出同一个合计 —— p_from 没有起作用';
    END IF;

    -- ══════════ E. 空 ≠ 错,而"科目不存在"≠"科目没有分录" ═════════════════════
    -- 存在但期间内无分录:具名的空状态(rows=[]、line_count=0、total=0),不抛错。
    led := account_ledger('4000', '2001-01-01', '2001-12-31', false);
    IF (led->>'line_count')::int <> 0
       OR (led->>'total')::numeric <> 0
       OR jsonb_array_length(led->'rows') <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 80E 失败:空期间应给出 line_count=0 / total=0 / rows=[],实得 % / % / %',
            led->>'line_count', led->>'total', led->'rows';
    END IF;
    -- 而它仍然要说得出【是哪个科目】—— 一个连科目名都没有的空答复,页面没法
    -- 渲染那句具名的空状态,只能渲染一张空表(正是 moduleGuard 抬头那条病)。
    IF led->'account'->>'code' <> '4000' THEN
        RAISE EXCEPTION 'FIXTURE 80E 失败:空期间的答复里丢了科目本身,实得 %', led->'account';
    END IF;

    -- 不存在的科目:【按名拒绝】,不是一个空集(mustRows / restRows 同一条)。
    v_denied := false;
    BEGIN
        PERFORM account_ledger('ZZ-NO-SUCH', '2028-01-01', '2028-12-31', false);
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'ACCOUNT_NOT_FOUND%' THEN
            RAISE EXCEPTION 'FIXTURE 80E 失败:不存在的科目应按名拒绝(ACCOUNT_NOT_FOUND|…),实得 %', SQLERRM;
        END IF;
        v_denied := true;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 80E 失败:不存在的科目竟然返回了一张空表 —— 打错科目号被显示成"这个期间没动过"';
    END IF;

    -- 期间与开关都不给默认值:漏了就拒,不 COALESCE 成今天/某一侧
    v_denied := false;
    BEGIN
        PERFORM account_ledger('4000', '2028-01-01', NULL, false);
    EXCEPTION WHEN OTHERS THEN v_denied := true;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 80E 失败:p_to 为空竟然通过了 —— 一个悄悄换了期间的明细表会与报表对不上,而看起来像报表错了';
    END IF;
    v_denied := false;
    BEGIN
        PERFORM account_ledger('4000', '2028-01-01', '2028-12-31', NULL);
    EXCEPTION WHEN OTHERS THEN v_denied := true;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 80E 失败:年结开关为空竟然通过了 —— 猜错它就是猜错了那条刻意的不对称';
    END IF;

    -- ══════════ F. 权限:另一个模块看到的是【拒绝】,不是零行 ═════════════════
    -- 【为什么是"另一个模块"而不是"什么都没有"】要证明的是模块边界本身。
    -- 一个持 module.processing.view 的人是这套系统里真实存在的读者(线上的
    -- operations 就是),而他不该读到总账 —— 而且要以【被拒】的方式知道,
    -- 不是拿到一张空表(那与"这个科目没动过"长得一模一样)。
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_ops), true);
    v_denied := false;
    BEGIN
        PERFORM account_ledger('4000', '2028-01-01', '2028-12-31', false);
    EXCEPTION WHEN OTHERS THEN v_denied := true;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 80F 失败:只持 module.processing.view 的主体读到了科目明细 —— 下钻页比它服务的报表松了一格';
    END IF;
    -- 对照:同一个主体读两张报表也必须被拒(否则上面那条可能只是碰巧)
    v_denied := false;
    BEGIN
        PERFORM pnl_statement('2028-01-01', '2028-12-31');
    EXCEPTION WHEN OTHERS THEN v_denied := true;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 80F 失败:只持 module.processing.view 的主体读到了损益表';
    END IF;
END $$;
ROLLBACK;
