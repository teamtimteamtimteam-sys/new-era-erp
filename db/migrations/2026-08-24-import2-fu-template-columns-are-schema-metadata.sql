-- 2026-08-24-import2-fu-template-columns-are-schema-metadata.sql
-- IMPORT-2-fu:模板列这支函数不再判权限 —— 它返回的是 schema 元数据,不是业务数据。
--
-- 【为什么】两条,第二条是硬的:
-- ① 它给的只有列名、必不必填、CHECK 取值集合。那不是要护的数据;真正的门在
--    路由与页面(action.bulk_import)。
-- ② **db/gate.py 的 import-template 检查要在【重建库】上调它,而重建库一个用户都没有。**
--    has_permission 解析 auth.uid(),所以任何带权限判断的版本在那里都调不动 ——
--    于是那条检查根本不可能存在。一个为了一层无谓的权限而【测不到】的函数,
--    换来的是一条测不到的规矩,而这个仓库对"测不到的规矩"有过很多次教训。

BEGIN;

CREATE OR REPLACE FUNCTION public.master_import_template_columns(p_table text)
 RETURNS TABLE(column_name text, is_required boolean, accepted_values text[])
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
    -- 【本函数【不】判权限,而这是一个决定 —— 理由写在这里免得有人"补上"】
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
