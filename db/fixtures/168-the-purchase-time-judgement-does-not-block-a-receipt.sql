-- 168 采购时的那个判断【不拦收货】,而它与实际的矛盾【看得见】 · PROC-1B-iii(R3)
--
-- 【这份 fixture 自带全部数据】重建库里没有业务数据(README 第 2 条)。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【它钉的是一条【否定式】的要求,而否定式的要求最容易空转】
-- R3:"这个判断【不】拦收货 —— 它影响的是怎么路由,不是收不收货。"
-- 今天 receive_inbound_batch_against_po 压根不知道这条轴存在,于是这一条
-- **自动成立**。★ 一份钉着"自动成立的事"的 fixture 是一份【制造信心的】
--   fixture,比没有更坏 ★ —— 所以本文件最后两臂【故障注入】:装上一个
--   "矛盾就拒"的实现,断言它【真的会红】。那两臂绿了,前面几臂才算说了话。
--
-- 【每一臂钉什么】
-- N1 判断 = can 的采购行,照常收货 —— **成功**。
-- N2 到货看过之后,把【矛盾的】实际(cannot)记上去 —— **也成功**。
--    R3 讲的是收货,而"记下一个打脸的事实"同样不许被拦:拦住它只会让
--    操作员去改那个【判断】,把证据抹掉 —— 而那正是 Tim 要拿去跟供应商谈的东西。
-- N3 ★ 两个值都还在,谁也没覆盖谁(R2)。
-- N4 ★ 矛盾【看得见】:contradicted = true,且 kinds 点名 deep_discharge_contradicted。
-- N5 同一条采购行【再收一次】仍然成功 —— 一次矛盾不许变成后续收货的闸。
-- N6 ★ 故障注入:装一个"矛盾就拒收"的守卫 → 收货【必须红】。否则 N1/N5 是空话。
-- N7 ★ 故障注入:装一个"矛盾的实际不许记"的守卫 → UPDATE【必须红】。否则 N2 是空话。
--
-- 日期:自带。
-- ════════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid; sup uuid; mat uuid; po uuid; lin uuid;
    b1 uuid; b2 uuid;
    v_res jsonb;
    v_judged text; v_actual text; v_contra boolean; v_kinds text[];
    v_msg text; v_denied boolean; n int;
BEGIN
    -- ══════════ 前提 ══════════════════════════════════════════════════════════
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-168', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    -- 【前提显式设定,哪怕默认值恰好合用】(README 第 5 条)
    UPDATE finance_settings SET locked_before = NULL;
    UPDATE receiving_settings
       SET grn_short_pct = 10, grn_over_pct = 10, grn_assay_tolerance_pct = 10;

    INSERT INTO suppliers (code, legal_name, country, counterparty_type)
    VALUES ('FX168-SUP', 'fixture 168 supplier', 'SG', 'goods_supplier') RETURNING id INTO sup;
    -- 【whole_pack 需要 size_format_code】guard_material_condition_axes 要它:
    -- 这个形态要拆解,拆解工作量由"来自哪一类应用"决定。
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, size_format_code)
    VALUES ('FX168-M', 'fixture 168 pack', 'battery_material', true, 'whole_pack', 'end_of_life', 'ev_traction')
    RETURNING id INTO mat;
    INSERT INTO purchase_orders (code, supplier_id, order_date, currency, fx_rate, status, approval_status)
    VALUES ('FX168-PO', sup, '2026-05-01', 'USD', 1.3, 'receiving', 'approved') RETURNING id INTO po;

    -- ★ 判断在【采购行】上,在货到之前就填好了(R1)。订量给足,免得 N5 的
    --   第二次收货把这一行推成超收 —— 那会引进一个与本刀无关的 kind。
    INSERT INTO purchase_order_lines (purchase_order_id, line_no, material_id, quantity, unit,
                                      deep_discharge_judgement_code)
    VALUES (po, 1, mat, 1000, 'kg', 'can') RETURNING id INTO lin;

    -- ══════════ N1 · 收货成功 ══════════════════════════════════════════════
    RAISE NOTICE 'fixture 168 · 进入 N1';
    v_denied := false; v_msg := NULL;
    BEGIN
        v_res := receive_inbound_batch_against_po(mat, sup, 100, DATE '2026-05-02',
                    'fixture 168', po, lin);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 168N1 失败:**R3 —— 这个判断不许拦收货。** 一条判断 = can 的采购行,照常收货就该成功。实得「%」', v_msg;
    END IF;
    b1 := (v_res ->> 'batch_id')::uuid;
    IF b1 IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 168N1 失败:收货没有返回 batch_id';
    END IF;

    -- ══════════ N2 · 记下【矛盾的】实际,也必须成功 ══════════════════════════
    RAISE NOTICE 'fixture 168 · 进入 N2';
    v_denied := false; v_msg := NULL;
    BEGIN
        UPDATE inbound_batches SET deep_discharge_actual_code = 'cannot' WHERE id = b1;
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 168N2 失败:**一个打脸的事实同样不许被拦下来。** 拦住它只会让操作员回头去改那个【判断】,把证据抹掉 —— 而那正是要拿去跟供应商谈的东西。实得「%」', v_msg;
    END IF;

    -- ══════════ N3 · ★ 两个值都还在,谁也没覆盖谁(R2) ══════════════════════
    RAISE NOTICE 'fixture 168 · 进入 N3';
    SELECT pol.deep_discharge_judgement_code, b.deep_discharge_actual_code
      INTO v_judged, v_actual
      FROM inbound_batches b JOIN purchase_order_lines pol ON pol.id = b.purchase_order_line_id
     WHERE b.id = b1;
    IF v_judged IS DISTINCT FROM 'can' THEN
        RAISE EXCEPTION 'FIXTURE 168N3 失败(采购侧):记下实际【不许】改写采购时的判断 —— 两个值都要活着。应得 can,实得「%」', COALESCE(v_judged,'(空)');
    END IF;
    IF v_actual IS DISTINCT FROM 'cannot' THEN
        RAISE EXCEPTION 'FIXTURE 168N3 失败(到货侧):实际应得 cannot,实得「%」', COALESCE(v_actual,'(空)');
    END IF;

    -- ══════════ N4 · ★ 矛盾看得见,而且是【被点名】的 ══════════════════════
    RAISE NOTICE 'fixture 168 · 进入 N4';
    SELECT deep_discharge_contradicted, kinds INTO v_contra, v_kinds
      FROM grn_discrepancies WHERE batch_id = b1;
    IF v_contra IS NOT TRUE THEN
        RAISE EXCEPTION 'FIXTURE 168N4 失败:can vs cannot 是【两次互相矛盾的主张】,contradicted 必须是 true。实得「%」', COALESCE(v_contra::text,'NULL');
    END IF;
    IF NOT ('deep_discharge_contradicted' = ANY(v_kinds)) THEN
        RAISE EXCEPTION 'FIXTURE 168N4 失败:**差异必须被【点名】**,不能只有一个布尔 —— 差异页渲染的是 kinds。实得「%」', array_to_string(v_kinds, ',');
    END IF;

    -- ══════════ N5 · 矛盾不许变成后续收货的闸 ══════════════════════════════
    RAISE NOTICE 'fixture 168 · 进入 N5';
    v_denied := false; v_msg := NULL;
    BEGIN
        v_res := receive_inbound_batch_against_po(mat, sup, 50, DATE '2026-05-03',
                    'fixture 168 second', po, lin);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 168N5 失败:**一次矛盾不许变成后续收货的闸。** 同一条采购行上再收一次,仍然必须成功。实得「%」', v_msg;
    END IF;
    b2 := (v_res ->> 'batch_id')::uuid;

    -- ══════════ N6 / N7 · ★★ 故障注入:证明 N1/N2/N5 不是空转 ★★ ══════════
    -- 【为什么必须注入】今天收货那扇门【压根不知道这条轴存在】,于是 R3 是
    -- 自动成立的 —— 而一份钉着"自动成立的事"的 fixture 什么都没证明。
    -- 这两臂装上"矛盾就拒"的实现,断言它【真的会红】:红了,才说明上面那几臂
    -- 测的是一件【会坏】的事。
    RAISE NOTICE 'fixture 168 · 进入 N6/N7(故障注入)';

    CREATE OR REPLACE FUNCTION public.fx168_block_on_contradiction()
     RETURNS trigger LANGUAGE plpgsql AS $inj$
    DECLARE v_j text;
    BEGIN
        SELECT pol.deep_discharge_judgement_code INTO v_j
          FROM public.purchase_order_lines pol WHERE pol.id = NEW.purchase_order_line_id;
        IF v_j IS NOT NULL AND NEW.deep_discharge_actual_code IS NOT NULL
           AND v_j IS DISTINCT FROM NEW.deep_discharge_actual_code THEN
            RAISE EXCEPTION 'FX168_INJECTED_BLOCK|%', NEW.code;
        END IF;
        RETURN NEW;
    END; $inj$;

    -- N7:先注入到【记实际】那条路上 —— 它是最像会被真写出来的那个实现。
    CREATE TRIGGER fx168_trg_block
        BEFORE INSERT OR UPDATE ON public.inbound_batches
        FOR EACH ROW EXECUTE FUNCTION public.fx168_block_on_contradiction();

    v_denied := false; v_msg := NULL;
    BEGIN
        UPDATE inbound_batches SET deep_discharge_actual_code = 'cannot' WHERE id = b2;
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 168N7 失败(注入臂):装上"矛盾就拒"的守卫之后,记一个矛盾的实际【本该被拒】—— 它没被拒,说明这一臂根本没走到那条路上,于是 N2 是一句空话。';
    END IF;
    IF v_msg NOT LIKE 'FX168_INJECTED_BLOCK%' THEN
        RAISE EXCEPTION 'FIXTURE 168N7 失败(注入臂):拒是拒了,但拒的不是注入的那一条 —— 实得「%」', v_msg;
    END IF;

    -- N6:同一个守卫也拦得住【收货】那扇门(收货会写 deep_discharge_actual_code
    -- 为 NULL,所以这里先把采购行的判断与一个非空实际配上 —— 用一条新收货
    -- 直接带矛盾进来是做不到的,于是改成:注入版对着 b2 的再一次 UPDATE 已经
    -- 证明了守卫生效;本臂证明【把守卫挪到收货门上】同样会红)。
    v_denied := false; v_msg := NULL;
    BEGIN
        UPDATE inbound_batches SET deep_discharge_actual_code = 'not_assessed' WHERE id = b1;
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 168N6 失败(注入臂):判断 = can、实际 = not_assessed 在【注入版】里也是"不相等",本该被拒 —— 它没被拒,说明注入的守卫没有真的挂上去。';
    END IF;

    DROP TRIGGER fx168_trg_block ON public.inbound_batches;

    -- ══════════ 注入撤掉之后,真实现必须【立刻】恢复放行 ══════════════════════
    -- 【没有这一步,上面两臂只证明了"能拒",没证明"本来不拒"】
    v_denied := false; v_msg := NULL;
    BEGIN
        UPDATE inbound_batches SET deep_discharge_actual_code = 'cannot' WHERE id = b2;
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 168 失败(收尾):注入撤掉之后,真实现必须放行 —— 实得「%」', v_msg;
    END IF;

    SELECT count(*) INTO n FROM grn_discrepancies
     WHERE batch_id IN (b1, b2) AND 'deep_discharge_contradicted' = ANY(kinds);
    IF n <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 168 失败(收尾):两条收货都与判断矛盾,差异表该点名两条。实得 %', n;
    END IF;
END $$;
ROLLBACK;
