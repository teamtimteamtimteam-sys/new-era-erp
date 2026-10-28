-- db/functions/document_detail_hrefs.sql
-- SYSTEM-MAP-3:document_detail_href() 的一屏版 —— 关联页的表格一次画 20 行,一次往返要齐它们的地址。
-- ★ CHAIN-WALK-COST(v1.4.80):实现搬到这里 —— 地址模板里的占位(化验单的 {inbound_batch_id})对一组 id 只查一次表,
--   document_detail_href(key, id) 是它的单张写法(以前反过来:这一支逐个调那一支,一张月结对账单的链条 200 张化验单各查一次)。
--   结果与以前逐行相同:每一个输入 id 一行、按输入的顺序;占位读不到(那一行看不见、或那一列为空)→ 地址为 NULL。INVOKER。
--
-- NOTE: introduced by db/migrations/2026-10-27-system-map-3-chain-bar.sql.

CREATE OR REPLACE FUNCTION public.document_detail_hrefs(p_key text, p_ids uuid[])
 RETURNS TABLE(id uuid, href text)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    d     record;
    v_expr text;
    m     text[];
BEGIN
    SELECT dt.key, dt.table_name, dt.route, dt.link_mode, dt.detail_route INTO d
      FROM public.document_types dt WHERE dt.key = p_key;
    IF d.key IS NULL THEN
        RAISE EXCEPTION 'SEARCH_UNKNOWN_DOCUMENT_TYPE|% —— 它不在 document_types 里', coalesce(p_key, '(null)');
    END IF;
    IF d.detail_route IS NOT NULL THEN
        v_expr := quote_literal(d.detail_route);
        FOR m IN SELECT regexp_matches(d.detail_route, '\{([a-z_]+)\}', 'g') LOOP
            v_expr := format('replace(%s, %L, %s)', v_expr, '{' || m[1] || '}',
                             CASE WHEN m[1] = 'id' THEN 'x.id::text' ELSE format('t.%I::text', m[1]) END);
        END LOOP;
        RETURN QUERY EXECUTE format(
            'SELECT x.id, CASE WHEN x.id IS NULL THEN NULL ELSE %s END'
            '  FROM unnest($1) WITH ORDINALITY AS x(id, n) LEFT JOIN public.%I t ON t.id = x.id ORDER BY x.n',
            v_expr, d.table_name) USING p_ids;
        RETURN;
    END IF;
    RETURN QUERY
    SELECT x.id, CASE WHEN x.id IS NOT NULL AND d.link_mode = 'detail' THEN d.route || '/' || x.id::text END
      FROM unnest(p_ids) WITH ORDINALITY AS x(id, n) ORDER BY x.n;
END;
$function$;
