-- AUDIT-1a(2026-09-01):把内层基视图【真的】收权。
--
-- ★ 这是一个由 fixture 183G 当场抓到的【真缺陷】,不是一次整理 ★
--
-- 前一支迁移的抬头里写着「batch_audit_trail_all 不授权给任何人」。
-- **那句话当时是假的。** Supabase 在 public schema 上有 DEFAULT PRIVILEGES
-- (`postgres` 与 `supabase_admin` 两个授予者,对象类型 r),于是【每一张新建的
-- 关系】自动带上 anon 与 authenticated 的全部权限 —— 视图也一样。
-- 实测建完之后:
--     batch_audit_trail_all.relacl = {…, anon=arwdDxtm/postgres,
--                                        authenticated=arwdDxtm/postgres, …}
-- 也就是说,判据【可以被绕过去】:任何登录用户直接读内层那一张,
-- 就拿到了不带 may_view、不带受限遮蔽的全量轨迹。
--
-- 【为什么 AUD-1 没有踩到】因为它踩过了,并且写下了那一行:
--     REVOKE ALL ON public.batch_lineage_all FROM authenticated, anon;
-- 本刀照抄了它的【视图拆法】,却漏抄了它的【收权那一句】——
-- 这正是本仓库反复写的那条:**一句写在抬头里的断言,不等于一条被执行的规矩**。
-- 所以补上收权,并由 fixture 183G 长期钉住它(has_table_privilege 直接断言)。
--
-- 【anon 也要收】不只是 authenticated:内层视图对匿名用户同样毫无理由开着。

BEGIN;

REVOKE ALL ON public.batch_audit_trail_all FROM authenticated, anon;

COMMIT;
