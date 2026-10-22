-- 291 一条专用导出不会在第 1,000 行处悄悄停下(TABLE-EXPORT-1,Tim 2026-10-22 Q15)
-- ═══════════════════════════════════════════════════════════════════════════
-- 【它要钉的是什么】线上 PostgREST `max_rows = 1000`(TABLE-EXPORT-1 Step 0 实测)。一条经 PostgREST 的读
--   拿到第 1,000【行】就停,不报错、不提示。五条保留的专用导出(GST F5 · 总账 · 应收账龄 · 应付账龄 · 管理包)
--   于是分两种:
--     ① 源是【一组行】的(总账 `journal_export_lines` · F5 已申报快照 `gst_return_boxes`)→ 路由必须翻页取全
--        (lib/export/serverRows.ts 的 fetchAllPages,按唯一键排序);
--     ② 源是【一个值】的(`ar_aging_asof` · `ap_aging_asof` · `f5_return` 返回 jsonb;管理包读一行的 payload jsonb)
--        → max_rows 截不到它,路由按构造停不下来。
--
-- 【重建库上没有 PostgREST】(本机既没有 postgrest 也没有 docker —— TABLE-EXPORT-1 实测),所以那个 1,000 的闸门
--   本身在这里造不出来。本 fixture 证的是重建库【答得了】的那两半:
--     A 臂 —— 总账那一源在 1,000 行以上【一行不少】,而且一个「只取前 1,000 行」的读(PostgREST 截断的形状)
--            【真的】会少 —— 两臂分得开,于是这条断言不是空转(README 第 3 条 · AGENTS.md「一个分不出两臂的判据」);
--     B 臂 —— 五个源的【形状】:① 那两个是一组行、且翻页用的键唯一;② 那四个是一个 jsonb 值。
--            哪一个哪天改了形状(比如账龄改成 RETURNS TABLE),本臂当场红 —— 那一天它的路由就必须改成翻页。
--   翻页代码本身对着一个「每次最多回 1,000 行」的桩跑过 2,500 行:db/scripts/2026-10-22-table-export-1-paging-proof.mts。
--
-- 自带数据(README 第 2 条);期间锁显式设定(第 5 条);自建角色(「权限:自建角色,不借引导角色」)。
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    v_role  uuid;
    u_fin   uuid := gen_random_uuid();
    v_ccy   text;
    a_bank  uuid; a_rev uuid;
    N       constant int := 1002;      -- 1,000 以上,且是偶数(借贷各半,分录平)
    v_full  int; v_capped int;
    v_bad   text;
BEGIN
    UPDATE finance_settings SET locked_before = NULL;
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    SELECT id INTO a_bank FROM accounts WHERE code = '1010';
    SELECT id INTO a_rev  FROM accounts WHERE code = '4000';
    IF v_ccy IS NULL OR a_bank IS NULL OR a_rev IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 291 前提失败:没有本位币,或引导科目表里没有 1010 / 4000';
    END IF;

    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fixture-291-fin', 'f', 'f', true) RETURNING id INTO v_role;
    INSERT INTO role_permissions (role_id, permission_code) VALUES
        (v_role, 'module.finance.view'), (v_role, 'data.view_pay');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_fin, v_role);

    -- ══════════════════ A · 总账那一源:1,000 行以上,一行不少 ══════════════════
    -- 一张分录 N 条腿:N/2 条借 1010、N/2 条贷 4000,各 1.00 —— 平,而且只有【一张】分录,
    -- 于是这里数的是【行】(导出就是一行一分录行),不是分录。
    WITH e AS (
        INSERT INTO journal_entries (code, entry_date, memo, source_type)
        VALUES ('FIX291-GL', DATE '2026-08-14', 'fixture 291: more lines than one PostgREST page', 'manual')
        RETURNING id
    )
    INSERT INTO journal_lines (entry_id, account_id, debit, credit, currency, amount_ccy, fx_rate)
    SELECT e.id,
           CASE WHEN g % 2 = 0 THEN a_bank ELSE a_rev END,
           CASE WHEN g % 2 = 0 THEN 1 ELSE 0 END,
           CASE WHEN g % 2 = 0 THEN 0 ELSE 1 END,
           v_ccy, 1, 1
      FROM e, generate_series(1, N) g;

    -- 以一个持 module.finance.view 的读者的身份读(README 第 6 条:RLS 那一半要切角色才不是空话)
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_fin), true);
    SELECT count(*) INTO v_full
      FROM journal_export_lines(DATE '2026-08-14', DATE '2026-08-14', false) x
     WHERE x.entry_code = 'FIX291-GL';
    -- PostgREST 截断的形状:同一个读,只拿前 1,000 行
    SELECT count(*) INTO v_capped
      FROM (SELECT * FROM journal_export_lines(DATE '2026-08-14', DATE '2026-08-14', false) x
             WHERE x.entry_code = 'FIX291-GL' ORDER BY x.line_id LIMIT 1000) s;
    RESET ROLE;

    IF v_full IS DISTINCT FROM N THEN
        RAISE EXCEPTION 'FIXTURE 291A 失败:造了 % 条分录行,journal_export_lines 读回 % 条', N, v_full;
    END IF;
    IF v_capped IS NOT DISTINCT FROM v_full THEN
        RAISE EXCEPTION 'FIXTURE 291A 空转:截到 1,000 行的读与全量读一样多(%),这条断言分不出两臂', v_full;
    END IF;

    -- ══════════════════ B · 五个源的形状 ══════════════════
    -- ① 一组行:路由必须翻页(按唯一键)
    SELECT string_agg(p.proname, ', ') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = 'public'
     WHERE p.proname = 'journal_export_lines' AND NOT p.proretset;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 291B 失败:% 不再返回一组行 —— 读本 fixture 抬头,再看总账导出的翻页还对不对', v_bad;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint c
         WHERE c.conrelid = 'public.gst_return_boxes'::regclass AND c.contype IN ('u', 'p')
           AND (SELECT array_agg(a.attname::text ORDER BY a.attname)
                  FROM unnest(c.conkey) k JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k)
               = ARRAY['box', 'period_id']
    ) THEN
        RAISE EXCEPTION 'FIXTURE 291B 失败:gst_return_boxes 的 (period_id, box) 不再唯一 —— F5 快照按 box 翻页会重行或漏行';
    END IF;
    -- ② 一个值:max_rows 截不到
    SELECT string_agg(f, ', ') INTO v_bad
      FROM unnest(ARRAY['ar_aging_asof', 'ap_aging_asof', 'f5_return']) f
     WHERE NOT EXISTS (
        SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = 'public'
         WHERE p.proname = f AND NOT p.proretset AND p.prorettype = 'jsonb'::regtype);
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 291B 失败:% 不再是「返回一个 jsonb」—— 它的导出路由从此会被 max_rows 截,必须改成翻页', v_bad;
    END IF;
    IF (SELECT atttypid FROM pg_attribute
         WHERE attrelid = 'public.management_packs'::regclass AND attname = 'payload') IS DISTINCT FROM 'jsonb'::regtype THEN
        RAISE EXCEPTION 'FIXTURE 291B 失败:management_packs.payload 不再是 jsonb —— 管理包导出读一行的假设不再成立';
    END IF;

    RAISE NOTICE 'FIXTURE 291 全部通过:总账源 % 行一行不少(截到 1,000 的读只有 %)· 两个行源可翻页 · 四个值源 max_rows 截不到', v_full, v_capped;
END $$;
ROLLBACK;
