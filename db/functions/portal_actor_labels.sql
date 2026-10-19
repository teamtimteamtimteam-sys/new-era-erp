-- db/functions/portal_actor_labels.sql
-- MES-9a(2026-10-19,MES-9 Step 0 Q21,Tim):【一个门户账号做的事,"谁做的"那一格写「Supplier portal — <供应商名>」】——
--   页面上的 ActorName(app/components/ActorName.tsx)在一个账号没有员工档案时,先问这里它是不是一个门户账号;
--   审计记录那一侧由 trail_actor 直接认(同一句话,两个读法)。
--   给一串账号 id,回其中【是门户账号的那几个】与它的供应商名。供应商名是一个显示标签(AGENTS.md 常设裁定 3:标签跟着单据走,
--   看得见那一行的人就看得见是谁做的);不回联系人的名字、邮箱或任何别的东西。不是门户账号的 id 一行都不回。
--   判据:调用者是一个登录了的会话(auth.uid())。
-- NOTE: introduced by db/migrations/2026-10-19-mes9a-supplier-portal-identity.sql.
CREATE OR REPLACE FUNCTION public.portal_actor_labels(p_user_ids uuid[])
 RETURNS TABLE(user_id uuid, supplier_name text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|session';
    END IF;
    RETURN QUERY
        SELECT p.user_id, s.legal_name
          FROM supplier_portal_users p JOIN suppliers s ON s.id = p.supplier_id
         WHERE p.user_id = ANY (p_user_ids);
END;
$function$;
