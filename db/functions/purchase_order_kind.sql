CREATE OR REPLACE FUNCTION public.purchase_order_kind(p_purchase_order_id uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    -- 'equipment' / 'material' / NULL(这张单还没有行 —— 判不出来,不许假装判得出)
    -- 【为什么是 SECURITY DEFINER】守卫靠它认主语。若它受 RLS 约束,一个看不见
    -- 行的调用者会拿到 NULL,而守卫会因此【静默放行】—— 那正是 AGENTS.md 里
    -- "守卫对主语缺席这一格是瞎的"那条病。守卫必须永远看得见它要判的东西。
    SELECT CASE
        WHEN count(*) FILTER (WHERE asset_id IS NOT NULL) > 0 THEN 'equipment'
        WHEN count(*) FILTER (WHERE material_id IS NOT NULL) > 0 THEN 'material'
        ELSE NULL
    END
    FROM purchase_order_lines WHERE purchase_order_id = p_purchase_order_id;
$function$