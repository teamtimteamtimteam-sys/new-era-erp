-- 127 一条规矩,两个问法;以及一个搁不死单据的开关(SOD-1)
--
-- 【这份 fixture 的三个层次】
--   (P) **前提** —— 规矩赖以成立的那些事实,先断言它们,再断言从它们推出来的东西。
--       P1 是本刀最容易被忽略的一件:控制②的主语(suppliers.created_by)
--       **在这一刀之前恒为 NULL**,一条挂在恒为 NULL 上的规矩永远不会触发。
--   (A/B) **两条路各自的正、反、边界**,每一条都有一个【会通过】的臂 ——
--       一份只断言"被拒"的 fixture,在一个【什么都拒】的实现上全绿。
--   (C) **开关的两道闸**,包括反方向那一半(关掉时不许搁死在途单据)。
--
-- 【为什么直连 INSERT/UPDATE 才是被测的那条路】职责分离的两道闸是【触发器】,
-- 因为 authenticated 对 payments 与 finance_settings 持表级授权,
-- 而 /finance/settings 的"手动锁"就是一条直连 UPDATE(GO-2 的同一个洞)。
-- 所以后门臂 **SET LOCAL ROLE authenticated** —— 不切角色证的是"postgres 能不能",
-- 那永远为真,臂就空转了(fixture 26 的 A/C 臂正是这样空转过)。
--
-- 【claims 必须设】fixtures 以 postgres 跑,auth.uid() 读 request.jwt.claims。
-- 不设 claims,assert_segregated 的第一句就 RETURN —— 每一臂都会"通过",
-- 而它证明的是【空转】。
--
-- 自带数据(README 第 2 条)。不继承 locked_before —— 自己设(README 第 4 条)。
-- 日期算出来、不写死:年结不可删改,只能把自己的日期放到既有年结之后(fixture 122)。
BEGIN;
DO $$
DECLARE
    v_a      uuid := gen_random_uuid();   -- 演员 A:又记账又想关账 / 又建户又想付款
    v_b      uuid := gen_random_uuid();   -- 演员 B:另一个人
    v_ghost  uuid := gen_random_uuid();   -- 一个【不在 auth.users 里】的 uuid
    r_ok     uuid;                        -- 有权限的角色
    r_empty  uuid;                        -- 没有任何真人持有的角色
    v_maxyc  date;  v_m1 date;  v_m2 date;  v_d1 date;  v_d2 date;
    c1 text; c2 text; L jsonb; je jsonb;
    v_sup_a uuid; v_sup_b uuid; v_sup_null uuid;
    v_bank text; v_ccy text; v_po uuid;
    v_msg text; v_denied boolean; v_cb uuid; v_n int;
    r jsonb := '{}'::jsonb;
BEGIN
    -- ══════════════════════ 布景 ══════════════════════
    INSERT INTO auth.users (id) VALUES (v_a), (v_b);      -- 【真的】账号(FK 与闸都要它)

    INSERT INTO roles (code,name_en,name_zh,is_active)
      VALUES ('fixture-127','f','f',true) RETURNING id INTO r_ok;
    INSERT INTO role_permissions (role_id,permission_code)
      SELECT r_ok, unnest(ARRAY['module.finance.view','module.finance.edit',
                                'module.suppliers.view','module.suppliers.edit',
                                'module.purchasing.view','module.purchasing.edit']);
    INSERT INTO user_roles (user_id,role_id) VALUES (v_a,r_ok),(v_b,r_ok);

    -- 一个【没有任何真人持有】的角色 —— C2 用它
    INSERT INTO roles (code,name_en,name_zh,is_active)
      VALUES ('fixture-127-empty','f','f',true) RETURNING id INTO r_empty;

    SELECT COALESCE(MAX(year_end), DATE '2000-12-31') INTO v_maxyc
      FROM year_closes WHERE reopened_at IS NULL;
    -- 两个【不相邻也不重叠】的月份:A 的手工凭证落在 M1,A 的非手工凭证落在 M2。
    -- 分开是为了让"范围"那一臂不被"拒绝"那一臂的数据污染(README 第 2 条)。
    v_m1 := (date_trunc('month', GREATEST(DATE '2025-12-31', v_maxyc + 400))
             + interval '1 month - 1 day')::date;
    v_m2 := (date_trunc('month', v_m1 + 40) + interval '1 month - 1 day')::date;
    v_d1 := v_m1 - 5;
    v_d2 := v_m2 - 5;

    SELECT code INTO c1 FROM accounts WHERE is_active ORDER BY code LIMIT 1;
    SELECT code INTO c2 FROM accounts WHERE is_active AND code<>c1 ORDER BY code LIMIT 1;
    SELECT code INTO v_bank FROM accounts WHERE is_active AND is_cash ORDER BY code LIMIT 1;
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    L := jsonb_build_array(
        jsonb_build_object('account_code',c1,'side','debit','amount_ccy',10,'currency',v_ccy,'fx_rate',1),
        jsonb_build_object('account_code',c2,'side','credit','amount_ccy',10,'currency',v_ccy,'fx_rate',1));

    UPDATE finance_settings SET locked_before = NULL;   -- 不继承运行时状态

    -- ═════════ P1 · 前提:建供应商的人【被记了下来】 ═════════
    -- 这一刀之前这里恒为 NULL(线上 8 家全部为 NULL,列无默认值,app 不传)。
    -- **控制②的整条推理都站在这一条上,所以它先被断言。**
    -- 故障注入方向:去掉 trg_supplier_creator,这一臂立刻红 —— 而如果只测 B1,
    -- B1 会因为 created_by 为 NULL 而"通过",也就是为了错的理由通过。
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_a), true);
    INSERT INTO suppliers (code, legal_name, country, counterparty_type)
      VALUES ('ZZ-SOD1-A', 'ZZ SOD1 A', 'SG', 'goods_supplier') RETURNING id INTO v_sup_a;
    SELECT created_by INTO v_cb FROM suppliers WHERE id = v_sup_a;
    IF v_cb IS DISTINCT FROM v_a THEN
        RAISE EXCEPTION 'P1 失败:建供应商的人没有被记下来(created_by=%,应为 %)', v_cb, v_a;
    END IF;
    r := r || jsonb_build_object('P1_supplier_creator_stamped', true);

    -- ═════════ P2 · 前提:手工凭证记得住它的记账人 ═════════
    je := post_journal_entry(v_d1, 'fixture 127 A 的手工凭证', 'manual', NULL, L);
    SELECT created_by INTO v_cb FROM journal_entries WHERE id = (je->>'entry_id')::uuid;
    IF v_cb IS DISTINCT FROM v_a THEN
        RAISE EXCEPTION 'P2 失败:手工凭证没有记住记账人(created_by=%,应为 %)', v_cb, v_a;
    END IF;
    r := r || jsonb_build_object('P2_manual_poster_stamped', true);

    -- ═════════ A1 · 正门:A 记了手工凭证,A 不许关那个期间 ═════════
    v_denied := false;
    BEGIN
        PERFORM close_period(v_m1, 'fixture 127');
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM; v_denied := (SQLERRM LIKE 'SOD_POST_AND_CLOSE|%');
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'A1 失败:A 关掉了自己记过手工凭证的期间(msg=%)', COALESCE(v_msg,'(没有报错)');
    END IF;
    r := r || jsonb_build_object('A1_front_door_refused', v_msg);

    -- ═════════ A2 · 后门:直连 UPDATE 同样被拒(GO-2 的那一半) ═════════
    v_denied := false;
    BEGIN
        EXECUTE 'SET LOCAL ROLE authenticated';
        UPDATE finance_settings SET locked_before = v_m1 + 1;
        EXECUTE 'RESET ROLE';
    EXCEPTION WHEN OTHERS THEN
        EXECUTE 'RESET ROLE';
        v_msg := SQLERRM; v_denied := (SQLERRM LIKE 'SOD_POST_AND_CLOSE|%');
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'A2 失败:直连 UPDATE 绕过了职责分离(msg=%)', COALESCE(v_msg,'(没有报错)');
    END IF;
    r := r || jsonb_build_object('A2_back_door_refused', v_msg);

    -- ═════════ A3 · 【会通过】的那一臂:B 没记过手工凭证,B 关得了 ═════════
    -- 少了这一臂,一个"谁都不许关账"的实现能让 A1/A2 全绿。
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_b), true);
    PERFORM close_period(v_m1, 'fixture 127 B 关账');
    IF (SELECT locked_before FROM finance_settings) <> v_m1 + 1 THEN
        RAISE EXCEPTION 'A3 失败:B 应当关得了这个期间';
    END IF;
    r := r || jsonb_build_object('A3_other_person_may_close', true);

    -- ═════════ A4 · 范围:【非手工】凭证不算 ═════════
    -- 规矩的主语是那一笔【自由裁量的调整】,不是"引起过任何一笔分录的人"。
    -- 一个把所有 source_type 都算进来的实现会在这一臂变红。
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_a), true);
    PERFORM post_journal_entry(v_d2, 'fixture 127 A 的付款分录', 'payment', NULL, L);
    PERFORM close_period(v_m2, 'fixture 127 A 关账(只有非手工凭证)');
    IF (SELECT locked_before FROM finance_settings) <> v_m2 + 1 THEN
        RAISE EXCEPTION 'A4 失败:只记过非手工凭证的人应当关得了这个期间';
    END IF;
    r := r || jsonb_build_object('A4_non_manual_does_not_block', true);

    -- ═════════ A5 · 方向:把锁【往回】搬不受管 ═════════
    -- 解锁与 reopen 不隐藏任何东西,拦它只会把纠错的路堵死。
    EXECUTE 'SET LOCAL ROLE authenticated';
    UPDATE finance_settings SET locked_before = v_m1 + 1;
    EXECUTE 'RESET ROLE';
    r := r || jsonb_build_object('A5_moving_the_lock_back_is_free', true);

    -- ═════════ B1 · A 建的供应商,A 不许付款给它(后门,直连 INSERT) ═════════
    v_denied := false;
    BEGIN
        EXECUTE 'SET LOCAL ROLE authenticated';
        INSERT INTO payments (code,direction,counterparty_type,supplier_id,amount_ccy,currency,
                              fx_rate,amount_base,bank_account_code,payment_date)
          VALUES ('ZZ-SOD1-P1','out','supplier',v_sup_a,10,v_ccy,1,10,v_bank,v_d2);
        EXECUTE 'RESET ROLE';
    EXCEPTION WHEN OTHERS THEN
        EXECUTE 'RESET ROLE';
        v_msg := SQLERRM; v_denied := (SQLERRM LIKE 'SOD_PAYEE_AND_PAY|%');
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'B1 失败:建户的人付款给了自己建的户(msg=%)', COALESCE(v_msg,'(没有报错)');
    END IF;
    r := r || jsonb_build_object('B1_creator_may_not_pay', v_msg);

    -- ═════════ B2 · 【会通过】的那一臂:B 付得了 A 建的户 ═════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_b), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    INSERT INTO payments (code,direction,counterparty_type,supplier_id,amount_ccy,currency,
                          fx_rate,amount_base,bank_account_code,payment_date)
      VALUES ('ZZ-SOD1-P2','out','supplier',v_sup_a,10,v_ccy,1,10,v_bank,v_d2);
    EXECUTE 'RESET ROLE';
    r := r || jsonb_build_object('B2_another_person_may_pay', true);

    -- ═════════ B3 · 范围:规矩问的是【这一家】的建户人,不是"A 不许付任何款" ═════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_b), true);
    INSERT INTO suppliers (code, legal_name, country, counterparty_type)
      VALUES ('ZZ-SOD1-B', 'ZZ SOD1 B', 'SG', 'goods_supplier') RETURNING id INTO v_sup_b;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_a), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    INSERT INTO payments (code,direction,counterparty_type,supplier_id,amount_ccy,currency,
                          fx_rate,amount_base,bank_account_code,payment_date)
      VALUES ('ZZ-SOD1-P3','out','supplier',v_sup_b,10,v_ccy,1,10,v_bank,v_d2);
    EXECUTE 'RESET ROLE';
    r := r || jsonb_build_object('B3_rule_is_about_this_payee', true);

    -- ═════════ B4 · 【主语缺席】—— 这一臂断言的是"规矩不适用",不是"规矩通过" ═════════
    -- AGENTS.md:一份 fixture 可以把规矩测得很透,却对【规矩的主语根本不存在】
    -- 那一格视而不见。线上 8 家既有供应商的 created_by 全为 NULL,这一格今天成立。
    -- 答案必须被写下来(允许),而不是让它成为守卫那句 IF 碰巧的行为。
    -- 代价记在 docs/known-issues.md 的 SOD-1-BLIND 条。
    -- 【怎么造出一家 created_by 为 NULL 的供应商】显式传 NULL 是【不够的】:
    -- trg_supplier_creator 认的就是 "NEW.created_by IS NULL",显式 NULL 与省略
    -- 在触发器眼里一模一样,照样会被盖上。**这一条是实测撞出来的,不是推想的。**
    -- 今天唯一还能留下 NULL 的路,正是触发器那句判据的反面:写入者不是一个
    -- auth.users 里的账号 —— 也就是线上那 8 行当年的处境(那时根本没有这个触发器)。
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_ghost), true);
    INSERT INTO suppliers (code, legal_name, country, counterparty_type)
      VALUES ('ZZ-SOD1-N', 'ZZ SOD1 NULL', 'SG', 'goods_supplier') RETURNING id INTO v_sup_null;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_a), true);
    IF (SELECT created_by FROM suppliers WHERE id=v_sup_null) IS NOT NULL THEN
        RAISE EXCEPTION 'B4 前提失败:这一臂需要一家 created_by 为 NULL 的供应商';
    END IF;
    EXECUTE 'SET LOCAL ROLE authenticated';
    INSERT INTO payments (code,direction,counterparty_type,supplier_id,amount_ccy,currency,
                          fx_rate,amount_base,bank_account_code,payment_date)
      VALUES ('ZZ-SOD1-P4','out','supplier',v_sup_null,10,v_ccy,1,10,v_bank,v_d2);
    EXECUTE 'RESET ROLE';
    r := r || jsonb_build_object('B4_absent_subject_is_allowed_and_stated', true);

    -- ═════════ B5 · 冲销走得通,而且那面旗【用完就落】 ═════════
    -- 两句话一起断言,因为它们是一对:旗立不起来,冲销被拦死;旗落不下来,
    -- 同一事务里后面每一笔直连 INSERT 都畅通无阻(APR-2c fu2 实测过的那一幕)。
    PERFORM set_config('evoltrya.payment_reversal_ctx', '1', true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    INSERT INTO payments (code,direction,counterparty_type,supplier_id,amount_ccy,currency,
                          fx_rate,amount_base,bank_account_code,payment_date)
      VALUES ('ZZ-SOD1-P5','out','supplier',v_sup_a,10,v_ccy,1,10,v_bank,v_d2);
    EXECUTE 'RESET ROLE';
    PERFORM set_config('evoltrya.payment_reversal_ctx', '', true);

    v_denied := false;
    BEGIN
        EXECUTE 'SET LOCAL ROLE authenticated';
        INSERT INTO payments (code,direction,counterparty_type,supplier_id,amount_ccy,currency,
                              fx_rate,amount_base,bank_account_code,payment_date)
          VALUES ('ZZ-SOD1-P6','out','supplier',v_sup_a,10,v_ccy,1,10,v_bank,v_d2);
        EXECUTE 'RESET ROLE';
    EXCEPTION WHEN OTHERS THEN
        EXECUTE 'RESET ROLE';
        v_denied := (SQLERRM LIKE 'SOD_PAYEE_AND_PAY|%');
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'B5 失败:冲销那面旗【没有落下来】—— 它之后的直连付款应当仍然被拒';
    END IF;
    r := r || jsonb_build_object('B5_reversal_flag_raises_and_falls', true);

    -- ═════════ C1 · 三个策略值都没设,开关【开不起来】 ═════════
    v_denied := false;
    BEGIN
        UPDATE finance_settings SET approvals_enabled = true;
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM; v_denied := (SQLERRM LIKE 'APPROVALS_POLICY_INCOMPLETE|%');
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'C1 失败:策略未配时开关不该开得起来(msg=%)', COALESCE(v_msg,'(没有报错)');
    END IF;
    r := r || jsonb_build_object('C1_incomplete_policy_refused', v_msg);

    -- ═════════ C2 · 一级角色【没有真人持有】—— 那是一个永远不会有人来批的队列 ═════════
    v_denied := false;
    BEGIN
        UPDATE finance_settings
           SET approval_level1_role_code='fixture-127-empty',
               approval_threshold_base=25000, approval_level2_user_id=v_b,
               approvals_enabled=true;
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM; v_denied := (SQLERRM LIKE 'APPROVALS_LEVEL1_ROLE_UNHELD|%');
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'C2 失败:无人持有的一级角色不该让开关开起来(msg=%)', COALESCE(v_msg,'(没有报错)');
    END IF;
    r := r || jsonb_build_object('C2_unheld_level1_refused', v_msg);

    -- ═════════ C3 · 二级审批人不是一个真的账号 ═════════
    v_denied := false;
    BEGIN
        UPDATE finance_settings
           SET approval_level1_role_code='fixture-127',
               approval_threshold_base=25000, approval_level2_user_id=v_ghost,
               approvals_enabled=true;
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM; v_denied := (SQLERRM LIKE 'APPROVALS_LEVEL2_USER_UNKNOWN|%');
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'C3 失败:不存在的二级审批人不该让开关开起来(msg=%)', COALESCE(v_msg,'(没有报错)');
    END IF;
    r := r || jsonb_build_object('C3_ghost_level2_refused', v_msg);

    -- ═════════ C4 · 【会通过】的那一臂:三样都对,开得起来 ═════════
    -- 少了它,一个"永远不许开"的实现能让 C1/C2/C3 全绿。
    UPDATE finance_settings
       SET approval_level1_role_code='fixture-127',
           approval_threshold_base=25000, approval_level2_user_id=v_b,
           approvals_enabled=true;
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'C4 失败:配齐之后开关应当开得起来';
    END IF;
    r := r || jsonb_build_object('C4_complete_policy_enables', true);

    -- ═════════ C5 · 关掉开关会把在途单据搁死 —— 所以点名拒绝 ═════════
    INSERT INTO purchase_orders (code, supplier_id, order_date, currency, fx_rate,
                                 estimated_total_ccy, status, approval_status)
      VALUES ('ZZ-SOD1-PO1', v_sup_b, v_d2, v_ccy, 1, 100, 'draft', 'pending')
      RETURNING id INTO v_po;
    v_denied := false;
    BEGIN
        UPDATE finance_settings SET approvals_enabled = false;
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM; v_denied := (SQLERRM LIKE 'APPROVALS_CANNOT_DISABLE_WITH_PENDING|%');
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'C5 失败:有在途 pending 单时关开关会把它们搁死(msg=%)', COALESCE(v_msg,'(没有报错)');
    END IF;
    IF v_msg NOT LIKE '%ZZ-SOD1-PO1%' THEN
        RAISE EXCEPTION 'C5 失败:拒绝必须【点名】是哪几张单,实际 msg=%', v_msg;
    END IF;
    r := r || jsonb_build_object('C5_disable_with_pending_refused', v_msg);

    -- ═════════ C6 · 开着的时候不许把策略值抽走 ═════════
    v_denied := false;
    BEGIN
        UPDATE finance_settings SET approval_threshold_base = NULL;
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM; v_denied := (SQLERRM LIKE 'APPROVALS_POLICY_LOCKED_WHILE_ON|%');
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'C6 失败:开着的时候不该抽得走策略值(msg=%)', COALESCE(v_msg,'(没有报错)');
    END IF;
    r := r || jsonb_build_object('C6_policy_locked_while_on', v_msg);

    -- ═════════ C7 · 在途清空之后,关得掉 ═════════
    -- 【把在途那张单批掉 —— 用与 approve_purchase_order 同一个声明】
    -- guard_po_amendable 分不出"状态转换"与"修改",要调用方显式说一句;
    -- 直接 UPDATE 会撞 PO_STATUS_NOT_AMENDABLE(实测撞到了,记在这里)。
    -- 用完立刻清 —— 事务局部(APR-2c fu2)。
    PERFORM set_config('evoltrya.po_status_ctx', '1', true);
    UPDATE purchase_orders SET approval_status='approved' WHERE id = v_po;
    PERFORM set_config('evoltrya.po_status_ctx', '', true);
    UPDATE finance_settings SET approvals_enabled = false;
    IF (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'C7 失败:没有在途单据时应当关得掉';
    END IF;
    r := r || jsonb_build_object('C7_disable_when_drained', true);

    -- ═════════ C8 · readiness 与闸【读的是同一件事】 ═════════
    -- 一个屏幕上说"可以开"、闸却拒绝的系统,比两者都拒绝更坏。
    UPDATE finance_settings SET approval_level1_role_code=NULL,
        approval_threshold_base=NULL, approval_level2_user_id=NULL;
    IF (approvals_readiness()->>'can_enable')::boolean THEN
        RAISE EXCEPTION 'C8 失败:三个策略值都为 NULL 时 readiness 不该说可以开';
    END IF;
    IF jsonb_array_length(approvals_readiness()->'blocking') <> 3 THEN
        RAISE EXCEPTION 'C8 失败:blocking 应当点名三项,实际 %',
            approvals_readiness()->'blocking';
    END IF;
    r := r || jsonb_build_object('C8_readiness_agrees_with_the_gate', true);

    -- 【成功不抛异常】db/gate.py 用 ON_ERROR_STOP=1 跑本目录,任何异常 = 这一支失败。
    -- 报告用 NOTICE,回滚由文件末尾的 ROLLBACK 做。
    -- (`RAISE EXCEPTION 'FIXTURE_REPORT …'` 是【Management API 探针】的写法 ——
    --  那里要靠异常把报告从错误消息里带回来。两者不是同一个东西,这里用错过一次。)
    RAISE NOTICE 'FIXTURE 127 全部通过 %', r::text;
END $$;
ROLLBACK;
