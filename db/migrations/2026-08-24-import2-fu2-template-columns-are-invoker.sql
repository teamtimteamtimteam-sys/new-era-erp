-- 2026-08-24-import2-fu2-template-columns-are-invoker.sql
-- IMPORT-2-fu2:模板列那支函数改成 SECURITY INVOKER —— B1/B2 抓到的,而它抓得对。
--
-- fu 那一刀把 require_permission 从这支函数里拿掉(理由:它返回的是 schema 元数据,
-- 而且 gate 要在一个没有用户的重建库上调它)。**但我把 SECURITY DEFINER 留着了。**
-- 于是它变成了 B2 正正好好要抓的那种东西:
--     SECURITY DEFINER + 没有调用者检查 + 对 authenticated 可执行。
--
-- **B2 是对的,而我是错的。** 这支函数只读系统目录(pg_attribute / pg_constraint),
-- 任何角色都读得到 —— 它根本不需要任何提权。DEFINER 是一处多余的权限,
-- 拿掉它之后既没有功能变化,也不再有不变量违规。
--
-- 记一句方法上的话:**这不是"给不变量让路",是不变量指出了一处真的多余的提权。**

BEGIN;

CREATE OR REPLACE FUNCTION public.master_import_template_columns(p_table text)
 RETURNS TABLE(column_name text, is_required boolean, accepted_values text[])
 LANGUAGE plpgsql
 STABLE SECURITY INVOKER
 SET search_path TO 'public'
AS $function$
BEGIN
    -- 【SECURITY INVOKER,而且不判权限 —— 两件事一起说,因为它们互为理由】
    -- **B2 抓过它一次:一支 SECURITY DEFINER、没有调用者检查、又对 authenticated
    -- 可执行的函数,就是 B2 要抓的东西 —— 而它抓得对。** DEFINER 是我写错了:
    -- 这支函数只读 pg_attribute / pg_constraint 这类【系统目录】,任何角色都读得到,
    -- 它一丁点提权都不需要。改成 INVOKER 之后,那条不变量自然就没有意见了。
    --
    -- 【它【不】判权限,而这是一个决定 —— 理由写在这里免得有人"补上"】
    -- 它返回的只有 **schema 元数据**:列名、必不必填、CHECK 的取值集合。
    -- 那不是业务数据 —— 任何一个登录用户从表单上也看得到同样的列名。
    -- 真正的门在【路由与页面】(`action.bulk_import`),与 moduleGuard 那句
    -- "这不是安全边界,边界在数据库"同一个安排:这里没有要护的数据。
    --
    -- **而它必须不判权限,还有一个硬理由:** db/gate.py 的 import-template 检查要在
    -- 【重建库】上调它,而那份库**一个用户都没有** —— has_permission 解析 auth.uid(),
    -- 于是任何带权限判断的版本在那里都调不动,那条检查也就不可能存在。
    -- 一个为了permission 而无法被检查的函数,换来的是一条测不到的规矩。
    IF p_table NOT IN ('materials','suppliers','customers',
                       'employees','departments','storage_locations') THEN
        RAISE EXCEPTION 'IMPORT_TABLE_NOT_IMPORTABLE|%', p_table;
    END IF;

    RETURN QUERY
    WITH cols AS (
        SELECT a.attname::text AS nm,
               a.attnotnull     AS notnull,
               (ad.adbin IS NOT NULL) AS has_default,
               (a.attgenerated <> '') AS generated
          FROM pg_attribute a
          JOIN pg_class c ON c.oid = a.attrelid
          JOIN pg_namespace n ON n.oid = c.relnamespace
          LEFT JOIN pg_attrdef ad ON ad.adrelid = a.attrelid AND ad.adnum = a.attnum
         WHERE n.nspname = 'public' AND c.relname = p_table
           AND a.attnum > 0 AND NOT a.attisdropped
    ),
    -- 单列 CHECK 里的闭集,以及真正的 enum 类型 —— 两种都要
    sets AS (
        SELECT a.attname::text AS nm,
               array_agg(DISTINCT m[1] ORDER BY m[1]) AS vals
          FROM pg_constraint con
          JOIN pg_class rel ON rel.oid = con.conrelid
          JOIN pg_namespace n ON n.oid = rel.relnamespace
          JOIN unnest(con.conkey) k(num) ON true
          JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k.num,
               LATERAL regexp_matches(pg_get_constraintdef(con.oid), '''([^'']+)''::text', 'g') m
         WHERE con.contype = 'c' AND n.nspname='public' AND rel.relname = p_table
           AND array_length(con.conkey,1) = 1
         GROUP BY a.attname
    )
    SELECT cols.nm,
           -- 【必填 = NOT NULL 且【没有】默认值】。有默认值的 NOT NULL 列**不是**必填:
           -- 留空是合法的,导入会把那个键整个省掉,让默认值生效。
           (cols.notnull AND NOT cols.has_default),
           sets.vals
      FROM cols LEFT JOIN sets ON sets.nm = cols.nm
     WHERE NOT (cols.nm = ANY (master_import_forbidden_columns()))
       -- 【GENERATED 列【根本不出现在模板里】】数据库会拒收一个供给的值,
       -- 而一个"发出来又被拒"的列正是本刀要消灭的东西。
       AND NOT cols.generated
     ORDER BY cols.nm;
END;
$function$
;

COMMIT;
