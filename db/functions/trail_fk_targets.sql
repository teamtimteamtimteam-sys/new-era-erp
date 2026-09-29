-- db/functions/trail_fk_targets.sql
-- AUDIT-TRAIL-1a(Tim 的 Q12 · Q13 · Q40):一张表里【哪些列指着别的记录】,指着哪张表的哪一列。
--   · 单列外键,读目录(pg_constraint),不靠列名猜;
--   · 外加【没有外键的账号列】:uuid 类型、名字以 _by 结尾或叫 actor_user_id —— 它们记的是登录账号
--     (auth.uid()),指向 'auth.users'。created_by / updated_by 也在此列,由界面按 Q12 隐藏。
-- 解析成人读得懂的名字由 trail_ref_label 做;这里只回答"指着谁"。
CREATE OR REPLACE FUNCTION public.trail_fk_targets(p_table text)
 RETURNS TABLE(column_name text, target_table text, target_column text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT a.attname::text, tc.relname::text, ta.attname::text
      FROM pg_constraint k
      JOIN pg_class c ON c.oid = k.conrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'public'
      JOIN pg_attribute a ON a.attrelid = k.conrelid AND a.attnum = k.conkey[1]
      JOIN pg_class tc ON tc.oid = k.confrelid
      JOIN pg_namespace tn ON tn.oid = tc.relnamespace
      JOIN pg_attribute ta ON ta.attrelid = k.confrelid AND ta.attnum = k.confkey[1]
     WHERE c.relname = p_table AND k.contype = 'f' AND cardinality(k.conkey) = 1
       AND tn.nspname = 'public'
    UNION ALL
    SELECT a.attname::text, 'auth.users', 'id'
      FROM pg_attribute a
      JOIN pg_class c ON c.oid = a.attrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'public'
     WHERE c.relname = p_table AND a.attnum > 0 AND NOT a.attisdropped
       AND a.atttypid = 'uuid'::regtype
       AND (a.attname ~ '_by$' OR a.attname IN ('actor_user_id', 'user_id'))
       AND NOT EXISTS (SELECT 1 FROM pg_constraint k2
                        WHERE k2.conrelid = c.oid AND k2.contype = 'f' AND k2.conkey = ARRAY[a.attnum]
                          AND k2.confrelid <> 'auth.users'::regclass);
$function$;
