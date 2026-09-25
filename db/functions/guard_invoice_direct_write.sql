-- db/functions/guard_invoice_direct_write.sql
-- APR-5a(2026-09-25,grilling Q11 ① ②):**invoices 与 invoice_lines 没有直连写**。
--
-- 【量过的】写这两张表的函数 —— create_invoice · create_order_invoice · void_invoice_internal(以及
-- invoices 上 propagate_invoice_void 那支触发器,它在属主身份下触发)—— 全是 SECURITY DEFINER;
-- 没有一个屏幕直连写它们(app/ 里对这两张表只有读)。record_invoice_issue 写的是 invoice_issues,不是它们。
-- 于是四条写策略(两张表各 INSERT、UPDATE,都开在 module.finance.edit 上)一并拿掉。它们放行过的三条路:
--   · UPDATE invoices SET status = 'void':守卫恰好放行 issued → void,绕过 void_invoice 的核销、
--     已发货两条检查与它的冲销分录 —— 应收、合同负债、销项税全留在账上,发票却作废了,
--     行被释放、可以再开一遍;
--   · UPDATE invoice_lines SET invoice_voided = true:一张在册发票的行被释放,同一条销售 / 订单行可以再开票;
--   · INSERT 一张手写的 kind = 'order' 发票:ship_order 的 SO_SHIP_NOT_INVOICED 认它,货发得出去,
--     背后却没有 1100 / 2500 的那一笔。
--
-- 【为什么还要一支语句级守卫】没有写策略时,直连 UPDATE / DELETE 是【零行、不报错】(SILENT-1 那一族);
-- 本守卫零行也照样触发,按名拒 INVOICE_THROUGH_FUNCTION_ONLY。它取代原来两支
-- enforce_write_permission('module.finance.edit') —— 那两支会让财务过关,再被 RLS 静默吞掉。
-- 属主路径(row_security_active = false)一律放行。形状照 guard_sales_record_direct_write。
--
-- NOTE: introduced by db/migrations/2026-09-25-apr5a-credit-notes-and-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.guard_invoice_direct_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NOT row_security_active(TG_RELID) THEN
        RETURN NULL;
    END IF;
    RAISE EXCEPTION 'INVOICE_THROUGH_FUNCTION_ONLY';
END;
$function$;

COMMENT ON FUNCTION public.guard_invoice_direct_write() IS
'APR-5a:invoices 与 invoice_lines 的任何直连写(row_security_active,语句级,零行也触发)按名拒 INVOICE_THROUGH_FUNCTION_ONLY。写它们的函数都是 SECURITY DEFINER;作废与贷项走 submit_invoice_void_request / submit_credit_note_request → CFO 批准。';
