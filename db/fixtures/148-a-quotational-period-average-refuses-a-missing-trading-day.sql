-- 148 PRICE-1:计价期均价 —— **交易日逐日,缺一天就拒**,而不是拿它碰巧有的那几天算
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【五个点名要躲开的陷阱,逐条写出这一支是怎么躲的】
--
--  (a) **一条断言之所以过,是因为两份实现碰巧一致。**
--      B 臂**把"会跳过的那个答案"也算出来**(剩下两天的均值 10500),
--      断言它与正确答案(11000)**不相等**,然后断言函数【拒绝】而不是返回 10500。
--      一个会跳过的实现在这里必定红,而且红在数字上,不是红在措辞上。
--
--  (b) **一条目录断言命中的是注释里的一次提及。**
--      H 臂查 information_schema / pg_constraint / pg_class.relrowsecurity /
--      pg_proc.prosecdef —— **目录事实**,不 grep 源码。
--      而且它**先断言该有的列在**,再断言不该有的列不在 ——
--      否则"没有 provisional 那一列"在一张【根本不存在的表】上也会通过。
--
--  (c) **一支 SECURITY DEFINER 函数没有权限检查。**
--      G 臂**真的换一个没权限的角色去调它**,断言按名拒;
--      H 臂另外断言 prosecdef = false —— 本函数根本不是 definer,
--      两头都占住:它是 invoker,而且自己还问了一次权限。
--
--  (d) **断言过了,是因为那个集合是空的。**
--      每一处比对之前先造出一个**会成功的**基线并断言出具体数字;
--      D 臂尤其要紧:"零个交易日"必须【拒绝】,而不是返回 0 或 NULL ——
--      一个把空集读成 0 的均价是本刀要消灭的那类答案。
--
--  (e) **一个什么都没注入的注入,长得和一个通过了的注入一模一样。**
--      末尾的注入先断言【定义真的变了】,变不了就当场报"这个注入什么也没删"。
--
-- 【本 fixture 钉住的东西】
--   A 日历没盖住这段期间 → 拒(而盖住了的那段能算出数)
--   B ★★ 缺一个交易日的报价 → 拒,**而不是拿剩下那些天算一个均值** ★★
--   C ★ 同一天、同样没有报价,【市场关着】与【该有没录】给出两个不同的答案 ★
--   D 零个交易日 → 拒(空集不是 0)
--   E M+n 落在正确的自然月上
--   F 同一天两条报价【插不进去】—— 保证由表上那条唯一约束给出,不是由本函数
--   G 权限【按名】拒,补回权限就放行(证明那不是死路)
--   H 目录事实(含那个【刻意的缺席】:没有暂定价那一列)
--   I 抄不是引用:改合同,已挂单据的计价条款副本【逐字节不变】
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '180s';
DO $$
DECLARE
    v_user    uuid := gen_random_uuid();
    r_all     uuid;
    v_cust    uuid;
    v_con     uuid;
    v_so      uuid;
    v_r       jsonb;
    v_before  jsonb; v_after jsonb;
    v_n       integer;
    v_naive   numeric;
    v_strict  numeric;
    v_denied  boolean; v_msg text;
    v_f       date; v_t date;
    def_avg   text; v_inj text;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-148', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);
    UPDATE finance_settings SET locked_before = NULL;
    def_avg := pg_get_functiondef('public.index_period_average(text,text,date,date)'::regprocedure);

    -- ══════════ 造一段【完全可算】的基线 ═══════════════════════════════════
    -- 2026-09-01..05:三个交易日各有报价,两天休市且没有报价。
    -- 用 LME(quote_currency = 'USD')是刻意的:USD 不需要汇率,
    -- 于是这一支钉的是【均价的规矩】,不会被一次缺汇率带偏。
    INSERT INTO index_market_calendar (index_code, calendar_date, is_trading_day, note) VALUES
        ('LME', DATE '2026-09-01', true,  'fixture 148'),
        ('LME', DATE '2026-09-02', true,  'fixture 148'),
        ('LME', DATE '2026-09-03', true,  'fixture 148'),
        ('LME', DATE '2026-09-04', false, 'fixture 148:市场关着'),
        ('LME', DATE '2026-09-05', false, 'fixture 148:市场关着');
    INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date, source, price_index) VALUES
        ('ni', 10000, DATE '2026-09-01', 'published_index', 'LME'),
        ('ni', 11000, DATE '2026-09-02', 'published_index', 'LME'),
        ('ni', 12000, DATE '2026-09-03', 'published_index', 'LME');

    v_r := index_period_average('LME', 'ni', DATE '2026-09-01', DATE '2026-09-05');
    v_strict := (v_r->>'avg_usd_per_tonne')::numeric;
    -- 【陷阱 d】先钉住一个【具体的数字】,而不是"它没报错"
    IF v_strict <> 11000 THEN
        RAISE EXCEPTION 'FIXTURE 148 基线失败:三个交易日 10000/11000/12000 的均价应当是 11000,实得 %', v_strict; END IF;
    IF (v_r->>'trading_days')::int <> 3 THEN
        RAISE EXCEPTION 'FIXTURE 148 基线失败:交易日应当是 3 天,实得 %', v_r->>'trading_days'; END IF;
    -- ★【C 臂的前一半:两天【市场关着】且没有报价,而它【不】妨碍算出均价】★
    --   这一句是 C 臂后一半的对照组 —— 没有它,C 臂证明不了日历是承重的。
    IF jsonb_array_length(v_r->'legs') <> 3 THEN
        RAISE EXCEPTION 'FIXTURE 148 基线失败:legs 应当逐日记下 3 条出处,实得 %', jsonb_array_length(v_r->'legs'); END IF;

    -- ══════════ A. 日历没盖住这段期间 → 拒 ═════════════════════════════════
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM index_period_average('LME', 'ni', DATE '2026-09-01', DATE '2026-09-06');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'QP_CALENDAR_NOT_COVERED|LME|2026-09-01|2026-09-06|2026-09-06%' THEN
        RAISE EXCEPTION 'FIXTURE 148A 失败:日历没盖住 09-06 应当按名拒,实得 %', COALESCE(v_msg,'(算出来了)'); END IF;

    -- ══════════ B. ★★ 缺一个交易日的报价 → 拒,而不是算剩下那些天 ★★ ═══════
    DELETE FROM metal_prices WHERE metal='ni' AND price_index='LME' AND price_date=DATE '2026-09-03';
    -- 【陷阱 a】把"会跳过的那个答案"也算出来,并断言它与正确答案【不相等】——
    -- 于是这一臂【不可能】因为两个答案碰巧一致而通过。
    SELECT avg(price_usd_per_tonne) INTO v_naive FROM metal_prices
     WHERE metal='ni' AND price_index='LME' AND price_date BETWEEN DATE '2026-09-01' AND DATE '2026-09-05';
    IF v_naive IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 148B 失败:剩下的那两天应当还在(否则这一臂比的是空集)'; END IF;
    IF v_naive = v_strict THEN
        RAISE EXCEPTION 'FIXTURE 148B 失败:会跳过的答案(%)与正确答案(%)相等 —— 这一臂证明不了任何事', v_naive, v_strict; END IF;
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM index_period_average('LME', 'ni', DATE '2026-09-01', DATE '2026-09-05');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'QP_QUOTE_MISSING|LME|ni|2026-09-03%' THEN
        RAISE EXCEPTION 'FIXTURE 148B 失败:★ 计价期内缺一个交易日的行情,应当按名拒,而不是拿剩下那 % 天算出 % ★ 实得 %',
            2, v_naive, COALESCE(v_msg,'(算出来了)'); END IF;
    -- 放回去,后面的臂要用这个基线
    INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date, source, price_index)
    VALUES ('ni', 12000, DATE '2026-09-03', 'published_index', 'LME');

    -- ══════════ C. ★ 同一天、同样没有报价,两个不同的答案 ★ ═════════════════
    -- 09-04 此刻是【市场关着】且没有报价 —— 基线证明了它不妨碍算出 11000。
    -- 现在把它改成【开市】,报价仍然没有 —— 必须当场拒。
    -- **同一天、同一处缺失,答案不同 → 日历是承重的,不是装饰。**
    UPDATE index_market_calendar SET is_trading_day = true
     WHERE index_code='LME' AND calendar_date=DATE '2026-09-04';
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM index_period_average('LME', 'ni', DATE '2026-09-01', DATE '2026-09-05');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'QP_QUOTE_MISSING|LME|ni|2026-09-04%' THEN
        RAISE EXCEPTION 'FIXTURE 148C 失败:★ 同一天从【关市】改成【开市】之后,缺报价应当当场拒 —— 否则这套系统分不开「市场关着」与「该有没录」★ 实得 %',
            COALESCE(v_msg,'(算出来了)'); END IF;
    UPDATE index_market_calendar SET is_trading_day = false
     WHERE index_code='LME' AND calendar_date=DATE '2026-09-04';
    -- 改回去之后必须又能算出【同一个数】—— 否则上面那次红可能来自别的原因
    IF (index_period_average('LME','ni',DATE '2026-09-01',DATE '2026-09-05')->>'avg_usd_per_tonne')::numeric <> 11000 THEN
        RAISE EXCEPTION 'FIXTURE 148C 失败:改回关市之后应当又是 11000 —— 否则 C 臂那次红来路不明'; END IF;

    -- ══════════ D. 零个交易日 → 拒(空集不是 0)═════════════════════════════
    INSERT INTO index_market_calendar (index_code, calendar_date, is_trading_day, note) VALUES
        ('LME', DATE '2026-09-10', false, 'fixture 148'),
        ('LME', DATE '2026-09-11', false, 'fixture 148'),
        ('LME', DATE '2026-09-12', false, 'fixture 148');
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM index_period_average('LME', 'ni', DATE '2026-09-10', DATE '2026-09-12');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'QP_NO_TRADING_DAYS|LME|2026-09-10|2026-09-12%' THEN
        RAISE EXCEPTION 'FIXTURE 148D 失败:一整段休市的期间【没有】均价,而不是 0 —— 实得 %', COALESCE(v_msg,'(算出来了)'); END IF;

    -- ══════════ E. M+n 落在正确的自然月上 ═══════════════════════════════════
    SELECT qp_from, qp_to INTO v_f, v_t FROM quotational_period(DATE '2026-08-15', 1);
    IF v_f <> DATE '2026-09-01' OR v_t <> DATE '2026-09-30' THEN
        RAISE EXCEPTION 'FIXTURE 148E 失败:8 月发货 M+1 应当是 09-01..09-30,实得 %..%', v_f, v_t; END IF;
    SELECT qp_from, qp_to INTO v_f, v_t FROM quotational_period(DATE '2026-08-15', 3);
    IF v_f <> DATE '2026-11-01' OR v_t <> DATE '2026-11-30' THEN
        RAISE EXCEPTION 'FIXTURE 148E 失败:8 月发货 M+3 应当是 11-01..11-30,实得 %..%', v_f, v_t; END IF;
    -- M+0 = 基准月本身(现实中确有这么约的)
    SELECT qp_from, qp_to INTO v_f, v_t FROM quotational_period(DATE '2026-08-15', 0);
    IF v_f <> DATE '2026-08-01' OR v_t <> DATE '2026-08-31' THEN
        RAISE EXCEPTION 'FIXTURE 148E 失败:M+0 应当是基准月本身 08-01..08-31,实得 %..%', v_f, v_t; END IF;
    -- 【陷阱 d】M+1 与 M+3 必须【不同】—— 否则上面三句可能都在读一个常量
    IF (SELECT qp_from FROM quotational_period(DATE '2026-08-15',1))
     = (SELECT qp_from FROM quotational_period(DATE '2026-08-15',3)) THEN
        RAISE EXCEPTION 'FIXTURE 148E 失败:M+1 与 M+3 算出了同一个月 —— 那说明 n 根本没被用上'; END IF;

    -- ══════════ F. 同一天两条报价【插不进去】—— 而那条保证不是本函数给的 ═════
    -- 【这一臂是本 fixture 自己改写过的,理由写下来】第一版在这里插第二条报价、
    -- 断言 index_period_average 按名拒 QP_DUPLICATE_QUOTE。**它当场撞在了表上**:
    --     UNIQUE NULLS NOT DISTINCT (metal, price_date, price_index)
    -- 也就是说那条拒绝**永远不可能触发** —— 是死代码,而一条永远不触发的具名拒绝
    -- 是一句系统兑现不了的承诺。函数里那段已经删掉(fu2),
    -- 这一臂改成断言【真正给出保证的那个东西】还在。
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conrelid='public.metal_prices'::regclass AND contype='u'
           AND pg_get_constraintdef(oid) ILIKE '%NULLS NOT DISTINCT%(metal, price_date, price_index)%') THEN
        RAISE EXCEPTION 'FIXTURE 148F 失败:metal_prices 上那条 (metal, price_date, price_index) 唯一约束不在了 —— 同一天可以有两条报价,而均值会把那一天静悄悄加权两次'; END IF;
    -- 【陷阱 d:证明它真的咬得动,而不是只在目录里躺着】
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date, source, price_index)
        VALUES ('ni', 99999, DATE '2026-09-02', 'published_index', 'LME');
    EXCEPTION WHEN unique_violation THEN v_denied := true; END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 148F 失败:第二条同日报价【插进去了】—— 那条唯一约束在目录里,却没有咬'; END IF;

    -- ══════════ G. 权限【按名】拒,补回就放行 ════════════════════════════════
    -- 【fixture 跑在 postgres 下会绕过 RLS】所以这一臂**真的换角色**。
    DELETE FROM role_permissions WHERE role_id=r_all AND permission_code='module.pricing.view';
    v_denied := false; v_msg := NULL;
    BEGIN
        EXECUTE 'SET LOCAL ROLE authenticated';
        PERFORM index_period_average('LME','ni',DATE '2026-09-01',DATE '2026-09-05');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    EXECUTE 'RESET ROLE';
    IF NOT v_denied OR v_msg NOT LIKE 'PRICING_PERMISSION_DENIED|module.pricing.view%' THEN
        RAISE EXCEPTION 'FIXTURE 148G 失败:没有 module.pricing.view 应当【按名】拒 —— 而不是让 RLS 把日历藏起来、报成一次「数据缺了」。实得 %',
            COALESCE(v_msg,'(算出来了)'); END IF;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_all, 'module.pricing.view');
    -- 【补回权限就放行 —— 证明上面那个拒绝不是一条死路】
    EXECUTE 'SET LOCAL ROLE authenticated';
    IF (index_period_average('LME','ni',DATE '2026-09-01',DATE '2026-09-05')->>'avg_usd_per_tonne')::numeric <> 11000 THEN
        EXECUTE 'RESET ROLE';
        RAISE EXCEPTION 'FIXTURE 148G 失败:补回权限之后应当算得出 11000 —— 否则上面那个拒绝不是一次测量'; END IF;
    EXECUTE 'RESET ROLE';

    -- ══════════ H. 目录事实(不 grep 源码)══════════════════════════════════
    -- 【先断言该有的在】否则"没有 provisional 那一列"在一张不存在的表上也会通过
    SELECT count(*) INTO v_n FROM information_schema.columns
     WHERE table_schema='public' AND table_name='contract_pricing_terms'
       AND column_name IN ('base_event','qp_months','index_code','payable_pct');
    IF v_n <> 4 THEN
        RAISE EXCEPTION 'FIXTURE 148H 失败:contract_pricing_terms 应当有那四列,实得 % —— 下面那句"没有暂定价列"会是一句空话', v_n; END IF;
    -- ★ 那个【刻意的缺席】:暂定价逐笔谈(§6.2),不是条款,所以这张表没有它 ★
    SELECT count(*) INTO v_n FROM information_schema.columns
     WHERE table_schema='public' AND table_name='contract_pricing_terms'
       AND (column_name ~* 'provisional|discount|deposit');
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 148H 失败:合同条款表上出现了暂定价/折扣一类的列(% 条)—— §6.2 裁定暂定价逐笔谈、不设合同级默认值,一个留空的格子迟早会被填', v_n; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname='contract_pricing_terms_one_per_metal' AND contype='u') THEN
        RAISE EXCEPTION 'FIXTURE 148H 失败:同一份合同同一种元素只规定一次那条唯一约束不在目录里'; END IF;
    IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid='public.index_market_calendar'::regclass) THEN
        RAISE EXCEPTION 'FIXTURE 148H 失败:index_market_calendar 没有开 RLS'; END IF;
    -- 【陷阱 c】两支新函数都【不是】SECURITY DEFINER
    SELECT count(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
     WHERE n.nspname='public' AND p.proname IN ('index_period_average','quotational_period')
       AND p.prosecdef;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 148H 失败:% 支新函数是 SECURITY DEFINER —— 而 definer 少一次权限检查正是本仓库点名过的陷阱', v_n; END IF;

    -- ══════════ I. 抄不是引用:改合同,已挂单据的计价条款【逐字节不变】═══════
    INSERT INTO customers (code, legal_name, country, payment_terms_days)
    VALUES ('ZZ148-C1', 'Fixture 148 Customer', 'SG', 30) RETURNING id INTO v_cust;
    INSERT INTO contracts (customer_id, kind, title, effective_from, status)
    VALUES (v_cust, 'offtake', 'Fixture 148 offtake', DATE '2026-01-01', 'active')
    RETURNING id INTO v_con;
    INSERT INTO contract_pricing_terms (contract_id, metal, base_event, qp_months, index_code, payable_pct)
    VALUES (v_con, 'ni', 'shipment', 1, 'LME', 70);
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES ('ZZ148-SO1', v_cust, DATE '2026-06-10', 'SGD', 1) RETURNING id INTO v_so;

    v_r := link_document_to_contract('sales_order', v_so, v_con);
    IF (v_r->>'pricing_terms_copied')::int <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 148I 失败:应当抄下 1 条计价条款,实得 %', v_r->>'pricing_terms_copied'; END IF;
    IF v_r->>'terms_frozen_note_code' <> 'TERMS_FROZEN_AT_LINK_TIME' THEN
        RAISE EXCEPTION 'FIXTURE 148I 失败:挂接的返回里应当带上"冻结时刻"的判词 —— 否则挂接的人事后才会发现自己冻的是哪一份'; END IF;

    SELECT pricing_terms INTO v_before FROM contract_document_terms WHERE sales_order_id = v_so;
    IF v_before IS NULL OR jsonb_array_length(v_before) <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 148I 失败:抄件不是一条计价条款 —— 下面那句比对会是一句空话'; END IF;

    -- ★ 把合同的计价条款改得面目全非 ★
    UPDATE contract_pricing_terms SET payable_pct = 95, qp_months = 3, base_event = 'arrival'
     WHERE contract_id = v_con AND metal = 'ni';

    SELECT pricing_terms INTO v_after FROM contract_document_terms WHERE sales_order_id = v_so;
    IF v_before IS DISTINCT FROM v_after THEN
        RAISE EXCEPTION 'FIXTURE 148I 失败:★ 改了合同之后,已挂单据抄下的计价条款变了 ★ 之前=% 之后=%',
            v_before, v_after; END IF;
    -- 【而合同确实变了 —— 否则"没变"什么也没证明】
    IF (SELECT payable_pct FROM contract_pricing_terms WHERE contract_id=v_con AND metal='ni') <> 95 THEN
        RAISE EXCEPTION 'FIXTURE 148I 失败:合同没有被改动 —— 这一臂因此证明不了任何事'; END IF;

    -- ══════════ 故障注入 —— 先证明"注入真的改了东西"(陷阱 e)═══════════════
    -- 注入:把"每个交易日都要有报价"那条拒绝短路掉,断言 B 臂当场瞎掉 ——
    -- 而且断言它返回的正是那个【会跳过的】答案,不是别的什么。
    v_inj := replace(def_avg, 'IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION ''QP_QUOTE_MISSING', 'IF false THEN
        RAISE EXCEPTION ''QP_QUOTE_MISSING');
    IF v_inj = def_avg THEN
        RAISE EXCEPTION 'FIXTURE 148 注入 失败:没找到 QP_QUOTE_MISSING 那条拒绝 —— 这个注入什么也没删'; END IF;
    EXECUTE v_inj;
    DELETE FROM metal_prices WHERE metal='ni' AND price_index='LME' AND price_date=DATE '2026-09-03';
    v_strict := (index_period_average('LME','ni',DATE '2026-09-01',DATE '2026-09-05')->>'avg_usd_per_tonne')::numeric;
    IF v_strict <> 10500 THEN
        RAISE EXCEPTION 'FIXTURE 148 注入 失败:短路掉那条拒绝之后,它应当返回【会跳过的】那个答案 10500,实得 % —— 说明这一臂守的不是我以为的那件事', v_strict; END IF;
    EXECUTE def_avg;   -- 放回去
    -- 恢复之后必须又拒 —— 否则"放回去了"只是一句话
    v_denied := false;
    BEGIN PERFORM index_period_average('LME','ni',DATE '2026-09-01',DATE '2026-09-05');
    EXCEPTION WHEN OTHERS THEN v_denied := true; END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 148 注入 失败:恢复定义之后应当又按名拒'; END IF;
END $$;
ROLLBACK;
