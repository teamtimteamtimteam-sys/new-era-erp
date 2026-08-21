-- 44 信用管控的两个空白:【本单自己越限】与【规则的主语缺席】
--
-- 【A 臂是那条一直没人测的规则】没有任何既往敞口、单笔销售【自己】就超过限额 ——
-- 必须拒。fixture 39 每一臂都先垫上既往敞口再断言拒绝,于是"只比既往敞口、
-- 不含本单"的实现在那里【全绿】。走查报的正是这一形状(虽然真因是 B 臂)。
-- 注入方式:把 record_output_sale 的 v_exposure + v_amount_base > v_limit 改成
-- v_exposure > v_limit,本臂即红。
--
-- 【B 臂是主语缺席】fixture 39 的每一次 record_output_sale 都显式传了客户,
-- 所以它对"没有客户会怎样"一无所知 —— 而无客户时信用检查整段跳过。
-- 这与"空集合"的空转不同:集合不空,【主语没了】。AGENTS.md 记了这个形状。
--
-- 【C/D/E:无主销售的三件事】不查信用地落库(正当);开票点名拒;补挂单向、留痕、
-- 敞口随之上移,再挂一次即拒。
BEGIN;
DO $$
DECLARE
    u uuid := gen_random_uuid();
    r uuid;
    v_mat uuid; ob uuid; v_base text;
    c_fresh uuid; c_own uuid;
    v_denied boolean; v_msg text;
    v_sale jsonb; v_sale_id uuid; v_res jsonb;
    v_exposure numeric; v_n int; v_row record;
BEGIN
    SELECT code INTO v_base FROM currencies WHERE is_base;
    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-44', 'f', 'f', true) RETURNING id INTO r;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r, unnest(ARRAY['module.output.edit','module.output.view','module.finance.edit',
                           'module.finance.view','module.customers.view','data.view_prices']);
    INSERT INTO user_roles (user_id, role_id) VALUES (u, r);

    INSERT INTO materials (code, name, kind_code, may_be_processed)
    VALUES ('ZZFIX44-M', 'fixture 44 material', 'battery_material', true) RETURNING id INTO v_mat;
    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, output_date)
    VALUES ('ZZFIX44-OB', v_mat, 10000, 10000, '2027-10-01') RETURNING id INTO ob;

    -- 全新客户:限额 1,000,【敞口为零】—— A 臂的判别力全在"零"上
    INSERT INTO customers (code, legal_name, country, credit_limit_base)
    VALUES ('ZZFIX44-C1', 'fresh, nothing owed', 'SG', 1000) RETURNING id INTO c_fresh;
    INSERT INTO customers (code, legal_name, country, credit_limit_base)
    VALUES ('ZZFIX44-C2', 'attribution target', 'SG', 1000) RETURNING id INTO c_own;

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u), true);

    -- ══════════ A. 零敞口 + 单笔自己越限 → 拒 ═══════════════════════════════
    v_exposure := customer_ar_exposure_base(c_fresh);
    IF v_exposure <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 44A 前置失败:本臂要的是【零敞口】,实得 % —— 有既往敞口就测不出"本单自己越限"这件事', v_exposure;
    END IF;
    v_denied := false;
    BEGIN
        -- 1,397 本位币 > 限额 1,000,而既往敞口是 0
        PERFORM record_output_sale(ob, 100, 13.97, v_base, NULL, c_fresh, '2027-10-05'::date, NULL, 'manual', NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 44A 失败:零敞口客户的【第一笔】销售 1,397 就超过 1,000 的限额,必须拒 —— 只比既往敞口的实现会放行它,而那意味着限额从第二笔才开始起作用';
    END IF;
    IF v_msg NOT LIKE 'CREDIT_LIMIT_EXCEEDED|ZZFIX44-C1|1000|0|1397%' THEN
        RAISE EXCEPTION 'FIXTURE 44A 失败:拒绝要把四个数说全(限额|既往敞口|本单|合计),实得「%」', v_msg;
    END IF;

    -- 限额之内的第一笔照常过 —— 否则本臂只是"这客户什么都买不了"
    PERFORM record_output_sale(ob, 100, 5, v_base, NULL, c_fresh, '2027-10-05'::date, NULL, 'manual', NULL);

    -- ══════════ B. 主语缺席:无客户的销售【不查信用】,照常落库 ═══════════════
    v_sale := record_output_sale(ob, 100, 13.97, v_base, NULL, NULL, '2027-10-05'::date, NULL, 'manual', NULL);
    v_sale_id := (v_sale->>'sale_id')::uuid;
    SELECT customer_id INTO v_row FROM sales_records WHERE id = v_sale_id;
    IF v_row.customer_id IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 44B 失败:没传客户的销售不该凭空有主';
    END IF;
    -- 【这一臂是"允许",不是"拦截"】无主销售是正当的(客户还没登记就卖了货)。
    -- 它同时钉住:上面那 1,397 若挂到 C1 名下【本会被拒】,可见跳过的是整段检查。

    -- ══════════ C. 开票点名拒:无主销售不能开给客户 ═══════════════════════════
    v_denied := false;
    BEGIN
        PERFORM create_invoice(c_own, ARRAY[v_sale_id], '2027-10-06'::date, NULL, NULL, NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied OR v_msg NOT LIKE 'SALE_NOT_ATTRIBUTED|ZZFIX44-OB%' THEN
        RAISE EXCEPTION 'FIXTURE 44C 失败:无主销售开给客户应被 SALE_NOT_ATTRIBUTED 点名拒,实得 denied=% msg=% —— 发票说某人欠钱,而销售没记录这件事,正是 INV-2026-0005 的来历',
            v_denied, COALESCE(v_msg, '(通过)');
    END IF;

    -- ══════════ D. 补挂:不查信用、留痕、敞口随之上移 ═════════════════════════
    -- C2 限额 1,000,而这笔是 1,397 —— 【补挂必须成功】:它记录的是已经成立的债,
    -- 在这里查限额等于拒绝把一笔已经欠下的钱记进账。
    v_res := attribute_sale_customer(v_sale_id, c_own, 'fixture 44');
    IF (v_res->>'customer_code') <> 'ZZFIX44-C2' THEN
        RAISE EXCEPTION 'FIXTURE 44D 失败:补挂应返回接手的客户,实得 %', v_res;
    END IF;
    IF (v_res->>'over_limit')::boolean IS NOT TRUE THEN
        RAISE EXCEPTION 'FIXTURE 44D 失败:1,397 挂到 1,000 限额的客户名下,补挂应【如实报告】已经越限(而不是拒绝),实得 %', v_res->>'over_limit';
    END IF;
    SELECT customer_id INTO v_row FROM sales_records WHERE id = v_sale_id;
    IF v_row.customer_id <> c_own THEN
        RAISE EXCEPTION 'FIXTURE 44D 失败:补挂之后销售应当有主';
    END IF;
    v_exposure := customer_ar_exposure_base(c_own);
    IF v_exposure <> 1397 THEN
        RAISE EXCEPTION 'FIXTURE 44D 失败:补挂之后敞口应为 1,397(此前 0),实得 % —— 敞口不动,这笔债就仍然对信用管控隐形,而隐形正是本刀要修的病', v_exposure;
    END IF;
    SELECT count(*) INTO v_n FROM sales_attribution_log
     WHERE sales_record_id = v_sale_id AND customer_id = c_own AND exposure_after = 1397;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 44D 失败:补挂要留一行痕(含当时的敞口),实得 % 行', v_n;
    END IF;
    -- 补挂之后开票就通了 —— 出路存在,不是死路
    PERFORM create_invoice(c_own, ARRAY[v_sale_id], '2027-10-06'::date, NULL, NULL, NULL);

    -- ══════════ E. 单向:已有主的不许再挂、不许改投、不许退回 NULL ═════════════
    v_denied := false;
    BEGIN
        PERFORM attribute_sale_customer(v_sale_id, c_fresh, NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied OR v_msg NOT LIKE 'SALE_ALREADY_ATTRIBUTED|ZZFIX44-OB|ZZFIX44-C2%' THEN
        RAISE EXCEPTION 'FIXTURE 44E 失败:已有主的销售再挂给别人应被点名拒,实得 denied=% msg=% —— 把已存在的债改记到另一个人头上是另一种行为,不该从这条路够得着',
            v_denied, COALESCE(v_msg, '(通过)');
    END IF;
    -- 直改也不行(没有 ctx):留痕不能是自愿项
    v_denied := false;
    BEGIN
        UPDATE sales_records SET customer_id = c_fresh WHERE id = v_sale_id;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied OR v_msg <> 'SALE_IMMUTABLE' THEN
        RAISE EXCEPTION 'FIXTURE 44E 失败:绕过补挂函数直改 customer_id 应被 SALE_IMMUTABLE 拒,实得 denied=% msg=% —— 否则任何持 finance.edit 的人都能不留痕地改归属',
            v_denied, COALESCE(v_msg, '(通过)');
    END IF;
    -- 退回 NULL 同样不行
    v_denied := false;
    BEGIN
        PERFORM set_config('evoltrya.attribution_ctx', 'attribute_sale_customer', true);
        UPDATE sales_records SET customer_id = NULL WHERE id = v_sale_id;
        PERFORM set_config('evoltrya.attribution_ctx', '', true);
    EXCEPTION WHEN OTHERS THEN v_denied := true;
    END;
    PERFORM set_config('evoltrya.attribution_ctx', '', true);
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 44E 失败:即使带着 ctx,把客户退回 NULL 也必须拒 —— 单向就是单向';
    END IF;
    -- 留痕只增不改
    v_denied := false;
    BEGIN
        UPDATE sales_attribution_log SET customer_id = c_fresh WHERE sales_record_id = v_sale_id;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied OR v_msg NOT LIKE 'SALES_ATTRIBUTION_APPEND_ONLY|update%' THEN
        RAISE EXCEPTION 'FIXTURE 44E 失败:补挂留痕应只增不改且自己报名,实得 %', COALESCE(v_msg, '(通过)');
    END IF;
END $$;
ROLLBACK;
