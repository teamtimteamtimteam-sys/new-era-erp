-- 185 物流有自己的门,而搬货的人开得了它
--
-- NAV-REG-1 · Tim 的裁定 R2。
--
-- 【在这之前】物流借 module.purchasing.view 把门(LOG-1c 明写"本刀不铸权限码")。
-- 借来的门有一个【实测的】受害者:live 的 role_permissions 里 operations /
-- warehouse / sales 三个角色都不持采购权限 —— 搬货的人看不见物流。
--
-- 【为什么只换 lib/modules.ts 那一行不够】把门的不是那一行,是这八张表的 RLS。
-- lib/modules.ts:134-135 早就把这个陷阱写下来了:换别的码只会得到一个
-- 【打得开、但零行】的页面。本 fixture 的 B 臂就是那个陷阱本身。
--
-- 【故障注入】
--   A 臂:只持 module.logistics.view 的读者 —— 八张表【每一张都读得到】。
--   B 臂:只持 module.purchasing.view 的读者(正是迁移前那把钥匙)——
--         八张表【每一张都零行】。这一臂证明码是真的搬了家,而不是两把钥匙都能开。
--   C 臂:一个既无物流也无采购的读者 —— 同样零行(否则 A 臂的"读得到"
--         可能只是"这张表对谁都开着")。
--   D 臂:【写的那一半没有跟着搬】—— 只持 logistics.view 的人【写不进】,
--         而写策略要的仍然是 module.purchasing.edit。读写两个答案可以不一样,
--         但必须是【故意】不一样(metal_prices 那一课)。
--   E 臂:看板四支声明的码跟着换了,而 po_awaiting_receipt【没有】跟着换 ——
--         只换表不换支,就是 EQP-2d 那个谎的重演(读得到行、屏幕写「受限」)。
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    v_log  uuid := gen_random_uuid();   -- 只持 module.logistics.view
    v_pur  uuid := gen_random_uuid();   -- 只持 module.purchasing.view(旧钥匙)
    v_none uuid := gen_random_uuid();   -- 两个都不持
    r_log uuid; r_pur uuid; r_none uuid; r_all uuid;
    v_admin uuid := gen_random_uuid();
    v_port uuid; v_port2 uuid; v_lane uuid; v_fwd uuid; v_cont uuid;
    n int; r jsonb := '{}'::jsonb; v_err text;
    v_tbl text;
    TABLES text[] := ARRAY['ports','lanes','forwarder_rate_quotes','forwarder_details',
                           'lane_document_requirements','containers','container_documents',
                           'container_milestones'];
BEGIN
    -- ── 建号与角色 ─────────────────────────────────────────────────────────
    INSERT INTO auth.users (id) VALUES (v_log), (v_pur), (v_none), (v_admin);
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fixture-185-all','f','f',true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fixture-185-log','f','f',true) RETURNING id INTO r_log;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_log, 'module.logistics.view');
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fixture-185-pur','f','f',true) RETURNING id INTO r_pur;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_pur, 'module.purchasing.view');
    -- 【有权限,只是不是这两个】—— 否则 C 臂的零行可能只是"他什么都没有"
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fixture-185-none','f','f',true) RETURNING id INTO r_none;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_none, 'module.hr.view');
    INSERT INTO user_roles (user_id, role_id)
    VALUES (v_log, r_log), (v_pur, r_pur), (v_none, r_none), (v_admin, r_all);

    -- ── 自带数据(空库里无处可借)────────────────────────────────────────
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_admin), true);
    -- lanes 有 origin <> destination 的 CHECK,所以要两个港口
    INSERT INTO ports (code, name, country) VALUES ('ZZFIX185A','fixture 185 origin','SG') RETURNING id INTO v_port;
    INSERT INTO ports (code, name, country) VALUES ('ZZFIX185B','fixture 185 destination','MY') RETURNING id INTO v_port2;
    INSERT INTO lanes (origin_port_id, destination_port_id) VALUES (v_port, v_port2) RETURNING id INTO v_lane;
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZFIX185-F','fixture 185 forwarder','SG','active','forwarder') RETURNING id INTO v_fwd;
    INSERT INTO forwarder_details (supplier_id) VALUES (v_fwd);
    INSERT INTO forwarder_rate_quotes (supplier_id, lane_id, amount_ccy, currency, valid_from, valid_to)
    VALUES (v_fwd, v_lane, 1000, 'USD', DATE '2027-03-01', DATE '2027-12-31');
    INSERT INTO lane_document_requirements (lane_id, document_type) VALUES (v_lane, 'bill_of_lading');
    -- containers.code 有格式 CHECK:^CTR-[0-9]{4}-[0-9]{4}$
    INSERT INTO containers (code, lane_id, forwarder_id, departure_date)
    VALUES ('CTR-2027-0185', v_lane, v_fwd, DATE '2027-03-02') RETURNING id INTO v_cont;
    INSERT INTO container_documents (container_id, document_type, status, from_lane)
    VALUES (v_cont, 'bill_of_lading', 'pending', true);
    INSERT INTO container_milestones (container_id, milestone, event_date)
    VALUES (v_cont, 'gated_in', DATE '2027-03-02');

    -- ── A 臂:只持物流码 → 八张表每一张都读得到 ───────────────────────────
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_log), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    FOREACH v_tbl IN ARRAY TABLES LOOP
        EXECUTE format('SELECT count(*) FROM public.%I', v_tbl) INTO n;
        IF n = 0 THEN
            RAISE EXCEPTION 'A 臂:只持 module.logistics.view 的读者在 % 上读到零行 —— 这正是"打得开、但零行"那个陷阱', v_tbl;
        END IF;
        r := r || jsonb_build_object('A_' || v_tbl, n);
    END LOOP;
    RESET ROLE;

    -- ── B 臂:旧钥匙(采购)→ 八张表每一张都零行 ─────────────────────────
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_pur), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    FOREACH v_tbl IN ARRAY TABLES LOOP
        EXECUTE format('SELECT count(*) FROM public.%I', v_tbl) INTO n;
        IF n <> 0 THEN
            RAISE EXCEPTION 'B 臂:只持 module.purchasing.view 的读者还能在 % 上读到 % 行 —— 码没有真的搬家,两把钥匙都开得了门', v_tbl, n;
        END IF;
    END LOOP;
    RESET ROLE;
    r := r || jsonb_build_object('B_purchasing_only_rows', 0);

    -- ── C 臂:两个都不持 → 同样零行 ───────────────────────────────────────
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_none), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    FOREACH v_tbl IN ARRAY TABLES LOOP
        EXECUTE format('SELECT count(*) FROM public.%I', v_tbl) INTO n;
        IF n <> 0 THEN
            RAISE EXCEPTION 'C 臂:一个既无物流也无采购的读者在 % 上读到 % 行 —— 那张表对谁都开着,A 臂就什么都没证明', v_tbl, n;
        END IF;
    END LOOP;
    RESET ROLE;
    r := r || jsonb_build_object('C_unrelated_role_rows', 0);

    -- ── D 臂:写的那一半没有跟着搬 ────────────────────────────────────────
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_log), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    BEGIN
        INSERT INTO ports (code, name, country) VALUES ('ZZFIX185X','should not save','SG');
        RESET ROLE;
        RAISE EXCEPTION 'D 臂:只持 module.logistics.view 的人【写进去了】—— 写策略应当仍然要 module.purchasing.edit';
    EXCEPTION WHEN insufficient_privilege THEN
        r := r || jsonb_build_object('D_write_refused', true);
    END;
    RESET ROLE;

    -- ── E 臂:看板四支换码,采购那一支不换 ────────────────────────────────
    DECLARE v_def text := pg_get_viewdef('public.operations_now'::regclass);
            v_arm text;
    BEGIN
        FOREACH v_arm IN ARRAY ARRAY['free_time_expiring','container_no_arrival',
                                     'container_eta_overdue','container_documents_late'] LOOP
            IF position(format('''%s''::text AS item_type,' || E'\n' ||
                               '            ''module.logistics.view''::text', v_arm) in v_def) = 0 THEN
                RAISE EXCEPTION 'E 臂:% 那一支没有声明 module.logistics.view', v_arm;
            END IF;
        END LOOP;
        IF position('''po_awaiting_receipt''::text AS item_type,' || E'\n' ||
                    '            ''module.purchasing.view''::text' in v_def) = 0 THEN
            RAISE EXCEPTION 'E 臂:po_awaiting_receipt 那一支【不该】换码 —— 它读的是 purchase_orders,那是真的采购';
        END IF;
    END;
    -- 放宽表:免柜期的物流那一半也跟着换了,财务那一半原样
    IF NOT (arm_permission_widen('free_time_expiring') @> ARRAY['module.logistics.view','module.finance.view']) THEN
        RAISE EXCEPTION 'E 臂:arm_permission_widen(free_time_expiring) 不是 [logistics, finance],实际 %',
            arm_permission_widen('free_time_expiring');
    END IF;
    r := r || jsonb_build_object('E_arms_swapped', true);

    -- ── 授予名单:9 个角色(引导种子里是 8 个 —— 种子里没有 cfo)───────────
    SELECT count(*) INTO n FROM role_permissions rp JOIN roles ro ON ro.id = rp.role_id
     WHERE rp.permission_code = 'module.logistics.view' AND ro.code NOT LIKE 'fixture-%';
    r := r || jsonb_build_object('seed_grants', n);

    -- 【报告用 NOTICE,不用 EXCEPTION】gate 用 psql -v ON_ERROR_STOP=1 跑本目录,
    -- 一次 RAISE EXCEPTION 就是一次失败 —— 哪怕它装的是一份成功的报告。
    -- (FIXTURE_REPORT 那个写法是给 Management API 单跑用的:那边要靠报错把报告带回来。)
    -- 回滚由文件末尾的 ROLLBACK 负责,不靠抛异常。
    RAISE NOTICE 'FIXTURE 185 全部通过 %', r::text;
END $$;
ROLLBACK;
