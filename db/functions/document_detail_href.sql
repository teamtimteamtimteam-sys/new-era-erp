-- db/functions/document_detail_href.sql
-- SYSTEM-MAP-3(Tim 2026-10-27,grilling 第 3 条):一张单据【自己那一页】的地址 —— 一份实现。
--   documentHref()(lib/search/documentHref.ts)答的是「搜索命中点开去哪」:进料批 / 产出批落在带 ?q= 的列表、
--   贷项通知单落在列表、化验单落在一种单据的全表列表。单据链条与关联页的表格要的是【那一张单据的页面】,
--   而那几种的页面地址不是 <route>/<id>:/inbound/<id>/edit · /output/<id>/edit · /finance/credit-notes/<id> ·
--   /inbound/<inbound_batch_id>/assays/<id>。
-- 判据:document_types.detail_route 有值 → 按它填(`{id}` 是这张单据的 id,`{<列>}` 是这一行那一列的值);
--   没有值而 link_mode = 'detail' → <route>/<id>;否则 NULL(这种单据没有逐张的页面)。
--   填不出来(一个占位列在这一行上是 NULL —— 例如一张产出批的化验单没有 inbound_batch_id)→ NULL,不猜。
-- ★ INVOKER:占位列按读者自己的身份读;读不到那一行 → NULL。
-- ★ 读者:document_chain_walk()(单据链条)· document_detail_hrefs()(关联页的表格,一次一屏)。
--
-- NOTE: introduced by db/migrations/2026-10-27-system-map-3-chain-bar.sql.
-- ★ CHAIN-WALK-COST(v1.4.80):实现在 document_detail_hrefs(key, ids[]) 里一份;这一支是它的单张写法。

CREATE OR REPLACE FUNCTION public.document_detail_href(p_key text, p_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v text;
BEGIN
    SELECT h.href INTO v FROM public.document_detail_hrefs(p_key, ARRAY[p_id]) h;
    RETURN v;
END;
$function$;

COMMENT ON FUNCTION public.document_detail_href(text, uuid) IS
    'SYSTEM-MAP-3:一张单据自己那一页的地址(detail_route 按占位填 / detail → <route>/<id> / 否则 NULL)。INVOKER。';
