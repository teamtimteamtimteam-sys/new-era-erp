-- db/functions/search_recents_uncovered.sql
-- SEARCH-2b · 迁移 D。表的镜像在 db/tables/document_types.sql;
-- 模块闸的行为断言在 db/fixtures/101-a-declared-module-gate-is-the-one-the-policy-calls.sql。

-- ── 「最近编辑过」覆盖不到几张表 —— ★ 现算,不写死 ★ ────────────────────────
-- 【为什么是一支函数而不是应用里的一个常量】裁定当时写的是「10 张未覆盖的表在
--   屏幕上点名」,而那个 10 的分母是【31 张有行的表】;单据种类是 39 张表,
--   同一个判据给出 17。一个抄进 TSX 的数字会在下一次加一张单据表时安静地错掉,
--   而没有任何东西会红。☞ 让机器把这个事实读出来,不叮嘱下一个人记着改。
-- 【数的是【表】,不是【种类】】payments 一张表上挂着两个前缀(RCPT / PMT);
--   屏幕上那句话说的是"有几张表还没有这半功能",所以按 table_name 去重。
CREATE OR REPLACE FUNCTION public.search_recents_uncovered()
 RETURNS integer
 LANGUAGE sql
 STABLE
AS $function$
    SELECT count(DISTINCT d.table_name)::integer
      FROM document_types d
     WHERE NOT EXISTS (
            SELECT 1 FROM pg_attribute a
             WHERE a.attrelid = format('public.%I', d.table_name)::regclass
               AND a.attname = 'updated_by' AND a.attnum > 0 AND NOT a.attisdropped)
        OR NOT EXISTS (
            SELECT 1 FROM pg_attribute a
             WHERE a.attrelid = format('public.%I', d.table_name)::regclass
               AND a.attname = 'updated_at' AND a.attnum > 0 AND NOT a.attisdropped);
$function$;
