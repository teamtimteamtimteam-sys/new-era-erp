-- 74 工单(WO-1a):计划改得动,但改不到【已经做过的事】下面去
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【这份 fixture 钉住的东西,以及每一条为什么需要一个对照】
--
--   ① 【地板是真的,不是一句注释】计划投料量不能低于挂上来的加工单已经吃掉的量。
--      这一条今天【走不到自然路径】—— commit_processing_run 要到 WO-1b 才写
--      work_order_id。所以 D 臂用一次【直改】把一条真加工单挂上去(见下面那段
--      "这座桥"的说明),让地板第一次读到非零的已耗量。没有这座桥,守卫里那段
--      join 从来没在真数据上跑过,而【一条从没跑过的守卫,与一条不存在的守卫,
--      在测试里长得一模一样】。
--   ② 【状态迁移要连"拒绝的方向"一起验】只验 draft→released→closed 走得通,
--      一个"什么都放行"的实现照样绿。所以矩阵里每一格的反方向各有一条断言。
--   ③ 【短交要【被记下来】,不是被拦住】close 不检查完成度 —— 拦住它只会让人
--      把计划改小以求关单,而那正好把差异抹掉。所以 F 臂断言的是"关成功了,
--      且理由留在历史里",不是"被拒了"。
--   ④ 【每一条拒绝都要是【唯一】没满足的前提】fixture 73 付过这笔账:那份的
--      抬头臂挂在一张没有行的发票上,拿回的是 INV_NO_LINES,而断言若只写
--      "被拒了"就会一路绿。所以这里每一条拒绝各自造自己的场景。
--   ⑤ 【注入:每个函数从【一份原样定义】派生,一次只少一道门】不从上一次注入的
--      残骸派生 —— 否则门会累积,第三个注入实际少了三道门,它证明的就不再是
--      "这一道门有牙"。每个注入先断言【替换确实改动了字节】:一次什么也没删的
--      replace 会把"现在应当成功"变成对原函数的断言,那是会骗人的空转。
--
-- 【这座桥:直改 work_order_id】fixtures 以 postgres 身份跑,绕过 RLS,所以
-- 这一步做得到。它【只是临时的】—— WO-1b 会给 commit_processing_run 加上工单
-- 参数,那时这两臂改成走真实路径,这段注释连同直改一起删掉。写在这里而不是
-- 留在提交信息里,是因为读这份 fixture 的人才是需要知道它的人。
--
-- 【注入臂放在最后】fixture 64/69/71/73 都付过这笔账:注入种下的行会污染后面各臂。
-- 自带数据(README 第 2 条)。期间锁显式设 NULL(第 5 条)。
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    v_user  uuid := gen_random_uuid();   -- 全权
    v_edit  uuid := gen_random_uuid();   -- module.processing.edit + view
    v_view  uuid := gen_random_uuid();   -- 只有 module.processing.view
    v_other uuid := gen_random_uuid();   -- 只有别的模块
    r_all uuid; r_edit uuid; r_view uuid; r_other uuid;
    v_sup uuid; v_matA uuid; v_matB uuid; v_matC uuid; v_ib uuid;
    woA uuid; woB uuid; woC uuid; woD uuid; woE uuid;
    v_run uuid;
    v_res jsonb; v_msg text; v_denied boolean; v_n integer; v_qty numeric; v_status text;
    v_def text; v_inj text;
    -- 【五份原样定义,在【任何注入之前】一次取齐】注入 3 会替换 close_work_order,
    -- 而注入 5 也要 close 的原样定义 —— 到那时现取,取到的是【已经缺了一道门的】
    -- 那一份,于是第二个注入实际少了两道门,它证明的就不再是「这一道门有牙」。
    def_create text; def_release text; def_close text; def_cancel text; def_amend text;
    d date := CURRENT_DATE;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-74', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);

    -- 【三个只有一半的角色】线上持 processing.edit 的角色同时都持 view,
    -- 于是两者的区别没有可观察的后果。造出只有一半的角色,那个区别才验得到。
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-74-edit', 'f', 'f', true) RETURNING id INTO r_edit;
    INSERT INTO role_permissions (role_id, permission_code)
    VALUES (r_edit, 'module.processing.edit'), (r_edit, 'module.processing.view');
    INSERT INTO user_roles (user_id, role_id) VALUES (v_edit, r_edit);

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-74-view', 'f', 'f', true) RETURNING id INTO r_view;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_view, 'module.processing.view');
    INSERT INTO user_roles (user_id, role_id) VALUES (v_view, r_view);

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-74-other', 'f', 'f', true) RETURNING id INTO r_other;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_other, 'module.sales.view');
    INSERT INTO user_roles (user_id, role_id) VALUES (v_other, r_other);

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);
    UPDATE finance_settings SET locked_before = NULL;

    -- 【原样定义在这里取,而不是各注入临用临取】理由见上面的声明。
    def_create  := pg_get_functiondef('public.create_work_order(jsonb,jsonb,date,text)'::regprocedure);
    def_release := pg_get_functiondef('public.release_work_order(uuid)'::regprocedure);
    def_close   := pg_get_functiondef('public.close_work_order(uuid,text)'::regprocedure);
    def_cancel  := pg_get_functiondef('public.cancel_work_order(uuid,text)'::regprocedure);
    def_amend   := pg_get_functiondef('public.amend_work_order(uuid,text,date,boolean,text,boolean,jsonb,jsonb)'::regprocedure);

    INSERT INTO suppliers (code, legal_name, country)
    VALUES ('ZZ74-S', 'fixture 74 supplier', 'SG') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, category) VALUES ('ZZ74-MA','f74 raw','black_mass')
        RETURNING id INTO v_matA;
    INSERT INTO materials (code, name, category) VALUES ('ZZ74-MB','f74 fine','black_mass')
        RETURNING id INTO v_matB;
    INSERT INTO materials (code, name, category) VALUES ('ZZ74-MC','f74 other','black_mass')
        RETURNING id INTO v_matC;

    -- ══════════ A. 新建:出生即 draft,行都在,预期产出可选 ═══════════════════
    v_res := create_work_order(
        jsonb_build_array(jsonb_build_object('material_id', v_matA, 'planned_qty', 100)),
        jsonb_build_array(jsonb_build_object('material_id', v_matB, 'expected_qty', 80)),
        d + 3, 'fixture 74 A');
    woA := (v_res->>'work_order_id')::uuid;
    IF (v_res->>'status') <> 'draft' THEN
        RAISE EXCEPTION 'FIXTURE 74A 失败:新建的工单应当是 draft,实得 %', v_res::text;
    END IF;
    IF (v_res->>'code') NOT LIKE 'WO-' || EXTRACT(YEAR FROM d)::text || '-%' THEN
        RAISE EXCEPTION 'FIXTURE 74A 失败:编号应当是 WO-YYYY-NNNN,实得 %', v_res->>'code';
    END IF;
    IF (SELECT count(*) FROM work_order_lines WHERE work_order_id = woA) <> 1
       OR (SELECT count(*) FROM work_order_expected_outputs WHERE work_order_id = woA) <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 74A 失败:一条计划行 + 一条预期产出行应当都写进去了';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM work_order_history
                    WHERE work_order_id = woA AND change_type = 'created') THEN
        RAISE EXCEPTION 'FIXTURE 74A 失败:新建应当留一条 created 痕';
    END IF;
    -- 【排产日可以整个不给,而它必须留成 NULL】—— 一个补出来的今天会把
    -- "谁也没排过期"伪装成"排在今天"。这一条是本刀那个决定的行为断言。
    v_res := create_work_order(
        jsonb_build_array(jsonb_build_object('material_id', v_matA, 'planned_qty', 5)),
        NULL, NULL, NULL);
    woB := (v_res->>'work_order_id')::uuid;
    IF (SELECT scheduled_date FROM work_orders WHERE id = woB) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 74A 失败:没给排产日就该留空 —— 补一个今天会把"没排期"伪装成"排在今天"';
    END IF;
    IF (SELECT count(*) FROM work_order_expected_outputs WHERE work_order_id = woB) <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 74A 失败:没给预期产出就该一行都没有(没估过 ≠ 估了零)';
    END IF;

    -- ══════════ B. 新建的七条拒绝,每一条【只差它自己那一件】═════════════════
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM create_work_order(jsonb_build_array(), NULL, NULL, NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg <> 'WO_NO_LINES' THEN
        RAISE EXCEPTION 'FIXTURE 74B 失败:空行应当报 WO_NO_LINES,实得 %', COALESCE(v_msg,'(建成了)');
    END IF;

    v_denied := false; v_msg := NULL;
    BEGIN PERFORM create_work_order(
        jsonb_build_array(jsonb_build_object('material_id', v_matA, 'planned_qty', 0)), NULL, NULL, NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg <> 'WO_LINE_QTY_INVALID' THEN
        RAISE EXCEPTION 'FIXTURE 74B 失败:零数量应当报 WO_LINE_QTY_INVALID,实得 %', COALESCE(v_msg,'(建成了)');
    END IF;

    v_denied := false; v_msg := NULL;
    BEGIN PERFORM create_work_order(
        jsonb_build_array(jsonb_build_object('material_id', gen_random_uuid(), 'planned_qty', 1)),
        NULL, NULL, NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'WO_MATERIAL_NOT_FOUND|%' THEN
        RAISE EXCEPTION 'FIXTURE 74B 失败:不存在的物料应当按名拒,实得 %', COALESCE(v_msg,'(建成了)');
    END IF;

    -- 【重复物料按名拒,而不是让唯一约束抛 23505】—— 那条机器串到不了人眼里。
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM create_work_order(
        jsonb_build_array(jsonb_build_object('material_id', v_matA, 'planned_qty', 1),
                          jsonb_build_object('material_id', v_matA, 'planned_qty', 2)),
        NULL, NULL, NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'WO_DUPLICATE_MATERIAL|%' THEN
        RAISE EXCEPTION 'FIXTURE 74B 失败:同一物料两行应当报 WO_DUPLICATE_MATERIAL(而不是 23505),实得 %',
            COALESCE(v_msg,'(建成了)');
    END IF;

    -- 预期产出那三条:投料行一律给合法的,让预期那一侧成为唯一没满足的前提
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM create_work_order(
        jsonb_build_array(jsonb_build_object('material_id', v_matA, 'planned_qty', 1)),
        jsonb_build_array(jsonb_build_object('material_id', v_matB, 'expected_qty', -1)), NULL, NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg <> 'WO_EXPECTED_QTY_INVALID' THEN
        RAISE EXCEPTION 'FIXTURE 74B 失败:负预期应当报 WO_EXPECTED_QTY_INVALID,实得 %', COALESCE(v_msg,'(建成了)');
    END IF;

    v_denied := false; v_msg := NULL;
    BEGIN PERFORM create_work_order(
        jsonb_build_array(jsonb_build_object('material_id', v_matA, 'planned_qty', 1)),
        jsonb_build_array(jsonb_build_object('material_id', gen_random_uuid(), 'expected_qty', 1)), NULL, NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'WO_EXPECTED_MATERIAL_NOT_FOUND|%' THEN
        RAISE EXCEPTION 'FIXTURE 74B 失败:预期产出指向不存在的物料应当按名拒,实得 %', COALESCE(v_msg,'(建成了)');
    END IF;

    v_denied := false; v_msg := NULL;
    BEGIN PERFORM create_work_order(
        jsonb_build_array(jsonb_build_object('material_id', v_matA, 'planned_qty', 1)),
        jsonb_build_array(jsonb_build_object('material_id', v_matB, 'expected_qty', 1),
                          jsonb_build_object('material_id', v_matB, 'expected_qty', 2)), NULL, NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'WO_DUPLICATE_EXPECTED|%' THEN
        RAISE EXCEPTION 'FIXTURE 74B 失败:同一物料两条预期应当报 WO_DUPLICATE_EXPECTED,实得 %',
            COALESCE(v_msg,'(建成了)');
    END IF;

    -- 【唯一约束本身也要在:按名拒是文案,约束是兜底 —— 两者都要】
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conrelid = 'public.work_order_lines'::regclass AND contype = 'u')
       OR NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conrelid = 'public.work_order_expected_outputs'::regclass AND contype = 'u') THEN
        RAISE EXCEPTION 'FIXTURE 74B 失败:两张行表都要有 (work_order_id, material_id) 的唯一约束 —— 按名拒是文案,约束才是兜底';
    END IF;

    -- ══════════ C. 状态矩阵:走得通的方向,与【走不通的方向】═════════════════
    -- draft 上不能 close(那是 cancel 的事)
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM close_work_order(woA, '想直接关掉一张草稿');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'WO_NOT_RELEASED|%|draft' THEN
        RAISE EXCEPTION 'FIXTURE 74C 失败:草稿不能收工(要 cancel),实得 %', COALESCE(v_msg,'(关掉了)');
    END IF;

    v_res := release_work_order(woA);
    IF (v_res->>'status') <> 'released' THEN
        RAISE EXCEPTION 'FIXTURE 74C 失败:放行之后应当是 released,实得 %', v_res::text;
    END IF;

    -- 放行过的不能再放行
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM release_work_order(woA);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'WO_NOT_DRAFT|%|released' THEN
        RAISE EXCEPTION 'FIXTURE 74C 失败:放行过的不该再放行,实得 %', COALESCE(v_msg,'(又放行了一次)');
    END IF;

    -- 收工要理由
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM close_work_order(woA, '   ');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'WO_CLOSE_REASON_REQUIRED|%' THEN
        RAISE EXCEPTION 'FIXTURE 74C 失败:收工理由必填,实得 %', COALESCE(v_msg,'(关掉了)');
    END IF;

    -- 取消要理由
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM cancel_work_order(woB, NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'WO_CANCEL_REASON_REQUIRED|%' THEN
        RAISE EXCEPTION 'FIXTURE 74C 失败:取消理由必填,实得 %', COALESCE(v_msg,'(取消了)');
    END IF;

    -- draft 可以取消(woB 从没放行过)
    v_res := cancel_work_order(woB, 'fixture 74:这件事不做了');
    IF (v_res->>'status') <> 'cancelled' THEN
        RAISE EXCEPTION 'FIXTURE 74C 失败:草稿应当取消得掉,实得 %', v_res::text;
    END IF;
    -- 终态之后任何动作都拒
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM release_work_order(woB);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'WO_NOT_DRAFT|%|cancelled' THEN
        RAISE EXCEPTION 'FIXTURE 74C 失败:取消了的单子不该还能放行,实得 %', COALESCE(v_msg,'(放行了)');
    END IF;
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM cancel_work_order(woB, '再取消一次');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'WO_NOT_CANCELLABLE|%|cancelled' THEN
        RAISE EXCEPTION 'FIXTURE 74C 失败:取消了的单子不该再取消一次,实得 %', COALESCE(v_msg,'(又取消了)');
    END IF;
    -- 【状态与它的证据同时成立】—— cancelled 了就该有时刻与理由,而这由 CHECK 兜底
    IF (SELECT cancelled_at IS NULL OR btrim(COALESCE(cancel_reason,'')) = ''
          FROM work_orders WHERE id = woB) THEN
        RAISE EXCEPTION 'FIXTURE 74C 失败:取消之后时刻与理由都该在行上';
    END IF;

    -- ══════════ D. 地板:计划改不到【已经吃掉的量】下面 ═══════════════════════
    -- 这一臂需要一条【真的挂在工单上的加工单】。见文件头"这座桥":今天
    -- commit_processing_run 还不写 work_order_id(那是 WO-1b),所以先正常提交
    -- 一次加工,再直改把它挂上去。fixtures 以 postgres 身份跑,绕得过 RLS。
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date)
    VALUES ('ZZ74-IB', v_matA, v_sup, 100, 100, 'kg', d) RETURNING id INTO v_ib;
    PERFORM reprice_inbound_batch(v_ib, 1, 'SGD', NULL, 'fixture 74 price');

    v_res := create_work_order(
        jsonb_build_array(jsonb_build_object('material_id', v_matA, 'planned_qty', 100)),
        NULL, d, 'fixture 74 D');
    woC := (v_res->>'work_order_id')::uuid;
    PERFORM release_work_order(woC);

    v_run := commit_processing_run(d, 'fixture 74 run', 0,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib, 'quantity_consumed', 60)),
        jsonb_build_array(jsonb_build_object('material_id', v_matB, 'quantity', 55)), 'weight');
    UPDATE processing_runs SET work_order_id = woC WHERE id = v_run;   -- ← 这座桥

    -- 改到 60 以上:通
    v_res := amend_work_order(woC, '现实比计划多一点', NULL, false, NULL, false,
        jsonb_build_array(jsonb_build_object('material_id', v_matA, 'planned_qty', 80)), NULL);
    IF (SELECT planned_qty FROM work_order_lines WHERE work_order_id = woC AND material_id = v_matA) <> 80 THEN
        RAISE EXCEPTION 'FIXTURE 74D 失败:改到已耗量之上应当通过';
    END IF;

    -- 改到 60 以下:【地板】按名拒,而且把三个数都说出来
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM amend_work_order(woC, '想把计划改小', NULL, false, NULL, false,
        jsonb_build_array(jsonb_build_object('material_id', v_matA, 'planned_qty', 50)), NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'WO_LINE_BELOW_CONSUMED|%|50|60' THEN
        RAISE EXCEPTION 'FIXTURE 74D 失败:计划改到已耗量之下应当按名拒并说出两个数,实得 %',
            COALESCE(v_msg,'(改成了)');
    END IF;
    -- 拒了就是什么都没改
    IF (SELECT planned_qty FROM work_order_lines WHERE work_order_id = woC AND material_id = v_matA) <> 80 THEN
        RAISE EXCEPTION 'FIXTURE 74D 失败:被拒的改单不该留下任何改动';
    END IF;
    -- 【删掉一条吃过料的行,与把它改成 0 是同一件事】所以同一道地板
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM amend_work_order(woC, '想把这一行删掉', NULL, false, NULL, false,
        jsonb_build_array(jsonb_build_object('material_id', v_matA)), NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'WO_LINE_BELOW_CONSUMED|%' THEN
        RAISE EXCEPTION 'FIXTURE 74D 失败:删掉一条已经吃过料的行应当撞同一道地板,实得 %',
            COALESCE(v_msg,'(删掉了)');
    END IF;

    -- 【改单必须留痕,而且理由必填】
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM amend_work_order(woC, '  ', NULL, false, NULL, false,
        jsonb_build_array(jsonb_build_object('material_id', v_matA, 'planned_qty', 90)), NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'WO_AMEND_REASON_REQUIRED|%' THEN
        RAISE EXCEPTION 'FIXTURE 74D 失败:改单理由必填,实得 %', COALESCE(v_msg,'(改成了)');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM work_order_history
                    WHERE work_order_id = woC AND change_type = 'line_update'
                      AND old_qty = 100 AND new_qty = 80
                      AND amend_reason = '现实比计划多一点') THEN
        RAISE EXCEPTION 'FIXTURE 74D 失败:改量应当留下成对的 old_/new_ 与理由';
    END IF;
    -- 【什么都没改也要说出来】—— 一次静默通过的空改单,会让人以为改动生效了
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM amend_work_order(woC, '什么都不改', NULL, false, NULL, false, NULL, NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'WO_AMEND_NO_CHANGES|%' THEN
        RAISE EXCEPTION 'FIXTURE 74D 失败:空改单应当按名拒,实得 %', COALESCE(v_msg,'(静默通过了)');
    END IF;

    -- 【预期产出【没有】地板 —— 那是一个决定,所以正面断言它】
    -- 它是一句估计,不是已经发生的事实;改小它不与任何发生过的事矛盾。
    PERFORM amend_work_order(woC, '预期调低', NULL, false, NULL, false, NULL,
        jsonb_build_array(jsonb_build_object('material_id', v_matB, 'expected_qty', 1)));
    IF (SELECT expected_qty FROM work_order_expected_outputs
         WHERE work_order_id = woC AND material_id = v_matB) <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 74D 失败:预期产出应当改得动(它没有地板,与计划投料行刻意不同)';
    END IF;

    -- ══════════ E. 挂了加工单就不能取消 —— 它只能收工 ═══════════════════════
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM cancel_work_order(woC, '想把开过工的单子取消掉');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'WO_HAS_RUNS|%|1' THEN
        RAISE EXCEPTION 'FIXTURE 74E 失败:挂着加工单的工单不该取消得掉(那会让那次加工失去出处),实得 %',
            COALESCE(v_msg,'(取消了)');
    END IF;

    -- ══════════ F. 短交:合法、要记下来,不是要拦住的错误 ═══════════════════
    -- woC 计划 80,实际只吃了 60 —— 关它不该被拦,而理由要留在历史里。
    v_res := close_work_order(woC, '客户改了需求,余量不做了');
    IF (v_res->>'status') <> 'closed' THEN
        RAISE EXCEPTION 'FIXTURE 74F 失败:短交应当关得掉 —— 拦住它只会逼人把计划改小以求关单,而那正好把差异抹掉';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM work_order_history
                    WHERE work_order_id = woC AND change_type = 'closed'
                      AND amend_reason = '客户改了需求,余量不做了') THEN
        RAISE EXCEPTION 'FIXTURE 74F 失败:收工理由应当留在历史里';
    END IF;
    IF (SELECT closed_at IS NULL OR btrim(COALESCE(close_reason,'')) = ''
          FROM work_orders WHERE id = woC) THEN
        RAISE EXCEPTION 'FIXTURE 74F 失败:收工之后时刻与理由都该在行上';
    END IF;
    -- 关了之后改不动
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM amend_work_order(woC, '关了还想改', NULL, false, NULL, false,
        jsonb_build_array(jsonb_build_object('material_id', v_matA, 'planned_qty', 99)), NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'WO_NOT_AMENDABLE|%|closed' THEN
        RAISE EXCEPTION 'FIXTURE 74F 失败:收工之后不该还能改计划,实得 %', COALESCE(v_msg,'(改成了)');
    END IF;

    -- ══════════ G. 权限:编辑写得了,只读读得到写不了,别的模块【看不见】═════
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_edit), true);
    v_res := create_work_order(
        jsonb_build_array(jsonb_build_object('material_id', v_matA, 'planned_qty', 7)), NULL, NULL, NULL);
    woD := (v_res->>'work_order_id')::uuid;
    IF woD IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 74G 失败:持 processing.edit 的人应当建得了工单';
    END IF;

    -- 只读:读得到那几张单,但一个写动作都做不了
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_view), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM work_orders WHERE id IN (woA, woC, woD);
    RESET ROLE;
    IF v_n <> 3 THEN
        RAISE EXCEPTION 'FIXTURE 74G 失败:只有 processing.view 的读者应当看得见那三张单,实得 % 行', v_n;
    END IF;
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM create_work_order(
        jsonb_build_array(jsonb_build_object('material_id', v_matA, 'planned_qty', 1)), NULL, NULL, NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'PERMISSION_DENIED%' THEN
        RAISE EXCEPTION 'FIXTURE 74G 失败:只读的角色不该建得了工单,实得 %', COALESCE(v_msg,'(建成了)');
    END IF;
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM release_work_order(woD);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'PERMISSION_DENIED%' THEN
        RAISE EXCEPTION 'FIXTURE 74G 失败:只读的角色不该放行得了工单,实得 %', COALESCE(v_msg,'(放行了)');
    END IF;

    -- 别的模块:看见的是【空】,而不是报错(与 fixture 73E 同一条)
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_other), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM work_orders;
    RESET ROLE;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 74G 失败:没有 processing.view 的读者应当一行都看不见,实得 % 行', v_n;
    END IF;
    -- 四张表都要挡住,不是只挡表头
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_other), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT (SELECT count(*) FROM work_order_lines)
         + (SELECT count(*) FROM work_order_expected_outputs)
         + (SELECT count(*) FROM work_order_history) INTO v_n;
    RESET ROLE;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 74G 失败:行表与历史也该一行看不见,实得 % 行 —— 只挡表头等于没挡', v_n;
    END IF;

    -- 【客户端直插:四张表都没有 INSERT 策略,唯一写入口是那几个函数】
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_edit), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_denied := false;
    BEGIN INSERT INTO work_orders (code, status) VALUES ('WO-SIDE-DOOR', 'draft');
    EXCEPTION WHEN OTHERS THEN v_denied := true; END;
    RESET ROLE;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 74G 失败:直连插一张工单应当被 RLS 拒(本表没有 INSERT 策略)';
    END IF;

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    -- ══════════ 注入 1/2/3/4:四道门各删一次 ═════════════════════════════════
    -- 每个注入从【它自己那个函数的原样定义】派生,一次只少一道门,不累积。
    -- 每个先断言"替换确实改动了字节" —— 一次什么也没删的 replace 会把下面那句
    -- "现在应当成功"变成对原函数的断言,那是会骗人的空转。

    -- ── 注入 1:删掉 amend 的【地板】────────────────────────────────────────
    -- 前提:woE 挂着一条吃了 60 的加工单,计划 80,状态 released —— 与 D 臂同形,
    -- 但另起一张,因为 woC 已经 closed(那会让调用落进 WO_NOT_AMENDABLE,
    -- 注入报"仍然被拒",而真正的原因是另一道门 —— fixture 73 B2 的教训)。
    v_res := create_work_order(
        jsonb_build_array(jsonb_build_object('material_id', v_matA, 'planned_qty', 80)), NULL, d, 'f74 inj');
    woE := (v_res->>'work_order_id')::uuid;
    PERFORM release_work_order(woE);
    UPDATE processing_runs SET work_order_id = woE WHERE id = v_run;   -- 同一条真加工单改挂过来
    IF (SELECT status FROM work_orders WHERE id = woE) <> 'released'
       OR (SELECT count(*) FROM processing_runs WHERE work_order_id = woE AND status='committed') <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 74 注入1 前提不成立:要的是【released、且挂着一条已提交加工单】的工单';
    END IF;

    v_def := def_amend;
    v_inj := replace(v_def,
$g$                IF v_qty < v_consumed THEN
                    RAISE EXCEPTION 'WO_LINE_BELOW_CONSUMED|%|%|%', v_mat, v_qty, v_consumed;
                END IF;
$g$, '');
    IF v_inj = v_def THEN
        RAISE EXCEPTION 'FIXTURE 74 注入1 失败:在函数定义里没找到【地板】那道门的原文 —— 这个注入什么也没删,下面那句"应当成功"会变成空转';
    END IF;
    EXECUTE v_inj;
    PERFORM amend_work_order(woE, '注入之后把计划改到已耗量之下', NULL, false, NULL, false,
        jsonb_build_array(jsonb_build_object('material_id', v_matA, 'planned_qty', 50)), NULL);
    SELECT planned_qty INTO v_qty FROM work_order_lines
     WHERE work_order_id = woE AND material_id = v_matA;
    IF v_qty <> 50 THEN
        RAISE EXCEPTION 'FIXTURE 74 注入1 失败:删掉地板之后,计划【仍然】没改到 50(实得 %)—— 说明 D 臂拒它的不是那道门', v_qty;
    END IF;

    -- ── 注入 2:删掉 cancel 的 WO_HAS_RUNS ─────────────────────────────────
    -- 前提:woE 仍是 released、仍挂着那条加工单、理由给足 —— 只差这一道门。
    IF (SELECT status FROM work_orders WHERE id = woE) <> 'released'
       OR (SELECT count(*) FROM processing_runs WHERE work_order_id = woE AND deleted_at IS NULL) <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 74 注入2 前提不成立:要的是【released、且挂着加工单】';
    END IF;
    v_def := def_cancel;
    v_inj := replace(v_def,
$g$    IF v_runs > 0 THEN
        RAISE EXCEPTION 'WO_HAS_RUNS|%|%', v_wo.code, v_runs;
    END IF;
$g$, '');
    IF v_inj = v_def THEN
        RAISE EXCEPTION 'FIXTURE 74 注入2 失败:在函数定义里没找到 WO_HAS_RUNS 那道门的原文 —— 这个注入什么也没删';
    END IF;
    EXECUTE v_inj;
    v_res := cancel_work_order(woE, '注入之后取消一张开过工的单');
    IF (v_res->>'status') <> 'cancelled' THEN
        RAISE EXCEPTION 'FIXTURE 74 注入2 失败:删掉 WO_HAS_RUNS 之后,取消【仍然】没成功 —— 说明 E 臂拒它的不是那道门';
    END IF;

    -- ── 注入 3:删掉 close 的【理由必填】────────────────────────────────────
    -- 前提:另起一张 released 的单(前面几张都进终态了),空理由是唯一没满足的。
    v_res := create_work_order(
        jsonb_build_array(jsonb_build_object('material_id', v_matC, 'planned_qty', 3)), NULL, NULL, 'f74 inj3');
    woD := (v_res->>'work_order_id')::uuid;
    PERFORM release_work_order(woD);
    v_def := def_close;
    v_inj := replace(v_def,
$g$    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'WO_CLOSE_REASON_REQUIRED|%', v_wo.code;
    END IF;
$g$, '');
    IF v_inj = v_def THEN
        RAISE EXCEPTION 'FIXTURE 74 注入3 失败:在函数定义里没找到【收工理由必填】那道门的原文 —— 这个注入什么也没删';
    END IF;
    EXECUTE v_inj;
    -- 【注意这一注入触到了 CHECK 约束 —— 而那正是要它触到的】函数那道门删掉之后,
    -- 表上的 work_orders_closed_consistent 仍然拦住"关了却没有理由"。两道防线是
    -- 刻意的:函数是唯一写入口【今天】成立,而约束对任何写入者都成立。
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM close_work_order(woD, '');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg LIKE 'WO_CLOSE_REASON_REQUIRED%' THEN
        RAISE EXCEPTION 'FIXTURE 74 注入3 失败:删掉函数那道门之后,拒绝【仍然】来自函数(实得 %)—— 说明 C 臂拒它的不是那道门',
            COALESCE(v_msg, '(关掉了,而且约束也没拦 —— 那是第二个问题)');
    END IF;
    IF v_msg NOT LIKE '%work_orders_closed_consistent%' THEN
        RAISE EXCEPTION 'FIXTURE 74 注入3 失败:函数那道门删掉之后,应当由表上的 CHECK 兜住,实得 %', v_msg;
    END IF;

    -- ── 注入 4:删掉 create 的【重复物料】那道门 ───────────────────────────
    -- 前提:两行都合法、物料都在,只有"同一物料两次"这一件没满足。
    v_def := def_create;
    v_inj := replace(v_def,
$g$    IF v_mat IS NOT NULL THEN
        RAISE EXCEPTION 'WO_DUPLICATE_MATERIAL|%', v_mat;
    END IF;
$g$, '');
    IF v_inj = v_def THEN
        RAISE EXCEPTION 'FIXTURE 74 注入4 失败:在函数定义里没找到 WO_DUPLICATE_MATERIAL 那道门的原文 —— 这个注入什么也没删';
    END IF;
    EXECUTE v_inj;
    -- 【同样落到约束上,而不是建成功】—— 按名拒是文案,唯一约束才是兜底。
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM create_work_order(
        jsonb_build_array(jsonb_build_object('material_id', v_matA, 'planned_qty', 1),
                          jsonb_build_object('material_id', v_matA, 'planned_qty', 2)), NULL, NULL, NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg LIKE 'WO_DUPLICATE_MATERIAL%' THEN
        RAISE EXCEPTION 'FIXTURE 74 注入4 失败:删掉函数那道门之后,拒绝【仍然】来自函数(实得 %)—— 说明 B 臂拒它的不是那道门',
            COALESCE(v_msg, '(建成了,而且唯一约束也没拦 —— 那是第二个问题)');
    END IF;
    IF v_msg NOT LIKE '%work_order_lines_one_per_material%' THEN
        RAISE EXCEPTION 'FIXTURE 74 注入4 失败:函数那道门删掉之后,应当由唯一约束兜住,实得 %', v_msg;
    END IF;

    -- ══════════ 注入 5/6/7/8:四道【状态门】——  WO-1a 里唯一没有第二层的一类 ═══
    -- 【为什么这四道单独值得一组注入】前面四个注入里有两个(3 收工理由、4 重复物料)
    -- 删掉之后拒绝【没有消失】,只是落到了表上的 CHECK / UNIQUE —— 那是好事,
    -- 但也说明那两道门就算漏了也不会写坏数据。
    -- **状态门不一样:`status` 的 CHECK 只枚举【取值】,不约束【迁移】。**
    -- 所以一道状态门若失效,一次非法迁移是【真的会写进去】的。这一组注入要
    -- 验的正是这件事:门拿掉之后,那次调用不但不报错,而且【状态真的变了】。
    -- 每一个仍然从原样定义派生(def_* 在任何注入之前取的),一次只少一道门。

    -- ── 注入 5:close 的状态门(WO_NOT_RELEASED)────────────────────────────
    -- 重复 C 臂那次被拒的方向:关一张【草稿】。另起一张,因为前面几张都进终态了。
    v_res := create_work_order(
        jsonb_build_array(jsonb_build_object('material_id', v_matC, 'planned_qty', 2)), NULL, NULL, 'f74 inj5');
    woD := (v_res->>'work_order_id')::uuid;
    IF (SELECT status FROM work_orders WHERE id = woD) <> 'draft' THEN
        RAISE EXCEPTION 'FIXTURE 74 注入5 前提不成立:要的是一张【草稿】';
    END IF;
    v_inj := replace(def_close,
$g$    IF v_wo.status <> 'released' THEN
        -- draft 的单子要"不做了",走 cancel —— 见上面那张迁移表的最后一段
        RAISE EXCEPTION 'WO_NOT_RELEASED|%|%', v_wo.code, v_wo.status;
    END IF;
$g$, '');
    IF v_inj = def_close THEN
        RAISE EXCEPTION 'FIXTURE 74 注入5 失败:在函数定义里没找到 close 那道状态门的原文 —— 这个注入什么也没删';
    END IF;
    EXECUTE v_inj;
    PERFORM close_work_order(woD, '注入之后关一张草稿');
    SELECT status INTO v_status FROM work_orders WHERE id = woD;
    IF v_status <> 'closed' THEN
        RAISE EXCEPTION 'FIXTURE 74 注入5 失败:删掉 close 的状态门之后,草稿【仍然】没被关成 closed(实得 %)—— 说明 C 臂拒它的不是那道门',
            v_status;
    END IF;

    -- ── 注入 6:amend 的状态门(WO_NOT_AMENDABLE)──────────────────────────
    -- 重复 F 臂那次被拒的方向:改一张【已收工】的单。而这一臂断言的是
    -- 【行真的被改了】—— 状态门失效最贵的后果不是状态本身,是它放进来的那次写入。
    IF (SELECT status FROM work_orders WHERE id = woC) <> 'closed' THEN
        RAISE EXCEPTION 'FIXTURE 74 注入6 前提不成立:要的是一张【已收工】的单';
    END IF;
    SELECT planned_qty INTO v_qty FROM work_order_lines WHERE work_order_id = woC AND material_id = v_matA;
    v_inj := replace(def_amend,
$g$    IF v_wo.status NOT IN ('draft','released') THEN
        RAISE EXCEPTION 'WO_NOT_AMENDABLE|%|%', v_wo.code, v_wo.status;
    END IF;
$g$, '');
    IF v_inj = def_amend THEN
        RAISE EXCEPTION 'FIXTURE 74 注入6 失败:在函数定义里没找到 amend 那道状态门的原文 —— 这个注入什么也没删';
    END IF;
    EXECUTE v_inj;
    PERFORM amend_work_order(woC, '注入之后改一张收了工的单', NULL, false, NULL, false,
        jsonb_build_array(jsonb_build_object('material_id', v_matA, 'planned_qty', 99)), NULL);
    IF (SELECT planned_qty FROM work_order_lines WHERE work_order_id = woC AND material_id = v_matA) <> 99 THEN
        RAISE EXCEPTION 'FIXTURE 74 注入6 失败:删掉 amend 的状态门之后,已收工的单的计划行【仍然】没被改到 99(原值 %)—— 说明 F 臂拒它的不是那道门',
            v_qty;
    END IF;

    -- ── 注入 7:release 的状态门(WO_NOT_DRAFT)────────────────────────────
    -- 重复 C 臂那次被拒的方向:放行一张【已经放行过】的单。
    -- 【为什么不用"放行一张已收工的"】—— 那正是这一组注入意外量到的东西,
    -- 见注入 8 底下那段说明:closed → released 会撞上表上的
    -- work_orders_closed_consistent(closed_at 还在,而 status 不再是 closed),
    -- 于是它【有】第二层。released → released 没有那层遮挡,
    -- 是这道门唯一裸露的方向,所以它才是该被验的那一个。
    v_res := create_work_order(
        jsonb_build_array(jsonb_build_object('material_id', v_matC, 'planned_qty', 4)), NULL, NULL, 'f74 inj7');
    woE := (v_res->>'work_order_id')::uuid;
    PERFORM release_work_order(woE);
    UPDATE work_orders SET updated_by = NULL WHERE id = woE;   -- 让"写没写"看得见
    IF (SELECT status FROM work_orders WHERE id = woE) <> 'released'
       OR (SELECT updated_by FROM work_orders WHERE id = woE) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 74 注入7 前提不成立:要的是一张【已放行、且 updated_by 已清空】的单';
    END IF;
    v_inj := replace(def_release,
$g$    IF v_wo.status <> 'draft' THEN
        RAISE EXCEPTION 'WO_NOT_DRAFT|%|%', v_wo.code, v_wo.status;
    END IF;
$g$, '');
    IF v_inj = def_release THEN
        RAISE EXCEPTION 'FIXTURE 74 注入7 失败:在函数定义里没找到 release 那道状态门的原文 —— 这个注入什么也没删';
    END IF;
    EXECUTE v_inj;
    PERFORM release_work_order(woE);
    -- 【状态本来就是 released,所以"状态变了"验不出来 —— 验那次写入落地了没有】
    -- updated_by 被清空过,函数会把它写回来;还有多出来的那条 released 痕。
    IF (SELECT updated_by FROM work_orders WHERE id = woE) IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 74 注入7 失败:删掉 release 的状态门之后,那次写入【仍然】没落地 —— 说明 C 臂拒它的不是那道门';
    END IF;
    IF (SELECT count(*) FROM work_order_history
         WHERE work_order_id = woE AND change_type = 'released') <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 74 注入7 失败:第二次放行应当也留了一条痕(共两条)';
    END IF;

    -- ── 注入 8:cancel 的状态门(WO_NOT_CANCELLABLE)───────────────────────
    -- 重复 C 臂那次被拒的方向:取消一张【已取消】的单。
    -- 同样避开 closed → cancelled(那条路上有 closed_consistent 那层遮挡)。
    IF (SELECT status FROM work_orders WHERE id = woB) <> 'cancelled' THEN
        RAISE EXCEPTION 'FIXTURE 74 注入8 前提不成立:要的是一张【已取消】的单';
    END IF;
    v_inj := replace(def_cancel,
$g$    IF v_wo.status NOT IN ('draft','released') THEN
        RAISE EXCEPTION 'WO_NOT_CANCELLABLE|%|%', v_wo.code, v_wo.status;
    END IF;
$g$, '');
    IF v_inj = def_cancel THEN
        RAISE EXCEPTION 'FIXTURE 74 注入8 失败:在函数定义里没找到 cancel 那道状态门的原文 —— 这个注入什么也没删';
    END IF;
    EXECUTE v_inj;
    PERFORM cancel_work_order(woB, '注入之后把理由改掉');
    IF (SELECT cancel_reason FROM work_orders WHERE id = woB) <> '注入之后把理由改掉' THEN
        RAISE EXCEPTION 'FIXTURE 74 注入8 失败:删掉 cancel 的状态门之后,那次写入【仍然】没落地(取消理由没被盖掉)—— 说明 C 臂拒它的不是那道门';
    END IF;

    -- ── 这一组注入量到的一件没预料到的事,记在这里 ─────────────────────────
    -- 【"状态门没有第二层"只对了一半。】表上那两条一致性 CHECK
    -- (work_orders_closed_consistent / work_orders_cancelled_consistent)
    -- 顺带挡住了【所有从终态出去的迁移】:closed → released 会让 closed_at 还在
    -- 而 status 不再是 closed,cancelled → closed 同理 —— 两者都当场违反 CHECK。
    -- 它们不是为此写的(它们要的是"状态与它的证据同时成立"),但效果是真的。
    -- 所以裸露的其实只有【终态之内 / 尚未进终态】那几条边,上面四臂验的正是它们。
    -- 写下来是因为下一个人多半会先想到 closed → released,然后发现它撞的是 CHECK
    -- 而不是那道门,并以为注入写错了。
END $$;
ROLLBACK;
