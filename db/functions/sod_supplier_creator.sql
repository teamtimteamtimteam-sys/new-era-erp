-- db/functions/sod_supplier_creator.sql
-- SOD-1:问法② —— "这家供应商是谁建的?"
-- created_by 为 NULL 时返回空集,于是规矩【不适用】(不是"通过")——
-- 见 assert_segregated 的注释与 docs/known-issues.md 的 SOD-1-BLIND 条。
--
-- NOTE: introduced by db/migrations/2026-08-24-sod1-one-rule-two-questions.sql.

CREATE OR REPLACE FUNCTION public.sod_supplier_creator(p_supplier_id uuid)
 RETURNS uuid[]
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE WHEN s.created_by IS NULL THEN '{}'::uuid[] ELSE ARRAY[s.created_by] END
      FROM suppliers s
     WHERE s.id = p_supplier_id;
$function$;