-- 86 一条被删的记录说得出【谁】和【为什么】—— 说不出时也要【按名说不出】
--
-- 【它守的是什么】AUDEL-1b 让软删记下谁与为什么;AUDEL-3 建了唯一能看见它们的
-- 那张视图 deleted_records。三件事必须同时成立,而它们各自会以不同的方式坏掉:
--   ① 删掉的行【出现在】视图里,带着它的人与理由;
--   ② AUDEL-1b 之前删的行【也出现】,而人与理由是 NULL —— 界面据此印
--      具名的「未记录」。**绝不留空、绝不猜**(FIN-26);线上 16 行已删记录里
--      有 14 行正是这一类,所以这不是假想的分支;
--   ③ 每一行跟着【它自己模块】的读权限:只持一个模块的读者【只看得见那一类】,
--      别的类【整类缺席】,而不是显示成零(/margin 那一课)。
--
-- 【为什么第 ③ 臂必须存在】这张视图是属主权限的:它自己读得到全部七张表。
-- 把外层那句 has_permission(permission) 删掉,页面会把【所有人删的所有东西】
-- 端给任何一个登录用户 —— 而那不会报错,只会多出几行。
--
-- 【本 fixture 以 postgres 跑】视图是属主权限 + 体内 has_permission(按 claims 解析,
-- 与数据库角色无关),所以权限臂不切 SET LOCAL ROLE 也有效 —— 与 fixture 28 同一条。
BEGIN;
DO $$
DECLARE
    v_all  uuid := gen_random_uuid();   -- 全部权限
    v_inb  uuid := gen_random_uuid();   -- 只有 module.inbound.view
    r_all uuid; r_inb uuid;
    sup uuid; mat uuid;
    ib_new uuid; ib_old uuid; ib_live uuid; ob uuid;
    rec record; n int; v_kinds text;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-86-all', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-86-inb', 'f', 'f', true) RETURNING id INTO r_inb;
    -- 【只给一个模块】—— 这一臂要证明的是模块边界,不是"什么都没有的人被拒"
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_inb, 'module.inbound.view');
    INSERT INTO user_roles (user_id, role_id) VALUES (v_all, r_all), (v_inb, r_inb);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_all), true);

    INSERT INTO suppliers (code, legal_name, country)
    VALUES ('FX86-SUP', 'fixture 86 supplier', 'SG') RETURNING id INTO sup;
    INSERT INTO materials (code, name, category)
    VALUES ('FX86-M', 'fixture 86 material', 'other') RETURNING id INTO mat;

    -- ── ① 走门删掉的批次:人与理由都在 ─────────────────────────────────────
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, unit, remaining_qty, arrival_date)
    VALUES ('FX86-IN-NEW', mat, sup, 10, 'kg', 10, '2026-05-01') RETURNING id INTO ib_new;
    INSERT INTO inventory_movements (inbound_batch_id, movement_type, qty_delta, business_date)
    VALUES (ib_new, 'receipt', 10, '2026-05-01');
    PERFORM soft_delete_inbound_batch(ib_new, '料受潮,整批报废');

    -- ── ② AUDEL-1b 【之前】那种行:deleted_at 有,两列为空 ───────────────────
    -- 【怎么造得出来,而且不用停任何触发器】守卫 guard_soft_delete_provenance 是
    -- BEFORE **UPDATE** 的 —— 它挡的是"把一条在册的行改成已删"。
    -- 一条【出生时就带着 deleted_at】的行根本不经过它。
    -- 这正好也是那 14 行历史记录的形状:它们的 deleted_at 是在守卫存在之前写下的,
    -- 今天读起来就是"有删除时刻、没有人、没有理由"。
    -- (第一版用了 ALTER TABLE ... DISABLE TRIGGER,撞上"pending trigger events";
    --  改用 SET CONSTRAINTS ALL IMMEDIATE 去结清又把库存恒等式提前引爆了。
    --  两条弯路都不必走 —— 直接插一行已删的就行。)
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, unit,
                                 remaining_qty, arrival_date, deleted_at)
    VALUES ('FX86-IN-OLD', mat, sup, 5, 'kg', 0, '2026-04-01', now())
    RETURNING id INTO ib_old;

    -- ── 一条【没有被删】的批次:C 臂靠它 ───────────────────────────────────
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, unit, remaining_qty, arrival_date)
    VALUES ('FX86-IN-LIVE', mat, sup, 7, 'kg', 7, '2026-05-02') RETURNING id INTO ib_live;
    INSERT INTO inventory_movements (inbound_batch_id, movement_type, qty_delta, business_date)
    VALUES (ib_live, 'receipt', 7, '2026-05-02');

    -- ── 另一个模块的一条,给权限臂用 ───────────────────────────────────────
    INSERT INTO output_batches (code, material_id, quantity, unit, remaining_qty, output_date)
    VALUES ('FX86-OUT', mat, 3, 'kg', 3, '2026-05-01') RETURNING id INTO ob;
    INSERT INTO inventory_movements (output_batch_id, movement_type, qty_delta, business_date)
    VALUES (ob, 'processing_produce', 3, '2026-05-01');
    PERFORM soft_delete_output_batch(ob, '产出记错了');

    -- ══════════ A. 走门删的那一条:人与理由都在,而且【是会话里那个人】═══════
    SELECT * INTO rec FROM deleted_records d WHERE d.code = 'FX86-IN-NEW';
    IF rec IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 86A 失败:走门删掉的批次没有出现在 deleted_records 里 —— 记下来却看不见,与没记下来一样';
    END IF;
    IF rec.record_kind <> 'inbound_batch' THEN
        RAISE EXCEPTION 'FIXTURE 86A 失败:种类应为 inbound_batch,实得 %', rec.record_kind;
    END IF;
    IF rec.deleted_by IS DISTINCT FROM v_all THEN
        RAISE EXCEPTION 'FIXTURE 86A 失败:操作人应为会话里那个人(%),实得 %', v_all, rec.deleted_by;
    END IF;
    IF rec.delete_reason <> '料受潮,整批报废' THEN
        RAISE EXCEPTION 'FIXTURE 86A 失败:理由应原样带出,实得 [%]', rec.delete_reason;
    END IF;
    -- 【台账那一半】注销流水必须挂得上 —— 删除在台账上的另一半就是它
    IF rec.movement_id IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 86A 失败:没有挂上那条 writeoff 流水 —— 删除在台账上的另一半不见了';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM inventory_movements m
                    WHERE m.id = rec.movement_id AND m.movement_type = 'writeoff'
                      AND m.inbound_batch_id = ib_new) THEN
        RAISE EXCEPTION 'FIXTURE 86A 失败:movement_id 指的不是这个批次的注销流水';
    END IF;

    -- ══════════ B. 老行:出现,而且两列【是 NULL】════════════════════════════
    -- 【断言 NULL 本身】—— 界面据此印具名的「未记录」。若这里变成一个非空值,
    -- 那就是有人回填了历史(FIN-26 明令不做),而页面会把它当成真的。
    SELECT * INTO rec FROM deleted_records d WHERE d.code = 'FX86-IN-OLD';
    IF rec IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 86B 失败:AUDEL-1b 之前删的行没有出现 —— 那 14 行历史记录会整批消失';
    END IF;
    IF rec.deleted_by IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 86B 失败:老行的 deleted_by 必须是 NULL(界面印「未记录」),实得 % —— 非空意味着有人回填了历史',
            rec.deleted_by;
    END IF;
    IF rec.delete_reason IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 86B 失败:老行的 delete_reason 必须是 NULL,实得 [%]', rec.delete_reason;
    END IF;

    -- ══════════ C. 没删的东西【不在】这里 ═══════════════════════════════════
    -- 【断言的对象必须是一条【同表、同种类、只差没被删】的行】——
    -- 第一版拿一个供应商去断言,而供应商压根不在这张视图的任何一支里:
    -- 那条断言【无论如何都成立】。故障注入当场证明了它:把
    -- `WHERE b.deleted_at IS NOT NULL` 整条拿掉,fixture 照样全绿。
    IF EXISTS (SELECT 1 FROM deleted_records d WHERE d.code = 'FX86-IN-LIVE') THEN
        RAISE EXCEPTION 'FIXTURE 86C 失败:一条【没有被删】的进料批次出现在已删除列表里 —— 那张页面会把在册的东西说成删掉了';
    END IF;

    -- ══════════ D. 权限:只持一个模块的读者【只看得见那一类】════════════════
    -- 全权读者两类都看得见(先证明这一点,否则 D 臂可能因为"本来就没有"而假绿)
    SELECT string_agg(DISTINCT d.record_kind, ',' ORDER BY d.record_kind) INTO v_kinds
      FROM deleted_records d WHERE d.code IN ('FX86-IN-NEW', 'FX86-OUT');
    IF v_kinds <> 'inbound_batch,output_batch' THEN
        RAISE EXCEPTION 'FIXTURE 86D 无效:全权读者应当同时看见两类,实得 % —— 那样 D 臂证明不了模块边界', v_kinds;
    END IF;

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_inb), true);
    IF NOT EXISTS (SELECT 1 FROM deleted_records d WHERE d.code = 'FX86-IN-NEW') THEN
        RAISE EXCEPTION 'FIXTURE 86D 失败:只持 module.inbound.view 的读者看不见进料那一类 —— 每一行本该跟着它自己模块的读权限';
    END IF;
    IF EXISTS (SELECT 1 FROM deleted_records d WHERE d.code = 'FX86-OUT') THEN
        RAISE EXCEPTION 'FIXTURE 86D 失败:只持 module.inbound.view 的读者看见了产出那一类 —— 无权的种类必须【整类缺席】';
    END IF;
    -- 而缺席不是"看见一个零" —— 那一类在结果里一行都没有
    SELECT count(*) INTO n FROM deleted_records d WHERE d.record_kind = 'output_batch';
    IF n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 86D 失败:产出那一类应当一行都没有,实得 % 行', n;
    END IF;

    -- ══════════ E. 一个模块都没有的读者:空,而不是报错 ═══════════════════════
    -- 【为什么是空而不是拒】这一页不属于任何模块 —— 它属于所有模块的交集,
    -- 而交集为空是一个正当的答案,由页面上那句具名空状态说出来。
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', gen_random_uuid()), true);
    SELECT count(*) INTO n FROM deleted_records;
    IF n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 86E 失败:一个模块都没有的读者看见了 % 行', n;
    END IF;
END $$;
ROLLBACK;
