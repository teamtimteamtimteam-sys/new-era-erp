-- db/functions/document_relation_arm_ids.sql
-- SYSTEM-MAP-3(Tim 2026-10-27):一条【声明的】关联(document_relation_arms 的一行)从一张单据走到哪几张。
--   search_related() / search_related_rows() 的 'arm' 分支调它;document_chain_walk() 经 search_related_rows() 间接调它。
--
-- ★ INVOKER,与那两支同一条理由:「你看得见哪几张」由 RLS 自己回答。这里一条权限判据都不写。
-- ★ 认不出的 arm 名【响】(RAISE),不是空集 —— 一个拼错的名字与一张真的没有关联的单据,在屏幕上分不开。
-- ★ 每一支只读它那一条路上的表;日期与状态的判据写在 document_relation_arms 那一行的 reason 里,两边说同一句话。
--
-- ★ CHAIN-WALK-COST(v1.4.80):十条路只写在 document_relation_arm_pairs(arm, ids[]) 里一份;这一支是它的单张写法。
--   单据链条一跳交一整圈来源进那一支,关联页(search_related / search_related_rows)照旧一张一张经这一支问 —— 两边同一份定义。
--
-- NOTE: introduced by db/migrations/2026-10-27-system-map-3-chain-bar.sql.

CREATE OR REPLACE FUNCTION public.document_relation_arm_ids(p_arm text, p_id uuid)
 RETURNS TABLE(id uuid)
 LANGUAGE plpgsql
 STABLE
AS $function$
BEGIN
    RETURN QUERY SELECT p.id FROM public.document_relation_arm_pairs(p_arm, ARRAY[p_id]) p;
END;
$function$;

COMMENT ON FUNCTION public.document_relation_arm_ids(text, uuid) IS
    'SYSTEM-MAP-3:一条声明的关联(document_relation_arms)从一张单据走到哪几张。INVOKER —— RLS 回答你看得见哪几张;'
    '认不出的 arm 名按名拒(DOCUMENT_RELATION_UNKNOWN_ARM)。';
