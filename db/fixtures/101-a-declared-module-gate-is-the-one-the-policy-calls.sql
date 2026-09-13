-- ════════════════════════════════════════════════════════════════════════════
-- fixture 101 —— 【被扣下的那个计数,数的是策略自己调的那道闸】(SEARCH-2b · T4)
-- ════════════════════════════════════════════════════════════════════════════
--
-- T4 的裁定:「definer 计数,**调策略自己调的那些谓词**;只数【模块】扣下的,
-- 不数【归属】扣下的。」落成代码就是 document_types.view_permission 那一列,
-- 而一列【声明】只有在有人核对它的时候才算数。
--
-- ★★ 这一臂守的失败是【安静的】★★
--   view_permission 里写错一个码,search_documents_withheld() 会去数一个
--   **与这张表无关的闸**。后果不是报错,是屏幕上那句
--   「Finance 里还有 3 条,你没有权限看」里的那个 3 变成一个胡说的数 ——
--   而它读起来与一个正确的数一模一样。
--
-- 判据两条:
--   ① 每一个 view_permission 的码,必须【真的出现在】该表 SELECT 策略的谓词里;
--   ② 每一个码必须是 permissions 表里的真码(拼错的码 has_permission 恒假,
--      于是那一类会【永远】被算成"你看不见" —— 又一个安静的错)。
--
-- ★ 这是【子集】判据,不是相等判据,而那个区别是刻意的:
--   策略谓词里会出现【不是闸】的码。实测两种:
--     · tasks:`has_permission('module.tasks.view') AND (… OR has_permission(
--       'module.tasks.view_all'))` —— view_all 是一个【归属放宽项】,不是闸;
--     · assay_results / contracts:按行析取,闸随行的内容走。
--   T4 明写「不数归属扣下的」,所以放宽项不入列 —— 于是只能断言子集。
--   ☞ 这条界限连同它少报的那一格写在 db/migrations/2026-09-13-search2d-*.sql 的抬头。
BEGIN;

DO $fixture$
DECLARE
    r      record;
    v_n    integer := 0;
    v_bad  text[] := '{}';
    v_qual text;
BEGIN
    FOR r IN SELECT DISTINCT d.table_name, c AS code FROM document_types d, unnest(d.view_permission) c LOOP
        v_n := v_n + 1;

        -- ── 判据 ② 码必须是真码 ────────────────────────────────────────────
        IF NOT EXISTS (SELECT 1 FROM permissions p WHERE p.code = r.code) THEN
            v_bad := v_bad || (r.table_name || ': ' || r.code || ' 不在 permissions 里');
            CONTINUE;
        END IF;

        -- ── 判据 ① 策略自己调的就是这个码 ──────────────────────────────────
        SELECT string_agg(COALESCE(pol.qual, ''), ' ') INTO v_qual
          FROM pg_policies pol
         WHERE pol.schemaname = 'public' AND pol.tablename = r.table_name AND pol.cmd = 'SELECT';
        IF v_qual IS NULL THEN
            v_bad := v_bad || (r.table_name || ': 没有 SELECT 策略,而登记表却给它声明了一道模块闸');
        ELSIF position('''' || r.code || '''' IN v_qual) = 0 THEN
            v_bad := v_bad || (r.table_name || ': 策略谓词里没有 ' || r.code);
        END IF;
    END LOOP;

    IF array_length(v_bad, 1) > 0 THEN
        RAISE EXCEPTION 'FIXTURE 101 失败:声明的模块闸与策略对不上:%', v_bad;
    END IF;

    -- ★ 覆盖率本身是一条断言 —— 一个瞎掉的循环与一份正确的登记表都打印"通过"。
    --   实测 2026-09-13:40 种单据 / 39 张表,去重后 43 组(表,码)。
    IF v_n <> 43 THEN
        RAISE EXCEPTION 'FIXTURE 101 失败:只检查了 %(表,码)组,期待 43 —— '
                        '判据瞎了,或者登记表真的变了(那就同时改这个数与切次报告)', v_n;
    END IF;

    -- ★ 每一行都必须有闸:一个空的 view_permission 会让 has_any_permission('{}')
    --   返回假,于是那一类【对所有人】都算成"你看不见" —— 而没有任何东西会报错。
    SELECT count(*) INTO v_n FROM document_types WHERE cardinality(view_permission) = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'FIXTURE 101 失败:% 种单据一道模块闸都没声明', v_n;
    END IF;

    RAISE NOTICE 'FIXTURE 101 全部通过:43 组(表,模块闸)逐组对上了策略自己调的谓词。';
END
$fixture$;

ROLLBACK;
