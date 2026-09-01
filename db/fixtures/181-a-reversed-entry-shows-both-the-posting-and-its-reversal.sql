-- 181 一笔被冲销的分录,轨迹上【两条都在】—— 过账,以及它的冲销
--
-- AUDIT-1 · 定义之完成第二条。这是本刀最想消灭的那个「错的好消息」:
--
-- 线上实测 JE-2026-0003 的 source_id = 批次、status='reversed';
-- 而它的冲销 JE-2026-0004 的 source_id 指向【那笔分录】,不是批次。
-- 于是一张老老实实 `WHERE source_id = 批次.id` 的轨迹,看得见那笔过账、
-- **看不见它已经被冲掉了** —— 屏幕上这个批次还挂着一笔定价分录。
-- 这与 AUD-1 是同一个家族的错的好消息,只是这次长在审计轨迹里。
--
-- 修法不是 schema 改动:journal_entries.reversed_by 【本来就】从过账指向冲销
-- (线上 13 对全部有值)。轨迹必须知道去跟这一跳,而且【只能】跟这一跳 ——
-- 绝不去解析 memo 里那句英文 'REVERSAL: …':memo 是人打的自由文本,
-- 依赖它拼法的轨迹会在第一个换个说法的人手上安静地坏掉。
--
-- 【故障注入】C 臂把 reversed_by 打断,先证明这条断言【看得见】那一跳。
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid; v_mat uuid; v_sup uuid; v_ib uuid;
    v_post uuid; v_rev uuid; v_post2 uuid; v_rev2 uuid; v_post3 uuid; v_rev3 uuid;
    n_post int; n_rev int; n_seam int;
BEGIN
    INSERT INTO auth.users (id) VALUES (v_user);
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-181','f','f',true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZFIX181-S','fixture 181 supplier','SG','active','goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZFIX181-M','fixture 181 material','battery_material',true,'black_mass','end_of_life')
    RETURNING id INTO v_mat;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty,
        arrival_date, unit_price, source_reason_code, source_reason_note)
    VALUES ('ZZFIX181-IB', v_mat, v_sup, 100, 100, DATE '2027-01-05', 10, 'other', 'fixture 181 自带数据') RETURNING id INTO v_ib;

    -- 复刻线上那一对的【形状】:过账挂批次,冲销挂【那笔过账】。
    -- 【顺序是被 guard_journal_entry_mutation 逼出来的】journal_entries 是不可变的
    -- (JOURNAL_IMMUTABLE),UPDATE 一律被拒 —— 所以 reversed_by 必须在 INSERT 的
    -- 那一刻就带上,先建冲销件、再建过账件。这一条本身值得记:分录只能【出生时】
    -- 就说清自己被谁冲销,而不是事后补一句。
    v_post := gen_random_uuid();
    INSERT INTO journal_entries (id, code, entry_date, memo, source_type, source_id, status)
    VALUES (gen_random_uuid(), 'ZZFIX181-JE2', DATE '2027-01-06',
            'REVERSAL: Pricing ZZFIX181-IB', 'purchase', v_post, 'posted')
    RETURNING id INTO v_rev;
    INSERT INTO journal_entries (id, code, entry_date, memo, source_type, source_id, status, reversed_by)
    VALUES (v_post, 'ZZFIX181-JE1', DATE '2027-01-06',
            'Pricing ZZFIX181-IB', 'purchase', v_ib, 'reversed', v_rev);

    -- ══════════ A. 过账【和】冲销都出现在这个批次的轨迹上 ═══════════════════
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO n_post FROM batch_audit_trail
     WHERE batch_id = v_ib AND batch_kind='inbound' AND source_id = v_post;
    SELECT count(*) INTO n_rev FROM batch_audit_trail
     WHERE batch_id = v_ib AND batch_kind='inbound' AND source_id = v_rev;
    RESET ROLE;

    IF n_post <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 181A 失败:过账那一笔没有出现在轨迹上(实得 % 行)', n_post;
    END IF;
    -- ★ 这一句就是本 fixture 的全部理由 ★
    IF n_rev <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 181A 失败:**冲销没有出现** —— 轨迹在说一个错的好消息:这个批次看起来还挂着一笔分录,而它已经被冲掉了(实得 % 行)', n_rev;
    END IF;
    RAISE NOTICE '181A 过账与冲销两条都在 ✓';

    -- ══════════ B. 两条各自带对了接缝标记 ═════════════════════════════════
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO n_seam FROM batch_audit_trail
     WHERE batch_id = v_ib AND source_id = v_post AND 'reversed' = ANY (seams);
    IF n_seam <> 1 THEN
        RESET ROLE;
        RAISE EXCEPTION 'FIXTURE 181B 失败:过账那一行没有标 reversed —— 读者无从知道它已被冲销';
    END IF;
    SELECT count(*) INTO n_seam FROM batch_audit_trail
     WHERE batch_id = v_ib AND source_id = v_rev AND 'is_reversal' = ANY (seams);
    RESET ROLE;
    IF n_seam <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 181B 失败:冲销那一行没有标 is_reversal';
    END IF;
    RAISE NOTICE '181B 两行各自的接缝标记都在 ✓';

    -- ══════════ C. 【故障注入】另造一对【不带 reversed_by】的,冲销必须缺席 ═══
    -- 注入若改不动结果,A 臂就是在空转。分录不可变,所以注入的做法不是
    -- UPDATE 掉那一跳,而是【造一对少了那一跳的】—— 同样的形状,同样挂在同一个
    -- 批次上,唯一的差别就是 reversed_by 是空的。
    v_post2 := gen_random_uuid();
    INSERT INTO journal_entries (id, code, entry_date, memo, source_type, source_id, status)
    VALUES (gen_random_uuid(), 'ZZFIX181-JE4', DATE '2027-01-07',
            'REVERSAL: second pricing', 'purchase', v_post2, 'posted')
    RETURNING id INTO v_rev2;
    INSERT INTO journal_entries (id, code, entry_date, memo, source_type, source_id, status)
    VALUES (v_post2, 'ZZFIX181-JE3', DATE '2027-01-07',
            'Pricing again', 'purchase', v_ib, 'reversed');   -- ← reversed_by 【留空】

    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO n_rev FROM batch_audit_trail
     WHERE batch_id = v_ib AND batch_kind='inbound' AND source_id = v_rev2;
    RESET ROLE;
    IF n_rev <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 181C 失败:少了 reversed_by 的那一件冲销【仍然】看得见 —— 那说明它不是靠这一跳到达的,A 臂没有在测它以为在测的东西(实得 % 行)', n_rev;
    END IF;
    RAISE NOTICE '181C 注入确实改变了结果(没有 reversed_by → 冲销缺席)—— A 臂测的正是那一跳 ✓';

    -- ══════════ D. 【绝不解析 memo】memo 里一个 REVERSAL 字样都没有,照样要在 ═
    -- 线上今天唯一能靠自己认出这层关系的东西,是那句英文 memo 'REVERSAL: …'。
    -- 一条依赖它拼法的轨迹,会在第一个换个说法的人手上【安静地】坏掉。
    -- 所以这一臂造一对 memo 完全不提冲销的,要求它照样两条都在。
    v_post3 := gen_random_uuid();
    INSERT INTO journal_entries (id, code, entry_date, memo, source_type, source_id, status)
    VALUES (gen_random_uuid(), 'ZZFIX181-JE6', DATE '2027-01-08',
            '冲掉了,换个说法写', 'purchase', v_post3, 'posted')
    RETURNING id INTO v_rev3;
    INSERT INTO journal_entries (id, code, entry_date, memo, source_type, source_id, status, reversed_by)
    VALUES (v_post3, 'ZZFIX181-JE5', DATE '2027-01-08',
            '第三笔定价', 'purchase', v_ib, 'reversed', v_rev3);

    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO n_rev FROM batch_audit_trail
     WHERE batch_id = v_ib AND batch_kind='inbound' AND source_id = v_rev3
       AND 'is_reversal' = ANY (seams);
    RESET ROLE;
    IF n_rev <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 181D 失败:memo 里没有 REVERSAL 字样的那一件冲销不见了 —— 轨迹在依赖一句人打的自由文本';
    END IF;
    RAISE NOTICE '181D memo 一个 REVERSAL 字样都没有,冲销照样在 —— 跟的是 reversed_by,不是文本 ✓';

    RAISE NOTICE 'FIXTURE 181 全部通过';
END $$;
ROLLBACK;
