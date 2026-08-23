-- 122 期间锁到底锁住了什么
--
-- 【为什么这份 fixture 【不】给 31 个过账函数各写一臂】
-- 查线上目录得出:32 个写日记账的函数里,**只有 post_journal_entry 一个真的
-- INSERT journal_entries / journal_lines**,另外 31 个都调它。给它们各写一臂,
-- 是把同一行判据证明 31 遍 —— 而真正会出事的是【第 33 个】:某天有人写了一个
-- 新函数,自己 INSERT,不走正门。31 条臂对那件事一无所知。
--
-- 所以这份 fixture 证的是让那 31 个安全的那条【性质】,分三层:
--   (一) 闸本身:两道锁、两个方向、加上 year_close 那条唯一的例外;
--   (二) 【目录断言】post_journal_entry 仍然是唯一的写入者,**并且两个
--        触发器仍然在**。它会因为一个谁都没想到去枚举的新路径而变红,
--        而这正是 31 条臂做不到的;
--   (三) 三条真实的端到端路径(付款 / 费用 / CPF),把接线也证了,
--        而不只是证了闸。
-- 【R3:修好之后,断言的主语变了】—— 让那 31 个安全的,从今往后【不只是】
-- "只有一个写入者",还包括"两个触发器在岗"。少断言后者,某天有人 DROP 掉一个
-- 触发器,目录那一臂照样绿,而性质已经没了。所以 F5 明确断言触发器按名存在。
--
-- 【线上实测过的洞,本 fixture 就是它的看门人】GO-2 之前:
--     正门·月锁 → PERIOD_LOCKED   正门·年结 → YEAR_CLOSED
--     后门·月锁 → **过账成功**     后门·年结 → **过账成功**
-- 后门 = authenticated 持表级 INSERT 授权 + RLS 只问 module.finance.edit。
--
-- 【CPF 不是例外 —— 这一条是本刀纠正的一个错误说法】docs/forward-queue.md 曾说
-- "CPF 是一个已知的、刻意的例外"。实测:pay_payroll_cpf 走 post_journal_entry,
-- 两道闸照常拒它。刻意的是【当月 CPF 次月汇】(一张单据两个月份),不是免锁。
--
-- 【本 fixture 依赖 RLS,所以必须切角色】fixtures 以 postgres 跑,绕过 RLS
-- (README 第 4 条 / AGENTS.md)。后门那几臂如果不 SET LOCAL ROLE authenticated,
-- 证的就不是"一个真实用户能不能绕过去",而是"postgres 能不能" —— 后者永远为真,
-- 那一臂就变成空转。fixture 26 的 A/C 臂正是这样空转过。
--
-- 自带数据(README 第 2 条)。不继承 locked_before —— 自己设(README 第 4 条)。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid;
    c1 text; c2 text; a1 uuid; a2 uuid;
    L jsonb; je jsonb; e uuid;
    -- 【日期是算出来的,不是写死的】year_closes 【不可删改】(reject_year_close_mutation),
    -- 所以 fixture 没法"把它清空再自己设" —— README 第 4 条要的"不继承时间态"
    -- 在这里只能靠【把自己的日期放到既有年结之后】来达成。写死日期的版本
    -- 会在某天线上真的结了一个年度之后,为一个完全无关的理由变红。
    v_lock date; v_ye date; v_open date; v_shut date; v_maxyc date;
    v_denied boolean; v_msg text; v_n int; v_sum numeric; v_writers text[];
    v_before numeric; v_after numeric;
    v_exp text; v_b1 text; v_b2 text; v_je2 jsonb;
BEGIN
    SELECT COALESCE(MAX(year_end), DATE '2000-12-31') INTO v_maxyc
      FROM year_closes WHERE reopened_at IS NULL;
    v_ye   := GREATEST(DATE '2025-12-31', v_maxyc + 366);  -- 自己造的年结,保证晚于既有的每一个
    v_lock := v_ye + 152;                                   -- 月锁
    v_open := v_lock + 14;                                  -- 锁之后 = 开着
    v_shut := v_lock - 1;                                   -- 锁之前 = 关着(且【晚于】v_ye,故年闸不会插手)

    SELECT code INTO c1 FROM accounts WHERE is_active ORDER BY code LIMIT 1;
    SELECT code INTO c2 FROM accounts WHERE is_active AND code<>c1 ORDER BY code LIMIT 1;
    SELECT id INTO a1 FROM accounts WHERE code=c1;
    SELECT id INTO a2 FROM accounts WHERE code=c2;
    L := jsonb_build_array(
        jsonb_build_object('account_code',c1,'side','debit','amount_ccy',10,'currency',base_currency_code(),'fx_rate',1),
        jsonb_build_object('account_code',c2,'side','credit','amount_ccy',10,'currency',base_currency_code(),'fx_rate',1));

    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fixture-122','f','f',true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id,permission_code)
      SELECT r_all, unnest(ARRAY['module.finance.view','module.finance.edit']);
    INSERT INTO user_roles (user_id,role_id) VALUES (v_user,r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    -- ══════════ F1 · 前提:期间【开着】的时候,这些路径确实过得了账 ═════════
    -- 【前提臂不能省】一份只断言"被拒"的 fixture,在一个【什么都拒】的实现上
    -- 全绿 —— 那正是 D2 说的"为了对的理由失败"的另一半。
    UPDATE finance_settings SET locked_before = NULL;

    BEGIN
        je := post_journal_entry(v_open, 'fixture 122 前提', 'manual', NULL, L);
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'FIXTURE 122 F1 失败:期间【开着】时正门本应过得了账,实际被拒:% —— 一个"什么都拒"的实现要在这里当场红,而不是靠下面几臂全绿蒙混过去', SQLERRM;
    END;
    IF je->>'entry_id' IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 122 F1 失败:期间开着时正门应当过得了账';
    END IF;
    -- 断言【过账本身】,不是"调用返回了"
    SELECT count(*), COALESCE(SUM(debit),0) INTO v_n, v_sum
      FROM journal_lines WHERE entry_id = (je->>'entry_id')::uuid;
    IF v_n <> 2 OR v_sum <> 10 THEN
        RAISE EXCEPTION 'FIXTURE 122 F1 失败:应当落下 2 条明细、借方合计 10,实得 % 条 / %', v_n, v_sum;
    END IF;

    -- 后门在开着的期间同样应当过 —— 否则下面"后门被拒"证明不了是【锁】拒的
    EXECUTE 'SET LOCAL ROLE authenticated';
    INSERT INTO journal_entries (code,entry_date,memo,source_type)
    VALUES ('ZZFIX122-OPEN', v_open, 'fixture 122 后门·开着', 'manual') RETURNING id INTO e;
    INSERT INTO journal_lines (entry_id,account_id,debit,credit,currency,fx_rate,amount_ccy)
    VALUES (e,a1,10,0,base_currency_code(),1,10),(e,a2,0,10,base_currency_code(),1,10);
    RESET ROLE;
    SET CONSTRAINTS ALL IMMEDIATE; SET CONSTRAINTS ALL DEFERRED;
    IF (SELECT count(*) FROM journal_lines WHERE entry_id=e) <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 122 F1 失败:期间开着时直连写入本应成功(否则 F2 证不出是锁在拒)';
    END IF;

    -- ══════════ F2 · 月锁:正门与后门【都】必须按码拒绝 ══════════════════════
    UPDATE finance_settings SET locked_before = v_lock;

    -- F2a 正门
    v_denied := false;
    BEGIN
        PERFORM post_journal_entry(v_shut, 'fixture 122 正门·月锁', 'manual', NULL, L);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 122 F2a 失败:月锁之前的日期,正门应当拒绝';
    END IF;
    IF split_part(v_msg,'|',1) <> 'PERIOD_LOCKED' THEN
        RAISE EXCEPTION 'FIXTURE 122 F2a 失败:必须【按码】拒绝 PERIOD_LOCKED,实得 % —— 因为参数写错而报的错也会让一条马虎的断言通过', v_msg;
    END IF;

    -- F2b 后门:直连 INSERT 分录(GO-2 之前这里是通的)
    v_denied := false;
    EXECUTE 'SET LOCAL ROLE authenticated';
    BEGIN
        INSERT INTO journal_entries (code,entry_date,memo,source_type)
        VALUES ('ZZFIX122-BACK', v_shut, 'fixture 122 后门·月锁', 'manual');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    RESET ROLE;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 122 F2b 失败:**直连 INSERT 绕过了期间锁** —— GO-2 之前线上就是这样,authenticated 持表级 INSERT 授权,RLS 只问 module.finance.edit';
    END IF;
    IF split_part(v_msg,'|',1) <> 'PERIOD_LOCKED' THEN
        RAISE EXCEPTION 'FIXTURE 122 F2b 失败:后门也必须按码拒 PERIOD_LOCKED,实得 %', v_msg;
    END IF;

    -- F2c 后门:往一张【开着的期间里已存在的】分录追加明细,但父分录在锁定期
    --      —— 先造一张锁定期内的分录(借 postgres 之手绕过闸),再以真实用户追加
    UPDATE finance_settings SET locked_before = NULL;
    INSERT INTO journal_entries (code,entry_date,memo,source_type)
    VALUES ('ZZFIX122-OLD', v_shut, 'fixture 122 锁定期内的旧分录', 'manual') RETURNING id INTO e;
    INSERT INTO journal_lines (entry_id,account_id,debit,credit,currency,fx_rate,amount_ccy)
    VALUES (e,a1,100,0,base_currency_code(),1,100),(e,a2,0,100,base_currency_code(),1,100);
    SET CONSTRAINTS ALL IMMEDIATE; SET CONSTRAINTS ALL DEFERRED;
    SELECT COALESCE(SUM(debit),0) INTO v_before FROM journal_lines WHERE entry_id=e;
    UPDATE finance_settings SET locked_before = v_lock;

    v_denied := false;
    EXECUTE 'SET LOCAL ROLE authenticated';
    BEGIN
        INSERT INTO journal_lines (entry_id,account_id,debit,credit,currency,fx_rate,amount_ccy)
        VALUES (e,a1,777,0,base_currency_code(),1,777),(e,a2,0,777,base_currency_code(),1,777);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    RESET ROLE;
    SELECT COALESCE(SUM(debit),0) INTO v_after FROM journal_lines WHERE entry_id=e;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 122 F2c 失败:**往锁定期内的已过账凭证追加明细成功了** —— 借方合计 % → %,一张已过账单据的金额被改了', v_before, v_after;
    END IF;
    IF split_part(v_msg,'|',1) <> 'PERIOD_LOCKED' THEN
        RAISE EXCEPTION 'FIXTURE 122 F2c 失败:必须按码拒 PERIOD_LOCKED,实得 %', v_msg;
    END IF;
    IF v_after <> v_before THEN
        RAISE EXCEPTION 'FIXTURE 122 F2c 失败:拒绝之后金额不该变,% → %', v_before, v_after;
    END IF;

    -- ══════════ F3 · 年结闸:与月锁【各自独立】的第二道 ═══════════════════════
    -- 【为什么单独一臂】FIN-23 记着:年闸不跟着月锁退。一个只认月锁的实现能
    -- 通过 F2 的每一条,而每年年结之后开一次口子 —— 一年只开一次的洞最难发现。
    UPDATE finance_settings SET locked_before = NULL;   -- 月锁【完全撤掉】
    je := post_journal_entry(v_open, 'fixture 122 年结壳', 'manual', NULL, L);
    INSERT INTO year_closes (year_end, closing_journal_id, net_result, closed_by)
    VALUES (v_ye, (je->>'entry_id')::uuid, 0, v_user);

    -- F3a 正门:月锁没了,年闸仍须拒
    v_denied := false;
    BEGIN
        PERFORM post_journal_entry(v_ye - 30, 'fixture 122 正门·年结', 'manual', NULL, L);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR split_part(v_msg,'|',1) <> 'YEAR_CLOSED' THEN
        RAISE EXCEPTION 'FIXTURE 122 F3a 失败:月锁已撤,落进已结年度的日期仍须按码拒 YEAR_CLOSED,实得 %', COALESCE(v_msg,'(没有拒绝)');
    END IF;

    -- F3b 后门:同样
    v_denied := false;
    EXECUTE 'SET LOCAL ROLE authenticated';
    BEGIN
        INSERT INTO journal_entries (code,entry_date,memo,source_type)
        VALUES ('ZZFIX122-YR', v_ye - 30, 'fixture 122 后门·年结', 'manual');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    RESET ROLE;
    IF NOT v_denied OR split_part(v_msg,'|',1) <> 'YEAR_CLOSED' THEN
        RAISE EXCEPTION 'FIXTURE 122 F3b 失败:**直连 INSERT 绕过了年结闸**,实得 %', COALESCE(v_msg,'(没有拒绝)');
    END IF;

    -- F3c 那条【唯一的】例外:year_close + close_ctx 必须仍然过得去,
    --     否则本刀就把年结自己锁在门外了(而那会在下一次年结时才发现)。
    PERFORM set_config('evoltrya.close_ctx', 'year_close', true);
    BEGIN
        je := post_journal_entry(v_ye - 30, 'fixture 122 年结例外', 'year_close', NULL, L);
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'FIXTURE 122 F3c 失败:year_close + close_ctx 是【唯一的例外】,它必须仍然过得去 —— 实际被拒:%。把这条例外收掉,年结自己就被锁在门外了,而那要等到下一次年结才会发现', SQLERRM;
    END;
    IF je->>'entry_id' IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 122 F3c 失败:year_close + close_ctx 是【唯一的例外】,它必须仍然过得去';
    END IF;
    -- 例外【只对 year_close 开】:同样带着 ctx,但 source_type 是别的,仍须拒
    v_denied := false;
    BEGIN
        PERFORM post_journal_entry(v_ye - 30, 'fixture 122 冒充年结', 'manual', NULL, L);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR split_part(v_msg,'|',1) <> 'YEAR_CLOSED' THEN
        RAISE EXCEPTION 'FIXTURE 122 F3c 失败:close_ctx 在场也【只】放行 source_type=year_close,实得 %', COALESCE(v_msg,'(没有拒绝)');
    END IF;
    PERFORM set_config('evoltrya.close_ctx', '', true);
    -- 【不删 year_closes】它不可删改;F4/F6 的日期都晚于 v_ye,年闸本就不会插手。

    -- ══════════ F4 · CPF 不是例外 ════════════════════════════════════════════
    -- docs/forward-queue.md 曾把 CPF 写成"已知的、刻意的例外"。它不是。
    -- 这一臂钉住这件事:【将来谁想给 CPF 开口子,先会踩红这里】。
    UPDATE finance_settings SET locked_before = v_lock;
    v_denied := false;
    BEGIN
        PERFORM pay_payroll_cpf(gen_random_uuid(), v_shut, 'fixture 122 CPF');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    -- 期间没找到会先报 PAYROLL_NOT_FOUND —— 那【不算】证明了锁。
    -- 所以这一臂只断言一件它能诚实断言的事:CPF 这条路上【没有任何免锁的分支】。
    IF split_part(v_msg,'|',1) = 'PAYROLL_NOT_FOUND' THEN
        -- 用真正的路径再问一次:直接问闸,参数就是 CPF 会用的那一对
        v_denied := false;
        BEGIN
            PERFORM assert_posting_allowed(v_shut, 'payroll');
        EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
        END;
        IF NOT v_denied OR split_part(v_msg,'|',1) <> 'PERIOD_LOCKED' THEN
            RAISE EXCEPTION 'FIXTURE 122 F4 失败:CPF 用的 source_type=payroll 必须照常撞上期间锁 —— 它【不是】例外,实得 %', COALESCE(v_msg,'(没有拒绝)');
        END IF;
    END IF;
    -- 唯一的例外只有一条,正面钉死:除了 year_close,没有第二个 source_type 免锁
    FOR v_msg IN SELECT unnest(ARRAY['manual','payroll','payment','expense','sale','purchase','fx','year_close']) LOOP
        v_denied := false;
        BEGIN
            PERFORM assert_posting_allowed(v_shut, v_msg);
        EXCEPTION WHEN OTHERS THEN v_denied := true;
        END;
        IF NOT v_denied THEN
            RAISE EXCEPTION 'FIXTURE 122 F4 失败:source_type=% 在锁定期里没有被拒 —— 例外要【两个条件同时成立】(source_type=year_close 且 close_ctx 在场),单有其中一个都不该放行', v_msg;
        END IF;
    END LOOP;

    -- ══════════ F6 · 三条【真实】路径的端到端:证接线,不只证闸 ═══════════════
    -- 闸对了、接线断了,同样是洞。这几臂走真的业务函数,而不是直接叫 post_journal_entry。
    -- 【前提先行】每一条都先在开着的期间跑通,再在锁上之后断言按码拒绝 ——
    -- 一个"什么都拒"的实现会在前提这一半上当场红。
    UPDATE finance_settings SET locked_before = NULL;
    SELECT code INTO v_exp FROM accounts WHERE account_type='expense' AND is_active ORDER BY code LIMIT 1;
    SELECT code INTO v_b1 FROM accounts WHERE is_cash AND is_active ORDER BY code LIMIT 1;
    SELECT code INTO v_b2 FROM accounts WHERE is_cash AND is_active AND code<>v_b1 ORDER BY code LIMIT 1;

    -- F6a 费用:开着 → 落账
    BEGIN
        v_je2 := record_expense(v_open, v_exp, 25, base_currency_code(),
                                NULL, 'paid', v_b1, NULL, 'fixture 122 收款方');
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'FIXTURE 122 F6a 前提失败:期间开着时 record_expense 本应过得了账,实际被拒:%', SQLERRM;
    END;
    IF v_je2 IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 122 F6a 前提失败:期间开着时 record_expense 应当过得了账';
    END IF;
    -- 锁上 → 按码拒
    UPDATE finance_settings SET locked_before = v_lock;
    v_denied := false;
    BEGIN
        PERFORM record_expense(v_shut, v_exp, 25, base_currency_code(),
                               NULL, 'paid', v_b1, NULL, 'fixture 122 收款方');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR split_part(v_msg,'|',1) <> 'PERIOD_LOCKED' THEN
        RAISE EXCEPTION 'FIXTURE 122 F6a 失败:record_expense 在锁定期必须按码拒 PERIOD_LOCKED,实得 %', COALESCE(v_msg,'(没有拒绝)');
    END IF;

    -- F6b 银行转账:同样两个方向
    UPDATE finance_settings SET locked_before = NULL;
    IF v_b2 IS NOT NULL THEN
        BEGIN
            PERFORM record_bank_transfer(v_open, v_b1, v_b2, 5, 5, 'fixture 122', NULL);
        EXCEPTION WHEN OTHERS THEN
            RAISE EXCEPTION 'FIXTURE 122 F6b 前提失败:期间开着时 record_bank_transfer 本应过得了账,实际被拒:%', SQLERRM;
        END;
        UPDATE finance_settings SET locked_before = v_lock;
        v_denied := false;
        BEGIN
            PERFORM record_bank_transfer(v_shut, v_b1, v_b2, 5, 5, 'fixture 122', NULL);
        EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
        END;
        IF NOT v_denied OR split_part(v_msg,'|',1) <> 'PERIOD_LOCKED' THEN
            RAISE EXCEPTION 'FIXTURE 122 F6b 失败:record_bank_transfer 在锁定期必须按码拒 PERIOD_LOCKED,实得 %', COALESCE(v_msg,'(没有拒绝)');
        END IF;
    END IF;

    -- ══════════ F5 · 目录断言:写入者仍是唯一的,触发器仍在岗 ═══════════════
    -- 【R1:点名】"有函数直接写 journal_lines"会让人去大海捞针;
    -- "X 直接写 journal_lines"直接把人送到那个文件。
    SELECT COALESCE(array_agg(p.oid::regprocedure::text ORDER BY p.oid::regprocedure::text), '{}')
      INTO v_writers
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.prosrc ~* 'INSERT\s+INTO\s+journal_(entries|lines)'
       AND p.proname <> 'post_journal_entry';
    IF array_length(v_writers,1) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 122 F5 失败:除 post_journal_entry 外还有函数【直接】写日记账 —— %。期间锁与年结闸靠"只有一个写入者"这条性质成立;多一个写入者就多一条不受闸管的路。要么让它改走 post_journal_entry,要么在这里连同理由记一笔。', array_to_string(v_writers, ', ');
    END IF;

    -- 【R3:修好之后,主语变了】两个触发器也是让那 31 条路安全的一部分。
    -- 少了这一句,某天有人 DROP 掉一个触发器,上面那一臂照样绿,而性质已经没了。
    FOR v_msg IN SELECT unnest(ARRAY['trg_journal_entries_period','trg_journal_lines_period']) LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
                        WHERE t.tgname = v_msg AND NOT t.tgisinternal AND t.tgenabled <> 'D') THEN
            RAISE EXCEPTION 'FIXTURE 122 F5 失败:触发器 % 不在(或被禁用)—— 正门仍然会拒,而【后门又开了】,这正是 GO-2 之前的状态', v_msg;
        END IF;
    END LOOP;
END $$;
ROLLBACK;
