-- db/functions/trail_row_visible.sql
-- AUDIT-TRAIL-1a(Tim 的 Q4 · Q5):【当前读者】能不能读这一行 —— 按【这一行自己那张表】的读规则,不按父记录的。
--   record_trail 是 SECURITY DEFINER(change_log 对应用角色没有任何授权),而 DEFINER 里做不了 SET ROLE,
--   所以这里把那张表的 SELECT 策略(permissive 的 SELECT 与 ALL,给 authenticated 或 public 的)用 OR 拼起来,
--   对着那一行重新求一次值。这样做是对的,因为实测(AUDIT-TRAIL-0 reader-masking.md §1.6):线上 287 条读策略
--   0 条 restrictive、0 条依赖数据库角色 —— 全部经 has_permission() / current_user_employee() 从登录的 JWT 认人。
--   restrictive 策略若将来出现,在这里用 AND 接上(已经写好)。
--   · 表没开 RLS → 看 authenticated 有没有任何一列的 SELECT 权限;
--   · authenticated 连一列都读不了(cod_verification_failures 那种没有读策略的表)→ 看不见;
--   · 这一行已被硬删 → 对它最后一份影像求同一个值(jsonb_populate_record,别名就是表名,于是带表名限定的列引用照样解析)。
--   ☞ 已知边界(reader-masking.md §1.6 已记):策略里 EXISTS 子查询读的别的表,在 DEFINER 里不再过那张表的 RLS。
--     线上两处这种策略的子查询都自己写全了条件,所以结果相同。
-- 【属主身份】EXECUTE 已从 authenticated 收回 —— 否则它就是一支"任意一行你看不看得见"的探针。
CREATE OR REPLACE FUNCTION public.trail_row_visible(p_table text, p_key jsonb, p_image jsonb)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_rls   boolean;
    v_perm  text;
    v_restr text;
    v_where text;
    v_ok    boolean;
    v_live  boolean;
BEGIN
    SELECT c.relrowsecurity INTO v_rls
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'public'
     WHERE c.relname = p_table AND c.relkind = 'r';
    IF NOT FOUND OR p_key IS NULL THEN
        RETURN false;
    END IF;
    IF NOT has_any_column_privilege('authenticated', format('public.%I', p_table), 'SELECT') THEN
        RETURN false;
    END IF;
    IF NOT v_rls THEN
        RETURN true;
    END IF;
    SELECT string_agg('(' || p.qual || ')', ' OR ') INTO v_perm
      FROM pg_policies p
     WHERE p.schemaname = 'public' AND p.tablename = p_table AND p.permissive = 'PERMISSIVE'
       AND p.cmd IN ('SELECT', 'ALL') AND p.roles && ARRAY['authenticated', 'public']::name[]
       AND p.qual IS NOT NULL;
    IF v_perm IS NULL THEN
        RETURN false;
    END IF;
    SELECT string_agg('(' || p.qual || ')', ' AND ') INTO v_restr
      FROM pg_policies p
     WHERE p.schemaname = 'public' AND p.tablename = p_table AND p.permissive = 'RESTRICTIVE'
       AND p.cmd IN ('SELECT', 'ALL') AND p.roles && ARRAY['authenticated', 'public']::name[]
       AND p.qual IS NOT NULL;
    v_perm := '(' || v_perm || ')' || COALESCE(' AND (' || v_restr || ')', '');

    SELECT string_agg(format('%I.%I::text = %L', p_table, k.key, k.value), ' AND ')
      INTO v_where FROM jsonb_each_text(p_key) k;
    EXECUTE format('SELECT EXISTS (SELECT 1 FROM public.%1$I %1$I WHERE %2$s)', p_table, v_where) INTO v_live;
    IF v_live THEN
        EXECUTE format('SELECT EXISTS (SELECT 1 FROM public.%1$I %1$I WHERE %2$s AND (%3$s))', p_table, v_where, v_perm)
           INTO v_ok;
        RETURN COALESCE(v_ok, false);
    END IF;
    IF p_image IS NULL THEN
        RETURN false;
    END IF;
    EXECUTE format('SELECT EXISTS (SELECT 1 FROM jsonb_populate_record(NULL::public.%1$I, $1) %1$I WHERE (%2$s))',
                   p_table, v_perm)
       INTO v_ok USING p_image;
    RETURN COALESCE(v_ok, false);
END;
$function$;
