-- 201 固定资产台账终于记得住【谁、什么时候、把什么改成了什么】—— 每一条写入路径
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【它钉住的那几句话】
--   ① `fixed_assets` 的**每一条**写入路径都落下【恰好一行】留痕 —— 不是只有
--      B3 那支设计划的函数。★ 委托书与三份文档上的那份「五支写函数」名单是
--      **错的**(线上目录扫描 2026-09-20):`depreciate_fixed_assets` 根本不写
--      这张表,而动【钱】的 `record_expense` / `reverse_expense` 从来不在名单上。
--      真集是 **7 支函数 / 8 条写语句**,本文件逐条走过。
--   ② 留痕记得住【谁】:`auth.uid()`,而它在 SECURITY DEFINER 里照样是调用者
--      (它读会话 GUC,不读角色)。没有登录会话的那一种**有名字**('no_session'),
--      不是一个沉默的 NULL。
--   ③ ★ 那支捕获触发器**不提 fixed_assets 的任何列名** —— 这不是风格,是
--      `db/fixtures/120` F5(d)① 的硬约束(触发器函数的 prokind 也是 'f',照样被扫)。
--      **P2 臂守着这一条**,于是 120 一个字节都不用改。
--   ④ ★ `jsonb_populate_record` 会【静默丢掉】没有对应列的键 —— **P1 臂**
--      (Tim 点名要的那一条)要求 fixed_assets 的每一列都有 old_/new_ 两列,
--      明天谁加第 24 列而忘了这里,**当场红,不是悄悄丢**。
--   ⑤ 只增不改:UPDATE / DELETE 都按名拒;基表的硬删也按名拒。
--   ⑥ 没有 module.finance.edit 的人写不动(**且角色切换是被证明的,不是假设的**);
--      没有 module.finance.view 的人读不到(**两半都钉:有权限的看得见 N 行**)。
--
-- 【这份 fixture 自带全部数据】重建库里没有业务数据。不借别处、不吃别的臂的状态。
-- ════════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    u_all   uuid := gen_random_uuid();   -- 全权限 —— 正面各臂
    u_view  uuid := gen_random_uuid();   -- ★ 只有 module.finance.view,没有 edit
    u_none  uuid := gen_random_uuid();   -- ★ 连 view 都没有
    r_all uuid; r_view uuid; r_none uuid;
    v_ccy text; v_sup uuid;
    v_asset uuid; v_asset2 uuid; v_asset3 uuid;
    v_res jsonb; v_exp uuid;
    v_n int; v_n2 int; v_rows bigint;
    v_src text; v_col text; v_missing text;
    v_h record;
    v_raised boolean; v_msg text;
    v_seen_view int; v_seen_none int;
    v_d1 date := CURRENT_DATE - 10;
    v_d2 date := CURRENT_DATE + 200;
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    UPDATE finance_settings SET locked_before = NULL;   -- 期间锁是运行时状态(README 5)

    INSERT INTO auth.users (id) VALUES (u_all), (u_view), (u_none);

    INSERT INTO roles (code, name_en, name_zh, is_active)
        VALUES ('fixture-201-all','f201','f201',true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;

    -- ★ u_view 仍然持 module.finance.view —— 于是 M 臂被拒的理由【只能是】
    --   没有编辑权,不能是"连这张卡都读不到"。一臂一件事(fixture 200 同一条)。
    INSERT INTO roles (code, name_en, name_zh, is_active)
        VALUES ('fixture-201-view','f201','f201',true) RETURNING id INTO r_view;
    INSERT INTO role_permissions (role_id, permission_code)
        VALUES (r_view,'module.finance.view');

    -- u_none:一个【有角色但没有财务权限】的人。不是"没有角色" ——
    -- 没有角色的人会因为别的理由读到零行,那样 N 臂会因为错的理由变绿。
    INSERT INTO roles (code, name_en, name_zh, is_active)
        VALUES ('fixture-201-none','f201','f201',true) RETURNING id INTO r_none;
    INSERT INTO role_permissions (role_id, permission_code)
        VALUES (r_none,'module.purchasing.view');

    INSERT INTO user_roles (user_id, role_id)
        VALUES (u_all,r_all), (u_view,r_view), (u_none,r_none);

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZFIX201-S','fixture 201 supplier','SG','active','goods_supplier')
    RETURNING id INTO v_sup;

    -- ══════════ 前提 · 三支触发器都在,否则以下每一臂都是空转 ════════════════
    IF NOT EXISTS (SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid
                    WHERE t.tgrelid = 'public.fixed_assets'::regclass AND NOT t.tgisinternal
                      AND p.proname = 'trg_fixed_assets_history'
                      AND (t.tgtype & 2) = 0                      -- AFTER
                      AND (t.tgtype & 4) > 0 AND (t.tgtype & 16) > 0) THEN   -- INSERT + UPDATE
        RAISE EXCEPTION 'FIXTURE 201 前提不成立:fixed_assets 上没有 AFTER INSERT OR UPDATE 的 trg_fixed_assets_history '
                        '—— 没有它,下面每一臂都会数到 0 行留痕,而 0 行看起来很像"这条路径不写历史"';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid
                    WHERE t.tgrelid = 'public.fixed_asset_history'::regclass AND NOT t.tgisinternal
                      AND p.proname = 'guard_fixed_asset_history_append_only') THEN
        RAISE EXCEPTION 'FIXTURE 201 前提不成立:fixed_asset_history 上没有只增不改的守卫';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid
                    WHERE t.tgrelid = 'public.fixed_assets'::regclass AND NOT t.tgisinternal
                      AND p.proname = 'guard_fixed_assets_no_hard_delete') THEN
        RAISE EXCEPTION 'FIXTURE 201 前提不成立:fixed_assets 上没有 guard_fixed_assets_no_hard_delete';
    END IF;

    -- ══════════ P1 · ★★ 成对齐全 —— Tim 点名要的那一条 ═══════════════════════
    -- 【它拦的是一次【静默的丢失】】jsonb_populate_record 对没有对应列的键
    -- **不报错,直接丢**。于是谁给 fixed_assets 加了第 24 列而没在影子表配上
    -- old_/new_ 两列,那一列的改动会从此【不留痕,也不出声】——
    -- 而一份沉默的留痕读起来正好等于"这一列没人改过"。
    v_missing := NULL;
    SELECT string_agg(a.attname, ', ' ORDER BY a.attnum) INTO v_missing
      FROM pg_attribute a
     WHERE a.attrelid = 'public.fixed_assets'::regclass AND a.attnum > 0 AND NOT a.attisdropped
       AND NOT (EXISTS (SELECT 1 FROM pg_attribute h
                         WHERE h.attrelid = 'public.fixed_asset_history'::regclass
                           AND h.attnum > 0 AND NOT h.attisdropped
                           AND h.attname = 'old_' || a.attname)
            AND EXISTS (SELECT 1 FROM pg_attribute h
                         WHERE h.attrelid = 'public.fixed_asset_history'::regclass
                           AND h.attnum > 0 AND NOT h.attisdropped
                           AND h.attname = 'new_' || a.attname));
    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 201P1 失败:fixed_assets 的这些列在 fixed_asset_history 里【没有成对的 old_/new_ 列】:%。'
                        '★ 捕获触发器用 jsonb_populate_record 落地,而它对没有对应列的键【不报错,直接丢】—— '
                        '于是这些列从此改了也不留痕,而且不出声。一份沉默的留痕读起来正好等于"这一列没人改过"', v_missing;
    END IF;

    -- ══════════ P2 · ★★ 捕获触发器【不提任何一个列名】═══════════════════════
    -- 【为什么这一臂必须在这里,而不是在 fixtures/120 里】
    --   120 F5(d)① 扫的是一个【具体的名字】(planned_in_service_date),而它守的
    --   承诺是"没有一条规则读那个计划日去决定任何事"。本刀让触发器根本不提它,
    --   于是 120 一个字节都没改 —— 但那份克制要有人守着,否则下一个人顺手把
    --   `IF NEW.status = 'disposed' THEN ...` 写进去,120 不会红(它只认一个名字),
    --   而这支触发器会一步一步长回那个被禁止的形状。
    --   ☞ 所以这一臂比 120 严:**22 个列名一个都不许出现**。
    --   【id 是唯一的例外,而它有理由】它是外键的落点(NEW.id),而且它是这张表上
    --   唯一一个任何写入都改不动的列 —— 读它决定不了任何事。
    SELECT regexp_replace(pg_get_functiondef(p.oid), '--[^\n]*', '', 'g') INTO v_src
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = 'trg_fixed_assets_history';
    IF v_src IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 201P2 失败:找不到 trg_fixed_assets_history 的函数体';
    END IF;
    FOR v_col IN
        SELECT a.attname FROM pg_attribute a
         WHERE a.attrelid = 'public.fixed_assets'::regclass AND a.attnum > 0
           AND NOT a.attisdropped AND a.attname <> 'id'
    LOOP
        IF position(v_col IN v_src) > 0 THEN
            RAISE EXCEPTION 'FIXTURE 201P2 失败:捕获触发器的函数体里出现了列名「%」。'
                            '★ 它【不许提任何一个列名】—— 那是 db/fixtures/120 F5(d)① 能保持原样不改的全部原因:'
                            '触发器函数的 prokind 也是 ''f'',一旦函数体里写出 planned_in_service_date,120 当场红。'
                            '要记什么值,走 to_jsonb 的差集,让键名在运行时拼出来', v_col;
        END IF;
    END LOOP;

    -- ── 以下各臂都以 u_all 的身份发生 ────────────────────────────────────────
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u_all), true);

    -- ══════════ A · create_fixed_asset ⇒ 恰好一行 'created' ═════════════════
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_asset := (create_fixed_asset('fixture 201 machine', 60, CURRENT_DATE - 300,
                                   'equipment', NULL, 'f201')->>'asset_id')::uuid;
    RESET ROLE;

    SELECT count(*) INTO v_n FROM fixed_asset_history WHERE fixed_asset_id = v_asset;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 201A 失败:建一张卡应当落下【恰好一行】留痕,实得 % 行', v_n;
    END IF;
    SELECT * INTO v_h FROM fixed_asset_history WHERE fixed_asset_id = v_asset;
    IF v_h.change_type <> 'created' THEN
        RAISE EXCEPTION 'FIXTURE 201A 失败:建卡那一行的 change_type 应当是 created,实得 %', v_h.change_type;
    END IF;
    IF v_h.changed_by IS DISTINCT FROM u_all THEN
        RAISE EXCEPTION 'FIXTURE 201A 失败:记下来的人是 %,应当是调用者 %。'
                        '★ 若它是 NULL,多半是有人把 auth.uid() 换成了 current_user 那一族 —— '
                        'auth.uid() 读的是会话 GUC,SECURITY DEFINER 换角色动不了它,这一臂钉的就是这句', v_h.changed_by, u_all;
    END IF;
    IF v_h.changed_by_kind <> 'user' THEN
        RAISE EXCEPTION 'FIXTURE 201A 失败:有登录会话时 changed_by_kind 应当是 user,实得 %', v_h.changed_by_kind;
    END IF;
    -- ★ 出生快照:new_* 侧【填满了】。这半件事证明 jsonb_populate_record 真的落了地,
    --   而不是写下一行只有元数据的空壳。
    IF v_h.new_code IS NULL OR v_h.new_description <> 'fixture 201 machine'
       OR v_h.new_useful_life_months <> 60 THEN
        RAISE EXCEPTION 'FIXTURE 201A 失败:created 那一行的出生快照没填满(code=% description=% life=%)',
                        v_h.new_code, v_h.new_description, v_h.new_useful_life_months;
    END IF;
    IF NOT ('description' = ANY(v_h.changed_columns) AND 'code' = ANY(v_h.changed_columns)) THEN
        RAISE EXCEPTION 'FIXTURE 201A 失败:created 那一行的 changed_columns 应当是整行 23 列,实得 %', v_h.changed_columns;
    END IF;

    -- ══════════ B · ★ record_expense【新建支】⇒ 恰好一行 'created' ═══════════
    -- 【这条路径不在任何一份名单上】—— 它是本刀开工前重测出来的两条之一。
    v_res := record_expense(DATE '2026-01-05', '1500', 100000, v_ccy, NULL, 'unpaid', NULL,
        v_sup, NULL, 'fixture 201 capital',
        jsonb_build_object('description','f201 capital machine','useful_life_months',60), NULL);
    SELECT id INTO v_asset2 FROM fixed_assets WHERE expense_id = (v_res->>'expense_id')::uuid;
    SELECT count(*) INTO v_n FROM fixed_asset_history WHERE fixed_asset_id = v_asset2;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 201B 失败:record_expense 的资本【新建】支应当落下恰好一行 created,实得 % 行 '
                        '—— 这条写入路径从来不在任何一份名单上,而它是【建卡】的两扇门之一', v_n;
    END IF;

    -- ══════════ C · ★★ record_expense【追加成本】支 ⇒ cost_base 的改动被记住 ══
    -- 【这是那两条「动钱却从来没人记下来」的路径之一】
    v_res := record_expense(DATE '2026-02-05', '1500', 70000, v_ccy, NULL, 'unpaid', NULL,
        v_sup, NULL, 'fixture 201 installation',
        jsonb_build_object('asset_id', v_asset2), NULL);
    v_exp := (v_res->>'expense_id')::uuid;

    SELECT count(*) INTO v_n FROM fixed_asset_history WHERE fixed_asset_id = v_asset2;
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 201C 失败:追加一笔成本之后应当共有 2 行留痕(created + updated),实得 %', v_n;
    END IF;
    -- ⚠★【不按 changed_at 取"最新那一行"】★⚠ `now()` 是【事务】时刻 —— 同一个
    --   事务里落下的每一行留痕,changed_at 一模一样。按它排序取 LIMIT 1,
    --   拿到的是【任意】一行,而这支 fixture 整个跑在一个事务里。
    --   所以每一臂都按【它自己要找的那件事】取行:改了哪一列、改成了什么。
    SELECT * INTO v_h FROM fixed_asset_history
     WHERE fixed_asset_id = v_asset2 AND changed_columns = ARRAY['cost_base']
       AND new_cost_base = 170000;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'FIXTURE 201C 失败:找不到那一行"只改了 cost_base、改成 170000"的留痕';
    END IF;
    IF v_h.changed_columns <> ARRAY['cost_base'] THEN
        RAISE EXCEPTION 'FIXTURE 201C 失败:追加成本那一行动的应当【只有】cost_base,实得 %', v_h.changed_columns;
    END IF;
    IF v_h.old_cost_base <> 100000 OR v_h.new_cost_base <> 170000 THEN
        RAISE EXCEPTION 'FIXTURE 201C 失败:成本的前后值不对(% → %,应当 100000 → 170000)',
                        v_h.old_cost_base, v_h.new_cost_base;
    END IF;

    -- ══════════ D · ★ reverse_expense ⇒ 退回去的那一笔也被记住 ═══════════════
    PERFORM reverse_expense(v_exp, 'fixture 201 D');
    SELECT count(*) INTO v_n FROM fixed_asset_history WHERE fixed_asset_id = v_asset2;
    IF v_n <> 3 THEN
        RAISE EXCEPTION 'FIXTURE 201D 失败:冲销之后应当共有 3 行留痕,实得 %', v_n;
    END IF;
    SELECT * INTO v_h FROM fixed_asset_history
     WHERE fixed_asset_id = v_asset2 AND changed_columns = ARRAY['cost_base']
       AND new_cost_base = 100000;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'FIXTURE 201D 失败:找不到那一行"只改了 cost_base、退回 100000"的留痕';
    END IF;
    IF v_h.old_cost_base <> 170000 OR v_h.new_cost_base <> 100000 THEN
        RAISE EXCEPTION 'FIXTURE 201D 失败:冲销那一行的前后值不对(% → %,应当 170000 → 100000)',
                        v_h.old_cost_base, v_h.new_cost_base;
    END IF;

    -- ══════════ E · set_asset_in_service ═══════════════════════════════════
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM set_asset_in_service(v_asset2, v_d1);
    RESET ROLE;
    SELECT * INTO v_h FROM fixed_asset_history
     WHERE fixed_asset_id = v_asset2 AND changed_columns = ARRAY['in_service_date'];
    IF NOT FOUND THEN
        RAISE EXCEPTION 'FIXTURE 201E 失败:投用没有落下【只动 in_service_date】的那一行';
    END IF;
    IF v_h.old_in_service_date IS NOT NULL OR v_h.new_in_service_date <> v_d1 THEN
        RAISE EXCEPTION 'FIXTURE 201E 失败:投用日的前后值不对(% → %,应当 NULL → %)',
                        v_h.old_in_service_date, v_h.new_in_service_date, v_d1;
    END IF;

    -- ══════════ F · set_asset_acceptance ════════════════════════════════════
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM set_asset_acceptance(v_asset, CURRENT_DATE - 20);
    RESET ROLE;
    SELECT count(*) INTO v_n FROM fixed_asset_history
     WHERE fixed_asset_id = v_asset AND changed_columns = ARRAY['acceptance_date'];
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 201F 失败:验收应当落下恰好一行【只动 acceptance_date】的留痕,实得 %', v_n;
    END IF;

    -- ══════════ G · ★★ set_asset_planned_in_service —— B3 那扇门 ═════════════
    -- 【这一臂同时证明了 P1 那条判据买到的东西】:计划日的前后值真的落进了
    -- **带类型的 date 列**,而不是被 jsonb_populate_record 悄悄丢掉。
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM set_asset_planned_in_service(v_asset, v_d2);
    RESET ROLE;
    SELECT count(*) INTO v_n FROM fixed_asset_history
     WHERE fixed_asset_id = v_asset AND changed_columns = ARRAY['planned_in_service_date'];
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 201G 失败:设计划投用日应当落下恰好一行留痕,实得 % '
                        '—— 这正是 FIXED-ASSETS-PLANNED-DATE-NOT-LOGGED 立案的那一件事', v_n;
    END IF;
    SELECT * INTO v_h FROM fixed_asset_history
     WHERE fixed_asset_id = v_asset AND changed_columns = ARRAY['planned_in_service_date'];
    IF v_h.old_planned_in_service_date IS NOT NULL OR v_h.new_planned_in_service_date <> v_d2 THEN
        RAISE EXCEPTION 'FIXTURE 201G 失败:计划日的前后值没有落进【带类型的】列(% → %,应当 NULL → %)。'
                        '★ 若两边都是 NULL,那就是 jsonb_populate_record 把键丢了 —— 见 P1 臂',
                        v_h.old_planned_in_service_date, v_h.new_planned_in_service_date, v_d2;
    END IF;

    -- ══════════ H · dispose_fixed_asset ═════════════════════════════════════
    PERFORM dispose_fixed_asset(v_asset2, CURRENT_DATE, 0, NULL, 'fixture 201 H');
    -- ⚠ 必须带 change_type = 'updated':'created' 那一行的 changed_columns 是
    --   【整行 23 列】,status 当然也在里面(A 臂钉的就是这一条)。只按
    --   `'status' = ANY(...)` 取,拿到的会是出生那一行 —— 一条因为错的理由红/绿的判据。
    SELECT * INTO v_h FROM fixed_asset_history
     WHERE fixed_asset_id = v_asset2 AND change_type = 'updated'
       AND 'status' = ANY(changed_columns);
    IF NOT FOUND THEN
        RAISE EXCEPTION 'FIXTURE 201H 失败:处置没有落下一行动了 status 的 updated 留痕';
    END IF;
    IF NOT ('status' = ANY(v_h.changed_columns) AND 'disposal_date' = ANY(v_h.changed_columns)) THEN
        RAISE EXCEPTION 'FIXTURE 201H 失败:处置那一行应当同时动了 status 与 disposal_date,实得 %', v_h.changed_columns;
    END IF;
    IF v_h.old_status <> 'active' OR v_h.new_status <> 'disposed' THEN
        RAISE EXCEPTION 'FIXTURE 201H 失败:状态的前后值不对(% → %)', v_h.old_status, v_h.new_status;
    END IF;

    -- ══════════ I · ★ 什么都没改的 UPDATE 不留行 ═════════════════════════════
    -- 【不是省事,是与 trg_so_history_header 同一条】一行"什么都没变"的历史会把
    -- 真正的修改淹掉。而这里的判据是【差集】,不是一份具名的列清单。
    SELECT count(*) INTO v_n FROM fixed_asset_history WHERE fixed_asset_id = v_asset;
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM set_asset_planned_in_service(v_asset, v_d2);   -- 同一个日期,再设一次
    RESET ROLE;
    SELECT count(*) INTO v_n2 FROM fixed_asset_history WHERE fixed_asset_id = v_asset;
    IF v_n2 <> v_n THEN
        RAISE EXCEPTION 'FIXTURE 201I 失败:把同一个日期再设一次,不该长出留痕(% → %)', v_n, v_n2;
    END IF;

    -- ══════════ J · ★★ 没有登录会话的那一种【有名字】═════════════════════════
    -- 线上【没有任何系统写入者】(没有 pg_cron;depreciate_fixed_assets 不写这张表),
    -- 所以这一格记的是它真正的意思:**一个不经登录的数据库直连会话**。
    -- ⚠ 不许叫 'system' —— 那是给一个不存在的主体起名字,而那个名字三个月后
    --    会被读成「例行作业改的,不用查」。
    PERFORM set_config('request.jwt.claims', '', true);
    UPDATE fixed_assets SET notes = 'f201 direct' WHERE id = v_asset;
    SELECT * INTO v_h FROM fixed_asset_history
     WHERE fixed_asset_id = v_asset AND changed_columns = ARRAY['notes'];
    IF NOT FOUND THEN
        RAISE EXCEPTION 'FIXTURE 201J 失败:一次直连 UPDATE 没有留痕 —— 触发器对【不经函数的写】也必须开火,'
                        '那正是"触发器而不是七支函数里的七条 INSERT"的全部意义';
    END IF;
    IF v_h.changed_by IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 201J 失败:没有 claims 的会话居然记下了一个人(%)', v_h.changed_by;
    END IF;
    IF v_h.changed_by_kind <> 'no_session' THEN
        RAISE EXCEPTION 'FIXTURE 201J 失败:没有登录会话时 changed_by_kind 应当是 no_session,实得「%」。'
                        '★ 一个沉默的 NULL 读起来像"不知道是谁",而真相是一句说得出口的话', v_h.changed_by_kind;
    END IF;
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u_all), true);

    -- ══════════ K · ★ 只增不改:UPDATE 与 DELETE 都按名拒 ════════════════════
    v_raised := false; v_msg := NULL;
    BEGIN
        UPDATE fixed_asset_history SET change_type = 'created' WHERE fixed_asset_id = v_asset;
    EXCEPTION WHEN OTHERS THEN v_raised := true; v_msg := SQLERRM;
    END;
    IF NOT v_raised OR v_msg NOT LIKE 'FA_HISTORY_IMMUTABLE%' THEN
        RAISE EXCEPTION 'FIXTURE 201K 失败:改一行留痕没有被按名拒(raised=%,「%」)', v_raised, v_msg;
    END IF;

    v_raised := false; v_msg := NULL;
    BEGIN
        DELETE FROM fixed_asset_history WHERE fixed_asset_id = v_asset;
    EXCEPTION WHEN OTHERS THEN v_raised := true; v_msg := SQLERRM;
    END;
    IF NOT v_raised OR v_msg NOT LIKE 'FA_HISTORY_IMMUTABLE%' THEN
        RAISE EXCEPTION 'FIXTURE 201K 失败:删一行留痕没有被按名拒(raised=%,「%」)', v_raised, v_msg;
    END IF;

    -- ══════════ L · ★ 基表的硬删:拦住,而且【自己报名】═══════════════════════
    v_raised := false; v_msg := NULL;
    BEGIN
        DELETE FROM fixed_assets WHERE id = v_asset;
    EXCEPTION WHEN OTHERS THEN v_raised := true; v_msg := SQLERRM;
    END;
    IF NOT v_raised OR v_msg NOT LIKE 'FIXED_ASSET_NO_HARD_DELETE|%' THEN
        RAISE EXCEPTION 'FIXTURE 201L 失败:硬删一张资产卡没有被【按名】拒(raised=%,「%」)。'
                        '★ 靠外键顺带挡下来的那句报错既不说是哪张卡、也不说规矩,'
                        '而且对一张还没有过任何改动的卡根本不拦', v_raised, v_msg;
    END IF;

    -- ══════════ M · ★★ 反面对照:没有 edit ⇒ 写不动,且【没有留痕长出来】════
    SELECT count(*) INTO v_n FROM fixed_asset_history WHERE fixed_asset_id = v_asset;
    v_raised := false; v_msg := NULL;
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u_view), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    BEGIN
        PERFORM set_asset_planned_in_service(v_asset, CURRENT_DATE + 1);
    EXCEPTION WHEN OTHERS THEN v_raised := true; v_msg := SQLERRM;
    END;
    -- ★★ 同一个会话里,老那条直连 UPDATE 仍然 0 行 —— B3 的 G 臂,一字不改。
    --    没有这一句,"切了角色"只是一句声明,而上面每一臂都可能是按构造变绿的。
    UPDATE fixed_assets SET planned_in_service_date = CURRENT_DATE + 2 WHERE id = v_asset;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RESET ROLE;

    IF NOT v_raised OR v_msg NOT LIKE 'PERMISSION_DENIED|module.finance.edit%' THEN
        RAISE EXCEPTION 'FIXTURE 201M 失败:没有 module.finance.edit 的会话没有被按名拒(raised=%,「%」)', v_raised, v_msg;
    END IF;
    IF v_rows <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 201M 失败:直连 UPDATE 改了 % 行。'
                        '★ 要么 SET LOCAL ROLE authenticated 没有生效(于是本文件每一臂都是按构造变绿的,'
                        '什么都没证),要么有人给 fixed_assets 补了一条 UPDATE 策略', v_rows;
    END IF;
    SELECT count(*) INTO v_n2 FROM fixed_asset_history WHERE fixed_asset_id = v_asset;
    IF v_n2 <> v_n THEN
        RAISE EXCEPTION 'FIXTURE 201M 失败:被拒的那一次居然长出了留痕(% → %)—— 一次没有发生的改动不该有记录', v_n, v_n2;
    END IF;

    -- ══════════ N · ★★ 读:两半都要钉 ═══════════════════════════════════════
    -- 【只钉"没权限的人读到 0 行"是不够的】—— 一张空表、一条写错的策略、
    -- 一个拼错的权限码,都会让那个 0 出现。所以先钉【有权限的人看得见 N 行】,
    -- 那个 0 才是一次测量,不是一次缺席。
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u_view), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_seen_view FROM fixed_asset_history;
    RESET ROLE;

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u_none), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_seen_none FROM fixed_asset_history;
    RESET ROLE;

    IF v_seen_view = 0 THEN
        RAISE EXCEPTION 'FIXTURE 201N 失败:一个【有 module.finance.view】的人读到 0 行留痕 —— '
                        '那么下一句"没权限的人读到 0"就什么都没证明';
    END IF;
    IF v_seen_none <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 201N 失败:一个【没有 module.finance.view】的人读到了 % 行留痕', v_seen_none;
    END IF;

    RAISE NOTICE 'FIXTURE 201 全部通过(8 条写语句逐条走过):'
                 'P1 ★成对齐全(加了列而忘了影子表 ⇒ 当场红,不是静默丢)· '
                 'P2 ★捕获触发器不提 22 个列名中的任何一个(fixtures/120 因此一字未改)· '
                 'A create_fixed_asset ⇒ 恰好一行 created + 出生快照 + changed_by 是调用者 · '
                 'B ★record_expense 新建支 · C ★record_expense 追加成本支(100000→170000)· '
                 'D ★reverse_expense(170000→100000)—— B/C/D 三条从来不在任何一份名单上 · '
                 'E set_asset_in_service · F set_asset_acceptance · G ★set_asset_planned_in_service · '
                 'H dispose_fixed_asset(active→disposed)· I 空改动不留行 · '
                 'J ★没有登录会话 ⇒ changed_by_kind = no_session(不是沉默的 NULL,也不叫 system)· '
                 'K 只增不改(UPDATE/DELETE 均 FA_HISTORY_IMMUTABLE)· '
                 'L 硬删按名拒 FIXED_ASSET_NO_HARD_DELETE · '
                 'M ★无 edit 者被按名拒、直连 UPDATE 仍 0 行、且没有留痕长出来 · '
                 'N ★读的两半:有 view 者看得见 % 行,无 view 者 0 行', v_seen_view;
END $$;
ROLLBACK;
