-- ════════════════════════════════════════════════════════════════════════════
-- fixture 102 —— 【一张有 code 列的表,要么在册,要么在例外表里带一句理由】
--                 (SEARCH-4 · Q16 / 裁定 ③)
-- ════════════════════════════════════════════════════════════════════════════
--
-- 关联搜索的【节点集】就是 document_types。于是一张没有登记的新单据表,
-- 不只是搜不到它自己 —— **所有指向它的关联边会一起安静地消失**。
-- 漏登记一次,漏掉的不是一条结果,是一片边。
--
-- ★★ 这一臂与 scripts/check-document-registry.mjs 是【同一句话的两半,而两半
--   看的不是同一个东西】★★
--     · 那支脚本读 `db/tables/` 的**镜像文本**,跑在 `npm run build` 里 ——
--       它在构建期就红,不必连库。
--     · 本 fixture 读**真的 pg_catalog**,跑在门重建出来的那个库上 ——
--       它抓得住"镜像文本骗过了正则、而真库里那一列确实存在"的那一种。
--   两支都留,谁都不冒充对方。
--
-- 判据三条:
--   ① public 里每一张有 code 列的表,要么在 document_types,要么在
--      document_type_exceptions;
--   ② 例外表里没有死条目 —— 一条例外指的表若没有 code 列、或其实已登记,
--      那条例外要么过期了,要么本判据瞎了,两种都红;
--   ③ 覆盖本身是断言:带 code 列的表数出 0 就是判据失效,不是"全都合格"。
BEGIN;

DO $fixture$
DECLARE
    v_n     bigint;
    v_list  text;
BEGIN
    -- ── ③ 覆盖断言先跑 —— 零必须是一次测量,不是一次缺席 ────────────────────
    SELECT count(*) INTO v_n
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'code'
                         AND a.attnum > 0 AND NOT a.attisdropped
     WHERE n.nspname = 'public' AND c.relkind = 'r';
    IF v_n < 2 THEN
        RAISE EXCEPTION 'FIXTURE 102 失败:public 里数出 % 张带 code 列的表 —— '
                        '判据瞎了,不是目录干净了', v_n;
    END IF;

    -- ── ① 要么在册,要么在例外表里 ──────────────────────────────────────────
    SELECT count(*), string_agg(c.relname, ', ' ORDER BY c.relname)
      INTO v_n, v_list
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'code'
                         AND a.attnum > 0 AND NOT a.attisdropped
     WHERE n.nspname = 'public' AND c.relkind = 'r'
       AND c.relname NOT IN (SELECT table_name FROM document_types)
       AND c.relname NOT IN (SELECT table_name FROM document_type_exceptions);
    IF v_n > 0 THEN
        RAISE EXCEPTION 'FIXTURE 102 失败:% 张有 code 列的表既没登记也没例外:% —— '
                        '它若是单据就登记它(否则指向它的关联边会一起安静地消失);'
                        '它若不是,就往 document_type_exceptions 里加一行【带理由】',
                        v_n, v_list;
    END IF;

    -- ── ② 例外表里不许有死条目 ──────────────────────────────────────────────
    SELECT count(*), string_agg(e.table_name, ', ' ORDER BY e.table_name)
      INTO v_n, v_list
      FROM document_type_exceptions e
     WHERE e.table_name IN (SELECT table_name FROM document_types)
        OR NOT EXISTS (
             SELECT 1 FROM pg_class c
               JOIN pg_namespace n ON n.oid = c.relnamespace
               JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'code'
                                  AND a.attnum > 0 AND NOT a.attisdropped
              WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relname = e.table_name);
    IF v_n > 0 THEN
        RAISE EXCEPTION 'FIXTURE 102 失败:例外表里 % 条今天一处都命不中:% —— '
                        '要么名单过期了(删掉那一条),要么判据瞎了。两种在输出上分不开,'
                        '所以不要为了让门变绿就删条目,先确认是哪一种', v_n, v_list;
    END IF;

    -- ── 理由非空:库里那条 CHECK 的反面对照 ─────────────────────────────────
    -- ★ 断言【那条 CHECK 还在】,而不是断言"今天没有空理由"——
    --   后者在 CHECK 被人摘掉的那天照样全绿。
    BEGIN
        INSERT INTO document_type_exceptions (table_name, reason)
        VALUES ('__fixture_102_probe__', '   ');
        RAISE EXCEPTION 'FIXTURE 102 失败:一行空理由的例外被【收下了】—— '
                        'document_type_exceptions_reason_present 那条 CHECK 不在了,'
                        '而一张塞得进空理由的例外表就是一张"不要红"的名单';
    EXCEPTION
        WHEN check_violation THEN NULL;   -- 这才是对的
    END;

    SELECT count(*) INTO v_n FROM document_type_exceptions;
    RAISE NOTICE 'FIXTURE 102 全部通过:public 里每一张带 code 列的表都被裁过一次 —— '
                 '% 张在册、% 条在例外表里各带一句理由,没有第三种。',
                 (SELECT count(DISTINCT table_name) FROM document_types), v_n;
END
$fixture$;

ROLLBACK;
