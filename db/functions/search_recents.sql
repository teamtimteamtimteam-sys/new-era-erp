-- db/functions/search_recents.sql
-- SEARCH-2b · 迁移 D。表的镜像在 db/tables/document_types.sql;
-- 模块闸的行为断言在 db/fixtures/101-a-declared-module-gate-is-the-one-the-policy-calls.sql。

-- ★ INVOKER:最近编辑过的单据。看不见的行【静默消失】(裁定),
--   因为 RLS 就是这么工作的 —— 这里不加第二层过滤。
CREATE OR REPLACE FUNCTION public.search_recents(p_limit integer DEFAULT 5)
 RETURNS TABLE(key text, id text, code text, label text, route text, link_mode text, updated_at timestamptz)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_sql text;
BEGIN
    v_sql := search_documents_sql('recents');
    RETURN QUERY EXECUTE format(
        'SELECT h.key, h.id, h.code, h.label, d.route, d.link_mode, h.updated_at '
        '  FROM (%s) h JOIN document_types d ON d.key = h.key '
        ' WHERE h.updated_at IS NOT NULL '
        ' ORDER BY h.updated_at DESC LIMIT %s', v_sql, p_limit::text)
    USING '';
END;
$function$;
