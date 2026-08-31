-- 170 许给客户的货,拒绝被指定成投料 —— 【按名,而且直插那条路也拒】 · PROC-1B-iii(R4)
--
-- 【这份 fixture 自带全部数据】重建库里没有业务数据(README 第 2 条)。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【它补的是一个【单向】的缺口 —— 这句话必须写在最前面】
-- 镜像那一侧(先指定、后预留)从 PROC-BUILD-1 起就在预留那一刻按名拒了
-- (trg_so_reservations_form_saleable → SALE_BATCH_EARMARKED)。**本刀一个字
-- 都没动它**,fixture 166 与 171M1 各自钉着它。
-- 缺的一直是这一侧:**先预留、后指定 —— 此前悄悄成功。**
--
-- 【每一臂钉什么】
-- N1 对照:**没有预留的批,指定成功。** 没有这一臂,一个"永远拒绝"的实现全绿
--    (fixture 63 F 臂的同一课)。
-- N2 ★ 有活预留的批 → 按名拒 BATCH_PROMISED_TO_CUSTOMER。
-- N3 ★ 这个名字与 assert_output_batch_saleable 那五条【销售】拒绝都不一样。
--    那五条讲"这一批能不能【卖】";本条讲反方向的一句话:"能不能被【拿去投料】"。
--    共用一个码,操作员读到的是一句与他正在做的事无关的话。
-- N4 ★★ **直插 UPDATE 那条路【也】被拒** —— output_batches 上有一条敞开的
--    UPDATE 策略(module.output.edit),守卫只放在函数里等于留了一扇没人看的门。
-- N5 ★★ **一个【看不见预留】的用户(有 processing.edit,没有 sales.view)
--    照样被拒。** 这一臂是 SECURITY DEFINER 那句话的凭据:一个 INVOKER 的守卫
--    会查到零行、安静放行 —— 那是 PROC-WIRE-1B-ii 刚修掉的缺陷原样重演。
-- N6 旁路真的存在:**释放预留之后,指定成功。** 一句"去释放"的拒绝,若释放
--    之后仍然不行,比不给旁路更坏。
-- N7 ★ 把指定【释放】回 saleable_stock 在有预留时【不许被拦】—— 拦它会把
--    镜像那一侧的旁路堵死(那一侧的 HINT 教的正是这一步)。
-- N8 ★★ 故障注入:换成 INVOKER 版守卫 + 拆掉触发器 → 那个盲用户的直插
--    【本该通过】。通了,才说明 N4/N5 测的是真东西。
--
-- 日期:自带。
-- ════════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    v_user  uuid := gen_random_uuid();   -- 全部权限
    u_blind uuid := gen_random_uuid();   -- processing.edit + output.edit,【没有】sales.view
    r_all uuid; r_blind uuid;
    v_ccy text; v_cust uuid; v_mat uuid;
    ob_free uuid; ob_res uuid; ob_blind uuid; ob_rel uuid;
    so uuid; L1 uuid; L2 uuid; L3 uuid;
    d date := DATE '2027-03-04';
    v_msg text; v_denied boolean; v_purpose text; n int;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-170-all', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);

    -- 【给加工与产出,【不】给销售】—— N5 要证明的是"看不见预留的人也被拒",
    -- 不是"什么权限都没有的人被拒"(那什么也证明不了)。
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-170-blind', 'f', 'f', true) RETURNING id INTO r_blind;
    INSERT INTO role_permissions (role_id, permission_code)
    VALUES (r_blind, 'module.processing.edit'), (r_blind, 'module.processing.view'),
           (r_blind, 'module.output.edit'), (r_blind, 'module.output.view');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_blind, r_blind);

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);
    UPDATE finance_settings SET locked_before = NULL;
    SELECT code INTO v_ccy FROM currencies WHERE is_base;

    INSERT INTO customers (code, legal_name, country)
    VALUES ('ZZ170-C', 'fixture 170 customer', 'SG') RETURNING id INTO v_cust;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, unit)
    VALUES ('ZZ170-M', 'f170 material', 'battery_material', true, 'black_mass', 'end_of_life', 'kg')
    RETURNING id INTO v_mat;

    ob_free  := (create_output_batch(v_mat, 100, 'kg', d, '库存中', NULL, NULL, NULL, NULL) ->> 'batch_id')::uuid;
    ob_res   := (create_output_batch(v_mat, 100, 'kg', d, '库存中', NULL, NULL, NULL, NULL) ->> 'batch_id')::uuid;
    ob_blind := (create_output_batch(v_mat, 100, 'kg', d, '库存中', NULL, NULL, NULL, NULL) ->> 'batch_id')::uuid;
    ob_rel   := (create_output_batch(v_mat, 100, 'kg', d, '库存中', NULL, NULL, NULL, NULL) ->> 'batch_id')::uuid;

    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES (next_sales_order_code(d), v_cust, d, v_ccy, 1) RETURNING id INTO so;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (so, 1, v_mat, 100, 10) RETURNING id INTO L1;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (so, 2, v_mat, 100, 10) RETURNING id INTO L2;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (so, 3, v_mat, 100, 10) RETURNING id INTO L3;
    PERFORM set_sales_order_status(so, 'confirmed');

    -- 三批各自被许出去(README 第 2 条:每臂自带数据,不共享可变状态)
    PERFORM reserve_stock(L1, ob_res,   100);
    PERFORM reserve_stock(L2, ob_blind, 100);
    PERFORM reserve_stock(L3, ob_rel,   100);

    -- ══════════ N1 · 对照:没有预留的批,指定【成功】 ════════════════════════
    RAISE NOTICE 'fixture 170 · 进入 N1(对照)';
    PERFORM set_output_batch_purpose(ob_free, 'process_feed', 'battery_powder_line');
    SELECT purpose_code INTO v_purpose FROM output_batches WHERE id = ob_free;
    IF v_purpose IS DISTINCT FROM 'process_feed' THEN
        RAISE EXCEPTION 'FIXTURE 170N1 失败(对照臂):没有预留的批必须指定得上 —— **没有这一臂,一个永远拒绝的实现会全绿**。实得「%」', COALESCE(v_purpose,'(空)');
    END IF;

    -- ══════════ N2 / N3 · ★ 有活预留 → 按名拒,而且名字是新的 ══════════════
    RAISE NOTICE 'fixture 170 · 进入 N2/N3';
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM set_output_batch_purpose(ob_res, 'process_feed', 'battery_powder_line');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 170N2 失败:**一批已经许给客户的货,不许被指定成下游工序的投料。** 它通过了 —— 这正是本刀要补的那个单向缺口。';
    END IF;
    IF v_msg NOT LIKE 'BATCH_PROMISED_TO_CUSTOMER%' THEN
        RAISE EXCEPTION 'FIXTURE 170N2 失败:拒是拒了,但【没有按名】—— 应得 BATCH_PROMISED_TO_CUSTOMER,实得「%」', v_msg;
    END IF;
    IF v_msg LIKE 'SALE\_%' THEN
        RAISE EXCEPTION 'FIXTURE 170N3 失败:这一条【不是】一条销售拒绝 —— 那五条讲"这一批能不能卖",本条讲"能不能被拿去投料"。共用一个码,操作员读到的是一句与他正在做的事无关的话。实得「%」', v_msg;
    END IF;
    -- 【拒绝之后,那一列一个字都没动】—— 一个"先写后拒"的实现在异常回滚之后
    -- 看起来也一样,但本臂在同一个事务里读,读得出它。
    SELECT purpose_code INTO v_purpose FROM output_batches WHERE id = ob_res;
    IF v_purpose IS DISTINCT FROM 'saleable_stock' THEN
        RAISE EXCEPTION 'FIXTURE 170N2 失败:被拒之后 purpose_code 必须原样不动,实得「%」', COALESCE(v_purpose,'(空)');
    END IF;

    -- ══════════ N4 · ★★ 直插 UPDATE 那条路【也】被拒 ══════════════════════
    RAISE NOTICE 'fixture 170 · 进入 N4(直插路径)';
    v_denied := false; v_msg := NULL;
    BEGIN
        UPDATE output_batches SET purpose_code = 'process_feed' WHERE id = ob_res;
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 170N4 失败:**直插 UPDATE 绕开了守卫。** output_batches 有一条敞开的 UPDATE 策略,把守卫只放在 set_output_batch_purpose 里,等于给这条规则留了一扇没人看的门。';
    END IF;
    IF v_msg NOT LIKE 'BATCH_PROMISED_TO_CUSTOMER%' THEN
        RAISE EXCEPTION 'FIXTURE 170N4 失败:直插被拒了,但拒的不是本条 —— 实得「%」', v_msg;
    END IF;

    -- ══════════ N5 · ★★ 看不见预留的用户,照样被拒 ══════════════════════════
    -- 【README 第 6 条:断言可见性的臂必须切数据库角色】postgres 是超级用户,
    -- RLS 对它完全不生效 —— 不切角色,INVOKER 版照样看得见,这一臂会假绿。
    RAISE NOTICE 'fixture 170 · 进入 N5(盲用户)';
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u_blind), true);
    EXECUTE 'SET LOCAL ROLE authenticated';

    -- 前置:这个用户【真的看不见】那条预留。看得见就什么也没证明。
    SELECT count(*) INTO n FROM sales_order_reservations WHERE output_batch_id = ob_blind;
    IF n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 170N5 前置失败:这个用户【本该看不见】任何预留行(它没有 sales.view)—— 实得 % 行,于是这一臂什么也证明不了', n;
    END IF;

    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM set_output_batch_purpose(ob_blind, 'process_feed', 'battery_powder_line');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 170N5 失败:**一个看不见预留的人把一批许出去的货指定成了投料。** 守卫必须是 SECURITY DEFINER —— 一个 INVOKER 的守卫会查到零行、安静放行,那是 PROC-WIRE-1B-ii 刚修掉的缺陷原样重演。';
    END IF;
    IF v_msg NOT LIKE 'BATCH_PROMISED_TO_CUSTOMER%' THEN
        RAISE EXCEPTION 'FIXTURE 170N5 失败:盲用户被拒了,但拒的不是本条(可能只是权限不足)—— 实得「%」', v_msg;
    END IF;

    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    -- ══════════ N7 · ★ 释放【指定】不许被拦(旁路要通) ══════════════════════
    RAISE NOTICE 'fixture 170 · 进入 N7';
    -- ob_free 现在是 process_feed 且【没有】预留;先给它加一条预留是做不到的
    -- (镜像那一侧会拒)—— 所以这一臂用 ob_res:它有预留,purpose 是
    -- saleable_stock,把它再设成 saleable_stock 必须【通过】。
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM set_output_batch_purpose(ob_res, 'saleable_stock');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 170N7 失败:**把一批货指回"可售库存"(也就是【释放指定】)在有预留时必须放行。** 拦住它会把镜像那一侧的旁路堵死 —— 而那一侧的 HINT 教操作员做的正是这一步。实得「%」', v_msg;
    END IF;

    -- ══════════ N6 · 旁路真的存在:释放预留之后,指定成功 ══════════════════
    RAISE NOTICE 'fixture 170 · 进入 N6(旁路)';
    PERFORM release_reservation(
        (SELECT id FROM sales_order_reservations
          WHERE output_batch_id = ob_rel AND released_at IS NULL AND consumed_at IS NULL),
        NULL, 'fixture 170 释放');   -- 【整行释放】p_qty = NULL
    PERFORM set_output_batch_purpose(ob_rel, 'process_feed', 'battery_powder_line');
    SELECT purpose_code INTO v_purpose FROM output_batches WHERE id = ob_rel;
    IF v_purpose IS DISTINCT FROM 'process_feed' THEN
        RAISE EXCEPTION 'FIXTURE 170N6 失败:**一句"去把预留释放掉"的拒绝,若释放之后仍然不行,比不给旁路更坏。** 实得「%」', COALESCE(v_purpose,'(空)');
    END IF;

    -- ══════════ N8 · ★★ 故障注入:证明 N4/N5 不是空转 ★★ ══════════════════
    -- 【换成 INVOKER 版守卫,并把触发器拆掉】—— 也就是"顺手写出来"的那个版本。
    -- 本臂断言:那个版本【真的会让盲用户的直插通过】。
    -- 它红了,说明那个"看不见的用户"其实看得见,于是 N4/N5 是两句空话。
    RAISE NOTICE 'fixture 170 · 进入 N8(故障注入)';
    DROP TRIGGER trg_output_batches_not_promised ON public.output_batches;
    CREATE OR REPLACE FUNCTION public.set_output_batch_purpose(p_output_batch_id uuid, p_purpose_code text, p_awaiting_operation_type_code text DEFAULT NULL::text)
     RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
    AS $inj$
    DECLARE v_saleable boolean; v_qty numeric;
    BEGIN
        PERFORM public.require_permission('module.processing.edit');
        SELECT is_saleable_stock INTO v_saleable FROM public.output_batch_purposes
         WHERE code = p_purpose_code AND is_active;
        IF v_saleable IS FALSE THEN
            -- ★ 注入点:这一句【没有】DEFINER 的可见性(它读的是调用者看得见的行)
            SELECT sum(r.qty) INTO v_qty FROM public.sales_order_reservations r
             WHERE r.output_batch_id = p_output_batch_id
               AND r.released_at IS NULL AND r.consumed_at IS NULL;
            IF v_qty IS NOT NULL AND v_qty > 0 THEN
                RAISE EXCEPTION 'BATCH_PROMISED_TO_CUSTOMER|injected';
            END IF;
        END IF;
        UPDATE public.output_batches SET purpose_code = p_purpose_code WHERE id = p_output_batch_id;
        RETURN jsonb_build_object('code', 'injected');
    END; $inj$;
    -- 【注入版必须是 INVOKER 才测得到那件事】上面写的是 DEFINER(签名要与线上
    -- 一致,preflight 的那条规矩),所以这里显式把它降成 INVOKER。
    ALTER FUNCTION public.set_output_batch_purpose(uuid, text, text) SECURITY INVOKER;

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u_blind), true);
    EXECUTE 'SET LOCAL ROLE authenticated';

    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM set_output_batch_purpose(ob_blind, 'process_feed', 'battery_powder_line');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 170N8 失败(注入臂):换成 INVOKER 版、拆掉触发器之后,那个盲用户【本该通过】—— 它没通过(「%」),说明这个用户其实看得见那条预留,于是 N5 是一句空话。', v_msg;
    END IF;

    EXECUTE 'RESET ROLE';
END $$;
ROLLBACK;
