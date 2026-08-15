-- 73 发票签发档(INV-2a):版本递增、摘要各不相同,而作废之后旧版本仍然在
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【这份 fixture 钉住的东西,以及为什么每一条都需要一个对照】
--
--   ① 【两版的 sha256 必须【不同】】只断言"版本号从 1 变成 2"是不够的:一个把
--      摘要写死、或者把上一版的摘要抄过来的实现,版本号照样递增。签发档的全部
--      意义是"当时发出去的那份字节",而摘要就是它的身份证。B 臂。
--   ② 【作废之后,旧版本仍然读得到】—— 而且这一条要断言【那些行还在】,
--      不是断言"没有报错"。作废不删任何东西,所以已经发出去过的那几版仍然是
--      真实发生过的事;被拒的只是【再发一版】。C 臂两句话分开验。
--   ③ 【客户端插不进去】签发档没有 INSERT 策略,唯一写入口是那个函数。
--      注入臂把策略补回来 —— 那条断言必须当场失效,否则它一直靠别的东西成立。
--   ④ 【两道门是合取,而线上今天分辨不出来】持 finance.edit 的三个角色同时都持
--      view_banking。所以 E 臂造两个【只有一半】的角色,让那个合取第一次变得
--      可观察:只读的 auditor 看得见版本却签发不了;什么都没有的角色连行都看不见。
--   ⑤ 【前提要自己设,哪怕默认值恰好合用】(README 第 5 条)公司抬头在【重建库】
--      里是空字符串(company_profile 的引导行就是 legal_name = ''),而它正是
--      INV_PROFILE_INCOMPLETE 的判据 —— 不显式设,后面每一条"应当签发成功"的
--      断言都会因为一个与被测规则无关的原因红掉。F 臂反过来利用它。
--
-- 【注入臂放在最后】fixture 64/69/71 付过这笔账:注入种下的行会污染后面各臂。
--   注入 1:摘掉只增不改守卫 → 改一版的摘要当场走通(A/B 两臂的断言因此有牙)。
--   注入 2:给 invoice_issues 补一条 INSERT 策略 → 客户端直插当场走通。
--
-- 自带数据(README 第 2 条)。期间锁显式设 NULL(第 5 条)。
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    v_user  uuid := gen_random_uuid();
    v_audit uuid := gen_random_uuid();   -- 只读:module.finance.view
    v_blind uuid := gen_random_uuid();   -- 连 finance.view 都没有
    r_all uuid; r_ro uuid; r_none uuid;
    v_cust uuid; v_mat uuid; v_base text;
    invA uuid; invEmpty uuid; soA uuid; lineA uuid;
    v_res jsonb; v_msg text; v_denied boolean; v_n int;
    sha1 constant text := repeat('a', 64);
    sha2 constant text := repeat('b', 64);
    d date := CURRENT_DATE;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-73', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);

    -- 【只读那个角色是这一臂的全部内容】线上持 finance.edit 的三个角色同时都持
    -- view_banking,于是"两道门"的合取没有可观察的后果。造一个只有 view 的角色,
    -- 那个合取才第一次真的被验到。
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-73-ro', 'f', 'f', true) RETURNING id INTO r_ro;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_ro, 'module.finance.view');
    INSERT INTO user_roles (user_id, role_id) VALUES (v_audit, r_ro);

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-73-none', 'f', 'f', true) RETURNING id INTO r_none;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_none, 'module.sales.view');
    INSERT INTO user_roles (user_id, role_id) VALUES (v_blind, r_none);

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);
    UPDATE finance_settings SET locked_before = NULL;
    SELECT code INTO v_base FROM currencies WHERE is_base;

    -- 【前提:公司抬头】重建库里它是空字符串,而那正是 INV_PROFILE_INCOMPLETE
    -- 的判据 —— 不设的话,下面每一条"应当签发成功"都会因为一个与被测规则无关的
    -- 原因红掉(README 第 5 条:前提要显式设定)。
    UPDATE company_profile SET legal_name = 'Fixture 73 Pte Ltd';

    INSERT INTO customers (code, legal_name, country)
    VALUES ('ZZ73-C1', 'fixture 73 customer', 'SG') RETURNING id INTO v_cust;
    INSERT INTO materials (code, name, category, unit)
    VALUES ('ZZFIX73-M', 'f73 material', '产出-金属', 'kg') RETURNING id INTO v_mat;

    -- 【主臂用 order 型,而这【不是】随手挑的载体】
    -- 第一版这里直接插了一张 sale 型发票加一行,当场撞上
    -- INVOICE_LINE_KIND_MISMATCH:发票行的来源与 kind 是绑死的(sale 行要
    -- sales_record_id,order 行要 sales_order_line_id,invoice_lines_one_source
    -- 恰一非空)。也就是说【一张带行的发票不可能凭空插出来】—— 它必须由那条
    -- 真实的链造出来。于是主臂走 create_order_invoice:订单 → 确认 → 开票。
    -- 这一改反而让"两种 kind 走同一个函数"验得更实:签发的是一张真的订单流发票。
    -- (D 臂那张【没有行】的 sale 型仍然直接插 —— 空表头本身是插得进去的,
    --  被 kind 绑住的只有行。)
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES (next_sales_order_code(d), v_cust, d, 'USD', 1.25) RETURNING id INTO soA;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (soA, 1, v_mat, 10, 10) RETURNING id INTO lineA;
    PERFORM set_sales_order_status(soA, 'confirmed');
    invA := (create_order_invoice(soA, d, NULL, NULL, NULL, ARRAY[lineA]) ->> 'invoice_id')::uuid;

    -- ══════════ A. 前提 + 目录 ═══════════════════════════════════════════════
    IF to_regprocedure('public.record_invoice_issue(uuid,text,text)') IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 73A 失败:record_invoice_issue 不在 —— 它是唯一写入口';
    END IF;
    -- 【它是那一族的第六份,形状要一样】UNIQUE(invoice_id, version) 是版本这件事
    -- 的硬保证;少了它,并发两次签发可以写出两个 v1。
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conrelid = 'public.invoice_issues'::regclass AND contype = 'u') THEN
        RAISE EXCEPTION 'FIXTURE 73A 失败:invoice_issues 少了 (invoice_id, version) 的唯一约束';
    END IF;

    -- ══════════ B. 签发两版:版本递增,而【摘要各不相同】═══════════════════════
    v_res := record_invoice_issue(invA, 'p/v1.pdf', sha1);
    IF (v_res->>'version') <> '1' OR (v_res->>'kind') <> 'order' THEN
        RAISE EXCEPTION 'FIXTURE 73B 失败:第一版应当是 v1 且带回 kind,实得 %', v_res::text;
    END IF;
    v_res := record_invoice_issue(invA, 'p/v2.pdf', sha2);
    IF (v_res->>'version') <> '2' THEN
        RAISE EXCEPTION 'FIXTURE 73B 失败:第二版应当是 v2,实得 %', v_res::text;
    END IF;

    -- 【两版的摘要必须不同 —— 这一句是整份 fixture 的心脏】
    -- 只看版本号的话,一个把上一版摘要抄过来的实现照样过。签发档的全部意义是
    -- "当时发出去的那份字节",而摘要就是它的身份证。
    SELECT count(DISTINCT sha256) INTO v_n FROM invoice_issues WHERE invoice_id = invA;
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 73B 失败:两版应当有两个【不同】的 sha256,实得 % 个不同值 —— 只递增版本号是不够的',
            v_n;
    END IF;
    -- 路径也要各自记着(取回哪一版靠的就是它)
    IF NOT EXISTS (SELECT 1 FROM invoice_issues WHERE invoice_id = invA AND version = 1 AND file_path = 'p/v1.pdf')
       OR NOT EXISTS (SELECT 1 FROM invoice_issues WHERE invoice_id = invA AND version = 2 AND file_path = 'p/v2.pdf') THEN
        RAISE EXCEPTION 'FIXTURE 73B 失败:两版的 file_path 应当各自记着';
    END IF;

    -- 只增不改(属主身份也不行 —— RLS 对表属主不生效,所以这一句问的正是触发器)
    v_denied := false; v_msg := NULL;
    BEGIN UPDATE invoice_issues SET sha256 = repeat('c', 64) WHERE invoice_id = invA AND version = 1;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied OR v_msg NOT LIKE 'INVOICE_ISSUE_IMMUTABLE|%' THEN
        RAISE EXCEPTION 'FIXTURE 73B 失败:改签发档应当按名拒,实得 denied=% msg=%',
            v_denied, COALESCE(v_msg, '(改成功了)');
    END IF;
    v_denied := false; v_msg := NULL;
    BEGIN DELETE FROM invoice_issues WHERE invoice_id = invA AND version = 1;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied OR v_msg NOT LIKE 'INVOICE_ISSUE_IMMUTABLE|%' THEN
        RAISE EXCEPTION 'FIXTURE 73B 失败:删签发档应当按名拒,实得 denied=% msg=%',
            v_denied, COALESCE(v_msg, '(删掉了)');
    END IF;

    -- ══════════ B2. 公司抬头空着 —— 【用一张【有行】的发票试,这一点是判据本身】
    -- 第一版把这一臂挂在那张【没有行】的发票上,于是它得到的是 INV_NO_LINES:
    -- 断言"被拒了"会通过,而它测的根本不是抬头那一条 —— 一个把抬头检查整个删掉的
    -- 实现照样绿。这就是空转的定义。所以这一臂用 invA(有行、还没作废),
    -- 让抬头成为【唯一】还没满足的前提。
    -- 【为什么这一条值得单独拦】渲染那条路也 409,但它报的是"金额取不到",
    -- 既可能是没有行、也可能是没有权限;而这里挡的是另一件事:把一份没有抬头的
    -- 东西【记进档案】——"某年某月发出去过第 3 版"而那一版没有公司名,
    -- 记录本身就成了一句假话。
    UPDATE company_profile SET legal_name = '   ';
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM record_invoice_issue(invA, 'p/v3.pdf', repeat('e', 64));
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied OR v_msg <> 'INV_PROFILE_INCOMPLETE' THEN
        RAISE EXCEPTION 'FIXTURE 73B2 失败:公司抬头空着时应当报 INV_PROFILE_INCOMPLETE,实得 % —— 一张没有公司名的发票寄出去是真实事故',
            COALESCE(v_msg, '(发出去了)');
    END IF;
    -- 【拒了就是什么都没记】档案不该因为一次被拒的签发多出一行
    IF (SELECT count(*) FROM invoice_issues WHERE invoice_id = invA) <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 73B2 失败:被拒的签发不该在档案里留下第三行';
    END IF;
    UPDATE company_profile SET legal_name = 'Fixture 73 Pte Ltd';

    -- ══════════ C. 作废之后:不再发新版,而【旧版本仍然在】═════════════════════
    -- 【order 型作废要冲销日】它有一张分录要冲(sale 型没有)—— 期间由它决定,
    -- 所以 void_invoice 对 order 型必填(REVERSAL_DATE_REQUIRED)。
    PERFORM void_invoice(invA, 'fixture 73:作废之后仍要看得见旧版本', d);
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM record_invoice_issue(invA, 'p/v3.pdf', repeat('d', 64));
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied OR v_msg NOT LIKE 'INV_VOIDED_NOT_ISSUABLE|%|void' THEN
        RAISE EXCEPTION 'FIXTURE 73C 失败:作废了的发票不该再发新版,实得 denied=% msg=%',
            v_denied, COALESCE(v_msg, '(发出去了)');
    END IF;
    -- 【断言那些行还在,不是断言"没报错"】作废不删任何东西,所以已经发出去过的
    -- 那两版仍然是真实发生过的事 —— 一个"作废顺手清档案"的实现在这里露馅。
    SELECT count(*) INTO v_n FROM invoice_issues WHERE invoice_id = invA;
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 73C 失败:作废之后那两版签发档应当【原样都在】,实得 % 行 —— 客户手里拿着的就是它们',
            v_n;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM invoice_issues WHERE invoice_id = invA AND version = 1 AND sha256 = sha1) THEN
        RAISE EXCEPTION 'FIXTURE 73C 失败:v1 的摘要应当一个字没变';
    END IF;
    -- 而发票行也一行不少(作废只是打标记)—— 这是"旧版本仍然渲染得出来"的前提
    IF (SELECT count(*) FROM invoice_lines WHERE invoice_id = invA) <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 73C 失败:作废不该删掉明细行';
    END IF;

    -- ══════════ D. 没有行的发票 —— 那是一张白纸,而客户要照着上面的数付款 ═══════
    INSERT INTO invoices (code, customer_id, issue_date, due_date, payment_terms_days,
                          currency, subtotal_base, total_base, bill_to_snapshot, kind)
    VALUES ('ZZ73-INV-EMPTY', v_cust, d, d + 30, 30, v_base, 0, 0,
            jsonb_build_object('code', 'ZZ73-C1'), 'sale')
    RETURNING id INTO invEmpty;
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM record_invoice_issue(invEmpty, 'p/x.pdf', repeat('e', 64));
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied OR v_msg NOT LIKE 'INV_NO_LINES|%' THEN
        RAISE EXCEPTION 'FIXTURE 73D 失败:没有行的发票不该签发(那是一张白纸),实得 %',
            COALESCE(v_msg, '(发出去了)');
    END IF;

    -- ══════════ E. 两道门:只读看得见,签发不了;无权者连行都看不见 ═════════════
    -- 【auditor 那一侧】读得到版本、时刻与摘要(审计要看的正是"发出去的是什么"),
    -- 但 record_invoice_issue 要 finance.edit,所以他签发不了。
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_audit), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM invoice_issues WHERE invoice_id = invA;
    RESET ROLE;
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 73E 失败:只有 finance.view 的读者应当看得见那两版(审计要看的正是它),实得 % 行', v_n;
    END IF;
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM record_invoice_issue(invEmpty, 'p/x.pdf', repeat('f', 64));
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied OR v_msg NOT LIKE 'PERMISSION_DENIED%' THEN
        RAISE EXCEPTION 'FIXTURE 73E 失败:只读的角色不该签发得了,实得 denied=% msg=%',
            v_denied, COALESCE(v_msg, '(签发成功了)');
    END IF;

    -- 【连 finance.view 都没有的人:看见的是【空】,而不是报错】
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_blind), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM invoice_issues WHERE invoice_id = invA;
    RESET ROLE;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 73E 失败:没有 finance.view 的读者应当一行都看不见,实得 % 行', v_n;
    END IF;

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    -- 【客户端插不进去】签发档没有 INSERT 策略 —— 留着侧门,任何持 finance.edit
    -- 的人都能插一行指着不存在对象的"签发记录",而档案正是不可伪造才有意义。
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_denied := false;
    BEGIN INSERT INTO invoice_issues (invoice_id, version, file_path, sha256)
          VALUES (invEmpty, 1, 'side/door.pdf', repeat('9', 64));
    EXCEPTION WHEN OTHERS THEN v_denied := true;
    END;
    RESET ROLE;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 73E 失败:直连插一行签发档应当被 RLS 拒(本表没有 INSERT 策略)';
    END IF;

    -- ══════════ 注入 1:摘掉只增不改守卫 ═════════════════════════════════════
    -- B 臂那两条断言必须能失败。摘掉触发器之后,改一版的摘要必须当场走通 ——
    -- 走不通就说明那两条一直靠别的东西成立。
    DROP TRIGGER trg_invoice_issues_append_only ON public.invoice_issues;
    v_denied := false; v_msg := NULL;
    BEGIN UPDATE invoice_issues SET sha256 = repeat('c', 64) WHERE invoice_id = invA AND version = 1;
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 73 注入1 失败:摘掉只增不改守卫之后,改摘要【仍然】被拒(%)—— 说明 B 臂那两条断言在空转',
            v_msg;
    END IF;

    -- ══════════ 注入 2:给签发档补一条 INSERT 策略 ═══════════════════════════
    -- E 臂最后那条断言测的是"没有 INSERT 策略"。补一条,直连插入必须当场走通。
    EXECUTE $inj$
        CREATE POLICY "fixture73 side door" ON public.invoice_issues
            AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (true);
    $inj$;
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_denied := false; v_msg := NULL;
    BEGIN INSERT INTO invoice_issues (invoice_id, version, file_path, sha256)
          VALUES (invEmpty, 1, 'side/door.pdf', repeat('9', 64));
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    RESET ROLE;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 73 注入2 失败:补上 INSERT 策略之后,直连插入【仍然】被拒(%)—— 说明 E 臂那条断言测的不是策略',
            v_msg;
    END IF;
END $$;
ROLLBACK;
