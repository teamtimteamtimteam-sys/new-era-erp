-- 142 预提税:债【全额】结清,而银行只走【净额】(WHT-1)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【这份 fixture 钉十件事】
--   · **代扣不是折扣** —— 供应商那张单闭合到零,银行只动净额,差额成为
--     一笔对 IRAS 的负债。三个数,一条分录,而它们两两不等(A 臂)。
--   · **税率是一项带日期的法定事实** —— 窗口外按名拒,不取最近的一条(B 臂)。
--   · **裁定属于【债务】,不属于收款人** —— 记单之后把供应商改成居民,
--     付款照样代扣(C 臂)。
--   · **部分付款按实付部分代扣**,而全额付清时 Σ 恰好等于单上冻的预期值(D 臂)。
--   · **每一条拒绝都真的拒**,逐条从函数体数出来(E 臂)。
--   · **欠 IRAS 的合计 ≡ 2150 的科目余额**,两条真正不同的推导路径(F 臂)。
--   · **告警清得掉,而清除只能由钱完成** —— 冲销汇款,它回来(G 臂)。
--   · **付款读的是债务冻下来的税率**,目录断言钉在那【一次赋值】上(H 臂)。
--   · **两支 SECURITY DEFINER 函数各自问过调用者是谁**(I 臂)。
--   · **欠 IRAS 多少这件事本身也问读者是谁** —— 属主权限视图的谓词(J 臂)。
--
-- ★★【三个反复出现的陷阱,这份 fixture 逐个躲开,并写明躲法】★★
--   ① **靠"两个实现碰巧一致"通过**:C 臂把【冻下来的身份】与【供应商现在的
--      身份】弄成【不同的两个值】,再断言代扣照样发生。一个"付款时现查
--      suppliers.tax_residence"的实现会扣 0,当场红。不制造这个差异,
--      两种实现给出一样的答案,而那样的断言什么都没证明(FIN-18 / CHASE-1)。
--   ② **目录断言匹配到注释**:H 臂先【剥掉注释行】,再匹配那【一次赋值】
--      (`v_wht_rate := v_doc.wht_rate_pct`),不是匹配 'wht_rate_pct' 这个
--      子串 —— 那个子串在函数体的注释里出现好几次(fixture 136 栽过的坑,
--      CHASE-1 的 I 臂又栽过一次)。
--   ③ **一支没有权限检查的 SECURITY DEFINER 函数**:I 臂【行为性地】证它 ——
--      把 claims 换成一个什么权限都没有的人,断言两支函数都拒。
--      这个形状在本仓库已经上线过两次、两次都由闸抓住,所以这里不写
--      "函数体里有 require_permission" 那种目录断言 —— 那只守措辞,不守行为。
--
-- 【每一条断言的非空转由构造保证,逐臂在断言旁写明】自带数据(README 第 2 条);
-- 期间锁与 GST 开关自己设(第 4/5 条)。
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    v_user   uuid := gen_random_uuid();
    v_nobody uuid := gen_random_uuid();
    r_all    uuid;
    v_sup    uuid; v_sup_res uuid; v_sup_null uuid;
    v_base   text; v_bank text;
    d_doc    date := date_trunc('month', CURRENT_DATE)::date;   -- 本月,避免跨月归属
    v_exp    uuid; v_exp2 uuid;
    v_res    jsonb; v_pay jsonb;
    v_gross  numeric := 10000;
    v_rate   numeric;
    v_wht    numeric; v_net numeric;
    v_dr2000 numeric; v_cr2150 numeric; v_crbank numeric;
    v_open   numeric; v_n int; v_msg text;
    v_month  date := date_trunc('month', CURRENT_DATE)::date;
    v_view   numeric; v_ledger numeric; v_unrem numeric;
    v_je     uuid; v_manual jsonb; v_remit jsonb;
    v_def    text; v_body text;
    v_frozen text; v_live text;
BEGIN
    -- ══════════════════ 布景 ══════════════════
    INSERT INTO auth.users (id) VALUES (v_user), (v_nobody);
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-142', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    -- v_nobody 【故意不给任何角色】—— I 臂要的就是"有账号、没权限"。

    -- 【前提显式设定，不继承】(README 第 4/5 条)
    --   · 期间锁 —— 本 fixture 全程要能过账;
    --   · GST 开关 —— 设成 false,因为本 fixture 与 GST 无关,而重建库的
    --     引导默认值就是 false。**写出来是为了让它是一个决定,不是一次继承**:
    --     真值一旦变成 true,record_expense 会开始要求税码,而那与本刀无关。
    UPDATE finance_settings SET locked_before = NULL, gst_registered = false;
    SELECT code INTO v_base FROM currencies WHERE is_base;
    v_bank := bank_account_for_currency(v_base);

    -- 三家供应商:非居民、居民、未申报 —— 三种身份各自要被证一次。
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type, tax_residence)
    VALUES ('ZZ-F142-NR', 'fixture 142 non-resident', 'SG', 'active', 'service_vendor', 'non_resident')
    RETURNING id INTO v_sup;
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type, tax_residence)
    VALUES ('ZZ-F142-R', 'fixture 142 resident', 'SG', 'active', 'service_vendor', 'resident')
    RETURNING id INTO v_sup_res;
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type, tax_residence)
    VALUES ('ZZ-F142-U', 'fixture 142 unstated', 'CN', 'active', 'service_vendor', NULL)
    RETURNING id INTO v_sup_null;
    -- ★ 自证非空转:非居民那一家的【国别是 SG】,未申报那一家的国别是 CN。
    --   于是任何"按国别推居民身份"的实现都会把两者判反,而本 fixture 的
    --   A 臂(SG 的非居民要代扣)与 E 臂(CN 的未申报不追问)会同时红。
    --   这一条把「country 不是 tax_residence」从一句注释变成一个可失败的断言。

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    v_rate := wht_rate_for('technical_service_fee', d_doc);
    -- ★ 自证非空转:税率必须【既不是 0 也不是 100】,否则下面"三个数两两不等"
    --   会退化 —— 0 会让净额等于毛额,100 会让净额为零。
    IF v_rate IS NULL OR v_rate <= 0 OR v_rate >= 100 THEN
        RAISE EXCEPTION 'FIXTURE 142 失败(空转):技术服务费税率是 % —— 它撑不起下面任何一条断言', v_rate;
    END IF;
    v_wht := round(v_gross * v_rate / 100.0, 2);
    v_net := v_gross - v_wht;

    -- ══════════════════════════════════════════════════════════════════════
    -- A 臂 · **债全额结清,银行只走净额,差额成为对 IRAS 的负债**
    -- ══════════════════════════════════════════════════════════════════════
    v_res := record_expense(
        p_expense_date := d_doc, p_account_code := '6400', p_amount := v_gross,
        p_currency := v_base, p_payment_status := 'unpaid', p_supplier_id := v_sup,
        p_wht_nature := 'technical_service_fee');
    v_exp := (v_res->>'expense_id')::uuid;

    -- 单上冻下来的预期值
    IF (v_res->>'wht_amount_ccy')::numeric <> v_wht THEN
        RAISE EXCEPTION 'FIXTURE 142A 失败:单上冻的代扣额是 %,应为 %',
            v_res->>'wht_amount_ccy', v_wht;
    END IF;

    -- ★ 自证非空转:三个数【两两不等】。少了这一句,一个"银行也走全额"的实现
    --   与一个"根本没代扣"的实现都可能蒙混过去。
    IF v_gross = v_net OR v_gross = v_wht OR v_net = v_wht THEN
        RAISE EXCEPTION 'FIXTURE 142A 失败(空转):毛额 %、净额 %、代扣 % 中有两个相等 —— 这三条断言分不开任何两种实现',
            v_gross, v_net, v_wht;
    END IF;

    v_pay := record_payment(
        p_direction := 'out', p_counterparty_id := v_sup, p_amount := v_net,
        p_currency := v_base, p_payment_date := d_doc,
        p_allocations := jsonb_build_array(
            jsonb_build_object('expense_id', v_exp, 'amount_doc', v_gross)));

    -- ① 应付【闭合到零】—— 债是按全额解除的
    SELECT COALESCE(SUM(open_base), 0) INTO v_open
    FROM ap_open_items WHERE doc_kind = 'expense' AND doc_id = v_exp;
    IF v_open <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 142A 失败:这张单还欠着 % —— 代扣把债变成了折扣', v_open;
    END IF;

    -- ② 分录三条腿:借 2000 = 毛额;贷 2150 = 代扣;贷银行 = 净额
    SELECT COALESCE(SUM(l.debit), 0) INTO v_dr2000
      FROM journal_activity_lines('1900-01-01'::date, '2999-12-31'::date, true) l
     WHERE l.account_code = '2000' AND l.source_id = (v_pay->>'payment_id')::uuid;
    SELECT COALESCE(SUM(l.credit), 0) INTO v_cr2150
      FROM journal_activity_lines('1900-01-01'::date, '2999-12-31'::date, true) l
     WHERE l.account_code = '2150' AND l.source_id = (v_pay->>'payment_id')::uuid;
    SELECT COALESCE(SUM(l.credit), 0) INTO v_crbank
      FROM journal_activity_lines('1900-01-01'::date, '2999-12-31'::date, true) l
     WHERE l.account_code = v_bank AND l.source_id = (v_pay->>'payment_id')::uuid;

    IF v_dr2000 <> v_gross THEN
        RAISE EXCEPTION 'FIXTURE 142A 失败:应付借方是 %,应为毛额 %', v_dr2000, v_gross;
    END IF;
    IF v_cr2150 <> v_wht THEN
        RAISE EXCEPTION 'FIXTURE 142A 失败:代扣负债是 %,应为 %', v_cr2150, v_wht;
    END IF;
    IF v_crbank <> v_net THEN
        RAISE EXCEPTION 'FIXTURE 142A 失败:银行贷方是 %,应为净额 % —— 钱走多了或走少了', v_crbank, v_net;
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- B 臂 · **税率是带日期的法定事实:窗口外按名拒,不取最近的一条**
    -- ══════════════════════════════════════════════════════════════════════
    -- 管理费的种子从 2010-01-01 起。两个日期【跨过那条边界】,所以一个
    -- "取最近的一条"的实现会对两边都返回 17,而这一臂当场红。
    IF wht_rate_for('management_fee', DATE '2010-01-01') IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 142B 失败(空转):边界当天都取不到税率,这一臂无从对比';
    END IF;
    BEGIN
        PERFORM wht_rate_for('management_fee', DATE '2009-12-31');
        RAISE EXCEPTION 'FIXTURE 142B 失败:窗口【之前】仍然解析出了税率 —— 它回退了';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        IF v_msg NOT LIKE 'WHT_RATE_NOT_FOUND%' THEN RAISE; END IF;
    END;

    -- ══════════════════════════════════════════════════════════════════════
    -- C 臂 · **裁定属于债务:身份冻在单上,不在付款时现查**
    -- ══════════════════════════════════════════════════════════════════════
    -- ★ 这一臂是躲开陷阱①的地方,而躲法就是【把两个值弄成不同的】。
    v_res := record_expense(
        p_expense_date := d_doc, p_account_code := '6400', p_amount := v_gross,
        p_currency := v_base, p_payment_status := 'unpaid', p_supplier_id := v_sup,
        p_wht_nature := 'technical_service_fee');
    v_exp2 := (v_res->>'expense_id')::uuid;

    -- 记单【之后】把这家改成居民 —— 现实里就是管理与控制迁走了。
    UPDATE suppliers SET tax_residence = 'resident' WHERE id = v_sup;
    SELECT wht_payee_residence INTO v_frozen FROM expenses WHERE id = v_exp2;
    SELECT tax_residence INTO v_live FROM suppliers WHERE id = v_sup;
    -- ★ 自证非空转:两个值必须【真的不同】,否则这一臂分不开两种实现。
    IF v_frozen IS NOT DISTINCT FROM v_live THEN
        RAISE EXCEPTION 'FIXTURE 142C 失败(空转):冻下来的身份(%)与现在的身份(%)相同 —— 一个"付款时现查"的实现与一个"读冻下来那份"的实现在这里会给出同样的答案',
            v_frozen, v_live;
    END IF;

    v_pay := record_payment(
        p_direction := 'out', p_counterparty_id := v_sup, p_amount := v_net,
        p_currency := v_base, p_payment_date := d_doc,
        p_allocations := jsonb_build_array(
            jsonb_build_object('expense_id', v_exp2, 'amount_doc', v_gross)));

    SELECT COALESCE(SUM(l.credit), 0) INTO v_cr2150
      FROM journal_activity_lines('1900-01-01'::date, '2999-12-31'::date, true) l
     WHERE l.account_code = '2150' AND l.source_id = (v_pay->>'payment_id')::uuid;
    IF v_cr2150 <> v_wht THEN
        RAISE EXCEPTION 'FIXTURE 142C 失败:供应商改成居民之后这笔代扣变成了 %(应为 %)—— 付款读的是【现在的】身份,而不是债务冻下来的裁定',
            v_cr2150, v_wht;
    END IF;
    -- 收场:把它改回去,后面几臂还要用这家。
    UPDATE suppliers SET tax_residence = 'non_resident' WHERE id = v_sup;

    -- ══════════════════════════════════════════════════════════════════════
    -- D 臂 · **部分付款按实付部分代扣;付清时 Σ 等于单上冻的预期值**
    -- ══════════════════════════════════════════════════════════════════════
    v_res := record_expense(
        p_expense_date := d_doc, p_account_code := '6400', p_amount := v_gross,
        p_currency := v_base, p_payment_status := 'unpaid', p_supplier_id := v_sup,
        p_wht_nature := 'technical_service_fee');
    v_exp2 := (v_res->>'expense_id')::uuid;

    -- 两次各结一半。一个"第一次就把整张单的税全扣掉"的实现会在第一次
    -- 就得到 v_wht,当场红。
    FOR v_n IN 1..2 LOOP
        PERFORM record_payment(
            p_direction := 'out', p_counterparty_id := v_sup,
            p_amount := round(v_net / 2, 2), p_currency := v_base, p_payment_date := d_doc,
            p_allocations := jsonb_build_array(
                jsonb_build_object('expense_id', v_exp2, 'amount_doc', round(v_gross / 2, 2))));
        IF v_n = 1 THEN
            SELECT COALESCE(SUM(pa.withheld_base), 0) INTO v_view
              FROM payment_allocations pa WHERE pa.expense_id = v_exp2;
            IF v_view >= v_wht THEN
                RAISE EXCEPTION 'FIXTURE 142D 失败:只付了一半,却已经扣了 %(整张单才 %)—— 代扣没有按【实付部分】算',
                    v_view, v_wht;
            END IF;
        END IF;
    END LOOP;
    SELECT COALESCE(SUM(pa.withheld_base), 0) INTO v_view
      FROM payment_allocations pa WHERE pa.expense_id = v_exp2;
    IF v_view <> v_wht THEN
        RAISE EXCEPTION 'FIXTURE 142D 失败:两次付清之后 Σ 代扣是 %,而单上冻的是 %', v_view, v_wht;
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- E 臂 · **每一条拒绝都真的拒**(逐条从函数体数出来,不是从撞到过的数)
    -- ══════════════════════════════════════════════════════════════════════
    -- ① 非居民 + 没回答性质 → WHT_NATURE_REQUIRED
    BEGIN
        PERFORM record_expense(p_expense_date := d_doc, p_account_code := '6400',
            p_amount := 100, p_currency := v_base, p_payment_status := 'unpaid',
            p_supplier_id := v_sup);
        RAISE EXCEPTION 'FIXTURE 142E1 失败:非居民收款人的费用单没有回答代扣就过去了';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        IF v_msg NOT LIKE 'WHT_NATURE_REQUIRED%' THEN RAISE; END IF;
    END;
    -- ② 居民 + 给了性质 → WHT_PAYEE_IS_RESIDENT
    BEGIN
        PERFORM record_expense(p_expense_date := d_doc, p_account_code := '6400',
            p_amount := 100, p_currency := v_base, p_payment_status := 'unpaid',
            p_supplier_id := v_sup_res, p_wht_nature := 'royalty');
        RAISE EXCEPTION 'FIXTURE 142E2 失败:给居民收款人做了代扣裁定';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        IF v_msg NOT LIKE 'WHT_PAYEE_IS_RESIDENT%' THEN RAISE; END IF;
    END;
    -- ③ ★【A2 那个洞】★ 已付 + 要代扣 → WHT_ON_PAID_EXPENSE_UNSUPPORTED。
    --    record_expense 的 p_payment_status 【默认就是 'paid'】,所以这条路
    --    是【不填任何东西】就会走上的那一条 —— 最该被钉死的一条。
    BEGIN
        PERFORM record_expense(p_expense_date := d_doc, p_account_code := '6400',
            p_amount := 100, p_currency := v_base, p_payment_status := 'paid',
            p_bank_account := v_bank, p_supplier_id := v_sup,
            p_wht_nature := 'royalty');
        RAISE EXCEPTION 'FIXTURE 142E3 失败:一笔【当场付清】的费用做了代扣裁定却没有拒 —— 那条路不经过 record_payment,于是一分钱都不会被扣';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        IF v_msg NOT LIKE 'WHT_ON_PAID_EXPENSE_UNSUPPORTED%' THEN RAISE; END IF;
    END;
    -- ④ 协定税率高于法定 → WHT_TREATY_RATE_ABOVE_STATUTORY
    BEGIN
        PERFORM record_expense(p_expense_date := d_doc, p_account_code := '6400',
            p_amount := 100, p_currency := v_base, p_payment_status := 'unpaid',
            p_supplier_id := v_sup, p_wht_nature := 'royalty',
            p_wht_rate_pct := 99, p_wht_treaty_ref := 'COR-X');
        RAISE EXCEPTION 'FIXTURE 142E4 失败:协定税率高于法定却通过了';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        IF v_msg NOT LIKE 'WHT_TREATY_RATE_ABOVE_STATUTORY%' THEN RAISE; END IF;
    END;
    -- ⑤ 低于法定但没有居民证明书 → WHT_TREATY_REF_REQUIRED
    BEGIN
        PERFORM record_expense(p_expense_date := d_doc, p_account_code := '6400',
            p_amount := 100, p_currency := v_base, p_payment_status := 'unpaid',
            p_supplier_id := v_sup, p_wht_nature := 'royalty', p_wht_rate_pct := 5);
        RAISE EXCEPTION 'FIXTURE 142E5 失败:主张了协定减免却不用出示凭据';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        IF v_msg NOT LIKE 'WHT_TREATY_REF_REQUIRED%' THEN RAISE; END IF;
    END;
    -- ⑥ 身份未申报 + 断言要代扣 → WHT_RESIDENCE_NOT_STATED
    BEGIN
        PERFORM record_expense(p_expense_date := d_doc, p_account_code := '6400',
            p_amount := 100, p_currency := v_base, p_payment_status := 'unpaid',
            p_supplier_id := v_sup_null, p_wht_nature := 'royalty');
        RAISE EXCEPTION 'FIXTURE 142E6 失败:对一个没有分类过的收款人做了代扣裁定';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        IF v_msg NOT LIKE 'WHT_RESIDENCE_NOT_STATED%' THEN RAISE; END IF;
    END;
    -- ⑦ ★【那个量过的取舍,正着证一遍】★ 身份【未申报】且【不做裁定】时,
    --    费用单照记 —— 这不是漏网,是一个写在 suppliers.tax_residence 列注释里
    --    的、量过成本的决定(16 份 fixture)。**把它断言出来,是为了让它成为
    --    一个决定而不是一个缺口**:哪天有人把它改成"一律拒",这一臂会红,
    --    而红的时候他会读到这段话。
    PERFORM record_expense(p_expense_date := d_doc, p_account_code := '6400',
        p_amount := 100, p_currency := v_base, p_payment_status := 'unpaid',
        p_supplier_id := v_sup_null);

    -- ⑧ ★【fu2 抓到的那堵墙:非居民 + 【不适用代扣】+ 当场付清,必须【放行】】★
    --    原实现把 paid 那道拒绝放在解析税率【之前】,谓词只看"有没有给性质"。
    --    于是对一个非居民收款人当场付清一笔不适用代扣的款,【两条路都被堵死】:
    --    不回答 → WHT_NATURE_REQUIRED;回答"不适用" → WHT_ON_PAID_EXPENSE_UNSUPPORTED。
    --    **一个两边都堵死的问题不是一道闸,是一堵墙**,而它会让人去改数据绕开。
    --    这一臂是【正着断言】的:它要求这条路【通】。任何把谓词退回
    --    "给了性质就拒"的实现,在这里当场红。
    PERFORM record_expense(p_expense_date := d_doc, p_account_code := '6400',
        p_amount := 100, p_currency := v_base, p_payment_status := 'paid',
        p_bank_account := v_bank, p_supplier_id := v_sup,
        p_wht_nature := 'none');
    -- ★ 自证非空转:同一条路上,把性质换成一个【真的要扣钱】的,必须【拒】——
    --   否则上面那次放行只说明这道闸根本不存在。
    BEGIN
        PERFORM record_expense(p_expense_date := d_doc, p_account_code := '6400',
            p_amount := 100, p_currency := v_base, p_payment_status := 'paid',
            p_bank_account := v_bank, p_supplier_id := v_sup,
            p_wht_nature := 'royalty');
        RAISE EXCEPTION 'FIXTURE 142E8 失败(空转):要代扣的 paid 费用单也放行了 —— 上面那次放行证明不了谓词在起作用';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        IF v_msg NOT LIKE 'WHT_ON_PAID_EXPENSE_UNSUPPORTED%' THEN RAISE; END IF;
    END;

    -- ══════════════════════════════════════════════════════════════════════
    -- F 臂 · **欠 IRAS 的合计 ≡ 2150 的科目余额**(两条不同的推导路径)
    -- ══════════════════════════════════════════════════════════════════════
    -- ★ 手工分录那一笔是【故障注入的方向】:一个把代扣侧写成
    --   `source_type = 'payment'` 的实现会漏掉它,于是视图与科目余额分家。
    v_manual := post_journal_entry(d_doc, 'fixture 142 manual adjustment to 2150',
        'manual', NULL,
        jsonb_build_array(
            jsonb_build_object('account_code', '6900', 'side', 'debit',
                'currency', v_base, 'amount_ccy', 100),
            jsonb_build_object('account_code', '2150', 'side', 'credit',
                'currency', v_base, 'amount_ccy', 100)));

    SELECT COALESCE(SUM(unremitted_base), 0) INTO v_view FROM wht_liability_by_month;
    SELECT COALESCE(SUM(l.credit - l.debit), 0) INTO v_ledger
      FROM journal_activity_lines('1900-01-01'::date, '2999-12-31'::date, true) l
     WHERE l.account_code = '2150';
    -- ★ 自证非空转:两边都必须【非零】,否则 0 = 0 什么都没证明。
    IF v_view = 0 OR v_ledger = 0 THEN
        RAISE EXCEPTION 'FIXTURE 142F 失败(空转):视图合计 %、科目余额 % —— 有一边是零,这条勾稽证明不了任何事',
            v_view, v_ledger;
    END IF;
    IF v_view <> v_ledger THEN
        RAISE EXCEPTION 'FIXTURE 142F 失败:视图说欠 %,而 2150 的科目余额是 % —— 两者应当恒等',
            v_view, v_ledger;
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- G 臂 · **告警清得掉,而清除只能由钱完成**
    -- ══════════════════════════════════════════════════════════════════════
    SELECT unremitted_base INTO v_unrem FROM wht_liability_by_month WHERE period_month = v_month;
    IF COALESCE(v_unrem, 0) <= 0 THEN
        RAISE EXCEPTION 'FIXTURE 142G 失败(空转):本月未汇缴额是 % —— 没有欠款就测不出"汇缴清得掉"', v_unrem;
    END IF;

    v_remit := remit_wht(p_period_month := v_month, p_remitted_on := d_doc,
                         p_filed_reference := 'ZZ-F142-IRAS', p_bank_account := v_bank);
    SELECT unremitted_base INTO v_unrem FROM wht_liability_by_month WHERE period_month = v_month;
    IF v_unrem <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 142G 失败:汇缴之后仍然欠 %', v_unrem;
    END IF;

    -- ★ 反向:冲销那张汇款分录,欠款【回来】。这一句证的是"清除挂在钱上,
    --   不挂在一个标志上" —— 一个把 remitted 记成 wht_remittances 行数、
    --   或记成一个 boolean 的实现,在这里不会回涨。
    SELECT (v_remit->>'journal_code') INTO v_msg;
    SELECT id INTO v_je FROM journal_entries WHERE code = v_msg;
    PERFORM reverse_journal_entry(v_je, d_doc, 'fixture 142 reversal');
    SELECT unremitted_base INTO v_unrem FROM wht_liability_by_month WHERE period_month = v_month;
    IF v_unrem <> v_ledger THEN
        RAISE EXCEPTION 'FIXTURE 142G 失败:冲销汇款之后欠款是 %,应回到 % —— 清除没有挂在钱上',
            v_unrem, v_ledger;
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- H 臂 · **付款读的是债务冻下来的税率**(目录断言,钉在那【一次赋值】上)
    -- ══════════════════════════════════════════════════════════════════════
    -- ★ 躲开陷阱②:先【剥掉注释行】再匹配。'wht_rate_pct' 这个子串在
    --   record_payment 的注释里出现好几次,匹配子串会守住措辞而不是行为。
    SELECT pg_get_functiondef(p.oid) INTO v_def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = 'record_payment';
    SELECT string_agg(ln, E'\n') INTO v_body
      FROM (SELECT ln FROM regexp_split_to_table(v_def, E'\n') AS ln
             WHERE btrim(ln) NOT LIKE '--%') s;
    IF v_body NOT LIKE '%v_wht_rate := v_doc.wht_rate_pct%' THEN
        RAISE EXCEPTION 'FIXTURE 142H 失败:record_payment 里找不到【那一次赋值】(v_wht_rate := v_doc.wht_rate_pct)—— 代扣率没有从债务上读';
    END IF;
    -- ★ 自证非空转:证明剥注释这一步真的做了事 —— 原文里必须【有】注释行,
    --   否则这条"剥了再匹配"的讲究是一句空话。
    IF v_def = v_body THEN
        RAISE EXCEPTION 'FIXTURE 142H 失败(空转):剥注释前后一模一样 —— 这条断言的防线没有生效';
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- I 臂 · **两支 SECURITY DEFINER 函数各自问过调用者是谁**(行为性)
    -- ══════════════════════════════════════════════════════════════════════
    -- ★ 躲开陷阱③。这个形状在本仓库【上线过两次、两次都由闸抓住】,所以
    --   这里不写"函数体里有 require_permission"那种目录断言 —— 那只守措辞。
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_nobody), true);
    BEGIN
        PERFORM wht_rate_for('royalty', d_doc);
        RAISE EXCEPTION 'FIXTURE 142I 失败:wht_rate_for 对一个没有任何权限的调用者放行了';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        IF v_msg NOT LIKE 'PERMISSION_DENIED%' THEN RAISE; END IF;
    END;
    BEGIN
        PERFORM remit_wht(p_period_month := v_month, p_remitted_on := d_doc,
                          p_filed_reference := 'X');
        RAISE EXCEPTION 'FIXTURE 142I 失败:remit_wht 对一个没有任何权限的调用者放行了';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        IF v_msg NOT LIKE 'PERMISSION_DENIED%' THEN RAISE; END IF;
    END;
    -- ★ 自证非空转:同一支函数,换回有权限的人必须【成功】—— 否则上面两条
    --   拒绝可能只是因为参数错了,而不是因为权限。
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);
    IF wht_rate_for('royalty', d_doc) IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 142I 失败(空转):有权限的调用者也拿不到税率 —— 上面那两条拒绝证明不了是权限在起作用';
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- J 臂 · **欠 IRAS 多少这件事,本身也要问读者是谁**(WHT-1 fu1)
    -- ══════════════════════════════════════════════════════════════════════
    -- ★ 属主权限视图解决的是"读得到吗",它【不】回答"谁可以读" —— 而这张视图
    --   带着 GRANT SELECT TO authenticated,于是没有谓词时,任何登录用户都能
    --   经 PostgREST 读到公司欠 IRAS 多少。
    -- ★【为什么必须是行为断言,而不是"视图体里有 has_permission"】★
    --   闸对这一类是【结构性失明】的:colreader 与 xmodule 只看 invoker 视图,
    --   colgrant 只看列有没有被授权。也就是说没有任何一条自动检查会问它。
    --   一条目录断言守的是措辞;这一臂守的是行为。
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_nobody), true);
    SELECT COUNT(*) INTO v_n FROM wht_liability_by_month;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 142J 失败:一个没有任何权限的读者看到了 % 行欠税记录 —— 属主权限视图必须自己问读者是谁', v_n;
    END IF;
    -- ★ 自证非空转:换回有权限的人必须【看得见】,否则上面那个 0 只是因为
    --   表里本来就没有数据,而不是因为谓词在起作用。
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);
    SELECT COUNT(*) INTO v_n FROM wht_liability_by_month;
    IF v_n = 0 THEN
        RAISE EXCEPTION 'FIXTURE 142J 失败(空转):有权限的读者也看到 0 行 —— 上面那条断言证明不了谓词在起作用';
    END IF;

    RAISE NOTICE 'fixture 142 OK — 十臂全过';
END $$;
ROLLBACK;
