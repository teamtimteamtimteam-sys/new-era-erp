-- db/functions/guard_po_direct_write.sql
-- APR-10(2026-09-27):**采购单的四张表没有直连写**(purchase_orders · purchase_order_lines ·
-- purchase_order_payment_terms · purchase_order_line_retentions)。
--
-- 【量过的】APR-10 以 postgres 读 pg_proc:写这四张表的 15 支函数(开 / 改 / 批 / 驳 / 取消 / 关闭 / 重开 / 付款条款 /
-- 质保金释放 / 挂合同 / 收货推进 / 三支留痕)在线上全是 SECURITY DEFINER、属主 postgres;app/ 里对它们只有读。
-- 而 12 条写策略(都开在 module.purchasing.edit 上)放行过的路:
--   · 直连 INSERT 一张采购单 —— approval_status 的默认值是 'approved',于是一张没经过任何人批的单直接生效,
--     品类随便填、开单码不问(Tim 的 Q6 就成了一句空话);
--   · 直连改别人开的单的行、付款条款、质保金 —— 绕过 Q7 的"开单人或这一类的开单码"。
-- 于是 12 条写策略一并拿掉,本守卫按名拒 PO_THROUGH_FUNCTION_ONLY(语句级,零行也触发)。
-- 属主路径(row_security_active = false)一律放行。形状照 guard_journal_direct_write(APR-6)。
-- NOTE: introduced by db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql.

CREATE OR REPLACE FUNCTION public.guard_po_direct_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NOT row_security_active(TG_RELID) THEN
        RETURN NULL;
    END IF;
    RAISE EXCEPTION 'PO_THROUGH_FUNCTION_ONLY';
END;
$function$;
