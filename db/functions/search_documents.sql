-- db/functions/search_documents.sql
-- SEARCH-2b · 迁移 D。表的镜像在 db/tables/document_types.sql;
-- 模块闸的行为断言在 db/fixtures/101-a-declared-module-gate-is-the-one-the-policy-calls.sql。

-- ★ INVOKER:他能看见哪几条,由 RLS 策略自己回答,这里不写第二遍。
CREATE OR REPLACE FUNCTION public.search_documents(p_query text, p_limit integer DEFAULT 8)
 RETURNS TABLE(key text, id text, code text, label text, route text, link_mode text,
               updated_at timestamptz, total bigint)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_sql text;
BEGIN
    IF p_query IS NULL OR btrim(p_query) = '' THEN
        RETURN;                       -- 空查询不是一次搜索
    END IF;
    v_sql := search_documents_sql('search');
    -- ★★ total 是【截断之前】的条数,而它必须由这一支给出 ★★
    --   裁定写着「不许静默截断」,而一个 `LIMIT n+1` 的写法只答得出
    --   "还有没有更多",答不出"还有几条" —— 于是 more 会在有 50 条时报 1。
    --   一个说了个小数的截断提示,与一个不提截断的结果,读起来一样错。
    --   count(*) OVER () 在 LIMIT 之前求值,所以它数的是整个匹配面。
    RETURN QUERY EXECUTE format(
        'SELECT q.key, q.id, q.code, q.label, q.route, q.link_mode, q.updated_at, q.total FROM ('
        '  SELECT h.key, h.id, h.code, h.label, d.route, d.link_mode, h.updated_at, '
        '         count(*) OVER () AS total, h.rank '
        '    FROM (%s) h JOIN document_types d ON d.key = h.key '
        -- 排序(裁定):精确 code → code 前缀 → code 后缀 → 标签;
        -- 组内 updated_at DESC,没有那一列的按 code DESC。
        '   ORDER BY h.rank, h.updated_at DESC NULLS LAST, h.code DESC '
        '   LIMIT %s) q (key, id, code, label, route, link_mode, updated_at, total, rank)',
        v_sql, p_limit::text)
    USING btrim(p_query);
END;
$function$;
