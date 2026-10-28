-- db/functions/document_detail_hrefs.sql
-- SYSTEM-MAP-3:document_detail_href() 的一屏版 —— 关联页的表格一次画 20 行,一次往返要齐它们的地址。
--   同一份实现(逐个调 document_detail_href),不是第二份。INVOKER。
--
-- NOTE: introduced by db/migrations/2026-10-27-system-map-3-chain-bar.sql.

CREATE OR REPLACE FUNCTION public.document_detail_hrefs(p_key text, p_ids uuid[])
 RETURNS TABLE(id uuid, href text)
 LANGUAGE sql
 STABLE
AS $function$
    SELECT x.id, public.document_detail_href(p_key, x.id)
      FROM unnest(p_ids) AS x(id)
$function$;

COMMENT ON FUNCTION public.document_detail_hrefs(text, uuid[]) IS
    'SYSTEM-MAP-3:一批单据各自那一页的地址(逐个调 document_detail_href)。INVOKER。';
