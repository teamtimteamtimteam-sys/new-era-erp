-- FIN-28-fu1(2026-08-07):把四个视图的 security_invoker=on 还回去。
--
-- 【我在 FIN-28 里弄丢的】那支迁移为了改列名 DROP 后重建了八个视图,重建语句里
-- 只给四个遮蔽视图补了 WITH (security_invoker = off),另外四个
-- (batch_assay_status / po_prepayment_applicable / po_receivable_lines /
--  purchase_order_status)【原本是 security_invoker = on】,重建时没写,
-- 于是落成了默认值 off —— 它们从"以调用者身份读基表"变成了"以属主身份读"。
-- 那是一次【权限语义的改动】,而 FIN-28 说好是纯改名。
--
-- 【是门抓到的,不是人看出来的】db/gate.py 的判词【镜像 vs 线上】当场报
-- `[view] xxx.opts DIFFERS live="" rebuild="security_invoker=on"` 四条。
-- 值得记一笔:DROP 视图会带走的不只是 GRANT(那一条 FIN-28 记得),
-- 还有【视图选项】。下次 DROP 重建视图,两样都要先抄下来。
--
-- 应用:./db/apply_migration.sh db/migrations/2026-08-07-fin28-fu1-restore-view-options.sql

BEGIN;

ALTER VIEW public.batch_assay_status       SET (security_invoker = on);
ALTER VIEW public.po_prepayment_applicable SET (security_invoker = on);
ALTER VIEW public.po_receivable_lines      SET (security_invoker = on);
ALTER VIEW public.purchase_order_status    SET (security_invoker = on);

COMMIT;
