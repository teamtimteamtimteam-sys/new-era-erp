-- db/migrations/2026-08-30-cmpl1-fu2-a-masked-table-needs-three-changes-not-one.sql
-- CMPL-1 fu2:给遮蔽表加列,要【三件事一起做】—— 我只做了一件。
--
-- ★【这是 AGENTS.md 写死的一条,而我踩了它】★
--   inbound_batches 是【列级授权】的遮蔽表:perm2b 把整表 SELECT 收回,只按列授出。
--   而 PostgreSQL 对两种动作的处理不一样,这个不对称就是全部的坑:
--     · 表级 INSERT/UPDATE 授权【会自动延伸】到之后新增的列;
--     · 列清单式的 SELECT 授权【不会】—— 清单是冻住的。
--   所以 ALTER TABLE ... ADD COLUMN 之后,应用【写得进、读不出】,
--   任何 select 到它、甚至只是 filter 它的查询都会 42501。
--   FIN-6 就是这么让 /finance/processing-costs 从上线那天起一直是空的,而所有闸都绿。
--
-- 【三件事,本该在【同一支迁移】里】(WO-1a 那一课:分三刀,每一刀看起来都完整)
--   ① ADD COLUMN            ← 上一支迁移做了
--   ② 列清单 GRANT SELECT   ← 漏了,本支补
--   ③ 加进 <表>_masked 视图 ← 漏了,本支补
--   gate 的 colgrant 判词在【live 与 rebuild 两侧】都点了名,所以它是被机制抓到的,
--   不是被人眼抓到的 —— 那正是那条判词存在的理由。
--
-- 【这四列都是【不敏感】的,所以走 ② 而不是"故意不授"】
--   是不是进口货、准证号、谁核的、什么时候核的 —— 都不是价格或身份类数据;
--   真正敏感的那一列(unit_price)仍然只经 _masked 视图按 data.view_prices 透出。

BEGIN;

GRANT SELECT (imported, import_permit_ref, import_permit_verified_by, import_permit_verified_at)
    ON public.inbound_batches TO authenticated;

-- 【WITH (security_invoker = off) 必须显式写出来】pg_get_viewdef 不吐 reloptions,
-- 照它重建会把这一句悄悄丢掉(AGENTS.md 为 PAYEE-1a 记过这一条)。实测线上就是 off。
CREATE OR REPLACE VIEW public.inbound_batches_masked
    WITH (security_invoker = off) AS
 SELECT id,
    code,
    material_id,
    supplier_id,
    quantity,
    unit,
    remaining_qty,
    arrival_date,
    stage,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN unit_price
            ELSE NULL::numeric
        END AS unit_price,
    notes,
    status,
    deleted_at,
    created_at,
    created_by,
    updated_at,
    updated_by,
    purchase_order_id,
    purchase_order_line_id,
    pricing_formula_id,
    pricing_status,
    deleted_by,
    delete_reason,
    declared_qty,
    chemistry_certainty_code,
    imported,
    import_permit_ref,
    import_permit_verified_by,
    import_permit_verified_at
   FROM inbound_batches
  WHERE has_permission('module.inbound.view'::text);;

COMMIT;
