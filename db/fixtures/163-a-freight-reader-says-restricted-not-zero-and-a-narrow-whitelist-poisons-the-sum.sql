-- 163 运费读取器:无权是【受限】不是 0 —— 而白名单开窄一格会毒化材料成本
--     PROC-COST-2
--
-- 【这份 fixture 自带全部数据】重建库里没有业务数据(README 第 2 条)。
--
-- 【它钉的是什么】batch_freight_base 曾是 SECURITY INVOKER,而它的函数体
-- JOIN freight_documents —— 那张表的 SELECT 策略是 inbound.view OR finance.view。
-- FRT-1 fu2 把它做成 INVOKER 的理由在当时成立(读它的只有运费自己那批人);
-- PROC-COST-1 在批次页上摆出落地成本拆解之后不再成立:**一个只有
-- module.processing.view 的读者第一次会去调它,JOIN 把每一行丢掉,函数安静地
-- 返回 0。** 而 `0.00` 与「受限」不是同一件事 —— 第一个是谎话(OPS-14 的 xmodule)。
--
-- A ★ 有权读者读到【真数】。
-- B ★ 只有 module.processing.view 的读者也读到真数 —— 修复前这里是 0。
-- C ★★ 与这件事【无关】权限的读者读到 **NULL(受限)**,不是 0。
--      这一臂靠 has_permission(不是 RLS),所以它不切数据库角色也是真的;
--      **但 B 臂靠的是 RLS**,不切角色就是在证明空话(README 第 6 条)。
--      两种臂在代码里长得一模一样,所以这里【一律切角色】。
-- D ★★★ **白名单开窄一格,会把一个【显示】缺陷变成一个更坏的【计值】缺陷。**
--      allocate_processing_costs 的材料成本表达式把这支函数写在一个【加法】里:
--          quantity_consumed * (unit_price + 运费/quantity + 加工成本/quantity)
--      一个 NULL 加数让整个加数变 NULL,`quantity_consumed * NULL` 是 NULL,
--      **SUM 于是跳过整条投料腿 —— 连它的 unit_price 一起**。
--      实测:材料成本从 750.00 掉到 **0.00**。
--      这一臂是【这一刀不许把事情弄得更糟】的那道闸,所以它注入一个窄白名单
--      并断言它确实变了 —— 一个不会变的注入证明不了任何事。
--
-- 【为什么白名单里有 module.processing.edit】allocate_processing_costs 第一行就是
-- require_permission('module.processing.edit'),所以它的调用者【必然】持有它 ——
-- 于是材料成本表达式里这一支【按构造】不可能是 NULL。这不是宽松,是承重。
--
-- 日期:自带。
BEGIN;
DO $$
DECLARE
    v_full   uuid := gen_random_uuid();
    v_proc   uuid := gen_random_uuid();   -- 只有 module.processing.view
    v_inb    uuid := gen_random_uuid();   -- 只有 module.inbound.view
    v_other  uuid := gen_random_uuid();   -- 只有 module.hr.view(与这件事无关)
    v_edit   uuid := gen_random_uuid();   -- 只有 module.processing.edit
    r_all uuid; r_proc uuid; r_inb uuid; r_oth uuid; r_edit uuid;
    v_ccy text; v_sup uuid; v_fwd uuid; v_mat uuid; v_matout uuid;
    v_ib uuid; v_run1 uuid; v_run2 uuid; v_d date := DATE '2027-12-06';
    v_x numeric; v_m numeric;
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fixture-163-all','f','f',true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id,permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id,role_id) VALUES (v_full,r_all);
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fixture-163-proc','f','f',true) RETURNING id INTO r_proc;
    INSERT INTO role_permissions (role_id,permission_code) VALUES (r_proc,'module.processing.view');
    INSERT INTO user_roles (user_id,role_id) VALUES (v_proc,r_proc);
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fixture-163-inb','f','f',true) RETURNING id INTO r_inb;
    INSERT INTO role_permissions (role_id,permission_code) VALUES (r_inb,'module.inbound.view');
    INSERT INTO user_roles (user_id,role_id) VALUES (v_inb,r_inb);
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fixture-163-oth','f','f',true) RETURNING id INTO r_oth;
    INSERT INTO role_permissions (role_id,permission_code) VALUES (r_oth,'module.hr.view');
    INSERT INTO user_roles (user_id,role_id) VALUES (v_other,r_oth);
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fixture-163-edit','f','f',true) RETURNING id INTO r_edit;
    INSERT INTO role_permissions (role_id,permission_code) VALUES (r_edit,'module.processing.edit');
    INSERT INTO user_roles (user_id,role_id) VALUES (v_edit,r_edit);

    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}',v_full), true);
    INSERT INTO suppliers (code,legal_name,country,status,counterparty_type)
    VALUES ('ZZ163-S','f','SG','active','goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO suppliers (code,legal_name,country,status,counterparty_type)
    VALUES ('ZZ163-F','f','SG','active','forwarder') RETURNING id INTO v_fwd;
    INSERT INTO materials (code,name,kind_code,may_be_processed,form_code,source_code,size_format_code)
    VALUES ('ZZ163-M','f163 pack','battery_material',true,'whole_pack','end_of_life','ev_traction') RETURNING id INTO v_mat;
    INSERT INTO materials (code,name,kind_code,may_be_processed,form_code,source_code,size_format_code)
    VALUES ('ZZ163-O','f163 powder','battery_material',true,'black_mass','end_of_life',NULL) RETURNING id INTO v_matout;

    -- 200kg @ 5,运费 500 → 单位运费 2.50
    INSERT INTO inbound_batches (code,material_id,supplier_id,quantity,remaining_qty,unit,arrival_date, source_reason_code, source_reason_note)
    VALUES ('ZZ163-A',v_mat,v_sup,200,200,'kg',v_d-1, 'other', 'fixture 163 自带数据') RETURNING id INTO v_ib;
    UPDATE inbound_batches SET chemistry_certainty_code='single_known' WHERE id=v_ib;
    INSERT INTO inbound_batch_safety_states (inbound_batch_id,safety_state_code) VALUES (v_ib,'discharged_verified');
    PERFORM reprice_inbound_batch(v_ib,5,v_ccy,NULL,'f163');
    PERFORM record_freight_document(v_d,v_fwd,500,v_ccy,'weight','unpaid',NULL,
        jsonb_build_array(jsonb_build_object('inbound_batch_id',v_ib)),'f163');

    -- ══════════ A · 有权读者(inbound.view)读到真数 ══════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}',v_inb), true);
    EXECUTE 'SET LOCAL ROLE authenticated';  v_x := batch_freight_base(v_ib);  RESET ROLE;
    IF v_x IS DISTINCT FROM 500.00 THEN
        RAISE EXCEPTION 'FIXTURE 163A 失败:inbound.view 读者应读到 500.00,实得 %', COALESCE(v_x::text,'NULL');
    END IF;

    -- ══════════ B · ★ processing.view 读者也读到真数(修复前是 0)★ ══════════
    -- 【这一臂靠 RLS,所以【必须】切数据库角色】—— postgres 是超级用户,
    -- 不切角色的话 RLS 根本不生效,注入旧版之后这一臂照样绿(README 第 6 条,
    -- fixture 26 第一版栽的就是这里)。
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}',v_proc), true);
    EXECUTE 'SET LOCAL ROLE authenticated';  v_x := batch_freight_base(v_ib);  RESET ROLE;
    IF v_x IS DISTINCT FROM 500.00 THEN
        RAISE EXCEPTION 'FIXTURE 163B 失败:**只有 module.processing.view 的读者(批次页上的落地成本拆解)必须读到真数 500.00**,实得 % —— 一个 SECURITY INVOKER 的实现在这里安静地返回 0,而屏幕上那批货身上明明挂着 500', COALESCE(v_x::text,'NULL');
    END IF;

    -- ══════════ C · ★★ 无权是【NULL = 受限】,不是 0 ★★ ══════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}',v_other), true);
    EXECUTE 'SET LOCAL ROLE authenticated';  v_x := batch_freight_base(v_ib);  RESET ROLE;
    IF v_x IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 163C 失败:无权读者必须得到 **NULL(受限)**,实得 % —— `0.00` 与「受限」不是同一件事:第一个是谎话。界面靠这个 NULL 才分得开"这批货没花过运费"与"你看不到"。', v_x;
    END IF;

    -- ══════════ D · ★★★ 窄白名单毒化材料成本 ★★★ ══════════
    -- 两张一模一样的转化型单,各吃 100kg;正确白名单下材料成本
    --   = 100 × (5 + 500/200) = 750.00
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}',v_full), true);
    v_run1 := commit_processing_run(v_d,'f163 粉料线 1',20,
        jsonb_build_array(jsonb_build_object('inbound_batch_id',v_ib,'quantity_consumed',100)),
        jsonb_build_array(jsonb_build_object('material_id',v_matout,'quantity',80,'unit','kg')),
        'weight',NULL,NULL,'battery_powder_line');
    v_run2 := commit_processing_run(v_d,'f163 粉料线 2',20,
        jsonb_build_array(jsonb_build_object('inbound_batch_id',v_ib,'quantity_consumed',100)),
        jsonb_build_array(jsonb_build_object('material_id',v_matout,'quantity',80,'unit','kg')),
        'weight',NULL,NULL,'battery_powder_line');

    -- 【由一个【只持 processing.edit】的人来分摊】—— 那正是白名单里那一格挡的场景
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}',v_edit), true);
    PERFORM allocate_processing_costs(v_run1,'weight');
    SELECT material_cost_base INTO v_m FROM processing_runs WHERE id=v_run1;
    IF v_m <> 750.00 THEN
        RAISE EXCEPTION 'FIXTURE 163D 前置失败:正确白名单下材料成本应为 750.00(= 100 × (5 + 500/200)),实得 % —— 前置不成立,后面的注入证明不了任何事', v_m;
    END IF;

    -- 注入:把 processing.view / processing.edit 从白名单里拿掉
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}',v_full), true);
    CREATE OR REPLACE FUNCTION public.batch_freight_base(p_inbound_batch_id uuid)
    RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public','pg_temp' AS $inj$
        SELECT CASE
            WHEN has_permission('module.inbound.view')
              OR has_permission('module.finance.view')
            THEN batch_freight_base_all(p_inbound_batch_id)
            ELSE NULL
        END;
    $inj$;

    -- 【先断言注入确实改变了什么】—— 一个不会变的注入证明不了任何事
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}',v_edit), true);
    v_x := batch_freight_base(v_ib);
    IF v_x IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 163D 注入无效:窄白名单下只持 processing.edit 的人应读到 NULL,实得 % —— 这一臂在空转', v_x;
    END IF;

    PERFORM allocate_processing_costs(v_run2,'weight');
    SELECT material_cost_base INTO v_m FROM processing_runs WHERE id=v_run2;
    IF v_m = 750.00 THEN
        RAISE EXCEPTION 'FIXTURE 163D 失败(空转):窄白名单【没有】改变材料成本,说明 NULL 并没有毒化求和 —— 这一臂的结论要重新测量,不要照抄';
    END IF;
    IF v_m <> 0.00 THEN
        RAISE EXCEPTION 'FIXTURE 163D 失败:窄白名单下材料成本应整条腿消失(0.00),实得 % —— 断言的是【机制】:一个 NULL 加数让 SUM 跳过整条投料腿,连它的 unit_price(500)一起', v_m;
    END IF;
    RAISE NOTICE 'fixture 163D · 已证:白名单开窄一格,材料成本从 750.00 掉到 0.00 —— 连采购价一起丢掉。这就是白名单里 processing.edit 那一格挡的事。';

    RAISE NOTICE 'fixture 163 · 全部通过';
END $$;
ROLLBACK;
