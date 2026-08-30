-- db/migrations/2026-08-30-cmpl1-fu-a-redundant-null-clause-hid-the-enum.sql
-- CMPL-1 fu:把 status 那条 CHECK 里【多余的 IS NULL OR】去掉。
--
-- 【它为什么是多余的】CHECK 约束在表达式求值为 NULL 时【放行】,而
-- `NULL IN ('a','b')` 求值就是 NULL。所以 `status IS NULL OR status IN (...)`
-- 与 `status IN (...)` **语义完全相同** —— 前者只是把一件本来就成立的事又写了一遍。
--
-- 【为什么值得单独一支迁移去改】不只是整洁:那句多余的前缀让
-- scripts/check-i18n.mjs 的 sqlCheckIn 解析不到这个枚举
-- (它认的是本仓库通行的 `CHECK (col IN (...))` 形状),于是
-- `company.licence.status.` 这个动态前缀【接不上真源】。
-- 接不上真源的下场是要么写死一份第二清单、要么标成"静态不可知"——
-- 两条都比把约束写回通行形状差。**这不是迁就检查,是我自己写偏了。**
--
-- 【安全性】company_compliance 线上 0 行,换约束不碰任何数据。

BEGIN;

ALTER TABLE public.company_compliance
    DROP CONSTRAINT company_compliance_status_check;

ALTER TABLE public.company_compliance
    ADD CONSTRAINT company_compliance_status_check
    CHECK (status IN ('active', 'suspended', 'revoked'));

COMMIT;
