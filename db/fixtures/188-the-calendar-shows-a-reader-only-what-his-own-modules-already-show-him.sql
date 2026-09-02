-- 188 日历只给读者看他【本来就看得见】的那些;而金属行情【现在真的会拒】
--
-- TOOLS-1 ②/①b(2026-09-03)。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★【② 的全部权限模型就是"没有权限模型" —— 这一支就是那句话的证据】★★
-- 日历的每一条查询都以【读者自己的会话】发出,所以一件事出现在日历上,
-- 当且仅当他本来就能在它自己的模块里看见它。
-- **要证明的不是"界面上没画出来",是【负载里根本没有那一行】** —— 委托点名的。
-- 一件被 CSS 藏起来的东西仍然在 HTML 里,而一件 RLS 挡掉的东西根本没到过服务器之外。
--
-- 【为什么这一支必须换角色跑】fixture 默认以 postgres 身份执行,而那是【绕过 RLS】的。
-- 不换角色的话,每一臂都会看到全部行,断言恒真 —— 那正是 fixture 26 记过的
-- 「真空通过」。所以每一次读都夹在 SET LOCAL ROLE authenticated 与 RESET ROLE 之间。
-- ════════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    v_admin uuid := gen_random_uuid();   -- 全权限
    v_emp   uuid := gen_random_uuid();   -- employee:零模块权限(六位同事到岗时的那个形状)
    r_admin uuid; r_emp uuid;
    v_cust uuid; v_inv uuid;
    n_admin_inv int; n_emp_inv int;
    n_admin_hol int; n_emp_hol int;
    n_emp_task  int;
    n_emp_metal int;
    v_pricing_ok boolean; v_emp_pricing_ok boolean;
BEGIN
    INSERT INTO auth.users (id) VALUES (v_admin), (v_emp);
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-188-admin','f','f',true) RETURNING id INTO r_admin;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_admin, code FROM permissions;
    -- 【employee:一个模块权限都不给】—— 线上那个 employee 角色实测就是 0 条权限
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-188-emp','f','f',true) RETURNING id INTO r_emp;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_admin, r_admin), (v_emp, r_emp);

    -- 造一张【日历会去读的】发票(以全权限身份)
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_admin), true);
    INSERT INTO customers (code, legal_name, country, status)
    VALUES ('ZZFIX188-C','fixture 188 customer','SG','active') RETURNING id INTO v_cust;
    -- 【必填列一个都不省】invoices 上没有默认值的 NOT NULL 列实测有九个;
    -- 少一个就是一次 fixture 自己的失败,而不是一次被测行为的失败。
    INSERT INTO invoices (code, customer_id, issue_date, due_date, payment_terms_days,
                          currency, subtotal_base, total_base, bill_to_snapshot, status)
    VALUES ('ZZFIX188-INV', v_cust, DATE '2027-05-01', DATE '2027-05-31', 30,
            'SGD', 100, 100, jsonb_build_object('name','fixture 188'), 'issued')
    RETURNING id INTO v_inv;

    -- ══════════ A. 基线:全权限读者【看得见】那张发票 ═════════════════════
    -- 【先造一个会成功的基线】—— 否则 B 臂的"看不见"可能只是"这一行压根不存在"
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO n_admin_inv FROM invoices_masked
     WHERE due_date BETWEEN DATE '2027-05-01' AND DATE '2027-05-31' AND code = 'ZZFIX188-INV';
    SELECT count(*) INTO n_admin_hol FROM public_holidays WHERE is_active;
    RESET ROLE;
    IF n_admin_inv <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 188A 失败:全权限读者应当看得见那张发票(实得 % 行)—— 基线不成立,B 臂就什么都证明不了', n_admin_inv;
    END IF;

    -- ══════════ B. employee 读者:那一行【不在负载里】 ═══════════════════
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_emp), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO n_emp_inv FROM invoices_masked
     WHERE due_date BETWEEN DATE '2027-05-01' AND DATE '2027-05-31' AND code = 'ZZFIX188-INV';
    -- 公共假期【人人可读】(RLS 是 USING(true))—— 所以日历对他不是空的,
    -- 而是【只剩他看得见的那些】。这两件事必须同时成立,否则"看不见"
    -- 可能只是"这个会话什么都读不到"。
    SELECT count(*) INTO n_emp_hol FROM public_holidays WHERE is_active;
    SELECT count(*) INTO n_emp_task FROM tasks WHERE deleted_at IS NULL;
    RESET ROLE;

    IF n_emp_inv <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 188B 失败:employee 不该在日历负载里拿到那张发票(实得 % 行)', n_emp_inv;
    END IF;
    IF n_emp_hol <> n_admin_hol OR n_emp_hol = 0 THEN
        RAISE EXCEPTION 'FIXTURE 188B2 失败:公共假期应当人人可读且两边一样(admin % / employee %)—— '
            '若两边都是 0,那是这一臂真空通过,不是"权限对了"', n_admin_hol, n_emp_hol;
    END IF;

    -- ══════════ C. ①b:金属行情的判据【真的把那五个角色挡在外面】 ════════
    -- 页面守卫读的就是这个谓词(requireFunction → allows('module.pricing.view'))。
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_admin), true);
    SELECT has_permission('module.pricing.view') INTO v_pricing_ok;
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_emp), true);
    SELECT has_permission('module.pricing.view') INTO v_emp_pricing_ok;
    IF NOT v_pricing_ok THEN
        RAISE EXCEPTION 'FIXTURE 188C 失败:全权限读者应当持有 module.pricing.view —— 基线不成立';
    END IF;
    IF v_emp_pricing_ok THEN
        RAISE EXCEPTION 'FIXTURE 188C2 失败:employee 不该持有 module.pricing.view,而金属行情现在正靠它把门';
    END IF;

    -- ══════════ D. 而【数据那一层没有被收窄】—— 这一条防的是后人读错 ═════
    -- metal_prices 的 SELECT 仍然是 USING(true):employee 在【库里】仍然读得到行。
    -- ①b 收窄的是导航与路由守卫,不是数据。两者必须分得开,否则下一个人
    -- 会把"金属行情"当成受控数据,并据此做出别的决定。
    -- ★【自带数据 —— 这一臂第一版【借】了线上的行,而重建库里那张表是空的】★
    --   db/gate.py 在【本地重建】上跑 fixture,那里没有任何业务数据。
    --   于是 `IF NOT EXISTS (SELECT 1 FROM metal_prices)` 在重建库上必然成立,
    --   这一臂报的是"RLS 被收窄了",而真相是"这张表本来就没有行"。
    --   **gate 当场抓到了它(GATE_EXIT=4)**,而它正是 db/fixtures/README.md
    --   点名的那一课(fixture 88 借 supplier_receipt_pattern 的同一个形状):
    --   **判据:这条 SELECT 在一个什么业务数据都没有的库里,还返回得出东西吗?**
    --   处置:自己造一行,再以 employee 身份去读它。
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_admin), true);
    INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date, source)
    VALUES ('cu', 9000, DATE '2027-05-02', 'internal_estimate');

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_emp), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO n_emp_metal FROM metal_prices
     WHERE price_date = DATE '2027-05-02' AND metal = 'cu';
    RESET ROLE;
    IF n_emp_metal <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 188D 失败:employee 在库那一层【应当】仍然读得到金属行情(实得 % 行)—— '
            '读不到就说明有人把 metal_prices 的 RLS 也收窄了,而本刀明说没有动它', n_emp_metal;
    END IF;

    RAISE NOTICE 'fixture 188 ok:发票 admin 1 / employee 0 · 公共假期两边都是 % · pricing 谓词 admin true / employee false · metal_prices 的 RLS 未动',
        n_admin_hol;
END $$;
ROLLBACK;
