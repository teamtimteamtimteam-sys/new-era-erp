-- 171 镜像方向【原样不动】;而【部分预留 = 整批拒】 · PROC-1B-iii(3c / 3d)
--
-- 【这份 fixture 自带全部数据】重建库里没有业务数据(README 第 2 条)。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【一、镜像方向:它不是本刀建的,本刀也【没有】改它 —— 这一臂就是那句话的凭据】
-- 先指定、后预留 → 在【预留那一刻】按名拒 SALE_BATCH_EARMARKED
-- (trg_so_reservations_form_saleable,PROC-BUILD-1 R5 就有了)。
-- ★ Tim 的裁定:R4 是【有方向的】。"客户的承诺压过工序指定"与"要许货给客户,
--   先把工序指定释放掉"是【同一条排序】—— 差别只在于释放由谁做,而答案是
--   【操作员】。一个悄悄毁掉一项没人同意毁掉的安排的系统,比一句响亮的、
--   带一步旁路的拒绝更坏。**所以这一侧原样留着,而 M1 保证它没被本刀碰坏。**
--
-- 【二、部分预留:整批拒,不在余量上放行 —— 这是一个裁定,不是一次保守】
-- purpose_code 是 output_batches 上的【一个列,作用于整批】。没有部分指定这种
-- 东西,也【没有子批模型】(它被明确挂起了)。于是"在余量上放行"落到库里
-- 只能是把【整批】翻成非可售 —— 连同已经许给客户的那 40kg;而那 40kg 接着
-- 会被 assert_output_batch_saleable 拦在发货门外。
-- ★★ 一次"部分放行"会把一句【守住了的承诺】变成一句【毁约】★★ ——
--    那正是 R4 存在要防的东西。整批拒是今天的模型唯一说得诚实的答案。
--
-- 【每一臂钉什么】
-- M1 ★ 镜像方向仍然按名拒 SALE_BATCH_EARMARKED,**且【不是】本刀那个新码** ——
--    两条拒绝各在各的方向上,没有互相顶掉。
-- M2 ★ 100kg 的批只许出去 40kg → 指定【整批被拒】。
-- M3 拒绝的话说的是【实情】:点的是许出去的 40,不是整批的 100。
-- M4 把那 40 释放掉 → 指定成功(旁路对部分预留同样通)。
-- M5 ★★ 故障注入:换成"只在【全批】被许出去时才拒"的守卫 → 部分预留那一条
--    【本该通过】。通了,才说明 M2 钉的是一个真裁定,而不是一次巧合。
--
-- 日期:自带。
-- ════════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid; v_ccy text; v_cust uuid; v_mat uuid;
    ob_mirror uuid; ob_part uuid;
    so uuid; L1 uuid; L2 uuid;
    d date := DATE '2027-03-05';
    v_msg text; v_denied boolean; v_purpose text; v_res_id uuid;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-171', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);
    UPDATE finance_settings SET locked_before = NULL;
    SELECT code INTO v_ccy FROM currencies WHERE is_base;

    INSERT INTO customers (code, legal_name, country)
    VALUES ('ZZ171-C', 'fixture 171 customer', 'SG') RETURNING id INTO v_cust;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, unit)
    VALUES ('ZZ171-M', 'f171 material', 'battery_material', true, 'black_mass', 'end_of_life', 'kg')
    RETURNING id INTO v_mat;

    ob_mirror := (create_output_batch(v_mat, 100, 'kg', d, '库存中', NULL, NULL, NULL, NULL) ->> 'batch_id')::uuid;
    ob_part   := (create_output_batch(v_mat, 100, 'kg', d, '库存中', NULL, NULL, NULL, NULL) ->> 'batch_id')::uuid;

    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES (next_sales_order_code(d), v_cust, d, v_ccy, 1) RETURNING id INTO so;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (so, 1, v_mat, 100, 10) RETURNING id INTO L1;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (so, 2, v_mat, 100, 10) RETURNING id INTO L2;
    PERFORM set_sales_order_status(so, 'confirmed');

    -- ══════════ M1 · ★ 镜像方向:先指定,后预留 —— 仍然按名拒 ══════════════
    -- 【这一臂不测本刀建的东西,它测的是"本刀没有把既有的东西碰坏"】
    RAISE NOTICE 'fixture 171 · 进入 M1(镜像方向)';
    PERFORM set_output_batch_purpose(ob_mirror, 'process_feed', 'battery_powder_line');

    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM reserve_stock(L1, ob_mirror, 10);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 171M1 失败:**镜像方向(先指定、后预留)从 PROC-BUILD-1 起就拒了,本刀不许把它碰坏。** 它通过了。';
    END IF;
    IF v_msg NOT LIKE 'SALE_BATCH_EARMARKED%' THEN
        RAISE EXCEPTION 'FIXTURE 171M1 失败:镜像那一侧必须【原样】抛 SALE_BATCH_EARMARKED —— 实得「%」。若这里变成了 BATCH_PROMISED_TO_CUSTOMER,说明两条拒绝顶掉了对方:它们各在各的方向上,谁也不该替谁说话。', v_msg;
    END IF;

    -- ══════════ M2 / M3 · ★★ 部分预留 → 整批拒,而且话说得是实情 ══════════
    RAISE NOTICE 'fixture 171 · 进入 M2/M3(部分预留)';
    v_res_id := (reserve_stock(L2, ob_part, 40) ->> 'reservation_id')::uuid;

    -- 前置:确实只许出去了一部分 —— 否则这一臂测的就是"全批"那个用例。
    IF (SELECT sum(qty) FROM sales_order_reservations
         WHERE output_batch_id = ob_part AND released_at IS NULL AND consumed_at IS NULL) <> 40
       OR (SELECT quantity FROM output_batches WHERE id = ob_part) <> 100 THEN
        RAISE EXCEPTION 'FIXTURE 171M2 前置失败:这一臂要的是【100 的批里许出去 40】';
    END IF;

    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM set_output_batch_purpose(ob_part, 'process_feed', 'battery_powder_line');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 171M2 失败:**部分预留也是整批拒。** 在"未预留的 60"上放行,落到库里只能是把整批翻成非可售 —— 连同已许出去的 40,而那 40 随后会被挡在发货门外。一次"部分放行"会把守住的承诺变成毁约。';
    END IF;
    IF v_msg NOT LIKE 'BATCH_PROMISED_TO_CUSTOMER%' THEN
        RAISE EXCEPTION 'FIXTURE 171M2 失败:应得 BATCH_PROMISED_TO_CUSTOMER,实得「%」', v_msg;
    END IF;
    -- M3:载荷第三段是【许出去的量】。说 100 是假话,而假话的拒绝会教人
    -- 去改一个根本没错的地方。
    IF split_part(v_msg, '|', 3) NOT LIKE '40%' THEN
        RAISE EXCEPTION 'FIXTURE 171M3 失败:拒绝的话要说实情 —— 许出去的是 40,不是整批的 100。实得载荷「%」', v_msg;
    END IF;
    SELECT purpose_code INTO v_purpose FROM output_batches WHERE id = ob_part;
    IF v_purpose IS DISTINCT FROM 'saleable_stock' THEN
        RAISE EXCEPTION 'FIXTURE 171M2 失败:被拒之后 purpose_code 必须原样不动,实得「%」', COALESCE(v_purpose,'(空)');
    END IF;

    -- ══════════ M4 · 旁路对部分预留同样通 ══════════════════════════════════
    RAISE NOTICE 'fixture 171 · 进入 M4(旁路)';
    PERFORM release_reservation(v_res_id, NULL, 'fixture 171 释放');
    PERFORM set_output_batch_purpose(ob_part, 'process_feed', 'battery_powder_line');
    SELECT purpose_code INTO v_purpose FROM output_batches WHERE id = ob_part;
    IF v_purpose IS DISTINCT FROM 'process_feed' THEN
        RAISE EXCEPTION 'FIXTURE 171M4 失败:把那 40 释放掉之后,指定必须通得过。实得「%」', COALESCE(v_purpose,'(空)');
    END IF;

    -- ══════════ M5 · ★★ 故障注入:证明 M2 钉的是一个真裁定 ★★ ══════════════
    -- 【注入的是那个"合理的另一种做法"】—— "只在【全批】都许出去时才拒,
    -- 否则在余量上放行"。这正是任务书 3d 列出的另一个选项,也是一个
    -- 下一个人很可能会写出来的实现。本臂断言它【真的会让部分预留通过】:
    -- 通了,说明 M2 分辨得出这两种做法;不通,说明 M2 在空转。
    RAISE NOTICE 'fixture 171 · 进入 M5(故障注入)';
    CREATE OR REPLACE FUNCTION public.guard_output_batch_not_promised()
     RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
    AS $inj$
    DECLARE v_saleable boolean; v_qty numeric;
    BEGIN
        SELECT p.is_saleable_stock INTO v_saleable
          FROM public.output_batch_purposes p WHERE p.code = NEW.purpose_code;
        IF v_saleable IS NOT FALSE THEN RETURN NEW; END IF;
        SELECT COALESCE(sum(r.qty),0) INTO v_qty FROM public.sales_order_reservations r
         WHERE r.output_batch_id = NEW.id AND r.released_at IS NULL AND r.consumed_at IS NULL;
        -- ★ 注入点:只在【全批】被许出去时才拒 —— 也就是"在余量上放行"。
        IF v_qty >= NEW.quantity THEN
            RAISE EXCEPTION 'BATCH_PROMISED_TO_CUSTOMER|injected|%|%', v_qty, NEW.code;
        END IF;
        RETURN NEW;
    END; $inj$;
    -- 函数侧那一份也要一并让路,否则它会先拦下来,测不到触发器那一层。
    CREATE OR REPLACE FUNCTION public.set_output_batch_purpose(p_output_batch_id uuid, p_purpose_code text, p_awaiting_operation_type_code text DEFAULT NULL::text)
     RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
    AS $inj$
    DECLARE v_saleable boolean;
    BEGIN
        PERFORM public.require_permission('module.processing.edit');
        SELECT is_saleable_stock INTO v_saleable FROM public.output_batch_purposes
         WHERE code = p_purpose_code AND is_active;
        -- 【"在等哪一道"照旧一并清掉】不清它,guard_output_batch_awaiting_operation
        -- 会先把这次写拦下来,于是这一臂根本走不到被测的那个守卫上。
        UPDATE public.output_batches
           SET purpose_code = p_purpose_code,
               awaiting_operation_type_code =
                   CASE WHEN v_saleable THEN NULL ELSE p_awaiting_operation_type_code END
         WHERE id = p_output_batch_id;
        RETURN jsonb_build_object('code', 'injected');
    END; $inj$;

    -- 重新做一次"100 的批里许出去 40"
    PERFORM set_output_batch_purpose(ob_part, 'saleable_stock');
    PERFORM reserve_stock(L2, ob_part, 40);

    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM set_output_batch_purpose(ob_part, 'process_feed', 'battery_powder_line');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 171M5 失败(注入臂):"只在全批被许出去时才拒"的实现,对着【100 里许了 40】的批【本该放行】—— 它没放行(「%」),说明 M2 分辨不出这两种做法,于是 M2 是一句空话。', v_msg;
    END IF;
END $$;
ROLLBACK;
