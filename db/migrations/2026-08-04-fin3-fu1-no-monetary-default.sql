-- db/migrations/2026-08-04-fin3-fu1-no-monetary-default.sql
-- FIN-3 追问 1:accounts.is_monetary 去掉 DEFAULT。
-- 有默认值,明年新增一个应付科目就会【没人问过】地悄悄跳过重估;
-- 去掉默认,建科目那一刻必须明说货币性与否 —— 镜像种子也逐行明写(没有一行是继承来的)。
-- 分类的值本身一行未动:1400/2100(GST 进项/销项)按性质应为货币性,报请确认后另行翻面。
BEGIN;
ALTER TABLE public.accounts ALTER COLUMN is_monetary DROP DEFAULT;
COMMIT;
