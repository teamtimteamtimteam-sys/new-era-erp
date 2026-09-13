-- db/functions/search_documents_withheld.sql
-- SEARCH-2b · 迁移 D。表的镜像在 db/tables/document_types.sql;
-- 模块闸的行为断言在 db/fixtures/101-a-declared-module-gate-is-the-one-the-policy-calls.sql。

-- ★★ DEFINER,而且【只返回数】—— S9:存在说出来,内容不给。
--    调用者检查:has_permission(),逐个模块闸求值 —— 就是策略自己调的那一支。
CREATE OR REPLACE FUNCTION public.search_documents_withheld(p_query text)
 RETURNS TABLE(key text, route text, n bigint)
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    r      record;
    v_sql  text;
    v_n    bigint;
    v_shared boolean;
    v_where text;
BEGIN
    IF p_query IS NULL OR btrim(p_query) = '' THEN
        RETURN;
    END IF;
    FOR r IN SELECT * FROM document_types ORDER BY key LOOP
        -- ★ 只数【模块扣下的】:一个闸码都不持有 ⇒ 这一类他一条都看不见。
        --   持有其中之一 ⇒ 不数(剩下看不见的是归属/行别扣下的,T4 明写不数)。
        IF has_any_permission(r.view_permission) THEN
            CONTINUE;
        END IF;
        SELECT count(*) > 1 INTO v_shared FROM document_types d WHERE d.table_name = r.table_name;
        v_where := 'code ILIKE ''%'' || $1 || ''%''';
        IF cardinality(r.match_columns) > 0 THEN
            v_where := v_where || ' OR (length($1) >= 2 AND (' ||
                (SELECT string_agg(format('%I::text ILIKE ''%%'' || $1 || ''%%''', c), ' OR ')
                   FROM unnest(r.match_columns) c) || '))';
        END IF;
        IF v_shared THEN
            v_where := format('(%s) AND code LIKE %L', v_where, r.prefix || '-%');
        END IF;
        v_sql := format('SELECT count(*) FROM public.%I WHERE %s', r.table_name, v_where);
        EXECUTE v_sql INTO v_n USING btrim(p_query);
        IF v_n > 0 THEN
            key := r.key; route := r.route; n := v_n;
            RETURN NEXT;
        END IF;
    END LOOP;
END;
$function$;
