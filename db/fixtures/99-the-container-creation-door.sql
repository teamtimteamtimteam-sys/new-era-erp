-- 99 集装箱的创建门 —— 以及"唯一的门"这句话【实际由什么保证】
--
-- LOG-2c。create_container 照 ship_order 的形状:权限在体内第一步、取号在体内、
-- 最后 INSERT。本 fixture 钉住那三件事,外加一件【与计划里的说法不同】的事实:
--
-- 【计划说"containers 没有 INSERT 策略,函数是唯一的门"—— 那句话对 shipments 成立,
--   对 containers 不成立】。LOG-2a 给 containers 装的是 FOR ALL 的写策略
--   (WITH CHECK has_permission('module.purchasing.edit')),所以一个【有权限的】
--   会话直接 INSERT 是过得去的。
--   **真正保证"必须走这扇门"的,是无缝取号器被收权了** —— 直接插的人拿不到号,
--   而 code 是 NOT NULL UNIQUE。他可以编一个号,但那样就不再无缝,
--   而无缝正是这扇门存在的理由。D 臂把这件事按实际情况断言,不按计划里的说法断言。
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    u_ok uuid := gen_random_uuid(); u_no uuid := gen_random_uuid();
    r_ok uuid; r_no uuid; p1 uuid; p2 uuid; lane uuid;
    v1 jsonb; v2 jsonb; v_msg text; v_denied boolean; v_n integer;
    c1 text; c2 text; v_row record;
BEGIN
    INSERT INTO auth.users (id) VALUES (u_ok), (u_no);
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fixture-99-ok','f99','f99',true) RETURNING id INTO r_ok;
    INSERT INTO role_permissions (role_id, permission_code) VALUES
        (r_ok,'module.purchasing.view'), (r_ok,'module.purchasing.edit');
    -- 【没有 purchasing 权限,但【有别的权限】】—— 否则"被拒"可能只是"他什么都没有"
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fixture-99-no','f99','f99',true) RETURNING id INTO r_no;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_no,'module.sales.view');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_ok, r_ok), (u_no, r_no);

    INSERT INTO ports (code, name) VALUES ('FX99PA','fixture 99 a') RETURNING id INTO p1;
    INSERT INTO ports (code, name) VALUES ('FX99PB','fixture 99 b') RETURNING id INTO p2;
    INSERT INTO lanes (origin_port_id, destination_port_id) VALUES (p1, p2) RETURNING id INTO lane;

    -- ══════════ A. 有权限的人建得出来,而且号是无缝的 ═══════════════════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_ok), true);
    v1 := create_container(lane, DATE '2026-08-20', 'FX99U0000001', 'FX99 Vessel', 'V1', NULL, 'FX99-BL-1', 'fixture 99');
    v2 := create_container(lane, DATE '2026-08-20', 'FX99U0000002', NULL, NULL, NULL, NULL, NULL);
    c1 := v1->>'code'; c2 := v2->>'code';

    SELECT * INTO v_row FROM containers WHERE id = (v1->>'id')::uuid;
    IF v_row.container_number <> 'FX99U0000001' OR v_row.vessel <> 'FX99 Vessel'
       OR v_row.voyage <> 'V1' OR v_row.bl_number <> 'FX99-BL-1'
       OR v_row.lane_id <> lane OR v_row.departure_date <> DATE '2026-08-20' THEN
        RAISE EXCEPTION 'FIXTURE 99A 失败:建出来的行不完整 —— %', to_jsonb(v_row)::text;
    END IF;

    -- 【无缝】:两次调用的序号必须连着
    IF split_part(c2,'-',3)::integer <> split_part(c1,'-',3)::integer + 1 THEN
        RAISE EXCEPTION 'FIXTURE 99A 失败:两次调用的号不连(% → %)—— 无缝正是这扇门的理由', c1, c2;
    END IF;
    IF c1 NOT LIKE 'CTR-2026-%' THEN
        RAISE EXCEPTION 'FIXTURE 99A 失败:号段不对(%)', c1;
    END IF;
    RAISE NOTICE '99A 建得出、行完整、号无缝(% → %)✓', c1, c2;

    -- ══════════ B. 没有那个模块权限的人:按名拒绝(前提已由 A 证明) ═════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_no), true);
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM create_container(lane, DATE '2026-08-20', 'FX99U0000003', NULL, NULL, NULL, NULL, NULL);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR position('PERMISSION_DENIED' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 99B 失败:没有 module.purchasing.edit 的人竟然建得出箱子 —— 实得:%', COALESCE(v_msg,'(没有拒绝)');
    END IF;
    RAISE NOTICE '99B 无权限者被按名拒绝 ✓(%)', left(v_msg, 50);

    -- ══════════ C. 开航日缺席:按名拒绝,不是 23502 ═════════════════════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_ok), true);
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM create_container(lane, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR position('CONTAINER_DEPARTURE_DATE_REQUIRED' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 99C 失败:缺开航日没有【按名】拒绝(23502 对操作员不可读)—— 实得:%', COALESCE(v_msg,'(没有拒绝)');
    END IF;
    RAISE NOTICE '99C 缺开航日按名拒绝 ✓';

    -- ══════════ D. "唯一的门"由【取号】保证,不由策略保证 ════════════════════
    -- D1:没有权限的人直接 INSERT —— RLS 挡住(写策略的 WITH CHECK)
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_no), true);
    v_denied := false; v_msg := NULL;
    BEGIN
        EXECUTE 'SET LOCAL ROLE authenticated';
        INSERT INTO containers (code, departure_date) VALUES ('CTR-2026-9998', DATE '2026-08-20');
        RESET ROLE;
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; RESET ROLE;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 99D1 失败:没有权限的人直接插进 containers 了 —— 写策略没有起作用';
    END IF;

    -- D2:【有权限的人直接 INSERT 是过得去的】—— 计划里"没有 INSERT 策略"那句话
    --     对 containers 不成立。所以这一臂断言的是【实际的保证在哪里】:
    --     他插得进去,但他【拿不到号】(取号器对 authenticated 收权),
    --     只能自己编一个 —— 而那就不再无缝。
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_ok), true);
    v_denied := false; v_msg := NULL;
    BEGIN
        EXECUTE 'SET LOCAL ROLE authenticated';
        PERFORM next_container_code(DATE '2026-08-20');
        RESET ROLE;
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; RESET ROLE;
    END;
    IF NOT v_denied OR position('permission denied for function next_container_code' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 99D2 失败:取号器竟然对 authenticated 开着 —— 那这扇门就不是唯一的路了。实得:%', COALESCE(v_msg,'(没有拒绝)');
    END IF;
    RAISE NOTICE '99D 无权限者插不进;有权限者插得进却【取不到号】—— 无缝由收权保证 ✓';

    RAISE NOTICE 'FIXTURE 99 全部通过';
END $$;
ROLLBACK;
