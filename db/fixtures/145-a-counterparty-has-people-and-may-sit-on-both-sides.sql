-- 145 PARTY-1:一个对手方有【好几个人】,而它可能【同时坐在两边】
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【五个点名要躲开的陷阱,逐条写出来它是怎么躲的】
--
--  (a) **一条断言之所以过,是因为两份实现碰巧一致。**
--      躲法:开票快照那一臂【不比两个实现】,它比的是
--      「快照里那三个键」与「本表里主联系人那一行」——
--      而后者是**被这一臂自己改过的**(换了主联系人再开一张票),
--      所以"两边一直一致"的实现过不去:第二张票必须写着【另一个人】。
--
--  (b) **一条目录断言命中的是注释里的一次提及。**
--      躲法:catalog 那一臂查的是 `pg_policy` / `pg_constraint` / `pg_proc.prosecdef`
--      这些**目录事实**,不是 grep 源码文本。注释里写一万遍 "is_primary"
--      也不会让 `counterparty_contacts_one_primary_customer` 那个索引存在。
--
--  (c) **一支 SECURITY DEFINER 函数没有权限检查。**
--      躲法:F 臂**在没有权限的角色下真的调它**,断言按名拒 ——
--      而不是去源码里找 `require_permission` 那几个字(那属于陷阱 b)。
--      三支新函数【每一支都被这样调过】。
--
--  (d) **断言过了,是因为那个集合是空的。**
--      躲法:**每一处比对之前先断言集合非空、而且正好是预期的行数**。
--      重叠那一臂尤其要紧:实测线上 customers 的 tax_id 是 **0 个**,
--      所以一份"没有重叠"的报告在今天【必然】为真而毫无信息 ——
--      本 fixture 因此**自己造出一个真的重叠**,并且先断言分母不是 0。
--
--  (e) **一个什么都没注入的注入,长得和一个通过了的注入一模一样。**
--      躲法:每一处 replace 之后都断言**定义真的变了**(v_inj <> def_xxx),
--      变不了就当场报"这个注入什么也没删"。fixture 77 昨天正是这样红的。
--
-- 【本 fixture 钉住的东西】
--   A 联系人的归属恰好一边;够不着的人写不进去;没名字的写不进去。
--   B 主联系人【每边最多一个】,而且换主是【一笔事务】里的事。
--   C ★ 开票快照取的是主联系人 —— 换了主,下一张票就换人,而【上一张不动】。
--   D ★ 账期不再编 30 天:客户没设、调用没给 → 按名拒(两扇门都拒)。
--   E ★ 重叠报告:造一个真重叠,断言 tax_id 那组抓得到、名字那组不重复计,
--       且**两个敞口是分开的两个数、不是一个和**。
--   F 三支新函数的权限;软删不自动挑新主。
--   G 目录事实(约束、索引、策略、definer)。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '180s';
DO $$
DECLARE
    v_user   uuid := gen_random_uuid();
    r_all    uuid;
    v_cust   uuid; v_cust2 uuid;
    v_sup    uuid;
    v_c1     uuid; v_c2 uuid;
    v_r      jsonb;
    v_rep    jsonb;
    v_inv1   uuid; v_inv2 uuid;
    v_snap1  jsonb; v_snap2 jsonb;
    v_denied boolean; v_msg text;
    v_n      integer;
    v_sale   uuid;
    def_save text; v_inj text;
    v_mat uuid; v_batch uuid;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-145', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);
    UPDATE finance_settings SET locked_before = NULL;
    def_save := pg_get_functiondef('public.save_counterparty_contact(uuid,uuid,text,text,text,text,text,boolean,uuid)'::regprocedure);

    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('FIXT-M145', 'Fixture Material 145', 'battery_material', true, 'black_mass', 'end_of_life')
    RETURNING id INTO v_mat;

    -- ★【这一家【两边都有】,而且用【同一个登记号】—— E 臂的主角】★
    INSERT INTO customers (legal_name, country, tax_id, default_tax_code, payment_terms_days)
    VALUES ('Fixture 145 Trading Pte Ltd', 'SG', 'F145UEN0001', 'SR', 45) RETURNING id INTO v_cust;
    INSERT INTO suppliers (code, legal_name, country, counterparty_type, tax_id)
    VALUES ('FIXT-S145', 'Fixture 145 Trading Pte Ltd', 'SG', 'goods_supplier', 'F145UEN0001')
    RETURNING id INTO v_sup;
    -- 一个【只同名、没有登记号】的对子 —— 用来证明弱信号那一组不是摆设
    INSERT INTO customers (legal_name, country, default_tax_code, payment_terms_days)
    VALUES ('Fixture 145  Namesake   Metals', 'SG', 'SR', 30) RETURNING id INTO v_cust2;
    INSERT INTO suppliers (code, legal_name, country, counterparty_type)
    VALUES ('FIXT-S145N', 'FIXTURE 145 NAMESAKE METALS', 'SG', 'goods_supplier');

    -- ══════════ A. 归属、够得着、有名字 ═══════════════════════════════════
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM save_counterparty_contact(p_customer_id => v_cust, p_supplier_id => v_sup,
                                            p_name => 'Both', p_email => 'b@x.com');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'CONTACT_OWNER_REQUIRED%' THEN
        RAISE EXCEPTION 'FIXTURE 145A 失败:两边都填应当按名拒,实得 %', COALESCE(v_msg,'(写进去了)'); END IF;

    v_denied := false; v_msg := NULL;
    BEGIN PERFORM save_counterparty_contact(p_name => 'Nobody', p_email => 'n@x.com');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'CONTACT_OWNER_REQUIRED%' THEN
        RAISE EXCEPTION 'FIXTURE 145A 失败:两边都不填也应当按名拒,实得 %', COALESCE(v_msg,'(写进去了)'); END IF;

    -- 【只有名字、够不着】—— 这条 CHECK 是本表存在的一半理由
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM save_counterparty_contact(p_customer_id => v_cust, p_name => 'Ghost');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'CONTACT_UNREACHABLE|%' THEN
        RAISE EXCEPTION 'FIXTURE 145A 失败:够不着的联系人应当按名拒,实得 %', COALESCE(v_msg,'(写进去了)'); END IF;

    -- 【空字符串不是"填了"】'' 必须在函数里落成 NULL,否则两个空框会溜过 CHECK
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM save_counterparty_contact(p_customer_id => v_cust, p_name => 'Ghost2',
                                            p_email => '   ', p_phone => '');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'CONTACT_UNREACHABLE|%' THEN
        RAISE EXCEPTION 'FIXTURE 145A 失败:全是空白的联系方式应当等于没填,实得 %', COALESCE(v_msg,'(写进去了)'); END IF;

    v_denied := false; v_msg := NULL;
    BEGIN PERFORM save_counterparty_contact(p_customer_id => v_cust, p_name => '   ', p_email => 'x@x.com');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'CONTACT_NAME_REQUIRED%' THEN
        RAISE EXCEPTION 'FIXTURE 145A 失败:空白名字应当按名拒,实得 %', COALESCE(v_msg,'(写进去了)'); END IF;

    -- ══════════ B. 主联系人每边最多一个,换主是一笔事务里的事 ══════════════
    v_r := save_counterparty_contact(p_customer_id => v_cust, p_name => 'Alice Tan',
                                     p_role => 'Accounts', p_email => 'alice@f145.com',
                                     p_is_primary => true);
    v_c1 := (v_r->>'contact_id')::uuid;
    v_r := save_counterparty_contact(p_customer_id => v_cust, p_name => 'Bob Lim',
                                     p_role => 'Operations', p_phone => '+65 9000 0000',
                                     p_is_primary => false);
    v_c2 := (v_r->>'contact_id')::uuid;

    -- 陷阱 (d):比对之前先证明集合是【两行】,不是空的
    SELECT count(*) INTO v_n FROM counterparty_contacts WHERE customer_id = v_cust AND deleted_at IS NULL;
    IF v_n <> 2 THEN RAISE EXCEPTION 'FIXTURE 145B 失败:应当有 2 个联系人,实得 %', v_n; END IF;
    SELECT count(*) INTO v_n FROM counterparty_contacts
     WHERE customer_id = v_cust AND is_primary AND deleted_at IS NULL;
    IF v_n <> 1 THEN RAISE EXCEPTION 'FIXTURE 145B 失败:主联系人应当恰好 1 个,实得 %', v_n; END IF;

    -- ══════════ C. ★ 开票快照取主联系人:换主 → 下一张换人,上一张不动 ★ ════
    -- 【陷阱 (a) 就躲在这一臂的构造里】它不比"两个实现",它比的是
    -- 【两张先后开出的发票】—— 一个"快照永远跟着当前主联系人走"的实现
    -- 会让第一张票也变成 Bob,而那正是这一臂要抓的那件事。
    INSERT INTO output_batches (material_id, code, quantity, remaining_qty, unit,
                                output_date, state, customer_id)
    VALUES (v_mat, 'F145-BATCH-1', 100, 100, 'kg', '2026-08-01', '库存中', v_cust) RETURNING id INTO v_batch;
    INSERT INTO sales_records (output_batch_id, customer_id, quantity, unit_price,
                               currency, fx_rate, amount_base, sale_date)
    VALUES (v_batch, v_cust, 100, 10, 'SGD', 1, 1000, '2026-08-01')
    RETURNING id INTO v_sale;
    v_r := create_invoice(v_cust, ARRAY[v_sale], '2026-08-01', 45);
    v_inv1 := (v_r->>'invoice_id')::uuid;
    SELECT bill_to_snapshot INTO v_snap1 FROM invoices WHERE id = v_inv1;
    IF v_snap1->>'contact_person' <> 'Alice Tan' THEN
        RAISE EXCEPTION 'FIXTURE 145C 失败:第一张票的快照应当写着主联系人 Alice Tan,实得 %',
            COALESCE(v_snap1->>'contact_person','(空)'); END IF;
    IF v_snap1->>'email' <> 'alice@f145.com' THEN
        RAISE EXCEPTION 'FIXTURE 145C 失败:快照的邮箱应当来自主联系人那一行,实得 %',
            COALESCE(v_snap1->>'email','(空)'); END IF;

    -- 换主:Bob 上位
    PERFORM save_counterparty_contact(p_customer_id => v_cust, p_contact_id => v_c2,
                                      p_name => 'Bob Lim', p_role => 'Operations',
                                      p_phone => '+65 9000 0000', p_is_primary => true);
    SELECT count(*) INTO v_n FROM counterparty_contacts
     WHERE customer_id = v_cust AND is_primary AND deleted_at IS NULL;
    IF v_n <> 1 THEN RAISE EXCEPTION 'FIXTURE 145C 失败:换主之后仍应恰好 1 个主,实得 %', v_n; END IF;
    IF (SELECT is_primary FROM counterparty_contacts WHERE id = v_c1) THEN
        RAISE EXCEPTION 'FIXTURE 145C 失败:旧主没有被撤掉'; END IF;

    INSERT INTO output_batches (material_id, code, quantity, remaining_qty, unit,
                                output_date, state, customer_id)
    VALUES (v_mat, 'F145-BATCH-2', 100, 100, 'kg', '2026-08-02', '库存中', v_cust) RETURNING id INTO v_batch;
    INSERT INTO sales_records (output_batch_id, customer_id, quantity, unit_price,
                               currency, fx_rate, amount_base, sale_date)
    VALUES (v_batch, v_cust, 100, 10, 'SGD', 1, 1000, '2026-08-02')
    RETURNING id INTO v_sale;
    v_r := create_invoice(v_cust, ARRAY[v_sale], '2026-08-02', 45);
    v_inv2 := (v_r->>'invoice_id')::uuid;
    SELECT bill_to_snapshot INTO v_snap2 FROM invoices WHERE id = v_inv2;
    IF v_snap2->>'contact_person' <> 'Bob Lim' THEN
        RAISE EXCEPTION 'FIXTURE 145C 失败:第二张票应当写着新的主联系人 Bob Lim,实得 %',
            COALESCE(v_snap2->>'contact_person','(空)'); END IF;
    -- ★★ 最要紧的一句:第一张票【一个字节都没变】★★
    IF (SELECT bill_to_snapshot FROM invoices WHERE id = v_inv1) IS DISTINCT FROM v_snap1 THEN
        RAISE EXCEPTION 'FIXTURE 145C 失败:★ 换主联系人改写了【已经开出去】的发票快照 ★'; END IF;
    IF v_snap1->>'contact_person' = v_snap2->>'contact_person' THEN
        RAISE EXCEPTION 'FIXTURE 145C 失败:两张票的联系人相同 —— 这一臂因此证明不了任何事'; END IF;

    -- ══════════ D. ★ 账期不再编 30 天,两扇门都拒 ★ ═══════════════════════
    -- v_cust2 的 payment_terms_days 是 30(设过的),所以先把它清掉再试。
    UPDATE customers SET payment_terms_days = NULL WHERE id = v_cust2;
    INSERT INTO output_batches (material_id, code, quantity, remaining_qty, unit,
                                output_date, state, customer_id)
    VALUES (v_mat, 'F145-BATCH-3', 10, 10, 'kg', '2026-08-03', '库存中', v_cust2) RETURNING id INTO v_batch;
    INSERT INTO sales_records (output_batch_id, customer_id, quantity, unit_price,
                               currency, fx_rate, amount_base, sale_date)
    VALUES (v_batch, v_cust2, 10, 10, 'SGD', 1, 100, '2026-08-03')
    RETURNING id INTO v_sale;
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM create_invoice(v_cust2, ARRAY[v_sale], '2026-08-03');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'CUSTOMER_PAYMENT_TERMS_NOT_SET|%' THEN
        RAISE EXCEPTION 'FIXTURE 145D 失败:没有账期就开票应当按名拒(不许编 30 天),实得 %',
            COALESCE(v_msg,'(开出去了)'); END IF;
    -- 【显式给一个就放行,而且用的是给的那个】—— 否则这条拒绝会挡死一条正当的路
    v_r := create_invoice(v_cust2, ARRAY[v_sale], '2026-08-03', 14);
    IF (SELECT due_date - issue_date FROM invoices WHERE id = (v_r->>'invoice_id')::uuid) <> 14 THEN
        RAISE EXCEPTION 'FIXTURE 145D 失败:显式账期 14 天应当被原样用上'; END IF;
    -- 【客户设了也放行】把那条路的另一半也走一遍
    UPDATE customers SET payment_terms_days = 60 WHERE id = v_cust2;
    INSERT INTO output_batches (material_id, code, quantity, remaining_qty, unit,
                                output_date, state, customer_id)
    VALUES (v_mat, 'F145-BATCH-4', 10, 10, 'kg', '2026-08-04', '库存中', v_cust2) RETURNING id INTO v_batch;
    INSERT INTO sales_records (output_batch_id, customer_id, quantity, unit_price,
                               currency, fx_rate, amount_base, sale_date)
    VALUES (v_batch, v_cust2, 10, 10, 'SGD', 1, 100, '2026-08-04')
    RETURNING id INTO v_sale;
    v_r := create_invoice(v_cust2, ARRAY[v_sale], '2026-08-04');
    IF (SELECT due_date - issue_date FROM invoices WHERE id = (v_r->>'invoice_id')::uuid) <> 60 THEN
        RAISE EXCEPTION 'FIXTURE 145D 失败:客户设的 60 天应当被用上'; END IF;

    -- ══════════ E. ★ 重叠报告:先证明分母不是 0,再谈"抓到了" ★ ═══════════
    v_rep := counterparty_overlap_report();
    -- 陷阱 (d):**先看分母**。线上今天 customers 的 tax_id 是 0 个,
    -- 所以一份"没有重叠"的报告必然为真而毫无信息 —— 本臂自己造了重叠。
    IF (v_rep->'coverage'->>'customers_with_tax_id')::int < 1
       OR (v_rep->'coverage'->>'suppliers_with_tax_id')::int < 1 THEN
        RAISE EXCEPTION 'FIXTURE 145E 失败:分母是 0 —— 这一臂问的是一个没有东西可比的问题(%)',
            v_rep->'coverage'; END IF;
    SELECT count(*) INTO v_n FROM jsonb_array_elements(v_rep->'by_tax_id') x
     WHERE (x->>'tax_id') = 'F145UEN0001';
    IF v_n <> 1 THEN RAISE EXCEPTION 'FIXTURE 145E 失败:同登记号那一对应当被抓到 1 次,实得 %', v_n; END IF;
    -- 【弱信号那组:同名的抓到,而已被登记号抓到的【不重复计】】
    SELECT count(*) INTO v_n FROM jsonb_array_elements(v_rep->'by_name') x
     WHERE (x->>'customer_id')::uuid = v_cust2;
    IF v_n <> 1 THEN RAISE EXCEPTION 'FIXTURE 145E 失败:只同名那一对应当出现在 by_name 里 1 次,实得 %', v_n; END IF;
    SELECT count(*) INTO v_n FROM jsonb_array_elements(v_rep->'by_name') x
     WHERE (x->>'customer_id')::uuid = v_cust;
    IF v_n <> 0 THEN RAISE EXCEPTION 'FIXTURE 145E 失败:已被登记号抓到的那一对不该在 by_name 里再算一次'; END IF;
    -- ★【两个敞口是【两个数】,不是一个和】★ 这一句在的理由就是那句"轧差是法律行为"。
    IF NOT (v_rep->'by_tax_id'->0) ? 'ar_open_base'
       OR NOT (v_rep->'by_tax_id'->0) ? 'ap_open_base' THEN
        RAISE EXCEPTION 'FIXTURE 145E 失败:两个敞口必须分开出现'; END IF;
    IF (v_rep->'by_tax_id'->0) ? 'net_base' OR (v_rep->'by_tax_id'->0) ? 'net_exposure' THEN
        RAISE EXCEPTION 'FIXTURE 145E 失败:★ 报告里出现了一个【净额】—— 轧差是一次法律行为,不是一次算术 ★'; END IF;
    IF (v_rep->>'exposures_are_not_netted')::boolean IS NOT TRUE
       OR btrim(COALESCE(v_rep->>'why_not_netted','')) = '' THEN
        RAISE EXCEPTION 'FIXTURE 145E 失败:那句"为什么不轧差"必须跟着数字一起返回'; END IF;

    -- ══════════ F. 权限,以及软删不自动挑新主 ═══════════════════════════════
    -- ★ 陷阱 (c):**真的用一个没权限的角色去调**,不是去源码里找那几个字。
    DELETE FROM role_permissions WHERE role_id = r_all AND permission_code = 'module.customers.edit';
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM save_counterparty_contact(p_customer_id => v_cust, p_name => 'X', p_email => 'x@x.com');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'PERMISSION_DENIED%' THEN
        RAISE EXCEPTION 'FIXTURE 145F 失败:没有 customers.edit 不该写得了客户联系人,实得 %',
            COALESCE(v_msg,'(写进去了)'); END IF;
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM soft_delete_counterparty_contact(v_c1);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'PERMISSION_DENIED%' THEN
        RAISE EXCEPTION 'FIXTURE 145F 失败:软删也要 customers.edit,实得 %', COALESCE(v_msg,'(删了)'); END IF;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_all, 'module.customers.edit');
    -- 【而这一句证明上面两个拒绝【不是】因为函数本来就不工作】
    v_r := save_counterparty_contact(p_customer_id => v_cust, p_name => 'Carol Ng', p_email => 'carol@f145.com');
    IF (v_r->>'contact_id') IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 145F 失败:补回权限之后应当写得进去 —— 上面那两个拒绝因此不是一次测量'; END IF;

    -- 重叠报告也要两侧权限:只有一侧时它给出的是【误导性的半张表】
    DELETE FROM role_permissions WHERE role_id = r_all AND permission_code = 'module.suppliers.view';
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM counterparty_overlap_report();
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'PERMISSION_DENIED%' THEN
        RAISE EXCEPTION 'FIXTURE 145F 失败:重叠报告要两侧权限,实得 %', COALESCE(v_msg,'(给了)'); END IF;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_all, 'module.suppliers.view');

    -- 【软删主联系人之后,不自动挑一个顶上】那会让开票快照悄悄换人
    PERFORM soft_delete_counterparty_contact(v_c2);   -- v_c2 此刻是主
    SELECT count(*) INTO v_n FROM counterparty_contacts
     WHERE customer_id = v_cust AND is_primary AND deleted_at IS NULL;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 145F 失败:删掉主联系人之后不该有人被自动顶上去,实得 % 个主', v_n; END IF;
    -- 而这时开票仍然【放行】(没有联系人不是错误),快照那三个键是 NULL
    INSERT INTO output_batches (material_id, code, quantity, remaining_qty, unit,
                                output_date, state, customer_id)
    VALUES (v_mat, 'F145-BATCH-5', 10, 10, 'kg', '2026-08-05', '库存中', v_cust) RETURNING id INTO v_batch;
    INSERT INTO sales_records (output_batch_id, customer_id, quantity, unit_price,
                               currency, fx_rate, amount_base, sale_date)
    VALUES (v_batch, v_cust, 10, 10, 'SGD', 1, 100, '2026-08-05')
    RETURNING id INTO v_sale;
    v_r := create_invoice(v_cust, ARRAY[v_sale], '2026-08-05', 45);
    IF (SELECT bill_to_snapshot->>'contact_person' FROM invoices WHERE id = (v_r->>'invoice_id')::uuid) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 145F 失败:没有主联系人时快照那一键应当是 NULL'; END IF;

    -- ══════════ G. 目录事实 —— 查 pg_catalog,不 grep 源码(陷阱 b)═════════
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conrelid = 'public.counterparty_contacts'::regclass
                      AND conname = 'counterparty_contacts_exactly_one_owner') THEN
        RAISE EXCEPTION 'FIXTURE 145G 失败:恰好一个归属那条 CHECK 不在目录里'; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname='public'
                    AND indexname = 'counterparty_contacts_one_primary_customer') THEN
        RAISE EXCEPTION 'FIXTURE 145G 失败:每客户一个主联系人的部分唯一索引不在目录里'; END IF;
    -- 【本表【没有】INSERT/UPDATE 策略 —— 那是刻意的,不是漏了】
    SELECT count(*) INTO v_n FROM pg_policy
     WHERE polrelid = 'public.counterparty_contacts'::regclass AND polcmd IN ('a','w');
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 145G 失败:本表不该有 INSERT/UPDATE 策略(写入只走函数),实得 % 条', v_n; END IF;
    SELECT count(*) INTO v_n FROM pg_policy
     WHERE polrelid = 'public.counterparty_contacts'::regclass AND polcmd = 'r';
    IF v_n <> 1 THEN RAISE EXCEPTION 'FIXTURE 145G 失败:应当恰好一条 SELECT 策略,实得 %', v_n; END IF;
    -- 三支函数都必须是 definer(它们要绕过本表的无写策略)
    SELECT count(*) INTO v_n FROM pg_proc
     WHERE proname IN ('save_counterparty_contact','soft_delete_counterparty_contact','counterparty_overlap_report')
       AND prosecdef;
    IF v_n <> 3 THEN RAISE EXCEPTION 'FIXTURE 145G 失败:三支函数都应当是 SECURITY DEFINER,实得 %', v_n; END IF;
    -- 【客户那三列真的没了】—— 留着就是同一个事实两个地方
    SELECT count(*) INTO v_n FROM information_schema.columns
     WHERE table_schema='public' AND table_name='customers'
       AND column_name IN ('contact_person','email','phone');
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 145G 失败:customers 上那三列还在(% 列)—— 同一个事实两个地方', v_n; END IF;

    -- ══════════ 故障注入 —— 每一处都先证明"注入真的改了东西"(陷阱 e)═══════
    -- 注入 1:把"设主之前先撤旧主"那一段短路掉 → 应当撞上部分唯一索引
    v_inj := replace(def_save, 'IF p_is_primary THEN', 'IF false THEN');
    IF v_inj = def_save THEN
        RAISE EXCEPTION 'FIXTURE 145 注入1 失败:没找到"设主先撤旧"那一段的原文 —— 这个注入什么也没删'; END IF;
    EXECUTE v_inj;
    PERFORM save_counterparty_contact(p_customer_id => v_cust2, p_name => 'P1', p_email => 'p1@x.com', p_is_primary => true);
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM save_counterparty_contact(p_customer_id => v_cust2, p_name => 'P2', p_email => 'p2@x.com', p_is_primary => true);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 145 注入1 失败:摘掉"先撤旧主"之后,第二个主应当撞上唯一索引 —— 说明 B/C 臂靠的不是那一段'; END IF;
    EXECUTE def_save;   -- 放回去
    -- 放回去之后同一件事应当成功(证明上面那次红是注入造成的,不是数据造成的)
    PERFORM save_counterparty_contact(p_customer_id => v_cust2, p_name => 'P3', p_email => 'p3@x.com', p_is_primary => true);
END $$;
ROLLBACK;
