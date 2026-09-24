-- db/functions/guard_po_supplier_approved.sql
-- ROLE-1 · Batch 2a(Batch 2 grilling Q7,Batch 2a grilling Q1):**新开的采购单,供应商必须已批准**。
--
-- 【规则】一张采购单【生下来】那一刻,供应商必须是 approved 或 active、且没被删;
-- 其余每一种状态按名拒:PO_SUPPLIER_NOT_APPROVED|<供应商编号>|<状态>(已删读作 deleted)。
--
-- 【只在 INSERT 上】Q7 的原话:既有采购单照常收货。supplier_id 在 UPDATE 上本来就不许改
-- (guard_po_amendable),所以一张已经开出去的单不会因为这条规矩改不动、收不了货、结不了。
--
-- 【为什么是触发器、而且【每一条路径】都拦(属主也拦)】create_purchase_order 是唯一
-- 开单的函数,但 purchase_orders 上还开着一条 module.purchasing.edit 的直连 INSERT 策略 ——
-- 只查函数,那扇门就绕过去了(Q1)。先例是同一张表上的 trg_purchase_orders_vendor_not_forwarder。
-- 属主路径也拦:一张开给未批准供应商的新单,从哪条路来都是同一件不该发生的事;
-- 要这种单的 fixture 自己去建一家 active 的供应商。
--
-- NOTE: introduced by db/migrations/2026-09-24-role1b2a-cfo-settings-credit-and-supplier-approval.sql.

CREATE OR REPLACE FUNCTION public.guard_po_supplier_approved()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code    text;
    v_status  text;
    v_deleted boolean;
BEGIN
    SELECT s.code, s.status::text, s.deleted_at IS NOT NULL INTO v_code, v_status, v_deleted
      FROM suppliers s WHERE s.id = NEW.supplier_id;
    IF NOT FOUND THEN
        RETURN NEW;  -- 外键会按它自己的名字拒
    END IF;
    IF v_deleted THEN
        RAISE EXCEPTION 'PO_SUPPLIER_NOT_APPROVED|%|deleted', v_code;
    END IF;
    IF v_status NOT IN ('approved', 'active') THEN
        RAISE EXCEPTION 'PO_SUPPLIER_NOT_APPROVED|%|%', v_code, v_status;
    END IF;
    RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.guard_po_supplier_approved() IS
'ROLE-1 Batch 2a:新采购单的供应商必须是 approved 或 active 且没被删,否则 PO_SUPPLIER_NOT_APPROVED|<编号>|<状态或 deleted>。只挂在 INSERT 上(既有采购单照常收货),每一条路径都拦(直连 INSERT 策略那扇门也在内)。';
