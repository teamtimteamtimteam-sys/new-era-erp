-- db/tables/supplier_status_history.sql
-- ROLE-1 · Batch 2a(Batch 2a grilling Q3):供应商状态的只增不改变动史 —— 每一步一行,
-- 拉黑与恢复也在内(customer_credit_history 的形状)。
--
-- 【为什么 approval_log 不够】approval_log 记的是【审批】:送审、批准、驳回。拉黑与
-- 「恢复」(拉黑后归档)是 CFO 的决定,却不是一次审批;此前它们唯一的痕迹是
-- suppliers.updated_by,而下一次随便一个编辑就把它盖掉了。
--
-- 写入口只有一个:suppliers 上的 trg_suppliers_status_history(属主身份)。
-- 触发器之前的状态变动没有行:空白好过编造。
-- NOTE: introduced by db/migrations/2026-09-24-role1b2a-cfo-settings-credit-and-supplier-approval.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.supplier_status_history (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    supplier_id  uuid NOT NULL REFERENCES public.suppliers (id),
    -- text,不是 supplier_status:重放时本文件可能先于 suppliers.sql(枚举在那里建)。
    -- 取值由写它的唯一入口(trg_suppliers_status_history)从枚举列抄来。
    from_status  text NOT NULL,
    to_status    text NOT NULL,
    changed_at   timestamptz NOT NULL DEFAULT now(),
    changed_by   uuid,
    note         text
);

CREATE INDEX idx_supplier_status_history_supplier
    ON public.supplier_status_history (supplier_id, changed_at DESC);

COMMENT ON TABLE public.supplier_status_history IS
    'ROLE-1 Batch 2a:供应商状态的只增不改变动史,每一步一行(拉黑与恢复也在内)。写入口只有 suppliers 上的 trg_suppliers_status_history;approval_log 另记送审 / 批准 / 驳回。触发器之前的变动没有行:空白好过编造。';

-- 写入触发器挂在 suppliers 上,镜像也在 db/tables/suppliers.sql(表在哪触发器在哪)

-- 守卫函数体在 db/functions/guard_supplier_status_history_append_only.sql
CREATE TRIGGER trg_supplier_status_history_append_only
    BEFORE UPDATE OR DELETE ON public.supplier_status_history
    FOR EACH ROW EXECUTE FUNCTION public.guard_supplier_status_history_append_only();

ALTER TABLE public.supplier_status_history ENABLE ROW LEVEL SECURITY;
CREATE POLICY "supplier_status_history select by permission"
    ON public.supplier_status_history
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.suppliers.view'::text));
-- 【没有 INSERT / UPDATE / DELETE 策略】唯一写入口是触发器(属主身份)—— 留痕不该有第二个写法。

-- anon 什么都不给(check-anon-grant-decision:每一张新表都要【说出】它对 anon 的决定)。
REVOKE ALL ON public.supplier_status_history FROM anon;
