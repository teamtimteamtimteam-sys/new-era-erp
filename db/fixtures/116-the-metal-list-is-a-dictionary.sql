-- 116 那份金属清单是一张【字典】—— 加一种物质是加一行,不是一支迁移
--
-- 【这份 fixture 自带全部数据】重建库里没有业务数据(README 第 2 条)。
--
-- 【每一臂钉什么】
-- F1 前提,先于一切:**既有的化验值、含量值、报价一个数都没变**。
--    断言【数字本身】,不是"查询跑通了" —— 一个把行删光的实现也能让查询跑通。
-- F2 八张表【逐张】按外键拒掉一个不认识的码,**按约束名断言**。
--    八张,不是四张:切次简报说四张,线上目录里数出来是八(见迁移抬头)。
--    少数出来的那几张会安静地留着 CHECK,于是"加一行字典"之后一半的表认新值、
--    另一半照旧拒 —— 而没有任何东西会说这件事。
-- F3 **本刀的全部意义**:在事务里加一行字典,立刻就能对它记一个数,
--    【不动任何 schema】。这一臂就是"它是不是一张字典"的定义。
-- F4 D5 两个动词:停用一行【不让已经记下的数失效】,而它【从可选集合里消失】。
--    两个方向都测,并把"外键为什么【不】读 is_active"钉在断言里。
-- F5 D4 顺序是数据:显示顺序照 sort_order,而它【与字母序不同】——
--    两者若恰好一样,这一臂就证明不了任何事,所以先断言它们不同。
--
-- 日期无关。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid; v_ccy text;
    v_sup uuid; v_mat uuid; v_ib uuid; v_assay uuid;
    v_ob uuid; v_formula uuid; v_commit uuid; v_sqlfrag text;
    v_pct numeric; v_price numeric; v_n int;
    v_denied boolean; v_msg text; v_con text;
    v_by_sort text; v_by_alpha text;
    t text;
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-116', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ116-S', 'fixture 116 supplier', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZ116-M', 'f116 feed', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO v_mat;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note)
    VALUES ('ZZ116-IB', v_mat, v_sup, 1000, 1000, 'kg', DATE '2027-03-01', 'other', 'fixture 116 自带数据') RETURNING id INTO v_ib;

    -- ══════════ F1 · 前提:既有的数一个都没变 ═══════════════════════════════
    RAISE NOTICE 'fixture 116 · 进入 F1';
    -- 【断言数字本身】把七个金属各记一个【互不相同】的含量,再逐个读回来比对。
    -- 互不相同是刻意的:全填同一个数的话,一个"把所有行都读成第一行"的实现也能过。
    -- 【包起来,让这一臂【自己】说出它抓到了什么】
    -- 不包的话,字典少发一个金属时整块 DO 会带着一句原始外键错中止 ——
    -- 而"该红的臂什么都没说"与"这一臂根本没跑"在屏幕上长得一模一样。
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO inbound_batch_metals (inbound_batch_id, metal, content_pct, content_source) VALUES
            (v_ib, 'ni', 11.1, 'manual'), (v_ib, 'co', 22.2, 'manual'), (v_ib, 'li', 33.3, 'manual'),
            (v_ib, 'mn', 44.4, 'manual'), (v_ib, 'cu', 55.5, 'manual'), (v_ib, 'al', 66.6, 'manual'),
            (v_ib, 'fe', 77.7, 'manual');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 116F1 失败:进入 F1 —— 七个金属【原样都要记得下】。外键换掉 CHECK 之后,字典少发一行就会让既有的数记不进来,而那是这一刀最直接的伤害。实得「%」', v_msg;
    END IF;
    SELECT count(*) INTO v_n FROM inbound_batch_metals WHERE inbound_batch_id = v_ib;
    IF v_n <> 7 THEN
        RAISE EXCEPTION 'FIXTURE 116F1 失败:进入 F1 —— 七个金属都应当记得下(外键换掉 CHECK 之后【一个都不能少】),实得 % 行', v_n;
    END IF;
    FOR t, v_pct IN SELECT * FROM (VALUES ('ni',11.1),('co',22.2),('li',33.3),('mn',44.4),
                                          ('cu',55.5),('al',66.6),('fe',77.7)) AS x(a,b)
    LOOP
        IF (SELECT content_pct FROM inbound_batch_metals
             WHERE inbound_batch_id = v_ib AND metal = t) IS DISTINCT FROM v_pct THEN
            RAISE EXCEPTION 'FIXTURE 116F1 失败:进入 F1 —— % 的含量应当原样读得回来(%),实得 %。**断言的是数字,不是"查询跑通了"** —— 一个把行删光的实现也能让查询跑通',
                t, v_pct, (SELECT content_pct FROM inbound_batch_metals WHERE inbound_batch_id = v_ib AND metal = t);
        END IF;
    END LOOP;

    -- 报价那一侧同样钉一个数(它是另一张表,另一条外键)
    INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date, source)
    VALUES ('ni', 16500, DATE '2027-03-01', 'broker_quote');
    SELECT price_usd_per_tonne INTO v_price FROM metal_prices
     WHERE metal = 'ni' AND price_date = DATE '2027-03-01';
    IF v_price <> 16500 THEN
        RAISE EXCEPTION 'FIXTURE 116F1 失败:进入 F1 —— 报价应当原样读得回来(16500),实得 %', v_price;
    END IF;

    -- ══════════ F2 · 八张表逐张按【外键】拒一个不认识的码 ══════════════════
    RAISE NOTICE 'fixture 116 · 进入 F2';
    -- 【为什么逐张而不是抽一张】这份清单曾经在八张表上各写一遍,
    -- 而"漏掉一张"正是它当初能长出八份副本的原因 —— 抽查一张证明不了其余七张。
    --
    -- 【为什么要先把父单据都造出来】这些表上还有【别的】非空列与外键,
    -- 而它们会【先于】metal 那条外键炸掉。第一版只塞 metal 一列,结果撞上
    -- assay_result_id 的 not-null,断言当场红了 —— **红的是断言,不是系统**。
    -- 要证明"是 metal 那条外键拒的",这一行除了 metal 之外必须【处处合法】。
    -- assay_results 有一条 one_parent:进料批与产出批【恰一非空】。
    INSERT INTO assay_results (code, assay_date, inbound_batch_id, weight_basis, result_party)
    VALUES ('ZZ116-AR', DATE '2027-03-01', v_ib, 'as_received', 'ours') RETURNING id INTO v_assay;
    -- output_batches 上的触发器会写一条 receipt 流水,而 FIN-32 要求它带业务日期
    -- —— 那个日期取自 output_date,所以这里必须给。
    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, output_date)
    VALUES ('ZZ116-OB', v_mat, 10, 10, DATE '2027-03-01') RETURNING id INTO v_ob;
    INSERT INTO pricing_formulas (code, name) VALUES ('ZZ116-PF', 'f116 formula')
    RETURNING id INTO v_formula;
    -- 承诺也有一条 one_target:采购单行与进料批【恰一非空】。
    INSERT INTO pricing_term_commitments
        (source_formula_code, price_basis, treatment_charge_usd_per_tonne, flat_discount_pct, inbound_batch_id)
    VALUES ('ZZ116-PF', 'spot', 0, 0, v_ib) RETURNING id INTO v_commit;

    FOR t, v_sqlfrag IN SELECT * FROM (VALUES
        ('assay_result_metals',            format('(assay_result_id, metal, content_pct) VALUES (%L, %%L, 1)', v_assay)),
        ('inbound_batch_metals',           format('(inbound_batch_id, metal, content_pct, content_source) VALUES (%L, %%L, 1, ''manual'')', v_ib)),
        ('output_batch_metals',            format('(output_batch_id, metal, content_pct, content_source) VALUES (%L, %%L, 1, ''manual'')', v_ob)),
        ('metal_prices',                   '(metal, price_usd_per_tonne, price_date, source) VALUES (%L, 1, DATE ''2027-03-03'', ''broker_quote'')'),
        ('pricing_formula_metals',         format('(formula_id, metal, payable_pct) VALUES (%L, %%L, 1)', v_formula)),
        ('pricing_term_commitment_metals', format('(commitment_id, metal, payable_pct) VALUES (%L, %%L, 1)', v_commit)),
        ('material_required_metals',       format('(material_id, metal) VALUES (%L, %%L)', v_mat)),
        ('pricing_formula_history',        format('(formula_id, change_type, metal) VALUES (%L, ''metal_set'', %%L)', v_formula))
    ) AS x(a,b)
    LOOP
        v_denied := false; v_msg := NULL; v_con := NULL;
        BEGIN
            EXECUTE format('INSERT INTO %I ' || v_sqlfrag, t, 'ZZ116-NOSUCH');
        EXCEPTION
            WHEN foreign_key_violation THEN
                v_denied := true;
                GET STACKED DIAGNOSTICS v_con = CONSTRAINT_NAME;
            WHEN OTHERS THEN
                v_msg := SQLERRM;
        END;
        IF NOT v_denied THEN
            RAISE EXCEPTION 'FIXTURE 116F2 失败:进入 F2 —— % 上一个不认识的物质码必须被【外键】拒。实得 msg=「%」。**若它压根没报错,说明那一张表的 metal 列没挂上外键** —— 而"漏掉一张"正是这份清单当初长出八份副本的方式',
                t, COALESCE(v_msg, '(插进去了)');
        END IF;
        IF v_con <> t || '_metal_fkey' THEN
            RAISE EXCEPTION 'FIXTURE 116F2 失败:进入 F2 —— % 拒的应当是它【自己那条】外键(%_metal_fkey),实得约束名「%」 —— 换句话说,炸的是别的约束,这一臂并没有测到 metal 那条', t, t, COALESCE(v_con,'(空)');
        END IF;
    END LOOP;

    -- ══════════ F3 · 【本刀的意义】加一行,新物质当场就记得下 ══════════════
    RAISE NOTICE 'fixture 116 · 进入 F3';
    -- 【这一臂就是"它是不是一张字典"的定义】
    -- 事务里加一行 —— **不建表、不改约束、不跑迁移** —— 然后对它记一个数。
    -- 氟是排在第一位的那个真实需求:今天它【连记都记不下来】,而这一臂证明
    -- PROC-4 之后它只差一行数据。(本刀不发它,理由与返回条件写在表注上。)
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO public.substances (code, name_en, name_zh, symbol, sort_order, notes)
        VALUES ('ZZ116_F', 'Fluorine (fixture)', '氟(fixture)', 'F', 99,
                'fixture 116:证明加一种物质是加一行');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 116F3 失败:进入 F3 —— 【加一行】这件事本身必须做得成。做不成,这就不是一张字典,只是一条换了写法的 CHECK。实得「%」', v_msg;
    END IF;
    INSERT INTO inbound_batch_metals (inbound_batch_id, metal, content_pct, content_source)
    VALUES (v_ib, 'ZZ116_F', 0.35, 'manual');
    SELECT content_pct INTO v_pct FROM inbound_batch_metals
     WHERE inbound_batch_id = v_ib AND metal = 'ZZ116_F';
    IF v_pct IS DISTINCT FROM 0.35 THEN
        RAISE EXCEPTION 'FIXTURE 116F3 失败:进入 F3 —— 【加一行字典就该能记一个数】。这一臂是本刀的全部意义:PROC-4 之前,记一种新物质要改八张表的 CHECK(一支迁移);之后它只差一行数据。实得 %', COALESCE(v_pct::text,'(没记下)');
    END IF;
    -- 另一张表也认它 —— 证明认它的是【字典】,不是某一张表自己的运气。
    INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date, source)
    VALUES ('ZZ116_F', 1, DATE '2027-03-02', 'broker_quote');
    IF NOT EXISTS (SELECT 1 FROM metal_prices WHERE metal = 'ZZ116_F') THEN
        RAISE EXCEPTION 'FIXTURE 116F3 失败:进入 F3 —— 新物质在【另一张】表上也必须立刻可用:八条外键指的是同一张字典';
    END IF;

    -- ══════════ F4 · D5 两个动词:停用 ≠ 让既有的数失效 ═════════════════════
    RAISE NOTICE 'fixture 116 · 进入 F4';
    UPDATE public.substances SET is_active = false WHERE code = 'ZZ116_F';
    -- 【方向一:已经记下的数【一个字都不变】,而且照样读得出来】
    SELECT content_pct INTO v_pct FROM inbound_batch_metals
     WHERE inbound_batch_id = v_ib AND metal = 'ZZ116_F';
    IF v_pct IS DISTINCT FROM 0.35 THEN
        RAISE EXCEPTION 'FIXTURE 116F4 失败:进入 F4 —— 停用一种物质【绝不能】让已经记下来的数失效或读不出来。那个 0.35 是当时测出来的事实,不因为今天不再选它而变成假的。实得 %', COALESCE(v_pct::text,'(读不出来)');
    END IF;
    -- 【外键【不】读 is_active —— 而这是刻意的,不是漏了】
    -- 若外键连 is_active 一起看,停用一行字典就会让所有引用它的历史行变成非法,
    -- 那是一条【无痕迹、且一次性对所有单据生效】的破坏路径(PROC-3 在
    -- inbound_safety_states 上立的是同一条)。
    -- 【包起来:这一臂要自己说出它抓到了什么】
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO inbound_batch_metals (inbound_batch_id, metal, content_pct, content_source)
        VALUES (v_ib, 'ZZ116_F', 0.36, 'manual')
        ON CONFLICT (inbound_batch_id, metal) DO UPDATE SET content_pct = 0.36;
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF v_denied OR (SELECT content_pct FROM inbound_batch_metals
                     WHERE inbound_batch_id = v_ib AND metal = 'ZZ116_F') IS DISTINCT FROM 0.36 THEN
        RAISE EXCEPTION 'FIXTURE 116F4 失败:进入 F4 —— 已停用物质的历史行必须【改得动】(录错了要能更正)。一个"连 is_active 一起看"的实现在这里会拒 —— 而它同时会让每一条历史行变成非法,那是一条无痕迹、且一次性对所有单据生效的破坏路径。实得「%」', COALESCE(v_msg,'(没报错,但值不对)');
    END IF;
    -- 【方向二:它从【可选集合】里消失】—— 那正是 app 的 loadSubstances 跑的那条查询。
    IF EXISTS (SELECT 1 FROM public.substances WHERE is_active AND code = 'ZZ116_F') THEN
        RAISE EXCEPTION 'FIXTURE 116F4 失败:进入 F4 —— 停用之后它必须从【可选集合】里消失(is_active = true 那一组)。两个动词:is_active 管"还能不能【新选】",may_be_fed 那类规则列管"还算不算数"';
    END IF;
    -- 【把这条边界写进断言里,而不是留给下一个人猜】
    -- 拦住"新选"的是【读 is_active 的那些界面与校验】,不是外键。
    -- 也就是说:直连 psql 仍然可以对一个已停用的物质记一个【新】数字。
    -- 这是刻意的取舍(否则改不动历史行,见上一条),而它的代价写在
    -- docs/known-issues.md 里,不藏着。
    UPDATE public.substances SET is_active = true WHERE code = 'ZZ116_F';

    -- ══════════ F5 · D4 顺序是数据,而且它【不是】字母序 ═══════════════════
    RAISE NOTICE 'fixture 116 · 进入 F5';
    -- 【先证明两者不同,否则这一臂什么都证明不了】
    -- 本刀之前,顺序有两个互相矛盾的出处:app 侧数组序(重要的排前面)与
    -- 库侧 `ORDER BY metal`(字母序)。若字典序恰好等于字母序,
    -- 一个"照旧按字母排"的实现也能让下面那条断言通过。
    SELECT string_agg(code, ',' ORDER BY sort_order) INTO v_by_sort
      FROM public.substances WHERE code IN ('ni','co','li','mn','cu','al','fe');
    SELECT string_agg(code, ',' ORDER BY code) INTO v_by_alpha
      FROM public.substances WHERE code IN ('ni','co','li','mn','cu','al','fe');
    -- 【先钉住七个 sort_order 彼此不同】并列的时候 `ORDER BY sort_order` 的结果
    -- 是【未定义的】,而它可能恰好排成期望的样子 —— 那样这一臂就是靠运气绿的。
    -- (实测:把七个 sort_order 全设成 0,下面那条断言照样通过。)
    SELECT count(DISTINCT sort_order) INTO v_n
      FROM public.substances WHERE code IN ('ni','co','li','mn','cu','al','fe');
    IF v_n <> 7 THEN
        RAISE EXCEPTION 'FIXTURE 116F5 失败:进入 F5 —— 七个物质的 sort_order 必须【两两不同】,实得 % 个不同值。并列时排序结果未定义,而一个"恰好排对了"的结果证明不了顺序来自字典', v_n;
    END IF;
    IF v_by_sort = v_by_alpha THEN
        RAISE EXCEPTION 'FIXTURE 116F5 前置失败:进入 F5 —— 字典序与字母序【必须不同】,否则这一臂证明不了顺序来自字典。实得两者都是「%」', v_by_sort;
    END IF;
    IF v_by_sort <> 'ni,co,li,mn,cu,al,fe' THEN
        RAISE EXCEPTION 'FIXTURE 116F5 失败:进入 F5 —— 显示顺序应当由 sort_order 决定(ni,co,li,mn,cu,al,fe:重要的排前面),实得「%」。**新加一行出现在哪儿,是一个被选择的事实**,不该由字母、也不该由插入次序决定', v_by_sort;
    END IF;
    -- 【新加的那一行落在它被指定的位置上】sort_order 99 → 排在最后。
    SELECT string_agg(code, ',' ORDER BY sort_order) INTO v_by_sort FROM public.substances;
    IF v_by_sort NOT LIKE '%,ZZ116_F' THEN
        RAISE EXCEPTION 'FIXTURE 116F5 失败:进入 F5 —— 新加的那一行应当落在 sort_order 指定的位置(99 → 最后),实得「%」', v_by_sort;
    END IF;
END $$;
ROLLBACK;
