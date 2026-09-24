-- db/functions/guard_sales_record_direct_write.sql
-- ROLE-1 · Batch 2b(Batch 2 grilling Q14 · Batch 2b grilling Q3):**sales_records 没有直连写**。
--
-- 【量过的】写 sales_records 的四支函数 —— record_output_sale · ship_order ·
-- attribute_sale_customer · allocate_processing_costs —— 全是 SECURITY DEFINER(线上
-- pg_proc.prosecdef = t,2026-09-24 以 postgres 读);没有一个屏幕直连写它。于是 INSERT 与
-- UPDATE 两条写策略(都开在 module.finance.edit 上)一并拿掉。
--   · INSERT 那一条让财务不经 record_output_sale(现归 action.direct_sale)就能记一笔销售;
--   · UPDATE 那一条过得了 reject_sales_record_mutation 的只剩一件事:把 cogs_entry_id 从空
--     填成任何一张分录 —— 伪造一条销货成本的链。
--
-- 【为什么还要一支语句级守卫】没有写策略时,直连 UPDATE / DELETE 是【零行、不报错】
-- (SILENT-1 那一族);本守卫零行也照样触发,按名拒 SALE_THROUGH_FUNCTION_ONLY。
-- 它取代原来那支 enforce_write_permission('module.finance.edit') —— 那支会让财务过关,
-- 再被 RLS 静默吞掉。属主路径(row_security_active = false)一律放行。
--
-- NOTE: introduced by db/migrations/2026-09-24-role1b2b-contracts-prices-direct-sale-and-assay.sql.

CREATE OR REPLACE FUNCTION public.guard_sales_record_direct_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NOT row_security_active(TG_RELID) THEN
        RETURN NULL;
    END IF;
    RAISE EXCEPTION 'SALE_THROUGH_FUNCTION_ONLY';
END;
$function$;

COMMENT ON FUNCTION public.guard_sales_record_direct_write() IS
'ROLE-1 Batch 2b:sales_records 的任何直连写(row_security_active,语句级,零行也触发)按名拒 SALE_THROUGH_FUNCTION_ONLY。写它的四支函数都是 SECURITY DEFINER;直接销售走 record_output_sale(action.direct_sale,cco)。';
