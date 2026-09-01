-- 183 看不到某个模块的读者,拿到的是一句【具名的受限】,不是一段空白
--
-- AUDIT-1 · Tim 的 R4/R5,以及 AUD-1(2026-08-17)那一课的直接延续。
--
-- AUD-1 修的是:一个只持 module.sales.view 的读者去读带判据的视图,拿到【零行】,
-- 而零行被读成「这个批次没有来源」—— 一个错的好消息。修法是把判据挪到外层。
--
-- 本刀面对的是同一件事的【模块粒度】版本:一条轨迹横跨 8 个模块,
-- 单一 OR 判据只有两种坏法,而两种都不能接受 ——
--   * 判据放宽 → 把财务行泄露给一个只持 inventory 的读者;
--   * 判据收紧 → 财务那一段【整段消失】,读起来是「这个批次没有分录」。
-- 所以:外层 OR 决定【进不进得来】,逐行 may_view 决定【是内容还是「受限」】。
-- 受限的行【仍然占着那一行】,但不带任何来自源表的值。
--
-- 【故障注入】C 臂把该读者的权限补齐,先证明"受限"随权限变化;
-- D 臂逐列断言受限行【一个源表的值都不带】—— 一个说「受限」却把值带出来的
-- 视图,比一个直接泄露的视图更坏:它看起来是安全的。
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    v_all uuid := gen_random_uuid();      -- 全权限读者
    v_inv uuid := gen_random_uuid();      -- 只持 module.inventory.view
    v_none uuid := gen_random_uuid();     -- 一个【别的】模块权限,与本轨迹无关
    r_all uuid; r_inv uuid; r_none uuid;
    v_mat uuid; v_sup uuid; v_ib uuid; v_je uuid;
    n_all int; n_inv int; n_vis int; n_res int; n_leak int; n_none int;
BEGIN
    INSERT INTO auth.users (id) VALUES (v_all), (v_inv), (v_none);
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-183-all','f','f',true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    -- 只持库存 —— 他【看得见流水】,【看不见分录】
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-183-inv','f','f',true) RETURNING id INTO r_inv;
    INSERT INTO role_permissions (role_id, permission_code)
    VALUES (r_inv, 'module.inventory.view');
    -- 【有权限,但都不是本轨迹的模块】—— 否则"被拒"可能只是"他什么都没有"
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-183-none','f','f',true) RETURNING id INTO r_none;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_none, 'module.hr.view');
    INSERT INTO user_roles (user_id, role_id)
    VALUES (v_all, r_all), (v_inv, r_inv), (v_none, r_none);

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_all), true);
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZFIX183-S','fixture 183 supplier','SG','active','goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZFIX183-M','fixture 183 material','battery_material',true,'black_mass','end_of_life')
    RETURNING id INTO v_mat;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty,
        arrival_date, unit_price, source_reason_code, source_reason_note)
    VALUES ('ZZFIX183-IB', v_mat, v_sup, 100, 100, DATE '2027-03-01', 10, 'other', 'fixture 183 自带数据') RETURNING id INTO v_ib;
    INSERT INTO inventory_movements (inbound_batch_id, movement_type, qty_delta, business_date, stock_status)
    VALUES (v_ib, 'receipt', 100, DATE '2027-03-01', 'available');
    INSERT INTO journal_entries (code, entry_date, memo, source_type, source_id, status)
    VALUES ('ZZFIX183-JE', DATE '2027-03-02', 'fixture 183', 'purchase', v_ib, 'posted')
    RETURNING id INTO v_je;

    -- ══════════ A. 全权限读者看得见全部 ═══════════════════════════════════
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_all), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO n_all FROM batch_audit_trail WHERE batch_id = v_ib;
    SELECT count(*) INTO n_vis FROM batch_audit_trail WHERE batch_id = v_ib AND may_view;
    RESET ROLE;
    IF n_all < 3 OR n_vis <> n_all THEN
        RAISE EXCEPTION 'FIXTURE 183A 失败:全权限读者应当看得见全部(实得 %/% 行可见)', n_vis, n_all;
    END IF;
    RAISE NOTICE '183A 全权限读者:%/% 行全部可见 ✓', n_vis, n_all;

    -- ══════════ B. ★ 只持 inventory 的读者:行数【一样】,分录变成「受限」★ ═
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_inv), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO n_inv FROM batch_audit_trail WHERE batch_id = v_ib;
    SELECT count(*) INTO n_vis FROM batch_audit_trail WHERE batch_id = v_ib AND may_view;
    SELECT count(*) INTO n_res FROM batch_audit_trail WHERE batch_id = v_ib AND NOT may_view;
    RESET ROLE;

    -- ★ 这一句是本 fixture 的全部理由:行数不许缩水 ★
    IF n_inv <> n_all THEN
        RAISE EXCEPTION 'FIXTURE 183B 失败:只持 inventory 的读者拿到 % 行,全权限读者拿到 % 行 —— 少掉的那些行会被读成「这个批次没发生过那些事」,而真相是「你不能看」。这正是 AUD-1 那个错的好消息', n_inv, n_all;
    END IF;
    IF n_res = 0 THEN
        RAISE EXCEPTION 'FIXTURE 183B 失败:只持 inventory 的读者【什么都没被挡】—— 分录本该是「受限」';
    END IF;
    IF n_vis = 0 THEN
        RAISE EXCEPTION 'FIXTURE 183B 失败:只持 inventory 的读者连流水都看不见 —— 判据收得太紧,整条轨迹对他等于零行';
    END IF;
    RAISE NOTICE '183B 只持 inventory:% 行【一行没少】,其中 % 行可见、% 行具名受限 ✓', n_inv, n_vis, n_res;

    -- ══════════ C. 受限的那一行【必须是分录】,并且点得出缺哪个权限 ═════════
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_inv), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO n_res FROM batch_audit_trail
     WHERE batch_id = v_ib AND event_kind='journal_entry'
       AND NOT may_view AND module_code = 'module.finance.view';
    RESET ROLE;
    IF n_res <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 183C 失败:分录那一行没有以「受限 · 需要 module.finance.view」的形态出现(实得 % 行)', n_res;
    END IF;
    RAISE NOTICE '183C 分录行以「受限 · 需要 module.finance.view」出现 —— 屏幕点得出缺哪个权限 ✓';

    -- ══════════ D. 【受限行不许带任何源表的值】════════════════════════════
    -- 一个说「受限」却把值带出来的视图,比直接泄露更坏:它看起来是安全的。
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_inv), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO n_leak FROM batch_audit_trail
     WHERE batch_id = v_ib AND NOT may_view
       AND (detail IS NOT NULL OR source_id IS NOT NULL OR source_code IS NOT NULL
            OR href IS NOT NULL OR actor_id IS NOT NULL);
    RESET ROLE;
    IF n_leak <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 183D 失败:% 行标着「受限」却仍然带着源表的值 —— 属主权限视图绕过了那张表的 RLS', n_leak;
    END IF;
    RAISE NOTICE '183D 受限行一个源表的值都不带 ✓';

    -- ══════════ E. 【故障注入】补上 finance 权限,受限必须【消失】═══════════
    -- 先证明"受限"随权限变化:一个恒真的受限与一段空白是同一种坏。
    INSERT INTO role_permissions (role_id, permission_code)
    VALUES (r_inv, 'module.finance.view');
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_inv), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO n_res FROM batch_audit_trail
     WHERE batch_id = v_ib AND event_kind='journal_entry' AND NOT may_view;
    SELECT count(*) INTO n_vis FROM batch_audit_trail
     WHERE batch_id = v_ib AND event_kind='journal_entry' AND may_view;
    RESET ROLE;
    IF n_res <> 0 OR n_vis <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 183E 注入失败:补上 module.finance.view 之后,分录仍然是受限(受限 % 行 / 可见 % 行)—— 那个受限是恒真的,B/C 两臂没有在测它们以为在测的东西', n_res, n_vis;
    END IF;
    RAISE NOTICE '183E 注入确实改变了结果(补权限 → 分录从受限变成内容)✓';

    -- ══════════ F. 一个模块都不沾的读者:admission 直接挡住,零行 ═══════════
    -- 【这一臂断言的是"零行"是【对的】那一种情形】—— 与 B 臂的"一行不少"
    -- 恰好互补:进不来的人拿零行,进得来的人一行不少。
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_none), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO n_none FROM batch_audit_trail WHERE batch_id = v_ib;
    RESET ROLE;
    IF n_none <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 183F 失败:一个相关模块都不持有的读者拿到了 % 行', n_none;
    END IF;
    RAISE NOTICE '183F 不沾任何相关模块的读者:admission 挡住,0 行 ✓';

    -- ══════════ G. 内层基视图【不授权给任何人】════════════════════════════
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_all), true);
    IF has_table_privilege('authenticated', 'public.batch_audit_trail_all', 'SELECT') THEN
        RAISE EXCEPTION 'FIXTURE 183G 失败:内层 batch_audit_trail_all 对 authenticated 开着 —— 判据可以被绕过去';
    END IF;
    RAISE NOTICE '183G 内层基视图不授权给任何人 ✓';

    RAISE NOTICE 'FIXTURE 183 全部通过';
END $$;
ROLLBACK;
