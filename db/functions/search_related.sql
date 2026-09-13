-- db/functions/search_related.sql
-- SEARCH-4 · 迁移 A。关系图在 db/views/document_relations.sql;
-- 行为断言在 db/fixtures/103-a-voided-bridge-does-not-void-a-real-relation.sql。

-- ★★ INVOKER,而这一条【不是随手抄的】(Q13)★★
--   关联计数要回答的是「**你**看得见几条」,而那正是 RLS 天生回答的问题。
--   DEFINER 只属于 search_documents_withheld() —— 「你**看不见**几条」RLS 按构造
--   答不了,所以那一支必须借身份。**两支函数,两种身份,不要合并。**
--   ☞ 推论:一类关联整类被模块闸扣下时,这里数出 0,那一组就不出现 —— 顶层
--     那一次 search_documents_withheld() 已经把"这一类你能不能看"说过一遍了,
--     这里不再报第二个数(两个数不一样,读起来像矛盾)。
--
-- ★ 每条命中【最多】几组:15(journal_entries,含它自己的冲销自指边)。
--   一组一支相关子查询,5 条命中 ⇒ 最坏 75 支。今天 320 行,规划器一律 Seq Scan。
--   **不报毫秒数** —— 迁移 B 的 84 条索引是为将来的体量建的,不为今天的读数。

CREATE OR REPLACE FUNCTION public.search_related(p_key text, p_id uuid)
 RETURNS TABLE(target_key text, target_table text, route text, link_mode text, n bigint)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_table  text;
    v_rows   jsonb := '[]'::jsonb;
    r        record;
    e        record;
    parts    text[];
    v_where  text;
    v_n      bigint;
BEGIN
    IF p_key IS NULL OR p_id IS NULL THEN
        RETURN;
    END IF;

    SELECT d.table_name INTO v_table FROM public.document_types d WHERE d.key = p_key;
    IF v_table IS NULL THEN
        -- 与 document_type_prefix() 同一条:读不到就响,不要静默返回空。
        -- 一个"这张单据没有关联记录"的空态,和一个拼错的 key,在屏幕上长得一模一样。
        RAISE EXCEPTION 'SEARCH_UNKNOWN_DOCUMENT_TYPE|% —— 它不在 document_types 里,'
                        '而一次拼错的 key 与一张真的没有关联的单据在屏幕上分不开', p_key;
    END IF;

    FOR r IN
        SELECT d.key, d.table_name, d.route, d.link_mode, d.prefix,
               (SELECT count(*) > 1 FROM public.document_types d2
                 WHERE d2.table_name = d.table_name) AS shared
          FROM public.document_types d
         WHERE EXISTS (SELECT 1 FROM public.document_relations dr
                        WHERE dr.from_table = v_table AND dr.to_table = d.table_name)
         ORDER BY d.key
    LOOP
        parts := '{}';
        FOR e IN
            SELECT * FROM public.document_relations dr
             WHERE dr.from_table = v_table AND dr.to_table = r.table_name
        LOOP
            IF e.kind = 'bridge' THEN
                parts := parts || format(
                    'SELECT t.id, t.code FROM public.%I v JOIN public.%I t ON t.%I = v.%I '
                    ' WHERE v.%I = (SELECT s.%I FROM public.%I s WHERE s.id = $1)',
                    e.via_table, e.to_table, e.to_column, e.via_to_column,
                    e.via_from_column, e.from_column, e.from_table);
            ELSE
                -- 出边与入边在这里是【同一个形状】:出边的 from_column 是本表那一列,
                -- 入边的 from_column 是被指向的那一列(几乎总是 id)。
                parts := parts || format(
                    'SELECT t.id, t.code FROM public.%I t '
                    ' WHERE t.%I = (SELECT s.%I FROM public.%I s WHERE s.id = $1)',
                    e.to_table, e.to_column, e.from_column, e.from_table);
            END IF;
        END LOOP;

        CONTINUE WHEN cardinality(parts) = 0;

        v_where := 'TRUE';
        -- 一张表两个前缀(payments = RCPT + PMT):不加前缀过滤,同一条关联会在
        -- 两种单据下各数一次。与 search_documents_sql() 逐字同一条理由。
        IF r.shared THEN
            v_where := v_where || format(' AND u.code LIKE %L', r.prefix || '-%');
        END IF;
        -- 自指关系不把自己算成自己的关联记录。
        IF r.table_name = v_table THEN
            v_where := v_where || ' AND u.id <> $1';
        END IF;

        EXECUTE format(
            'SELECT count(*) FROM (SELECT DISTINCT u.id FROM (%s) u (id, code) WHERE %s) z',
            array_to_string(parts, E'\nUNION ALL\n'), v_where)
          INTO v_n USING p_id;

        -- 0 组不返回:「这张单据没有关联记录」由应用层画,而不是画 39 行 0。
        CONTINUE WHEN v_n = 0;

        v_rows := v_rows || jsonb_build_object(
            'target_key', r.key, 'target_table', r.table_name,
            'route', r.route, 'link_mode', r.link_mode, 'n', v_n);
    END LOOP;

    RETURN QUERY
    SELECT x->>'target_key', x->>'target_table', x->>'route', x->>'link_mode',
           (x->>'n')::bigint
      FROM jsonb_array_elements(v_rows) x
     ORDER BY (x->>'n')::bigint DESC, x->>'target_key';
END;
$function$;

COMMENT ON FUNCTION public.search_related(text, uuid) IS
    'SEARCH-4:一条命中带出来的关联记录,**按目标单据种类分组,每组一个计数**。'
    'INVOKER —— 数的是"你看得见几条"(Q13)。行不取回来:一个分组行答得出'
    '"这个供应商现在什么情况",而 11 行批号答不出。';

-- ★ EXECUTE 的授权【不写在这里】:db/views/zzz_function_grants.sql 是那一条的
--   唯一出处(先 REVOKE FROM PUBLIC, anon，再 GRANT ON ALL FUNCTIONS TO
--   authenticated, service_role)。在这里再写一遍就是第二份真相 ——
--   而 search_documents / search_recents 四支的镜像里也都没有它。
--   ⚠ 迁移那一侧【显式写了】:一支刚建出来的函数拿的是默认权限，
--     而「默认多半是对的」正是本刀在 document_relations 上刚栽过的那一跮。
